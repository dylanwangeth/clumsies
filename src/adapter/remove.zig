const std = @import("std");
const model = @import("model.zig");
const packages = @import("packages/root.zig");
const store = @import("store.zig");
const toml_ops = @import("primitives/toml_ops.zig");
const json_ops = @import("primitives/json_ops.zig");
const json_mcp_registry = @import("primitives/json_mcp_registry.zig");

pub const RemoveSummary = struct {
    removed_count: usize,
    blocked_count: usize,
};

pub fn removeInstall(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    loaded: *store.LoadedManifest,
) !RemoveSummary {
    const manifest = loaded.parsed.value;

    try store.appendWalEvent(allocator, .{
        .event_type = "revision_started",
        .install_id = manifest.install_id,
        .revision = manifest.active_revision,
        .mode = "remove",
        .timestamp = std.time.milliTimestamp(),
        .message = "Starting adapter remove",
    });

    var next_resources: std.ArrayList(model.ManagedResource) = .empty;
    defer next_resources.deinit(allocator);

    var removed_count: usize = 0;
    var blocked_count: usize = 0;

    for (manifest.managed_resources, 0..) |resource, idx| {
        if (!resource.active) {
            try next_resources.append(allocator, resource);
            continue;
        }

        const absolute_path = try resourceAbsolutePath(allocator, manifest.target_root, resource);
        defer allocator.free(absolute_path);
        try stdout.print("[{d}/{d}] remove {s}\n", .{ idx + 1, manifest.managed_resources.len, absolute_path });
        try stdout.flush();

        const content = readFileIfExists(allocator, absolute_path) catch null;
        defer if (content) |owned| allocator.free(owned);

        if (content == null) {
            removed_count += 1;
            try next_resources.append(allocator, .{
                .resource_id = resource.resource_id,
                .resource_kind = resource.resource_kind,
                .relative_path = resource.relative_path,
                .absolute_path = resource.absolute_path,
                .ownership = resource.ownership,
                .fingerprint = resource.fingerprint,
                .managed_content = resource.managed_content,
                .active = false,
            });
            try store.appendWalEvent(allocator, .{
                .event_type = "step_reverted",
                .install_id = manifest.install_id,
                .revision = manifest.active_revision,
                .mode = "remove",
                .timestamp = std.time.milliTimestamp(),
                .step_id = resource.resource_id,
                .resource_id = resource.resource_id,
                .target = resource.relative_path,
                .status = "reverted",
                .message = "Managed file already absent",
            });
            continue;
        }

        if (isTomlFragmentResource(resource)) {
            const managed_config_content = resource.managed_content orelse return error.MissingManagedContent;
            const remove_result = try toml_ops.removeTomlFragment(
                allocator,
                content.?,
                managed_config_content,
            );
            switch (remove_result) {
                .conflict => |message| {
                    blocked_count += 1;
                    try next_resources.append(allocator, resource);
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_blocked",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "blocked",
                        .message = message,
                    });
                },
                .already_absent => {
                    removed_count += 1;
                    try next_resources.append(allocator, .{
                        .resource_id = resource.resource_id,
                        .resource_kind = resource.resource_kind,
                        .relative_path = resource.relative_path,
                        .absolute_path = resource.absolute_path,
                        .ownership = resource.ownership,
                        .fingerprint = resource.fingerprint,
                        .managed_content = resource.managed_content,
                        .active = false,
                    });
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_reverted",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "reverted",
                        .message = "Managed config entries already absent",
                    });
                },
                .delete_file => {
                    try std.fs.deleteFileAbsolute(absolute_path);
                    cleanupEmptyParents(absolute_path, manifest.target_root);
                    removed_count += 1;
                    try next_resources.append(allocator, .{
                        .resource_id = resource.resource_id,
                        .resource_kind = resource.resource_kind,
                        .relative_path = resource.relative_path,
                        .absolute_path = resource.absolute_path,
                        .ownership = resource.ownership,
                        .fingerprint = resource.fingerprint,
                        .managed_content = resource.managed_content,
                        .active = false,
                    });
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_reverted",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "reverted",
                        .message = "Managed config file removed",
                    });
                },
                .rewrite => |rewritten| {
                    defer allocator.free(rewritten);
                    try writeFileAbsolute(absolute_path, rewritten, 0o644);
                    removed_count += 1;
                    try next_resources.append(allocator, .{
                        .resource_id = resource.resource_id,
                        .resource_kind = resource.resource_kind,
                        .relative_path = resource.relative_path,
                        .absolute_path = resource.absolute_path,
                        .ownership = resource.ownership,
                        .fingerprint = resource.fingerprint,
                        .managed_content = resource.managed_content,
                        .active = false,
                    });
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_reverted",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "reverted",
                        .message = "Managed config entries removed",
                    });
                },
            }
            continue;
        }

        if (isJsonHooksRegistryResource(resource)) {
            const managed_hooks_content = try managedHooksContent(allocator, manifest.target_agent, manifest.scope, manifest.target_root, resource);
            defer if (resource.managed_content == null) allocator.free(managed_hooks_content);
            const remove_result = try json_ops.removeJsonHooksRegistry(
                allocator,
                content.?,
                managed_hooks_content,
            );
            switch (remove_result) {
                .conflict => |message| {
                    blocked_count += 1;
                    try next_resources.append(allocator, resource);
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_blocked",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "blocked",
                        .message = message,
                    });
                },
                .already_absent => {
                    removed_count += 1;
                    try next_resources.append(allocator, .{
                        .resource_id = resource.resource_id,
                        .resource_kind = resource.resource_kind,
                        .relative_path = resource.relative_path,
                        .absolute_path = resource.absolute_path,
                        .ownership = resource.ownership,
                        .fingerprint = resource.fingerprint,
                        .managed_content = resource.managed_content,
                        .active = false,
                    });
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_reverted",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "reverted",
                        .message = "Managed hooks entry already absent",
                    });
                },
                .delete_file => {
                    try std.fs.deleteFileAbsolute(absolute_path);
                    cleanupEmptyParents(absolute_path, manifest.target_root);
                    removed_count += 1;
                    try next_resources.append(allocator, .{
                        .resource_id = resource.resource_id,
                        .resource_kind = resource.resource_kind,
                        .relative_path = resource.relative_path,
                        .absolute_path = resource.absolute_path,
                        .ownership = resource.ownership,
                        .fingerprint = resource.fingerprint,
                        .managed_content = resource.managed_content,
                        .active = false,
                    });
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_reverted",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "reverted",
                        .message = "Managed hooks registry removed",
                    });
                },
                .rewrite => |rewritten| {
                    defer allocator.free(rewritten);
                    try writeFileAbsolute(absolute_path, rewritten, 0o644);
                    removed_count += 1;
                    try next_resources.append(allocator, .{
                        .resource_id = resource.resource_id,
                        .resource_kind = resource.resource_kind,
                        .relative_path = resource.relative_path,
                        .absolute_path = resource.absolute_path,
                        .ownership = resource.ownership,
                        .fingerprint = resource.fingerprint,
                        .managed_content = resource.managed_content,
                        .active = false,
                    });
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_reverted",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "reverted",
                        .message = "Managed hooks entry removed",
                    });
                },
            }
            continue;
        }

        if (isJsonMcpRegistryResource(resource)) {
            const managed_mcp_content = resource.managed_content orelse return error.MissingManagedContent;
            const remove_result = try json_mcp_registry.removeJsonMcpRegistry(
                allocator,
                content.?,
                managed_mcp_content,
            );
            switch (remove_result) {
                .conflict => |message| {
                    blocked_count += 1;
                    try next_resources.append(allocator, resource);
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_blocked",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "blocked",
                        .message = message,
                    });
                },
                .already_absent => {
                    removed_count += 1;
                    try next_resources.append(allocator, .{
                        .resource_id = resource.resource_id,
                        .resource_kind = resource.resource_kind,
                        .relative_path = resource.relative_path,
                        .absolute_path = resource.absolute_path,
                        .ownership = resource.ownership,
                        .fingerprint = resource.fingerprint,
                        .managed_content = resource.managed_content,
                        .active = false,
                    });
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_reverted",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "reverted",
                        .message = "Managed MCP server already absent",
                    });
                },
                .delete_file => {
                    try std.fs.deleteFileAbsolute(absolute_path);
                    cleanupEmptyParents(absolute_path, manifest.target_root);
                    removed_count += 1;
                    try next_resources.append(allocator, .{
                        .resource_id = resource.resource_id,
                        .resource_kind = resource.resource_kind,
                        .relative_path = resource.relative_path,
                        .absolute_path = resource.absolute_path,
                        .ownership = resource.ownership,
                        .fingerprint = resource.fingerprint,
                        .managed_content = resource.managed_content,
                        .active = false,
                    });
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_reverted",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "reverted",
                        .message = "Managed MCP registry removed",
                    });
                },
                .rewrite => |rewritten| {
                    defer allocator.free(rewritten);
                    try writeFileAbsolute(absolute_path, rewritten, 0o644);
                    removed_count += 1;
                    try next_resources.append(allocator, .{
                        .resource_id = resource.resource_id,
                        .resource_kind = resource.resource_kind,
                        .relative_path = resource.relative_path,
                        .absolute_path = resource.absolute_path,
                        .ownership = resource.ownership,
                        .fingerprint = resource.fingerprint,
                        .managed_content = resource.managed_content,
                        .active = false,
                    });
                    try store.appendWalEvent(allocator, .{
                        .event_type = "step_reverted",
                        .install_id = manifest.install_id,
                        .revision = manifest.active_revision,
                        .mode = "remove",
                        .timestamp = std.time.milliTimestamp(),
                        .step_id = resource.resource_id,
                        .resource_id = resource.resource_id,
                        .target = resource.relative_path,
                        .status = "reverted",
                        .message = "Managed MCP server removed",
                    });
                },
            }
            continue;
        }

        const current_fingerprint = try store.fingerprintForContent(allocator, content.?);
        defer allocator.free(current_fingerprint);

        if (!std.mem.eql(u8, current_fingerprint, resource.fingerprint)) {
            blocked_count += 1;
            try next_resources.append(allocator, resource);
            try store.appendWalEvent(allocator, .{
                .event_type = "step_blocked",
                .install_id = manifest.install_id,
                .revision = manifest.active_revision,
                .mode = "remove",
                .timestamp = std.time.milliTimestamp(),
                .step_id = resource.resource_id,
                .resource_id = resource.resource_id,
                .target = resource.relative_path,
                .status = "blocked",
                .message = "Managed file drifted and was not removed",
            });
            continue;
        }

        try std.fs.deleteFileAbsolute(absolute_path);
        cleanupEmptyParents(absolute_path, manifest.target_root);
        removed_count += 1;

        try next_resources.append(allocator, .{
            .resource_id = resource.resource_id,
            .resource_kind = resource.resource_kind,
            .relative_path = resource.relative_path,
            .absolute_path = resource.absolute_path,
            .ownership = resource.ownership,
            .fingerprint = resource.fingerprint,
            .managed_content = resource.managed_content,
            .active = false,
        });
        try store.appendWalEvent(allocator, .{
            .event_type = "step_reverted",
            .install_id = manifest.install_id,
            .revision = manifest.active_revision,
            .mode = "remove",
            .timestamp = std.time.milliTimestamp(),
            .step_id = resource.resource_id,
            .resource_id = resource.resource_id,
            .target = resource.relative_path,
            .status = "reverted",
            .message = "Managed file removed",
        });
    }

    const next_status = if (blocked_count == 0) "removed" else "active";
    const next_manifest = model.InstallManifest{
        .install_id = manifest.install_id,
        .adapter_id = manifest.adapter_id,
        .target_agent = manifest.target_agent,
        .scope = manifest.scope,
        .target_root = manifest.target_root,
        .status = next_status,
        .active_revision = manifest.active_revision,
        .managed_resources = try next_resources.toOwnedSlice(allocator),
        .created_at = manifest.created_at,
        .updated_at = std.time.milliTimestamp(),
    };
    defer allocator.free(next_manifest.managed_resources);

    try store.writeManifest(allocator, next_manifest);

    try store.appendWalEvent(allocator, .{
        .event_type = if (blocked_count == 0) "revision_committed" else "revision_aborted",
        .install_id = manifest.install_id,
        .revision = manifest.active_revision,
        .mode = "remove",
        .timestamp = std.time.milliTimestamp(),
        .message = if (blocked_count == 0) "Adapter remove committed" else "Adapter remove left blocked resources",
    });

    return .{
        .removed_count = removed_count,
        .blocked_count = blocked_count,
    };
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

fn cleanupEmptyParents(absolute_path: []const u8, root_hint: []const u8) void {
    var parent_opt = std.fs.path.dirname(absolute_path);
    while (parent_opt) |parent| {
        if (!std.mem.startsWith(u8, parent, root_hint)) break;
        if (std.mem.eql(u8, parent, root_hint)) break;
        std.fs.deleteDirAbsolute(parent) catch break;
        parent_opt = std.fs.path.dirname(parent);
    }
}

fn writeFileAbsolute(path: []const u8, content: []const u8, mode: u16) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = mode });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.Writer.init(file, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

fn isJsonHooksRegistryResource(resource: model.ManagedResource) bool {
    return std.mem.eql(u8, resource.resource_kind, "json_hooks_registry") or
        std.mem.eql(u8, resource.resource_id, "codex.hooks.registry");
}

fn isTomlFragmentResource(resource: model.ManagedResource) bool {
    // `codex_config` is the legacy pre-primitive manifest kind kept for safe uninstall.
    return std.mem.eql(u8, resource.resource_kind, "toml_fragment") or
        std.mem.eql(u8, resource.resource_kind, "codex_config");
}

fn isJsonMcpRegistryResource(resource: model.ManagedResource) bool {
    return std.mem.eql(u8, resource.resource_kind, "json_mcp_registry");
}

fn resourceAbsolutePath(
    allocator: std.mem.Allocator,
    target_root: []const u8,
    resource: model.ManagedResource,
) ![]u8 {
    if (resource.absolute_path) |absolute_path| {
        return allocator.dupe(u8, absolute_path);
    }
    return std.fs.path.join(allocator, &.{ target_root, resource.relative_path });
}

fn managedHooksContent(
    allocator: std.mem.Allocator,
    agent_name: []const u8,
    scope_raw: []const u8,
    target_root: []const u8,
    resource: model.ManagedResource,
) ![]const u8 {
    if (resource.managed_content) |managed_content| return managed_content;

    const scope = model.Scope.parse(scope_raw) orelse .repo;
    const pkg = packages.resolve(agent_name) orelse return error.UnknownAdapterPackage;
    return try (try pkg.renderManagedResource(allocator, resource.resource_id, scope, target_root) orelse error.MissingManagedContent);
}
