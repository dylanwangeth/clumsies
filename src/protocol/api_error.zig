const httpz = @import("httpz");

pub fn send(res: *httpz.Response, status: u16, code: []const u8, message: []const u8) !void {
    res.status = status;
    try res.json(.{ .@"error" = .{ .code = code, .message = message } }, .{});
}
