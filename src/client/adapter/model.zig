//! Adapter data model: plans, steps, manifests, and conflicts. An adapter install is planned
//! before execution — the planner produces a Plan of PlanSteps (create/update/keep), and the
//! install manifest tracks what was written for safe removal later.
const std = @import("std");

pub const Scope = enum {
    workspace,
    user,

    pub fn cliString(self: Scope) []const u8 {
        return switch (self) {
            .workspace => "workspace",
            .user => "user",
        };
    }

    pub fn parseCli(raw: []const u8) ?Scope {
        if (std.mem.eql(u8, raw, "workspace")) return .workspace;
        if (std.mem.eql(u8, raw, "user")) return .user;
        return null;
    }
};

pub const PlanStep = struct {
    step_id: []const u8,
    resource_id: []const u8,
    resource_kind: []const u8,
    relative_path: []const u8,
    absolute_path: ?[]const u8 = null,
    ownership: []const u8,
    action: []const u8,
    label: []const u8,
    content: []const u8,
    managed_content: ?[]const u8 = null,
    file_mode: u16,
};

pub const RenderedAsset = struct {
    resource_id: []const u8,
    resource_kind: []const u8,
    relative_path: []const u8,
    absolute_path: ?[]const u8 = null,
    ownership: []const u8,
    label: []const u8,
    file_mode: u16,
    content: []const u8,
};

pub const Plan = struct {
    agent_name: []const u8,
    mode: []const u8,
    install_id: []const u8,
    scope: []const u8,
    target_root: []const u8,
    revision: u32,
    steps: []const PlanStep,
    notes: []const []const u8 = &.{},

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_name);
        allocator.free(self.install_id);
        allocator.free(self.target_root);
        for (self.notes) |note| allocator.free(note);
        if (self.notes.len > 0) allocator.free(self.notes);
        deinitPlanStepsSlice(allocator, self.steps);
        allocator.free(self.steps);
    }
};

pub const ManagedResource = struct {
    resource_id: []const u8,
    resource_kind: []const u8 = "plain_file",
    relative_path: []const u8,
    absolute_path: ?[]const u8 = null,
    ownership: []const u8,
    fingerprint: []const u8,
    managed_content: ?[]const u8 = null,
    active: bool,
};

pub const InstallManifest = struct {
    schema_version: []const u8 = "adapter-install/v1",
    install_id: []const u8,
    adapter_id: []const u8 = "",
    target_agent: []const u8 = "",
    scope: []const u8 = "",
    target_root: []const u8,
    status: []const u8,
    active_revision: u32,
    managed_resources: []const ManagedResource,
    created_at: i64,
    updated_at: i64,
};

pub const WalEvent = struct {
    schema_version: []const u8 = "adapter-wal/v1",
    event_type: []const u8,
    install_id: []const u8,
    revision: u32,
    mode: []const u8,
    timestamp: i64,
    step_id: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    target: ?[]const u8 = null,
    status: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const Conflict = struct {
    install_id: []const u8,
    target_root: []const u8,
    path: []const u8,
    message: []const u8,

    pub fn deinit(self: *Conflict, allocator: std.mem.Allocator) void {
        allocator.free(self.install_id);
        allocator.free(self.target_root);
        allocator.free(self.path);
        allocator.free(self.message);
    }
};

pub const BuildResult = union(enum) {
    plan: Plan,
    conflict: Conflict,
};

pub const ApplySummary = struct {
    wrote_count: usize,
    kept_count: usize,
};

pub fn deinitOwnedManifest(allocator: std.mem.Allocator, manifest: *InstallManifest) void {
    allocator.free(manifest.install_id);
    allocator.free(manifest.target_root);
    for (manifest.managed_resources) |resource| {
        allocator.free(resource.fingerprint);
        if (resource.managed_content) |managed_content| allocator.free(managed_content);
    }
    allocator.free(manifest.managed_resources);
}

pub fn deinitPlanStepsSlice(allocator: std.mem.Allocator, steps: []const PlanStep) void {
    for (steps) |step| {
        allocator.free(step.step_id);
        allocator.free(step.resource_id);
        allocator.free(step.relative_path);
        if (step.absolute_path) |absolute_path| allocator.free(absolute_path);
        allocator.free(step.label);
        allocator.free(step.content);
        if (step.managed_content) |managed_content| allocator.free(managed_content);
    }
}

const testing = std.testing;

test "Scope uses a single spelling across CLI and state" {
    try testing.expectEqual(Scope.workspace, Scope.parseCli("workspace").?);
    try testing.expect(Scope.parseCli("local") == null);
    try testing.expectEqualStrings("workspace", Scope.workspace.cliString());
    try testing.expectEqualStrings("user", Scope.user.cliString());
}
