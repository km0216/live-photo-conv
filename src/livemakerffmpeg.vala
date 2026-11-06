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

/**
 * Implementation of LiveMaker using FFmpeg.
 */
internal class LivePhotoConv.LiveMakerFFmpeg : LivePhotoConv.LiveMaker {

    /**
     * Creates a new instance.
     *
     * @param video_path Path to the video file
     * @param main_image_path Path to the main image
     * @param dest Destination path for output
     */
    public LiveMakerFFmpeg (string video_path, string? main_image_path = null, string? dest = null) {
        base (video_path, main_image_path, dest);
    }

    public override int64 export_with_video_only () throws Error {
        // No source metadata is reused here: a video carries none exiv2 can read,
        // and LiveMaker.export() builds a fresh object from the written JPEG.
        var live_file = File.new_for_commandline_arg  (this.dest);
        var video_file = File.new_for_commandline_arg  (this.video_path);

        var video_size = video_file.query_info ("standard::size", FileQueryInfoFlags.NONE).get_size ();

        // The still frame is extracted to a temporary file rather than a stdout
        // pipe: when this code runs inside the GUI process the child's stdout is
        // not wired up reliably, and a dead pipe yields exit 0, no stderr and no
        // frame — a live photo with no main image. A file cannot go missing that way.
        var still_path = Path.build_filename (Environment.get_tmp_dir (),
            "live-photo-conv-still-%08x.jpg".printf (Random.int_range (0, 0x7fffffff)));

        // The video path is passed directly so ffmpeg can seek freely
        string[] commands = {
            "ffmpeg",
            "-loglevel", "error",
            "-nostdin",
            "-hwaccel", "auto",
            "-i", this.video_path,
            "-frames:v", "1",
            "-vf", "select=eq(n\\,0)",
            "-y",
            still_path, null, // Need to be null-terminated
        };

        // Run ffmpeg through the hidden launcher: a GUI process spawning a
        // console program would flash a black window on every export, and its
        // standard handles are not wired up reliably either (a dead stdout pipe
        // silently yields a live photo with no main image).
        var stderr_path = Path.build_filename (Environment.get_tmp_dir (),
            "live-photo-conv-ffmpeg.log");
        var exit_code = Utils.run_hidden (commands, stderr_path);

        var stderr_text = "";
        try {
            FileUtils.get_contents (stderr_path, out stderr_text);
        } catch (Error e) { }

        var still_file = File.new_for_path (still_path);
        int64 still_bytes = 0;
        try {
            still_bytes = still_file.query_info ("standard::size", FileQueryInfoFlags.NONE).get_size ();
        } catch (Error e) { }

        var stderr_trimmed = stderr_text.strip ();
        if (stderr_trimmed.length > 600)
            stderr_trimmed = stderr_trimmed.substring (0, 600);
        Utils.log_diagnostic ("ffmpeg run: bin=`%s' exit=%d still_bytes=%s stderr=`%s'"
            .printf (Environment.find_program_in_path ("ffmpeg") ?? "(not on PATH)",
                exit_code, still_bytes.to_string (), stderr_trimmed));

        var output_stream = live_file.replace (null, this.make_backup, this.file_create_flags);
        try {
            if (exit_code == 0 && still_bytes > 0) {
                var still_stream = still_file.read ();
                Utils.write_stream (still_stream, output_stream);
            }
        } finally {
            try {
                still_file.delete (null);
            } catch (Error e) { }
        }

        if (exit_code != 0) {
            output_stream.close ();
            throw new ExportError.FFMPEG_EXIED_WITH_ERROR (
                "Command `%s' failed with %d - `%s'",
                string.joinv (" ", commands),
                exit_code,
                stderr_trimmed);
        }
        if (still_bytes <= 0) {
            output_stream.close ();
            throw new ExportError.FFMPEG_EXIED_WITH_ERROR (
                "Command `%s' exited 0 but wrote no still frame", string.joinv (" ", commands));
        }

        // Write the video to the live photo
        var video_stream = video_file.read ();
        Utils.write_stream (video_stream, output_stream);

        // g_file_replace() stages the write in a temporary file and only renames
        // it over the destination on close, so the live photo does not exist at
        // its final path until this runs.
        output_stream.close ();

        int64 written = -1;
        try {
            written = live_file.query_info ("standard::size", FileQueryInfoFlags.NONE).get_size ();
        } catch (Error e) { }
        Utils.log_diagnostic ("video-only: dest=`%s' video=`%s' video_bytes=%s written=%s"
            .printf (this.dest, this.video_path, video_size.to_string (), written.to_string ()));

        return video_size;
    }

    public override File write_main_image () throws Error {
        var main_file = File.new_for_commandline_arg (this.main_image_path);
        var live_file = File.new_for_commandline_arg (this.dest);

        if (is_supported_main_image (main_file)) {
            // If the main image is supported, copy it to the live photo
            this.open_source_metadata (this.main_image_path);
            if (!this.export_original_metadata) {
                this.metadata.clear ();
            }

            var output_stream = live_file.replace (null, this.make_backup, this.file_create_flags);
            var main_input_stream = main_file.read ();
            Utils.write_stream (main_input_stream, output_stream);
        } else {
            // Convert the main image to supported format
            Reporter.warning_puts ("FormatWarning", "Image format is not supported, converting to JPEG");
            bool display_oriented = this.export_original_metadata
                && IsoBmff.primary_has_display_transform (this.main_image_path);
            // Same file-based extraction as the video-only path: a stdout pipe is
            // not wired up reliably inside the GUI process.
            var still_path = Path.build_filename (Environment.get_tmp_dir (),
                "live-photo-conv-image-%08x.jpg".printf (Random.int_range (0, 0x7fffffff)));
            string[] commands = {
                "ffmpeg",
                "-loglevel", "error",
                "-nostdin",
                "-autorotate",
                "-i", this.main_image_path,
                "-frames:v", "1",
                "-y",
                still_path, null,
            };
            // Same hidden launcher and file-based extraction as the video-only
            // path: no console window, no stdout pipe to lose.
            var stderr_path = Path.build_filename (Environment.get_tmp_dir (),
                "live-photo-conv-ffmpeg.log");
            var exit_code = Utils.run_hidden (commands, stderr_path);

            var stderr_text = "";
            try {
                FileUtils.get_contents (stderr_path, out stderr_text);
            } catch (Error e) { }

            var still_file = File.new_for_path (still_path);
            int64 still_bytes = 0;
            try {
                still_bytes = still_file.query_info ("standard::size", FileQueryInfoFlags.NONE).get_size ();
            } catch (Error e) { }

            var output_stream = live_file.replace (null, this.make_backup, this.file_create_flags);
            try {
                if (exit_code == 0 && still_bytes > 0) {
                    Utils.write_stream (still_file.read (), output_stream);
                }
            } finally {
                try {
                    still_file.delete (null);
                } catch (Error e) { }
            }

            if (exit_code != 0) {
                output_stream.close ();
                throw new ExportError.FFMPEG_EXIED_WITH_ERROR (
                    "Command `%s' failed with %d - `%s'",
                    string.joinv (" ", commands),
                    exit_code,
                    stderr_text.strip ());
            }
            if (still_bytes <= 0) {
                output_stream.close ();
                throw new ExportError.FFMPEG_EXIED_WITH_ERROR (
                    "Command `%s' exited 0 but wrote no image", string.joinv (" ", commands));
            }
            if (this.export_original_metadata && display_oriented) {
                this.metadata.set_tag_string ("Exif.Image.Orientation", "1");
            }
        }

        return live_file;
    }
}
