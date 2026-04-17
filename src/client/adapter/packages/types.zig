const std = @import("std");
const model = @import("../model.zig");

pub const AdapterPackage = struct {
    id: []const u8,
    display_name: []const u8,
    choice_description: []const u8,
    workspace_scope_description: ?[]const u8 = null,
    user_scope_description: ?[]const u8 = null,
    remove_workspace_scope_description: ?[]const u8 = null,
    remove_user_scope_description: ?[]const u8 = null,
    resolve_target_root_fn: *const fn (allocator: std.mem.Allocator, scope: model.Scope, workspace_root_opt: ?[]const u8) anyerror!?[]const u8,
    render_runtime_assets_fn: *const fn (allocator: std.mem.Allocator, scope: model.Scope, target_root: []const u8) anyerror![]model.RenderedAsset,
    deinit_rendered_assets_fn: *const fn (allocator: std.mem.Allocator, assets: []const model.RenderedAsset) void,
    render_managed_resource_fn: ?*const fn (allocator: std.mem.Allocator, resource_id: []const u8, scope: model.Scope, target_root: []const u8) anyerror!?[]u8 = null,

    pub fn resolveTargetRoot(self: AdapterPackage, allocator: std.mem.Allocator, scope: model.Scope, workspace_root_opt: ?[]const u8) !?[]const u8 {
        return self.resolve_target_root_fn(allocator, scope, workspace_root_opt);
    }

    pub fn renderRuntimeAssets(self: AdapterPackage, allocator: std.mem.Allocator, scope: model.Scope, target_root: []const u8) ![]model.RenderedAsset {
        return self.render_runtime_assets_fn(allocator, scope, target_root);
    }

    pub fn deinitRenderedAssets(self: AdapterPackage, allocator: std.mem.Allocator, assets: []const model.RenderedAsset) void {
        self.deinit_rendered_assets_fn(allocator, assets);
    }

    pub fn renderManagedResource(self: AdapterPackage, allocator: std.mem.Allocator, resource_id: []const u8, scope: model.Scope, target_root: []const u8) !?[]u8 {
        const render_fn = self.render_managed_resource_fn orelse return null;
        return render_fn(allocator, resource_id, scope, target_root);
    }
};
