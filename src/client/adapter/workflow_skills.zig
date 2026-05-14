//! Workflow skill import. Scans the workspace's cached workflow rules and generates SKILL.md
//! files that agent hooks can invoke as slash commands (e.g., /commit, /review-pr).
const model = @import("model.zig");
const rule = @import("../rule.zig");
const std = @import("std");
const workspace_config = @import("../workspace_config.zig");

pub const Host = enum {
    codex,
    claude_code,
    gemini_cli,
};

pub fn renderImportedWorkflowSkills(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    skill_root_absolute: []const u8,
    skill_root_display: []const u8,
    resource_prefix: []const u8,
    host: Host,
) ![]model.RenderedAsset {
    const binding = workspace_config.resolveWorkspace(allocator, workspace_root) catch return allocator.alloc(model.RenderedAsset, 0);
    defer allocator.free(binding.ws_id);
    defer allocator.free(binding.name);

    const ws_dir = try workspace_config.getWsDir(allocator, binding.ws_id);
    defer allocator.free(ws_dir);

    var manifest = try rule.loadManifest(allocator, ws_dir);
    defer manifest.deinit(allocator);

    var assets: std.ArrayList(model.RenderedAsset) = .empty;
    errdefer deinitRenderedAssets(allocator, assets.items);

    var slug_counts: std.StringHashMap(usize) = .init(allocator);
    defer {
        var it = slug_counts.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        slug_counts.deinit();
    }

    var it = manifest.rules.iterator();
    while (it.next()) |entry| {
        const workflow_path = entry.value_ptr.path;
        if (!std.mem.startsWith(u8, workflow_path, "workflow/")) continue;
        if (!std.mem.endsWith(u8, workflow_path, ".md")) continue;

        const filename = std.fs.path.basename(workflow_path);
        const workflow_name = workflowNameFromFilename(filename);

        const base_slug = try workflowSlugFromFilename(allocator, filename);
        defer allocator.free(base_slug);
        const slug = try uniqueSlug(allocator, &slug_counts, base_slug);
        defer allocator.free(slug);

        const skill_content = try renderSkillContent(allocator, host, slug, filename, workflow_name);
        const relative_path = try skillFilePath(allocator, host, skill_root_display, slug);
        const absolute_path = try skillFilePath(allocator, host, skill_root_absolute, slug);
        const resource_id = try std.fmt.allocPrint(allocator, "{s}.workflow.{s}", .{ resource_prefix, slug });
        const label = try std.fmt.allocPrint(allocator, "Workflow skill {s}", .{slug});

        try assets.append(allocator, .{
            .resource_id = resource_id,
            .resource_kind = "plain_file",
            .relative_path = relative_path,
            .absolute_path = absolute_path,
            .ownership = "exclusive",
            .label = label,
            .file_mode = 0o644,
            .content = skill_content,
        });
    }

    return try assets.toOwnedSlice(allocator);
}

pub fn deinitRenderedAssets(allocator: std.mem.Allocator, assets: []const model.RenderedAsset) void {
    for (assets) |asset| {
        allocator.free(asset.resource_id);
        allocator.free(asset.relative_path);
        if (asset.absolute_path) |absolute_path| allocator.free(absolute_path);
        allocator.free(asset.label);
        allocator.free(asset.content);
    }
    allocator.free(assets);
}

pub fn skillAlreadyInstalled(absolute_path: ?[]const u8) bool {
    const path = absolute_path orelse return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn skillFilePath(
    allocator: std.mem.Allocator,
    host: Host,
    root: []const u8,
    slug: []const u8,
) ![]u8 {
    return switch (host) {
        .codex, .claude_code => std.fs.path.join(allocator, &.{ root, slug, "SKILL.md" }),
        .gemini_cli => std.fs.path.join(allocator, &.{ root, slug, "SKILL.md" }),
    };
}

fn uniqueSlug(
    allocator: std.mem.Allocator,
    slug_counts: *std.StringHashMap(usize),
    base_slug: []const u8,
) ![]u8 {
    if (slug_counts.getPtr(base_slug)) |count_ptr| {
        count_ptr.* += 1;
        return std.fmt.allocPrint(allocator, "{s}-{d}", .{ base_slug, count_ptr.* });
    }

    try slug_counts.put(try allocator.dupe(u8, base_slug), 1);
    return allocator.dupe(u8, base_slug);
}

fn workflowSlugFromFilename(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const stem = filename[0 .. filename.len - ".md".len];
    const trimmed = trimWorkflowPrefix(stem);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var last_was_dash = false;
    for (trimmed) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try buf.append(allocator, std.ascii.toLower(ch));
            last_was_dash = false;
        } else if (!last_was_dash) {
            try buf.append(allocator, '-');
            last_was_dash = true;
        }
    }

    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') {
        _ = buf.pop();
    }
    if (buf.items.len == 0) {
        return allocator.dupe(u8, "workflow");
    }
    return buf.toOwnedSlice(allocator);
}

fn trimWorkflowPrefix(stem: []const u8) []const u8 {
    var idx: usize = 0;
    while (idx < stem.len and std.ascii.isDigit(stem[idx])) : (idx += 1) {}
    while (idx < stem.len and (stem[idx] == '_' or stem[idx] == '-' or stem[idx] == ' ')) : (idx += 1) {}
    return stem[idx..];
}

fn workflowNameFromFilename(filename: []const u8) []const u8 {
    const stem = filename[0 .. filename.len - ".md".len];
    return trimWorkflowPrefix(stem);
}

fn renderSkillContent(
    allocator: std.mem.Allocator,
    host: Host,
    slug: []const u8,
    filename: []const u8,
    workflow_name: []const u8,
) ![]u8 {
    const workflow_ref = try std.fmt.allocPrint(allocator, "workflow:{s}", .{workflow_name});
    defer allocator.free(workflow_ref);

    return switch (host) {
        .codex => std.fmt.allocPrint(
            allocator,
            \\---
            \\name: {s}
            \\description: Load and follow the clumsies workflow {s} when the task matches it.
            \\metadata:
            \\  short-description: Follow {s}
            \\---
            \\
            \\Call the `memload` MCP tool with ids: ["{s}"] and
            \\knownHashes: {{"{s}": "<remembered_hash_or_empty_string>"}}.
            \\Use the last hash you remember for this workflow when available; otherwise use an empty string.
            \\If memload returns changed:false without content, continue from the workflow content you already remember.
            \\Then follow the loaded workflow carefully.
            \\If the user already provided task details, use them as the workflow input.
            \\
        ,
            .{ slug, filename, filename, workflow_ref, workflow_ref },
        ),
        .claude_code => std.fmt.allocPrint(
            allocator,
            \\---
            \\name: {s}
            \\description: Run {s} workflow
            \\argument-hint: "[task description]"
            \\user-invocable: true
            \\---
            \\Call the `memload` MCP tool with ids: ["{s}"] and
            \\knownHashes: {{"{s}": "<remembered_hash_or_empty_string>"}}.
            \\Use the last hash you remember for this workflow when available; otherwise use an empty string.
            \\If memload returns changed:false without content, continue from the workflow content you already remember.
            \\Then follow the loaded workflow carefully.
            \\
            \\$ARGUMENTS
        ,
            .{ slug, filename, workflow_ref, workflow_ref },
        ),
        .gemini_cli => std.fmt.allocPrint(
            allocator,
            \\---
            \\name: {s}
            \\description: Run {s} workflow
            \\---
            \\
            \\Call the `memload` MCP tool with ids: ["{s}"] and
            \\knownHashes: {{"{s}": "<remembered_hash_or_empty_string>"}}.
            \\Use the last hash you remember for this workflow when available; otherwise use an empty string.
            \\If memload returns changed:false without content, continue from the workflow content you already remember.
            \\Then follow the loaded workflow carefully.
            \\If the user already provided task details, use them as the workflow input.
        ,
            .{ slug, filename, workflow_ref, workflow_ref },
        ),
    };
}

test "workflowSlugFromFilename trims numeric prefixes and normalizes separators" {
    const slug = try workflowSlugFromFilename(std.testing.allocator, "00_GEN_COMMIT_MSG.md");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("gen-commit-msg", slug);
}

test "workflowSlugFromFilename falls back when stem is empty after trimming" {
    const slug = try workflowSlugFromFilename(std.testing.allocator, "00__.md");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("workflow", slug);
}

test "skillAlreadyInstalled detects existing absolute skill paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "SKILL.md", .data = "test skill" });
    const absolute_path = try tmp.dir.realpathAlloc(std.testing.allocator, "SKILL.md");
    defer std.testing.allocator.free(absolute_path);

    try std.testing.expect(skillAlreadyInstalled(absolute_path));
    try std.testing.expect(!skillAlreadyInstalled(null));
    try std.testing.expect(!skillAlreadyInstalled("/tmp/clumsies-skill-does-not-exist"));
}

test "renderSkillContent loads workflow by name alias" {
    const content = try renderSkillContent(std.testing.allocator, .codex, "gen-commit-msg", "GEN_COMMIT_MSG.md", "GEN_COMMIT_MSG");
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "ids: [\"workflow:GEN_COMMIT_MSG\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "<remembered_hash_or_empty_string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "workflow/GEN_COMMIT_MSG.md") == null);
}

test "study workflow renders as auto-imported workflow skill proxy" {
    const slug = try workflowSlugFromFilename(std.testing.allocator, "STUDY.md");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("study", slug);

    const content = try renderSkillContent(std.testing.allocator, .codex, slug, "STUDY.md", "STUDY");
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "name: study") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "ids: [\"workflow:STUDY\"]") != null);
}

test "error prone workflow renders as auto-imported workflow skill proxy" {
    const slug = try workflowSlugFromFilename(std.testing.allocator, "ERROR_PRONE.md");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("error-prone", slug);

    const content = try renderSkillContent(std.testing.allocator, .codex, slug, "ERROR_PRONE.md", "ERROR_PRONE");
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "name: error-prone") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "ids: [\"workflow:ERROR_PRONE\"]") != null);
}
