//! Minimal memory boundary around provider inferences.
//!
//! Memory is not a model-callable tool. The assembler pulls transient context
//! before every provider call, not just before the first user prompt in a run.
//! That lets future graph memory react to fresh assistant/tool evidence between
//! tool-call turns without becoming part of the tool runtime.
//!
//! Concrete implementations may process pushed evidence asynchronously. The
//! core contract only requires a request-scoped pull result that remains valid
//! until the current provider call returns.

const std = @import("std");
const Session = @import("session.zig");
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

/// Context available to one pre-inference memory pull.
///
/// `run_messages` is the current run's linear provider protocol chain. It must
/// preserve assistant tool calls and matching tool results so the next model
/// call can reason about what just happened. `session_entries` contains older
/// durable conversation facts that memory may use for recall, but those entries
/// are not automatically replayed into the provider request.
pub const PullInput = struct {
    run_messages: []const transcript.Message,
    session_entries: []const Session.Entry = &.{},
    turn_index: usize,
};

/// Transient context to include in one provider request.
///
/// Message payloads are borrowed from the memory layer and must remain valid
/// until the current provider call returns. These are still provider-neutral
/// messages, not a special `memory` role; the assembler/provider
/// path must render memory into roles supported by the target API. The agent
/// loop does not append or free these messages.
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
///
/// The loop pushes evidence after each assistant response and tool result, then
/// pulls again before the next provider call. This supports per-inference
/// recall inside a single agent run even when no durable graph memory is
/// attached yet.
pub const PushInput = struct {
    run_messages: []const transcript.Message,
    session_entries: []const Session.Entry = &.{},
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
