//! OpenAI-compatible Chat Completions provider adapter.

const std = @import("std");
const http = std.http;
const HttpTransport = @import("../../net/http_transport.zig");
const Provider = @import("../provider.zig");
const tool = @import("../tool.zig");
const transcript = @import("../transcript.zig");

const OpenAICompatible = @This();

allocator: std.mem.Allocator,
config: Config,
transport: HttpTransport,
arena: std.heap.ArenaAllocator,
last_error: ?ProviderError = null,

pub const Config = struct {
    id: []const u8 = "openai-compatible",
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    auth: Auth = .bearer,
};

pub const Auth = union(enum) {
    bearer,
    api_key: []const u8,
};

pub const ProviderError = struct {
    status: http.Status,
    body: []const u8,

    pub fn deinit(self: ProviderError, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

const RequestBody = struct {
    model: []const u8,
    messages: []const MessageJson,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    max_tokens: ?u32 = null,
    stream: bool = false,
};

// OpenAI Chat Completions uses message-level `tool_calls` to replay prior
// assistant tool-call requests, paired with later `role = "tool"` messages via
// `tool_call_id`. Top-level `tools` and `tool_choice` are a separate request
// contract for declaring what the model may call.
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

const FunctionJson = struct {
    name: []const u8,
    arguments: []const u8,
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
};

/// Creates an OpenAI-compatible provider with a persistent HTTP client.
pub fn init(allocator: std.mem.Allocator, config: Config) OpenAICompatible {
    return .{
        .allocator = allocator,
        .config = config,
        .transport = HttpTransport.init(allocator),
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *OpenAICompatible) void {
    self.clearLastError();
    self.arena.deinit();
    self.transport.deinit();
}

pub fn takeLastError(self: *OpenAICompatible) ?ProviderError {
    const last_error = self.last_error;
    self.last_error = null;
    return last_error;
}

pub fn provider(self: *OpenAICompatible) Provider {
    return .{
        .ctx = self,
        .respond_fn = respond,
        .metadata_fn = metadata,
    };
}

fn metadata(ctx: *anyopaque) Provider.Metadata {
    const self: *OpenAICompatible = @ptrCast(@alignCast(ctx));
    return .{
        .id = self.config.id,
        .model = self.config.model,
    };
}

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

    const body = try std.json.Stringify.valueAlloc(allocator, RequestBody{
        .model = self.config.model,
        .messages = messages_json,
        .temperature = request.options.temperature,
        .top_p = request.options.top_p,
        .max_tokens = request.options.max_output_tokens,
    }, .{ .emit_null_optional_fields = false });
    defer allocator.free(body);

    const response_body = try self.fetchChatCompletions(body);
    defer allocator.free(response_body);

    const parsed = try std.json.parseFromSlice(ResponseJson, allocator, response_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return error.EmptyProviderResponse;
    return assistantFromJson(self.arena.allocator(), parsed.value.choices[0].message);
}

fn freeMessageJson(allocator: std.mem.Allocator, messages: []const MessageJson) void {
    for (messages) |message| {
        if (message.tool_calls) |calls| allocator.free(calls);
    }
}

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

fn assistantFromJson(
    allocator: std.mem.Allocator,
    message: AssistantJson,
) !transcript.AssistantMessage {
    const content = try allocator.dupe(u8, message.content orelse "");
    errdefer allocator.free(content);

    const source_calls = message.tool_calls orelse &.{};
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
    };
}

fn freeOwnedCalls(allocator: std.mem.Allocator, calls: []const tool.Call) void {
    for (calls) |call| {
        allocator.free(call.id);
        allocator.free(call.name);
        allocator.free(call.arguments);
    }
}

fn fetchChatCompletions(self: *OpenAICompatible, body: []const u8) ![]const u8 {
    self.clearLastError();

    const url = try endpointUrl(self.allocator, self.config.base_url);
    defer self.allocator.free(url);

    var headers: [4]http.Header = undefined;
    headers[0] = .{ .name = "content-type", .value = "application/json" };
    var header_count: usize = 1;
    headers[header_count] = .{ .name = "accept", .value = "application/json" };
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

    const response = try self.transport.fetch(.{
        .url = url,
        .method = .POST,
        .payload = body,
        .headers = headers[0..header_count],
        .keep_alive = false,
    });
    errdefer response.deinit();

    if (response.status != .ok) {
        self.last_error = .{
            .status = response.status,
            .body = response.body,
        };
        return error.ProviderRequestFailed;
    }
    return response.body;
}

fn clearLastError(self: *OpenAICompatible) void {
    if (self.last_error) |last_error| {
        self.allocator.free(last_error.body);
        self.last_error = null;
    }
}

fn endpointUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{trimmed});
}

test "endpointUrl appends chat completions path once" {
    const first = try endpointUrl(std.testing.allocator, "https://example.com/v1");
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("https://example.com/v1/chat/completions", first);

    const second = try endpointUrl(std.testing.allocator, "https://example.com/v1/");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("https://example.com/v1/chat/completions", second);
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
