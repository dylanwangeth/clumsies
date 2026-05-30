//! Current-state projection derived from agent trace records.
//!
//! `Trace` preserves the raw event stream. `SessionState` is the small, mutable
//! projection that a TUI or RPC surface can render without understanding every
//! lifecycle event: whether the session is active, which turn is current, what
//! the latest assistant text is, and which tools are running or finished.

const std = @import("std");
const tool = @import("tool.zig");
const Trace = @import("trace.zig");
const transcript = @import("transcript.zig");

const SessionState = @This();

allocator: std.mem.Allocator,
status: Status = .idle,
current_turn_index: ?usize = null,
message_count: usize = 0,
latest_user_content: []const u8 = "",
latest_assistant_content: []const u8 = "",
end_reason: ?transcript.EndReason = null,
tools: std.ArrayList(ToolRun) = .empty,

/// Initializes a mutable projection for one active or replayed session.
pub fn init(allocator: std.mem.Allocator) SessionState {
    return .{ .allocator = allocator };
}

/// Releases all strings copied from trace records.
pub fn deinit(self: *SessionState) void {
    self.clear();
    self.tools.deinit(self.allocator);
}

/// Clears run state while keeping allocated list capacity for reuse.
pub fn reset(self: *SessionState) void {
    self.clear();
    self.status = .idle;
    self.current_turn_index = null;
    self.message_count = 0;
    self.end_reason = null;
}

/// Rebuilds this projection from a complete trace snapshot.
///
/// This is the boundary used when UI code receives a trace from another worker:
/// the projection owns its copied strings, so the source trace may be dropped
/// or compacted after rebuilding.
pub fn rebuild(self: *SessionState, records: []const Trace.Record) !void {
    self.reset();
    for (records) |record| try self.apply(record);
}

/// Applies one trace record to the mutable projection.
///
/// `SessionState` intentionally reduces an append-only event stream into the
/// latest status, latest user/assistant text, and per-tool status rows. It is
/// therefore a derived view, not the authoritative session history.
pub fn apply(self: *SessionState, record: Trace.Record) !void {
    switch (record) {
        .agent_start => {
            self.reset();
            self.status = .running;
        },
        .turn_start => |value| {
            self.status = .running;
            self.current_turn_index = value.turn_index;
        },
        .message_append => |message| try self.applyMessage(message),
        .tool_start => |call| try self.startTool(call),
        .tool_end => |value| try self.endTool(value),
        .turn_end => |value| {
            self.current_turn_index = value.turn_index;
            try self.replaceString(&self.latest_assistant_content, value.assistant.content);
        },
        .agent_end => |value| {
            self.message_count = value.message_count;
            self.end_reason = value.reason;
            self.status = .{ .ended = value.reason };
        },
    }
}

fn clear(self: *SessionState) void {
    self.allocator.free(self.latest_user_content);
    self.latest_user_content = "";
    self.allocator.free(self.latest_assistant_content);
    self.latest_assistant_content = "";
    for (self.tools.items) |tool_run| tool_run.deinit(self.allocator);
    self.tools.clearRetainingCapacity();
}

fn applyMessage(self: *SessionState, message: Trace.MessageAppend) !void {
    self.message_count += 1;
    switch (message) {
        .user => |value| try self.replaceString(&self.latest_user_content, value.content),
        .assistant => |value| try self.replaceString(&self.latest_assistant_content, value.content),
        .tool_result => |value| try self.applyToolResultMessage(value),
    }
}

fn applyToolResultMessage(self: *SessionState, message: Trace.ToolResultMessage) !void {
    if (self.findTool(message.tool_call_id)) |item| {
        try item.replaceResult(self.allocator, message.content);
        item.status = if (message.is_error) .err else .ok;
    }
}

fn startTool(self: *SessionState, call: Trace.ToolStart) !void {
    if (self.findTool(call.id)) |item| {
        try item.replaceStart(self.allocator, call);
        item.status = .running;
        item.control = .continue_run;
        return;
    }

    const item = try ToolRun.cloneStart(self.allocator, call);
    errdefer item.deinit(self.allocator);
    try self.tools.append(self.allocator, item);
}

fn endTool(self: *SessionState, value: Trace.ToolEnd) !void {
    const item = self.findTool(value.call.id) orelse item: {
        const created = try ToolRun.cloneStart(self.allocator, value.call);
        errdefer created.deinit(self.allocator);
        try self.tools.append(self.allocator, created);
        break :item &self.tools.items[self.tools.items.len - 1];
    };

    try item.replaceResult(self.allocator, value.result.content);
    item.status = if (value.result.is_error) .err else .ok;
    item.control = value.result.control;
}

fn findTool(self: *SessionState, id: []const u8) ?*ToolRun {
    for (self.tools.items) |*item| {
        if (std.mem.eql(u8, item.id, id)) return item;
    }
    return null;
}

fn replaceString(self: *SessionState, target: *[]const u8, value: []const u8) !void {
    const owned = try self.allocator.dupe(u8, value);
    self.allocator.free(target.*);
    target.* = owned;
}

pub const Status = union(enum) {
    idle,
    running,
    ended: transcript.EndReason,
};

pub const ToolStatus = enum {
    running,
    ok,
    err,
};

pub const ToolRun = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
    result_content: []const u8 = "",
    status: ToolStatus = .running,
    control: tool.Control = .continue_run,

    /// Clones the provider-requested call into projection-owned tool state.
    fn cloneStart(allocator: std.mem.Allocator, call: Trace.ToolStart) !ToolRun {
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

    fn deinit(self: ToolRun, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
        allocator.free(self.result_content);
    }

    fn replaceStart(self: *ToolRun, allocator: std.mem.Allocator, call: Trace.ToolStart) !void {
        const id = try allocator.dupe(u8, call.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, call.name);
        errdefer allocator.free(name);
        const arguments = try allocator.dupe(u8, call.arguments);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
        self.id = id;
        self.name = name;
        self.arguments = arguments;
    }

    fn replaceResult(self: *ToolRun, allocator: std.mem.Allocator, content: []const u8) !void {
        const owned = try allocator.dupe(u8, content);
        allocator.free(self.result_content);
        self.result_content = owned;
    }
};

const testing = std.testing;

test "session state aggregates lifecycle records" {
    var state = SessionState.init(testing.allocator);
    defer state.deinit();

    try state.apply(.agent_start);
    try state.apply(.{ .turn_start = .{ .turn_index = 0 } });
    try state.apply(.{ .message_append = .{ .user = .{ .content = "fix tests" } } });
    try state.apply(.{ .message_append = .{ .assistant = .{
        .content = "I will inspect the failure.",
        .tool_calls = &.{.{ .id = "call_1", .name = "Bash" }},
    } } });
    try state.apply(.{ .tool_start = .{
        .id = "call_1",
        .name = "Bash",
        .arguments = "{\"command\":\"zig test src/root.zig\"}",
    } });
    try state.apply(.{ .tool_end = .{
        .call = .{
            .id = "call_1",
            .name = "Bash",
            .arguments = "{\"command\":\"zig test src/root.zig\"}",
        },
        .result = .{
            .content = "{\"status\":\"ok\",\"exit_code\":0}",
            .is_error = false,
            .control = .continue_run,
        },
    } });
    try state.apply(.{ .agent_end = .{
        .reason = .complete,
        .message_count = 3,
    } });

    try testing.expectEqual(Status{ .ended = .complete }, state.status);
    try testing.expectEqual(@as(usize, 0), state.current_turn_index.?);
    try testing.expectEqual(@as(usize, 3), state.message_count);
    try testing.expectEqualStrings("fix tests", state.latest_user_content);
    try testing.expectEqualStrings("I will inspect the failure.", state.latest_assistant_content);
    try testing.expectEqual(@as(usize, 1), state.tools.items.len);
    try testing.expectEqual(ToolStatus.ok, state.tools.items[0].status);
    try testing.expectEqualStrings("Bash", state.tools.items[0].name);
    try testing.expectEqualStrings("{\"status\":\"ok\",\"exit_code\":0}", state.tools.items[0].result_content);
}

test "session state rebuild owns data independently of trace" {
    var trace = Trace.init(testing.allocator);
    defer trace.deinit();
    try trace.sink().emit(.agent_start);
    try trace.sink().emit(.{ .message_append = .{ .user = .{ .content = "read file" } } });

    var state = SessionState.init(testing.allocator);
    defer state.deinit();
    try state.rebuild(trace.records.items);

    trace.deinit();
    trace = Trace.init(testing.allocator);

    try testing.expectEqual(Status.running, state.status);
    try testing.expectEqualStrings("read file", state.latest_user_content);
}
