//! Agent session container shared by future CLI, TUI, and RPC surfaces.
//!
//! A session is the runtime span of a coding-agent conversation. It owns the
//! append-only lifecycle `Trace` and a derived `SessionState` projection. The
//! durable entry tree, compaction, and resume semantics can grow behind this
//! boundary without forcing UI code to treat a current-state view as the
//! authoritative session history.

const std = @import("std");
const event = @import("event.zig");
const SessionState = @import("session_state.zig");
const Trace = @import("trace.zig");

const Session = @This();

allocator: std.mem.Allocator,
trace: Trace,
state: SessionState,

/// Initializes an in-memory agent session.
///
/// The first implementation is intentionally runtime-only: it records owned
/// lifecycle events and keeps a derived state projection. A future persistence
/// layer should append durable session entries through this boundary instead
/// of replacing `Session` with a UI-specific shape.
pub fn init(allocator: std.mem.Allocator) Session {
    return .{
        .allocator = allocator,
        .trace = Trace.init(allocator),
        .state = SessionState.init(allocator),
    };
}

/// Releases the owned trace and derived state projection.
pub fn deinit(self: *Session) void {
    self.trace.deinit();
    self.state.deinit();
}

/// Clears recorded events and derived state.
pub fn reset(self: *Session) void {
    self.trace.deinit();
    self.trace = Trace.init(self.allocator);
    self.state.reset();
}

/// Returns the session's composite event sink.
///
/// The agent loop knows only about `event.Sink`. `Session` implements that port
/// by cloning each borrowed event once, applying the owned record to
/// `SessionState`, then transferring the same record into its owned `Trace`.
pub fn sink(self: *Session) event.Sink {
    return .{ .ctx = self, .emit_fn = emit };
}

/// Rebuilds the derived state from the owned trace.
///
/// Use this after loading or compacting trace records. It keeps `SessionState`
/// explicitly derived from history rather than making it the source of truth.
pub fn rebuildState(self: *Session) !void {
    try self.state.rebuild(self.trace.records.items);
}

fn emit(ctx: *anyopaque, new_event: event.Event) !void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const record = try Trace.Record.clone(self.allocator, new_event);
    self.state.apply(record) catch |err| {
        record.deinit(self.allocator);
        return err;
    };
    try self.trace.appendOwned(record);
}

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
    try testing.expectEqualStrings("call_1", session.trace.records.items[3].message_append.assistant.tool_calls[0].id);
    try testing.expectEqual(SessionState.Status{ .ended = .complete }, session.state.status);
    try testing.expectEqual(@as(usize, 0), session.state.current_turn_index.?);
    try testing.expectEqual(@as(usize, 3), session.state.message_count);
    try testing.expectEqualStrings("fix tests", session.state.latest_user_content);
    try testing.expectEqualStrings("I will inspect the failure.", session.state.latest_assistant_content);
    try testing.expectEqual(@as(usize, 1), session.state.tools.items.len);
    try testing.expectEqual(SessionState.ToolStatus.ok, session.state.tools.items[0].status);
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
}
