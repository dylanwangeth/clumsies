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
