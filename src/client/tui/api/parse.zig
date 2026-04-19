const std = @import("std");
const auth_api = @import("clumsies_lib").protocol.auth_api;
const collab_api = @import("clumsies_lib").protocol.collab_api;
const library_api = @import("clumsies_lib").protocol.library_api;
const stats_api = @import("clumsies_lib").protocol.stats_api;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;
const data = @import("../view_types.zig");
const model = @import("model.zig");

pub fn parseComments(alloc: std.mem.Allocator, body: []const u8) ?[]const data.CommentEntry {
    const parsed = std.json.parseFromSlice(collab_api.PromptPrCommentsResponse, alloc, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(data.CommentEntry) = .empty;
    for (parsed.value.comments) |c| {
        const author = if (c.author.len > 0) c.author else c.author_id;
        list.append(alloc, .{
            .id = alloc.dupe(u8, c.comment_id) catch continue,
            .author = alloc.dupe(u8, author) catch continue,
            .body = alloc.dupe(u8, c.body) catch continue,
            .created = alloc.dupe(u8, c.created_at) catch continue,
        }) catch continue;
    }
    return list.toOwnedSlice(alloc) catch return null;
}

pub fn parseContextFiles(alloc: std.mem.Allocator, body: []const u8) ?[]const model.ContextFileData {
    const parsed = std.json.parseFromSlice(workspace_api.ContextFilesResponse, alloc, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(model.ContextFileData) = .empty;
    for (parsed.value.files) |f| {
        list.append(alloc, .{
            .path = alloc.dupe(u8, f.path) catch continue,
            .hash = alloc.dupe(u8, f.content_hash) catch continue,
            .size = f.size,
            .author = alloc.dupe(u8, f.author) catch continue,
            .updated_at = alloc.dupe(u8, f.updated_at) catch continue,
        }) catch continue;
    }
    return list.toOwnedSlice(alloc) catch return null;
}

pub fn parseManifestPrompts(alloc: std.mem.Allocator, body: []const u8) ?[]const model.WsPromptData {
    const parsed = std.json.parseFromSlice(workspace_api.WorkspaceManifestResponse, alloc, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(model.WsPromptData) = .empty;
    for (parsed.value.prompts.items) |entry| {
        list.append(alloc, .{
            .prompt_id = alloc.dupe(u8, entry.key) catch continue,
            .content_hash = alloc.dupe(u8, entry.value.hash) catch continue,
            .path = alloc.dupe(u8, entry.value.path) catch continue,
        }) catch continue;
    }
    return list.toOwnedSlice(alloc) catch return null;
}

pub fn parseUser(alloc: std.mem.Allocator, body: []const u8) ?model.UserData {
    const parsed = std.json.parseFromSlice(auth_api.MeResponse, alloc, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const v = parsed.value;

    var ws_list: std.ArrayList(model.WsData) = .empty;
    for (v.workspaces) |ws| {
        ws_list.append(alloc, .{
            .ws_id = alloc.dupe(u8, ws.ws_id) catch continue,
            .name = alloc.dupe(u8, ws.name) catch continue,
            .role = alloc.dupe(u8, ws.role) catch continue,
        }) catch continue;
    }

    return .{
        .user_id = alloc.dupe(u8, v.user_id) catch return null,
        .username = alloc.dupe(u8, v.username) catch return null,
        .role = alloc.dupe(u8, v.role) catch return null,
        .scopes = alloc.dupe(u8, v.scopes) catch return null,
        .workspaces = ws_list.items,
    };
}

pub fn parseDirectory(alloc: std.mem.Allocator, body: []const u8) ?model.DirectoryData {
    const parsed = std.json.parseFromSlice(auth_api.DirectoryResponse, alloc, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var members: std.ArrayList(model.DirectoryMember) = .empty;
    for (parsed.value.members) |m| {
        members.append(alloc, .{
            .user_id = alloc.dupe(u8, m.user_id) catch continue,
            .username = alloc.dupe(u8, m.username) catch continue,
            .role = alloc.dupe(u8, m.role) catch continue,
            .joined_at = alloc.dupe(u8, m.joined_at) catch continue,
        }) catch continue;
    }

    return .{ .members = members.items };
}

pub fn parseLibraryPrompts(alloc: std.mem.Allocator, body: []const u8) ?[]const model.LibraryPrompt {
    const parsed = std.json.parseFromSlice(library_api.PromptListResponse, alloc, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(model.LibraryPrompt) = .empty;
    for (parsed.value.prompts) |p| {
        list.append(alloc, .{
            .prompt_id = alloc.dupe(u8, p.prompt_id) catch continue,
            .path = alloc.dupe(u8, p.path) catch continue,
            .content_hash = alloc.dupe(u8, p.content_hash) catch continue,
            .updated_at = alloc.dupe(u8, p.updated_at) catch continue,
        }) catch continue;
    }
    return list.toOwnedSlice(alloc) catch return null;
}

pub fn parseOrgStats(alloc: std.mem.Allocator, body: []const u8) ?model.OrgStats {
    const parsed = std.json.parseFromSlice(stats_api.OrgStatsResponse, alloc, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const v = parsed.value;

    var trend_list: std.ArrayList(model.TrendPoint) = .empty;
    for (v.trend.data) |t| {
        trend_list.append(alloc, .{
            .date = alloc.dupe(u8, t.date) catch continue,
            .refer_count = t.refer_count,
        }) catch continue;
    }

    var prompt_stats: std.ArrayList(model.PromptStats) = .empty;
    for (v.prompts) |p| {
        var trend_values: std.ArrayList(i64) = .empty;
        for (p.trend) |bucket| {
            trend_values.append(alloc, bucket) catch continue;
        }
        prompt_stats.append(alloc, .{
            .prompt_id = alloc.dupe(u8, p.prompt_id) catch continue,
            .refer_count = p.refer_count,
            .active_constraint_count = p.active_constraint_count,
            .workspace_count = p.workspace_count,
            .bundle_count = p.bundle_count,
            .open_pr_count = p.open_pr_count,
            .last_referred_at = p.last_referred_at,
            .trend = trend_values.items,
        }) catch continue;
    }

    var user_stats: std.ArrayList(model.UserStats) = .empty;
    for (v.users) |u| {
        var trend_values: std.ArrayList(i64) = .empty;
        for (u.trend) |bucket| {
            trend_values.append(alloc, bucket) catch continue;
        }

        var top_prompts: std.ArrayList(model.UserPromptStats) = .empty;
        for (u.top_prompts) |tp| {
            top_prompts.append(alloc, .{
                .prompt_id = alloc.dupe(u8, tp.prompt_id) catch continue,
                .refer_count = tp.refer_count,
            }) catch continue;
        }

        user_stats.append(alloc, .{
            .user_id = alloc.dupe(u8, u.user_id) catch continue,
            .username = alloc.dupe(u8, u.username) catch continue,
            .refer_count = u.refer_count,
            .active_days = u.active_days,
            .last_referred_at = u.last_referred_at,
            .trend = trend_values.items,
            .top_prompts = top_prompts.items,
        }) catch continue;
    }

    return .{
        .total_refer_count = v.total_refer_count,
        .workspace_count = v.workspace_count,
        .prompt_count = v.prompt_count,
        .constraint_count = 0,
        .active_constraint_count = 0,
        .idle_constraint_count = 0,
        .signal_ratio = 0,
        .last_event_at = null,
        .trend = trend_list.items,
        .prompts = prompt_stats.items,
        .users = user_stats.items,
    };
}

pub fn parseBundles(alloc: std.mem.Allocator, body: []const u8) ?[]const model.BundleData {
    const parsed = std.json.parseFromSlice(library_api.BundleListResponse, alloc, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(model.BundleData) = .empty;
    for (parsed.value.bundles) |b| {
        const prompt_count: usize = if (b.prompt_count > 0)
            @intCast(b.prompt_count)
        else
            b.prompt_ids.len;
        list.append(alloc, .{
            .name = alloc.dupe(u8, b.name) catch continue,
            .description = alloc.dupe(u8, b.description) catch continue,
            .prompt_count = prompt_count,
        }) catch continue;
    }
    return list.toOwnedSlice(alloc) catch return null;
}

pub fn parsePromptPrs(alloc: std.mem.Allocator, body: []const u8) ?[]const model.PromptPr {
    const parsed = std.json.parseFromSlice(collab_api.PromptPrListResponse, alloc, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var list: std.ArrayList(model.PromptPr) = .empty;
    for (parsed.value.prs) |pr| {
        list.append(alloc, .{
            .pr_id = alloc.dupe(u8, pr.pr_id) catch continue,
            .status = alloc.dupe(u8, pr.status) catch continue,
            .description = alloc.dupe(u8, pr.description) catch continue,
            .created_at = alloc.dupe(u8, pr.created_at) catch continue,
            .author = alloc.dupe(u8, pr.author) catch continue,
            .operation_count = @intCast(@min(pr.operation_count, std.math.maxInt(i32))),
        }) catch continue;
    }
    return list.toOwnedSlice(alloc) catch return null;
}

test "parseContextFiles accepts content_hash from hub response" {
    const testing = std.testing;
    const body =
        \\{"files":[{"path":"spec/ARCHITECTURE.md","content_hash":"sha256:abc","size":123,"author":"admin","updated_at":"2026-04-14T00:00:00Z"}]}
    ;

    const files = parseContextFiles(testing.allocator, body) orelse return error.TestUnexpectedResult;
    defer {
        for (files) |file| {
            testing.allocator.free(file.path);
            testing.allocator.free(file.hash);
            testing.allocator.free(file.author);
            testing.allocator.free(file.updated_at);
        }
        testing.allocator.free(files);
    }
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("spec/ARCHITECTURE.md", files[0].path);
    try testing.expectEqualStrings("sha256:abc", files[0].hash);
}

test "prompt content response parsing ignores extra fields" {
    const testing = std.testing;
    const body =
        \\{"prompt_id":"p-1","path":"rule/architecture/HUB_SINGLE_SOURCE.md","content_hash":"sha256:def","body":"hello"}
    ;

    const parsed = try std.json.parseFromSlice(library_api.PromptContentResponse, testing.allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try testing.expectEqualStrings("hello", parsed.value.body);
}

test "parseManifestPrompts reads shared manifest schema" {
    const testing = std.testing;
    const body =
        \\{"ws_id":"ws-1","name":"demo","revision":7,"prompts":{"p-1":{"path":"rule/coding/00_COMPATIBILITY.md","hash":"sha256:def"}},"context":{}}
    ;

    const prompts = parseManifestPrompts(testing.allocator, body) orelse return error.TestUnexpectedResult;
    defer {
        for (prompts) |prompt| {
            testing.allocator.free(prompt.prompt_id);
            testing.allocator.free(prompt.content_hash);
            testing.allocator.free(prompt.path);
        }
        testing.allocator.free(prompts);
    }

    try testing.expectEqual(@as(usize, 1), prompts.len);
    try testing.expectEqualStrings("p-1", prompts[0].prompt_id);
    try testing.expectEqualStrings("sha256:def", prompts[0].content_hash);
    try testing.expectEqualStrings("rule/coding/00_COMPATIBILITY.md", prompts[0].path);
}

test "parseComments reads wrapped comments response" {
    const testing = std.testing;
    const body =
        \\{"comments":[{"comment_id":"cmt-1","author_id":"u-1","author":"alice","body":"looks good","created_at":"2026-04-16T00:00:00Z"}]}
    ;

    const comments = parseComments(testing.allocator, body) orelse return error.TestUnexpectedResult;
    defer {
        for (comments) |comment| {
            testing.allocator.free(comment.id);
            testing.allocator.free(comment.author);
            testing.allocator.free(comment.body);
            testing.allocator.free(comment.created);
        }
        testing.allocator.free(comments);
    }

    try testing.expectEqual(@as(usize, 1), comments.len);
    try testing.expectEqualStrings("alice", comments[0].author);
    try testing.expectEqualStrings("looks good", comments[0].body);
}

test "parseBundles uses prompt_count when server provides it" {
    const testing = std.testing;
    const body =
        \\{"bundles":[{"name":"core","description":"Core prompts","updated_at":"2026-04-16T00:00:00Z","prompt_count":3}]}
    ;

    const bundles = parseBundles(testing.allocator, body) orelse return error.TestUnexpectedResult;
    defer {
        for (bundles) |bundle| {
            testing.allocator.free(bundle.name);
            testing.allocator.free(bundle.description);
        }
        testing.allocator.free(bundles);
    }

    try testing.expectEqual(@as(usize, 1), bundles.len);
    try testing.expectEqual(@as(usize, 3), bundles[0].prompt_count);
}
