/* Copyright 2024-2026 Zhou Qiankang <wszqkzqk@qq.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
*/

#include <glib.h>

#if defined(_WIN32) // Windows
#include <windows.h>
#include <io.h>

#else // Unix
#include <sys/ioctl.h>
#include <unistd.h>
#endif

int get_console_width () {
#if defined(_WIN32)
    CONSOLE_SCREEN_BUFFER_INFO csbi;
    int columns;
    // GetConsoleScreenBufferInfo will return 0 if it FAILS
    int success = GetConsoleScreenBufferInfo (GetStdHandle (STD_ERROR_HANDLE), &csbi);
    if (success) {
        columns = csbi.srWindow.Right - csbi.srWindow.Left + 1;
        return (int) columns;
    } else {
        return 0;
    }
#else // Unix
    struct winsize w;
    // ioctl will return 0 if it SUCCEEDS
    int fail  = ioctl (STDERR_FILENO, TIOCGWINSZ, &w);
    if (fail) {
        return 0;
    } else {
        return (int) w.ws_col;
    }
#endif
}

gboolean is_a_tty (int fd) {
#if defined(_WIN32)
    return (gboolean) (_isatty (fd) != 0);
#else // Unix
    return (gboolean) (isatty (fd) != 0);
#endif
}

#if defined(_WIN32)

/* Appends one argument to a Windows command line, quoted as parsed by
   CommandLineToArgvW. */
static void append_quoted (GString *cmd, const char *arg) {
    if (*arg != '\0' && strpbrk (arg, " \t\n\v\"") == NULL) {
        g_string_append (cmd, arg);
        return;
    }

    g_string_append_c (cmd, '"');
    for (const char *p = arg;; p++) {
        guint backslashes = 0;
        while (*p == '\\') {
            backslashes++;
            p++;
        }
        if (*p == '\0') {
            for (guint i = 0; i < backslashes * 2; i++)
                g_string_append_c (cmd, '\\');
            break;
        } else if (*p == '"') {
            for (guint i = 0; i < backslashes * 2 + 1; i++)
                g_string_append_c (cmd, '\\');
            g_string_append_c (cmd, '"');
        } else {
            for (guint i = 0; i < backslashes; i++)
                g_string_append_c (cmd, '\\');
            g_string_append_c (cmd, *p);
        }
    }
    g_string_append_c (cmd, '"');
}

#endif

/**
 * Runs a program to completion with any console window suppressed.
 *
 * A GUI process that spawns a console program (ffmpeg) makes Windows allocate
 * a fresh console, which shows up as a black window flashing on every export,
 * and the child's standard handles are not wired up reliably either. The child
 * is started with CREATE_NO_WINDOW and its stderr goes to stderr_path, so
 * failures still leave a trace.
 *
 * @param argv NULL-terminated argument vector; argv[0] is searched in PATH.
 * @param stderr_path UTF-8 path that receives the child's stderr, or NULL.
 * @return the child's exit status, or -1 when it could not be started.
 */
int lpc_run_hidden (char **argv, const char *stderr_path) {
#if defined(_WIN32)
    GString *cmd = g_string_new (NULL);
    append_quoted (cmd, argv[0]);
    for (char **arg = argv + 1; *arg != NULL; arg++) {
        g_string_append_c (cmd, ' ');
        append_quoted (cmd, *arg);
    }

    gunichar2 *wcmd = g_utf8_to_utf16 (cmd->str, -1, NULL, NULL, NULL);
    gunichar2 *werr = stderr_path != NULL && *stderr_path != '\0'
        ? g_utf8_to_utf16 (stderr_path, -1, NULL, NULL, NULL)
        : NULL;

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof (sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = TRUE;

    HANDLE err_handle = INVALID_HANDLE_VALUE;
    if (werr != NULL)
        err_handle = CreateFileW ((LPCWSTR) werr, GENERIC_WRITE,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);

    STARTUPINFOW si;
    ZeroMemory (&si, sizeof (si));
    si.cb = sizeof (si);
    si.dwFlags = STARTF_USESTDHANDLES;
    /* Handing over INVALID_HANDLE_VALUE means "no handle", which keeps the
       child from grabbing the parent's or allocating a console. */
    si.hStdInput = INVALID_HANDLE_VALUE;
    si.hStdOutput = err_handle;
    si.hStdError = err_handle;

    PROCESS_INFORMATION pi;
    ZeroMemory (&pi, sizeof (pi));

    int status = -1;
    if (CreateProcessW (NULL, (LPWSTR) wcmd, NULL, NULL, TRUE, CREATE_NO_WINDOW,
                        NULL, NULL, &si, &pi)) {
        WaitForSingleObject (pi.hProcess, INFINITE);
        DWORD code = 1;
        if (GetExitCodeProcess (pi.hProcess, &code))
            status = (int) code;
        CloseHandle (pi.hThread);
        CloseHandle (pi.hProcess);
    }

    if (err_handle != INVALID_HANDLE_VALUE)
        CloseHandle (err_handle);
    g_free (wcmd);
    g_free (werr);
    g_string_free (cmd, TRUE);
    return status;
#else // Unix
    gchar *out = NULL;
    gchar *err = NULL;
    gint wait_status = 0;
    gboolean ok = g_spawn_sync (NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL,
                                &out, &err, &wait_status, NULL);
    if (!ok) {
        g_free (out);
        g_free (err);
        return -1;
    }
    if (stderr_path != NULL)
        g_file_set_contents (stderr_path, err != NULL ? err : "", -1, NULL);
    g_free (out);
    g_free (err);
    return WIFEXITED (wait_status) ? WEXITSTATUS (wait_status) : -1;
#endif
}
