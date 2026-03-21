const std = @import("std");
const mcp_server = @import("mcp/server.zig");

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, version: []const u8) !void {
    try mcp_server.run(stdout, stderr, allocator, version);
}
