//! MCP server entry point. Resolves the workspace and delegates to the message
//! loop in server.zig.
const std = @import("std");
const session_mod = @import("session.zig");
const server = @import("server.zig");
const workspace_config = @import("../workspace_config.zig");

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, version: []const u8) !void {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);

    var session = session_mod.init(allocator, cwd) catch |err| switch (err) {
        error.NoWorkspaceFound, error.NoConfigFound => {
            try stderr.print("Error: this directory is not bound to a clumsies workspace.\n", .{});
            try stderr.print("Run 'clumsies init' to bind it to a workspace.\n", .{});
            return;
        },
        else => return err,
    };
    defer session.deinit(allocator);

    const ws_dir = try workspace_config.getWsDir(allocator, session.ws_id);
    defer allocator.free(ws_dir);

    try server.runWithRoot(stdout, stderr, allocator, version, ws_dir, &session);
}
