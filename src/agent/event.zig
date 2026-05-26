//! Lifecycle events emitted by the agent loop.

const transcript = @import("transcript.zig");
const tool = @import("tool.zig");

/// Observable lifecycle events emitted by the provider-neutral loop.
pub const Event = union(enum) {
    agent_start,
    turn_start: TurnStart,
    message_append: transcript.Message,
    tool_start: tool.Call,
    tool_end: ToolEnd,
    turn_end: TurnEnd,
    agent_end: AgentEnd,

    pub const TurnStart = struct {
        turn_index: usize,
    };

    pub const ToolEnd = struct {
        call: tool.Call,
        result: tool.Result,
    };

    pub const TurnEnd = struct {
        turn_index: usize,
        assistant: transcript.AssistantMessage,
    };

    pub const AgentEnd = struct {
        reason: transcript.EndReason,
        message_count: usize,
    };
};

/// Optional event sink for UI, tracing, and dashboard integrations.
pub const Sink = struct {
    ctx: *anyopaque,
    emit_fn: *const fn (ctx: *anyopaque, event: Event) anyerror!void,

    pub fn emit(self: Sink, event: Event) anyerror!void {
        return self.emit_fn(self.ctx, event);
    }
};
