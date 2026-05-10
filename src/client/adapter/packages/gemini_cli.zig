//! Gemini CLI adapter. Handles the unified settings.json (hooks + MCP in one file),
//! JSON stdin/stdout hook protocol, and TOML-based custom slash commands.
const build_options = @import("build_options");
const model = @import("../model.zig");
const std = @import("std");
const types = @import("types.zig");
const workflow_skills = @import("../workflow_skills.zig");

pub const package: types.AdapterPackage = .{
    .id = "gemini-cli",
    .display_name = "Gemini CLI",
    .choice_description = "Google Gemini CLI adapter",
    .workspace_scope_description = "Only this workspace (.gemini)",
    .user_scope_description = "All Gemini CLI sessions on this machine (~/.gemini)",
    .remove_workspace_scope_description = "Current workspace install (.gemini)",
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
        .resource_id = "gemini-cli.settings",
        .resource_kind = "json_hooks_registry",
        .relative_path = try scopedRelativePath(allocator, "settings"),
        .ownership = "shared",
        .label = "Gemini CLI settings (hooks + MCP)",
        .file_mode = 0o644,
        .content = try renderSettingsJson(allocator, scope, target_root),
    });
    try assets.append(allocator, .{
        .resource_id = "gemini-cli.hooks.resolve_binary",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "hooks/resolve-binary.sh"),
        .ownership = "exclusive",
        .label = "Gemini CLI hook helper",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_gemini_cli_runtime_resolve_binary_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "gemini-cli.hooks.session_start",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "hooks/session-start.sh"),
        .ownership = "exclusive",
        .label = "Gemini CLI SessionStart hook",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_gemini_cli_runtime_session_start_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "gemini-cli.hooks.user_prompt_submit",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "hooks/user-prompt-submit.sh"),
        .ownership = "exclusive",
        .label = "Gemini CLI BeforeAgent hook",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_gemini_cli_runtime_user_prompt_submit_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "gemini-cli.hooks.stop_check",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "hooks/stop-refer-check.sh"),
        .ownership = "exclusive",
        .label = "Gemini CLI AfterAgent hook",
        .file_mode = 0o755,
        .content = try allocator.dupe(u8, build_options.adapter_gemini_cli_runtime_stop_refer_check_sh),
    });
    try assets.append(allocator, .{
        .resource_id = "gemini-cli.skills.discover",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "commands/discover.toml"),
        .ownership = "exclusive",
        .label = "Gemini CLI discover command",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_gemini_cli_runtime_skill_discover),
    });
    try assets.append(allocator, .{
        .resource_id = "gemini-cli.skills.clumsies_error_prone",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "commands/clumsies-error-prone.toml"),
        .ownership = "exclusive",
        .label = "Gemini CLI clumsies-error-prone command",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_gemini_cli_runtime_skill_clumsies_error_prone),
    });
    try assets.append(allocator, .{
        .resource_id = "gemini-cli.skills.ntmd",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "commands/ntmd.toml"),
        .ownership = "exclusive",
        .label = "Gemini CLI ntmd command",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_gemini_cli_runtime_skill_ntmd),
    });
    try assets.append(allocator, .{
        .resource_id = "gemini-cli.skills.setup",
        .resource_kind = "plain_file",
        .relative_path = try scopedRelativePath(allocator, "commands/setup.toml"),
        .ownership = "exclusive",
        .label = "Gemini CLI setup command",
        .file_mode = 0o644,
        .content = try allocator.dupe(u8, build_options.adapter_gemini_cli_runtime_skill_setup),
    });

    if (scope == .workspace) {
        const agents_skills_root = try std.fs.path.join(allocator, &.{ target_root, ".agents", "skills" });
        defer allocator.free(agents_skills_root);

        const imported = try workflow_skills.renderImportedWorkflowSkills(
            allocator,
            target_root,
            agents_skills_root,
            ".agents/skills",
            "gemini-cli.skills",
            .gemini_cli,
        );
        defer workflow_skills.deinitRenderedAssets(allocator, imported);

        for (imported) |asset| {
            if (skillAlreadyInstalled(asset.absolute_path)) continue;

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
        const is_dynamic_workflow_skill = std.mem.startsWith(u8, asset.resource_id, "gemini-cli.skills.workflow.");
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
) !?[]u8 {
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
    if (std.mem.eql(u8, resource_id, "gemini-cli.settings")) {
        return try renderSettingsJson(allocator, scope, target_root);
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
    const user_prompt_submit_cmd_json = try commandJsonLiteral(allocator, scope, target_root, "user-prompt-submit.sh");
    defer allocator.free(user_prompt_submit_cmd_json);
    const stop_check_cmd_json = try commandJsonLiteral(allocator, scope, target_root, "stop-refer-check.sh");
    defer allocator.free(stop_check_cmd_json);

    var rendered = try allocator.dupe(u8, build_options.adapter_gemini_cli_runtime_settings_json);
    errdefer allocator.free(rendered);

    rendered = try replaceOwned(allocator, rendered, "__CLUMSIES_SESSION_START_COMMAND_JSON__", session_start_cmd_json);
    rendered = try replaceOwned(allocator, rendered, "__CLUMSIES_USER_PROMPT_SUBMIT_COMMAND_JSON__", user_prompt_submit_cmd_json);
    rendered = try replaceOwned(allocator, rendered, "__CLUMSIES_STOP_CHECK_COMMAND_JSON__", stop_check_cmd_json);
    return rendered;
}

fn scopedRelativePath(
    allocator: std.mem.Allocator,
    resource_key: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, resource_key, "settings")) {
        return std.fs.path.join(allocator, &.{ ".gemini", "settings.json" });
    }
    return std.fs.path.join(allocator, &.{ ".gemini", resource_key });
}

fn commandJsonLiteral(
    allocator: std.mem.Allocator,
    scope: model.Scope,
    target_root: []const u8,
    script_name: []const u8,
) ![]u8 {
    _ = scope;
    const script_path = try std.fs.path.join(allocator, &.{ target_root, ".gemini", "hooks", script_name });
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

    const agents_skills_root = try std.fs.path.join(allocator, &.{ target_root, ".agents", "skills" });
    defer allocator.free(agents_skills_root);

    var skipped: usize = 0;
    var total: usize = 0;

    const imported = try workflow_skills.renderImportedWorkflowSkills(
        allocator,
        target_root,
        agents_skills_root,
        ".agents/skills",
        "gemini-cli.skills",
        .gemini_cli,
    );
    defer workflow_skills.deinitRenderedAssets(allocator, imported);

    for (imported) |asset| {
        total += 1;
        if (skillAlreadyInstalled(asset.absolute_path)) {
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

fn skillAlreadyInstalled(absolute_path: ?[]const u8) bool {
    const path = absolute_path orelse return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
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

test "renderRuntimeAssets uses workspace-local Gemini CLI hook paths" {
    const allocator = std.testing.allocator;
    const assets = try renderRuntimeAssets(allocator, .workspace, "/tmp/workspace");
    defer deinitRenderedAssets(allocator, assets);

    try std.testing.expect(std.mem.indexOf(u8, assets[0].content, "/tmp/workspace/.gemini/hooks/session-start.sh") != null);
}
