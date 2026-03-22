const std = @import("std");
const testing = std.testing;
const encoding = @import("encoding.zig");

pub const CLUMSIES_DIR = ".clumsies";
pub const TRACE_FILE = "trace.jsonl";
pub const TASKS_DIR = "tasks";
pub const TASKS_INDEX = "index.json";

// --- Trace event types ---

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
    workspace_id: []const u8,
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

// --- Task management ---

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

    const tasks_path = try std.fs.path.join(allocator, &.{ workspace_root, CLUMSIES_DIR, TASKS_DIR });
    defer allocator.free(tasks_path);

    std.fs.makeDirAbsolute(tasks_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Append a trace event to trace.jsonl.
pub fn appendTraceEvent(allocator: std.mem.Allocator, workspace_root: []const u8, event: TraceEvent) !void {
    try ensureClumsiesDir(workspace_root, allocator);

    const trace_path = try std.fs.path.join(allocator, &.{ workspace_root, CLUMSIES_DIR, TRACE_FILE });
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

    const esc_ws = try encoding.jsonEscapeAlloc(allocator, event.workspace_id);
    defer allocator.free(esc_ws);

    try buf.writer(allocator).print("{{\"type\":\"{s}\",\"ts\":{d},\"workspace_id\":\"{s}\"", .{ type_str, ts, esc_ws });

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

// --- Tests ---

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

    const ws_id = try workspaceId(testing.allocator, root);
    defer testing.allocator.free(ws_id);

    try appendTraceEvent(testing.allocator, root, .{
        .event_type = .begin,
        .workspace_id = ws_id,
        .task_id = "task-001",
        .goal_summary = "test goal",
    });

    try appendTraceEvent(testing.allocator, root, .{
        .event_type = .refer,
        .workspace_id = ws_id,
        .task_id = "task-001",
        .prompt_id = "rule:zig/00_STYLE.md",
        .prompt_hash = "abc123",
        .constraint_id = "c-1",
        .reason = "applying naming rule",
    });

    try appendTraceEvent(testing.allocator, root, .{
        .event_type = .complete,
        .workspace_id = ws_id,
        .task_id = "task-001",
        .status = "completed",
    });

    // Read and verify
    const trace_path = try std.fs.path.join(testing.allocator, &.{ root, CLUMSIES_DIR, TRACE_FILE });
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
