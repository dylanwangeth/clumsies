const std = @import("std");
const styles = @import("styles.zig");

const Color = styles.Color;
const P = styles.P;

const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub const Spinner = struct {
    message: []const u8,
    frame: usize = 0,
    running: bool = false,
    thread: ?std.Thread = null,

    pub fn start(self: *Spinner) void {
        self.running = true;
        self.thread = std.Thread.spawn(.{}, spin, .{self}) catch null;
    }

    pub fn succeed(self: *Spinner) void {
        self.stop();
        // Use unbuffered stdout for consistent output ordering
        const stdout = std.fs.File.stdout();
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\x1b[2K\r{s}{s}✓{s} {s}\n", .{ P, Color.green, Color.reset, self.message }) catch return;
        _ = stdout.write(line) catch {};
    }

    pub fn fail(self: *Spinner) void {
        self.stop();
        // Use unbuffered stdout for consistent output ordering
        const stdout = std.fs.File.stdout();
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\x1b[2K\r{s}{s}✗{s} {s}\n", .{ P, Color.red, Color.reset, self.message }) catch return;
        _ = stdout.write(line) catch {};
    }

    fn stop(self: *Spinner) void {
        self.running = false;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn spin(self: *Spinner) void {
        // Use unbuffered stdout directly for immediate animation display
        const stdout = std.fs.File.stdout();
        var buf: [256]u8 = undefined;
        while (self.running) {
            const line = std.fmt.bufPrint(&buf, "\x1b[2K\r{s}{s}{s}{s} {s}...", .{ P, Color.orange, frames[self.frame], Color.reset, self.message }) catch continue;
            _ = stdout.write(line) catch {};
            self.frame = (self.frame + 1) % frames.len;
            std.Thread.sleep(80 * std.time.ns_per_ms);
        }
        // Clear spinner line before final status is written
        _ = stdout.write("\x1b[2K\r") catch {};
    }
};

pub fn init(_: anytype, message: []const u8) Spinner {
    return Spinner{
        .message = message,
    };
}
