const std = @import("std");
const testing = std.testing;
const encoding = @import("encoding.zig");

pub const CLUMSIES_DIR = ".clumsies";

pub const EventType = enum {
    setup,
    begin,
    search,
    load,
    refer,
    shortcut,
    complete,
};

pub const TraceEvent = struct {
    event_type: EventType,
    task_id: ?[]const u8 = null,

    // setup fields
    synced_count: ?usize = null,

    // begin fields
    goal_summary: ?[]const u8 = null,

    // load fields
    prompt_id: ?[]const u8 = null,
    prompt_hash: ?[]const u8 = null,

    // refer fields
    constraint_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,

    // shortcut fields
    workflow_name: ?[]const u8 = null,

    // complete fields
    status: ?[]const u8 = null,
};

pub const TaskStatus = enum {
    in_progress,
    completed,
    abandoned,
};

pub const TaskInfo = struct {
    task_id: []const u8,
    workspace_id: []const u8,
    goal_summary: []const u8,
    status: TaskStatus,
};

/// Generate a workspace_id from workspace root path.
pub fn workspaceId(allocator: std.mem.Allocator, workspace_root: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(workspace_root);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    var hex: [64]u8 = undefined;
    encoding.hexEncode(&hash, &hex);
    return try std.fmt.allocPrint(allocator, "ws-{s}", .{hex[0..16]});
}

/// Get the trace file path: .clumsies/{workspace_id}.jsonl
pub fn traceFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]const u8 {
    const ws_id = try workspaceId(allocator, workspace_root);
    defer allocator.free(ws_id);
    const filename = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{ws_id});
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &.{ workspace_root, CLUMSIES_DIR, filename });
}

/// Generate a unique task_id.
pub fn generateTaskId(allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.time.milliTimestamp();
    var rand_buf: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    var rand_hex: [8]u8 = undefined;
    encoding.hexEncode(rand_buf[0..4], rand_hex[0..8]);
    return try std.fmt.allocPrint(allocator, "task-{d}-{s}", .{ ts, rand_hex[0..8] });
}

/// Ensure .clumsies/ directory exists.
pub fn ensureClumsiesDir(workspace_root: []const u8, allocator: std.mem.Allocator) !void {
    const clumsies_path = try std.fs.path.join(allocator, &.{ workspace_root, CLUMSIES_DIR });
    defer allocator.free(clumsies_path);

    std.fs.makeDirAbsolute(clumsies_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Check if a task has been finalized (completed or abandoned).
pub fn isTaskFinalized(allocator: std.mem.Allocator, workspace_root: []const u8, task_id: []const u8) !bool {
    const trace_path = try traceFilePath(allocator, workspace_root);
    defer allocator.free(trace_path);

    const file = std.fs.openFileAbsolute(trace_path, .{}) catch return false;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const evt_type = getStr(obj, "type") orelse continue;
        if (!std.mem.eql(u8, evt_type, "complete")) continue;

        const tid = getStr(obj, "task_id") orelse continue;
        if (std.mem.eql(u8, tid, task_id)) return true;
    }

    return false;
}

/// Append a trace event to trace.jsonl.
pub fn appendTraceEvent(allocator: std.mem.Allocator, workspace_root: []const u8, event: TraceEvent) !void {
    try ensureClumsiesDir(workspace_root, allocator);

    const trace_path = try traceFilePath(allocator, workspace_root);
    defer allocator.free(trace_path);

    var file = try std.fs.createFileAbsolute(trace_path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);

    const line = try serializeTraceEvent(allocator, event);
    defer allocator.free(line);

    try file.writeAll(line);
}

fn serializeTraceEvent(allocator: std.mem.Allocator, event: TraceEvent) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const ts = std.time.milliTimestamp();
    const type_str = @tagName(event.event_type);

    try buf.writer(allocator).print("{{\"type\":\"{s}\",\"ts\":{d}", .{ type_str, ts });

    if (event.task_id) |tid| {
        const esc = try encoding.jsonEscapeAlloc(allocator, tid);
        defer allocator.free(esc);
        try buf.writer(allocator).print(",\"task_id\":\"{s}\"", .{esc});
    }

    // Type-specific fields
    switch (event.event_type) {
        .setup => {
            if (event.synced_count) |count| {
                try buf.writer(allocator).print(",\"synced_count\":{d}", .{count});
            }
        },
        .begin => {
            if (event.goal_summary) |gs| {
                const esc = try encoding.jsonEscapeAlloc(allocator, gs);
                defer allocator.free(esc);
                try buf.writer(allocator).print(",\"goal_summary\":\"{s}\"", .{esc});
            }
        },
        .load => {
            if (event.prompt_id) |pid| {
                const esc = try encoding.jsonEscapeAlloc(allocator, pid);
                defer allocator.free(esc);
                try buf.writer(allocator).print(",\"prompt_id\":\"{s}\"", .{esc});
            }
            if (event.prompt_hash) |ph| {
                try buf.writer(allocator).print(",\"prompt_hash\":\"{s}\"", .{ph});
            }
        },
        .refer => {
            if (event.prompt_id) |pid| {
                const esc = try encoding.jsonEscapeAlloc(allocator, pid);
                defer allocator.free(esc);
                try buf.writer(allocator).print(",\"prompt_id\":\"{s}\"", .{esc});
            }
            if (event.prompt_hash) |ph| {
                try buf.writer(allocator).print(",\"prompt_hash\":\"{s}\"", .{ph});
            }
            if (event.constraint_id) |cid| {
                const esc = try encoding.jsonEscapeAlloc(allocator, cid);
                defer allocator.free(esc);
                try buf.writer(allocator).print(",\"constraint_id\":\"{s}\"", .{esc});
            }
            if (event.reason) |r| {
                const esc = try encoding.jsonEscapeAlloc(allocator, r);
                defer allocator.free(esc);
                try buf.writer(allocator).print(",\"reason\":\"{s}\"", .{esc});
            }
        },
        .shortcut => {
            if (event.workflow_name) |wn| {
                const esc = try encoding.jsonEscapeAlloc(allocator, wn);
                defer allocator.free(esc);
                try buf.writer(allocator).print(",\"workflow\":\"{s}\"", .{esc});
            }
        },
        .complete => {
            if (event.status) |s| {
                try buf.writer(allocator).print(",\"status\":\"{s}\"", .{s});
            }
        },
        .search => {},
    }

    try buf.appendSlice(allocator, "}\n");
    return try buf.toOwnedSlice(allocator);
}

// Stats: read and aggregate trace

pub const PromptStats = struct {
    id: []const u8,
    refer_count: usize = 0,
    completed_tasks: usize = 0,
    abandoned_tasks: usize = 0,
    task_set: std.StringHashMap([]const u8), // task_id → status
};

pub const WorkspaceStats = struct {
    prompts: std.StringArrayHashMap(PromptStats),

    pub fn deinit(self: *WorkspaceStats, allocator: std.mem.Allocator) void {
        var iter = self.prompts.iterator();
        while (iter.next()) |entry| {
            var ps = entry.value_ptr;
            allocator.free(ps.id);
            var ts_iter = ps.task_set.iterator();
            while (ts_iter.next()) |ts_entry| {
                allocator.free(@constCast(ts_entry.key_ptr.*));
                allocator.free(ts_entry.value_ptr.*);
            }
            ps.task_set.deinit();
        }
        self.prompts.deinit();
    }
};

pub fn computeWorkspaceStats(allocator: std.mem.Allocator, workspace_root: []const u8) !WorkspaceStats {
    var stats: WorkspaceStats = .{ .prompts = .init(allocator) };
    errdefer stats.deinit(allocator);

    const trace_path = try traceFilePath(allocator, workspace_root);
    defer allocator.free(trace_path);

    const file = std.fs.openFileAbsolute(trace_path, .{}) catch return stats;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(content);

    // Build task_id → status map from complete events
    var task_status = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = task_status.iterator();
        while (iter.next()) |entry| {
            allocator.free(@constCast(entry.key_ptr.*));
            allocator.free(entry.value_ptr.*);
        }
        task_status.deinit();
    }

    // First pass: collect task statuses
    var lines1 = std.mem.splitScalar(u8, content, '\n');
    while (lines1.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const evt_type = getStr(obj, "type") orelse continue;
        if (!std.mem.eql(u8, evt_type, "complete")) continue;

        const tid = getStr(obj, "task_id") orelse continue;
        const status = getStr(obj, "status") orelse continue;

        const key = try allocator.dupe(u8, tid);
        errdefer allocator.free(key);
        const val = try allocator.dupe(u8, status);
        errdefer allocator.free(val);

        if (try task_status.fetchPut(key, val)) |old| {
            allocator.free(@constCast(old.key));
            allocator.free(old.value);
        }
    }

    // Second pass: aggregate refer events
    var lines2 = std.mem.splitScalar(u8, content, '\n');
    while (lines2.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const evt_type = getStr(obj, "type") orelse continue;
        if (!std.mem.eql(u8, evt_type, "refer")) continue;

        const pid = getStr(obj, "prompt_id") orelse continue;
        const tid = getStr(obj, "task_id") orelse continue;

        const gop = try stats.prompts.getOrPut(pid);
        if (!gop.found_existing) {
            const owned_key = try allocator.dupe(u8, pid);
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{
                .id = owned_key,
                .task_set = .init(allocator),
            };
        }
        gop.value_ptr.refer_count += 1;

        // Track unique tasks per prompt
        if (!gop.value_ptr.task_set.contains(tid)) {
            const ts_key = try allocator.dupe(u8, tid);
            errdefer allocator.free(ts_key);

            const task_st = task_status.get(tid) orelse "in_progress";
            const ts_val = try allocator.dupe(u8, task_st);
            errdefer allocator.free(ts_val);

            try gop.value_ptr.task_set.put(ts_key, ts_val);

            if (std.mem.eql(u8, task_st, "completed")) {
                gop.value_ptr.completed_tasks += 1;
            } else if (std.mem.eql(u8, task_st, "abandoned")) {
                gop.value_ptr.abandoned_tasks += 1;
            }
        }
    }

    return stats;
}

// Per-constraint stats for prompt scope

pub const ConstraintStats = struct {
    constraint_id: []const u8,
    refer_count: usize = 0,
    task_count: usize = 0,
    last_referred_at: ?i64 = null,
    task_set: std.StringHashMap(void),
};

pub const PromptDetailStats = struct {
    prompt_id: []const u8,
    prompt_hash: ?[]const u8,
    total_tasks: usize = 0,
    constraints: std.StringArrayHashMap(ConstraintStats),
    // task_id → (status, timestamp) for heatmap columns
    task_ids: std.ArrayList([]const u8),

    pub fn deinit(self: *PromptDetailStats, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt_id);
        if (self.prompt_hash) |h| allocator.free(h);
        var iter = self.constraints.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.constraint_id);
            var ts_iter = entry.value_ptr.task_set.keyIterator();
            while (ts_iter.next()) |key| allocator.free(@constCast(key.*));
            entry.value_ptr.task_set.deinit();
        }
        self.constraints.deinit();
        for (self.task_ids.items) |tid| allocator.free(tid);
        self.task_ids.deinit(allocator);
    }
};

pub fn computePromptStats(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    prompt_id: []const u8,
    task_id_filter: ?[]const u8,
) !PromptDetailStats {
    var stats: PromptDetailStats = .{
        .prompt_id = try allocator.dupe(u8, prompt_id),
        .prompt_hash = null,
        .constraints = .init(allocator),
        .task_ids = .empty,
    };
    errdefer stats.deinit(allocator);

    const trace_path = try traceFilePath(allocator, workspace_root);
    defer allocator.free(trace_path);

    const file = std.fs.openFileAbsolute(trace_path, .{}) catch return stats;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(content);

    // Collect task statuses (only count finalized tasks)
    var finalized_tasks = std.StringHashMap(void).init(allocator);
    defer {
        var iter = finalized_tasks.keyIterator();
        while (iter.next()) |key| allocator.free(@constCast(key.*));
        finalized_tasks.deinit();
    }

    var lines1 = std.mem.splitScalar(u8, content, '\n');
    while (lines1.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const evt_type = getStr(obj, "type") orelse continue;
        if (!std.mem.eql(u8, evt_type, "complete")) continue;
        const tid = getStr(obj, "task_id") orelse continue;
        if (!finalized_tasks.contains(tid)) {
            const key = try allocator.dupe(u8, tid);
            try finalized_tasks.put(key, {});
        }
    }

    // Collect unique task_ids that have refer events for this prompt
    var seen_tasks = std.StringHashMap(void).init(allocator);
    defer {
        var iter = seen_tasks.keyIterator();
        while (iter.next()) |key| allocator.free(@constCast(key.*));
        seen_tasks.deinit();
    }

    // Aggregate refer events for this prompt
    var lines2 = std.mem.splitScalar(u8, content, '\n');
    while (lines2.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const evt_type = getStr(obj, "type") orelse continue;
        if (!std.mem.eql(u8, evt_type, "refer")) continue;

        const pid = getStr(obj, "prompt_id") orelse continue;
        if (!std.mem.eql(u8, pid, prompt_id)) continue;

        const tid = getStr(obj, "task_id") orelse continue;
        if (task_id_filter) |filter| {
            if (!std.mem.eql(u8, tid, filter)) continue;
        }

        // Only count finalized tasks
        if (!finalized_tasks.contains(tid)) continue;

        const cid = getStr(obj, "constraint_id") orelse continue;
        const ph = getStr(obj, "prompt_hash");

        // Capture prompt_hash from first event
        if (stats.prompt_hash == null and ph != null) {
            stats.prompt_hash = try allocator.dupe(u8, ph.?);
        }

        const ts_val: ?i64 = if (obj.get("ts")) |ts_json| switch (ts_json) {
            .integer => |i| i,
            else => null,
        } else null;

        // Track task for heatmap columns
        if (!seen_tasks.contains(tid)) {
            const key = try allocator.dupe(u8, tid);
            try seen_tasks.put(key, {});
            try stats.task_ids.append(allocator, try allocator.dupe(u8, tid));
        }

        // Update constraint stats
        const gop = try stats.constraints.getOrPut(cid);
        if (!gop.found_existing) {
            const owned_cid = try allocator.dupe(u8, cid);
            gop.key_ptr.* = owned_cid;
            gop.value_ptr.* = .{
                .constraint_id = owned_cid,
                .task_set = .init(allocator),
            };
        }
        gop.value_ptr.refer_count += 1;

        if (ts_val) |ts| {
            if (gop.value_ptr.last_referred_at == null or ts > gop.value_ptr.last_referred_at.?) {
                gop.value_ptr.last_referred_at = ts;
            }
        }

        if (!gop.value_ptr.task_set.contains(tid)) {
            const ts_key = try allocator.dupe(u8, tid);
            try gop.value_ptr.task_set.put(ts_key, {});
            gop.value_ptr.task_count += 1;
        }
    }

    stats.total_tasks = stats.task_ids.items.len;
    return stats;
}

// Diff scope stats

pub const DiffConstraintStats = struct {
    constraint_id: []const u8,
    text_hash: []const u8,
    refer_count: usize,
    task_count: usize,
};

pub const DiffMatchedStats = struct {
    old_constraint_id: []const u8,
    new_constraint_id: []const u8,
    text_hash: []const u8,
    old_refer_count: usize,
    old_task_count: usize,
    new_refer_count: usize,
    new_task_count: usize,
};

pub const PromptDiffStats = struct {
    prompt_id: []const u8,
    old_hash: []const u8,
    new_hash: []const u8,
    old_only: std.ArrayList(DiffConstraintStats),
    new_only: std.ArrayList(DiffConstraintStats),
    matched: std.ArrayList(DiffMatchedStats),

    pub fn deinit(self: *PromptDiffStats, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt_id);
        allocator.free(self.old_hash);
        allocator.free(self.new_hash);
        for (self.old_only.items) |item| {
            allocator.free(item.constraint_id);
            allocator.free(item.text_hash);
        }
        self.old_only.deinit(allocator);
        for (self.new_only.items) |item| {
            allocator.free(item.constraint_id);
            allocator.free(item.text_hash);
        }
        self.new_only.deinit(allocator);
        for (self.matched.items) |item| {
            allocator.free(item.old_constraint_id);
            allocator.free(item.new_constraint_id);
            allocator.free(item.text_hash);
        }
        self.matched.deinit(allocator);
    }
};

/// Aggregate refer counts for a specific prompt_id + prompt_hash, grouped by constraint_id.
pub fn computeReferCountsByConstraint(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    prompt_id: []const u8,
    prompt_hash: []const u8,
) !std.StringHashMap(ConstraintReferAgg) {
    var result = std.StringHashMap(ConstraintReferAgg).init(allocator);
    errdefer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(@constCast(entry.key_ptr.*));
            var ts_iter = entry.value_ptr.task_set.keyIterator();
            while (ts_iter.next()) |key| allocator.free(@constCast(key.*));
            entry.value_ptr.task_set.deinit();
        }
        result.deinit();
    }

    const trace_path = try traceFilePath(allocator, workspace_root);
    defer allocator.free(trace_path);

    const file = std.fs.openFileAbsolute(trace_path, .{}) catch return result;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const evt_type = getStr(obj, "type") orelse continue;
        if (!std.mem.eql(u8, evt_type, "refer")) continue;

        const pid = getStr(obj, "prompt_id") orelse continue;
        if (!std.mem.eql(u8, pid, prompt_id)) continue;

        const ph = getStr(obj, "prompt_hash") orelse continue;
        if (!std.mem.eql(u8, ph, prompt_hash)) continue;

        const cid = getStr(obj, "constraint_id") orelse continue;
        const tid = getStr(obj, "task_id") orelse continue;

        const gop = try result.getOrPut(cid);
        if (!gop.found_existing) {
            const owned_key = try allocator.dupe(u8, cid);
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{
                .refer_count = 0,
                .task_set = .init(allocator),
            };
        }
        gop.value_ptr.refer_count += 1;

        if (!gop.value_ptr.task_set.contains(tid)) {
            const ts_key = try allocator.dupe(u8, tid);
            try gop.value_ptr.task_set.put(ts_key, {});
        }
    }

    return result;
}

pub const ConstraintReferAgg = struct {
    refer_count: usize,
    task_set: std.StringHashMap(void),
};

// TimeBuckets stats

pub const TimeBucket = struct {
    date: []const u8, // "YYYY-MM-DD" or "YYYY-Www"
    coverage_ratio: f64,
    tasks: usize,
};

pub const TimeBucketResult = struct {
    prompt_id: []const u8,
    prompt_hash: ?[]const u8,
    buckets: std.ArrayList(TimeBucket),

    pub fn deinit(self: *TimeBucketResult, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt_id);
        if (self.prompt_hash) |h| allocator.free(h);
        for (self.buckets.items) |b| allocator.free(b.date);
        self.buckets.deinit(allocator);
    }
};

pub const TimeBucketMode = enum {
    daily,
    weekly,
};

pub const ReferEvent = struct {
    timestamp: i64,
    constraint_id: []const u8,
    task_id: []const u8,
};

/// Collect all refer events for a specific prompt, optionally filtered by task_id.
pub fn collectReferEvents(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    prompt_id: []const u8,
    task_id_filter: ?[]const u8,
) !std.ArrayList(ReferEvent) {
    var events: std.ArrayList(ReferEvent) = .empty;
    errdefer {
        for (events.items) |e| {
            allocator.free(e.constraint_id);
            allocator.free(e.task_id);
        }
        events.deinit(allocator);
    }

    const trace_path = try traceFilePath(allocator, workspace_root);
    defer allocator.free(trace_path);

    const file = std.fs.openFileAbsolute(trace_path, .{}) catch return events;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(content);

    // Collect finalized tasks
    var finalized_tasks = std.StringHashMap(void).init(allocator);
    defer {
        var iter = finalized_tasks.keyIterator();
        while (iter.next()) |key| allocator.free(@constCast(key.*));
        finalized_tasks.deinit();
    }

    var lines1 = std.mem.splitScalar(u8, content, '\n');
    while (lines1.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const evt_type = getStr(obj, "type") orelse continue;
        if (!std.mem.eql(u8, evt_type, "complete")) continue;
        const tid = getStr(obj, "task_id") orelse continue;
        if (!finalized_tasks.contains(tid)) {
            try finalized_tasks.put(try allocator.dupe(u8, tid), {});
        }
    }

    var lines2 = std.mem.splitScalar(u8, content, '\n');
    while (lines2.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const evt_type = getStr(obj, "type") orelse continue;
        if (!std.mem.eql(u8, evt_type, "refer")) continue;

        const pid = getStr(obj, "prompt_id") orelse continue;
        if (!std.mem.eql(u8, pid, prompt_id)) continue;

        const tid = getStr(obj, "task_id") orelse continue;
        if (task_id_filter) |filter| {
            if (!std.mem.eql(u8, tid, filter)) continue;
        }
        if (!finalized_tasks.contains(tid)) continue;

        const cid = getStr(obj, "constraint_id") orelse continue;
        const ts: i64 = if (obj.get("ts")) |ts_json| switch (ts_json) {
            .integer => |i| i,
            else => continue,
        } else continue;

        try events.append(allocator, .{
            .timestamp = ts,
            .constraint_id = try allocator.dupe(u8, cid),
            .task_id = try allocator.dupe(u8, tid),
        });
    }

    return events;
}

/// Format a millisecond timestamp to "YYYY-MM-DD" date string.
pub fn msToDateStr(allocator: std.mem.Allocator, ms: i64) ![]const u8 {
    const epoch_secs: i64 = @divTrunc(ms, 1000);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, epoch_secs)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        @intFromEnum(md.month),
        md.day_index + 1,
    });
}

/// Format a millisecond timestamp to "YYYY-Www" week string.
pub fn msToWeekStr(allocator: std.mem.Allocator, ms: i64) ![]const u8 {
    const epoch_secs: i64 = @divTrunc(ms, 1000);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, epoch_secs)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    // ISO week: approximate by day of year / 7
    const week = @divTrunc(yd.day, 7) + 1;
    return try std.fmt.allocPrint(allocator, "{d:0>4}-W{d:0>2}", .{ yd.year, week });
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn writeFile(dir: std.fs.Dir, sub_path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(sub_path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn tmpDirAbsolutePath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    return tmp.dir.realpath(".", buf) catch "";
}

test "workspaceId: deterministic from path" {
    const id1 = try workspaceId(testing.allocator, "/path/to/project");
    defer testing.allocator.free(id1);
    const id2 = try workspaceId(testing.allocator, "/path/to/project");
    defer testing.allocator.free(id2);

    try testing.expectEqualStrings(id1, id2);
    try testing.expect(std.mem.startsWith(u8, id1, "ws-"));
}

test "generateTaskId: unique" {
    const id1 = try generateTaskId(testing.allocator);
    defer testing.allocator.free(id1);
    const id2 = try generateTaskId(testing.allocator);
    defer testing.allocator.free(id2);

    try testing.expect(!std.mem.eql(u8, id1, id2));
    try testing.expect(std.mem.startsWith(u8, id1, "task-"));
}

test "appendTraceEvent: writes jsonl" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try appendTraceEvent(testing.allocator, root, .{
        .event_type = .begin,

        .task_id = "task-001",
        .goal_summary = "test goal",
    });

    try appendTraceEvent(testing.allocator, root, .{
        .event_type = .refer,

        .task_id = "task-001",
        .prompt_id = "rule:zig/00_STYLE.md",
        .prompt_hash = "abc123",
        .constraint_id = "c-1",
        .reason = "applying naming rule",
    });

    try appendTraceEvent(testing.allocator, root, .{
        .event_type = .complete,

        .task_id = "task-001",
        .status = "completed",
    });

    // Read and verify
    const trace_path = try traceFilePath(testing.allocator, root);
    defer testing.allocator.free(trace_path);

    const file = try std.fs.openFileAbsolute(trace_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 16384);
    defer testing.allocator.free(content);

    // Should have 3 lines
    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), line_count);

    // Content checks
    try testing.expect(std.mem.indexOf(u8, content, "\"type\":\"begin\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"goal_summary\":\"test goal\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"type\":\"refer\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"constraint_id\":\"c-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"type\":\"complete\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"status\":\"completed\"") != null);
}
