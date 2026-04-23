const build_options = @import("build_options");
const model = @import("../model.zig");
const std = @import("std");
const types = @import("types.zig");
const workflow_skills = @import("../workflow_skills.zig");

pub const package: types.AdapterPackage = .{
    .id = "codex",
    .display_name = "Codex",
    .choice_description = "OpenAI Codex CLI adapter",
    .workspace_scope_description = "Only this workspace (.codex + .agents/skills)",
    .user_scope_description = "All Codex sessions on this machine (~/.codex)",
    .remove_workspace_scope_description = "Current workspace install (.codex)",
    .remove_user_scope_description = "Machine-wide install (~/.codex)",
    .resolve_target_root_fn = resolveTargetRoot,
    .render_runtime_assets_fn = renderRuntimeAssets,
    .deinit_rendered_assets_fn = deinitRenderedAssets,
    .render_managed_resource_fn = renderManagedResource,
};

pub fn renderRuntimeAssets(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
) ![]model.RenderedAsset {
    var assets: std.ArrayList(model.RenderedAsset) = .empty;
    errdefer deinitRenderedAssets(allocator, assets.items);

    try assets.append(allocator, .{
        .resource_id = "codex.config",
        .resource_kind = "toml_fragment",
        .relative_path = try scopedRelativePath(allocator, "config.toml"),
        .ownership = "shared",
        .label = "Codex config",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_codex_runtime_config_toml),
    });
    try assets.append(allocator, .{
        .resource_id = "codex.hooks.registry",
        .resource_kind = "json_hooks_registry",
        .relative_path = try scopedRelativePath(allocator, "hooks.json"),
        .ownership = "shared",
        .label = "Codex hooks registry",
        .file_mode = 0o644,
        .content = try renderHooksRegistry(allocator, target_root),
    });
    try assets.append(allocator, .{
        .resource_id = "codex.hooks.resolve_binary",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "hooks/resolve-binary.sh"),
        .ownership = "exclusive",
        .label = "Codex hook helper",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_codex_runtime_resolve_binary_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "codex.hooks.session_start",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "hooks/session-start.sh"),
        .ownership = "exclusive",
        .label = "Codex SessionStart hook",
        .file_mode = 0o755,
        .content = try renderSessionStartHook(allocator, scope, target_root),
    });
    try assets.append(allocator, .{
        .resource_id = "codex.hooks.user_prompt_submit",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "hooks/user-prompt-submit.sh"),
        .ownership = "exclusive",
        .label = "Codex UserPromptSubmit hook",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_codex_runtime_user_prompt_submit_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "codex.hooks.stop_check",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "hooks/stop-refer-check.sh"),
        .ownership = "exclusive",
        .label = "Codex Stop hook",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_codex_runtime_stop_refer_check_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "codex.skills.discover",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "skills/discover/SKILL.md"),
        .ownership = "exclusive",
        .label = "Codex discover skill",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_codex_runtime_skill_discover),
    });
    try assets.append(allocator, .{
        .resource_id = "codex.skills.ntmd",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "skills/ntmd/SKILL.md"),
        .ownership = "exclusive",
        .label = "Codex ntmd skill",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_codex_runtime_skill_ntmd),
    });
    try assets.append(allocator, .{
        .resource_id = "codex.skills.setup",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "skills/setup/SKILL.md"),
        .ownership = "exclusive",
        .label = "Codex setup skill",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_codex_runtime_skill_setup),
    });

    if (scope == .workspace) {
        const workspace_root = workspaceRootFromAdapterRoot(target_root);
        const skills_root_absolute = try std.fs.path.join(allocator, &.{ workspace_root, ".agents", "skills" });
        defer allocator.free(skills_root_absolute);

        const imported = try workflow_skills.renderImportedWorkflowSkills(
            allocator,
            workspace_root,
            skills_root_absolute,
            ".agents/skills",
            "codex.skills",
            .codex,
        );
        defer workflow_skills.deinitRenderedAssets(allocator, imported);

        for (imported) |asset| {
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
        const is_dynamic_workflow_skill = std.mem.startsWith(u8, asset.resource_id, "codex.skills.workflow.");
        if (is_dynamic_workflow_skill) allocator.free(asset.resource_id);
        allocator.free(asset.relative_path);
        if (asset.absolute_path) |absolute_path| allocator.free(absolute_path);
        if (is_dynamic_workflow_skill) allocator.free(asset.label);
        allocator.free(asset.content);
    }
    allocator.free(assets);
}

pub fn renderHooksRegistry(
    allocator: std.mem.Allocator,
    target_root: []const u8,
) ![]u8 {
    const session_start_cmd_json = try commandJsonLiteral(allocator, target_root, "session-start.sh");
    defer allocator.free(session_start_cmd_json);
    const user_prompt_submit_cmd_json = try commandJsonLiteral(allocator, target_root, "user-prompt-submit.sh");
    defer allocator.free(user_prompt_submit_cmd_json);
    const stop_check_cmd_json = try commandJsonLiteral(allocator, target_root, "stop-refer-check.sh");
    defer allocator.free(stop_check_cmd_json);

    var rendered = try allocator.dupe(u8, build_options.adapter_codex_runtime_hooks_json);
    errdefer allocator.free(rendered);

    rendered = try replaceOwned(
        allocator,
        rendered,
        "__CLUMSIES_SESSION_START_COMMAND_JSON__",
        session_start_cmd_json,
    );
    rendered = try replaceOwned(
        allocator,
        rendered,
        "__CLUMSIES_USER_PROMPT_SUBMIT_COMMAND_JSON__",
        user_prompt_submit_cmd_json,
    );
    rendered = try replaceOwned(
        allocator,
        rendered,
        "__CLUMSIES_STOP_CHECK_COMMAND_JSON__",
        stop_check_cmd_json,
    );
    return rendered;
}

pub fn resolveTargetRoot(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    workspace_root_opt: ?[]const u8,
) !?[]const u8 {
    return switch (scope) {
        .workspace => blk: {
            const workspace_root = workspace_root_opt orelse break :blk null;
            break :blk try std.fs.path.join(allocator, &.{ workspace_root, ".codex" });
        },
        .user => try userCodexRoot(allocator),
    };
}

pub fn renderManagedResource(
    allocator: std.mem.Allocator,
    resource_id: []const u8,
    scope: model.Scope,
    target_root: []const u8,
) !?[]u8 {
    _ = scope;
    if (std.mem.eql(u8, resource_id, "codex.hooks.registry")) {
        return try renderHooksRegistry(allocator, target_root);
    }
    if (std.mem.eql(u8, resource_id, "codex.config")) {
        return try allocator.dupe(u8, build_options.adapter_codex_runtime_config_toml);
    }
    return null;
}

fn scopedRelativePath(
    allocator: std.mem.Allocator,
    tail: []const u8,
) ![]u8 {
    return allocator.dupe(u8, tail);
}

fn userCodexRoot(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |fallback_err| switch (fallback_err) {
            error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
            else => return fallback_err,
        },
        else => return err,
    };
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".codex" });
}

fn commandJsonLiteral(
    allocator: std.mem.Allocator,
    target_root: []const u8,
    script_name: []const u8,
) ![]u8 {
    const script_path = try std.fs.path.join(allocator, &.{ target_root, "hooks", script_name });
    defer allocator.free(script_path);

    const command = try std.fmt.allocPrint(allocator, "bash \"{s}\"", .{script_path});
    defer allocator.free(command);

    return std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = command },
        .{},
    );
}

fn renderSessionStartHook(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
) ![]u8 {
    var rendered = try allocator.dupe(u8, build_options.adapter_codex_runtime_session_start_sh);
    errdefer allocator.free(rendered);

    const workflow_skills_dir = switch (scope) {
        .workspace => blk: {
            const workspace_root = workspaceRootFromAdapterRoot(target_root);
            break :blk try std.fs.path.join(allocator, &.{ workspace_root, ".agents", "skills" });
        },
        .user => try allocator.dupe(u8, ""),
    };
    defer allocator.free(workflow_skills_dir);

    rendered = try replaceOwned(
        allocator,
        rendered,
        "__CLUMSIES_WORKFLOW_SKILLS_DIR__",
        workflow_skills_dir,
    );
    return rendered;
}

fn workspaceRootFromAdapterRoot(target_root: []const u8) []const u8 {
    return std.fs.path.dirname(target_root) orelse target_root;
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

test "renderRuntimeAssets uses absolute workspace-local codex hook paths" {
    const allocator = std.testing.allocator;
    const assets = try renderRuntimeAssets(allocator, .workspace, "/tmp/workspace/.codex");
    defer deinitRenderedAssets(allocator, assets);

    try std.testing.expect(std.mem.indexOf(u8, assets[1].content, "/tmp/workspace/.codex/hooks/session-start.sh") != null);
}

test "renderSessionStartHook disables workflow import for user scope" {
    const allocator = std.testing.allocator;
    const rendered = try renderSessionStartHook(allocator, .user, "/Users/test/.codex");
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "__CLUMSIES_WORKFLOW_SKILLS_DIR__") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "WORKFLOW_SKILLS_DIR=\"\"") != null);
}
