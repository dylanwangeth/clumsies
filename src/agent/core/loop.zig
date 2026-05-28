//! Provider-neutral agent turn loop.
//!
//! The loop owns turn sequencing, event emission, and transcript growth. It
//! does not know any provider wire format or local tool implementation details:
//! provider adapters translate transcript/tool definitions for model calls, and
//! `tool.Runtime` resolves and invokes model-requested tools.

const std = @import("std");
const Assembler = @import("assembler.zig");
const event = @import("event.zig");
const Memory = @import("memory.zig");
const Provider = @import("provider.zig");
const tool = @import("tool.zig");
const transcript = @import("transcript.zig");

/// Runtime dependencies and safety bounds for one agent run.
pub const RunOptions = struct {
    model_provider: Provider,
    provider_options: Provider.Options = .{},
    tool_runtime: *tool.Runtime,
    memory: ?Memory = null,
    event_sink: ?event.Sink = null,
    max_turns: usize = 32,
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
    var history: transcript.Builder = .{};
    errdefer history.deinit(allocator);

    try emit(options.event_sink, .agent_start);
    for (prompts) |message| {
        try history.append(allocator, message);
        try emit(options.event_sink, .{ .message_append = message });
    }

    var turn_index: usize = 0;
    while (turn_index < options.max_turns) : (turn_index += 1) {
        try emit(options.event_sink, .{ .turn_start = .{ .turn_index = turn_index } });

        // One provider response defines the full assistant turn, including any
        // unordered tool-call batch requested by the model.
        const available_tools = try options.tool_runtime.definitions();
        const request = try (Assembler{ .memory = options.memory }).build(.{
            .history = history.items(),
            .tools = available_tools,
            .provider_options = options.provider_options,
            .turn_index = turn_index,
        });
        const assistant = try options.model_provider.respond(allocator, request);
        try history.append(allocator, .{ .assistant = assistant });
        try emit(options.event_sink, .{ .message_append = .{ .assistant = assistant } });
        try pushMemory(options.memory, history.items(), turn_index, .{ .assistant = assistant });

        const tool_calls = assistant.tool_calls;
        if (tool_calls.len == 0) {
            try emit(options.event_sink, .{
                .turn_end = .{
                    .turn_index = turn_index,
                    .assistant = assistant,
                },
            });
            try emit(options.event_sink, .{ .agent_end = .{
                .reason = .complete,
                .message_count = history.len(),
            } });
            var result = try history.finish(allocator, .complete);
            errdefer result.deinit(allocator);
            try pushMemory(options.memory, result.messages, turn_index, .{ .run_end = .complete });
            return result;
        }

        for (tool_calls) |call| {
            try emit(options.event_sink, .{ .tool_start = call });
        }

        // The tool runtime owns scheduling and per-tool failure handling, but
        // must return one result per input call so call ids stay aligned.
        const tool_results = try options.tool_runtime.executeBatch(allocator, tool_calls);
        defer allocator.free(tool_results);

        var stop_request_count: usize = 0;
        for (tool_calls, tool_results) |call, result| {
            // This is the provider boundary: local `tool.Result` values do not
            // carry provider ids, so the loop attaches the original call id
            // before the provider adapter serializes this as a role="tool"
            // message.
            if (result.control == .stop_run) stop_request_count += 1;
            try emit(options.event_sink, .{ .tool_end = .{ .call = call, .result = result } });

            const result_message: transcript.ToolResultMessage = .{
                .content = result.content,
                .tool_call_id = call.id,
                .is_error = result.is_error,
            };
            try history.append(allocator, .{ .tool_result = result_message });
            try emit(options.event_sink, .{ .message_append = .{ .tool_result = result_message } });
            try pushMemory(options.memory, history.items(), turn_index, .{ .tool_result = result_message });
        }

        try emit(options.event_sink, .{
            .turn_end = .{
                .turn_index = turn_index,
                .assistant = assistant,
            },
        });

        if (stop_request_count > 0) {
            try emit(options.event_sink, .{ .agent_end = .{
                .reason = .terminated,
                .message_count = history.len(),
            } });
            var result = try history.finish(allocator, .terminated);
            errdefer result.deinit(allocator);
            try pushMemory(options.memory, result.messages, turn_index, .{ .run_end = .terminated });
            return result;
        }
    }

    try emit(options.event_sink, .{ .agent_end = .{
        .reason = .max_turns,
        .message_count = history.len(),
    } });
    var result = try history.finish(allocator, .max_turns);
    errdefer result.deinit(allocator);
    try pushMemory(options.memory, result.messages, turn_index, .{ .run_end = .max_turns });
    return result;
}

fn emit(event_sink: ?event.Sink, new_event: event.Event) !void {
    if (event_sink) |sink| try sink.emit(new_event);
}

fn pushMemory(
    memory_layer: ?Memory,
    history: []const transcript.Message,
    turn_index: usize,
    push_event: Memory.PushEvent,
) !void {
    if (memory_layer) |memory| {
        try memory.push(.{
            .history = history,
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
    var recorder: EventRecorder = .{};
    defer recorder.deinit(testing.allocator);

    const prompts = [_]transcript.Message{
        .{ .user = .{ .content = "fix it" } },
    };
    const result = try run(testing.allocator, &prompts, .{
        .model_provider = provider_state.provider(),
        .tool_runtime = &runtime,
        .event_sink = recorder.sink(),
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(transcript.EndReason, .complete), result.end_reason);
    try testing.expectEqual(@as(usize, 5), result.messages.len);
    try testing.expectEqual(@as(usize, 2), provider_state.calls);
    try testing.expectEqual(@as(usize, 2), invoker_state.calls);
    try testing.expectEqualStrings("call_1", result.messages[2].tool_result.tool_call_id);
    try testing.expectEqualStrings("call_2", result.messages[3].tool_result.tool_call_id);
    try testing.expectEqual(@as(usize, 15), recorder.events.items.len);
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
        .expected_context_len = 1,
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
    try testing.expectEqual(@as(usize, 4), memory_state.last_history_len);
}

// Private adapters used by this file's tests. Keeping them here makes the
// provider/tool contracts executable without exporting scripted runtime types.
const TestProvider = struct {
    calls: usize = 0,
    first_tool_calls: []const tool.Call,
    expected_tools_len: ?usize = null,
    expected_context_len: ?usize = null,

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
        if (self.expected_context_len) |expected| {
            try testing.expectEqual(expected, request.context.len);
            try testing.expectEqualStrings("memory context", request.context[0].user.content);
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

const TestInvoker = struct {
    calls: usize = 0,
    stop_run: bool = false,
    stop_run_call_index: ?usize = null,
    expected_definition: ?tool.Definition = null,

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

const TestMemory = struct {
    pull_count: usize = 0,
    push_count: usize = 0,
    last_history_len: usize = 0,
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
        self.last_history_len = input.history.len;
        try testing.expectEqual(self.pull_count - 1, input.turn_index);
        return .{ .messages = self.context_messages[0..] };
    }

    fn push(
        ctx: ?*anyopaque,
        input: Memory.PushInput,
    ) !void {
        const self: *TestMemory = @ptrCast(@alignCast(ctx.?));
        self.push_count += 1;
        self.last_history_len = input.history.len;
        switch (input.event) {
            .assistant => self.saw_assistant = true,
            .tool_result => self.saw_tool_result = true,
            .run_end => self.saw_run_end = true,
        }
    }
};
