const std = @import("std");
const styles = @import("styles.zig");

const Color = styles.Color;
const P = styles.P;

const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub const Spinner = struct {
    message: []const u8,
    is_tty: bool,
    frame: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn start(self: *Spinner) void {
        if (!self.is_tty) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, spin, .{self}) catch null;
    }

    pub fn succeed(self: *Spinner) void {
        self.stop();
        const stdout = std.fs.File.stdout();
        var buf: [256]u8 = undefined;
        if (self.is_tty) {
            const line = std.fmt.bufPrint(&buf, "\x1b[2K\r{s}{s}✓{s} {s}\n", .{ P, Color.green, Color.reset, self.message }) catch return;
            _ = stdout.write(line) catch {};
        } else {
            const line = std.fmt.bufPrint(&buf, "{s}✓ {s}\n", .{ P, self.message }) catch return;
            _ = stdout.write(line) catch {};
        }
    }

    pub fn fail(self: *Spinner) void {
        self.stop();
        const stdout = std.fs.File.stdout();
        var buf: [256]u8 = undefined;
        if (self.is_tty) {
            const line = std.fmt.bufPrint(&buf, "\x1b[2K\r{s}{s}✗{s} {s}\n", .{ P, Color.red, Color.reset, self.message }) catch return;
            _ = stdout.write(line) catch {};
        } else {
            const line = std.fmt.bufPrint(&buf, "{s}✗ {s}\n", .{ P, self.message }) catch return;
            _ = stdout.write(line) catch {};
        }
    }

    fn stop(self: *Spinner) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn spin(self: *Spinner) void {
        const stdout = std.fs.File.stdout();
        var buf: [256]u8 = undefined;
        while (self.running.load(.acquire)) {
            const frame = self.frame.load(.acquire);
            const line = std.fmt.bufPrint(&buf, "\x1b[2K\r{s}{s}{s}{s} {s}...", .{ P, Color.orange, frames[frame], Color.reset, self.message }) catch continue;
            _ = stdout.write(line) catch {};
            self.frame.store((frame + 1) % frames.len, .release);
            std.Thread.sleep(80 * std.time.ns_per_ms);
        }
        _ = stdout.write("\x1b[2K\r") catch {};
    }
};

pub fn init(_: *std.io.Writer, message: []const u8) Spinner {
    return Spinner{
        .message = message,
        .is_tty = std.fs.File.stdout().isTty(),
    };
}
