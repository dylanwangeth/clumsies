//! Adapter removal. Reads the install manifest to identify managed files, removes exclusive
//! files, unmerges shared fragments (TOML/JSON), and marks the install as removed.
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

        const absolute_path = resolveManagedAbsolutePath(allocator, manifest.target_root, resource) catch |err| switch (err) {
            error.InvalidManagedPath, error.ManagedPathEscapesTargetRoot => {
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
                    .message = switch (err) {
                        error.InvalidManagedPath => "Managed path is invalid and was not removed",
                        error.ManagedPathEscapesTargetRoot => "Managed path escaped target root and was not removed",
                        else => unreachable,
                    },
                });
                continue;
            },
            else => return err,
        };
        defer allocator.free(absolute_path);
        try stdout.print("[{d}/{d}] remove {s}\n", .{ idx + 1, manifest.managed_resources.len, absolute_path });
        try stdout.flush();

        const content = try readFileIfExists(allocator, absolute_path);
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
            const managed_hooks_content = try managedHooksContent(
                allocator,
                manifest.target_agent,
                manifest.adapter_id,
                manifest.scope,
                manifest.target_root,
                resource,
            );
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
    return std.mem.eql(u8, resource.resource_kind, "toml_fragment");
}

fn isJsonMcpRegistryResource(resource: model.ManagedResource) bool {
    return std.mem.eql(u8, resource.resource_kind, "json_mcp_registry");
}

fn resolveManagedAbsolutePath(
    allocator: std.mem.Allocator,
    target_root: []const u8,
    resource: model.ManagedResource,
) ![]u8 {
    const normalized_root = try std.fs.path.resolve(allocator, &.{target_root});
    defer allocator.free(normalized_root);
    const normalized_managed_root = try managedPathRoot(allocator, normalized_root);
    defer allocator.free(normalized_managed_root);

    if (resource.absolute_path) |absolute_path| {
        if (!std.fs.path.isAbsolute(absolute_path)) return error.InvalidManagedPath;
        const resolved = try std.fs.path.resolve(allocator, &.{absolute_path});
        errdefer allocator.free(resolved);
        if (!pathIsWithinRoot(normalized_managed_root, resolved)) return error.ManagedPathEscapesTargetRoot;
        return resolved;
    }

    if (std.fs.path.isAbsolute(resource.relative_path)) return error.InvalidManagedPath;
    const resolved = try std.fs.path.resolve(allocator, &.{ normalized_root, resource.relative_path });
    errdefer allocator.free(resolved);
    if (!pathIsWithinRoot(normalized_root, resolved)) return error.ManagedPathEscapesTargetRoot;
    return resolved;
}

fn managedPathRoot(
    allocator: std.mem.Allocator,
    normalized_root: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, std.fs.path.basename(normalized_root), ".codex")) {
        if (std.fs.path.dirname(normalized_root)) |parent| {
            return allocator.dupe(u8, parent);
        }
    }
    return allocator.dupe(u8, normalized_root);
}

fn managedHooksContent(
    allocator: std.mem.Allocator,
    target_agent: []const u8,
    adapter_id: []const u8,
    scope_raw: []const u8,
    target_root: []const u8,
    resource: model.ManagedResource,
) ![]const u8 {
    if (resource.managed_content) |managed_content| return managed_content;

    const scope = model.Scope.parseCli(scope_raw) orelse .workspace;
    const agent_name = if (target_agent.len != 0) target_agent else adapter_id;
    const pkg = packages.resolve(agent_name) orelse return error.UnknownAdapterPackage;
    return try (try pkg.renderManagedResource(allocator, resource.resource_id, scope, target_root) orelse error.MissingManagedContent);
}

fn pathIsWithinRoot(root: []const u8, candidate: []const u8) bool {
    if (pathEql(root, candidate)) return true;
    if (candidate.len <= root.len) return false;
    if (!pathPrefixEql(root, candidate[0..root.len])) return false;
    return std.fs.path.isSep(candidate[root.len]);
}

fn pathEql(a: []const u8, b: []const u8) bool {
    return if (@import("builtin").os.tag == .windows)
        std.os.windows.eqlIgnoreCaseWtf8(a, b)
    else
        std.mem.eql(u8, a, b);
}

fn pathPrefixEql(expected: []const u8, actual_prefix: []const u8) bool {
    return if (@import("builtin").os.tag == .windows)
        std.os.windows.eqlIgnoreCaseWtf8(expected, actual_prefix)
    else
        std.mem.eql(u8, expected, actual_prefix);
}

test "resolveManagedAbsolutePath keeps paths under target root" {
    const resource = model.ManagedResource{
        .resource_id = "x",
        .relative_path = "hooks/session-start.sh",
        .ownership = "exclusive",
        .fingerprint = "",
        .active = true,
    };
    const resolved = try resolveManagedAbsolutePath(std.testing.allocator, "/tmp/clumsies-root", resource);
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(pathIsWithinRoot("/tmp/clumsies-root", resolved));
}

test "resolveManagedAbsolutePath rejects relative escape outside target root" {
    const resource = model.ManagedResource{
        .resource_id = "x",
        .relative_path = "../outside.txt",
        .ownership = "exclusive",
        .fingerprint = "",
        .active = true,
    };
    try std.testing.expectError(
        error.ManagedPathEscapesTargetRoot,
        resolveManagedAbsolutePath(std.testing.allocator, "/tmp/clumsies-root", resource),
    );
}

test "resolveManagedAbsolutePath rejects absolute path outside target root" {
    const resource = model.ManagedResource{
        .resource_id = "x",
        .relative_path = "hooks/session-start.sh",
        .absolute_path = "/tmp/elsewhere/file.sh",
        .ownership = "exclusive",
        .fingerprint = "",
        .active = true,
    };
    try std.testing.expectError(
        error.ManagedPathEscapesTargetRoot,
        resolveManagedAbsolutePath(std.testing.allocator, "/tmp/clumsies-root", resource),
    );
}

test "resolveManagedAbsolutePath allows codex sibling managed paths" {
    const resource = model.ManagedResource{
        .resource_id = "codex.skills.discover",
        .relative_path = ".agents/skills/discover/SKILL.md",
        .absolute_path = "/tmp/workspace/.agents/skills/discover/SKILL.md",
        .ownership = "exclusive",
        .fingerprint = "",
        .active = true,
    };
    const resolved = try resolveManagedAbsolutePath(std.testing.allocator, "/tmp/workspace/.codex", resource);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("/tmp/workspace/.agents/skills/discover/SKILL.md", resolved);
}
