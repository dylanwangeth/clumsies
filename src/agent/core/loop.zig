//! Provider-neutral agent turn loop.
//!
//! The loop owns turn sequencing, event emission, and run-message growth. It
//! does not know any provider wire format or local tool implementation details:
//! provider adapters translate messages and tool definitions for model calls,
//! and `tool.Runtime` resolves and invokes model-requested tools.

const std = @import("std");
const Assembler = @import("assembler.zig");
const event = @import("event.zig");
const Memory = @import("memory.zig");
const Provider = @import("provider.zig");
const Session = @import("session.zig");
const Trace = @import("trace.zig");
const tool = @import("tool.zig");
const transcript = @import("transcript.zig");

/// Runtime dependencies and safety bounds for one agent run.
pub const RunOptions = struct {
    model_provider: Provider,
    provider_options: Provider.Options = .{},
    tool_runtime: *tool.Runtime,
    memory: ?Memory = null,
    session_entries: []const Session.Entry = &.{},
    event_sink: ?event.Sink = null,
    cancel: ?Cancel = null,
    max_turns: usize = 32,
};

/// Cooperative cancellation hook for long-running UI/RPC callers.
///
/// Cancellation is checked at agent-loop boundaries, not inside provider or
/// tool implementations. Blocking HTTP requests and local processes must still
/// return or time out before the loop can observe the stop request.
pub const Cancel = struct {
    ctx: *anyopaque,
    is_requested_fn: *const fn (ctx: *anyopaque) bool,

    pub fn isRequested(self: Cancel) bool {
        return self.is_requested_fn(self.ctx);
    }
};

/// Runs the provider-neutral agent loop until completion, termination, or turn
/// exhaustion.
///
/// `run` is the core orchestration boundary: it builds provider requests from
/// the current run message chain, appends assistant/tool-result messages, calls
/// local tools, and gives memory a chance to pull/push around every provider
/// inference. Older session entries are passed as facts for memory/assembly,
/// not appended into the run message chain by default. Message payloads are
/// copied by `transcript.Builder`, so providers and tools may return temporary buffers
/// as long as the loop appends them before deinit.
pub fn run(
    allocator: std.mem.Allocator,
    prompts: []const transcript.Message,
    options: RunOptions,
) !transcript.Run {
    var run_builder: transcript.Builder = .{};
    errdefer run_builder.deinit(allocator);

    try emit(options.event_sink, .agent_start);
    for (prompts) |prompt| {
        try run_builder.append(allocator, prompt);
        try emit(options.event_sink, .{ .message_append = prompt });
    }

    var turn_index: usize = 0;
    while (turn_index < options.max_turns) : (turn_index += 1) {
        if (isCancelled(options.cancel)) {
            try emit(options.event_sink, .{ .agent_end = .{
                .reason = .terminated,
                .message_count = run_builder.len(),
            } });
            var result = try run_builder.finish(allocator, .terminated);
            errdefer result.deinit(allocator);
            try pushMemory(options.memory, result.messages, options.session_entries, turn_index, .{ .run_end = .terminated });
            return result;
        }

        try emit(options.event_sink, .{ .turn_start = .{ .turn_index = turn_index } });

        // One provider response defines the full assistant turn, including any
        // unordered tool-call batch requested by the model.
        const available_tools = try options.tool_runtime.definitions();
        const assembled = try (Assembler{ .memory = options.memory }).build(allocator, .{
            .run_messages = run_builder.items(),
            .session_entries = options.session_entries,
            .tools = available_tools,
            .provider_options = options.provider_options,
            .turn_index = turn_index,
        });
        defer assembled.deinit(allocator);

        const assistant = try options.model_provider.respond(allocator, assembled.request);
        try run_builder.append(allocator, .{ .assistant = assistant });
        try emit(options.event_sink, .{ .message_append = .{ .assistant = assistant } });
        try pushMemory(options.memory, run_builder.items(), options.session_entries, turn_index, .{ .assistant = assistant });

        const tool_calls = assistant.tool_calls;
        if (isCancelled(options.cancel)) {
            try emit(options.event_sink, .{
                .turn_end = .{
                    .turn_index = turn_index,
                    .assistant = assistant,
                },
            });
            try emit(options.event_sink, .{ .agent_end = .{
                .reason = .terminated,
                .message_count = run_builder.len(),
            } });
            var result = try run_builder.finish(allocator, .terminated);
            errdefer result.deinit(allocator);
            try pushMemory(options.memory, result.messages, options.session_entries, turn_index, .{ .run_end = .terminated });
            return result;
        }

        if (tool_calls.len == 0) {
            try emit(options.event_sink, .{
                .turn_end = .{
                    .turn_index = turn_index,
                    .assistant = assistant,
                },
            });
            try emit(options.event_sink, .{ .agent_end = .{
                .reason = .complete,
                .message_count = run_builder.len(),
            } });
            var result = try run_builder.finish(allocator, .complete);
            errdefer result.deinit(allocator);
            try pushMemory(options.memory, result.messages, options.session_entries, turn_index, .{ .run_end = .complete });
            return result;
        }

        for (tool_calls) |call| {
            try emit(options.event_sink, .{ .tool_start = call });
        }

        // The tool runtime owns scheduling and per-tool failure handling, but
        // must return one result per input call so call ids stay aligned.
        const tool_results = try options.tool_runtime.executeBatch(allocator, tool_calls);
        defer {
            for (tool_results) |result| result.deinit(allocator);
            allocator.free(tool_results);
        }

        var stop_request_count: usize = 0;
        for (tool_calls, tool_results) |call, result| {
            // This is the provider boundary: local `tool.Result` values do not
            // carry provider ids, so the loop attaches the original call id
            // before the provider adapter serializes this as a role="tool"
            // transcript.
            if (result.control == .stop_run) stop_request_count += 1;
            try emit(options.event_sink, .{ .tool_end = .{ .call = call, .result = result } });

            const result_message: transcript.ToolResultMessage = .{
                .content = result.content,
                .tool_call_id = call.id,
                .is_error = result.is_error,
            };
            try run_builder.append(allocator, .{ .tool_result = result_message });
            try emit(options.event_sink, .{ .message_append = .{ .tool_result = result_message } });
            try pushMemory(options.memory, run_builder.items(), options.session_entries, turn_index, .{ .tool_result = result_message });
        }

        try emit(options.event_sink, .{
            .turn_end = .{
                .turn_index = turn_index,
                .assistant = assistant,
            },
        });

        if (stop_request_count > 0 or isCancelled(options.cancel)) {
            try emit(options.event_sink, .{ .agent_end = .{
                .reason = .terminated,
                .message_count = run_builder.len(),
            } });
            var result = try run_builder.finish(allocator, .terminated);
            errdefer result.deinit(allocator);
            try pushMemory(options.memory, result.messages, options.session_entries, turn_index, .{ .run_end = .terminated });
            return result;
        }
    }

    try emit(options.event_sink, .{ .agent_end = .{
        .reason = .max_turns,
        .message_count = run_builder.len(),
    } });
    var result = try run_builder.finish(allocator, .max_turns);
    errdefer result.deinit(allocator);
    try pushMemory(options.memory, result.messages, options.session_entries, turn_index, .{ .run_end = .max_turns });
    return result;
}

fn emit(event_sink: ?event.Sink, new_event: event.Event) !void {
    if (event_sink) |sink| try sink.emit(new_event);
}

fn isCancelled(cancel: ?Cancel) bool {
    if (cancel) |token| return token.isRequested();
    return false;
}

/// Pushes post-inference evidence when a memory layer is attached.
///
/// Memory is deliberately optional and outside the tool runtime; the loop calls
/// this helper after assistant messages, tool results, and run end events so a
/// future graph-memory layer can ingest evidence without becoming model-callable.
/// The next provider turn will pull memory again with the updated run messages.
fn pushMemory(
    memory_layer: ?Memory,
    run_messages: []const transcript.Message,
    session_entries: []const Session.Entry,
    turn_index: usize,
    push_event: Memory.PushEvent,
) !void {
    if (memory_layer) |memory| {
        try memory.push(.{
            .run_messages = run_messages,
            .session_entries = session_entries,
            .turn_index = turn_index,
            .event = push_event,
        });
    }
}

const testing = std.testing;

test "agent loop executes tools and continues until assistant completes" {
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "read", .arguments = "a.zig" },
        .{ .id = "call_2", .name = "grep", .arguments = "needle" },
    };
    var provider_state: TestProvider = .{ .first_tool_calls = &calls };
    var invoker_state: TestInvoker = .{};
    var registry_state: TestRegistry = .{ .definitions = &.{
        .{ .name = "read" },
        .{ .name = "grep" },
    } };
    var runtime: tool.Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };
    var trace = Trace.init(testing.allocator);
    defer trace.deinit();

    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "fix it" } },
    };
    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &runtime,
        .event_sink = trace.sink(),
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(transcript.EndReason, .complete), result.end_reason);
    try testing.expectEqual(@as(usize, 5), result.messages.len);
    try testing.expectEqual(@as(usize, 2), provider_state.calls);
    try testing.expectEqual(@as(usize, 2), invoker_state.calls);
    try testing.expectEqualStrings("call_1", result.messages[2].tool_result.tool_call_id);
    try testing.expectEqualStrings("call_2", result.messages[3].tool_result.tool_call_id);
    try testing.expectEqual(@as(usize, 15), trace.records.items.len);
    try testing.expectEqual(Trace.Record.agent_start, std.meta.activeTag(trace.records.items[0]));
    try testing.expectEqualStrings("read", trace.records.items[4].tool_start.name);
    try testing.expectEqualStrings("grep", trace.records.items[5].tool_start.name);
}

test "agent loop stops when a tool result requests stop_run" {
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "stop" },
    };
    var provider_state: TestProvider = .{
        .first_tool_calls = &calls,
        .expected_tools_len = 1,
    };
    var invoker_state: TestInvoker = .{ .stop_run = true };
    var registry_state: TestRegistry = .{ .definitions = &.{
        .{ .name = "stop" },
    } };
    var runtime: tool.Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "stop after tool" } },
    };

    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &runtime,
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
    var invoker_state: TestInvoker = .{ .stop_run_call_index = 0 };
    var registry_state: TestRegistry = .{ .definitions = &.{
        .{ .name = "stop" },
        .{ .name = "read" },
    } };
    var runtime: tool.Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "stop after one tool" } },
    };

    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &runtime,
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
    var invoker_state: TestInvoker = .{};
    var registry_state: TestRegistry = .{ .definitions = &.{
        .{ .name = "loop" },
    } };
    var runtime: tool.Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "loop" } },
    };

    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &runtime,
        .max_turns = 1,
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(transcript.EndReason, .max_turns), result.end_reason);
    try testing.expectEqual(@as(usize, 3), result.messages.len);
}

test "agent loop terminates before provider call when cancellation is already requested" {
    const calls = [_]tool.Call{};
    var provider_state: TestProvider = .{ .first_tool_calls = &calls };
    var invoker_state: TestInvoker = .{};
    var registry_state: TestRegistry = .{ .definitions = &.{} };
    var runtime: tool.Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };
    var cancel_state: TestCancel = .{ .requested = true };
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "stop now" } },
    };

    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &runtime,
        .cancel = cancel_state.cancel(),
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(transcript.EndReason, .terminated), result.end_reason);
    try testing.expectEqual(@as(usize, 1), result.messages.len);
    try testing.expectEqual(@as(usize, 0), provider_state.calls);
}

test "agent loop terminates after current tool batch when cancellation is requested" {
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "read" },
    };
    var cancel_requested = false;
    var provider_state: TestProvider = .{ .first_tool_calls = &calls };
    var invoker_state: TestInvoker = .{ .cancel_after_call = &cancel_requested };
    var registry_state: TestRegistry = .{ .definitions = &.{
        .{ .name = "read" },
    } };
    var runtime: tool.Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };
    var cancel_state: TestCancel = .{ .requested_ptr = &cancel_requested };
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "read then stop" } },
    };

    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &runtime,
        .cancel = cancel_state.cancel(),
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(transcript.EndReason, .terminated), result.end_reason);
    try testing.expectEqual(@as(usize, 3), result.messages.len);
    try testing.expectEqual(@as(usize, 1), provider_state.calls);
    try testing.expect(cancel_requested);
}

test "agent loop uses the configured tool runtime" {
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "write" },
    };
    const definitions = [_]tool.Definition{
        .{
            .name = "write",
            .scheduling = .serial,
            .effects = .{ .writes_workspace = true },
            .failure_policy = .stop_on_error,
        },
    };
    var provider_state: TestProvider = .{ .first_tool_calls = &calls };
    var invoker_state: TestInvoker = .{
        .expected_definition = definitions[0],
    };
    var registry_state: TestRegistry = .{ .definitions = &definitions };
    var runtime: tool.Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "write file" } },
    };

    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &runtime,
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), registry_state.lookups);
    try testing.expectEqual(@as(usize, 2), registry_state.lists);
    try testing.expectEqual(@as(transcript.EndReason, .complete), result.end_reason);
}

test "agent loop pulls memory context for provider calls and pushes inference evidence" {
    var memory_state: TestMemory = .{};
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "read" },
    };
    var provider_state: TestProvider = .{
        .first_tool_calls = &calls,
        .expected_leading_memory = true,
    };
    var invoker_state: TestInvoker = .{};
    var registry_state: TestRegistry = .{ .definitions = &.{
        .{ .name = "read" },
    } };
    var runtime: tool.Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };
    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "use pulled context" } },
    };

    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &runtime,
        .memory = memory_state.memory(),
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), memory_state.pull_count);
    try testing.expectEqual(@as(usize, 4), memory_state.push_count);
    try testing.expect(memory_state.saw_assistant);
    try testing.expect(memory_state.saw_tool_result);
    try testing.expect(memory_state.saw_run_end);
    try testing.expectEqual(@as(usize, 4), result.messages.len);
    try testing.expectEqual(@as(std.meta.Tag(transcript.Message), .user), std.meta.activeTag(result.messages[0]));
    try testing.expectEqualStrings("use pulled context", result.messages[0].user.content);
    try testing.expectEqual(@as(usize, 4), memory_state.last_run_message_len);
}

// Private adapters used by this file's tests. Keeping them here makes the
// provider/tool contracts executable without exporting scripted runtime types.
const TestProvider = struct {
    calls: usize = 0,
    first_tool_calls: []const tool.Call,
    expected_tools_len: ?usize = null,
    expected_leading_memory: bool = false,

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
        if (self.expected_tools_len) |expected| {
            try testing.expectEqual(expected, request.tools.len);
        }
        if (self.expected_leading_memory) {
            try testing.expect(request.messages.len > 0);
            try testing.expectEqualStrings("memory context", request.messages[0].user.content);
        }
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

const TestCancel = struct {
    requested: bool = false,
    requested_ptr: ?*bool = null,

    fn cancel(self: *TestCancel) Cancel {
        return .{ .ctx = self, .is_requested_fn = isRequested };
    }

    fn isRequested(ctx: *anyopaque) bool {
        const self: *TestCancel = @ptrCast(@alignCast(ctx));
        if (self.requested_ptr) |requested| return requested.*;
        return self.requested;
    }
};

const TestInvoker = struct {
    calls: usize = 0,
    stop_run: bool = false,
    stop_run_call_index: ?usize = null,
    expected_definition: ?tool.Definition = null,
    cancel_after_call: ?*bool = null,

    fn invoker(self: *TestInvoker) tool.Invoker {
        return .{ .ctx = self, .invoke_fn = invoke };
    }

    fn invoke(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        call: tool.Call,
        definition: tool.Definition,
    ) !tool.Result {
        _ = allocator;
        const self: *TestInvoker = @ptrCast(@alignCast(ctx));
        if (self.expected_definition) |expected| {
            try expectDefinitionEqual(expected, definition);
        }

        const call_index = self.calls;
        self.calls += 1;
        if (self.cancel_after_call) |requested| requested.* = true;
        const stop_run = self.stop_run or
            (self.stop_run_call_index != null and self.stop_run_call_index.? == call_index);
        return .{
            .content = call.name,
            .control = if (stop_run) .stop_run else .continue_run,
        };
    }
};

const TestRegistry = struct {
    definitions: []const tool.Definition,
    lookups: usize = 0,
    lists: usize = 0,

    fn registry(self: *TestRegistry) tool.Registry {
        return .{ .ctx = self, .lookup_fn = lookup, .list_fn = list };
    }

    fn lookup(ctx: *anyopaque, name: []const u8) !?tool.Definition {
        const self: *TestRegistry = @ptrCast(@alignCast(ctx));
        self.lookups += 1;
        for (self.definitions) |definition| {
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }

    fn list(ctx: *anyopaque) ![]const tool.Definition {
        const self: *TestRegistry = @ptrCast(@alignCast(ctx));
        self.lists += 1;
        return self.definitions;
    }
};

fn expectDefinitionEqual(expected: tool.Definition, actual: tool.Definition) !void {
    try testing.expectEqualStrings(expected.name, actual.name);
    try testing.expectEqualStrings(expected.description, actual.description);
    try testing.expectEqual(expected.kind, actual.kind);
    try testing.expectEqual(expected.scheduling, actual.scheduling);
    try testing.expectEqual(expected.effects.reads_workspace, actual.effects.reads_workspace);
    try testing.expectEqual(expected.effects.writes_workspace, actual.effects.writes_workspace);
    try testing.expectEqual(expected.effects.external_side_effect, actual.effects.external_side_effect);
    try testing.expectEqual(expected.failure_policy, actual.failure_policy);
}

const TestMemory = struct {
    pull_count: usize = 0,
    push_count: usize = 0,
    last_run_message_len: usize = 0,
    saw_assistant: bool = false,
    saw_tool_result: bool = false,
    saw_run_end: bool = false,
    context_messages: [1]transcript.Message = .{
        .{ .user = .{ .content = "memory context" } },
    },

    fn memory(self: *TestMemory) Memory {
        return .{
            .ctx = self,
            .pull_fn = pull,
            .push_fn = push,
        };
    }

    fn pull(
        ctx: ?*anyopaque,
        input: Memory.PullInput,
    ) !Memory.PullResult {
        const self: *TestMemory = @ptrCast(@alignCast(ctx.?));
        self.pull_count += 1;
        self.last_run_message_len = input.run_messages.len;
        try testing.expectEqual(@as(usize, 0), input.session_entries.len);
        try testing.expectEqual(self.pull_count - 1, input.turn_index);
        return .{ .messages = self.context_messages[0..] };
    }

    fn push(
        ctx: ?*anyopaque,
        input: Memory.PushInput,
    ) !void {
        const self: *TestMemory = @ptrCast(@alignCast(ctx.?));
        self.push_count += 1;
        self.last_run_message_len = input.run_messages.len;
        try testing.expectEqual(@as(usize, 0), input.session_entries.len);
        switch (input.event) {
            .assistant => self.saw_assistant = true,
            .tool_result => self.saw_tool_result = true,
            .run_end => self.saw_run_end = true,
        }
    }
};
