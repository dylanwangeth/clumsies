//! Session persistence: append-only JSONL and replay-based recovery.
//!
//! Each `Trace.Record` becomes one JSON line. On recovery, lines are parsed
//! back into owned records and replayed through `Session.emit()`, which
//! rebuilds entries, trace, state, and run containers identically to the
//! original in-memory session.
//!
//! This file is deliberately NOT the same as a future runtime.jsonl. The
//! session file records the loop-level events needed for durable recovery:
//! messages, tool invocations and results, and lifecycle boundaries. A
//! separate runtime log would add timestamps, stream chunks, token counts,
//! retry spans, and provider-level diagnostics that are not needed to
//! reconstruct a conversation.

const std = @import("std");
const Trace = @import("trace.zig");
const Session = @import("session.zig");
const tool = @import("tool.zig");
const transcript = @import("transcript.zig");

/// Appends one trace record as a JSON line to the session file.
pub fn appendRecord(file: std.fs.File, record: Trace.Record, allocator: std.mem.Allocator) !void {
    const line = try serializeRecord(allocator, record);
    defer allocator.free(line);
    try file.writeAll(line);
    try file.writeAll("\n");
}

/// Appends a compaction summary entry to the session file.
pub fn appendCompactionEntry(file: std.fs.File, summary: []const u8, tokens_before: usize, run_count: usize, message_count: usize, allocator: std.mem.Allocator) !void {
    const line = try std.json.Stringify.valueAlloc(allocator, .{
        .type = "compaction",
        .summary = summary,
        .tokens_before = tokens_before,
        .compacted_runs = run_count,
        .compacted_msgs = message_count,
    }, .{});
    defer allocator.free(line);
    try file.writeAll(line);
    try file.writeAll("\n");
}

/// Loads a session from a JSONL file by replaying every record.
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Session {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(content);

    var session = Session.init(allocator);
    errdefer session.deinit();

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (isCompactionLine(trimmed)) {
            // Compaction replaces everything before it — clear current entries
            // then inject the compaction entry.
            for (session.entries.items) |*e| e.deinit(session.allocator);
            session.entries.clearRetainingCapacity();
            const entry = try parseCompactionEntry(allocator, trimmed);
            try session.entries.append(session.allocator, entry);
        } else {
            var record = try parseRecord(allocator, trimmed);
            errdefer record.deinit(allocator);

            try replayRecord(&session, record);
            record.deinit(allocator);
        }
    }
    return session;
}

// ── Serialization ──────────────────────────────────────────────────────────

fn serializeRecord(allocator: std.mem.Allocator, record: Trace.Record) ![]const u8 {
    return switch (record) {
        .agent_start => try std.json.Stringify.valueAlloc(allocator, .{ .type = "agent_start" }, .{}),
        .turn_start => |v| try std.json.Stringify.valueAlloc(allocator, .{
            .type = "turn_start", .turn_index = v.turn_index,
        }, .{}),
        .message_append => |m| try serializeMessageAppend(allocator, m),
        .tool_start => |v| try std.json.Stringify.valueAlloc(allocator, .{
            .type = "tool_start", .id = v.id, .name = v.name, .arguments = v.arguments,
        }, .{}),
        .tool_end => |v| try serializeToolEnd(allocator, v),
        .turn_end => |v| try serializeTurnEnd(allocator, v),
        .run_error => |v| try std.json.Stringify.valueAlloc(allocator, .{
            .type = "run_error", .message = v.message,
        }, .{}),
        .agent_end => |v| try std.json.Stringify.valueAlloc(allocator, .{
            .type = "agent_end", .reason = @tagName(v.reason), .message_count = v.message_count,
        }, .{}),
    };
}

fn serializeMessageAppend(allocator: std.mem.Allocator, m: Trace.MessageAppend) ![]const u8 {
    return switch (m) {
        .user => |v| try std.json.Stringify.valueAlloc(allocator, .{
            .type = "message_append", .user = .{ .content = v.content },
        }, .{}),
        .assistant => |v| try serializeAssistantAppend(allocator, v),
        .tool_result => |v| try std.json.Stringify.valueAlloc(allocator, .{
            .type = "message_append", .tool_result = .{
                .tool_call_id = v.tool_call_id, .content = v.content, .is_error = v.is_error,
            },
        }, .{}),
    };
}

fn serializeAssistantAppend(allocator: std.mem.Allocator, a: Trace.AssistantMessage) ![]const u8 {
    const TC = struct { id: []const u8, name: []const u8, arguments: []const u8 };
    const calls = try allocator.alloc(TC, a.tool_calls.len);
    defer allocator.free(calls);
    for (a.tool_calls, calls) |c, *d| d.* = .{ .id = c.id, .name = c.name, .arguments = c.arguments };
    return try std.json.Stringify.valueAlloc(allocator, .{
        .type = "message_append", .assistant = .{ .content = a.content, .tool_calls = calls, .reasoning = a.reasoning },
    }, .{});
}

fn serializeToolEnd(allocator: std.mem.Allocator, v: Trace.ToolEnd) ![]const u8 {
    return try std.json.Stringify.valueAlloc(allocator, .{
        .type = "tool_end",
        .call = .{ .id = v.call.id, .name = v.call.name, .arguments = v.call.arguments },
        .result = .{ .content = v.result.content, .is_error = v.result.is_error, .control = @tagName(v.result.control) },
    }, .{});
}

fn serializeTurnEnd(allocator: std.mem.Allocator, v: Trace.TurnEnd) ![]const u8 {
    const TC = struct { id: []const u8, name: []const u8, arguments: []const u8 };
    const calls = try allocator.alloc(TC, v.assistant.tool_calls.len);
    defer allocator.free(calls);
    for (v.assistant.tool_calls, calls) |c, *d| d.* = .{ .id = c.id, .name = c.name, .arguments = c.arguments };
    return try std.json.Stringify.valueAlloc(allocator, .{
        .type = "turn_end", .turn_index = v.turn_index,
        .assistant = .{ .content = v.assistant.content, .tool_calls = calls, .reasoning = v.assistant.reasoning },
    }, .{});
}

// ── Parsing ────────────────────────────────────────────────────────────────

fn parseRecord(allocator: std.mem.Allocator, line: []const u8) !Trace.Record {
    const U = struct { content: []const u8 };
    const TC = struct { id: []const u8, name: []const u8, arguments: []const u8 };
    const A = struct { content: []const u8, tool_calls: ?[]const TC = null, reasoning: ?[]const u8 = null };
    const TM = struct { tool_call_id: []const u8, content: []const u8, is_error: ?bool = null };
    const TR = struct { content: []const u8, is_error: ?bool = null, control: ?[]const u8 = null };

    const Parsed = struct {
        type: []const u8,
        turn_index: ?usize = null,
        id: ?[]const u8 = null, name: ?[]const u8 = null, arguments: ?[]const u8 = null,
        call: ?TC = null, result: ?TR = null,
        message: ?[]const u8 = null, reason: ?[]const u8 = null, message_count: ?usize = null,
        user: ?U = null, assistant: ?A = null, tool_result: ?TM = null,
    };

    var parsed = try std.json.parseFromSlice(Parsed, allocator, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const p = parsed.value;

    if (std.mem.eql(u8, p.type, "agent_start")) return .agent_start;
    if (std.mem.eql(u8, p.type, "turn_start"))
        return .{ .turn_start = .{ .turn_index = p.turn_index orelse return error.MissingField } };
    if (std.mem.eql(u8, p.type, "message_append")) return try parseMessageAppend(allocator, p);
    if (std.mem.eql(u8, p.type, "tool_start")) {
        const id = try allocator.dupe(u8, p.id orelse return error.MissingField);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, p.name orelse return error.MissingField);
        errdefer allocator.free(name);
        const args = try allocator.dupe(u8, p.arguments orelse "");
        return .{ .tool_start = .{ .id = id, .name = name, .arguments = args } };
    }
    if (std.mem.eql(u8, p.type, "tool_end")) {
        const c = p.call orelse return error.MissingField;
        const r = p.result orelse return error.MissingField;
        const cid = try allocator.dupe(u8, c.id);
        errdefer allocator.free(cid);
        const cn = try allocator.dupe(u8, c.name);
        errdefer allocator.free(cn);
        const ca = try allocator.dupe(u8, c.arguments);
        errdefer allocator.free(ca);
        const rc = try allocator.dupe(u8, r.content);
        errdefer allocator.free(rc);
        const ctrl = if (r.control) |s| std.meta.stringToEnum(tool.Control, s) orelse .continue_run else .continue_run;
        return .{ .tool_end = .{
            .call = .{ .id = cid, .name = cn, .arguments = ca },
            .result = .{ .content = rc, .is_error = r.is_error orelse false, .control = ctrl },
        } };
    }
    if (std.mem.eql(u8, p.type, "turn_end")) {
        const a = p.assistant orelse return error.MissingField;
        const ac = try allocator.dupe(u8, a.content);
        errdefer allocator.free(ac);
        const ar = try allocator.dupe(u8, a.reasoning orelse "");
        errdefer allocator.free(ar);
        const atc = try dupToolCalls(allocator, a.tool_calls orelse &.{});
        return .{ .turn_end = .{
            .turn_index = p.turn_index orelse return error.MissingField,
            .assistant = .{ .content = ac, .tool_calls = atc, .reasoning = ar },
        } };
    }
    if (std.mem.eql(u8, p.type, "run_error"))
        return .{ .run_error = .{ .message = try allocator.dupe(u8, p.message orelse return error.MissingField) } };
    if (std.mem.eql(u8, p.type, "agent_end"))
        return .{ .agent_end = .{
            .reason = std.meta.stringToEnum(transcript.EndReason, p.reason orelse "complete") orelse .complete,
            .message_count = p.message_count orelse 0,
        } };
    return error.UnknownRecordType;
}

/// Quick check whether a JSON line is a compaction entry.
fn isCompactionLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "{\"type\":\"compaction\"");
}

/// Parses a compaction JSONL line into a Session.Entry.
fn parseCompactionEntry(allocator: std.mem.Allocator, line: []const u8) !Session.Entry {
    const Parsed = struct {
        type: []const u8,
        summary: ?[]const u8 = null,
        tokens_before: ?usize = null,
        compacted_runs: ?usize = null,
        compacted_msgs: ?usize = null,
    };
    var parsed = try std.json.parseFromSlice(Parsed, allocator, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const p = parsed.value;
    const summary = try allocator.dupe(u8, p.summary orelse return error.MissingField);
    errdefer allocator.free(summary);
    return .{ .compaction = .{
        .summary = summary,
        .tokens_before = p.tokens_before orelse 0,
        .run_count = p.compacted_runs orelse 0,
        .message_count = p.compacted_msgs orelse 0,
    } };
}

fn parseMessageAppend(allocator: std.mem.Allocator, p: anytype) !Trace.Record {
    if (p.user) |u| {
        const content = try allocator.dupe(u8, u.content);
        return .{ .message_append = .{ .user = .{ .content = content } } };
    }
    if (p.assistant) |a| {
        const content = try allocator.dupe(u8, a.content);
        errdefer allocator.free(content);
        const calls = try dupToolCalls(allocator, a.tool_calls orelse &.{});
        const reasoning = try allocator.dupe(u8, a.reasoning orelse "");
        errdefer allocator.free(reasoning);
        return .{ .message_append = .{ .assistant = .{ .content = content, .tool_calls = calls, .reasoning = reasoning } } };
    }
    if (p.tool_result) |r| {
        const tcid = try allocator.dupe(u8, r.tool_call_id);
        errdefer allocator.free(tcid);
        const content = try allocator.dupe(u8, r.content);
        return .{ .message_append = .{ .tool_result = .{
            .tool_call_id = tcid, .content = content, .is_error = r.is_error orelse false,
        } } };
    }
    return error.MissingField;
}

fn dupToolCalls(allocator: std.mem.Allocator, calls: anytype) ![]const tool.Call {
    if (calls.len == 0) return &.{};
    const result = try allocator.alloc(tool.Call, calls.len);
    errdefer allocator.free(result);
    var i: usize = 0;
    errdefer {
        for (result[0..i]) |c| {
            allocator.free(c.id);
            allocator.free(c.name);
            allocator.free(c.arguments);
        }
    }
    for (calls, result) |src, *dest| {
        dest.id = try allocator.dupe(u8, src.id);
        errdefer allocator.free(dest.id);
        dest.name = try allocator.dupe(u8, src.name);
        errdefer allocator.free(dest.name);
        dest.arguments = try allocator.dupe(u8, src.arguments);
        i += 1;
    }
    return result;
}

// ── Replay ─────────────────────────────────────────────────────────────────

fn replayRecord(session: *Session, record: Trace.Record) !void {
    const evt = @import("event.zig");
    const event = switch (record) {
        .agent_start => evt.Event.agent_start,
        .turn_start => |v| evt.Event{ .turn_start = .{ .turn_index = v.turn_index } },
        .message_append => |m| evt.Event{ .message_append = switch (m) {
            .user => |v| .{ .user = .{ .content = v.content } },
            .assistant => |v| .{ .assistant = .{ .content = v.content, .tool_calls = v.tool_calls, .reasoning = v.reasoning } },
            .tool_result => |v| .{ .tool_result = .{ .tool_call_id = v.tool_call_id, .content = v.content, .is_error = v.is_error } },
        } },
        .tool_start => |v| evt.Event{ .tool_start = .{ .id = v.id, .name = v.name, .arguments = v.arguments } },
        .tool_end => |v| evt.Event{ .tool_end = .{
            .call = .{ .id = v.call.id, .name = v.call.name, .arguments = v.call.arguments },
            .result = .{ .content = v.result.content, .is_error = v.result.is_error, .control = v.result.control },
        } },
        .turn_end => |v| evt.Event{ .turn_end = .{
            .turn_index = v.turn_index,
            .assistant = .{ .content = v.assistant.content, .tool_calls = v.assistant.tool_calls, .reasoning = v.assistant.reasoning },
        } },
        .run_error => |v| evt.Event{ .run_error = .{ .message = v.message } },
        .agent_end => |v| evt.Event{ .agent_end = .{ .reason = v.reason, .message_count = v.message_count } },
    };
    try session.sink().emit(event);
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "serializeParse round-trips all record variants" {
    const testing = std.testing;
    const a = testing.allocator;

    const records = [_]Trace.Record{
        .agent_start,
        .{ .turn_start = .{ .turn_index = 0 } },
        .{ .message_append = .{ .user = .{ .content = "hello" } } },
        .{ .tool_start = .{ .id = "c1", .name = "read", .arguments = "x.zig" } },
        .{ .tool_end = .{
            .call = .{ .id = "c1", .name = "read", .arguments = "x.zig" },
            .result = .{ .content = "ok", .is_error = false, .control = .continue_run },
        } },
        .{ .message_append = .{ .assistant = .{ .content = "done", .tool_calls = &.{} } } },
        .{ .turn_end = .{ .turn_index = 0, .assistant = .{ .content = "done", .tool_calls = &.{} } } },
        .{ .agent_end = .{ .reason = .complete, .message_count = 5 } },
        .{ .run_error = .{ .message = "timeout" } },
        .{ .message_append = .{ .assistant = .{
            .content = "",
            .tool_calls = &.{.{ .id = "c2", .name = "write", .arguments = "{}" }},
        } } },
    };

    for (records) |rec| {
        const json = try serializeRecord(a, rec);
        defer a.free(json);
        try testing.expect(std.mem.indexOfScalar(u8, json, '\n') == null);

        const parsed = try parseRecord(a, json);
        defer parsed.deinit(a);

        try testing.expectEqual(std.meta.activeTag(rec), std.meta.activeTag(parsed));
        switch (rec) {
            .agent_start => {},
            .turn_start => |v| try testing.expectEqual(v.turn_index, parsed.turn_start.turn_index),
            .message_append => |v| try testing.expectEqualStrings(@tagName(v), @tagName(parsed.message_append)),
            .tool_start => |v| {
                try testing.expectEqualStrings(v.id, parsed.tool_start.id);
                try testing.expectEqualStrings(v.name, parsed.tool_start.name);
                try testing.expectEqualStrings(v.arguments, parsed.tool_start.arguments);
            },
            .tool_end => |v| {
                try testing.expectEqualStrings(v.call.id, parsed.tool_end.call.id);
                try testing.expectEqualStrings(v.result.content, parsed.tool_end.result.content);
                try testing.expectEqual(v.result.is_error, parsed.tool_end.result.is_error);
                try testing.expectEqual(v.result.control, parsed.tool_end.result.control);
            },
            .turn_end => |v| try testing.expectEqual(v.turn_index, parsed.turn_end.turn_index),
            .run_error => |v| try testing.expectEqualStrings(v.message, parsed.run_error.message),
            .agent_end => |v| {
                try testing.expectEqual(v.reason, parsed.agent_end.reason);
                try testing.expectEqual(v.message_count, parsed.agent_end.message_count);
            },
        }
    }
}

test "loadFromFile replays session correctly" {
    const testing = std.testing;
    const a = testing.allocator;
    const path = "test_session_load.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try appendRecord(f, .agent_start, a);
        try appendRecord(f, .{ .message_append = .{ .user = .{ .content = "fix it" } } }, a);
        try appendRecord(f, .{ .message_append = .{ .assistant = .{ .content = "done", .tool_calls = &.{} } } }, a);
        try appendRecord(f, .{ .agent_end = .{ .reason = .complete, .message_count = 3 } }, a);
    }

    var session = try loadFromFile(a, path);
    defer session.deinit();

    try testing.expectEqual(@as(usize, 1), session.runsView().len);
    try testing.expectEqual(@as(usize, 3), session.history().len);
    try testing.expectEqualStrings("fix it", session.history()[0].message.user.content);
    try testing.expect(session.trace.records.items.len >= 4);
}

test "loadFromFile with tool calls recovers state" {
    const testing = std.testing;
    const a = testing.allocator;
    const path = "test_session_tools.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try appendRecord(f, .agent_start, a);
        try appendRecord(f, .{ .message_append = .{ .user = .{ .content = "read file" } } }, a);
        try appendRecord(f, .{ .message_append = .{ .assistant = .{
            .content = "", .tool_calls = &.{.{ .id = "c1", .name = "read", .arguments = "m.zig" }},
        } } }, a);
        try appendRecord(f, .{ .tool_start = .{ .id = "c1", .name = "read", .arguments = "m.zig" } }, a);
        try appendRecord(f, .{ .tool_end = .{
            .call = .{ .id = "c1", .name = "read", .arguments = "m.zig" },
            .result = .{ .content = "fn main() {}", .is_error = false, .control = .continue_run },
        } }, a);
        try appendRecord(f, .{ .message_append = .{ .tool_result = .{
            .tool_call_id = "c1", .content = "fn main() {}", .is_error = false,
        } } }, a);
        try appendRecord(f, .{ .agent_end = .{ .reason = .complete, .message_count = 6 } }, a);
    }

    var session = try loadFromFile(a, path);
    defer session.deinit();

    var found = false;
    for (session.currentRun().?.trace.records.items) |r| {
        if (r == .tool_start and std.mem.eql(u8, r.tool_start.id, "c1")) found = true;
    }
    try testing.expect(found);
    try testing.expectEqual(Session.Status{ .ended = .complete }, session.state.status);
}
