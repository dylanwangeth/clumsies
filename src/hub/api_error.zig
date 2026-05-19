//! Structured JSON error responses for Hub endpoints. Provides a consistent error envelope
//! format across all API handlers.
const std = @import("std");
const httpz = @import("httpz");

pub fn send(res: *httpz.Response, status: u16, code: []const u8, message: []const u8) !void {
    res.status = status;
    res.header("x-clumsies-error-code", try headerSafe(res.arena, code));
    res.header("x-clumsies-error-message", try headerSafe(res.arena, message));
    try res.json(.{ .@"error" = .{ .code = code, .message = message } }, .{});
}

fn headerSafe(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |byte, idx| {
        out[idx] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
    }
    return out;
}

test "headerSafe replaces invalid header bytes" {
    const out = try headerSafe(std.testing.allocator, "bad\nvalue");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("bad?value", out);
}
