//! Provider adapter boundary for producing assistant messages.

const std = @import("std");
const transcript = @import("transcript.zig");

const Provider = @This();

ctx: *anyopaque,
respond_fn: *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    messages: []const transcript.Message,
) anyerror!transcript.AssistantMessage,

/// Obtains the next assistant message from the model provider.
pub fn respond(
    self: Provider,
    allocator: std.mem.Allocator,
    messages: []const transcript.Message,
) anyerror!transcript.AssistantMessage {
    return self.respond_fn(self.ctx, allocator, messages);
}
