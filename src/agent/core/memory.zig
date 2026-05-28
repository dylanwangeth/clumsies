//! Minimal memory boundary around provider inferences.
//!
//! Memory is not a model-callable tool. The assembler pulls transient context
//! before each provider call, and the loop pushes new evidence after
//! assistant/tool outputs. Concrete graph-memory implementations can process
//! pushed evidence asynchronously without changing provider or tool runtime
//! contracts.

const std = @import("std");
const transcript = @import("transcript.zig");

const Memory = @This();

ctx: ?*anyopaque = null,
pull_fn: *const fn (
    ctx: ?*anyopaque,
    input: PullInput,
) anyerror!PullResult = noopPull,
push_fn: *const fn (
    ctx: ?*anyopaque,
    input: PushInput,
) anyerror!void = noopPush,

/// Context available to pre-inference memory pull.
pub const PullInput = struct {
    history: []const transcript.Message,
    turn_index: usize,
};

/// Transient context to include in one provider request.
///
/// Message payloads are borrowed from the memory layer and must remain valid
/// until the current provider call returns. The agent loop does not append or
/// free these messages.
pub const PullResult = struct {
    messages: []const transcript.Message = &.{},
};

/// Evidence emitted after an inference or tool result.
pub const PushEvent = union(enum) {
    assistant: transcript.AssistantMessage,
    tool_result: transcript.ToolResultMessage,
    run_end: transcript.EndReason,
};

/// Evidence available to memory after one runtime event.
pub const PushInput = struct {
    history: []const transcript.Message,
    turn_index: usize,
    event: PushEvent,
};

/// No-op memory implementation for runs without a memory layer.
pub fn noop() Memory {
    return .{};
}

/// Pulls transient context for the next provider request.
pub fn pull(
    self: Memory,
    input: PullInput,
) anyerror!PullResult {
    return self.pull_fn(self.ctx, input);
}

/// Pushes new evidence to the memory layer.
pub fn push(
    self: Memory,
    input: PushInput,
) anyerror!void {
    return self.push_fn(self.ctx, input);
}

fn noopPull(
    ctx: ?*anyopaque,
    input: PullInput,
) !PullResult {
    _ = ctx;
    _ = input;
    return .{};
}

fn noopPush(
    ctx: ?*anyopaque,
    input: PushInput,
) !void {
    _ = ctx;
    _ = input;
}
