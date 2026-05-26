//! Tool-call types and execution adapter for the agent loop.

const std = @import("std");

/// A provider-normalized request to invoke one local tool.
pub const Call = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8 = "",
};

/// Result of one tool invocation.
///
/// `control` can request that the runtime stop the agent after recording the
/// current assistant turn's full tool-result batch.
pub const Result = struct {
    content: []const u8,
    is_error: bool = false,
    control: Control = .continue_run,
};

/// Runtime control signal carried by a tool result.
///
/// This is separate from `Result.is_error`. A tool error is model-visible data:
/// the result is appended to the transcript and the provider can recover in the
/// next turn. `.stop_run` is a control-plane signal: after the runtime records
/// the current assistant turn's full tool-result batch, it stops the run instead
/// of asking the provider for another turn.
///
/// For example, a failed grep or test command should usually be returned as
/// `Result{ .is_error = true, .control = .continue_run }` so the model can
/// react. A user cancellation, safety stop, or approval denial that must halt
/// the agent should use `.stop_run`.
pub const Control = enum {
    continue_run,
    stop_run,
};

/// How per-tool failures should affect the rest of a batch.
pub const FailurePolicy = enum {
    collect_all,
    stop_on_error,
};

/// Tool adapter used by the loop to execute assistant-requested call batches.
pub const Executor = struct {
    ctx: *anyopaque,
    execute_batch_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        calls: []const Call,
        failure_policy: FailurePolicy,
    ) anyerror![]Result,

    /// Executes one batch and returns one result per call in input order.
    ///
    /// A batch represents tool calls requested by one assistant turn. The calls
    /// are not ordered by model semantics; the executor should use its tool
    /// registry or runtime metadata to decide which calls can run in parallel
    /// and which calls require exclusive serial execution.
    ///
    /// Per-tool failures that can be shown to the model should be returned as
    /// `Result{ .is_error = true }`. Returning an error from this function
    /// means the runtime itself cannot continue the batch.
    ///
    /// With `.collect_all`, the executor should produce one result for every
    /// input call. With `.stop_on_error`, the executor may stop after the first
    /// failure, but must still return one result per input call so the provider
    /// can receive a response for every requested tool call id.
    ///
    /// The caller owns the returned result slice. Individual result payloads
    /// follow the executor's documented lifetime rules.
    pub fn executeBatch(
        self: Executor,
        allocator: std.mem.Allocator,
        calls: []const Call,
        failure_policy: FailurePolicy,
    ) anyerror![]Result {
        return self.execute_batch_fn(self.ctx, allocator, calls, failure_policy);
    }
};
