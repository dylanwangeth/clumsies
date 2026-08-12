//! MCP connection context. Project identity is resolved by the daemon from the
//! current workspace path; legacy TOML participates only in one-time migration.
const std = @import("std");
const daemon_ipc = @import("../daemon/ipc.zig");
const workspace_config = @import("../workspace_config.zig");

pub const Session = struct {
    project_id: []const u8,
    workspace_root: []const u8,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.project_id);
        allocator.free(self.workspace_root);
    }
};

pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) !Session {
    var binding = daemon_ipc.resolveProjectBinding(allocator, workspace_root) catch |err| switch (err) {
        error.ProjectBindingNotFound => try migrateLegacyBinding(allocator, workspace_root),
        else => return err,
    };
    errdefer binding.deinit(allocator);

    return .{
        .project_id = binding.project_id,
        .workspace_root = binding.workspace_root,
    };
}

const LegacyProjectRef = struct {
    project_id: []const u8,
    name: []const u8,
};

const LegacyMeResponse = struct {
    projects: []const LegacyProjectRef,
};

fn migrateLegacyBinding(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
) !daemon_ipc.ProjectBinding {
    var hint = workspace_config.resolveLegacyWorkspaceHint(allocator, workspace_path) catch |err| switch (err) {
        error.NoWorkspaceFound, error.NoConfigFound => return error.ProjectBindingNotFound,
        else => return err,
    };
    defer hint.deinit(allocator);

    const body = try daemon_ipc.serverGetBodyAlloc(allocator, "/api/v1/me");
    defer allocator.free(body);
    const parsed = try std.json.parseFromSlice(LegacyMeResponse, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const resolved_project_id = try legacyProjectId(parsed.value.projects, hint.name);
    var binding = try daemon_ipc.replaceProjectBinding(
        allocator,
        hint.workspace_root,
        resolved_project_id,
        null,
    );
    errdefer binding.deinit(allocator);
    try workspace_config.removeLegacyWorkspacePath(allocator, hint.workspace_root);
    daemon_ipc.retryCommitSync(allocator) catch {};
    return binding;
}

fn legacyProjectId(projects: []const LegacyProjectRef, name: []const u8) ![]const u8 {
    var project_id: ?[]const u8 = null;
    for (projects) |project| {
        if (!std.mem.eql(u8, project.name, name)) continue;
        if (project_id != null) return error.ProjectBindingAmbiguous;
        project_id = project.project_id;
    }
    return project_id orelse error.ProjectBindingUnresolved;
}

test "legacy project matching requires one exact project name" {
    const body =
        \\{"projects":[{"project_id":"prj_a","name":"DylanVault"},{"project_id":"prj_b","name":"Koal"}]}
    ;
    const parsed = try std.json.parseFromSlice(LegacyMeResponse, std.testing.allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "prj_a",
        try legacyProjectId(parsed.value.projects, "DylanVault"),
    );
    try std.testing.expectError(
        error.ProjectBindingUnresolved,
        legacyProjectId(parsed.value.projects, "Missing"),
    );
}

test "legacy project matching rejects duplicate names" {
    const projects = [_]LegacyProjectRef{
        .{ .project_id = "prj_a", .name = "Shared" },
        .{ .project_id = "prj_b", .name = "Shared" },
    };
    try std.testing.expectError(
        error.ProjectBindingAmbiguous,
        legacyProjectId(&projects, "Shared"),
    );
}
