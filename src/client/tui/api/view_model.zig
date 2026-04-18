const std = @import("std");
const data = @import("../view_types.zig");
const trace_reader = @import("../trace_reader.zig");
const model = @import("model.zig");
const state = @import("state.zig");

pub fn toPromptEntries(
    alloc: std.mem.Allocator,
    prompts: []const model.LibraryPrompt,
) []const data.PromptEntry {
    var list: std.ArrayList(data.PromptEntry) = .empty;
    for (prompts) |p| {
        const refer_str = formatCount(alloc, p.refer_count) catch "";
        list.append(alloc, .{
            .path = p.path,
            .kind = data.kindFromPath(p.path),
            .refer_count = refer_str,
            .constraint_count = @intCast(@min(p.active_constraint_count, 255)),
            .bundle_count = @intCast(@min(p.bundle_count, 255)),
            .bundle_names = "",
            .updated = p.updated_at,
            .age = "",
            .summary = "",
            .trend = .{0} ** 8,
            .content_hash = p.content_hash,
            .open_pr_count = @intCast(@min(p.open_pr_count, 255)),
            .workspace_count = @intCast(@min(p.workspace_count, 255)),
            .workspace_names = "",
            .revision = 0,
        }) catch continue;
    }
    return list.items;
}

pub fn toBundleEntries(
    alloc: std.mem.Allocator,
    bundles: []const model.BundleData,
) []const data.BundleEntry {
    var list: std.ArrayList(data.BundleEntry) = .empty;
    for (bundles) |b| {
        list.append(alloc, .{
            .name = b.name,
            .count = @intCast(@min(b.prompt_count, std.math.maxInt(u16))),
        }) catch continue;
    }
    return list.items;
}

pub fn toPrEntries(
    alloc: std.mem.Allocator,
    prs: []const model.PromptPr,
    prompt_path: []const u8,
    api_state: *state.ApiState,
) []const data.PullRequestEntry {
    var list: std.ArrayList(data.PullRequestEntry) = .empty;
    for (prs) |pr| {
        var diff: []const []const u8 = &.{};
        var comments: []const data.CommentEntry = &.{};
        var trace_refers: u16 = 0;
        var op_type: []const u8 = "";
        var op_current_path: []const u8 = "";
        var op_new_path: []const u8 = "";
        var op_index: u16 = 0;
        if (api_state.pr_detail_id) |cached_id| {
            if (std.mem.eql(u8, cached_id, pr.pr_id)) {
                diff = api_state.pr_detail_diff orelse &.{};
                trace_refers = api_state.pr_detail_trace_refers;
                op_type = api_state.pr_detail_op_type orelse "";
                op_current_path = api_state.pr_detail_op_current_path orelse "";
                op_new_path = api_state.pr_detail_op_new_path orelse "";
                op_index = api_state.pr_detail_op_index;
            }
        }
        if (api_state.pr_comments_cache.lookup(.{ .value = pr.pr_id })) |c| {
            comments = c;
        }

        list.append(alloc, .{
            .id = pr.pr_id,
            .prompt_name = prompt_path,
            .status = pr.status,
            .author = pr.author,
            .created = pr.created_at,
            .description = pr.description,
            .base_hash = "",
            .diff = diff,
            .comments = comments,
            .trace_refers = trace_refers,
            .trace_sessions = 0,
            .operation_count = @intCast(@max(pr.operation_count, 0)),
            .op_type = op_type,
            .op_current_path = op_current_path,
            .op_new_path = op_new_path,
            .op_index = op_index,
        }) catch continue;
    }
    return list.items;
}

pub fn analysisFromStats(
    alloc: std.mem.Allocator,
    stats: model.OrgStats,
    library: ?[]const model.LibraryPrompt,
    local: ?trace_reader.LocalStats,
) data.AnalysisData {
    var trend: [30]u16 = .{0} ** 30;
    const tcount = @min(stats.trend.len, 30);
    for (0..tcount) |i| {
        const idx = if (stats.trend.len > 30) stats.trend.len - 30 + i else i;
        trend[i] = @intCast(@min(stats.trend[idx].refer_count, std.math.maxInt(u16)));
    }

    const ratio_pct: u8 = @intCast(@min(@as(u64, @intFromFloat(stats.signal_ratio * 100)), 100));
    const idle: u32 = @intCast(@max(stats.idle_constraint_count, 0));
    const active: u32 = @intCast(@max(stats.active_constraint_count, 0));
    const total: u32 = @intCast(@max(stats.constraint_count, 0));

    var refers_per_hour: u16 = 0;
    if (tcount > 0) {
        const last_day = stats.trend[stats.trend.len - 1].refer_count;
        refers_per_hour = @intCast(@min(@divTrunc(@max(last_day, 0), 24), std.math.maxInt(u16)));
    }

    var prompts_list: std.ArrayList(data.AnalysisPrompt) = .empty;
    for (stats.prompts) |ps| {
        const name = if (library) |lib| blk: {
            for (lib) |lp| {
                if (std.mem.eql(u8, lp.prompt_id, ps.prompt_id))
                    break :blk lp.path;
            }
            break :blk ps.prompt_id;
        } else ps.prompt_id;

        const c_total: u8 = @intCast(@min(ps.active_constraint_count, 255));
        const c_idle: u8 = 0;
        const sig: u8 = if (c_total > 0)
            @intCast(@min(@divTrunc(ps.active_constraint_count * 100, @max(c_total, 1)), 100))
        else
            0;
        const rate: u16 = @intCast(@min(
            @divTrunc(@max(ps.refer_count, 0), @max(@as(i64, @intCast(tcount)), 1)),
            std.math.maxInt(u16),
        ));

        prompts_list.append(alloc, .{
            .name = name,
            .constraint_count = c_total,
            .active_constraint_count = c_total,
            .idle_constraint_count = c_idle,
            .signal_ratio = sig,
            .refer_count = @intCast(@min(ps.refer_count, std.math.maxInt(u32))),
            .workspace_count = @intCast(@min(ps.workspace_count, 255)),
            .rate_per_day = rate,
            .delta_pct = 0,
            .last_referred_days_ago = lastReferredDaysAgo(ps.last_referred_at),
            .trend = trend30FromBuckets(ps.trend),
            .constraints = &.{},
        }) catch continue;
    }

    if (local) |l| {
        const remapped_prompts: []const data.AnalysisPrompt = if (library) |lib| blk: {
            var remapped: std.ArrayList(data.AnalysisPrompt) = .empty;
            for (l.prompts) |p| {
                var copy = p;
                for (lib) |lp| {
                    if (std.mem.eql(u8, lp.prompt_id, p.name)) {
                        copy.name = lp.path;
                        break;
                    }
                }
                remapped.append(alloc, copy) catch continue;
            }
            break :blk remapped.items;
        } else l.prompts;

        var inputs_list: std.ArrayList(data.InputItem) = .empty;
        for (l.inputs) |iv| {
            inputs_list.append(alloc, .{ .timestamp = iv.timestamp, .content = iv.content }) catch break;
        }

        return .{
            .constraint_count = l.constraint_count,
            .active_constraint_count = l.active_constraint_count,
            .idle_constraint_count = if (l.constraint_count > l.active_constraint_count)
                l.constraint_count - l.active_constraint_count
            else
                0,
            .signal_ratio = l.signal_ratio,
            .refers_per_hour = refers_per_hour,
            .today_delta_pct = 0,
            .last_event_minutes_ago = 0,
            .refer_trend = l.refer_trend,
            .prompts = remapped_prompts,
            .members = toMemberStatss(alloc, stats.users, library),
            .models = &.{},
            .alerts = &.{},
            .inputs = inputs_list.items,
        };
    }

    return .{
        .constraint_count = total,
        .active_constraint_count = active,
        .idle_constraint_count = idle,
        .signal_ratio = ratio_pct,
        .refers_per_hour = refers_per_hour,
        .today_delta_pct = 0,
        .last_event_minutes_ago = 0,
        .refer_trend = trend,
        .prompts = prompts_list.items,
        .members = toMemberStatss(alloc, stats.users, library),
        .models = &.{},
        .alerts = &.{},
    };
}

fn formatCount(alloc: std.mem.Allocator, n: i64) ![]const u8 {
    if (n >= 1000) {
        const k = @as(f64, @floatFromInt(n)) / 1000.0;
        return std.fmt.allocPrint(alloc, "{d:.1}k", .{k});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{n});
}

fn lastReferredDaysAgo(ts_ms: ?i64) ?u16 {
    const ts = ts_ms orelse return null;
    const now_ms = std.time.milliTimestamp();
    if (ts > now_ms) return 0;
    const age_days = @divTrunc(now_ms - ts, std.time.ms_per_day);
    return @intCast(@min(age_days, std.math.maxInt(u16)));
}

fn trend30FromBuckets(source: []const i64) [30]u16 {
    var trend30: [30]u16 = .{0} ** 30;
    const count = @min(source.len, 30);
    const start = if (source.len > 30) source.len - 30 else 0;
    for (0..count) |i| {
        trend30[30 - count + i] = @intCast(@min(@max(source[start + i], 0), std.math.maxInt(u16)));
    }
    return trend30;
}

test "toPromptEntries maps library prompts to view entries" {
    const alloc = std.testing.allocator;
    const prompts = [_]model.LibraryPrompt{
        .{ .prompt_id = "p1", .path = "rule/STYLE.md", .content_hash = "abc", .updated_at = "2025-01-01" },
        .{ .prompt_id = "p2", .path = "workflow/COMMIT.md", .content_hash = "def", .updated_at = "2025-01-02", .refer_count = 1500 },
    };
    const entries = toPromptEntries(alloc, &prompts);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("rule/STYLE.md", entries[0].path);
    try std.testing.expectEqualStrings("rule", entries[0].kind);
    try std.testing.expectEqualStrings("workflow/COMMIT.md", entries[1].path);
    try std.testing.expectEqualStrings("wf", entries[1].kind);
    // 1500 should be formatted as "1.5k"
    try std.testing.expectEqualStrings("1.5k", entries[1].refer_count);
    alloc.free(entries[1].refer_count);
    alloc.free(entries[0].refer_count);
}

test "toBundleEntries maps bundle data to view entries" {
    const alloc = std.testing.allocator;
    const bundles = [_]model.BundleData{
        .{ .name = "default", .description = "", .prompt_count = 5 },
    };
    const entries = toBundleEntries(alloc, &bundles);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("default", entries[0].name);
    try std.testing.expectEqual(@as(u16, 5), entries[0].count);
}

test "formatCount formats thousands with k suffix" {
    const alloc = std.testing.allocator;
    const r1 = try formatCount(alloc, 42);
    defer alloc.free(r1);
    try std.testing.expectEqualStrings("42", r1);

    const r2 = try formatCount(alloc, 1000);
    defer alloc.free(r2);
    try std.testing.expectEqualStrings("1.0k", r2);

    const r3 = try formatCount(alloc, 2500);
    defer alloc.free(r3);
    try std.testing.expectEqualStrings("2.5k", r3);
}

test "trend30FromBuckets right-aligns short source into 30-element array" {
    const src = [_]i64{ 10, 20, 30 };
    const result = trend30FromBuckets(&src);
    try std.testing.expectEqual(@as(u16, 0), result[0]);
    try std.testing.expectEqual(@as(u16, 10), result[27]);
    try std.testing.expectEqual(@as(u16, 20), result[28]);
    try std.testing.expectEqual(@as(u16, 30), result[29]);
}

test "trend30FromBuckets truncates long source to last 30" {
    var src: [35]i64 = undefined;
    for (0..35) |i| src[i] = @intCast(i);
    const result = trend30FromBuckets(&src);
    try std.testing.expectEqual(@as(u16, 5), result[0]);
    try std.testing.expectEqual(@as(u16, 34), result[29]);
}

fn promptNameForId(library: ?[]const model.LibraryPrompt, prompt_id: []const u8) []const u8 {
    if (library) |lib| {
        for (lib) |lp| {
            if (std.mem.eql(u8, lp.prompt_id, prompt_id)) return lp.path;
        }
    }
    return prompt_id;
}

fn toMemberStatss(
    alloc: std.mem.Allocator,
    members: []const model.UserStats,
    library: ?[]const model.LibraryPrompt,
) []const data.MemberStats {
    var list: std.ArrayList(data.MemberStats) = .empty;
    for (members) |m| {
        var top_prompts: std.ArrayList(data.MemberPromptStat) = .empty;
        for (m.top_prompts) |tp| {
            top_prompts.append(alloc, .{
                .name = promptNameForId(library, tp.prompt_id),
                .refer_count = @intCast(@min(tp.refer_count, std.math.maxInt(u32))),
            }) catch continue;
        }
        list.append(alloc, .{
            .username = m.username,
            .refer_count = @intCast(@min(m.refer_count, std.math.maxInt(u32))),
            .active_days = @intCast(@min(m.active_days, 255)),
            .trend = trend30FromBuckets(m.trend),
            .top_prompts = top_prompts.items,
            .models = &.{},
        }) catch continue;
    }
    return list.items;
}
