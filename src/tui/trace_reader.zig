// Read local trace.jsonl files and compute Insights stats.
const std = @import("std");
const data = @import("mock_data.zig");

pub const LocalStats = struct {
    total_refer_count: u32 = 0,
    constraint_count: u32 = 0,
    active_constraint_count: u32 = 0,
    signal_ratio: u8 = 0,
    refer_trend: [30]u16 = .{0} ** 30,
    prompts: []const data.InsightsPrompt = &.{},
};

const TraceEvent = struct {
    type: []const u8 = "",
    ts: i64 = 0,
    prompt_id: ?[]const u8 = null,
    prompt_hash: ?[]const u8 = null,
    constraint_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub fn readLocalStats(allocator: std.mem.Allocator) ?LocalStats {
    const log_dir = getLogDir(allocator) orelse return null;
    defer allocator.free(log_dir);

    // Read all workspace trace files
    var dir = std.fs.openDirAbsolute(log_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var all_events: std.ArrayList(TraceEvent) = .empty;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const path = std.fs.path.join(allocator, &.{ log_dir, entry.name }) catch continue;
        defer allocator.free(path);
        readEventsFromFile(allocator, path, &all_events);
    }

    if (all_events.items.len == 0) return null;
    return computeStats(allocator, all_events.items);
}

fn getLogDir(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".clumsies", "log" }) catch null;
}

fn readEventsFromFile(allocator: std.mem.Allocator, path: []const u8, events: *std.ArrayList(TraceEvent)) void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.read(buf[total..]) catch return;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return;

    var line_it = std.mem.splitScalar(u8, buf[0..total], '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(TraceEvent, allocator, line, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch continue;
        events.append(allocator, parsed.value) catch continue;
    }
}

fn computeStats(allocator: std.mem.Allocator, events: []const TraceEvent) LocalStats {
    var stats: LocalStats = .{};

    // Count refers per prompt, track unique constraints
    const PromptAcc = struct {
        refer_count: u32 = 0,
        constraints: std.StringHashMap(u32),
    };
    var prompt_map: std.StringHashMap(PromptAcc) = .init(allocator);

    // 30-day trend: bucket events by day
    const now_ms: i64 = std.time.milliTimestamp();
    const day_ms: i64 = 86400 * 1000;

    for (events) |ev| {
        if (!std.mem.eql(u8, ev.type, "refer")) continue;
        stats.total_refer_count += 1;

        // Trend: which day bucket (0 = 30 days ago, 29 = today)
        const age_days = @divTrunc(now_ms - ev.ts, day_ms);
        if (age_days >= 0 and age_days < 30) {
            const bucket: usize = @intCast(29 - age_days);
            stats.refer_trend[bucket] += 1;
        }

        // Per-prompt accumulation
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

    // Build InsightsPrompt list
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

        prompts_list.append(allocator, .{
            .name = kv.key_ptr.*,
            .constraint_count = c_count,
            .active_constraint_count = c_count,
            .idle_constraint_count = 0,
            .signal_ratio = sig,
            .refer_count = kv.value_ptr.refer_count,
            .rate_per_day = rate,
            .delta_pct = 0,
            .last_referred_days_ago = 0,
            .trend = .{0} ** 30,
            .constraints = &.{},
        }) catch continue;
    }

    // Sort by refer_count descending
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
    stats.prompts = prompts_list.items;

    return stats;
}
