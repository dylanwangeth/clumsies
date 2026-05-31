//! Agent session container shared by future CLI, TUI, and RPC surfaces.
//!
//! A session is the runtime span of a coding-agent conversation. It owns
//! durable history entries, append-only lifecycle `Trace`, and a derived
//! current-state projection. Keeping these session-owned concepts in one module
//! makes their boundaries explicit without scattering one session abstraction
//! across several files.

const std = @import("std");
const event = @import("event.zig");
const tool = @import("tool.zig");
const Trace = @import("trace.zig");
const transcript = @import("transcript.zig");

const Session = @This();

allocator: std.mem.Allocator,
entries: std.ArrayList(Entry) = .empty,
trace: Trace,
state: State,

/// Initializes an in-memory agent session.
///
/// The first implementation is intentionally runtime-only: it records owned
/// lifecycle events, keeps durable history entries, and maintains a derived
/// state projection. A future persistence layer should append durable session
/// entries through this boundary instead of replacing `Session` with a
/// UI-specific shape.
pub fn init(allocator: std.mem.Allocator) Session {
    return .{
        .allocator = allocator,
        .trace = Trace.init(allocator),
        .state = State.init(allocator),
    };
}

/// Releases durable entries, owned trace, and derived state projection.
pub fn deinit(self: *Session) void {
    self.clearEntries();
    self.entries.deinit(self.allocator);
    self.trace.deinit();
    self.state.deinit();
}

/// Clears durable history, recorded events, and derived state.
pub fn reset(self: *Session) void {
    self.clearEntries();
    self.trace.deinit();
    self.trace = Trace.init(self.allocator);
    self.state.reset();
}

/// Returns the session's composite event sink.
///
/// The agent loop knows only about `event.Sink`. `Session` implements that port
/// by cloning each borrowed event once, applying the owned record to `State`,
/// deriving an optional durable `Entry`, then transferring the same record into
/// its owned `Trace`.
pub fn sink(self: *Session) event.Sink {
    return .{ .ctx = self, .emit_fn = emit };
}

/// Returns durable session-history entries.
///
/// This excludes runtime-only progress records such as tool starts and turn
/// boundaries. Use `trace.records` when a caller needs execution observability.
pub fn history(self: *const Session) []const Entry {
    return self.entries.items;
}

/// Rebuilds the derived state from the owned trace.
///
/// Use this after loading or compacting trace records. It keeps `State`
/// explicitly derived from history rather than making it the source of truth.
pub fn rebuildState(self: *Session) !void {
    try self.state.rebuild(self.trace.records.items);
}

fn emit(ctx: *anyopaque, new_event: event.Event) !void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    var record = try Trace.Record.clone(self.allocator, new_event);
    var record_owned = true;
    defer if (record_owned) record.deinit(self.allocator);

    const entry = try Entry.cloneFromTrace(self.allocator, record);
    errdefer if (entry) |value| value.deinit(self.allocator);

    try self.trace.records.ensureUnusedCapacity(self.allocator, 1);
    if (entry != null) try self.entries.ensureUnusedCapacity(self.allocator, 1);

    self.state.apply(record) catch |err| {
        return err;
    };
    if (entry) |value| self.entries.appendAssumeCapacity(value);
    self.trace.appendOwnedAssumeCapacity(record);
    record_owned = false;
}

fn clearEntries(self: *Session) void {
    for (self.entries.items) |entry| entry.deinit(self.allocator);
    self.entries.clearRetainingCapacity();
}

/// One durable entry in an agent session.
///
/// `Trace.Record` captures the full lifecycle stream for observability.
/// `Entry` keeps only the long-lived conversation facts that matter for
/// replay, history rendering, compaction, and future persistence.
pub const Entry = union(enum) {
    message: transcript.Message,
    run_end: transcript.EndReason,

    /// Clones the trace record if it carries durable session meaning.
    ///
    /// Runtime-only records such as `turn_start`, `tool_start`, and `turn_end`
    /// return null because they describe execution progress, not conversation
    /// history.
    pub fn cloneFromTrace(
        allocator: std.mem.Allocator,
        record: Trace.Record,
    ) !?Entry {
        return switch (record) {
            .message_append => |message| .{ .message = try cloneMessageAppend(allocator, message) },
            .agent_end => |value| .{ .run_end = value.reason },
            .agent_start,
            .turn_start,
            .tool_start,
            .tool_end,
            .turn_end,
            => null,
        };
    }

    /// Releases any payload owned by this session entry.
    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        switch (self) {
            .message => |message| transcript.deinitMessage(message, allocator),
            .run_end => {},
        }
    }
};

fn cloneMessageAppend(
    allocator: std.mem.Allocator,
    message: Trace.MessageAppend,
) !transcript.Message {
    return switch (message) {
        .user => |value| transcript.cloneMessage(allocator, .{ .user = .{ .content = value.content } }),
        .assistant => |value| transcript.cloneMessage(allocator, .{ .assistant = .{
            .content = value.content,
            .tool_calls = value.tool_calls,
        } }),
        .tool_result => |value| transcript.cloneMessage(allocator, .{ .tool_result = .{
            .tool_call_id = value.tool_call_id,
            .content = value.content,
            .is_error = value.is_error,
        } }),
    };
}

/// Current-state projection derived from agent trace records.
///
/// `Trace` preserves the raw event stream. `State` is the small, mutable
/// projection that a TUI or RPC surface can render without understanding every
/// lifecycle event: whether the session is active, which turn is current, what
/// the latest assistant text is, and which tools are running or finished.
pub const State = struct {
    allocator: std.mem.Allocator,
    status: Status = .idle,
    current_turn_index: ?usize = null,
    message_count: usize = 0,
    latest_user_content: []const u8 = "",
    latest_assistant_content: []const u8 = "",
    end_reason: ?transcript.EndReason = null,
    tools: std.ArrayList(ToolRun) = .empty,

    /// Initializes a mutable projection for one active or replayed session.
    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    /// Releases all strings copied from trace records.
    pub fn deinit(self: *State) void {
        self.clear();
        self.tools.deinit(self.allocator);
    }

    /// Clears run state while keeping allocated list capacity for reuse.
    pub fn reset(self: *State) void {
        self.clear();
        self.status = .idle;
        self.current_turn_index = null;
        self.message_count = 0;
        self.end_reason = null;
    }

    /// Rebuilds this projection from a complete trace snapshot.
    ///
    /// This is the boundary used when UI code receives a trace from another
    /// worker: the projection owns its copied strings, so the source trace may
    /// be dropped or compacted after rebuilding.
    pub fn rebuild(self: *State, records: []const Trace.Record) !void {
        self.reset();
        for (records) |record| try self.apply(record);
    }

    /// Applies one trace record to the mutable projection.
    ///
    /// `State` intentionally reduces an append-only event stream into the
    /// latest status, latest user/assistant text, and per-tool status rows. It
    /// is therefore a derived view, not the authoritative session history.
    pub fn apply(self: *State, record: Trace.Record) !void {
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

    fn clear(self: *State) void {
        self.allocator.free(self.latest_user_content);
        self.latest_user_content = "";
        self.allocator.free(self.latest_assistant_content);
        self.latest_assistant_content = "";
        for (self.tools.items) |tool_run| tool_run.deinit(self.allocator);
        self.tools.clearRetainingCapacity();
    }

    fn applyMessage(self: *State, message: Trace.MessageAppend) !void {
        self.message_count += 1;
        switch (message) {
            .user => |value| try self.replaceString(&self.latest_user_content, value.content),
            .assistant => |value| try self.replaceString(&self.latest_assistant_content, value.content),
            .tool_result => |value| try self.applyToolResultMessage(value),
        }
    }

    fn applyToolResultMessage(self: *State, message: Trace.ToolResultMessage) !void {
        if (self.findTool(message.tool_call_id)) |item| {
            try item.replaceResult(self.allocator, message.content);
            item.status = if (message.is_error) .err else .ok;
        }
    }

    fn startTool(self: *State, call: Trace.ToolStart) !void {
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

    fn endTool(self: *State, value: Trace.ToolEnd) !void {
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

    fn findTool(self: *State, id: []const u8) ?*ToolRun {
        for (self.tools.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) return item;
        }
        return null;
    }

    fn replaceString(self: *State, target: *[]const u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(target.*);
        target.* = owned;
    }
};

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

test "session records events and updates derived state" {
    var session = Session.init(testing.allocator);
    defer session.deinit();

    const event_sink = session.sink();
    try event_sink.emit(.agent_start);
    try event_sink.emit(.{ .turn_start = .{ .turn_index = 0 } });
    try event_sink.emit(.{ .message_append = .{ .user = .{ .content = "fix tests" } } });
    try event_sink.emit(.{ .message_append = .{ .assistant = .{
        .content = "I will inspect the failure.",
        .tool_calls = &.{.{ .id = "call_1", .name = "Bash" }},
    } } });
    try event_sink.emit(.{ .tool_start = .{
        .id = "call_1",
        .name = "Bash",
        .arguments = "{\"command\":\"zig test src/root.zig\"}",
    } });
    try event_sink.emit(.{ .tool_end = .{
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
    try event_sink.emit(.{ .agent_end = .{
        .reason = .complete,
        .message_count = 3,
    } });

    try testing.expectEqual(@as(usize, 7), session.trace.records.items.len);
    try testing.expectEqual(@as(usize, 3), session.history().len);
    try testing.expectEqualStrings("fix tests", session.history()[0].message.user.content);
    try testing.expectEqualStrings("call_1", session.history()[1].message.assistant.tool_calls[0].id);
    try testing.expectEqual(transcript.EndReason.complete, session.history()[2].run_end);
    try testing.expectEqualStrings("call_1", session.trace.records.items[3].message_append.assistant.tool_calls[0].id);
    try testing.expectEqual(Status{ .ended = .complete }, session.state.status);
    try testing.expectEqual(@as(usize, 0), session.state.current_turn_index.?);
    try testing.expectEqual(@as(usize, 3), session.state.message_count);
    try testing.expectEqualStrings("fix tests", session.state.latest_user_content);
    try testing.expectEqualStrings("I will inspect the failure.", session.state.latest_assistant_content);
    try testing.expectEqual(@as(usize, 1), session.state.tools.items.len);
    try testing.expectEqual(ToolStatus.ok, session.state.tools.items[0].status);
    try testing.expectEqualStrings("Bash", session.state.tools.items[0].name);
    try testing.expectEqualStrings("{\"status\":\"ok\",\"exit_code\":0}", session.state.tools.items[0].result_content);
}

test "session rebuilds state from trace" {
    var session = Session.init(testing.allocator);
    defer session.deinit();

    const event_sink = session.sink();
    try event_sink.emit(.agent_start);
    try event_sink.emit(.{ .message_append = .{ .user = .{ .content = "read file" } } });

    session.state.reset();
    try session.rebuildState();

    try testing.expectEqualStrings("read file", session.state.latest_user_content);
    try testing.expectEqualStrings("read file", session.history()[0].message.user.content);
}

test "session entry keeps durable messages and run end only" {
    const assistant_record: Trace.Record = .{ .message_append = .{ .assistant = .{
        .content = "I will inspect it.",
        .tool_calls = &.{.{ .id = "call_1", .name = "Read", .arguments = "{\"path\":\"src/root.zig\"}" }},
    } } };
    const entry = (try Entry.cloneFromTrace(testing.allocator, assistant_record)).?;
    defer entry.deinit(testing.allocator);

    try testing.expectEqualStrings("call_1", entry.message.assistant.tool_calls[0].id);

    const runtime_record: Trace.Record = .{ .tool_start = .{
        .id = "call_1",
        .name = "Read",
        .arguments = "{\"path\":\"src/root.zig\"}",
    } };
    try testing.expectEqual(@as(?Entry, null), try Entry.cloneFromTrace(testing.allocator, runtime_record));
}

test "session state aggregates lifecycle records" {
    var state = State.init(testing.allocator);
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

    var state = State.init(testing.allocator);
    defer state.deinit();
    try state.rebuild(trace.records.items);

    trace.deinit();
    trace = Trace.init(testing.allocator);

    try testing.expectEqual(Status.running, state.status);
    try testing.expectEqualStrings("read file", state.latest_user_content);
}
