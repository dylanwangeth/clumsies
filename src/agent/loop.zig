//! Provider-neutral agent turn loop.

const std = @import("std");
const event = @import("event.zig");
const Provider = @import("provider.zig");
const tool = @import("tool.zig");
const transcript = @import("transcript.zig");

/// Runtime dependencies and safety bounds for one agent run.
pub const RunOptions = struct {
    model_provider: Provider,
    provider_options: Provider.Options = .{},
    tool_executor: tool.Executor,
    event_sink: ?event.Sink = null,
    max_turns: usize = 32,
    tool_failure_policy: tool.FailurePolicy = .collect_all,
};

/// Runs the provider-neutral agent loop until completion, termination, or turn
/// exhaustion.
///
/// Prompt messages are copied into the returned transcript array as borrowed
/// message values. Provider and tool adapters are responsible for ensuring
/// nested content slices remain valid for the returned transcript lifetime.
pub fn run(
    allocator: std.mem.Allocator,
    prompts: []const transcript.Message,
    options: RunOptions,
) !transcript.Transcript {
    var messages: std.ArrayList(transcript.Message) = .empty;
    errdefer messages.deinit(allocator);

    try emit(options.event_sink, .agent_start);
    for (prompts) |message| {
        try messages.append(allocator, message);
        try emit(options.event_sink, .{ .message_append = message });
    }

    var turn_index: usize = 0;
    while (turn_index < options.max_turns) : (turn_index += 1) {
        try emit(options.event_sink, .{ .turn_start = .{ .turn_index = turn_index } });

        // One provider response defines the full assistant turn, including any
        // unordered tool-call batch requested by the model.
        const assistant = try options.model_provider.respond(allocator, .{
            .messages = messages.items,
            .options = options.provider_options,
        });
        try messages.append(allocator, .{ .assistant = assistant });
        try emit(options.event_sink, .{ .message_append = .{ .assistant = assistant } });

        const tool_calls = assistant.tool_calls;
        if (tool_calls.len == 0) {
            try emit(options.event_sink, .{
                .turn_end = .{
                    .turn_index = turn_index,
                    .assistant = assistant,
                },
            });
            return finish(allocator, &messages, options.event_sink, .complete);
        }

        for (tool_calls) |call| {
            try emit(options.event_sink, .{ .tool_start = call });
        }

        // The executor owns scheduling and per-tool failure handling, but must
        // return one result per input call so call ids stay aligned.
        const tool_results = try options.tool_executor.executeBatch(
            allocator,
            tool_calls,
            options.tool_failure_policy,
        );
        defer allocator.free(tool_results);
        if (tool_results.len != tool_calls.len) return error.InvalidToolBatchResult;

        var stop_request_count: usize = 0;
        for (tool_calls, tool_results) |call, result| {
            // Tool results are appended in request order even if the executor
            // runs the batch concurrently.
            if (result.control == .stop_run) stop_request_count += 1;
            try emit(options.event_sink, .{ .tool_end = .{ .call = call, .result = result } });

            const result_message: transcript.ToolResultMessage = .{
                .content = result.content,
                .tool_call_id = call.id,
                .is_error = result.is_error,
            };
            try messages.append(allocator, .{ .tool_result = result_message });
            try emit(options.event_sink, .{ .message_append = .{ .tool_result = result_message } });
        }

        try emit(options.event_sink, .{
            .turn_end = .{
                .turn_index = turn_index,
                .assistant = assistant,
            },
        });

        if (stop_request_count > 0) {
            return finish(allocator, &messages, options.event_sink, .terminated);
        }
    }

    return finish(allocator, &messages, options.event_sink, .max_turns);
}

fn finish(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(transcript.Message),
    event_sink: ?event.Sink,
    reason: transcript.EndReason,
) !transcript.Transcript {
    try emit(event_sink, .{ .agent_end = .{
        .reason = reason,
        .message_count = messages.items.len,
    } });
    return .{
        .messages = try messages.toOwnedSlice(allocator),
        .end_reason = reason,
    };
}

fn emit(event_sink: ?event.Sink, new_event: event.Event) !void {
    if (event_sink) |sink| try sink.emit(new_event);
}

const testing = std.testing;

test "agent loop executes tools and continues until assistant completes" {
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "read", .arguments = "a.zig" },
        .{ .id = "call_2", .name = "grep", .arguments = "needle" },
    };
    var provider_state: TestProvider = .{ .first_tool_calls = &calls };
    var tool_state: TestToolExecutor = .{};
    var recorder: EventRecorder = .{};
    defer recorder.deinit(testing.allocator);

    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "fix it" } },
    };
    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_executor = tool_state.executor(),
        .event_sink = recorder.sink(),
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(transcript.EndReason, .complete), result.end_reason);
    try testing.expectEqual(@as(usize, 5), result.messages.len);
    try testing.expectEqual(@as(usize, 2), provider_state.calls);
    try testing.expectEqual(@as(usize, 2), tool_state.calls);
    try testing.expectEqualStrings("call_1", result.messages[2].tool_result.tool_call_id);
    try testing.expectEqualStrings("call_2", result.messages[3].tool_result.tool_call_id);
    try testing.expectEqual(@as(usize, 15), recorder.events.items.len);
}

test "agent loop stops when a tool result requests stop_run" {
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "stop" },
    };
    var provider_state: TestProvider = .{ .first_tool_calls = &calls };
    var tool_state: TestToolExecutor = .{ .stop_run = true };
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "stop after tool" } },
    };

    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_executor = tool_state.executor(),
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(transcript.EndReason, .terminated), result.end_reason);
    try testing.expectEqual(@as(usize, 3), result.messages.len);
    try testing.expectEqual(@as(usize, 1), provider_state.calls);
}

test "agent loop stops after appending all results when one result requests stop_run" {
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "stop" },
        .{ .id = "call_2", .name = "read" },
    };
    var provider_state: TestProvider = .{ .first_tool_calls = &calls };
    var tool_state: TestToolExecutor = .{ .stop_run_call_index = 0 };
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "stop after one tool" } },
    };

    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_executor = tool_state.executor(),
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(transcript.EndReason, .terminated), result.end_reason);
    try testing.expectEqual(@as(usize, 4), result.messages.len);
    try testing.expectEqualStrings("call_1", result.messages[2].tool_result.tool_call_id);
    try testing.expectEqualStrings("call_2", result.messages[3].tool_result.tool_call_id);
    try testing.expectEqual(@as(usize, 1), provider_state.calls);
}

test "agent loop returns max turns when assistant keeps calling tools" {
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "loop" },
    };
    var provider_state: TestProvider = .{ .first_tool_calls = &calls };
    var tool_state: TestToolExecutor = .{};
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "loop" } },
    };

    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_executor = tool_state.executor(),
        .max_turns = 1,
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(transcript.EndReason, .max_turns), result.end_reason);
    try testing.expectEqual(@as(usize, 3), result.messages.len);
}

test "agent loop rejects tool batches with mismatched result counts" {
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "read" },
        .{ .id = "call_2", .name = "grep" },
    };
    var provider_state: TestProvider = .{ .first_tool_calls = &calls };
    var tool_state: TestToolExecutor = .{ .result_count_override = 1 };
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "mismatch" } },
    };

    try testing.expectError(error.InvalidToolBatchResult, run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_executor = tool_state.executor(),
    }));
}

// Private adapters used by this file's tests. Keeping them here makes the
// provider/tool contracts executable without exporting scripted runtime types.
const TestProvider = struct {
    calls: usize = 0,
    first_tool_calls: []const tool.Call,

    fn provider(self: *TestProvider) Provider {
        return .{ .ctx = self, .respond_fn = respond };
    }

    fn respond(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        request: Provider.Request,
    ) !transcript.AssistantMessage {
        _ = allocator;
        const self: *TestProvider = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            return .{
                .content = "need tools",
                .tool_calls = self.first_tool_calls,
            };
        }
        try testing.expectEqual(@as(std.meta.Tag(transcript.Message), .tool_result), std.meta.activeTag(request.messages[request.messages.len - 1]));
        return .{ .content = "done" };
    }
};

const TestToolExecutor = struct {
    calls: usize = 0,
    stop_run: bool = false,
    stop_run_call_index: ?usize = null,
    result_count_override: ?usize = null,

    fn executor(self: *TestToolExecutor) tool.Executor {
        return .{ .ctx = self, .execute_batch_fn = executeBatch };
    }

    fn executeBatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        calls: []const tool.Call,
        failure_policy: tool.FailurePolicy,
    ) ![]tool.Result {
        try testing.expectEqual(tool.FailurePolicy.collect_all, failure_policy);
        const self: *TestToolExecutor = @ptrCast(@alignCast(ctx));
        const result_count = self.result_count_override orelse calls.len;
        const results = try allocator.alloc(tool.Result, result_count);
        for (results, 0..) |*result, idx| {
            self.calls += 1;
            const content = if (idx < calls.len) calls[idx].name else "extra";
            const stop_run = self.stop_run or
                (self.stop_run_call_index != null and self.stop_run_call_index.? == idx);
            result.* = .{
                .content = content,
                .control = if (stop_run) .stop_run else .continue_run,
            };
        }
        return results;
    }
};

const EventRecorder = struct {
    events: std.ArrayList(event.Event) = .empty,

    fn deinit(self: *EventRecorder, allocator: std.mem.Allocator) void {
        self.events.deinit(allocator);
    }

    fn sink(self: *EventRecorder) event.Sink {
        return .{ .ctx = self, .emit_fn = emitEvent };
    }

    fn emitEvent(ctx: *anyopaque, new_event: event.Event) !void {
        const self: *EventRecorder = @ptrCast(@alignCast(ctx));
        try self.events.append(testing.allocator, new_event);
    }
};
