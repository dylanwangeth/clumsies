//! Transcript message and run-result types for the agent loop.

const std = @import("std");
const tool = @import("tool.zig");

/// One transcript entry.
///
/// String fields and tool call slices are borrowed from the caller, provider,
/// or tool executor. The agent loop owns only the transcript message array it
/// returns, not the nested message payloads.
pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

/// User-authored context sent to the model.
pub const UserMessage = struct {
    content: []const u8,
};

/// Assistant response produced by the model provider.
pub const AssistantMessage = struct {
    content: []const u8 = "",
    tool_calls: []const tool.Call = &.{},
};

/// Result of one tool call, linked to the original call id.
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

/// Mutable transcript under construction during one agent run.
///
/// The builder owns only the message array it grows. Each `Message` keeps the
/// same borrowed payload lifetime rules documented above.
pub const Builder = struct {
    messages: std.ArrayList(Message) = .empty,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.messages.deinit(allocator);
    }

    pub fn append(
        self: *Builder,
        allocator: std.mem.Allocator,
        message: Message,
    ) !void {
        try self.messages.append(allocator, message);
    }

    pub fn items(self: Builder) []const Message {
        return self.messages.items;
    }

    pub fn len(self: Builder) usize {
        return self.messages.items.len;
    }

    pub fn finish(
        self: *Builder,
        allocator: std.mem.Allocator,
        reason: EndReason,
    ) !Transcript {
        return .{
            .messages = try self.messages.toOwnedSlice(allocator),
            .end_reason = reason,
        };
    }
};

/// Owned transcript returned by a completed agent run.
///
/// `deinit` releases only the message array. Nested slices follow the same
/// borrowed lifetime rules as `Message`.
pub const Transcript = struct {
    messages: []const Message,
    end_reason: EndReason,

    pub fn deinit(self: Transcript, allocator: std.mem.Allocator) void {
        allocator.free(self.messages);
    }
};
