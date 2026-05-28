//! Inference request assembly for the agent core.
//!
//! The assembler is the boundary that decides what the model sees for one
//! provider call. It combines durable transcript history, available tool
//! definitions, provider options, and transient memory context. The loop owns
//! sequencing; providers own wire formats; memory owns recall. This module
//! keeps those responsibilities from leaking into each other.

const std = @import("std");
const Memory = @import("memory.zig");
const Provider = @import("provider.zig");
const tool = @import("tool.zig");
const transcript = @import("transcript.zig");

const Assembler = @This();

memory: ?Memory = null,

/// Inputs needed to build one provider request.
pub const Input = struct {
    history: []const transcript.Message,
    tools: []const tool.Definition = &.{},
    provider_options: Provider.Options = .{},
    turn_index: usize,
};

/// Assembles the provider-neutral request for one inference.
///
/// Pulled memory is request-scoped context: it is visible to this provider call
/// but is not appended to the durable transcript by the assembler.
pub fn build(
    self: Assembler,
    input: Input,
) !Provider.Request {
    const pulled = if (self.memory) |memory|
        try memory.pull(.{
            .history = input.history,
            .turn_index = input.turn_index,
        })
    else
        Memory.PullResult{};

    return .{
        .messages = input.history,
        .context = pulled.messages,
        .tools = input.tools,
        .options = input.provider_options,
    };
}

test "assembler pulls transient memory without changing durable history" {
    const history = [_]transcript.Message{
        .{ .user = .{ .content = "fix the provider" } },
    };
    const definitions = [_]tool.Definition{
        .{ .name = "Read" },
    };
    var memory_state: TestMemory = .{};
    const assembler: Assembler = .{ .memory = memory_state.memory() };

    const request = try assembler.build(.{
        .history = &history,
        .tools = &definitions,
        .provider_options = .{ .max_output_tokens = 128 },
        .turn_index = 7,
    });

    try std.testing.expectEqual(@as(usize, 1), memory_state.pull_count);
    try std.testing.expectEqual(@as(usize, 7), memory_state.turn_index);
    try std.testing.expectEqual(@as(usize, 1), request.messages.len);
    try std.testing.expectEqualStrings("fix the provider", request.messages[0].user.content);
    try std.testing.expectEqual(@as(usize, 1), request.context.len);
    try std.testing.expectEqualStrings("memory context", request.context[0].user.content);
    try std.testing.expectEqual(@as(usize, 1), request.tools.len);
    try std.testing.expectEqual(@as(?u32, 128), request.options.max_output_tokens);
}

const TestMemory = struct {
    pull_count: usize = 0,
    turn_index: usize = 0,
    context_messages: [1]transcript.Message = .{
        .{ .user = .{ .content = "memory context" } },
    },

    fn memory(self: *TestMemory) Memory {
        return .{
            .ctx = self,
            .pull_fn = pull,
        };
    }

    fn pull(
        ctx: ?*anyopaque,
        input: Memory.PullInput,
    ) !Memory.PullResult {
        const self: *TestMemory = @ptrCast(@alignCast(ctx.?));
        self.pull_count += 1;
        self.turn_index = input.turn_index;
        return .{ .messages = self.context_messages[0..] };
    }
};
