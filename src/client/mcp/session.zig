//! MCP connection context. Retrieval state is carried explicitly by activate,
//! so this object only identifies the selected project and local workspace.
const std = @import("std");
const workspace_config = @import("../workspace_config.zig");

pub const Session = struct {
    ws_id: []const u8,
    workspace_root: []const u8,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.ws_id);
        allocator.free(self.workspace_root);
    }
};

pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) !Session {
    const binding = try workspace_config.resolveWorkspace(allocator, workspace_root);
    defer allocator.free(binding.name);
    errdefer allocator.free(binding.ws_id);

    return .{
        .ws_id = binding.ws_id,
        .workspace_root = try allocator.dupe(u8, workspace_root),
    };
}
