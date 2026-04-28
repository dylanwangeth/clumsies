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
    .user_scope_description = "All Codex sessions on this machine (~/.codex + ~/.agents/skills)",
    .remove_workspace_scope_description = "Current workspace install (.codex)",
    .remove_user_scope_description = "Machine-wide install (~/.codex + ~/.agents/skills)",
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
    if (scope == .user) {
        const skills_root_absolute = try codexSkillsRootAbsolute(allocator, target_root);
        defer allocator.free(skills_root_absolute);

        try appendCodexSkill(
            allocator,
            &assets,
            "codex.skills.discover",
            "discover",
            "Codex discover skill",
            skills_root_absolute,
            build_options.adapter_codex_runtime_skill_discover,
        );
        try appendCodexSkill(
            allocator,
            &assets,
            "codex.skills.ntmd",
            "ntmd",
            "Codex ntmd skill",
            skills_root_absolute,
            build_options.adapter_codex_runtime_skill_ntmd,
        );
        try appendCodexSkill(
            allocator,
            &assets,
            "codex.skills.setup",
            "setup",
            "Codex setup skill",
            skills_root_absolute,
            build_options.adapter_codex_runtime_skill_setup,
        );
    }

    if (scope == .workspace) {
        const workspace_root = workspaceRootFromAdapterRoot(target_root);
        const workflow_skills_root_absolute = try std.fs.path.join(allocator, &.{ workspace_root, ".agents", "skills" });
        defer allocator.free(workflow_skills_root_absolute);

        const imported = try workflow_skills.renderImportedWorkflowSkills(
            allocator,
            workspace_root,
            workflow_skills_root_absolute,
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

fn appendCodexSkill(
    allocator: std.mem.Allocator,
    assets: *std.ArrayList(model.RenderedAsset),
    resource_id: []const u8,
    slug: []const u8,
    label: []const u8,
    skills_root_absolute: []const u8,
    content: []const u8,
) !void {
    try assets.append(allocator, .{
        .resource_id = resource_id,
        .resource_kind = "plain_file",
        .relative_path = try std.fs.path.join(allocator, &.{ ".agents", "skills", slug, "SKILL.md" }),
        .absolute_path = try std.fs.path.join(allocator, &.{ skills_root_absolute, slug, "SKILL.md" }),
        .ownership = "exclusive",
        .label = label,
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, content),
    });
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
    _: model.Scope,
    _: []const u8,
) ![]u8 {
    return allocator.dupe(u8, build_options.adapter_codex_runtime_session_start_sh);
}

fn workspaceRootFromAdapterRoot(target_root: []const u8) []const u8 {
    return std.fs.path.dirname(target_root) orelse target_root;
}

fn codexSkillsRootAbsolute(
    allocator: std.mem.Allocator,
    target_root: []const u8,
) ![]u8 {
    const owner_root = workspaceRootFromAdapterRoot(target_root);
    return std.fs.path.join(allocator, &.{ owner_root, ".agents", "skills" });
}

fn renderNotes(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
) !?[]const []const u8 {
    var notes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (notes.items) |note| allocator.free(note);
        notes.deinit(allocator);
    }

    try notes.append(allocator, try allocator.dupe(u8, "Restart Codex to reload hooks and discover newly installed skills."));

    try notes.append(allocator, switch (scope) {
        .workspace => try allocator.dupe(u8, "Codex workflow skills are installed under this workspace's .agents/skills directory."),
        .user => try allocator.dupe(u8, "Codex user skills are installed under ~/.agents/skills."),
    });

    _ = target_root;
    return try notes.toOwnedSlice(allocator);
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

test "codex config does not require Codex thread id in MCP server env" {
    const allocator = std.testing.allocator;
    const rendered = (try renderManagedResource(allocator, "codex.config", .workspace, "/tmp/workspace/.codex")).?;
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "env_vars") == null);
}

test "codex hooks pass Codex session id through clumsies host session env" {
    const allocator = std.testing.allocator;
    const assets = try renderRuntimeAssets(allocator, .workspace, "/tmp/workspace/.codex");
    defer deinitRenderedAssets(allocator, assets);

    var found_user_prompt = false;
    var found_stop_check = false;
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.resource_id, "codex.hooks.user_prompt_submit")) {
            found_user_prompt = true;
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "session_id") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "CLUMSIES_HOST_SESSION_ID") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "turn_id") == null);
        } else if (std.mem.eql(u8, asset.resource_id, "codex.hooks.stop_check")) {
            found_stop_check = true;
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "session_id") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "CLUMSIES_HOST_SESSION_ID") != null);
            try std.testing.expect(std.mem.indexOf(u8, asset.content, "turn_id") == null);
        }
    }
    try std.testing.expect(found_user_prompt);
    try std.testing.expect(found_stop_check);
}

test "renderSessionStartHook does not import workflow skills" {
    const allocator = std.testing.allocator;
    const rendered = try renderSessionStartHook(allocator, .workspace, "/Users/test/project/.codex");
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "__CLUMSIES_WORKFLOW_SKILLS_DIR__") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "WORKFLOW_SKILLS_DIR") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "_agent setup") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "hookSpecificOutput") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "memory.setup") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "session_id") != null);
}

test "renderRuntimeAssets installs codex user skills under home agents skills" {
    const allocator = std.testing.allocator;
    const assets = try renderRuntimeAssets(allocator, .user, "/Users/test/.codex");
    defer deinitRenderedAssets(allocator, assets);

    var found = false;
    for (assets) |asset| {
        if (!std.mem.eql(u8, asset.resource_id, "codex.skills.discover")) continue;
        found = true;
        try std.testing.expectEqualStrings(".agents/skills/discover/SKILL.md", asset.relative_path);
        try std.testing.expect(asset.absolute_path != null);
        try std.testing.expectEqualStrings("/Users/test/.agents/skills/discover/SKILL.md", asset.absolute_path.?);
    }
    try std.testing.expect(found);
}

test "renderRuntimeAssets does not install codex core skills in workspace scope" {
    const allocator = std.testing.allocator;
    const assets = try renderRuntimeAssets(allocator, .workspace, "/Users/test/project/.codex");
    defer deinitRenderedAssets(allocator, assets);

    for (assets) |asset| {
        try std.testing.expect(!std.mem.eql(u8, asset.resource_id, "codex.skills.discover"));
        try std.testing.expect(!std.mem.eql(u8, asset.resource_id, "codex.skills.ntmd"));
        try std.testing.expect(!std.mem.eql(u8, asset.resource_id, "codex.skills.setup"));
    }
}
