// Read local trace.jsonl files and compute Insights stats.
const std = @import("std");
const data = @import("mock_data.zig");

pub const LocalStats = struct {
    total_refer_count: u32 = 0,
    constraint_count: u32 = 0,
    active_constraint_count: u32 = 0,
    signal_ratio: u8 = 0,
    refer_trend: [30]u16 = .{0} ** 30,
    refers: []const ReferEvent = &.{},
    prompts: []const data.InsightsPrompt = &.{},
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
    prompts: []const data.InsightsPrompt = &.{},
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

pub fn readLocalStats(allocator: std.mem.Allocator) ?LocalStats {
    const base = getBaseDir(allocator) orelse return null;
    defer allocator.free(base);
    const ws_root = std.fs.path.join(allocator, &.{ base, "workspaces" }) catch return null;
    defer allocator.free(ws_root);

    var dir = std.fs.openDirAbsolute(ws_root, .{ .iterate = true }) catch return null;
    defer dir.close();

    var all_events: std.ArrayList(TraceEvent) = .empty;
    var workspace_stats: std.ArrayList(WorkspaceLocalStats) = .empty;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const ws_id = allocator.dupe(u8, entry.name) catch continue;
        const trace_path = std.fs.path.join(allocator, &.{ ws_root, entry.name, "trace.jsonl" }) catch continue;
        defer allocator.free(trace_path);
        var ws_events: std.ArrayList(TraceEvent) = .empty;
        readEventsFromFile(allocator, trace_path, ws_id, &ws_events);
        if (ws_events.items.len == 0) continue;

        const ws_stats = computeStats(allocator, ws_events.items);
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
    var all_stats = computeStats(allocator, all_events.items);
    all_stats.workspaces = workspace_stats.items;
    return all_stats;
}

fn getBaseDir(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
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
        var ev = parsed.value;
        ev.ws_id = ws_id;
        events.append(allocator, ev) catch continue;
    }
}

fn computeStats(allocator: std.mem.Allocator, events: []const TraceEvent) LocalStats {
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

    var prompts_list: std.ArrayList(data.InsightsPrompt) = .empty;
    var total_constraints: u32 = 0;
    var active_constraints: u32 = 0;

    var map_it = prompt_map.iterator();
    while (map_it.next()) |kv| {
        const c_count: u8 = @intCast(@min(kv.value_ptr.constraints.count(), 255));
        total_constraints += c_count;
        active_constraints += c_count;

        const rate: u16 = @intCast(@min(@divTrunc(kv.value_ptr.refer_count, 30), std.math.maxInt(u16)));
        const sig: u8 = if (c_count > 0) 100 else 0;

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
            .constraint_count = c_count,
            .active_constraint_count = c_count,
            .idle_constraint_count = 0,
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

    std.mem.sort(data.InsightsPrompt, prompts_list.items, {}, struct {
        fn cmp(_: void, a: data.InsightsPrompt, b: data.InsightsPrompt) bool {
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
