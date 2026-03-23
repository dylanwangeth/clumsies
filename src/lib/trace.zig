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
