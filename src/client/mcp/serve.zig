//! MCP server entry point. Resolves the workspace and delegates to the message
//! loop in server.zig.
const std = @import("std");
const session_mod = @import("session.zig");
const server = @import("server.zig");

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, version: []const u8) !void {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);

    var session = session_mod.init(allocator, cwd) catch |err| switch (err) {
        error.ProjectBindingNotFound => {
            try stderr.print("Error: this directory is not bound to a Clumsies Project.\n", .{});
            try stderr.print("Bind the local directory to a Server Project before starting MCP.\n", .{});
            return;
        },
        error.ProjectBindingUnresolved => {
            try stderr.print("Error: the legacy local binding does not match an accessible Server Project.\n", .{});
            try stderr.print("Bind this directory to a canonical Project explicitly.\n", .{});
            return;
        },
        error.ProjectBindingAmbiguous => {
            try stderr.print("Error: more than one accessible Server Project matches the legacy binding.\n", .{});
            try stderr.print("Bind this directory to one canonical Project explicitly.\n", .{});
            return;
        },
        else => return err,
    };
    defer session.deinit(allocator);

    try server.run(stdout, stderr, allocator, version, &session);
}
