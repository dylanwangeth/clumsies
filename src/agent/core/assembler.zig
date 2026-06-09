//! Inference request assembly for the agent core.
//!
//! The assembler is the boundary that decides what the model sees for one
//! provider call. It starts from the current inference frame, pulls transient
//! memory context, renders all context into one provider-neutral message list,
//! then returns the provider request. The loop owns sequencing; providers own
//! wire formats; memory owns recall. This module keeps those responsibilities
//! from leaking into each other.

const std = @import("std");
const Memory = @import("memory.zig");
const Provider = @import("provider.zig");
const Session = @import("session.zig");
const tool = @import("tool.zig");
const transcript = @import("transcript.zig");

const Assembler = @This();

memory: ?Memory = null,

/// Inference-local state used to build one provider request.
///
/// `run_messages` starts with the current user prompt and grows with
/// assistant/tool messages produced during this run. Older `session_entries`
/// are separate facts for memory and future context selection; they are not
/// replayed by default.
pub const Frame = struct {
    run_messages: []const transcript.Message,
    session_entries: []const Session.Entry = &.{},
    tools: []const tool.Definition = &.{},
    provider_options: Provider.Options = .{},
    turn_index: usize,
};

/// Assembles the provider-neutral request for one inference.
///
/// Pulled memory is request-scoped context: it is visible to this provider call
/// but is not appended to the run message chain or durable session history.
///
/// The loop calls `build` before every model inference in a run. A future
/// memory layer can therefore recall context after tool results as well as
/// before the first assistant response.
pub fn build(
    self: Assembler,
    allocator: std.mem.Allocator,
    frame: Frame,
) !Output {
    const pulled = if (self.memory) |memory|
        try memory.pull(.{
            .run_messages = frame.run_messages,
            .session_entries = frame.session_entries,
            .turn_index = frame.turn_index,
        })
    else
        Memory.PullResult{};

    // When no memory layer is attached, convert session entries into context
    // messages. Walk backwards to find the compaction boundary: entries before
    // it are replaced by the compaction summary; entries after are kept.
    var context_messages: []const transcript.Message = pulled.messages;
    var context_buf: std.ArrayList(transcript.Message) = .empty;
    defer if (context_buf.items.len > 0) {
        for (context_buf.items) |m| transcript.deinitMessage(m, allocator);
        context_buf.deinit(allocator);
    };
    if (self.memory == null and frame.session_entries.len > 0) {
        var start_idx: usize = 0;
        var back_idx: usize = frame.session_entries.len;
        while (back_idx > 0) {
            back_idx -= 1;
            if (frame.session_entries[back_idx] == .compaction) {
                const c = frame.session_entries[back_idx].compaction;
                const duped = try transcript.cloneMessage(allocator, .{ .user = .{ .content = c.summary } });
                try context_buf.append(allocator, duped);
                start_idx = back_idx + 1;
                break;
            }
        }
        for (frame.session_entries[start_idx..]) |entry| {
            switch (entry) {
                .message => |msg| {
                    const duped = try transcript.cloneMessage(allocator, msg);
                    try context_buf.append(allocator, duped);
                },
                .run_end => {},
                .compaction => {},
            }
        }
        context_messages = context_buf.items;
    }

    const messages = try cloneMessages(allocator, context_messages, frame.run_messages);

    return .{
        .request = .{
            .messages = messages,
            .tools = frame.tools,
            .options = frame.provider_options,
        },
        .messages = messages,
    };
}

/// Owned provider request produced by the assembler.
///
/// The provider receives borrowed slices from this object. The caller must keep
/// it alive until `Provider.respond` returns, then call `deinit`.
pub const Output = struct {
    request: Provider.Request,
    messages: []const transcript.Message,

    /// Releases the assembler-owned message list.
    pub fn deinit(self: Output, allocator: std.mem.Allocator) void {
        deinitMessages(allocator, self.messages);
    }
};

/// Clones memory context before run messages into one provider-visible list.
///
/// This is the actual assembly step. Memory does not become a special provider
/// role; it is rendered as provider-neutral messages here, then provider
/// adapters serialize only the final list.
fn cloneMessages(
    allocator: std.mem.Allocator,
    context_messages: []const transcript.Message,
    run_messages: []const transcript.Message,
) ![]const transcript.Message {
    const messages = try allocator.alloc(transcript.Message, context_messages.len + run_messages.len);
    errdefer allocator.free(messages);

    var index: usize = 0;
    errdefer {
        for (messages[0..index]) |message| {
            transcript.deinitMessage(message, allocator);
        }
    }

    for (context_messages) |message| {
        messages[index] = try transcript.cloneMessage(allocator, message);
        index += 1;
    }
    for (run_messages) |message| {
        messages[index] = try transcript.cloneMessage(allocator, message);
        index += 1;
    }
    return messages;
}

fn deinitMessages(allocator: std.mem.Allocator, messages: []const transcript.Message) void {
    for (messages) |message| {
        transcript.deinitMessage(message, allocator);
    }
    allocator.free(messages);
}

test "assembler pulls transient memory without changing run messages" {
    const run_messages = [_]transcript.Message{
        .{ .user = .{ .content = "fix the provider" } },
    };
    const definitions = [_]tool.Definition{
        .{ .name = "Read" },
    };
    var memory_state: TestMemory = .{};
    const assembler: Assembler = .{ .memory = memory_state.memory() };

    const output = try assembler.build(std.testing.allocator, .{
        .run_messages = &run_messages,
        .tools = &definitions,
        .provider_options = .{ .max_output_tokens = 128 },
        .turn_index = 7,
    });
    defer output.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), memory_state.pull_count);
    try std.testing.expectEqual(@as(usize, 7), memory_state.turn_index);
    try std.testing.expectEqual(@as(usize, 2), output.request.messages.len);
    try std.testing.expectEqualStrings("memory context", output.request.messages[0].user.content);
    try std.testing.expectEqualStrings("fix the provider", output.request.messages[1].user.content);
    try std.testing.expectEqual(@as(usize, 1), output.request.tools.len);
    try std.testing.expectEqual(@as(?u32, 128), output.request.options.max_output_tokens);
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
        try std.testing.expectEqual(@as(usize, 1), input.run_messages.len);
        try std.testing.expectEqual(@as(usize, 0), input.session_entries.len);
        return .{ .messages = self.context_messages[0..] };
    }
};
