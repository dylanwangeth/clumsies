//! Workflow skill import. Scans the workspace's cached workflow rules and generates SKILL.md
//! files that agent hooks can invoke as slash commands (e.g., /commit, /review-pr).
const model = @import("model.zig");
const std = @import("std");
const workspace_config = @import("../workspace_config.zig");

pub const Host = enum {
    codex,
    claude_code,
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

    const cache_dir = workspace_config.getCachePath(allocator, binding.ws_id) catch return allocator.alloc(model.RenderedAsset, 0);
    defer allocator.free(cache_dir);

    const workflow_root = try std.fs.path.join(allocator, &.{ cache_dir, "prompt", "workflow" });
    defer allocator.free(workflow_root);

    var workflow_dir = std.fs.openDirAbsolute(workflow_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(model.RenderedAsset, 0),
        else => return err,
    };
    defer workflow_dir.close();

    var walker = try workflow_dir.walk(allocator);
    defer walker.deinit();

    var assets: std.ArrayList(model.RenderedAsset) = .empty;
    errdefer deinitRenderedAssets(allocator, assets.items);

    var slug_counts: std.StringHashMap(usize) = .init(allocator);
    defer {
        var it = slug_counts.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        slug_counts.deinit();
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const filename = std.fs.path.basename(entry.path);
        const base_slug = try workflowSlugFromFilename(allocator, filename);
        defer allocator.free(base_slug);
        const slug = try uniqueSlug(allocator, &slug_counts, base_slug);
        defer allocator.free(slug);

        const relative_id = try std.fmt.allocPrint(allocator, "workflow:{s}", .{entry.path});
        defer allocator.free(relative_id);

        const skill_content = try renderSkillContent(allocator, host, slug, filename, relative_id);
        const relative_path = try std.fs.path.join(allocator, &.{ skill_root_display, slug, "SKILL.md" });
        const absolute_path = try std.fs.path.join(allocator, &.{ skill_root_absolute, slug, "SKILL.md" });
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

fn renderSkillContent(
    allocator: std.mem.Allocator,
    host: Host,
    slug: []const u8,
    filename: []const u8,
    workflow_id: []const u8,
) ![]u8 {
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
            \\Call the `memory.load` MCP tool with ids: ["{s}"].
            \\Then follow the loaded workflow carefully.
            \\If the user already provided task details, use them as the workflow input.
            \\
        ,
            .{ slug, filename, filename, workflow_id },
        ),
        .claude_code => std.fmt.allocPrint(
            allocator,
            \\---
            \\name: {s}
            \\description: Run {s} workflow
            \\argument-hint: "[task description]"
            \\user-invocable: true
            \\---
            \\Call the `memory.load` MCP tool with ids: ["{s}"]
            \\
            \\$ARGUMENTS
        ,
            .{ slug, filename, workflow_id },
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
