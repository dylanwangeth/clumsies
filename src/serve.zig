const std = @import("std");
const mcp_server = @import("mcp/server.zig");
const ws_config = @import("workspace_config.zig");

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, version: []const u8) !void {
    // Resolve workspace cache path from config
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const workspace_root = if (ws_config.resolveWorkspace(allocator, cwd)) |binding|
        ws_config.getCachePath(allocator, binding.ws_id) catch cwd
    else |_|
        // No workspace bound — use cwd as fallback (legacy mode)
        cwd;

    try mcp_server.runWithRoot(stdout, stderr, allocator, version, workspace_root);
}
