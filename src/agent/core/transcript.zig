//! Run-local provider-neutral transcript protocol.
//!
//! A transcript is not durable session history. It is the in-run message chain
//! that preserves provider protocol causality: user input, assistant tool-call
//! requests, matching tool results, and final assistant output. Session history
//! may store transcript messages, but the assembler decides later which session
//! facts become context for a new run.
//!
//! `Builder.append` deep-copies message payloads. That keeps provider and tool
//! implementations free to return short-lived buffers: once a message is
//! appended, the builder owns the stored copy until it is finished or deinit'd.

const std = @import("std");
const tool = @import("tool.zig");

/// One provider-neutral message in the run-local causal chain.
pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

/// User-authored input or context sent to the model.
pub const UserMessage = struct {
    content: []const u8,
};

/// Assistant response produced by the model provider.
///
/// Tool calls are kept on the assistant message because provider APIs pair
/// later tool-result messages with these call ids.
pub const AssistantMessage = struct {
    content: []const u8 = "",
    tool_calls: []const tool.Call = &.{},
};

/// Result of one tool call, linked to the original assistant call id.
pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

/// Why the loop stopped producing turns.
pub const EndReason = enum {
    complete,
    max_turns,
    terminated,
};

/// Mutable run message chain under construction during one agent run.
pub const Builder = struct {
    messages: std.ArrayList(Message) = .empty,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| {
            deinitMessage(message, allocator);
        }
        self.messages.deinit(allocator);
    }

    /// Appends a message by deep-copying all payload slices.
    ///
    /// The loop appends run-local user, assistant, and tool-result messages.
    /// Cloning here makes the builder the single owner of stored message
    /// payloads, instead of leaking lifetime rules into every caller.
    pub fn append(
        self: *Builder,
        allocator: std.mem.Allocator,
        message: Message,
    ) !void {
        const cloned = try cloneMessage(allocator, message);
        errdefer deinitMessage(cloned, allocator);
        try self.messages.append(allocator, cloned);
    }

    pub fn items(self: Builder) []const Message {
        return self.messages.items;
    }

    pub fn len(self: Builder) usize {
        return self.messages.items.len;
    }

    /// Finishes the builder and transfers the message array to `Run`.
    ///
    /// Nested payload ownership has already been established by `append`.
    pub fn finish(
        self: *Builder,
        allocator: std.mem.Allocator,
        reason: EndReason,
    ) !Run {
        return .{
            .messages = try self.messages.toOwnedSlice(allocator),
            .end_reason = reason,
        };
    }
};

/// Owned message chain returned by a completed agent run.
pub const Run = struct {
    messages: []const Message,
    end_reason: EndReason,

    /// Releases the run message array and every copied payload.
    pub fn deinit(self: Run, allocator: std.mem.Allocator) void {
        for (self.messages) |message| {
            deinitMessage(message, allocator);
        }
        allocator.free(self.messages);
    }
};

/// Clones a message variant into owned memory.
///
/// Session history and run-message builders both need the same ownership rule:
/// once a message crosses into durable agent state, no string or tool-call
/// payload may depend on a provider or tool executor buffer.
pub fn cloneMessage(allocator: std.mem.Allocator, message: Message) !Message {
    return switch (message) {
        .user => |user| .{ .user = .{
            .content = try allocator.dupe(u8, user.content),
        } },
        .assistant => |assistant| try cloneAssistant(allocator, assistant),
        .tool_result => |result| try cloneToolResult(allocator, result),
    };
}

/// Clones an assistant message as one ownership unit.
///
/// Assistant messages carry nested tool calls. Keeping content and calls owned
/// together prevents mixed borrowed/owned fields in the message.
fn cloneAssistant(
    allocator: std.mem.Allocator,
    assistant: AssistantMessage,
) !Message {
    const content = try allocator.dupe(u8, assistant.content);
    errdefer allocator.free(content);

    const calls = try cloneCalls(allocator, assistant.tool_calls);
    errdefer {
        for (calls) |call| {
            deinitCall(call, allocator);
        }
        if (calls.len > 0) allocator.free(calls);
    }

    return .{ .assistant = .{
        .content = content,
        .tool_calls = calls,
    } };
}

/// Clones a tool result with the provider's original tool call id.
///
/// Providers need the id/result pair replayed on later stateless requests, so
/// both fields are copied into message-owned memory.
fn cloneToolResult(
    allocator: std.mem.Allocator,
    result: ToolResultMessage,
) !Message {
    const tool_call_id = try allocator.dupe(u8, result.tool_call_id);
    errdefer allocator.free(tool_call_id);

    const content = try allocator.dupe(u8, result.content);
    errdefer allocator.free(content);

    return .{ .tool_result = .{
        .tool_call_id = tool_call_id,
        .content = content,
        .is_error = result.is_error,
    } };
}

/// Clones a tool-call slice while preserving call order.
///
/// Provider APIs require tool-result messages to line up with prior assistant
/// tool calls, so the message stores a stable ordered copy.
fn cloneCalls(allocator: std.mem.Allocator, calls: []const tool.Call) ![]const tool.Call {
    if (calls.len == 0) return &.{};
    const cloned = try allocator.alloc(tool.Call, calls.len);
    errdefer allocator.free(cloned);

    var index: usize = 0;
    errdefer {
        for (cloned[0..index]) |call| {
            deinitCall(call, allocator);
        }
    }

    for (calls, cloned) |call, *dest| {
        dest.* = try cloneCall(allocator, call);
        index += 1;
    }
    return cloned;
}

/// Clones a provider tool call into message-owned memory.
///
/// Later tool-result messages refer back to the call id, so no call string can
/// depend on a provider-owned arena after append.
fn cloneCall(allocator: std.mem.Allocator, call: tool.Call) !tool.Call {
    const id = try allocator.dupe(u8, call.id);
    errdefer allocator.free(id);

    const name = try allocator.dupe(u8, call.name);
    errdefer allocator.free(name);

    const arguments = try allocator.dupe(u8, call.arguments);
    errdefer allocator.free(arguments);

    return .{
        .id = id,
        .name = name,
        .arguments = arguments,
    };
}

/// Releases one cloned message, mirroring `cloneMessage`.
///
/// Any new `Message` variant must be added here at the same time it becomes
/// cloneable.
pub fn deinitMessage(message: Message, allocator: std.mem.Allocator) void {
    switch (message) {
        .user => |user| allocator.free(user.content),
        .assistant => |assistant| {
            allocator.free(assistant.content);
            for (assistant.tool_calls) |call| {
                deinitCall(call, allocator);
            }
            if (assistant.tool_calls.len > 0) allocator.free(assistant.tool_calls);
        },
        .tool_result => |result| {
            allocator.free(result.tool_call_id);
            allocator.free(result.content);
        },
    }
}

/// Releases one cloned provider tool call.
fn deinitCall(call: tool.Call, allocator: std.mem.Allocator) void {
    allocator.free(call.id);
    allocator.free(call.name);
    allocator.free(call.arguments);
}
