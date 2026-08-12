//! TTY detection for CLI output formatting. Caches whether stdout is a terminal to decide
//! between colored (human-readable) and plain (pipe-friendly) output modes.
const std = @import("std");

const Mode = enum {
    human, // TTY — colors, decorative output
    pipe, // Non-TTY — raw text for hooks/scripts
};

var cached_mode: ?Mode = null;

pub fn detect() Mode {
    if (cached_mode) |m| return m;
    const m: Mode = if (std.Io.File.stdout().isTty(std.Options.debug_io) catch false) .human else .pipe;
    cached_mode = m;
    return m;
}
