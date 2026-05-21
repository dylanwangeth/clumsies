//! Antigravity CLI adapter. Handles workspace/user customization files for
//! hooks, MCP, and Agent Skills.
const build_options = @import("build_options");
const model = @import("../model.zig");
const std = @import("std");
const types = @import("types.zig");
const workflow_skills = @import("../workflow_skills.zig");

pub const package: types.AdapterPackage = .{
    .id = "agy",
    .display_name = "Antigravity CLI",
    .choice_description = "Google Antigravity CLI adapter",
    .workspace_scope_description = "Only this workspace (.agents)",
    .user_scope_description = "All Antigravity CLI sessions on this machine (~/.gemini)",
    .remove_workspace_scope_description = "Current workspace install (.agents)",
    .remove_user_scope_description = "Machine-wide install (~/.gemini)",
    .resolve_target_root_fn = resolveTargetRoot,
    .render_runtime_assets_fn = renderRuntimeAssets,
    .deinit_rendered_assets_fn = deinitRenderedAssets,
    .render_managed_resource_fn = renderManagedResource,
    .render_notes_fn = renderNotes,
};

pub fn renderRuntimeAssets(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
) ![]model.RenderedAsset {
    var assets: std.ArrayList(model.RenderedAsset) = .empty;
    errdefer deinitRenderedAssets(allocator, assets.items);

    try assets.append(allocator, .{
        .resource_id = "agy.hooks",
        .resource_kind = "json_named_hooks_registry",
        .relative_path = try scopedRelativePath(allocator, scope, "hooks"),
        .ownership = "shared",
        .label = "Antigravity CLI hooks",
        .file_mode = 0o644,
        .content = try renderHooksJson(allocator, scope, target_root),
    });
    try assets.append(allocator, .{
        .resource_id = "agy.mcp",
        .resource_kind = "json_mcp_registry",
        .relative_path = try scopedRelativePath(allocator, scope, "mcp"),
        .ownership = "shared",
        .label = "Antigravity CLI MCP registry",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_agy_runtime_mcp_config_json),
    });
    try assets.append(allocator, .{
        .resource_id = "agy.hooks.resolve_binary",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, scope, "hooks/resolve-binary.sh"),
        .ownership = "exclusive",
        .label = "Antigravity CLI hook helper",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_agy_runtime_resolve_binary_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "agy.hooks.pre_invocation",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, scope, "hooks/pre-invocation.sh"),
        .ownership = "exclusive",
        .label = "Antigravity CLI PreInvocation hook",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_agy_runtime_pre_invocation_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "agy.hooks.stop_check",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, scope, "hooks/stop-refer-check.sh"),
        .ownership = "exclusive",
        .label = "Antigravity CLI Stop hook",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_agy_runtime_stop_refer_check_sh),
    });
    try appendSkillAsset(allocator, &assets, scope, target_root, "discover", "Antigravity CLI discover skill", build_options.adapter_agy_runtime_skill_discover);
    try appendSkillAsset(allocator, &assets, scope, target_root, "ntmd", "Antigravity CLI ntmd skill", build_options.adapter_agy_runtime_skill_ntmd);
    try appendSkillAsset(allocator, &assets, scope, target_root, "setup", "Antigravity CLI setup skill", build_options.adapter_agy_runtime_skill_setup);

    if (scope == .workspace) {
        const skills_root_absolute = try std.fs.path.join(allocator, &.{ target_root, ".agents", "skills" });
        defer allocator.free(skills_root_absolute);

        const imported = try workflow_skills.renderImportedWorkflowSkills(
            allocator,
            target_root,
            skills_root_absolute,
            ".agents/skills",
            "agy.skills",
            .agy,
        );
        defer workflow_skills.deinitRenderedAssets(allocator, imported);

        for (imported) |asset| {
            if (workflow_skills.skillAlreadyInstalled(asset.absolute_path)) continue;

            try assets.append(allocator, .{
                .resource_id = try allocator.dupe(u8, asset.resource_id),
                .resource_kind = asset.resource_kind,
                .relative_path = try allocator.dupe(u8, asset.relative_path),
                .absolute_path = if (asset.absolute_path) |absolute_path| try allocator.dupe(u8, absolute_path) else null,
                .ownership = asset.ownership,
                .label = try allocator.dupe(u8, asset.label),
                .file_mode = asset.file_mode,
                .content = try allocator.dupe(u8, asset.content),
            });
        }
    }

    return try assets.toOwnedSlice(allocator);
}

pub fn deinitRenderedAssets(allocator: std.mem.Allocator, assets: []const model.RenderedAsset) void {
    for (assets) |asset| {
        const is_dynamic_workflow_skill = std.mem.startsWith(u8, asset.resource_id, "agy.skills.workflow.");
        const is_owned_skill = isOwnedSkillResource(asset.resource_id);
        if (is_dynamic_workflow_skill or is_owned_skill) allocator.free(asset.resource_id);
        allocator.free(asset.relative_path);
        if (asset.absolute_path) |absolute_path| allocator.free(absolute_path);
        if (is_dynamic_workflow_skill or is_owned_skill) allocator.free(asset.label);
        allocator.free(asset.content);
    }
    allocator.free(assets);
}

pub fn resolveTargetRoot(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    workspace_root_opt: ?[]const u8,
) !?[]const u8 {
    return switch (scope) {
        .workspace => if (workspace_root_opt) |workspace_root| try allocator.dupe(u8, workspace_root) else null,
        .user => blk: {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |fallback_err| switch (fallback_err) {
                    error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
                    else => return fallback_err,
                },
                else => return err,
            };
            defer allocator.free(home);
            break :blk try allocator.dupe(u8, home);
        },
    };
}

pub fn renderManagedResource(
    allocator: std.mem.Allocator,
    resource_id: []const u8,
    scope: model.Scope,
    target_root: []const u8,
) !?[]u8 {
    if (std.mem.eql(u8, resource_id, "agy.hooks")) {
        return try renderHooksJson(allocator, scope, target_root);
    }
    if (std.mem.eql(u8, resource_id, "agy.mcp")) {
        return try allocator.dupe(u8, build_options.adapter_agy_runtime_mcp_config_json);
    }
    return null;
}

fn renderHooksJson(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
) ![]u8 {
    const pre_invocation_cmd_json = try commandJsonLiteral(allocator, scope, target_root, "pre-invocation.sh");
    defer allocator.free(pre_invocation_cmd_json);
    const stop_check_cmd_json = try commandJsonLiteral(allocator, scope, target_root, "stop-refer-check.sh");
    defer allocator.free(stop_check_cmd_json);

    var rendered = try allocator.dupe(u8, build_options.adapter_agy_runtime_hooks_json);
    errdefer allocator.free(rendered);

    rendered = try replaceOwned(allocator, rendered, "__CLUMSIES_PRE_INVOCATION_COMMAND_JSON__", pre_invocation_cmd_json);
    rendered = try replaceOwned(allocator, rendered, "__CLUMSIES_STOP_CHECK_COMMAND_JSON__", stop_check_cmd_json);
    return rendered;
}

fn scopedRelativePath(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    resource_key: []const u8,
) ![]u8 {
    return switch (scope) {
        .workspace => switchKeyToPath(allocator, ".agents", resource_key),
        .user => switchKeyToUserPath(allocator, resource_key),
    };
}

fn switchKeyToPath(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    resource_key: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, resource_key, "hooks")) {
        return std.fs.path.join(allocator, &.{ base_dir, "hooks.json" });
    }
    if (std.mem.eql(u8, resource_key, "mcp")) {
        return std.fs.path.join(allocator, &.{ base_dir, "mcp_config.json" });
    }
    return std.fs.path.join(allocator, &.{ base_dir, resource_key });
}

fn switchKeyToUserPath(
    allocator: std.mem.Allocator,
    resource_key: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, resource_key, "hooks")) {
        return std.fs.path.join(allocator, &.{ ".gemini", "config", "hooks.json" });
    }
    if (std.mem.eql(u8, resource_key, "mcp")) {
        return std.fs.path.join(allocator, &.{ ".gemini", "agy", "mcp_config.json" });
    }
    if (std.mem.startsWith(u8, resource_key, "skills/")) {
        return std.fs.path.join(allocator, &.{ ".gemini", "agy", resource_key });
    }
    if (std.mem.startsWith(u8, resource_key, "hooks/")) {
        return std.fs.path.join(allocator, &.{ ".gemini", "config", resource_key });
    }
    return std.fs.path.join(allocator, &.{ ".gemini", "agy", resource_key });
}

fn appendSkillAsset(
    allocator: std.mem.Allocator,
    assets: *std.ArrayList(model.RenderedAsset),
    scope: model.Scope,
    target_root: []const u8,
    slug: []const u8,
    label: []const u8,
    content: []const u8,
) !void {
    const resource_id = try std.fmt.allocPrint(allocator, "agy.skills.{s}", .{slug});
    errdefer allocator.free(resource_id);

    const resource_key = try std.fmt.allocPrint(allocator, "skills/{s}/SKILL.md", .{slug});
    defer allocator.free(resource_key);

    const relative_path = try scopedRelativePath(allocator, scope, resource_key);
    errdefer allocator.free(relative_path);

    var absolute_path_opt: ?[]u8 = null;
    errdefer if (absolute_path_opt) |absolute_path| allocator.free(absolute_path);

    if (scope == .workspace) {
        const absolute_path = try std.fs.path.join(allocator, &.{ target_root, relative_path });
        if (workflow_skills.skillAlreadyInstalled(absolute_path)) {
            allocator.free(absolute_path);
            allocator.free(relative_path);
            allocator.free(resource_id);
            return;
        }
        absolute_path_opt = absolute_path;
    }

    try assets.append(allocator, .{
        .resource_id = resource_id,
        .resource_kind = "plain_file",
        .relative_path = relative_path,
        .absolute_path = absolute_path_opt,
        .ownership = "exclusive",
        .label = try allocator.dupe(u8, label),
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, content),
    });
}

fn isOwnedSkillResource(resource_id: []const u8) bool {
    return std.mem.eql(u8, resource_id, "agy.skills.discover") or
        std.mem.eql(u8, resource_id, "agy.skills.ntmd") or
        std.mem.eql(u8, resource_id, "agy.skills.setup");
}

fn commandJsonLiteral(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
    script_name: []const u8,
) ![]u8 {
    const script_path = switch (scope) {
        .workspace => try std.fs.path.join(allocator, &.{ target_root, ".agents", "hooks", script_name }),
        .user => try std.fs.path.join(allocator, &.{ target_root, ".gemini", "config", "hooks", script_name }),
    };
    defer allocator.free(script_path);

    const command = try std.fmt.allocPrint(allocator, "bash \"{s}\"", .{script_path});
    defer allocator.free(command);

    return std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = command },
        .{},
    );
}

fn renderNotes(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
) !?[]const []const u8 {
    if (scope != .workspace) return null;

    const skills_root_absolute = try std.fs.path.join(allocator, &.{ target_root, ".agents", "skills" });
    defer allocator.free(skills_root_absolute);

    var skipped: usize = 0;
    var total: usize = 0;

    const imported = try workflow_skills.renderImportedWorkflowSkills(
        allocator,
        target_root,
        skills_root_absolute,
        ".agents/skills",
        "agy.skills",
        .agy,
    );
    defer workflow_skills.deinitRenderedAssets(allocator, imported);

    for (imported) |asset| {
        total += 1;
        if (workflow_skills.skillAlreadyInstalled(asset.absolute_path)) {
            skipped += 1;
        }
    }

    if (skipped == 0) return null;

    const note = try std.fmt.allocPrint(allocator, "{d}/{d} workflow skills skipped (already installed in .agents/skills/ by another adapter)", .{ skipped, total });
    errdefer allocator.free(note);
    var notes = try allocator.alloc([]const u8, 1);
    notes[0] = note;
    return notes;
}

fn replaceOwned(
    allocator: std.mem.Allocator,
    original: []u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const replaced = try std.mem.replaceOwned(u8, allocator, original, needle, replacement);
    allocator.free(original);
    return replaced;
}

test "renderRuntimeAssets uses workspace-local Antigravity hook paths" {
    const allocator = std.testing.allocator;
    const assets = try renderRuntimeAssets(allocator, .workspace, "/tmp/workspace");
    defer deinitRenderedAssets(allocator, assets);

    try std.testing.expect(std.mem.indexOf(u8, assets[0].content, "/tmp/workspace/.agents/hooks/pre-invocation.sh") != null);
}

test "renderRuntimeAssets injects memsetup instructions from Antigravity conversationId" {
    const allocator = std.testing.allocator;
    const assets = try renderRuntimeAssets(allocator, .workspace, "/tmp/workspace");
    defer deinitRenderedAssets(allocator, assets);

    var found_pre_invocation = false;
    var found_stop_check = false;
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.resource_id, "agy.hooks.pre_invocation")) {
            found_pre_invocation = true;
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "conversationId") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "invocationNum") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "transcriptPath") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "attestation-append --type user_prompt") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "memsetup") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "session_id") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "_agent setup") == null);
        } else if (std.mem.eql(u8, asset.resource_id, "agy.hooks.stop_check")) {
            found_stop_check = true;
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "conversationId") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "transcriptPath") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "CLUMSIES_HOST_SESSION_ID") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "memsetup") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "agentreport") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "attestation-append --type agent_report") != null);
        }
    }
    try std.testing.expect(found_pre_invocation);
    try std.testing.expect(found_stop_check);
}
