const std = @import("std");
const styles = @import("styles.zig");

pub const Color = styles.Color;
pub const P = styles.P;

pub const Mode = enum {
    human, // TTY — colors, decorative output
    pipe, // Non-TTY — raw text for hooks/scripts
};

var cached_mode: ?Mode = null;

pub fn detect() Mode {
    if (cached_mode) |m| return m;
    const m: Mode = if (std.fs.File.stdout().isTty()) .human else .pipe;
    cached_mode = m;
    return m;
}

pub fn reset() void {
    cached_mode = null;
}
