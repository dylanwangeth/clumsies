//! Owned agent event trace for UI and runtime observers.
//!
//! `event.Event` is a synchronous loop callback and may contain provider- or
//! tool-owned slices that are only valid during emission. `Trace` converts that
//! callback stream into owned records so TUI and session views can inspect the
//! run after each event without depending on those short-lived buffers.

const std = @import("std");
const event = @import("event.zig");
const tool = @import("tool.zig");
const transcript = @import("transcript.zig");

const Trace = @This();

allocator: std.mem.Allocator,
records: std.ArrayList(Record) = .empty,

/// Initializes an owned trace recorder using `allocator` for record payloads.
pub fn init(allocator: std.mem.Allocator) Trace {
    return .{ .allocator = allocator };
}

/// Releases every record cloned from the event stream.
pub fn deinit(self: *Trace) void {
    for (self.records.items) |record| record.deinit(self.allocator);
    self.records.deinit(self.allocator);
}

/// Returns a standalone `event.Sink` that appends owned records to this trace.
///
/// Use this when the caller only needs the raw lifecycle log. Higher-level
/// containers such as `Session` may own a `Trace` directly and append records
/// through `appendOwned` while maintaining additional projections.
pub fn sink(self: *Trace) event.Sink {
    return .{ .ctx = self, .emit_fn = emit };
}

/// Appends one owned record to the trace.
///
/// On success, ownership transfers to `Trace`. On append failure, the record is
/// released here so callers do not need a second cleanup path after transfer.
pub fn appendOwned(self: *Trace, record: Record) !void {
    errdefer record.deinit(self.allocator);
    try self.records.append(self.allocator, record);
}

/// Appends one owned record after the caller has reserved trace capacity.
///
/// This lets composite observers reserve all of their owned collections before
/// mutating derived state, then transfer record ownership without another
/// allocation failure point.
pub fn appendOwnedAssumeCapacity(self: *Trace, record: Record) void {
    self.records.appendAssumeCapacity(record);
}

fn emit(ctx: *anyopaque, new_event: event.Event) !void {
    const self: *Trace = @ptrCast(@alignCast(ctx));
    const record = try Record.clone(self.allocator, new_event);
    try self.appendOwned(record);
}

/// Owned, UI-facing shape of one agent lifecycle event.
pub const Record = union(enum) {
    agent_start,
    turn_start: TurnStart,
    message_append: MessageAppend,
    tool_start: ToolStart,
    tool_end: ToolEnd,
    turn_end: TurnEnd,
    agent_end: AgentEnd,

    /// Clones one synchronous event into an owned trace record.
    ///
    /// This is the observability boundary: the event stream is allowed to
    /// borrow provider/tool memory, while trace records must remain readable
    /// until `Trace.deinit`.
    pub fn clone(allocator: std.mem.Allocator, source: event.Event) !Record {
        return switch (source) {
            .agent_start => .agent_start,
            .turn_start => |value| .{ .turn_start = .{ .turn_index = value.turn_index } },
            .message_append => |message| .{ .message_append = try MessageAppend.clone(allocator, message) },
            .tool_start => |call| .{ .tool_start = try ToolStart.clone(allocator, call) },
            .tool_end => |value| .{ .tool_end = try ToolEnd.clone(allocator, value) },
            .turn_end => |value| .{ .turn_end = try TurnEnd.clone(allocator, value) },
            .agent_end => |value| .{ .agent_end = .{
                .reason = value.reason,
                .message_count = value.message_count,
            } },
        };
    }

    pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
        switch (self) {
            .agent_start,
            .turn_start,
            .agent_end,
            => {},
            .message_append => |value| value.deinit(allocator),
            .tool_start => |value| value.deinit(allocator),
            .tool_end => |value| value.deinit(allocator),
            .turn_end => |value| value.deinit(allocator),
        }
    }
};

pub const TurnStart = struct {
    turn_index: usize,
};

pub const MessageAppend = union(enum) {
    user: TextMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,

    fn clone(allocator: std.mem.Allocator, message: transcript.Message) !MessageAppend {
        return switch (message) {
            .user => |value| .{ .user = .{
                .content = try allocator.dupe(u8, value.content),
            } },
            .assistant => |value| .{ .assistant = try AssistantMessage.clone(allocator, value) },
            .tool_result => |value| .{ .tool_result = try ToolResultMessage.clone(allocator, value) },
        };
    }

    fn deinit(self: MessageAppend, allocator: std.mem.Allocator) void {
        switch (self) {
            .user => |value| value.deinit(allocator),
            .assistant => |value| value.deinit(allocator),
            .tool_result => |value| value.deinit(allocator),
        }
    }
};

pub const TextMessage = struct {
    content: []const u8,

    fn deinit(self: TextMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const AssistantMessage = struct {
    content: []const u8,
    tool_calls: []const tool.Call,

    fn clone(allocator: std.mem.Allocator, value: transcript.AssistantMessage) !AssistantMessage {
        const content = try allocator.dupe(u8, value.content);
        errdefer allocator.free(content);

        const calls = try cloneCalls(allocator, value.tool_calls);
        return .{
            .content = content,
            .tool_calls = calls,
        };
    }

    fn deinit(self: AssistantMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        for (self.tool_calls) |call| deinitCall(call, allocator);
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
    }
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    content: []const u8,
    is_error: bool,

    fn clone(allocator: std.mem.Allocator, value: transcript.ToolResultMessage) !ToolResultMessage {
        const tool_call_id = try allocator.dupe(u8, value.tool_call_id);
        errdefer allocator.free(tool_call_id);
        const content = try allocator.dupe(u8, value.content);
        return .{
            .tool_call_id = tool_call_id,
            .content = content,
            .is_error = value.is_error,
        };
    }

    fn deinit(self: ToolResultMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.content);
    }
};

pub const ToolStart = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,

    fn clone(allocator: std.mem.Allocator, call: tool.Call) !ToolStart {
        const id = try allocator.dupe(u8, call.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, call.name);
        errdefer allocator.free(name);
        const arguments = try allocator.dupe(u8, call.arguments);
        return .{
            .id = id,
            .name = name,
            .arguments = arguments,
        };
    }

    fn deinit(self: ToolStart, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
    }
};

fn cloneCalls(allocator: std.mem.Allocator, calls: []const tool.Call) ![]const tool.Call {
    if (calls.len == 0) return &.{};
    const cloned = try allocator.alloc(tool.Call, calls.len);
    errdefer allocator.free(cloned);

    var index: usize = 0;
    errdefer {
        for (cloned[0..index]) |call| deinitCall(call, allocator);
    }

    for (calls, cloned) |call, *dest| {
        dest.* = try cloneCall(allocator, call);
        index += 1;
    }
    return cloned;
}

fn cloneCall(allocator: std.mem.Allocator, call: tool.Call) !tool.Call {
    const id = try allocator.dupe(u8, call.id);
    errdefer allocator.free(id);

    const name = try allocator.dupe(u8, call.name);
    errdefer allocator.free(name);

    const arguments = try allocator.dupe(u8, call.arguments);
    errdefer allocator.free(arguments);

    return .{
        .id = id,
        .name = name,
        .arguments = arguments,
    };
}

fn deinitCall(call: tool.Call, allocator: std.mem.Allocator) void {
    allocator.free(call.id);
    allocator.free(call.name);
    allocator.free(call.arguments);
}

pub const ToolEnd = struct {
    call: ToolStart,
    result: ToolResult,

    fn clone(allocator: std.mem.Allocator, value: event.Event.ToolEnd) !ToolEnd {
        const call = try ToolStart.clone(allocator, value.call);
        errdefer call.deinit(allocator);
        const result = try ToolResult.clone(allocator, value.result);
        return .{ .call = call, .result = result };
    }

    fn deinit(self: ToolEnd, allocator: std.mem.Allocator) void {
        self.call.deinit(allocator);
        self.result.deinit(allocator);
    }
};

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool,
    control: tool.Control,

    fn clone(allocator: std.mem.Allocator, value: tool.Result) !ToolResult {
        return .{
            .content = try allocator.dupe(u8, value.content),
            .is_error = value.is_error,
            .control = value.control,
        };
    }

    fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const TurnEnd = struct {
    turn_index: usize,
    assistant: AssistantMessage,

    fn clone(allocator: std.mem.Allocator, value: event.Event.TurnEnd) !TurnEnd {
        return .{
            .turn_index = value.turn_index,
            .assistant = try AssistantMessage.clone(allocator, value.assistant),
        };
    }

    fn deinit(self: TurnEnd, allocator: std.mem.Allocator) void {
        self.assistant.deinit(allocator);
    }
};

pub const AgentEnd = struct {
    reason: transcript.EndReason,
    message_count: usize,
};

const testing = std.testing;

test "trace clones tool events into owned records" {
    var trace = Trace.init(testing.allocator);
    defer trace.deinit();

    const owned_content = try testing.allocator.dupe(u8, "tool output");
    defer testing.allocator.free(owned_content);

    try trace.sink().emit(.{ .tool_end = .{
        .call = .{ .id = "call_1", .name = "Bash", .arguments = "{\"command\":\"pwd\"}" },
        .result = .{
            .content = owned_content,
            .is_error = false,
        },
    } });

    @memset(owned_content, 'x');

    try testing.expectEqual(@as(usize, 1), trace.records.items.len);
    const record = trace.records.items[0].tool_end;
    try testing.expectEqualStrings("call_1", record.call.id);
    try testing.expectEqualStrings("Bash", record.call.name);
    try testing.expectEqualStrings("{\"command\":\"pwd\"}", record.call.arguments);
    try testing.expectEqualStrings("tool output", record.result.content);
}

test "trace records full loop lifecycle" {
    var trace = Trace.init(testing.allocator);
    defer trace.deinit();

    try trace.sink().emit(.agent_start);
    try trace.sink().emit(.{ .turn_start = .{ .turn_index = 2 } });
    try trace.sink().emit(.{ .message_append = .{ .assistant = .{
        .content = "done",
        .tool_calls = &.{.{ .id = "call_1", .name = "Read", .arguments = "{\"path\":\"src/root.zig\"}" }},
    } } });
    try trace.sink().emit(.{ .agent_end = .{
        .reason = .complete,
        .message_count = 2,
    } });

    try testing.expectEqual(@as(usize, 4), trace.records.items.len);
    try testing.expectEqual(Record.agent_start, std.meta.activeTag(trace.records.items[0]));
    try testing.expectEqual(@as(usize, 2), trace.records.items[1].turn_start.turn_index);
    try testing.expectEqualStrings("done", trace.records.items[2].message_append.assistant.content);
    try testing.expectEqualStrings("call_1", trace.records.items[2].message_append.assistant.tool_calls[0].id);
    try testing.expectEqualStrings("Read", trace.records.items[2].message_append.assistant.tool_calls[0].name);
    try testing.expectEqual(transcript.EndReason.complete, trace.records.items[3].agent_end.reason);
}
