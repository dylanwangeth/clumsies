// Animated spinner component for IO operations
// Uses threading to animate while blocking operations run

const std = @import("std");
const styles = @import("styles.zig");

const Color = styles.Color;
const P = styles.P;

// Braille dots spinner frames (9 frames rotating)
const FRAMES = [_][]const u8{
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
    "⠏",
};

const FRAME_DELAY_MS = 80;

/// Animated spinner that runs in a separate thread
pub fn Spinner(comptime WriterType: type) type {
    return struct {
        writer: WriterType,
        message: []const u8,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        thread: ?std.Thread = null,

        const Self = @This();

        /// Start the spinner animation in a background thread
        pub fn start(self: *Self) void {
            if (self.running.load(.acquire)) return;
            self.running.store(true, .release);

            self.thread = std.Thread.spawn(.{}, animateLoop, .{self}) catch {
                // If thread spawn fails, just print static message
                self.writer.print("{s}{s}{s}{s} {s}...", .{
                    P,
                    Color.orange,
                    FRAMES[0],
                    Color.reset,
                    self.message,
                }) catch {};
                self.writer.flush() catch {};
                return;
            };
        }

        fn animateLoop(self: *Self) void {
            var frame_idx: usize = 0;

            while (self.running.load(.acquire)) {
                // Print current frame
                self.writer.print("\r{s}{s}{s}{s} {s}...", .{
                    P,
                    Color.orange,
                    FRAMES[frame_idx],
                    Color.reset,
                    self.message,
                }) catch {};
                self.writer.flush() catch {};

                // Next frame
                frame_idx = (frame_idx + 1) % FRAMES.len;

                // Sleep
                std.Thread.sleep(FRAME_DELAY_MS * std.time.ns_per_ms);
            }
        }

        /// Stop animation and show success ✓
        pub fn succeed(self: *Self) void {
            self.stop();
            self.writer.print("\r\x1b[K{s}{s}✓{s} {s}\n", .{
                P,
                Color.green,
                Color.reset,
                self.message,
            }) catch {};
            self.writer.flush() catch {};
        }

        /// Stop animation and show success with suffix
        pub fn succeedWith(self: *Self, suffix: []const u8) void {
            self.stop();
            self.writer.print("\r\x1b[K{s}{s}✓{s} {s} {s}{s}{s}\n", .{
                P,
                Color.green,
                Color.reset,
                self.message,
                Color.dim,
                suffix,
                Color.reset,
            }) catch {};
            self.writer.flush() catch {};
        }

        /// Stop animation and clear line (for when next content follows immediately)
        pub fn clear(self: *Self) void {
            self.stop();
            self.writer.writeAll("\r\x1b[K") catch {};
            self.writer.flush() catch {};
        }

        /// Stop animation and show error ✗
        pub fn fail(self: *Self) void {
            self.stop();
            self.writer.print("\r\x1b[K{s}{s}✗{s} {s}\n", .{
                P,
                Color.red,
                Color.reset,
                self.message,
            }) catch {};
            self.writer.flush() catch {};
        }

        fn stop(self: *Self) void {
            self.running.store(false, .release);
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
        }
    };
}

/// Create a new animated spinner
pub fn init(writer: anytype, message: []const u8) Spinner(@TypeOf(writer)) {
    return .{
        .writer = writer,
        .message = message,
    };
}

/// Print a static info line (for items that don't need loading state)
/// Displays: → message (in orange)
pub fn info(writer: anytype, message: []const u8) void {
    writer.print("{s}{s}→{s} {s}\n", .{ P, Color.orange, Color.reset, message }) catch {};
}

/// Print a static info line with formatted message
pub fn infoPrint(writer: anytype, comptime fmt: []const u8, args: anytype) void {
    writer.print("{s}{s}→{s} ", .{ P, Color.orange, Color.reset }) catch {};
    writer.print(fmt, args) catch {};
    writer.writeAll("\n") catch {};
}

/// Print a success line without spinner
/// Displays: ✓ message (in green)
pub fn success(writer: anytype, message: []const u8) void {
    writer.print("{s}{s}✓{s} {s}\n", .{ P, Color.green, Color.reset, message }) catch {};
}

/// Print a success line with suffix
pub fn successWith(writer: anytype, message: []const u8, suffix: []const u8) void {
    writer.print("{s}{s}✓{s} {s} {s}{s}{s}\n", .{
        P,
        Color.green,
        Color.reset,
        message,
        Color.dim,
        suffix,
        Color.reset,
    }) catch {};
}

/// Print an error line without spinner
/// Displays: ✗ message (in red)
pub fn err(writer: anytype, message: []const u8) void {
    writer.print("{s}{s}✗{s} {s}\n", .{ P, Color.red, Color.reset, message }) catch {};
}

/// Print an error line with formatted message
pub fn errPrint(writer: anytype, comptime fmt: []const u8, args: anytype) void {
    writer.print("{s}{s}✗{s} ", .{ P, Color.red, Color.reset }) catch {};
    writer.print(fmt, args) catch {};
    writer.writeAll("\n") catch {};
}
