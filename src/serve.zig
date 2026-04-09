const std = @import("std");
const mcp_server = @import("mcp/server.zig");
const ws_config = @import("workspace_config.zig");

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, version: []const u8) !void {
    // Resolve workspace cache path from config
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var owned_cache_path: ?[]const u8 = null;
    defer if (owned_cache_path) |p| allocator.free(p);

    const workspace_root = if (ws_config.resolveWorkspace(allocator, cwd)) |binding| blk: {
        defer allocator.free(binding.ws_id);
        defer allocator.free(binding.name);
        owned_cache_path = ws_config.getCachePath(allocator, binding.ws_id) catch null;
        break :blk owned_cache_path orelse cwd;
    } else |_| cwd;

    try mcp_server.runWithRoot(stdout, stderr, allocator, version, workspace_root);
}
