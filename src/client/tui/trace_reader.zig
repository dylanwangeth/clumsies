// Read local trace.jsonl files and compute analysis stats.
const std = @import("std");
const workspace_prompt = @import("../prompt.zig");
const data = @import("view_types.zig");

pub const LocalStats = struct {
    total_refer_count: u32 = 0,
    constraint_count: u32 = 0,
    active_constraint_count: u32 = 0,
    signal_ratio: u8 = 0,
    refer_trend: [30]u16 = .{0} ** 30,
    refers: []const ReferEvent = &.{},
    prompts: []const data.AnalysisPrompt = &.{},
    inputs: []const InputEvent = &.{},
    workspaces: []const WorkspaceLocalStats = &.{},

    pub fn workspace(self: *const LocalStats, ws_id: []const u8) ?*const WorkspaceLocalStats {
        for (self.workspaces) |*ws| {
            if (std.mem.eql(u8, ws.ws_id, ws_id)) return ws;
        }
        return null;
    }
};

pub const WorkspaceLocalStats = struct {
    ws_id: []const u8,
    total_refer_count: u32 = 0,
    constraint_count: u32 = 0,
    active_constraint_count: u32 = 0,
    signal_ratio: u8 = 0,
    refer_trend: [30]u16 = .{0} ** 30,
    refers: []const ReferEvent = &.{},
    prompts: []const data.AnalysisPrompt = &.{},
    inputs: []const InputEvent = &.{},
};

pub const ReferEvent = struct {
    ws_id: []const u8 = "",
    timestamp: i64,
};

pub const InputEvent = struct {
    ws_id: []const u8 = "",
    session_id: []const u8 = "",
    timestamp: i64,
    content: []const u8,
};

const TraceEvent = struct {
    ws_id: []const u8 = "",
    session_id: []const u8 = "",
    type: []const u8 = "",
    timestamp: i64 = 0,
    prompt_id: ?[]const u8 = null,
    prompt_hash: ?[]const u8 = null,
    constraint_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

const PromptConstraintTotals = std.StringHashMap(u16);

pub fn readLocalStats(allocator: std.mem.Allocator) ?LocalStats {
    const base = getBaseDir(allocator) orelse return null;
    defer allocator.free(base);
    const ws_root = std.fs.path.join(allocator, &.{ base, "workspaces" }) catch return null;
    defer allocator.free(ws_root);

    var dir = std.fs.openDirAbsolute(ws_root, .{ .iterate = true }) catch return null;
    defer dir.close();

    var all_events: std.ArrayList(TraceEvent) = .empty;
    var workspace_stats: std.ArrayList(WorkspaceLocalStats) = .empty;
    var all_prompt_totals: PromptConstraintTotals = .init(allocator);
    defer deinitPromptConstraintTotals(allocator, &all_prompt_totals);
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const ws_id = allocator.dupe(u8, entry.name) catch continue;
        var keep_ws_id = false;
        defer if (!keep_ws_id) allocator.free(ws_id);
        const ws_dir = std.fs.path.join(allocator, &.{ ws_root, entry.name }) catch continue;
        defer allocator.free(ws_dir);
        const trace_path = std.fs.path.join(allocator, &.{ ws_root, entry.name, "trace.jsonl" }) catch continue;
        defer allocator.free(trace_path);
        var ws_events: std.ArrayList(TraceEvent) = .empty;
        readEventsFromFile(allocator, trace_path, ws_id, &ws_events);
        if (ws_events.items.len == 0) continue;
        keep_ws_id = true;

        var ws_prompt_totals = loadPromptConstraintTotals(allocator, ws_dir) catch PromptConstraintTotals.init(allocator);
        defer deinitPromptConstraintTotals(allocator, &ws_prompt_totals);

        mergePromptConstraintTotals(allocator, &all_prompt_totals, &ws_prompt_totals);

        const ws_stats = computeStats(allocator, ws_events.items, &ws_prompt_totals);
        workspace_stats.append(allocator, .{
            .ws_id = ws_id,
            .total_refer_count = ws_stats.total_refer_count,
            .constraint_count = ws_stats.constraint_count,
            .active_constraint_count = ws_stats.active_constraint_count,
            .signal_ratio = ws_stats.signal_ratio,
            .refer_trend = ws_stats.refer_trend,
            .refers = ws_stats.refers,
            .prompts = ws_stats.prompts,
            .inputs = ws_stats.inputs,
        }) catch continue;

        for (ws_events.items) |ev| {
            all_events.append(allocator, ev) catch break;
        }
    }

    if (all_events.items.len == 0) return null;
    var all_stats = computeStats(allocator, all_events.items, &all_prompt_totals);
    all_stats.workspaces = workspace_stats.items;
    return all_stats;
}

fn getBaseDir(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return null;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".clumsies" }) catch null;
}

fn readEventsFromFile(allocator: std.mem.Allocator, path: []const u8, ws_id: []const u8, events: *std.ArrayList(TraceEvent)) void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    const max_trace_bytes: u64 = 8 * 1024 * 1024;
    const end_pos = file.getEndPos() catch return;
    if (end_pos == 0) return;

    const read_from: u64 = if (end_pos > max_trace_bytes) end_pos - max_trace_bytes else 0;
    file.seekTo(read_from) catch return;

    const read_len: usize = @intCast(end_pos - read_from);
    const buf = allocator.alloc(u8, read_len) catch return;
    defer allocator.free(buf);

    const total = file.readAll(buf) catch return;
    if (total == 0) return;

    var contents = buf[0..total];
    if (read_from > 0) {
        if (std.mem.indexOfScalar(u8, contents, '\n')) |newline| {
            contents = contents[newline + 1 ..];
        } else {
            return;
        }
    }

    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(TraceEvent, allocator, line, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        const ev = cloneTraceEvent(allocator, ws_id, parsed.value) catch continue;
        events.append(allocator, ev) catch {
            freeTraceEventOwned(allocator, ev);
            continue;
        };
    }
}

fn cloneTraceEvent(allocator: std.mem.Allocator, ws_id: []const u8, src: TraceEvent) !TraceEvent {
    var out = TraceEvent{
        .ws_id = ws_id,
        .session_id = try allocator.dupe(u8, src.session_id),
        .type = try allocator.dupe(u8, src.type),
        .timestamp = src.timestamp,
        .prompt_id = null,
        .prompt_hash = null,
        .constraint_id = null,
        .reason = null,
        .content = null,
    };
    errdefer allocator.free(out.session_id);
    errdefer allocator.free(out.type);

    out.prompt_id = try dupeOptional(allocator, src.prompt_id);
    errdefer if (out.prompt_id) |s| allocator.free(s);

    out.prompt_hash = try dupeOptional(allocator, src.prompt_hash);
    errdefer if (out.prompt_hash) |s| allocator.free(s);

    out.constraint_id = try dupeOptional(allocator, src.constraint_id);
    errdefer if (out.constraint_id) |s| allocator.free(s);

    out.reason = try dupeOptional(allocator, src.reason);
    errdefer if (out.reason) |s| allocator.free(s);

    out.content = try dupeOptional(allocator, src.content);
    errdefer if (out.content) |s| allocator.free(s);

    return out;
}

fn dupeOptional(allocator: std.mem.Allocator, maybe: ?[]const u8) !?[]const u8 {
    return if (maybe) |value| try allocator.dupe(u8, value) else null;
}

fn freeTraceEventOwned(allocator: std.mem.Allocator, ev: TraceEvent) void {
    allocator.free(ev.session_id);
    allocator.free(ev.type);
    if (ev.prompt_id) |s| allocator.free(s);
    if (ev.prompt_hash) |s| allocator.free(s);
    if (ev.constraint_id) |s| allocator.free(s);
    if (ev.reason) |s| allocator.free(s);
    if (ev.content) |s| allocator.free(s);
}

fn loadPromptConstraintTotals(allocator: std.mem.Allocator, ws_dir: []const u8) !PromptConstraintTotals {
    var totals: PromptConstraintTotals = .init(allocator);
    errdefer deinitPromptConstraintTotals(allocator, &totals);

    var manifest = workspace_prompt.loadManifest(allocator, ws_dir) catch |err| switch (err) {
        error.InvalidManifest, error.FileNotFound => return totals,
        else => return err,
    };
    defer manifest.deinit(allocator);

    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(allocator);

    var it = manifest.prompts.iterator();
    while (it.next()) |entry| {
        ids.append(allocator, entry.key_ptr.*) catch continue;
    }

    if (ids.items.len == 0) return totals;

    var loaded = workspace_prompt.loadPrompts(allocator, ws_dir, ids.items, &.{}) catch |err| switch (err) {
        error.UnknownPromptId, error.FileNotFound, error.UnsafeCachePath => return totals,
        else => return err,
    };
    defer loaded.deinit(allocator);

    for (loaded.items.items) |prompt_item| {
        const content = prompt_item.content orelse continue;
        var parsed = workspace_prompt.parseConstraints(allocator, content) catch continue;
        defer parsed.deinit(allocator);

        const constraint_total: u16 = @intCast(@min(parsed.constraints.items.len, std.math.maxInt(u16)));
        putPromptConstraintTotal(allocator, &totals, prompt_item.id, constraint_total) catch continue;
    }

    return totals;
}

fn mergePromptConstraintTotals(
    allocator: std.mem.Allocator,
    target: *PromptConstraintTotals,
    source: *const PromptConstraintTotals,
) void {
    var it = source.iterator();
    while (it.next()) |entry| {
        putPromptConstraintTotal(allocator, target, entry.key_ptr.*, entry.value_ptr.*) catch continue;
    }
}

fn putPromptConstraintTotal(
    allocator: std.mem.Allocator,
    totals: *PromptConstraintTotals,
    prompt_id: []const u8,
    constraint_total: u16,
) !void {
    if (totals.getPtr(prompt_id)) |value_ptr| {
        if (constraint_total > value_ptr.*) value_ptr.* = constraint_total;
        return;
    }

    const key = try allocator.dupe(u8, prompt_id);
    errdefer allocator.free(key);
    try totals.put(key, constraint_total);
}

fn deinitPromptConstraintTotals(allocator: std.mem.Allocator, totals: *PromptConstraintTotals) void {
    var key_it = totals.keyIterator();
    while (key_it.next()) |key| allocator.free(key.*);
    totals.deinit();
}

fn computeStats(
    allocator: std.mem.Allocator,
    events: []const TraceEvent,
    prompt_totals: *const PromptConstraintTotals,
) LocalStats {
    var stats: LocalStats = .{};

    const PromptAcc = struct {
        refer_count: u32 = 0,
        constraints: std.StringHashMap(u32),
    };
    var prompt_map: std.StringHashMap(PromptAcc) = .init(allocator);

    var refers_list: std.ArrayList(ReferEvent) = .empty;
    var inputs_list: std.ArrayList(InputEvent) = .empty;

    const now_ms: i64 = std.time.milliTimestamp();
    const day_ms: i64 = 86400 * 1000;

    for (events) |ev| {
        if (std.mem.eql(u8, ev.type, "session_input")) {
            if (ev.content) |c| {
                inputs_list.append(allocator, .{
                    .ws_id = ev.ws_id,
                    .session_id = ev.session_id,
                    .timestamp = ev.timestamp,
                    .content = c,
                }) catch {};
            }
            continue;
        }
        if (!std.mem.eql(u8, ev.type, "refer")) continue;
        stats.total_refer_count += 1;
        refers_list.append(allocator, .{
            .ws_id = ev.ws_id,
            .timestamp = ev.timestamp,
        }) catch {};

        const age_days = @divTrunc(now_ms - ev.timestamp, day_ms);
        if (age_days >= 0 and age_days < 30) {
            const bucket: usize = @intCast(29 - age_days);
            stats.refer_trend[bucket] += 1;
        }

        const pid = ev.prompt_id orelse continue;
        const entry = prompt_map.getOrPut(pid) catch continue;
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .refer_count = 0, .constraints = .init(allocator) };
        }
        entry.value_ptr.refer_count += 1;

        if (ev.constraint_id) |cid| {
            const c_entry = entry.value_ptr.constraints.getOrPut(cid) catch continue;
            if (!c_entry.found_existing) c_entry.value_ptr.* = 0;
            c_entry.value_ptr.* += 1;
        }
    }

    var prompts_list: std.ArrayList(data.AnalysisPrompt) = .empty;
    var total_constraints: u32 = 0;
    var active_constraints: u32 = 0;

    var map_it = prompt_map.iterator();
    while (map_it.next()) |kv| {
        const active_count_u32: u32 = @intCast(kv.value_ptr.constraints.count());
        const total_count_u32: u32 = if (prompt_totals.get(kv.key_ptr.*)) |count|
            @max(@as(u32, count), active_count_u32)
        else
            active_count_u32;
        const active_count: u8 = @intCast(@min(active_count_u32, 255));
        const total_count: u8 = @intCast(@min(total_count_u32, 255));
        const idle_count: u8 = total_count -| active_count;

        total_constraints += total_count_u32;
        active_constraints += @min(active_count_u32, total_count_u32);

        const rate: u16 = @intCast(@min(@divTrunc(kv.value_ptr.refer_count, 30), std.math.maxInt(u16)));
        const sig: u8 = if (total_count_u32 > 0)
            @intCast(@min(@divTrunc(@min(active_count_u32, total_count_u32) * 100, total_count_u32), 100))
        else
            0;

        var constraints_list: std.ArrayList(data.ConstraintStat) = .empty;
        var c_it = kv.value_ptr.constraints.iterator();
        while (c_it.next()) |cv| {
            constraints_list.append(allocator, .{
                .id = cv.key_ptr.*,
                .label = cv.key_ptr.*,
                .refer_count = cv.value_ptr.*,
                .idle_days = null,
            }) catch continue;
        }
        std.mem.sort(data.ConstraintStat, constraints_list.items, {}, struct {
            fn cmp(_: void, a: data.ConstraintStat, b: data.ConstraintStat) bool {
                if (a.refer_count == b.refer_count) {
                    return std.mem.lessThan(u8, a.id, b.id);
                }
                return a.refer_count > b.refer_count;
            }
        }.cmp);

        prompts_list.append(allocator, .{
            .name = kv.key_ptr.*,
            .constraint_count = total_count,
            .active_constraint_count = active_count,
            .idle_constraint_count = idle_count,
            .signal_ratio = sig,
            .refer_count = kv.value_ptr.refer_count,
            .workspace_count = 0,
            .rate_per_day = rate,
            .delta_pct = 0,
            .last_referred_days_ago = null,
            .trend = .{0} ** 30,
            .constraints = constraints_list.items,
        }) catch continue;
    }

    std.mem.sort(data.AnalysisPrompt, prompts_list.items, {}, struct {
        fn cmp(_: void, a: data.AnalysisPrompt, b: data.AnalysisPrompt) bool {
            return a.refer_count > b.refer_count;
        }
    }.cmp);

    stats.constraint_count = total_constraints;
    stats.active_constraint_count = active_constraints;
    stats.signal_ratio = if (total_constraints > 0)
        @intCast(@min(@divTrunc(active_constraints * 100, total_constraints), 100))
    else
        0;
    stats.refers = refers_list.items;
    stats.prompts = prompts_list.items;

    std.mem.sort(InputEvent, inputs_list.items, {}, struct {
        fn cmp(_: void, a: InputEvent, b: InputEvent) bool {
            return a.timestamp > b.timestamp;
        }
    }.cmp);
    stats.inputs = inputs_list.items;

    return stats;
}

test "computeStats uses prompt totals to derive non-100 signal ratios" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = [_]TraceEvent{
        .{
            .ws_id = "ws-1",
            .session_id = "ses-1",
            .type = "refer",
            .timestamp = std.time.milliTimestamp(),
            .prompt_id = "p-1",
            .constraint_id = "c-1",
        },
        .{
            .ws_id = "ws-1",
            .session_id = "ses-1",
            .type = "refer",
            .timestamp = std.time.milliTimestamp(),
            .prompt_id = "p-1",
            .constraint_id = "c-2",
        },
    };

    var totals: PromptConstraintTotals = .init(alloc);
    defer deinitPromptConstraintTotals(alloc, &totals);
    try putPromptConstraintTotal(alloc, &totals, "p-1", 4);

    const stats = computeStats(alloc, &events, &totals);

    try std.testing.expectEqual(@as(u32, 4), stats.constraint_count);
    try std.testing.expectEqual(@as(u32, 2), stats.active_constraint_count);
    try std.testing.expectEqual(@as(u8, 50), stats.signal_ratio);
    try std.testing.expectEqual(@as(u8, 4), stats.prompts[0].constraint_count);
    try std.testing.expectEqual(@as(u8, 2), stats.prompts[0].active_constraint_count);
    try std.testing.expectEqual(@as(u8, 2), stats.prompts[0].idle_constraint_count);
    try std.testing.expectEqual(@as(u8, 50), stats.prompts[0].signal_ratio);
}

test "computeStats falls back to active constraint counts when prompt totals are unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = [_]TraceEvent{
        .{
            .ws_id = "ws-1",
            .session_id = "ses-1",
            .type = "refer",
            .timestamp = std.time.milliTimestamp(),
            .prompt_id = "p-1",
            .constraint_id = "c-1",
        },
    };

    var totals: PromptConstraintTotals = .init(alloc);
    defer deinitPromptConstraintTotals(alloc, &totals);

    const stats = computeStats(alloc, &events, &totals);

    try std.testing.expectEqual(@as(u32, 1), stats.constraint_count);
    try std.testing.expectEqual(@as(u32, 1), stats.active_constraint_count);
    try std.testing.expectEqual(@as(u8, 100), stats.signal_ratio);
}
