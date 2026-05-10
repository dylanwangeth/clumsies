//! Adapter installation planner. Given a package and target scope, reads existing files, detects
//! conflicts with non-managed content, and produces a Plan of file operations. Handles TOML
//! fragment merging, JSON hooks registry merging, and MCP registry merging.
const std = @import("std");
const model = @import("model.zig");
const packages = @import("packages/root.zig");
const store = @import("store.zig");
const toml_ops = @import("primitives/toml_ops.zig");
const json_ops = @import("primitives/json_ops.zig");
const json_mcp_registry = @import("primitives/json_mcp_registry.zig");

pub fn buildAdaptPlan(
    allocator: std.mem.Allocator,
    pkg: packages.AdapterPackage,
    scope: model.Scope,
    target_root: []const u8,
    is_update: bool,
) !model.BuildResult {
    const computed_install_id = try store.installIdForTarget(allocator, pkg.id, scope.cliString(), target_root);
    var loaded_opt = try store.loadManifestForTarget(allocator, pkg.id, scope.cliString(), target_root);
    defer if (loaded_opt) |*loaded| loaded.deinit();
    const install_id = if (loaded_opt) |loaded| blk: {
        allocator.free(computed_install_id);
        break :blk try allocator.dupe(u8, loaded.parsed.value.install_id);
    } else computed_install_id;
    var release_install_id = true;
    defer if (release_install_id) allocator.free(install_id);

    if (loaded_opt) |loaded| {
        const manifest = loaded.parsed.value;
        const is_active = std.mem.eql(u8, manifest.status, "active");
        if (is_active and !is_update) {
            return .{ .conflict = .{
                .install_id = try allocator.dupe(u8, install_id),
                .target_root = try allocator.dupe(u8, target_root),
                .path = try allocator.dupe(u8, target_root),
                .message = try std.fmt.allocPrint(allocator, "An active {s} adapter install already exists in this scope. Use --update to refresh it, or remove it first.", .{pkg.display_name}),
            } };
        }
        if (!is_active and is_update) {
            return .{ .conflict = .{
                .install_id = try allocator.dupe(u8, install_id),
                .target_root = try allocator.dupe(u8, target_root),
                .path = try allocator.dupe(u8, target_root),
                .message = try std.fmt.allocPrint(allocator, "No active {s} adapter install exists for the selected scope.", .{pkg.display_name}),
            } };
        }
    } else if (is_update) {
        return .{ .conflict = .{
            .install_id = try allocator.dupe(u8, install_id),
            .target_root = try allocator.dupe(u8, target_root),
            .path = try allocator.dupe(u8, target_root),
            .message = try std.fmt.allocPrint(allocator, "No active {s} adapter install exists for the selected scope.", .{pkg.display_name}),
        } };
    }

    var steps: std.ArrayList(model.PlanStep) = .empty;
    defer {
        model.deinitPlanStepsSlice(allocator, steps.items);
        steps.deinit(allocator);
    }

    const runtime_assets = try pkg.renderRuntimeAssets(allocator, scope, target_root);
    defer pkg.deinitRenderedAssets(allocator, runtime_assets);

    for (runtime_assets) |asset| {
        const absolute_path = try assetAbsolutePath(allocator, target_root, asset);
        defer allocator.free(absolute_path);

        const existing = readFileIfExists(allocator, absolute_path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (existing) |content| allocator.free(content);

        if (std.mem.eql(u8, asset.resource_kind, "toml_fragment")) {
            const previous_managed = previousManagedContent(loaded_opt, asset.resource_id);
            const toml_result = try toml_ops.prepareTomlFragment(allocator, existing, asset.content, previous_managed);
            switch (toml_result) {
                .conflict => |message| {
                    return .{ .conflict = .{
                        .install_id = try allocator.dupe(u8, install_id),
                        .target_root = try allocator.dupe(u8, target_root),
                        .path = try allocator.dupe(u8, absolute_path),
                        .message = try allocator.dupe(u8, message),
                    } };
                },
                .prepared => |prepared| {
                    try steps.append(allocator, .{
                        .step_id = try allocator.dupe(u8, asset.resource_id),
                        .resource_id = try allocator.dupe(u8, asset.resource_id),
                        .resource_kind = asset.resource_kind,
                        .relative_path = try allocator.dupe(u8, asset.relative_path),
                        .absolute_path = if (asset.absolute_path) |_| try allocator.dupe(u8, absolute_path) else null,
                        .ownership = asset.ownership,
                        .action = prepared.action,
                        .label = try allocator.dupe(u8, asset.label),
                        .content = prepared.rendered_content,
                        .managed_content = prepared.managed_content,
                        .file_mode = asset.file_mode,
                    });
                },
            }
            continue;
        }

        if (std.mem.eql(u8, asset.resource_kind, "json_hooks_registry")) {
            const hooks_result = try json_ops.prepareJsonHooksRegistry(allocator, existing, asset.content);
            switch (hooks_result) {
                .conflict => |message| {
                    return .{ .conflict = .{
                        .install_id = try allocator.dupe(u8, install_id),
                        .target_root = try allocator.dupe(u8, target_root),
                        .path = try allocator.dupe(u8, absolute_path),
                        .message = try allocator.dupe(u8, message),
                    } };
                },
                .prepared => |prepared| {
                    try steps.append(allocator, .{
                        .step_id = try allocator.dupe(u8, asset.resource_id),
                        .resource_id = try allocator.dupe(u8, asset.resource_id),
                        .resource_kind = asset.resource_kind,
                        .relative_path = try allocator.dupe(u8, asset.relative_path),
                        .absolute_path = if (asset.absolute_path) |_| try allocator.dupe(u8, absolute_path) else null,
                        .ownership = asset.ownership,
                        .action = prepared.action,
                        .label = try allocator.dupe(u8, asset.label),
                        .content = prepared.rendered_content,
                        .managed_content = prepared.managed_content,
                        .file_mode = asset.file_mode,
                    });
                },
            }
            continue;
        }

        if (std.mem.eql(u8, asset.resource_kind, "json_mcp_registry")) {
            const mcp_result = try json_mcp_registry.prepareJsonMcpRegistry(allocator, existing, asset.content);
            switch (mcp_result) {
                .conflict => |message| {
                    return .{ .conflict = .{
                        .install_id = try allocator.dupe(u8, install_id),
                        .target_root = try allocator.dupe(u8, target_root),
                        .path = try allocator.dupe(u8, absolute_path),
                        .message = try allocator.dupe(u8, message),
                    } };
                },
                .prepared => |prepared| {
                    try steps.append(allocator, .{
                        .step_id = try allocator.dupe(u8, asset.resource_id),
                        .resource_id = try allocator.dupe(u8, asset.resource_id),
                        .resource_kind = asset.resource_kind,
                        .relative_path = try allocator.dupe(u8, asset.relative_path),
                        .absolute_path = if (asset.absolute_path) |_| try allocator.dupe(u8, absolute_path) else null,
                        .ownership = asset.ownership,
                        .action = prepared.action,
                        .label = try allocator.dupe(u8, asset.label),
                        .content = prepared.rendered_content,
                        .managed_content = prepared.managed_content,
                        .file_mode = asset.file_mode,
                    });
                },
            }
            continue;
        }

        if (existing) |content| {
            const managed_update = isManagedPlainFileUpdate(allocator, loaded_opt, asset, absolute_path, content);
            if (managed_update == null and is_update and isAdoptableCoreSkillAsset(asset, content)) {
                try steps.append(allocator, .{
                    .step_id = try allocator.dupe(u8, asset.resource_id),
                    .resource_id = try allocator.dupe(u8, asset.resource_id),
                    .resource_kind = asset.resource_kind,
                    .relative_path = try allocator.dupe(u8, asset.relative_path),
                    .absolute_path = if (asset.absolute_path) |_| try allocator.dupe(u8, absolute_path) else null,
                    .ownership = asset.ownership,
                    .action = if (std.mem.eql(u8, content, asset.content)) "keep" else "update",
                    .label = try allocator.dupe(u8, asset.label),
                    .content = try allocator.dupe(u8, asset.content),
                    .managed_content = null,
                    .file_mode = asset.file_mode,
                });
                continue;
            }
            if (isSharedWorkflowSkillAsset(asset) and managed_update == null) {
                try steps.append(allocator, .{
                    .step_id = try allocator.dupe(u8, asset.resource_id),
                    .resource_id = try allocator.dupe(u8, asset.resource_id),
                    .resource_kind = asset.resource_kind,
                    .relative_path = try allocator.dupe(u8, asset.relative_path),
                    .absolute_path = if (asset.absolute_path) |_| try allocator.dupe(u8, absolute_path) else null,
                    .ownership = asset.ownership,
                    .action = "skip",
                    .label = try allocator.dupe(u8, asset.label),
                    .content = try allocator.dupe(u8, content),
                    .managed_content = null,
                    .file_mode = asset.file_mode,
                });
                continue;
            }
            if (!std.mem.eql(u8, content, asset.content)) {
                if (managed_update) |should_update| {
                    try steps.append(allocator, .{
                        .step_id = try allocator.dupe(u8, asset.resource_id),
                        .resource_id = try allocator.dupe(u8, asset.resource_id),
                        .resource_kind = asset.resource_kind,
                        .relative_path = try allocator.dupe(u8, asset.relative_path),
                        .absolute_path = if (asset.absolute_path) |_| try allocator.dupe(u8, absolute_path) else null,
                        .ownership = asset.ownership,
                        .action = if (should_update) "update" else "keep",
                        .label = try allocator.dupe(u8, asset.label),
                        .content = try allocator.dupe(u8, asset.content),
                        .managed_content = null,
                        .file_mode = asset.file_mode,
                    });
                    continue;
                }
                const conflict_message = if (std.mem.eql(u8, asset.resource_kind, "plain_file"))
                    try std.fmt.allocPrint(
                        allocator,
                        "A file already exists at this location and does not match the expected {s} adapter content for {s}. clumsies will not overwrite it automatically.",
                        .{ pkg.display_name, asset.label },
                    )
                else
                    try std.fmt.allocPrint(
                        allocator,
                        "A shared file already exists at this location and does not match the expected {s} adapter content for {s}. Review and merge it before running clumsies adapt again.",
                        .{ pkg.display_name, asset.label },
                    );
                return .{ .conflict = .{
                    .install_id = try allocator.dupe(u8, install_id),
                    .target_root = try allocator.dupe(u8, target_root),
                    .path = try allocator.dupe(u8, absolute_path),
                    .message = conflict_message,
                } };
            }
        }

        try steps.append(allocator, .{
            .step_id = try allocator.dupe(u8, asset.resource_id),
            .resource_id = try allocator.dupe(u8, asset.resource_id),
            .resource_kind = asset.resource_kind,
            .relative_path = try allocator.dupe(u8, asset.relative_path),
            .absolute_path = if (asset.absolute_path) |_| try allocator.dupe(u8, absolute_path) else null,
            .ownership = asset.ownership,
            .action = if (existing == null) "create" else "keep",
            .label = try allocator.dupe(u8, asset.label),
            .content = try allocator.dupe(u8, asset.content),
            .managed_content = null,
            .file_mode = asset.file_mode,
        });
    }

    const revision: u32 = if (loaded_opt) |loaded|
        loaded.parsed.value.active_revision + 1
    else
        1;

    const owned_steps = try steps.toOwnedSlice(allocator);
    steps = .empty;
    release_install_id = false;

    var notes: []const []const u8 = &.{};
    var notes_owned = false;
    if (pkg.render_notes_fn) |notes_fn| {
        if (try notes_fn(allocator, scope, target_root)) |n| {
            notes = n;
            notes_owned = true;
        }
    }
    errdefer if (notes_owned) {
        for (notes) |note| allocator.free(note);
        allocator.free(notes);
    };

    return .{ .plan = .{
        .agent_name = try allocator.dupe(u8, pkg.id),
        .mode = if (is_update) "update" else "adapt",
        .install_id = install_id,
        .scope = scope.cliString(),
        .target_root = try allocator.dupe(u8, target_root),
        .revision = revision,
        .steps = owned_steps,
        .notes = notes,
    } };
}

fn previousManagedContent(loaded_opt: ?store.LoadedManifest, resource_id: []const u8) ?[]const u8 {
    const loaded = loaded_opt orelse return null;
    for (loaded.parsed.value.managed_resources) |resource| {
        if (!std.mem.eql(u8, resource.resource_id, resource_id)) continue;
        return resource.managed_content;
    }
    return null;
}

fn assetAbsolutePath(
    allocator: std.mem.Allocator,
    target_root: []const u8,
    asset: model.RenderedAsset,
) ![]u8 {
    if (asset.absolute_path) |absolute_path| {
        return allocator.dupe(u8, absolute_path);
    }
    return std.fs.path.join(allocator, &.{ target_root, asset.relative_path });
}

fn readFileIfExists(allocator: std.mem.Allocator, absolute_path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(absolute_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var reader = std.fs.File.Reader.init(file, &read_buf);
    return try reader.interface.allocRemaining(allocator, std.io.Limit.limited(256 * 1024));
}

fn isManagedPlainFileUpdate(
    allocator: std.mem.Allocator,
    loaded_opt: ?store.LoadedManifest,
    asset: model.RenderedAsset,
    absolute_path: []const u8,
    existing_content: []const u8,
) ?bool {
    if (!std.mem.eql(u8, asset.resource_kind, "plain_file")) return null;
    const loaded = loaded_opt orelse return null;
    const manifest = loaded.parsed.value;

    for (manifest.managed_resources) |resource| {
        if (!resource.active) continue;
        if (!std.mem.eql(u8, resource.resource_id, asset.resource_id)) continue;
        if (!resourcePathMatches(resource, asset.relative_path, asset.absolute_path, absolute_path)) continue;

        const current_fingerprint = store.fingerprintForContent(allocator, existing_content) catch return null;
        defer allocator.free(current_fingerprint);
        return std.mem.eql(u8, current_fingerprint, resource.fingerprint);
    }

    return null;
}

fn isSharedWorkflowSkillAsset(asset: model.RenderedAsset) bool {
    return std.mem.indexOf(u8, asset.resource_id, ".skills.workflow.") != null;
}

fn isAdoptableCoreSkillAsset(asset: model.RenderedAsset, existing_content: []const u8) bool {
    if (!std.mem.eql(u8, asset.resource_kind, "plain_file")) return false;
    if (std.mem.indexOf(u8, asset.resource_id, ".skills.") == null) return false;
    if (isSharedWorkflowSkillAsset(asset)) return false;

    const parent = std.fs.path.dirname(asset.relative_path) orelse return false;
    const slug = std.fs.path.basename(parent);
    if (slug.len == 0 or std.mem.eql(u8, slug, "skills")) return false;

    var name_buf: [128]u8 = undefined;
    const expected_name = std.fmt.bufPrint(&name_buf, "name: {s}", .{slug}) catch return false;
    return std.mem.indexOf(u8, existing_content, expected_name) != null;
}

fn resourcePathMatches(
    resource: model.ManagedResource,
    asset_relative_path: []const u8,
    asset_absolute_path_opt: ?[]const u8,
    absolute_path: []const u8,
) bool {
    if (asset_absolute_path_opt != null) {
        return if (resource.absolute_path) |resource_absolute_path|
            std.mem.eql(u8, resource_absolute_path, absolute_path)
        else
            false;
    }
    return std.mem.eql(u8, resource.relative_path, asset_relative_path);
}
