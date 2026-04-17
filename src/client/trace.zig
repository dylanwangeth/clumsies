//! Trace event recording. Each MCP setup/search/load/refer interaction is serialized as a
//! TraceEvent and appended to ~/.clumsies/workspaces/{ws_id}/trace.jsonl. The Hub later ingests
//! these events via POST /api/traces to compute constraint-level usage statistics.
const std = @import("std");
const testing = std.testing;
const encoding = @import("clumsies_lib").util.encoding;

fn getBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.HomeNotSet;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".clumsies" });
}

pub const TraceEvent = struct {
    ws_id: []const u8,
    session_id: []const u8,
    event_id: i64,
    type: []const u8,
    timestamp: i64,
    prompt_id: ?[]const u8 = null,
    prompt_hash: ?[]const u8 = null,
    constraint_id: ?[]const u8 = null,
    override_base_hash: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    content: ?[]const u8 = null,
    content_hash: ?[]const u8 = null,
};

/// Get the trace file path: ~/.clumsies/workspaces/{ws_id}/trace.jsonl
pub fn traceFilePath(allocator: std.mem.Allocator, ws_id: []const u8) ![]const u8 {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "workspaces", ws_id, "trace.jsonl" });
}

/// Get the trace cursor file path: ~/.clumsies/workspaces/{ws_id}/trace.cursor
pub fn cursorFilePath(allocator: std.mem.Allocator, ws_id: []const u8) ![]const u8 {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "workspaces", ws_id, "trace.cursor" });
}

fn ensureWorkspaceDir(allocator: std.mem.Allocator, ws_id: []const u8) !void {
    const base = try getBasePath(allocator);
    defer allocator.free(base);

    std.fs.makeDirAbsolute(base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const ws_parent = try std.fs.path.join(allocator, &.{ base, "workspaces" });
    defer allocator.free(ws_parent);
    std.fs.makeDirAbsolute(ws_parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const ws_dir = try std.fs.path.join(allocator, &.{ ws_parent, ws_id });
    defer allocator.free(ws_dir);
    std.fs.makeDirAbsolute(ws_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn ensureCursorFile(allocator: std.mem.Allocator, ws_id: []const u8) !void {
    const cursor_path = try cursorFilePath(allocator, ws_id);
    defer allocator.free(cursor_path);

    const existing = std.fs.openFileAbsolute(cursor_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const file = try std.fs.createFileAbsolute(cursor_path, .{});
            defer file.close();
            var buf: [32]u8 = undefined;
            var w = std.fs.File.Writer.init(file, &buf);
            defer w.interface.flush() catch {};
            try w.interface.writeAll("0\n");
            return;
        },
        else => return err,
    };
    existing.close();
}

/// Append a trace event to ~/.clumsies/workspaces/{ws_id}/trace.jsonl.
/// The JSON format matches the server `POST /api/traces` TraceEventInput shape.
pub fn appendTraceEvent(allocator: std.mem.Allocator, event: TraceEvent) !void {
    try ensureWorkspaceDir(allocator, event.ws_id);
    try ensureCursorFile(allocator, event.ws_id);

    const trace_path = try traceFilePath(allocator, event.ws_id);
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

    const esc_ws = try encoding.jsonEscapeAlloc(allocator, event.ws_id);
    defer allocator.free(esc_ws);
    const esc_session = try encoding.jsonEscapeAlloc(allocator, event.session_id);
    defer allocator.free(esc_session);
    const esc_type = try encoding.jsonEscapeAlloc(allocator, event.type);
    defer allocator.free(esc_type);

    try buf.writer(allocator).print(
        "{{\"ws_id\":\"{s}\",\"session_id\":\"{s}\",\"event_id\":{d},\"type\":\"{s}\",\"timestamp\":{d}",
        .{ esc_ws, esc_session, event.event_id, esc_type, event.timestamp },
    );

    try writeOptionalString(allocator, &buf, "prompt_id", event.prompt_id);
    try writeOptionalString(allocator, &buf, "prompt_hash", event.prompt_hash);
    try writeOptionalString(allocator, &buf, "constraint_id", event.constraint_id);
    try writeOptionalString(allocator, &buf, "override_base_hash", event.override_base_hash);
    try writeOptionalString(allocator, &buf, "reason", event.reason);
    try writeOptionalString(allocator, &buf, "content", event.content);
    try writeOptionalString(allocator, &buf, "content_hash", event.content_hash);

    try buf.appendSlice(allocator, "}\n");
    return try buf.toOwnedSlice(allocator);
}

fn writeOptionalString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: ?[]const u8) !void {
    const v = value orelse return;
    const esc = try encoding.jsonEscapeAlloc(allocator, v);
    defer allocator.free(esc);
    try buf.writer(allocator).print(",\"{s}\":\"{s}\"", .{ key, esc });
}

test "traceFilePath is under ~/.clumsies/workspaces/{ws_id}/" {
    const p = try traceFilePath(testing.allocator, "ws-test123");
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "/.clumsies/workspaces/ws-test123/trace.jsonl") != null);
}

test "serializeTraceEvent produces server-ready JSON" {
    const event: TraceEvent = .{
        .ws_id = "ws-abc",
        .session_id = "sess-xyz",
        .event_id = 3,
        .type = "refer",
        .timestamp = 1743753000000,
        .prompt_id = "p-550e8400",
        .constraint_id = "c-2",
        .reason = "applying style",
    };
    const line = try serializeTraceEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"ws_id\":\"ws-abc\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"session_id\":\"sess-xyz\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"event_id\":3") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"type\":\"refer\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"timestamp\":1743753000000") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"prompt_id\":\"p-550e8400\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"constraint_id\":\"c-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"reason\":\"applying style\"") != null);
    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
}

test "serializeTraceEvent omits null optional fields" {
    const event: TraceEvent = .{
        .ws_id = "ws-1",
        .session_id = "sess-1",
        .event_id = 0,
        .type = "setup",
        .timestamp = 100,
    };
    const line = try serializeTraceEvent(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "\"prompt_id\"") == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"constraint_id\"") == null);
}
