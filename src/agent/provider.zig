//! Provider adapter boundary for producing assistant messages.
//!
//! `Provider` is the agent core's model-facing port. The loop sends
//! provider-neutral transcript messages plus available tool definitions, and a
//! concrete adapter turns that request into the provider's wire format. The
//! adapter returns a normalized assistant message so the loop does not know
//! whether the backing service is OpenAI-compatible, local, or something else.

const std = @import("std");
const transcript = @import("transcript.zig");
const tool = @import("tool.zig");

const Provider = @This();

ctx: *anyopaque,
respond_fn: *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    request: Request,
) anyerror!transcript.AssistantMessage,
metadata_fn: *const fn (ctx: *anyopaque) Metadata = defaultMetadata,

/// Provider identity shown in logs, dashboards, and diagnostics.
pub const Metadata = struct {
    id: []const u8 = "unknown",
    model: []const u8 = "",
};

/// Model sampling and response bounds for one provider request.
pub const Options = struct {
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    max_output_tokens: ?u32 = null,
};

/// Provider-neutral request built by the agent loop.
///
/// `messages` is the conversation context to send this turn. `tools` is the
/// request-level capability declaration: adapters decide how to encode those
/// definitions for their provider.
pub const Request = struct {
    messages: []const transcript.Message,
    tools: []const tool.Definition = &.{},
    options: Options = .{},
};

/// Obtains the next assistant message from the model provider.
pub fn respond(
    self: Provider,
    allocator: std.mem.Allocator,
    request: Request,
) anyerror!transcript.AssistantMessage {
    return self.respond_fn(self.ctx, allocator, request);
}

/// Returns provider identity metadata without making a model request.
pub fn metadata(self: Provider) Metadata {
    return self.metadata_fn(self.ctx);
}

fn defaultMetadata(ctx: *anyopaque) Metadata {
    _ = ctx;
    return .{};
}
