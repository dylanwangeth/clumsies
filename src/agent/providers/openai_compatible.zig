//! OpenAI-compatible Chat Completions provider adapter.
//!
//! This module is the provider-specific translation boundary for the agent
//! core. It consumes provider-neutral transcript messages and tool definitions,
//! materializes the OpenAI-compatible Chat Completions request shape, then
//! normalizes the assistant response back into the core assistant-message type.
//!
//! Tool conversion happens in both directions here by design. Request-level
//! `tools[]` declares what the model may call for the current request, while
//! message-level `tool_calls` replays tool-call requests already made by prior
//! assistant turns. Local tool results are represented internally as
//! transcript tool-result messages and serialized here as `role = "tool"`.

const std = @import("std");
const http = std.http;
const ProviderTransport = @import("../../net/provider_transport.zig");
const Provider = @import("../core/provider.zig");
const RuntimeLog = @import("../core/runtime_log.zig");
const tool = @import("../core/tool.zig");
const transcript = @import("../core/transcript.zig");
const OpenAICompatible = @This();

allocator: std.mem.Allocator,
runtime_log: ?*RuntimeLog = null,
config: Config,
transport: ProviderTransport,
arena: std.heap.ArenaAllocator,
last_error: ?ProviderError = null,
last_transport_failure: ?ProviderTransport.Failure = null,

pub const Config = struct {
    id: []const u8 = "openai-compatible",
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    context_window: usize = 131072,
    auth: Auth = .bearer,
    request_timeout_ms: ?u64 = 60 * std.time.ms_per_s,
    use_env_proxy: bool = true,
};

pub const Auth = union(enum) {
    bearer,
    api_key: []const u8,
};

pub const ProviderError = struct {
    status: http.Status,
    body: []const u8,

    /// Releases the retained HTTP error body.
    pub fn deinit(self: ProviderError, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

const RequestBody = struct {
    model: []const u8,
    messages: []const MessageJson,
    tools: ?[]const ToolDefinitionJson = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    max_tokens: ?u32 = null,
    stream: bool = false,
};

/// OpenAI-compatible message shape used inside Chat Completions requests.
///
/// Message-level `tool_calls` replays prior assistant tool-call requests,
/// paired with later `role = "tool"` messages via `tool_call_id`. Top-level
/// `tools` is a separate request contract for declaring what the model may call.
const MessageJson = struct {
    role: Role,
    content: []const u8 = "",
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]const ToolCallJson = null,
};

const Role = enum {
    user,
    assistant,
    tool,
};

const ToolCallJson = struct {
    id: []const u8,
    type: ToolCallType = .function,
    function: FunctionJson,
};

const ToolCallType = enum {
    function,
};

const ToolDefinitionJson = struct {
    type: ToolCallType = .function,
    function: FunctionDefinitionJson,
};

const FunctionDefinitionJson = struct {
    name: []const u8,
    description: []const u8 = "",
    parameters: std.json.Value,
};

const FunctionJson = struct {
    name: []const u8,
    arguments: []const u8,
};

const ToolDefinitionsJson = struct {
    tools: []const ToolDefinitionJson,
    parsed_parameters: []std.json.Parsed(std.json.Value),

    /// Releases parsed JSON schema objects held alive for request stringify.
    fn deinit(self: ToolDefinitionsJson, allocator: std.mem.Allocator) void {
        for (self.parsed_parameters) |parsed| {
            parsed.deinit();
        }
        if (self.parsed_parameters.len > 0) allocator.free(self.parsed_parameters);
        if (self.tools.len > 0) allocator.free(self.tools);
    }
};

const ResponseJson = struct {
    choices: []const ChoiceJson = &.{},
};

const ChoiceJson = struct {
    message: AssistantJson,
    finish_reason: ?[]const u8 = null,
};

const AssistantJson = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCallJson = null,
    reasoning_content: ?[]const u8 = null,
};

/// Creates an OpenAI-compatible provider with a persistent HTTP client.
pub fn init(allocator: std.mem.Allocator, config: Config) OpenAICompatible {
    return .{
        .allocator = allocator,
        .config = config,
        .transport = ProviderTransport.init(allocator),
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
}

/// Releases provider-owned HTTP state and arena-backed assistant payloads.
pub fn deinit(self: *OpenAICompatible) void {
    self.clearLastError();
    self.arena.deinit();
    self.transport.deinit();
}

/// Moves the last HTTP error out for CLI/UI diagnostics.
///
/// Non-OK provider responses return `error.ProviderRequestFailed`; this method
/// lets callers retrieve the response status/body without making that transport
/// shape part of the provider-neutral core interface.
pub fn takeLastError(self: *OpenAICompatible) ?ProviderError {
    const last_error = self.last_error;
    self.last_error = null;
    return last_error;
}

/// Moves the last transport-stage failure out for CLI/UI diagnostics.
pub fn takeLastTransportFailure(self: *OpenAICompatible) ?ProviderTransport.Failure {
    const failure = self.last_transport_failure;
    self.last_transport_failure = null;
    return failure;
}

/// Exposes this adapter through the provider-neutral core port.
pub fn provider(self: *OpenAICompatible) Provider {
    return .{
        .ctx = self,
        .respond_fn = respond,
        .metadata_fn = metadata,
    };
}

/// Returns provider identity without coupling the core to adapter config.
fn metadata(ctx: *anyopaque) Provider.Metadata {
    const self: *OpenAICompatible = @ptrCast(@alignCast(ctx));
    return .{
        .id = self.config.id,
        .model = self.config.model,
        .context_window = self.config.context_window,
    };
}

/// Executes one OpenAI-compatible chat completions request.
///
/// This is the adapter's main boundary: it serializes the assembler-built
/// message list, declares available tools, sends the wire request, and
/// normalizes the first assistant choice back into core types.
fn respond(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    request: Provider.Request,
) !transcript.AssistantMessage {
    const self: *OpenAICompatible = @ptrCast(@alignCast(ctx));

    const messages_json = try allocator.alloc(MessageJson, request.messages.len);
    defer allocator.free(messages_json);
    var message_count: usize = 0;
    defer freeMessageJson(allocator, messages_json[0..message_count]);
    for (request.messages, messages_json) |message, *message_json| {
        message_json.* = try messageToJson(allocator, message);
        message_count += 1;
    }

    const tools_json = try toolDefinitionsToJson(allocator, request.tools);
    defer tools_json.deinit(allocator);

    const body = try std.json.Stringify.valueAlloc(allocator, RequestBody{
        .model = self.config.model,
        .messages = messages_json,
        .tools = if (tools_json.tools.len == 0) null else tools_json.tools,
        .temperature = request.options.temperature,
        .top_p = request.options.top_p,
        .max_tokens = request.options.max_output_tokens,
    }, .{ .emit_null_optional_fields = false });
    defer allocator.free(body);

    if (self.runtime_log) |log| {
        log.append(.{ .type = "provider_request_raw", .body = body }) catch {};
    }

    const response_body = try self.fetchChatCompletions(body);
    defer self.allocator.free(response_body);

    if (self.runtime_log) |log| {
        log.append(.{ .type = "provider_response_raw", .body = response_body }) catch {};
    }

    const parsed = try std.json.parseFromSlice(ResponseJson, allocator, response_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    if (parsed.value.choices.len == 0) return error.EmptyProviderResponse;
    return assistantFromJson(self.arena.allocator(), parsed.value.choices[0].message);
}

/// Releases temporary message-level tool-call arrays created for JSON encoding.
fn freeMessageJson(allocator: std.mem.Allocator, messages: []const MessageJson) void {
    for (messages) |item| {
        if (item.tool_calls) |calls| allocator.free(calls);
    }
}

/// Converts one core message into OpenAI-compatible message JSON.
///
/// This is where internal message variants become provider roles. The core uses
/// `.tool_result` to describe local semantics; only this adapter turns it into
/// `role = "tool"` plus `tool_call_id`.
fn messageToJson(allocator: std.mem.Allocator, message: transcript.Message) !MessageJson {
    return switch (message) {
        .user => |user| .{
            .role = .user,
            .content = user.content,
        },
        .assistant => |assistant| .{
            .role = .assistant,
            .content = assistant.content,
            .tool_calls = try toolCallsToJson(allocator, assistant.tool_calls),
        },
        .tool_result => |result| .{
            .role = .tool,
            .content = result.content,
            .tool_call_id = result.tool_call_id,
        },
    };
}

/// Serializes assistant-requested calls from prior turns.
///
/// These are not request-level tool declarations. They are replayed assistant
/// messages that let a stateless provider connect later tool-result messages to
/// the original assistant requests.
fn toolCallsToJson(allocator: std.mem.Allocator, calls: []const tool.Call) !?[]const ToolCallJson {
    if (calls.len == 0) return null;
    const json_calls = try allocator.alloc(ToolCallJson, calls.len);
    for (calls, json_calls) |call, *json_call| {
        json_call.* = .{
            .id = call.id,
            .function = .{
                .name = call.name,
                .arguments = call.arguments,
            },
        };
    }
    return json_calls;
}

/// Serializes currently available local tools as request-level function tools.
///
/// Each provider owns this conversion because function/tool schemas are wire
/// format, not core runtime data. `tool.Definition.parameters_schema` is stored
/// as raw JSON so the provider-neutral registry does not depend on
/// OpenAI-specific structs; this function parses it into a JSON object before
/// request serialization.
fn toolDefinitionsToJson(
    allocator: std.mem.Allocator,
    definitions: []const tool.Definition,
) !ToolDefinitionsJson {
    if (definitions.len == 0) {
        return .{ .tools = &.{}, .parsed_parameters = &.{} };
    }

    const tools = try allocator.alloc(ToolDefinitionJson, definitions.len);
    errdefer allocator.free(tools);
    const parsed_parameters = try allocator.alloc(std.json.Parsed(std.json.Value), definitions.len);
    errdefer allocator.free(parsed_parameters);

    var count: usize = 0;
    errdefer {
        for (parsed_parameters[0..count]) |parsed| {
            parsed.deinit();
        }
    }

    for (definitions, tools, 0..) |definition, *json_tool, idx| {
        // The API expects `parameters` to be a JSON Schema object. If we passed
        // the schema through as a string, the model would see a malformed tool
        // declaration instead of structured argument metadata.
        parsed_parameters[idx] = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            definition.parameters_schema,
            .{ .allocate = .alloc_always },
        );
        count += 1;
        json_tool.* = .{
            .function = .{
                .name = definition.name,
                .description = definition.description,
                .parameters = parsed_parameters[idx].value,
            },
        };
    }

    return .{
        .tools = tools,
        .parsed_parameters = parsed_parameters,
    };
}

/// Normalizes the first provider choice into a core assistant message.
///
/// The returned content and tool-call fields are arena-owned by the provider.
/// The agent loop copies them into its run-message builder before the next turn.
fn assistantFromJson(
    allocator: std.mem.Allocator,
    assistant_json: AssistantJson,
) !transcript.AssistantMessage {
    const content = try allocator.dupe(u8, assistant_json.content orelse "");
    errdefer allocator.free(content);

    const reasoning = try allocator.dupe(u8, assistant_json.reasoning_content orelse "");
    errdefer allocator.free(reasoning);

    const source_calls = assistant_json.tool_calls orelse &.{};
    const calls = try allocator.alloc(tool.Call, source_calls.len);
    errdefer allocator.free(calls);
    for (source_calls, calls, 0..) |source, *call, idx| {
        const name = try allocator.dupe(u8, source.function.name);
        errdefer freeOwnedCalls(allocator, calls[0..idx]);
        errdefer allocator.free(name);
        const arguments = try allocator.dupe(u8, source.function.arguments);
        errdefer allocator.free(arguments);
        const id = try allocator.dupe(u8, source.id);
        call.* = .{
            .id = id,
            .name = name,
            .arguments = arguments,
        };
    }

    return .{
        .content = content,
        .tool_calls = calls,
        .reasoning = reasoning,
    };
}

/// Releases already-cloned calls during assistant parsing failure cleanup.
fn freeOwnedCalls(allocator: std.mem.Allocator, calls: []const tool.Call) void {
    for (calls) |call| {
        allocator.free(call.id);
        allocator.free(call.name);
        allocator.free(call.arguments);
    }
}

/// Sends the serialized Chat Completions body and preserves non-OK responses.
///
/// The provider interface returns a normal Zig error on failure, while
/// `last_error` keeps the provider-specific HTTP status/body available for
/// diagnostics outside the core loop. Successful response bodies are allocated
/// by the provider's transport allocator and must be freed by this adapter.
fn fetchChatCompletions(self: *OpenAICompatible, body: []const u8) ![]const u8 {
    self.clearLastError();

    const url = try endpointUrl(self.allocator, self.config.base_url);
    defer self.allocator.free(url);

    var headers: [5]http.Header = undefined;
    headers[0] = .{ .name = "content-type", .value = "application/json" };
    var header_count: usize = 1;
    headers[header_count] = .{ .name = "accept", .value = "application/json" };
    header_count += 1;
    headers[header_count] = .{ .name = "accept-encoding", .value = "identity" };
    header_count += 1;
    headers[header_count] = .{ .name = "user-agent", .value = "clumsies-agent" };
    header_count += 1;

    var auth_value: ?[]const u8 = null;
    switch (self.config.auth) {
        .bearer => {
            auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.config.api_key});
            headers[header_count] = .{ .name = "authorization", .value = auth_value.? };
            header_count += 1;
        },
        .api_key => |header_name| {
            headers[header_count] = .{ .name = header_name, .value = self.config.api_key };
            header_count += 1;
        },
    }
    defer if (auth_value) |value| self.allocator.free(value);

    const response = self.transport.fetch(.{
        .url = url,
        .method = .POST,
        .payload = body,
        .headers = headers[0..header_count],
        .timeout_ms = self.config.request_timeout_ms,
        .use_env_proxy = self.config.use_env_proxy,
    }) catch |err| {
        if (self.transport.takeLastFailure()) |failure| {
            self.last_transport_failure = failure;
        }
        return err;
    };

    if (response.status != .ok) {
        self.last_error = .{
            .status = response.status,
            .body = response.body,
        };
        return error.ProviderRequestFailed;
    }
    return response.body;
}

/// Clears any stored provider HTTP error body.
fn clearLastError(self: *OpenAICompatible) void {
    if (self.last_error) |last_error| {
        self.allocator.free(last_error.body);
        self.last_error = null;
    }
    if (self.last_transport_failure) |failure| {
        failure.deinit(self.allocator);
        self.last_transport_failure = null;
    }
}

/// Builds the OpenAI-compatible chat completions endpoint from a base URL.
///
/// Some providers document the version root (`https://host/v1`), while local
/// `.env` files often paste the full Chat Completions endpoint. Accept both
/// forms so switching providers does not silently produce
/// `/chat/completions/chat/completions`.
fn endpointUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/chat/completions")) {
        return allocator.dupe(u8, trimmed);
    }
    return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{trimmed});
}

test "endpointUrl appends chat completions path once" {
    const first = try endpointUrl(std.testing.allocator, "https://example.com/v1");
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("https://example.com/v1/chat/completions", first);

    const second = try endpointUrl(std.testing.allocator, "https://example.com/v1/");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("https://example.com/v1/chat/completions", second);

    const full = try endpointUrl(std.testing.allocator, "https://example.com/v1/chat/completions/");
    defer std.testing.allocator.free(full);
    try std.testing.expectEqualStrings("https://example.com/v1/chat/completions", full);
}

test "toolDefinitionsToJson emits request-level function tools" {
    const allocator = std.testing.allocator;
    const definitions = [_]tool.Definition{
        .{
            .name = "read_file",
            .description = "Read a UTF-8 file from the workspace.",
            .parameters_schema =
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "path": { "type": "string" }
            \\  },
            \\  "required": ["path"]
            \\}
            ,
        },
    };

    const converted = try toolDefinitionsToJson(allocator, &definitions);
    defer converted.deinit(allocator);

    const messages = [_]MessageJson{
        .{ .role = .user, .content = "read src/root.zig" },
    };
    const body = try std.json.Stringify.valueAlloc(allocator, RequestBody{
        .model = "test-model",
        .messages = &messages,
        .tools = converted.tools,
    }, .{ .emit_null_optional_fields = false });
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"path\":{\"type\":\"string\"}") != null);
}

test "toolDefinitionsToJson deinit accepts empty tool lists" {
    const converted = try toolDefinitionsToJson(std.testing.allocator, &.{});
    converted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), converted.tools.len);
}

test "non-OK provider responses retain owned error body" {
    const body = try std.testing.allocator.dupe(u8, "{\"error\":\"bad request\"}");
    var provider_state = OpenAICompatible.init(std.testing.allocator, .{
        .base_url = "https://example.test/v1",
        .api_key = "secret",
        .model = "test-model",
    });
    defer provider_state.deinit();

    provider_state.last_error = .{
        .status = .bad_request,
        .body = body,
    };

    const retained = provider_state.takeLastError().?;
    defer retained.deinit(std.testing.allocator);
    try std.testing.expectEqual(http.Status.bad_request, retained.status);
    try std.testing.expectEqualStrings("{\"error\":\"bad request\"}", retained.body);
}

test "responds through configured OpenAI-compatible provider" {
    const allocator = std.testing.allocator;
    const base_url = std.process.getEnvVarOwned(allocator, "CLUMSIES_AGENT_PROVIDER_BASE_URL") catch return error.SkipZigTest;
    defer allocator.free(base_url);
    const api_key = std.process.getEnvVarOwned(allocator, "CLUMSIES_AGENT_PROVIDER_API_KEY") catch return error.SkipZigTest;
    defer allocator.free(api_key);
    const model = std.process.getEnvVarOwned(allocator, "CLUMSIES_AGENT_PROVIDER_MODEL") catch return error.SkipZigTest;
    defer allocator.free(model);

    const auth_header = std.process.getEnvVarOwned(allocator, "CLUMSIES_AGENT_PROVIDER_AUTH_HEADER") catch null;
    defer if (auth_header) |header| allocator.free(header);

    var provider_state = OpenAICompatible.init(allocator, .{
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .auth = if (auth_header) |header| .{ .api_key = header } else .bearer,
    });
    defer provider_state.deinit();

    const messages = [_]transcript.Message{
        .{ .user = .{ .content = "评价这个开源项目：https://github.com/lilhammerfun/clumsies。" } },
    };
    const assistant = try provider_state.provider().respond(allocator, .{
        .messages = &messages,
        .options = .{ .max_output_tokens = 80 },
    });

    try std.testing.expect(assistant.content.len > 0 or assistant.tool_calls.len > 0);
}

test "parses reasoning_content from assistant message" {
    const response_json =
        \\{"id":"test","choices":[{"message":{"content":"2","reasoning_content":"这是推理过程..."},"finish_reason":"stop"}]}
    ;
    const parsed = try std.json.parseFromSlice(ResponseJson, std.testing.allocator, response_json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    const msg = parsed.value.choices[0].message;
    try std.testing.expectEqualStrings("2", msg.content.?);
    try std.testing.expectEqualStrings("这是推理过程...", msg.reasoning_content.?);
}
