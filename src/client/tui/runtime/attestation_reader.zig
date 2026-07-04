//! Read local attestation logs and compute analysis stats.
const std = @import("std");
const workspace_rule = @import("../../rule.zig");
const data = @import("../models/view_types.zig");

pub const LocalStats = struct {
    total_refer_count: u32 = 0,
    constraint_count: u32 = 0,
    active_constraint_count: u32 = 0,
    signal_ratio: u8 = 0,
    refer_trend: [30]u16 = .{0} ** 30,
    refers: []const ReferEvent = &.{},
    rules: []const data.AnalysisRule = &.{},
    inputs: []const InputEvent = &.{},
    rounds: []const RoundEvent = &.{},
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
    rules: []const data.AnalysisRule = &.{},
    inputs: []const InputEvent = &.{},
    rounds: []const RoundEvent = &.{},
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
    model: ?[]const u8 = null,
};

pub const RoundRefer = struct {
    rule_id: []const u8,
    constraint_id: []const u8,
    constraint_name: ?[]const u8 = null,
    constraint_text: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub const RoundTool = struct {
    kind: []const u8,
    timestamp: i64,
    session_id: []const u8 = "",
    rule_id: ?[]const u8 = null,
    constraint_id: ?[]const u8 = null,
    constraint_name: ?[]const u8 = null,
    constraint_text: ?[]const u8 = null,
    mpf_hash: ?[]const u8 = null,
    mpf_content: ?[]const u8 = null,
    mpf_changed: ?bool = null,
    discover_kind: ?[]const u8 = null,
    discover_group: ?[]const u8 = null,
    discover_query: ?[]const u8 = null,
    discover_result_count: ?u32 = null,
    discover_result_names: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
    path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
};

pub const RoundEvent = struct {
    ws_id: []const u8 = "",
    session_id: []const u8 = "",
    timestamp: i64,
    content: []const u8,
    model: ?[]const u8 = null,
    missing_user_prompt: bool = false,
    load_count: u16 = 0,
    refer_count: u16 = 0,
    submit_count: u16 = 0,
    reject_count: u16 = 0,
    summary: ?[]const u8 = null,
    reject_reason: ?[]const u8 = null,
    refers: []const RoundRefer = &.{},
    tools: []const RoundTool = &.{},
};

const AttestationEvent = struct {
    ws_id: []const u8 = "",
    session_id: []const u8 = "",
    type: []const u8 = "",
    timestamp: i64 = 0,
    rule_id: ?[]const u8 = null,
    rule_hash: ?[]const u8 = null,
    constraint_id: ?[]const u8 = null,
    constraint_name: ?[]const u8 = null,
    constraint_text: ?[]const u8 = null,
    mpf_hash: ?[]const u8 = null,
    mpf_content: ?[]const u8 = null,
    mpf_changed: ?bool = null,
    kind: ?[]const u8 = null,
    group: ?[]const u8 = null,
    query: ?[]const u8 = null,
    result_count: ?u32 = null,
    result_names: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    content: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    model: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
    path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
};

const RuleConstraintTotals = std.StringHashMap(u16);

pub fn readLocalStats(allocator: std.mem.Allocator) ?LocalStats {
    const base = getBaseDir(allocator) orelse return null;
    defer allocator.free(base);
    const ws_root = std.fs.path.join(allocator, &.{ base, "workspaces" }) catch return null;
    defer allocator.free(ws_root);

    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, ws_root, .{ .iterate = true }) catch return null;
    defer dir.close(std.Options.debug_io);

    var all_events: std.ArrayList(AttestationEvent) = .empty;
    var workspace_stats: std.ArrayList(WorkspaceLocalStats) = .empty;
    var all_rule_totals: RuleConstraintTotals = .init(allocator);
    defer deinitRuleConstraintTotals(allocator, &all_rule_totals);
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const ws_id = allocator.dupe(u8, entry.name) catch continue;
        var keep_ws_id = false;
        defer if (!keep_ws_id) allocator.free(ws_id);
        const ws_dir = std.fs.path.join(allocator, &.{ ws_root, entry.name }) catch continue;
        defer allocator.free(ws_dir);
        var ws_events: std.ArrayList(AttestationEvent) = .empty;
        readWorkspaceEvents(allocator, ws_dir, ws_id, &ws_events);
        if (ws_events.items.len == 0) continue;
        keep_ws_id = true;

        var ws_rule_totals = loadRuleConstraintTotals(allocator, ws_dir) catch RuleConstraintTotals.init(allocator);
        defer deinitRuleConstraintTotals(allocator, &ws_rule_totals);

        mergeRuleConstraintTotals(allocator, &all_rule_totals, &ws_rule_totals);

        const ws_stats = computeStats(allocator, ws_events.items, &ws_rule_totals);
        workspace_stats.append(allocator, .{
            .ws_id = ws_id,
            .total_refer_count = ws_stats.total_refer_count,
            .constraint_count = ws_stats.constraint_count,
            .active_constraint_count = ws_stats.active_constraint_count,
            .signal_ratio = ws_stats.signal_ratio,
            .refer_trend = ws_stats.refer_trend,
            .refers = ws_stats.refers,
            .rules = ws_stats.rules,
            .inputs = ws_stats.inputs,
            .rounds = ws_stats.rounds,
        }) catch continue;

        for (ws_events.items) |ev| {
            all_events.append(allocator, ev) catch break;
        }
    }

    if (all_events.items.len == 0) return null;
    var all_stats = computeStats(allocator, all_events.items, &all_rule_totals);
    all_stats.workspaces = workspace_stats.items;
    return all_stats;
}

fn readWorkspaceEvents(allocator: std.mem.Allocator, ws_dir: []const u8, ws_id: []const u8, events: *std.ArrayList(AttestationEvent)) void {
    const log_dir = std.fs.path.join(allocator, &.{ ws_dir, "attestation" }) catch return;
    defer allocator.free(log_dir);

    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, log_dir, .{ .iterate = true }) catch null;
    if (dir) |*opened_dir| {
        defer opened_dir.close(std.Options.debug_io);
        var it = opened_dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const path = std.fs.path.join(allocator, &.{ log_dir, entry.name }) catch continue;
            defer allocator.free(path);
            readEventsFromFile(allocator, path, ws_id, events);
        }
    }
}

fn getBaseDir(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return null;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".clumsies" }) catch null;
}

fn readEventsFromFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    ws_id: []const u8,
    events: *std.ArrayList(AttestationEvent),
) void {
    const file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return;
    defer file.close(std.Options.debug_io);

    const max_attestation_bytes: u64 = 8 * 1024 * 1024;
    const end_pos = file.getEndPos() catch return;
    if (end_pos == 0) return;

    const read_from: u64 = if (end_pos > max_attestation_bytes) end_pos - max_attestation_bytes else 0;
    file.seekTo(read_from) catch return;

    const read_len: usize = @intCast(end_pos - read_from);
    const buf = allocator.alloc(u8, read_len) catch return;
    defer allocator.free(buf);

    var read_buf: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, std.Options.debug_io, &read_buf);
    const total = reader.interface.readSliceShort(buf) catch return;
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
        const parsed = std.json.parseFromSlice(AttestationEvent, allocator, line, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        const ev = cloneAttestationEvent(allocator, ws_id, parsed.value) catch continue;
        events.append(allocator, ev) catch {
            freeAttestationEventOwned(allocator, ev);
            continue;
        };
    }
}

fn cloneAttestationEvent(
    allocator: std.mem.Allocator,
    ws_id: []const u8,
    src: AttestationEvent,
) !AttestationEvent {
    var out = AttestationEvent{
        .ws_id = ws_id,
        .session_id = try allocator.dupe(u8, src.session_id),
        .type = try allocator.dupe(u8, src.type),
        .timestamp = src.timestamp,
        .rule_id = null,
        .rule_hash = null,
        .constraint_id = null,
        .constraint_name = null,
        .constraint_text = null,
        .mpf_hash = null,
        .mpf_content = null,
        .mpf_changed = src.mpf_changed,
        .kind = null,
        .group = null,
        .query = null,
        .result_count = src.result_count,
        .result_names = null,
        .reason = null,
        .content = null,
        .summary = null,
        .model = null,
        .context_id = null,
        .path = null,
        .new_path = null,
    };
    errdefer allocator.free(out.session_id);
    errdefer allocator.free(out.type);

    out.rule_id = try dupeOptional(allocator, src.rule_id);
    errdefer if (out.rule_id) |s| allocator.free(s);

    out.rule_hash = try dupeOptional(allocator, src.rule_hash);
    errdefer if (out.rule_hash) |s| allocator.free(s);

    out.constraint_id = try dupeOptional(allocator, src.constraint_id);
    errdefer if (out.constraint_id) |s| allocator.free(s);

    out.constraint_name = try dupeOptional(allocator, src.constraint_name);
    errdefer if (out.constraint_name) |s| allocator.free(s);

    out.constraint_text = try dupeOptional(allocator, src.constraint_text);
    errdefer if (out.constraint_text) |s| allocator.free(s);

    out.mpf_hash = try dupeOptional(allocator, src.mpf_hash);
    errdefer if (out.mpf_hash) |s| allocator.free(s);

    out.mpf_content = try dupeOptional(allocator, src.mpf_content);
    errdefer if (out.mpf_content) |s| allocator.free(s);

    out.kind = try dupeOptional(allocator, src.kind);
    errdefer if (out.kind) |s| allocator.free(s);

    out.group = try dupeOptional(allocator, src.group);
    errdefer if (out.group) |s| allocator.free(s);

    out.query = try dupeOptional(allocator, src.query);
    errdefer if (out.query) |s| allocator.free(s);

    out.result_names = try dupeOptional(allocator, src.result_names);
    errdefer if (out.result_names) |s| allocator.free(s);

    out.reason = try dupeOptional(allocator, src.reason);
    errdefer if (out.reason) |s| allocator.free(s);

    out.content = try dupeOptional(allocator, src.content);
    errdefer if (out.content) |s| allocator.free(s);

    out.summary = try dupeOptional(allocator, src.summary);
    errdefer if (out.summary) |s| allocator.free(s);

    out.model = try dupeOptional(allocator, src.model);
    errdefer if (out.model) |s| allocator.free(s);

    out.context_id = try dupeOptional(allocator, src.context_id);
    errdefer if (out.context_id) |s| allocator.free(s);

    out.path = try dupeOptional(allocator, src.path);
    errdefer if (out.path) |s| allocator.free(s);

    out.new_path = try dupeOptional(allocator, src.new_path);
    errdefer if (out.new_path) |s| allocator.free(s);

    return out;
}

fn dupeOptional(allocator: std.mem.Allocator, maybe: ?[]const u8) !?[]const u8 {
    return if (maybe) |value| try allocator.dupe(u8, value) else null;
}

fn freeAttestationEventOwned(allocator: std.mem.Allocator, ev: AttestationEvent) void {
    allocator.free(ev.session_id);
    allocator.free(ev.type);
    if (ev.rule_id) |s| allocator.free(s);
    if (ev.rule_hash) |s| allocator.free(s);
    if (ev.constraint_id) |s| allocator.free(s);
    if (ev.constraint_name) |s| allocator.free(s);
    if (ev.constraint_text) |s| allocator.free(s);
    if (ev.mpf_hash) |s| allocator.free(s);
    if (ev.mpf_content) |s| allocator.free(s);
    if (ev.kind) |s| allocator.free(s);
    if (ev.group) |s| allocator.free(s);
    if (ev.query) |s| allocator.free(s);
    if (ev.result_names) |s| allocator.free(s);
    if (ev.reason) |s| allocator.free(s);
    if (ev.content) |s| allocator.free(s);
    if (ev.summary) |s| allocator.free(s);
    if (ev.model) |s| allocator.free(s);
    if (ev.context_id) |s| allocator.free(s);
    if (ev.path) |s| allocator.free(s);
    if (ev.new_path) |s| allocator.free(s);
}

fn loadRuleConstraintTotals(allocator: std.mem.Allocator, ws_dir: []const u8) !RuleConstraintTotals {
    var totals: RuleConstraintTotals = .init(allocator);
    errdefer deinitRuleConstraintTotals(allocator, &totals);

    var manifest = workspace_rule.loadManifest(allocator, ws_dir) catch |err| switch (err) {
        error.InvalidManifest, error.FileNotFound => return totals,
        else => return err,
    };
    defer manifest.deinit(allocator);

    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(allocator);

    var it = manifest.rules.iterator();
    while (it.next()) |entry| {
        ids.append(allocator, entry.key_ptr.*) catch continue;
    }

    if (ids.items.len == 0) return totals;

    var loaded = workspace_rule.loadRules(allocator, ws_dir, ids.items, &.{}) catch |err| switch (err) {
        error.UnknownRuleId, error.FileNotFound, error.UnsafeCachePath => return totals,
        else => return err,
    };
    defer loaded.deinit(allocator);

    for (loaded.items.items) |rule_item| {
        const content = rule_item.content orelse continue;
        var parsed = workspace_rule.parseConstraints(allocator, content) catch continue;
        defer parsed.deinit(allocator);

        const constraint_total: u16 = @intCast(@min(parsed.constraints.items.len, std.math.maxInt(u16)));
        putRuleConstraintTotal(allocator, &totals, rule_item.id, constraint_total) catch continue;
    }

    return totals;
}

fn mergeRuleConstraintTotals(
    allocator: std.mem.Allocator,
    target: *RuleConstraintTotals,
    source: *const RuleConstraintTotals,
) void {
    var it = source.iterator();
    while (it.next()) |entry| {
        putRuleConstraintTotal(allocator, target, entry.key_ptr.*, entry.value_ptr.*) catch continue;
    }
}

fn putRuleConstraintTotal(
    allocator: std.mem.Allocator,
    totals: *RuleConstraintTotals,
    rule_id: []const u8,
    constraint_total: u16,
) !void {
    if (totals.getPtr(rule_id)) |value_ptr| {
        if (constraint_total > value_ptr.*) value_ptr.* = constraint_total;
        return;
    }

    const key = try allocator.dupe(u8, rule_id);
    errdefer allocator.free(key);
    try totals.put(key, constraint_total);
}

fn deinitRuleConstraintTotals(allocator: std.mem.Allocator, totals: *RuleConstraintTotals) void {
    var key_it = totals.keyIterator();
    while (key_it.next()) |key| allocator.free(key.*);
    totals.deinit();
}

fn computeStats(
    allocator: std.mem.Allocator,
    events: []const AttestationEvent,
    rule_totals: *const RuleConstraintTotals,
) LocalStats {
    var stats: LocalStats = .{};

    const RuleAcc = struct {
        refer_count: u32 = 0,
        constraints: std.StringHashMap(u32),
        constraint_names: std.StringHashMap([]const u8),
    };
    var rule_map: std.StringHashMap(RuleAcc) = .init(allocator);

    var refers_list: std.ArrayList(ReferEvent) = .empty;
    var inputs_list: std.ArrayList(InputEvent) = .empty;

    const now_ms: i64 = @import("clumsies_lib").util.time_util.nowMillis();
    const day_ms: i64 = 86400 * 1000;

    for (events) |ev| {
        if (std.mem.eql(u8, ev.type, "user_prompt")) {
            if (ev.content) |c| {
                inputs_list.append(allocator, .{
                    .ws_id = ev.ws_id,
                    .session_id = ev.session_id,
                    .timestamp = ev.timestamp,
                    .content = c,
                    .model = ev.model,
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

        const pid = ev.rule_id orelse continue;
        const entry = rule_map.getOrPut(pid) catch continue;
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .refer_count = 0,
                .constraints = .init(allocator),
                .constraint_names = .init(allocator),
            };
        }
        entry.value_ptr.refer_count += 1;

        if (ev.constraint_id) |cid| {
            const c_entry = entry.value_ptr.constraints.getOrPut(cid) catch continue;
            if (!c_entry.found_existing) c_entry.value_ptr.* = 0;
            c_entry.value_ptr.* += 1;
            if (ev.constraint_name) |name| {
                entry.value_ptr.constraint_names.put(cid, name) catch {};
            }
        }
    }

    var rules_list: std.ArrayList(data.AnalysisRule) = .empty;
    var total_constraints: u32 = 0;
    var active_constraints: u32 = 0;

    var map_it = rule_map.iterator();
    while (map_it.next()) |kv| {
        const active_count_u32: u32 = @intCast(kv.value_ptr.constraints.count());
        const total_count_u32: u32 = if (rule_totals.get(kv.key_ptr.*)) |count|
            @max(@as(u32, count), active_count_u32)
        else
            active_count_u32;
        const active_count: u8 = @intCast(@min(active_count_u32, 255));
        const total_count: u8 = @intCast(@min(total_count_u32, 255));
        const idle_count: u8 = total_count -| active_count;

        total_constraints += total_count_u32;
        active_constraints += @min(active_count_u32, total_count_u32);

        const sig: u8 = if (total_count_u32 > 0)
            @intCast(@min(@divTrunc(@min(active_count_u32, total_count_u32) * 100, total_count_u32), 100))
        else
            0;

        var constraints_list: std.ArrayList(data.ConstraintStat) = .empty;
        var c_it = kv.value_ptr.constraints.iterator();
        while (c_it.next()) |cv| {
            constraints_list.append(allocator, .{
                .id = cv.key_ptr.*,
                .label = kv.value_ptr.constraint_names.get(cv.key_ptr.*) orelse cv.key_ptr.*,
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

        rules_list.append(allocator, .{
            .name = kv.key_ptr.*,
            .constraint_count = total_count,
            .active_constraint_count = active_count,
            .idle_constraint_count = idle_count,
            .signal_ratio = sig,
            .refer_count = kv.value_ptr.refer_count,
            .trend = .{0} ** 30,
            .constraints = constraints_list.items,
        }) catch continue;
    }

    std.mem.sort(data.AnalysisRule, rules_list.items, {}, struct {
        fn cmp(_: void, a: data.AnalysisRule, b: data.AnalysisRule) bool {
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
    stats.rules = rules_list.items;

    std.mem.sort(InputEvent, inputs_list.items, {}, struct {
        fn cmp(_: void, a: InputEvent, b: InputEvent) bool {
            return a.timestamp > b.timestamp;
        }
    }.cmp);
    stats.inputs = inputs_list.items;
    stats.rounds = buildRounds(allocator, events);

    return stats;
}

fn buildRounds(allocator: std.mem.Allocator, events: []const AttestationEvent) []const RoundEvent {
    const RoundBuilder = struct {
        event: RoundEvent,
        refers: std.ArrayList(RoundRefer) = .empty,
        tools: std.ArrayList(RoundTool) = .empty,
    };

    const ordered = allocator.dupe(AttestationEvent, events) catch return &.{};
    defer allocator.free(ordered);
    sortAttestationEvents(ordered);

    var prompt_sessions: std.StringHashMap(void) = .init(allocator);
    defer deinitStringSet(allocator, &prompt_sessions);

    for (ordered) |ev| {
        if (std.mem.eql(u8, ev.type, "user_prompt")) {
            putStringSetKey(allocator, &prompt_sessions, ev.ws_id, ev.session_id) catch continue;
        }
    }

    var builders: std.ArrayList(RoundBuilder) = .empty;
    var active_rounds: std.StringHashMap(usize) = .init(allocator);
    defer deinitActiveRoundMap(allocator, &active_rounds);
    var missing_prompt_rounds: std.StringHashMap(usize) = .init(allocator);
    defer deinitActiveRoundMap(allocator, &missing_prompt_rounds);

    for (ordered) |ev| {
        if (std.mem.eql(u8, ev.type, "user_prompt")) {
            const content = ev.content orelse continue;
            const index = builders.items.len;
            builders.append(allocator, .{
                .event = .{
                    .ws_id = ev.ws_id,
                    .session_id = ev.session_id,
                    .timestamp = ev.timestamp,
                    .content = content,
                    .model = ev.model,
                },
            }) catch continue;
            putActiveRound(allocator, &active_rounds, ev.ws_id, ev.session_id, index) catch continue;
            continue;
        }

        const key = roundSessionKey(allocator, ev.ws_id, ev.session_id) catch continue;
        defer allocator.free(key);
        const round_index = active_rounds.get(key) orelse blk: {
            if (prompt_sessions.contains(key)) continue;
            const missing_index = missing_prompt_rounds.get(key) orelse createMissingPromptRound(
                allocator,
                &builders,
                &missing_prompt_rounds,
                ev,
            ) catch continue;
            break :blk missing_index;
        };
        if (round_index >= builders.items.len) continue;
        const builder = &builders.items[round_index];

        if (std.mem.eql(u8, ev.type, "load")) {
            builder.event.load_count +|= 1;
            appendRoundTool(allocator, builder, ev);
        } else if (std.mem.eql(u8, ev.type, "refer")) {
            builder.event.refer_count +|= 1;
            appendRoundTool(allocator, builder, ev);
            if (ev.rule_id) |rule_id| {
                if (ev.constraint_id) |constraint_id| {
                    builder.refers.append(allocator, .{
                        .rule_id = rule_id,
                        .constraint_id = constraint_id,
                        .constraint_name = ev.constraint_name,
                        .constraint_text = ev.constraint_text,
                        .reason = ev.reason,
                    }) catch continue;
                }
            }
        } else if (std.mem.eql(u8, ev.type, "agent_report")) {
            builder.event.submit_count +|= 1;
            builder.event.summary = ev.summary;
            appendRoundTool(allocator, builder, ev);
        } else if (std.mem.eql(u8, ev.type, "reject")) {
            builder.event.reject_count +|= 1;
            builder.event.reject_reason = ev.reason;
            appendRoundTool(allocator, builder, ev);
        } else if (isProtocolToolEvent(ev.type)) {
            appendRoundTool(allocator, builder, ev);
        }
    }

    const rounds = allocator.alloc(RoundEvent, builders.items.len) catch return &.{};
    for (builders.items, 0..) |*builder, index| {
        builder.event.refers = builder.refers.items;
        builder.event.tools = builder.tools.items;
        rounds[index] = builder.event;
    }
    std.mem.sort(RoundEvent, rounds, {}, struct {
        fn cmp(_: void, a: RoundEvent, b: RoundEvent) bool {
            return a.timestamp > b.timestamp;
        }
    }.cmp);
    return rounds;
}

fn createMissingPromptRound(
    allocator: std.mem.Allocator,
    builders: anytype,
    missing_prompt_rounds: *std.StringHashMap(usize),
    ev: AttestationEvent,
) !usize {
    const index = builders.items.len;
    try builders.append(allocator, .{
        .event = .{
            .ws_id = ev.ws_id,
            .session_id = ev.session_id,
            .timestamp = ev.timestamp,
            .content = "No user_prompt recorded in this session log.",
            .missing_user_prompt = true,
        },
    });
    try putActiveRound(allocator, missing_prompt_rounds, ev.ws_id, ev.session_id, index);
    return index;
}

fn sortAttestationEvents(events: []AttestationEvent) void {
    std.mem.sort(AttestationEvent, events, {}, struct {
        fn cmp(_: void, a: AttestationEvent, b: AttestationEvent) bool {
            return a.timestamp < b.timestamp;
        }
    }.cmp);
}

fn roundSessionKey(allocator: std.mem.Allocator, ws_id: []const u8, session_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ ws_id, session_id });
}

fn putActiveRound(
    allocator: std.mem.Allocator,
    active_rounds: *std.StringHashMap(usize),
    ws_id: []const u8,
    session_id: []const u8,
    index: usize,
) !void {
    const key = try roundSessionKey(allocator, ws_id, session_id);
    errdefer allocator.free(key);
    if (active_rounds.getPtr(key)) |value_ptr| {
        value_ptr.* = index;
        allocator.free(key);
        return;
    }
    try active_rounds.put(key, index);
}

fn deinitActiveRoundMap(allocator: std.mem.Allocator, active_rounds: *std.StringHashMap(usize)) void {
    var key_it = active_rounds.keyIterator();
    while (key_it.next()) |key| allocator.free(key.*);
    active_rounds.deinit();
}

fn putStringSetKey(
    allocator: std.mem.Allocator,
    set: *std.StringHashMap(void),
    ws_id: []const u8,
    session_id: []const u8,
) !void {
    const key = try roundSessionKey(allocator, ws_id, session_id);
    errdefer allocator.free(key);
    if (set.contains(key)) {
        allocator.free(key);
        return;
    }
    try set.put(key, {});
}

fn deinitStringSet(allocator: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var key_it = set.keyIterator();
    while (key_it.next()) |key| allocator.free(key.*);
    set.deinit();
}

fn appendRoundTool(allocator: std.mem.Allocator, builder: anytype, ev: AttestationEvent) void {
    builder.tools.append(allocator, .{
        .kind = ev.type,
        .timestamp = ev.timestamp,
        .session_id = ev.session_id,
        .rule_id = ev.rule_id,
        .constraint_id = ev.constraint_id,
        .constraint_name = ev.constraint_name,
        .constraint_text = ev.constraint_text,
        .mpf_hash = ev.mpf_hash,
        .mpf_content = ev.mpf_content,
        .mpf_changed = ev.mpf_changed,
        .discover_kind = ev.kind,
        .discover_group = ev.group,
        .discover_query = ev.query,
        .discover_result_count = ev.result_count,
        .discover_result_names = ev.result_names,
        .summary = ev.summary,
        .reason = ev.reason,
        .context_id = ev.context_id,
        .path = ev.path,
        .new_path = ev.new_path,
    }) catch return;
}

fn isProtocolToolEvent(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "setup") or
        std.mem.eql(u8, kind, "discover") or
        std.mem.eql(u8, kind, "search") or
        std.mem.eql(u8, kind, "context_propose_create") or
        std.mem.eql(u8, kind, "context_propose_update") or
        std.mem.eql(u8, kind, "context_propose_rename") or
        std.mem.eql(u8, kind, "context_propose_delete") or
        std.mem.eql(u8, kind, "rule_propose_create") or
        std.mem.eql(u8, kind, "rule_propose_update") or
        std.mem.eql(u8, kind, "rule_propose_rename") or
        std.mem.eql(u8, kind, "rule_propose_delete") or
        std.mem.eql(u8, kind, "mpf_propose_create") or
        std.mem.eql(u8, kind, "mpf_propose_update") or
        std.mem.eql(u8, kind, "mpf_propose_delete") or
        std.mem.eql(u8, kind, "draft_discard");
}

test "computeStats uses rule totals to derive non-100 signal ratios" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = [_]AttestationEvent{
        .{
            .ws_id = "ws-1",
            .session_id = "ses-1",
            .type = "refer",
            .timestamp = @import("clumsies_lib").util.time_util.nowMillis(),
            .rule_id = "p-1",
            .constraint_id = "c-1",
        },
        .{
            .ws_id = "ws-1",
            .session_id = "ses-1",
            .type = "refer",
            .timestamp = @import("clumsies_lib").util.time_util.nowMillis(),
            .rule_id = "p-1",
            .constraint_id = "c-2",
        },
    };

    var totals: RuleConstraintTotals = .init(alloc);
    defer deinitRuleConstraintTotals(alloc, &totals);
    try putRuleConstraintTotal(alloc, &totals, "p-1", 4);

    const stats = computeStats(alloc, &events, &totals);

    try std.testing.expectEqual(@as(u32, 4), stats.constraint_count);
    try std.testing.expectEqual(@as(u32, 2), stats.active_constraint_count);
    try std.testing.expectEqual(@as(u8, 50), stats.signal_ratio);
    try std.testing.expectEqual(@as(u8, 4), stats.rules[0].constraint_count);
    try std.testing.expectEqual(@as(u8, 2), stats.rules[0].active_constraint_count);
    try std.testing.expectEqual(@as(u8, 2), stats.rules[0].idle_constraint_count);
    try std.testing.expectEqual(@as(u8, 50), stats.rules[0].signal_ratio);
}

test "computeStats falls back to active constraint counts when rule totals are unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = [_]AttestationEvent{
        .{
            .ws_id = "ws-1",
            .session_id = "ses-1",
            .type = "refer",
            .timestamp = @import("clumsies_lib").util.time_util.nowMillis(),
            .rule_id = "p-1",
            .constraint_id = "c-1",
        },
    };

    var totals: RuleConstraintTotals = .init(alloc);
    defer deinitRuleConstraintTotals(alloc, &totals);

    const stats = computeStats(alloc, &events, &totals);

    try std.testing.expectEqual(@as(u32, 1), stats.constraint_count);
    try std.testing.expectEqual(@as(u32, 1), stats.active_constraint_count);
    try std.testing.expectEqual(@as(u8, 100), stats.signal_ratio);
}

test "buildRounds groups evidence after each user prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = [_]AttestationEvent{
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "user_prompt", .timestamp = 1000, .content = "first" },
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "discover", .timestamp = 1001 },
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "load", .timestamp = 1002, .rule_id = "p-1", .rule_hash = "h-1" },
        .{
            .ws_id = "ws-1",
            .session_id = "s-1",
            .type = "refer",
            .timestamp = 1003,
            .rule_id = "p-1",
            .constraint_id = "c-1",
            .constraint_name = "Rule loading",
            .constraint_text = "Load the relevant rules before editing.",
            .reason = "used it",
        },
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "agent_report", .timestamp = 1004, .summary = "done" },
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "user_prompt", .timestamp = 2000, .content = "second" },
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "reject", .timestamp = 2001, .reason = "bad" },
    };

    const rounds = buildRounds(alloc, &events);

    try std.testing.expectEqual(@as(usize, 2), rounds.len);
    try std.testing.expectEqualStrings("second", rounds[0].content);
    try std.testing.expectEqual(@as(u16, 1), rounds[0].reject_count);
    try std.testing.expectEqualStrings("bad", rounds[0].reject_reason.?);
    try std.testing.expectEqualStrings("first", rounds[1].content);
    try std.testing.expectEqual(@as(u16, 1), rounds[1].load_count);
    try std.testing.expectEqual(@as(u16, 1), rounds[1].refer_count);
    try std.testing.expectEqual(@as(u16, 1), rounds[1].submit_count);
    try std.testing.expectEqualStrings("done", rounds[1].summary.?);
    try std.testing.expectEqualStrings("p-1", rounds[1].refers[0].rule_id);
    try std.testing.expectEqualStrings("c-1", rounds[1].refers[0].constraint_id);
    try std.testing.expectEqualStrings("Rule loading", rounds[1].refers[0].constraint_name.?);
    try std.testing.expectEqualStrings("Load the relevant rules before editing.", rounds[1].refers[0].constraint_text.?);
    try std.testing.expectEqual(@as(usize, 4), rounds[1].tools.len);
    try std.testing.expectEqualStrings("discover", rounds[1].tools[0].kind);
    try std.testing.expectEqualStrings("load", rounds[1].tools[1].kind);
    try std.testing.expectEqualStrings("refer", rounds[1].tools[2].kind);
    try std.testing.expectEqualStrings("Load the relevant rules before editing.", rounds[1].tools[2].constraint_text.?);
    try std.testing.expectEqualStrings("agent_report", rounds[1].tools[3].kind);
}

test "buildRounds carries user prompt model into round" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = [_]AttestationEvent{
        .{
            .ws_id = "ws-1",
            .session_id = "s-1",
            .type = "user_prompt",
            .timestamp = 1000,
            .content = "ask",
            .model = "gpt-5.5",
        },
    };

    const rounds = buildRounds(alloc, &events);
    try std.testing.expectEqual(@as(usize, 1), rounds.len);
    try std.testing.expect(rounds[0].model != null);
    try std.testing.expectEqualStrings("gpt-5.5", rounds[0].model.?);
}

test "buildRounds attaches tools when merged logs are read out of order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = [_]AttestationEvent{
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "load", .timestamp = 1001, .rule_id = "p-1", .rule_hash = "h-1" },
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "refer", .timestamp = 1002, .rule_id = "p-1", .constraint_id = "c-1" },
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "agent_report", .timestamp = 1003, .summary = "done" },
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "user_prompt", .timestamp = 1000, .content = "ask" },
    };

    const rounds = buildRounds(alloc, &events);

    try std.testing.expectEqual(@as(usize, 1), rounds.len);
    try std.testing.expectEqualStrings("ask", rounds[0].content);
    try std.testing.expectEqual(@as(u16, 1), rounds[0].load_count);
    try std.testing.expectEqual(@as(u16, 1), rounds[0].refer_count);
    try std.testing.expectEqual(@as(u16, 1), rounds[0].submit_count);
    try std.testing.expectEqual(@as(usize, 3), rounds[0].tools.len);
    try std.testing.expectEqualStrings("load", rounds[0].tools[0].kind);
    try std.testing.expectEqualStrings("refer", rounds[0].tools[1].kind);
    try std.testing.expectEqualStrings("agent_report", rounds[0].tools[2].kind);
}

test "buildRounds exposes session activity without user prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = [_]AttestationEvent{
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "load", .timestamp = 1001, .rule_id = "p-1", .rule_hash = "h-1" },
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "refer", .timestamp = 1002, .rule_id = "p-1", .constraint_id = "c-1" },
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "agent_report", .timestamp = 1003, .summary = "done" },
    };

    const rounds = buildRounds(alloc, &events);

    try std.testing.expectEqual(@as(usize, 1), rounds.len);
    try std.testing.expect(rounds[0].missing_user_prompt);
    try std.testing.expectEqualStrings("No user_prompt recorded in this session log.", rounds[0].content);
    try std.testing.expectEqual(@as(u16, 1), rounds[0].load_count);
    try std.testing.expectEqual(@as(u16, 1), rounds[0].refer_count);
    try std.testing.expectEqual(@as(u16, 1), rounds[0].submit_count);
    try std.testing.expectEqual(@as(usize, 3), rounds[0].tools.len);
}

test "buildRounds does not attach protocol tools from a different session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = [_]AttestationEvent{
        .{ .ws_id = "ws-1", .session_id = "user-session", .type = "user_prompt", .timestamp = 1000, .content = "ask" },
        .{ .ws_id = "ws-1", .session_id = "agent-session", .type = "load", .timestamp = 1001, .rule_id = "p-1", .rule_hash = "h-1" },
        .{ .ws_id = "ws-1", .session_id = "agent-session", .type = "refer", .timestamp = 1002, .rule_id = "p-1", .constraint_id = "c-1" },
        .{ .ws_id = "ws-1", .session_id = "agent-session", .type = "agent_report", .timestamp = 1003, .summary = "done" },
    };

    const rounds = buildRounds(alloc, &events);

    try std.testing.expectEqual(@as(usize, 2), rounds.len);
    try std.testing.expect(rounds[0].missing_user_prompt);
    try std.testing.expectEqualStrings("agent-session", rounds[0].session_id);
    try std.testing.expectEqual(@as(usize, 3), rounds[0].tools.len);
    try std.testing.expectEqualStrings("user-session", rounds[1].session_id);
    try std.testing.expectEqualStrings("ask", rounds[1].content);
    try std.testing.expectEqual(@as(u16, 0), rounds[1].load_count);
    try std.testing.expectEqual(@as(u16, 0), rounds[1].refer_count);
    try std.testing.expectEqual(@as(u16, 0), rounds[1].submit_count);
    try std.testing.expectEqual(@as(usize, 0), rounds[1].tools.len);
}

test "buildRounds exposes propose draft metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const events = [_]AttestationEvent{
        .{ .ws_id = "ws-1", .session_id = "s-1", .type = "user_prompt", .timestamp = 1000, .content = "ask" },
        .{
            .ws_id = "ws-1",
            .session_id = "s-1",
            .type = "context_propose_rename",
            .timestamp = 1001,
            .context_id = "ctx-1",
            .path = "old.md",
            .new_path = "new.md",
        },
        .{
            .ws_id = "ws-1",
            .session_id = "s-1",
            .type = "rule_propose_update",
            .timestamp = 1002,
            .rule_id = "p-1",
            .path = "coding/RULE.md",
        },
    };

    const rounds = buildRounds(alloc, &events);

    try std.testing.expectEqual(@as(usize, 1), rounds.len);
    try std.testing.expectEqual(@as(usize, 2), rounds[0].tools.len);
    try std.testing.expectEqualStrings("context_propose_rename", rounds[0].tools[0].kind);
    try std.testing.expectEqualStrings("ctx-1", rounds[0].tools[0].context_id.?);
    try std.testing.expectEqualStrings("old.md", rounds[0].tools[0].path.?);
    try std.testing.expectEqualStrings("new.md", rounds[0].tools[0].new_path.?);
    try std.testing.expectEqualStrings("rule_propose_update", rounds[0].tools[1].kind);
    try std.testing.expectEqualStrings("p-1", rounds[0].tools[1].rule_id.?);
    try std.testing.expectEqualStrings("coding/RULE.md", rounds[0].tools[1].path.?);
}
