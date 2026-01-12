const std = @import("std");
const styles = @import("styles.zig");

const Color = styles.Color;
const P = styles.P;

const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub const Spinner = struct {
    writer: *std.Io.Writer,
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
        self.writer.print("\x1b[2K\r{s}{s}✓{s} {s}\n", .{ P, Color.green, Color.reset, self.message }) catch {};
    }

    pub fn fail(self: *Spinner) void {
        self.stop();
        self.writer.print("\x1b[2K\r{s}{s}✗{s} {s}\n", .{ P, Color.red, Color.reset, self.message }) catch {};
    }

    fn stop(self: *Spinner) void {
        self.running = false;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn spin(self: *Spinner) void {
        while (self.running) {
            self.writer.print("\x1b[2K\r{s}{s}{s}{s} {s}...", .{ P, Color.orange, frames[self.frame], Color.reset, self.message }) catch {};
            self.frame = (self.frame + 1) % frames.len;
            std.Thread.sleep(80 * std.time.ns_per_ms);
        }
    }
};

pub fn init(writer: *std.Io.Writer, message: []const u8) Spinner {
    return Spinner{
        .writer = writer,
        .message = message,
    };
}
