const std = @import("std");
const mcp_server = @import("mcp/server.zig");
const mcp_handlers = @import("mcp/handlers.zig");
const ws_config = @import("workspace_config.zig");

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, version: []const u8) !void {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var session = mcp_handlers.initSession(allocator, cwd) catch |err| switch (err) {
        error.NoWorkspaceFound, error.NoConfigFound => {
            try stderr.print("Error: this directory is not bound to a clumsies workspace.\n", .{});
            try stderr.print("Run 'clumsies init' to bind it to a workspace.\n", .{});
            return;
        },
        else => return err,
    };
    errdefer session.deinit(allocator);

    const ws_dir = try ws_config.getWsDir(allocator, session.ws_id);
    defer allocator.free(ws_dir);

    try mcp_server.runWithRoot(stdout, stderr, allocator, version, ws_dir, session);
}
