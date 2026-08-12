const build_options = @import("build_options");
const model = @import("../model.zig");
const std = @import("std");
const types = @import("types.zig");
const env_util = @import("clumsies_lib").util.env_util;
const workflow_skills = @import("../workflow_skills.zig");

pub const package: types.AdapterPackage = .{
    .id = "claude-code",
    .display_name = "Claude Code",
    .choice_description = "Claude Code standalone adapter",
    .workspace_scope_description = "Only this workspace (.claude + .mcp.json)",
    .user_scope_description = "All Claude Code sessions on this machine (~/.claude)",
    .remove_workspace_scope_description = "Current workspace install (.claude + .mcp.json)",
    .remove_user_scope_description = "Machine-wide install (~/.claude)",
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
        .resource_id = "claude-code.settings",
        .resource_kind = "json_hooks_registry",
        .relative_path = try scopedRelativePath(allocator, scope, "settings"),
        .ownership = "shared",
        .label = "Claude Code settings hooks",
        .file_mode = 0o644,
        .content = try renderSettingsJson(allocator, scope, target_root),
    });
    try assets.append(allocator, .{
        .resource_id = "claude-code.mcp",
        .resource_kind = "json_mcp_registry",
        .relative_path = try scopedRelativePath(allocator, scope, "mcp"),
        .ownership = "shared",
        .label = "Claude Code MCP registry",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_claude_code_runtime_mcp_json),
    });
    try assets.append(allocator, .{
        .resource_id = "claude-code.hooks.resolve_binary",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, scope, "hooks/resolve-binary.sh"),
        .ownership = "exclusive",
        .label = "Claude Code hook helper",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_claude_code_runtime_resolve_binary_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "claude-code.hooks.session_start",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, scope, "hooks/session-start.sh"),
        .ownership = "exclusive",
        .label = "Claude Code SessionStart hook",
        .file_mode = 0o755,
        .content = try renderSessionStartHook(allocator, scope, target_root),
    });
    try assets.append(allocator, .{
        .resource_id = "claude-code.hooks.issue_run_event",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, scope, "hooks/issue-run-event.sh"),
        .ownership = "exclusive",
        .label = "Claude Code Issue run lifecycle hook",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_claude_code_runtime_issue_run_event_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "claude-code.skills.activate",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, scope, "skills/activate/SKILL.md"),
        .ownership = "exclusive",
        .label = "Claude Code activate skill",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_claude_code_runtime_skill_activate),
    });
    try assets.append(allocator, .{
        .resource_id = "claude-code.skills.ntmd",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, scope, "skills/ntmd/SKILL.md"),
        .ownership = "exclusive",
        .label = "Claude Code ntmd skill",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_claude_code_runtime_skill_ntmd),
    });

    if (scope == .workspace) {
        const skills_root_absolute = try std.fs.path.join(allocator, &.{ target_root, ".claude", "skills" });
        defer allocator.free(skills_root_absolute);

        const imported = try workflow_skills.renderImportedWorkflowSkills(
            allocator,
            target_root,
            skills_root_absolute,
            ".claude/skills",
            "claude-code.skills",
            .claude_code,
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
        const is_dynamic_workflow_skill = std.mem.startsWith(u8, asset.resource_id, "claude-code.skills.workflow.");
        if (is_dynamic_workflow_skill) allocator.free(asset.resource_id);
        allocator.free(asset.relative_path);
        if (asset.absolute_path) |absolute_path| allocator.free(absolute_path);
        if (is_dynamic_workflow_skill) allocator.free(asset.label);
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
            break :blk try env_util.homeDir(allocator);
        },
    };
}

pub fn renderManagedResource(
    allocator: std.mem.Allocator,
    resource_id: []const u8,
    scope: model.Scope,
    target_root: []const u8,
) !?[]u8 {
    if (std.mem.eql(u8, resource_id, "claude-code.settings")) {
        return try renderSettingsJson(allocator, scope, target_root);
    }
    if (std.mem.eql(u8, resource_id, "claude-code.mcp")) {
        return try allocator.dupe(u8, build_options.adapter_claude_code_runtime_mcp_json);
    }
    return null;
}

fn renderSettingsJson(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
) ![]u8 {
    const session_start_cmd_json = try commandJsonLiteral(allocator, scope, target_root, "session-start.sh");
    defer allocator.free(session_start_cmd_json);
    const issue_run_event_cmd_json = try commandJsonLiteral(allocator, scope, target_root, "issue-run-event.sh");
    defer allocator.free(issue_run_event_cmd_json);

    var rendered = try allocator.dupe(u8, build_options.adapter_claude_code_runtime_settings_json);
    errdefer allocator.free(rendered);

    rendered = try replaceOwned(allocator, rendered, "__CLUMSIES_SESSION_START_COMMAND_JSON__", session_start_cmd_json);
    rendered = try replaceOwned(allocator, rendered, "__CLUMSIES_ISSUE_RUN_EVENT_COMMAND_JSON__", issue_run_event_cmd_json);
    return rendered;
}

fn renderSessionStartHook(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
) ![]u8 {
    var rendered = try allocator.dupe(u8, build_options.adapter_claude_code_runtime_session_start_sh);
    errdefer allocator.free(rendered);

    const workflow_skills_dir = switch (scope) {
        .workspace => try std.fs.path.join(allocator, &.{ target_root, ".claude", "skills" }),
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

fn scopedRelativePath(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    resource_key: []const u8,
) ![]u8 {
    return switch (scope) {
        .workspace => switchKeyToPath(allocator, ".claude", resource_key),
        .user => if (std.mem.eql(u8, resource_key, "mcp"))
            allocator.dupe(u8, ".claude.json")
        else
            switchKeyToPath(allocator, ".claude", resource_key),
    };
}

fn switchKeyToPath(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    resource_key: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, resource_key, "settings")) {
        return std.fs.path.join(allocator, &.{ base_dir, "settings.json" });
    }
    if (std.mem.eql(u8, resource_key, "mcp")) {
        return allocator.dupe(u8, ".mcp.json");
    }
    return std.fs.path.join(allocator, &.{ base_dir, resource_key });
}

fn commandJsonLiteral(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
    script_name: []const u8,
) ![]u8 {
    const script_path = switch (scope) {
        .workspace => try std.fs.path.join(allocator, &.{ target_root, ".claude", "hooks", script_name }),
        .user => try std.fs.path.join(allocator, &.{ target_root, ".claude", "hooks", script_name }),
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

test "renderRuntimeAssets uses workspace-local Claude Code hook paths" {
    const allocator = std.testing.allocator;
    const assets = try renderRuntimeAssets(allocator, .workspace, "/tmp/workspace");
    defer deinitRenderedAssets(allocator, assets);

    try std.testing.expect(std.mem.indexOf(u8, assets[0].content, "/tmp/workspace/.claude/hooks/session-start.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, assets[0].content, "/tmp/workspace/.claude/hooks/issue-run-event.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, assets[0].content, "user-prompt-submit.sh") == null);
}

test "Claude lifecycle hook covers failure and remains fail open" {
    const allocator = std.testing.allocator;
    const assets = try renderRuntimeAssets(allocator, .workspace, "/tmp/workspace");
    defer deinitRenderedAssets(allocator, assets);

    var found_lifecycle = false;
    for (assets) |asset| {
        try std.testing.expect(!std.mem.eql(u8, asset.resource_id, "claude-code.hooks.user_prompt_submit"));
        if (!std.mem.eql(u8, asset.resource_id, "claude-code.hooks.issue_run_event")) continue;
        found_lifecycle = true;
        try std.testing.expect(std.mem.indexOf(u8, asset.content, "_agent issue-run-event --host claude-code") != null);
        try std.testing.expect(std.mem.indexOf(u8, asset.content, "|| true") != null);
        try std.testing.expect(std.mem.indexOf(u8, asset.content, "jq") == null);
    }
    try std.testing.expect(found_lifecycle);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, assets[0].content, .{});
    defer parsed.deinit();
    const hooks = parsed.value.object.get("hooks").?.object;
    for ([_][]const u8{ "UserPromptSubmit", "Stop", "SubagentStart", "SubagentStop", "SessionEnd", "StopFailure" }) |event| {
        const groups = hooks.get(event).?.array.items;
        try std.testing.expectEqual(@as(usize, 1), groups.len);
        const handlers = groups[0].object.get("hooks").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), handlers.len);
        try std.testing.expect(std.mem.indexOf(u8, handlers[0].object.get("command").?.string, "issue-run-event.sh") != null);
    }
}

test "Claude resolver prefers an executable desktop-managed helper" {
    const allocator = std.testing.allocator;
    const assets = try renderRuntimeAssets(allocator, .workspace, "/tmp/workspace");
    defer deinitRenderedAssets(allocator, assets);

    try std.testing.expect(std.mem.indexOf(u8, assets[2].content, "CLUMSIES_ADAPTER_BINARY") != null);
    try std.testing.expect(std.mem.indexOf(u8, assets[2].content, "[ -x \"$CLUMSIES_ADAPTER_BINARY\" ]") != null);
}

test "renderSessionStartHook disables workflow import for user scope" {
    const allocator = std.testing.allocator;
    const rendered = try renderSessionStartHook(allocator, .user, "/Users/test");
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "WORKFLOW_SKILLS_DIR=\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "_agent setup") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "META_PROMPT") == null);
}

test "renderSessionStartHook generates workflow proxies for the load contract" {
    const allocator = std.testing.allocator;
    const rendered = try renderSessionStartHook(allocator, .workspace, "/tmp/workspace");
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "WORKFLOW_SKILLS_DIR=\"/tmp/workspace/.claude/skills\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Call the \\`load\\` MCP tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ids: [\"workflow/$filename\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "retrieve") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "_agent setup") == null);
    // Workflow rules are synced under the rule namespace; the hook must scan
    // cache/rule/workflow, not the dead cache/workflow path.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "CACHE_DIR/rule/workflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"$CACHE_DIR/workflow\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "CACHE_DIR/workflow\"") == null);
}
