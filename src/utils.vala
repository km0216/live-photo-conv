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

namespace LivePhotoConv.Utils {
    const int BUFFER_SIZE = 1 << 16; // 2^6 * 2^10 B = 64 KiB

    /**
     * Reads a string from an input stream.
     *
     * This function reads data from the provided input stream and converts it into a string.
     * It uses a buffer to read the data in chunks and appends it to a string builder.
     * The function continues reading until there is no more data to read from the input stream.
     *
     * @param input_stream The input stream to read from.
     * @throws IOError if an error occurs while reading from the input stream.
     * @return The string read from the input stream.
    */
    public string get_string_from_file_input_stream (InputStream input_stream) throws IOError {
        var builder = new StringBuilder ();
        uint8[] buffer = new uint8[BUFFER_SIZE + 1]; // allocate one more byte for the null terminator
        buffer.length = BUFFER_SIZE; // Set the length of the buffer to BUFFER_SIZE
        ssize_t bytes_read;

        while ((bytes_read = input_stream.read (buffer)) > 0) {
            buffer[bytes_read] = '\0'; // Add a null terminator to the end of the string
            builder.append ((string) buffer);
        }

        return (owned) builder.str;
    }

    /**
     * Writes the contents of an input stream to an output stream.
     *
     * @param input_stream The input stream to read from.
     * @param output_stream The output stream to write to.
     *
     * @return The number of bytes copied.
     * @throws IOError if an error occurs while reading from or writing to the streams.
    */
    public int64 write_stream (InputStream input_stream, OutputStream output_stream) throws IOError {
        var buffer = new uint8[BUFFER_SIZE];
        ssize_t bytes_read;
        int64 total = 0;
        while ((bytes_read = input_stream.read (buffer)) > 0) {
            buffer.length = (int) bytes_read;
            output_stream.write_all (buffer, null);
            total += bytes_read;
            buffer.length = BUFFER_SIZE;
        }
        return total;
    }

    /**
     * Copies an exact number of bytes from an input stream to an output stream.
     *
     * Unlike a copy to EOF, this never consumes bytes beyond `length` and
     * reports an error if the input ends before the requested range is copied.
     *
     * @param input_stream The input stream to read from.
     * @param output_stream The output stream to write to.
     * @param length The exact number of bytes to copy.
     * @throws IOError if the copy fails, the length is negative, or EOF is reached early.
     */
    public void write_stream_exactly (InputStream input_stream, OutputStream output_stream,
                                      int64 length) throws IOError {
        if (length < 0)
            throw new IOError.INVALID_ARGUMENT ("Cannot copy a negative number of bytes");

        int64 remaining = length;
        var buffer = new uint8[BUFFER_SIZE];
        while (remaining > 0) {
            int chunk_size = (int) (remaining < BUFFER_SIZE ? remaining : BUFFER_SIZE);
            buffer.length = chunk_size;
            ssize_t bytes_read = input_stream.read (buffer);
            if (bytes_read == 0) {
                throw new IOError.FAILED (
                    "Unexpected end of stream: %lld of %lld bytes remain to be copied".printf (
                        remaining, length));
            }
            buffer.length = (int) bytes_read;
            output_stream.write_all (buffer, null);
            remaining -= bytes_read;
            buffer.length = BUFFER_SIZE;
        }
    }

    /**
     * Writes a specified number of bytes from the stream's current position.
     *
     * @param input_stream The input stream to read data from.
     * @param output_stream The output stream to write data to.
     * @param end The number of bytes to write.
     *
     * @throws IOError if an error occurs while reading or writing, or EOF is reached early.
    */
    public void write_stream_before (InputStream input_stream, OutputStream output_stream, int64 end) throws IOError {
        write_stream_exactly (input_stream, output_stream, end);
    }

    /**
     * Checks whether two paths name the same file.
     *
     * Compares the canonicalized paths; hard links to the same file are
     * not considered the same. Symbolic links and URIs are not resolved.
     *
     * @param path_a The first path.
     * @param path_b The second path.
     * @return Whether the two paths name the same file.
     */
    public bool same_file (string path_a, string path_b) {
        return Filename.canonicalize (path_a) == Filename.canonicalize (path_b);
    }

    /**
     * Derives the Item:Mime value of an appended video from its ftyp brand.
     *
     * Motion Photo 1.0 only allows `video/mp4` and `video/quicktime` for
     * video items, so a QuickTime source must not be declared as MP4.
     *
     * @param path The file holding the video bytes.
     * @param offset Byte offset of the video in that file (0 for a plain video).
     * @return "video/quicktime" for a `qt  ` brand, otherwise "video/mp4".
     */
    public string detect_video_mime (string path, int64 offset = 0) {
        try {
            var input = File.new_for_path (path).read ();
            if (offset > 0 && !input.seek (offset, SeekType.SET))
                return "video/mp4";

            var buffer = new uint8[12];
            size_t bytes_read = 0;
            if (!input.read_all (buffer, out bytes_read, null) || bytes_read < 12)
                return "video/mp4";

            var box_type = "%c%c%c%c".printf ((char) buffer[4], (char) buffer[5], (char) buffer[6], (char) buffer[7]);
            if (box_type != "ftyp")
                return "video/mp4";

            var brand = "%c%c%c%c".printf ((char) buffer[8], (char) buffer[9], (char) buffer[10], (char) buffer[11]);
            return brand == "qt  " ? "video/quicktime" : "video/mp4";
        } catch (Error e) {
            return "video/mp4";
        }
    }

    /**
     * Whether every byte of the path is plain ASCII.
     *
     * ASCII is a strict subset of every ANSI code page, so a path that passes
     * this test is always safe to hand to exiv2 on Windows.
     */
    public bool path_is_ascii (string path) {
        unowned uint8[] bytes = (uint8[]) path.data;
        for (int i = 0; i < bytes.length; i++) {
            if (bytes[i] > 0x7e)
                return false;
        }
        return true;
    }

    [CCode (cname = "lpc_run_hidden")]
    extern static int run_program_hidden ([CCode (array_length = false, array_null_terminated = true)] string[] argv,
                                          string? stderr_path);

    /**
     * Runs an external program to completion without opening a console window.
     *
     * A GUI process that spawns a console program (ffmpeg) makes Windows
     * allocate a console, which flashes a black window for every export and
     * leaves the child's standard handles unreliable. The platform layer
     * starts it with CREATE_NO_WINDOW and sends stderr to a file instead.
     *
     * @param argv Argument vector; argv[0] is looked up in PATH.
     * @param stderr_path File that receives the child's stderr, or null.
     * @return The exit status, or -1 when the program could not be started.
     */
    public int run_hidden (string[] argv, string? stderr_path = null) {
        return run_program_hidden (argv, stderr_path);
    }

    /**
     * Appends a diagnostic line to `live-photo-conv.log` in the temp directory.
     *
     * Exports run inside the GUI where stderr is invisible, so the export
     * pipeline records what it actually wrote where it can be read afterwards.
     *
     * @param message The line to record.
     */
    public void log_diagnostic (string message) {
        try {
            var path = Path.build_filename (Environment.get_tmp_dir (), "live-photo-conv.log");
            var stream = FileStream.open (path, "a");
            if (stream != null) {
                stream.puts ("%s %s\n".printf (new DateTime.now_local ().format ("%H:%M:%S.%f"), message));
                stream.flush ();
            }
        } catch (Error e) { }
    }

    /**
     * Copies a file to an ASCII-only alias next to it.
     *
     * Windows builds of exiv2/gexiv2 cannot touch a path that the ANSI code
     * page cannot represent, so operations on such files go through a hidden
     * alias and the result is moved back afterwards.
     *
     * @param path The file to alias.
     * @return The alias path.
     * @throws Error when the copy fails.
     */
    public string ascii_alias_for_file (string path) throws Error {
        var dir_name = Path.get_dirname (path);
        var base_name = Path.get_basename (path);
        var dot = base_name.last_index_of_char ('.');
        var suffix = dot > 0 ? base_name.substring (dot) : ".jpg";
        var alias = Path.build_filename (dir_name,
            ".live-photo-conv-alias-%08x%s".printf (Random.int_range (0, 0x7fffffff), suffix));
        File.new_for_path (path).copy (File.new_for_path (alias), FileCopyFlags.OVERWRITE, null, null);
        return alias;
    }

    /**
     * Copies an alias back over the original file and removes the alias.
     *
     * @param alias The alias path.
     * @param path The original path.
     * @throws Error when the copy back fails; the alias is removed either way.
     */
    public void commit_ascii_alias (string alias, string path) throws Error {
        File.new_for_path (alias).copy (File.new_for_path (path), FileCopyFlags.OVERWRITE, null, null);
        try {
            File.new_for_path (alias).delete (null);
        } catch (Error e) { }
    }

    /**
     * Opens metadata from a file, tolerating names outside the ANSI code page.
     *
     * exiv2 refuses every tag write on a metadata object that has no backing
     * image, so the destination has to be opened before tagging. When its name
     * cannot be represented in the ANSI code page the file is opened through an
     * ASCII alias and the caller deletes the returned alias afterwards.
     *
     * @param metadata The metadata object to load into.
     * @param path The file to open.
     * @return The alias path to delete later, or null when the real path was used.
     * @throws Error when the file cannot be opened.
     */
    public string? open_metadata (GExiv2.Metadata metadata, string path) throws Error {
        if (path_is_ascii (path)) {
            metadata.open_path (path);
            return null;
        }
        var alias = ascii_alias_for_file (path);
        try {
            metadata.open_path (alias);
        } catch (Error e) {
            try {
                File.new_for_path (alias).delete (null);
            } catch (Error ignored) { }
            throw e;
        }
        return alias;
    }

    /**
     * Saves GExiv2 metadata, tolerating destination names outside the ANSI code page.
     *
     * On Windows gexiv2 maps the UTF-8 path with g_win32_locale_filename_from_utf8(),
     * so a destination containing emoji or other non-ANSI characters fails with
     * "Failed to convert ... to locale ...". The file is then copied to an ASCII
     * temporary name in the same directory, the tags are written there, and the
     * bytes are copied back, which keeps the appended video and every tag intact.
     *
     * @param metadata The metadata to write.
     * @param path The destination file.
     * @return true on success, false when exiv2 could not encode the tags.
     * @throws Error when the file could not be copied or written.
     */
    public bool save_metadata (GExiv2.Metadata metadata, string path) throws Error {
        if (path_is_ascii (path))
            return metadata.save_file (path);

        var dir_name = Path.get_dirname (path);
        var base_name = Path.get_basename (path);
        var dot = base_name.last_index_of_char ('.');
        var suffix = dot > 0 ? base_name.substring (dot) : ".jpg";
        var tmp_path = Path.build_filename (dir_name,
            ".live-photo-conv-meta-%08x%s".printf (Random.int_range (0, 0x7fffffff), suffix));

        var source = File.new_for_path (path);
        var target = File.new_for_path (tmp_path);
        try {
            source.copy (target, FileCopyFlags.OVERWRITE, null, null);
            if (!metadata.save_file (tmp_path))
                return false;
            target.copy (source, FileCopyFlags.OVERWRITE, null, null);
            return true;
        } finally {
            try {
                target.delete (null);
            } catch (Error e) { }
        }
    }

    /**
     * Returns the effective locale directory at runtime.
     */
    public string get_localedir () {
#if WINDOWS
        var prefix = Win32.get_package_installation_directory_of_module (null);
        if (prefix != null) {
            return Path.build_filename (prefix, "share", "locale");
        }
#endif
        return LOCALEDIR;
    }
}
