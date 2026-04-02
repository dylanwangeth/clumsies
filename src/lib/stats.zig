// Stats engine: aggregation + view rendering for workspace, prompt, diff, and time-bucket scopes.
// Consumes trace data and prompt metadata, produces structured results and pre-rendered text views.

const std = @import("std");
const trace = @import("trace.zig");
const workspace_prompt = @import("workspace_prompt.zig");
const encoding = @import("encoding.zig");

pub const WorkspaceResult = struct {
    stats: trace.WorkspaceStats,

    pub fn deinit(self: *WorkspaceResult, allocator: std.mem.Allocator) void {
        self.stats.deinit(allocator);
    }
};

pub const PromptResult = struct {
    stats: trace.PromptDetailStats,
    constraints: std.ArrayList(workspace_prompt.ParsedConstraint),

    pub fn deinit(self: *PromptResult, allocator: std.mem.Allocator) void {
        self.stats.deinit(allocator);
        for (self.constraints.items) |c| {
            allocator.free(c.id);
            allocator.free(c.text_hash);
        }
        self.constraints.deinit(allocator);
    }
};

pub const DiffResult = struct {
    prompt_id: []const u8,
    old_hash: []const u8,
    new_hash: []const u8,
    old_refers: std.StringHashMap(trace.ConstraintReferAgg),
    new_refers: std.StringHashMap(trace.ConstraintReferAgg),

    pub fn deinit(self: *DiffResult, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt_id);
        allocator.free(self.old_hash);
        allocator.free(self.new_hash);
        deinitReferMap(allocator, &self.old_refers);
        deinitReferMap(allocator, &self.new_refers);
    }

    fn deinitReferMap(allocator: std.mem.Allocator, map: *std.StringHashMap(trace.ConstraintReferAgg)) void {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            allocator.free(@constCast(entry.key_ptr.*));
        }
        map.deinit();
    }
};

pub const TimeBucketsResult = struct {
    prompt_id: []const u8,
    time_buckets: []const u8,
    total_constraints: usize,
    bucket_order: std.ArrayList([]const u8),
    cumulative_coverage: std.StringArrayHashMap(f64),
    bucket_refer_count: std.StringArrayHashMap(usize),

    pub fn deinit(self: *TimeBucketsResult, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt_id);
        for (self.bucket_order.items) |b| allocator.free(b);
        self.bucket_order.deinit(allocator);
        self.cumulative_coverage.deinit();
        self.bucket_refer_count.deinit();
    }
};

// Aggregation

pub fn computeWorkspace(allocator: std.mem.Allocator, workspace_root: []const u8) !WorkspaceResult {
    return .{ .stats = try trace.computeWorkspaceStats(allocator, workspace_root) };
}

pub fn computePrompt(allocator: std.mem.Allocator, workspace_root: []const u8, prompt_id: []const u8) !PromptResult {
    var stats = try trace.computePromptStats(allocator, workspace_root, prompt_id);
    errdefer stats.deinit(allocator);

    var all_constraints: std.ArrayList(workspace_prompt.ParsedConstraint) = .empty;
    errdefer {
        for (all_constraints.items) |c| {
            allocator.free(c.id);
            allocator.free(c.text_hash);
        }
        all_constraints.deinit(allocator);
    }

    blk: {
        var inventory = workspace_prompt.discoverAll(allocator, workspace_root) catch break :blk;
        defer workspace_prompt.deinitPromptItems(allocator, &inventory);

        for (inventory.items) |item| {
            if (std.mem.eql(u8, item.id, prompt_id)) {
                if (item.kind == .rule or item.kind == .workflow) {
                    var load_result = workspace_prompt.loadPrompts(allocator, workspace_root, &.{prompt_id}, &.{}) catch break :blk;
                    defer load_result.deinit(allocator);
                    if (load_result.items.items.len > 0) {
                        if (load_result.items.items[0].content) |file_content| {
                            var parsed = workspace_prompt.parseConstraints(allocator, file_content) catch break :blk;
                            all_constraints = parsed.constraints;
                            parsed.constraints = .empty;
                            for (parsed.issues.items) |issue| allocator.free(issue);
                            parsed.issues.deinit(allocator);
                        }
                    }
                }
                break;
            }
        }
    }

    return .{ .stats = stats, .constraints = all_constraints };
}

pub fn computeDiff(allocator: std.mem.Allocator, workspace_root: []const u8, prompt_id: []const u8, old_hash: []const u8, new_hash: []const u8) !DiffResult {
    var old_refers = try trace.computeReferCountsByConstraint(allocator, workspace_root, prompt_id, old_hash);
    errdefer {
        var iter = old_refers.iterator();
        while (iter.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
        old_refers.deinit();
    }

    var new_refers = try trace.computeReferCountsByConstraint(allocator, workspace_root, prompt_id, new_hash);
    errdefer {
        var iter = new_refers.iterator();
        while (iter.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
        new_refers.deinit();
    }

    return .{
        .prompt_id = try allocator.dupe(u8, prompt_id),
        .old_hash = try allocator.dupe(u8, old_hash),
        .new_hash = try allocator.dupe(u8, new_hash),
        .old_refers = old_refers,
        .new_refers = new_refers,
    };
}

pub fn computeTimeBuckets(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    prompt_id: []const u8,
    time_buckets: []const u8,
) !TimeBucketsResult {
    const is_daily = std.mem.eql(u8, time_buckets, "daily");

    var total_constraints: usize = 0;
    blk: {
        var inventory = workspace_prompt.discoverAll(allocator, workspace_root) catch break :blk;
        defer workspace_prompt.deinitPromptItems(allocator, &inventory);
        for (inventory.items) |item| {
            if (std.mem.eql(u8, item.id, prompt_id)) {
                if (item.kind == .rule or item.kind == .workflow) {
                    var load_result = workspace_prompt.loadPrompts(allocator, workspace_root, &.{prompt_id}, &.{}) catch break :blk;
                    defer load_result.deinit(allocator);
                    if (load_result.items.items.len > 0) {
                        if (load_result.items.items[0].content) |content| {
                            var parsed = workspace_prompt.parseConstraints(allocator, content) catch break :blk;
                            total_constraints = parsed.constraints.items.len;
                            parsed.deinit(allocator);
                        }
                    }
                }
                break;
            }
        }
    }

    var events = try trace.collectReferEvents(allocator, workspace_root, prompt_id);
    defer {
        for (events.items) |e| {
            allocator.free(e.constraint_id);
        }
        events.deinit(allocator);
    }

    std.mem.sort(trace.ReferEvent, events.items, {}, struct {
        fn lessThan(_: void, a: trace.ReferEvent, b: trace.ReferEvent) bool {
            return a.timestamp < b.timestamp;
        }
    }.lessThan);

    var bucket_order: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (bucket_order.items) |b| allocator.free(b);
        bucket_order.deinit(allocator);
    }

    var seen_constraints = std.StringHashMap(void).init(allocator);
    defer {
        var iter = seen_constraints.keyIterator();
        while (iter.next()) |key| allocator.free(@constCast(key.*));
        seen_constraints.deinit();
    }

    var bucket_refer_count: std.StringArrayHashMap(usize) = .init(allocator);
    errdefer bucket_refer_count.deinit();

    var cumulative_coverage: std.StringArrayHashMap(f64) = .init(allocator);
    errdefer cumulative_coverage.deinit();

    for (events.items) |event| {
        const date_key = if (is_daily)
            try trace.msToDateStr(allocator, event.timestamp)
        else
            try trace.msToWeekStr(allocator, event.timestamp);

        if (!bucket_refer_count.contains(date_key)) {
            try bucket_order.append(allocator, try allocator.dupe(u8, date_key));
            try bucket_refer_count.put(date_key, 0);
        }

        if (!seen_constraints.contains(event.constraint_id)) {
            try seen_constraints.put(try allocator.dupe(u8, event.constraint_id), {});
        }

        const count_ptr = bucket_refer_count.getPtr(date_key).?;
        count_ptr.* += 1;

        const coverage: f64 = if (total_constraints > 0)
            @as(f64, @floatFromInt(seen_constraints.count())) / @as(f64, @floatFromInt(total_constraints))
        else
            0.0;
        try cumulative_coverage.put(date_key, coverage);

        allocator.free(date_key);
    }

    return .{
        .prompt_id = try allocator.dupe(u8, prompt_id),
        .time_buckets = time_buckets,
        .total_constraints = total_constraints,
        .bucket_order = bucket_order,
        .cumulative_coverage = cumulative_coverage,
        .bucket_refer_count = bucket_refer_count,
    };
}

// View rendering

pub fn renderWorkspaceView(allocator: std.mem.Allocator, result: *const WorkspaceResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "Prompt                                    Refers\n");
    try buf.appendSlice(allocator, "──────────────────────────────────────────────────\n");

    var iter = result.stats.prompts.iterator();
    while (iter.next()) |entry| {
        const ps = entry.value_ptr;
        try buf.writer(allocator).print("{s: <42}{d: >6}\n", .{
            ps.id,
            ps.refer_count,
        });
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn renderPromptView(allocator: std.mem.Allocator, result: *const PromptResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.writer(allocator).print("{s}\n", .{result.stats.prompt_id});
    try buf.appendSlice(allocator, "──────────────────────────────────────────────────────────\n");

    if (result.constraints.items.len > 0) {
        var cold_count: usize = 0;
        for (result.constraints.items) |c| {
            const cs = result.stats.constraints.get(c.id);
            const refer_count = if (cs) |s| s.refer_count else 0;

            const label: []const u8 = if (refer_count == 0)
                "  <- unused"
            else
                "";

            if (refer_count == 0) {
                cold_count += 1;
            }

            try buf.writer(allocator).print("{s: <20} {d: >4} refers{s}\n", .{
                c.id, refer_count, label,
            });
        }
        if (cold_count > 0) {
            try buf.writer(allocator).print("\n{d} out of {d} constraints are unused.\n", .{ cold_count, result.constraints.items.len });
        }
    } else {
        var iter = result.stats.constraints.iterator();
        while (iter.next()) |entry| {
            const cs = entry.value_ptr;
            try buf.writer(allocator).print("{s: <20} {d: >4} refers\n", .{
                cs.constraint_id, cs.refer_count,
            });
        }
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn renderDiffView(allocator: std.mem.Allocator, result: *const DiffResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.writer(allocator).print("{s}  {s} -> {s}\n", .{
        result.prompt_id,
        result.old_hash[0..@min(7, result.old_hash.len)],
        result.new_hash[0..@min(7, result.new_hash.len)],
    });
    try buf.appendSlice(allocator, "─────────────────────────────────────────────────────\n");

    // Matched
    {
        var iter = result.old_refers.iterator();
        while (iter.next()) |entry| {
            const new_entry = result.new_refers.get(entry.key_ptr.*) orelse continue;
            try buf.writer(allocator).print("  {s: <20} {d} -> {d}  (stable)\n", .{
                entry.key_ptr.*,
                entry.value_ptr.refer_count,
                new_entry.refer_count,
            });
        }
    }
    // Old only
    {
        var iter = result.old_refers.iterator();
        while (iter.next()) |entry| {
            if (result.new_refers.contains(entry.key_ptr.*)) continue;
            try buf.writer(allocator).print("- {s: <20} {d}  (removed)\n", .{
                entry.key_ptr.*,
                entry.value_ptr.refer_count,
            });
        }
    }
    // New only
    {
        var iter = result.new_refers.iterator();
        while (iter.next()) |entry| {
            if (result.old_refers.contains(entry.key_ptr.*)) continue;
            try buf.writer(allocator).print("+ {s: <20} {d}  (new)\n", .{
                entry.key_ptr.*,
                entry.value_ptr.refer_count,
            });
        }
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn renderTimeBucketsView(allocator: std.mem.Allocator, result: *const TimeBucketsResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.writer(allocator).print("{s}  coverage over time ({s})\n", .{ result.prompt_id, result.time_buckets });
    try buf.appendSlice(allocator, "──────────────────────────────────────────────────────────\n");
    try buf.appendSlice(allocator, "Date              Coverage  Refers\n");

    for (result.bucket_order.items) |bucket| {
        const coverage = result.cumulative_coverage.get(bucket) orelse 0.0;
        const refers = result.bucket_refer_count.get(bucket) orelse 0;
        const pct: usize = @intFromFloat(coverage * 100.0);
        try buf.writer(allocator).print("{s: <18}{d: >3}%      {d: >3}\n", .{ bucket, pct, refers });
    }

    return try buf.toOwnedSlice(allocator);
}

// JSON serialization (for MCP structured data response)

pub fn renderWorkspaceDataJson(allocator: std.mem.Allocator, result: *const WorkspaceResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"prompts\":[");
    var iter = result.stats.prompts.iterator();
    var first = true;
    while (iter.next()) |entry| {
        if (!first) try buf.append(allocator, ',');
        first = false;

        const ps = entry.value_ptr;
        const esc_id = try encoding.jsonEscapeAlloc(allocator, ps.id);
        defer allocator.free(esc_id);

        try buf.writer(allocator).print(
            "{{\"id\":\"{s}\",\"totalRefers\":{d}}}",
            .{ esc_id, ps.refer_count },
        );
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

pub fn renderPromptDataJson(allocator: std.mem.Allocator, result: *const PromptResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const esc_pid = try encoding.jsonEscapeAlloc(allocator, result.stats.prompt_id);
    defer allocator.free(esc_pid);

    try buf.writer(allocator).print("{{\"id\":\"{s}\",\"hash\":", .{esc_pid});
    if (result.stats.prompt_hash) |h| {
        try buf.writer(allocator).print("\"{s}\"", .{h});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"constraints\":[");

    if (result.constraints.items.len > 0) {
        for (result.constraints.items, 0..) |c, idx| {
            if (idx > 0) try buf.append(allocator, ',');
            const esc_cid = try encoding.jsonEscapeAlloc(allocator, c.id);
            defer allocator.free(esc_cid);

            const cs = result.stats.constraints.get(c.id);
            const refer_count = if (cs) |s| s.refer_count else 0;

            try buf.writer(allocator).print(
                "{{\"constraintId\":\"{s}\",\"referCount\":{d}}}",
                .{ esc_cid, refer_count },
            );
        }
    } else {
        var iter = result.stats.constraints.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try buf.append(allocator, ',');
            first = false;
            const cs = entry.value_ptr;
            const esc_cid = try encoding.jsonEscapeAlloc(allocator, cs.constraint_id);
            defer allocator.free(esc_cid);
            try buf.writer(allocator).print(
                "{{\"constraintId\":\"{s}\",\"referCount\":{d}}}",
                .{ esc_cid, cs.refer_count },
            );
        }
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

pub fn renderDiffDataJson(allocator: std.mem.Allocator, result: *const DiffResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const esc_pid = try encoding.jsonEscapeAlloc(allocator, result.prompt_id);
    defer allocator.free(esc_pid);
    const esc_old = try encoding.jsonEscapeAlloc(allocator, result.old_hash);
    defer allocator.free(esc_old);
    const esc_new = try encoding.jsonEscapeAlloc(allocator, result.new_hash);
    defer allocator.free(esc_new);

    try buf.writer(allocator).print(
        "{{\"promptId\":\"{s}\",\"oldHash\":\"{s}\",\"newHash\":\"{s}\"",
        .{ esc_pid, esc_old, esc_new },
    );

    // old_only
    try buf.appendSlice(allocator, ",\"oldOnly\":[");
    {
        var iter = result.old_refers.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (result.new_refers.contains(entry.key_ptr.*)) continue;
            if (!first) try buf.append(allocator, ',');
            first = false;
            const esc_cid = try encoding.jsonEscapeAlloc(allocator, entry.key_ptr.*);
            defer allocator.free(esc_cid);
            try buf.writer(allocator).print(
                "{{\"constraintId\":\"{s}\",\"referCount\":{d}}}",
                .{ esc_cid, entry.value_ptr.refer_count },
            );
        }
    }
    // new_only
    try buf.appendSlice(allocator, "],\"newOnly\":[");
    {
        var iter = result.new_refers.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (result.old_refers.contains(entry.key_ptr.*)) continue;
            if (!first) try buf.append(allocator, ',');
            first = false;
            const esc_cid = try encoding.jsonEscapeAlloc(allocator, entry.key_ptr.*);
            defer allocator.free(esc_cid);
            try buf.writer(allocator).print(
                "{{\"constraintId\":\"{s}\",\"referCount\":{d}}}",
                .{ esc_cid, entry.value_ptr.refer_count },
            );
        }
    }
    // matched
    try buf.appendSlice(allocator, "],\"matched\":[");
    {
        var iter = result.old_refers.iterator();
        var first = true;
        while (iter.next()) |entry| {
            const new_entry = result.new_refers.get(entry.key_ptr.*) orelse continue;
            if (!first) try buf.append(allocator, ',');
            first = false;
            const esc_cid = try encoding.jsonEscapeAlloc(allocator, entry.key_ptr.*);
            defer allocator.free(esc_cid);
            try buf.writer(allocator).print(
                "{{\"constraintId\":\"{s}\",\"oldReferCount\":{d},\"newReferCount\":{d}}}",
                .{ esc_cid, entry.value_ptr.refer_count, new_entry.refer_count },
            );
        }
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

pub fn renderTimeBucketsDataJson(allocator: std.mem.Allocator, result: *const TimeBucketsResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const esc_pid = try encoding.jsonEscapeAlloc(allocator, result.prompt_id);
    defer allocator.free(esc_pid);

    try buf.writer(allocator).print("{{\"id\":\"{s}\",\"coverageOverTime\":[", .{esc_pid});

    for (result.bucket_order.items, 0..) |bucket, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const esc_date = try encoding.jsonEscapeAlloc(allocator, bucket);
        defer allocator.free(esc_date);
        const coverage = result.cumulative_coverage.get(bucket) orelse 0.0;
        const refers = result.bucket_refer_count.get(bucket) orelse 0;
        try buf.writer(allocator).print(
            "{{\"date\":\"{s}\",\"coverageRatio\":{d:.2},\"refers\":{d}}}",
            .{ esc_date, coverage, refers },
        );
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}
