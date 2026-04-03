const std = @import("std");
const testing = std.testing;
const encoding = @import("encoding.zig");
const config = @import("config.zig");

pub const LOG_DIR = "log";

pub const EventType = enum {
    setup,
    search,
    load,
    refer,
};

pub const TraceEvent = struct {
    event_type: EventType,

    // setup fields
    mpf_hash: ?[]const u8 = null,

    // load fields
    prompt_id: ?[]const u8 = null,
    prompt_hash: ?[]const u8 = null,

    // refer fields
    constraint_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
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

/// Get the trace file path: ~/.clumsies/log/{workspace_id}.jsonl
pub fn traceFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]const u8 {
    const base = try config.getBasePath(allocator);
    defer allocator.free(base);
    const ws_id = try workspaceId(allocator, workspace_root);
    defer allocator.free(ws_id);
    const filename = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{ws_id});
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &.{ base, LOG_DIR, filename });
}

/// Ensure ~/.clumsies/log/ directory exists.
pub fn ensureLogDir(allocator: std.mem.Allocator) !void {
    const base = try config.getBasePath(allocator);
    defer allocator.free(base);

    std.fs.makeDirAbsolute(base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const log_path = try std.fs.path.join(allocator, &.{ base, LOG_DIR });
    defer allocator.free(log_path);

    std.fs.makeDirAbsolute(log_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Append a trace event to trace.jsonl.
pub fn appendTraceEvent(allocator: std.mem.Allocator, workspace_root: []const u8, event: TraceEvent) !void {
    try ensureLogDir(allocator);

    const trace_path = try traceFilePath(allocator, workspace_root);
    defer allocator.free(trace_path);

    var file = try std.fs.createFileAbsolute(trace_path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);

    const line = try serializeTraceEvent(allocator, event);
    defer allocator.free(line);

    var write_buf: [4096]u8 = undefined;
    var fw = std.fs.File.Writer.initStreaming(file, &write_buf);
    try fw.interface.writeAll(line);
    try fw.interface.flush();
}

fn serializeTraceEvent(allocator: std.mem.Allocator, event: TraceEvent) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const ts = std.time.milliTimestamp();
    const type_str = @tagName(event.event_type);

    try buf.writer(allocator).print("{{\"type\":\"{s}\",\"ts\":{d}", .{ type_str, ts });

    // Type-specific fields
    switch (event.event_type) {
        .setup => {
            if (event.mpf_hash) |h| {
                const esc = try encoding.jsonEscapeAlloc(allocator, h);
                defer allocator.free(esc);
                try buf.writer(allocator).print(",\"mpf_hash\":\"{s}\"", .{esc});
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
        .search => {},
    }

    try buf.appendSlice(allocator, "}\n");
    return try buf.toOwnedSlice(allocator);
}

// Stats: read and aggregate trace

pub const PromptStats = struct {
    id: []const u8,
    refer_count: usize = 0,
};

pub const WorkspaceStats = struct {
    prompts: std.StringArrayHashMap(PromptStats),

    pub fn deinit(self: *WorkspaceStats, allocator: std.mem.Allocator) void {
        var iter = self.prompts.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.id);
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

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = try fr.interface.allocRemaining(allocator, std.io.Limit.limited(64 * 1024 * 1024));
    defer allocator.free(content);

    // Aggregate refer events
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

        const gop = try stats.prompts.getOrPut(pid);
        if (!gop.found_existing) {
            const owned_key = try allocator.dupe(u8, pid);
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{
                .id = owned_key,
            };
        }
        gop.value_ptr.refer_count += 1;
    }

    return stats;
}

// Per-constraint stats for prompt scope

pub const ConstraintStats = struct {
    constraint_id: []const u8,
    refer_count: usize = 0,
    last_referred_at: ?i64 = null,
};

pub const PromptDetailStats = struct {
    prompt_id: []const u8,
    prompt_hash: ?[]const u8,
    constraints: std.StringArrayHashMap(ConstraintStats),

    pub fn deinit(self: *PromptDetailStats, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt_id);
        if (self.prompt_hash) |h| allocator.free(h);
        var iter = self.constraints.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.constraint_id);
        }
        self.constraints.deinit();
    }
};

pub fn computePromptStats(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    prompt_id: []const u8,
) !PromptDetailStats {
    var stats: PromptDetailStats = .{
        .prompt_id = try allocator.dupe(u8, prompt_id),
        .prompt_hash = null,
        .constraints = .init(allocator),
    };
    errdefer stats.deinit(allocator);

    const trace_path = try traceFilePath(allocator, workspace_root);
    defer allocator.free(trace_path);

    const file = std.fs.openFileAbsolute(trace_path, .{}) catch return stats;
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = try fr.interface.allocRemaining(allocator, std.io.Limit.limited(64 * 1024 * 1024));
    defer allocator.free(content);

    // Aggregate refer events for this prompt
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

        // Update constraint stats
        const gop = try stats.constraints.getOrPut(cid);
        if (!gop.found_existing) {
            const owned_cid = try allocator.dupe(u8, cid);
            gop.key_ptr.* = owned_cid;
            gop.value_ptr.* = .{
                .constraint_id = owned_cid,
            };
        }
        gop.value_ptr.refer_count += 1;

        if (ts_val) |ts| {
            if (gop.value_ptr.last_referred_at == null or ts > gop.value_ptr.last_referred_at.?) {
                gop.value_ptr.last_referred_at = ts;
            }
        }
    }

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
        }
        result.deinit();
    }

    const trace_path = try traceFilePath(allocator, workspace_root);
    defer allocator.free(trace_path);

    const file = std.fs.openFileAbsolute(trace_path, .{}) catch return result;
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = try fr.interface.allocRemaining(allocator, std.io.Limit.limited(64 * 1024 * 1024));
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

        const gop = try result.getOrPut(cid);
        if (!gop.found_existing) {
            const owned_key = try allocator.dupe(u8, cid);
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{
                .refer_count = 0,
            };
        }
        gop.value_ptr.refer_count += 1;
    }

    return result;
}

pub const ConstraintReferAgg = struct {
    refer_count: usize,
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
};

/// Collect all refer events for a specific prompt.
pub fn collectReferEvents(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    prompt_id: []const u8,
) !std.ArrayList(ReferEvent) {
    var events: std.ArrayList(ReferEvent) = .empty;
    errdefer {
        for (events.items) |e| {
            allocator.free(e.constraint_id);
        }
        events.deinit(allocator);
    }

    const trace_path = try traceFilePath(allocator, workspace_root);
    defer allocator.free(trace_path);

    const file = std.fs.openFileAbsolute(trace_path, .{}) catch return events;
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = try fr.interface.allocRemaining(allocator, std.io.Limit.limited(64 * 1024 * 1024));
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

        const cid = getStr(obj, "constraint_id") orelse continue;
        const ts: i64 = if (obj.get("ts")) |ts_json| switch (ts_json) {
            .integer => |i| i,
            else => continue,
        } else continue;

        try events.append(allocator, .{
            .timestamp = ts,
            .constraint_id = try allocator.dupe(u8, cid),
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

test "workspaceId: deterministic from path" {
    const id1 = try workspaceId(testing.allocator, "/path/to/project");
    defer testing.allocator.free(id1);
    const id2 = try workspaceId(testing.allocator, "/path/to/project");
    defer testing.allocator.free(id2);

    try testing.expectEqualStrings(id1, id2);
    try testing.expect(std.mem.startsWith(u8, id1, "ws-"));
}

test "appendTraceEvent: writes jsonl" {
    // Use a unique fake workspace root so the trace file doesn't collide
    const root = "/tmp/clumsies-test-appendTraceEvent-unique";

    try appendTraceEvent(testing.allocator, root, .{
        .event_type = .setup,
        .mpf_hash = "hash123",
    });

    try appendTraceEvent(testing.allocator, root, .{
        .event_type = .refer,
        .prompt_id = "rule:zig/00_STYLE.md",
        .prompt_hash = "abc123",
        .constraint_id = "c-1",
        .reason = "applying naming rule",
    });

    // Read and verify
    const trace_path = try traceFilePath(testing.allocator, root);
    defer testing.allocator.free(trace_path);

    // Clean up trace file after test
    defer std.fs.deleteFileAbsolute(trace_path) catch {};

    const file = try std.fs.openFileAbsolute(trace_path, .{});
    defer file.close();
    var tr_buf: [4096]u8 = undefined;
    var tr = std.fs.File.Reader.init(file, &tr_buf);
    const content = try tr.interface.readAllAlloc(testing.allocator, 16384);
    defer testing.allocator.free(content);

    // Should have 2 lines
    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), line_count);

    // Content checks
    try testing.expect(std.mem.indexOf(u8, content, "\"type\":\"setup\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"mpf_hash\":\"hash123\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"type\":\"refer\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"constraint_id\":\"c-1\"") != null);
}
