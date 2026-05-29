//! Standard result constructors for built-in tool output.
//!
//! Core `tool.Result` only carries bytes, ownership, model-visible error state,
//! and runtime control. The helper functions in this module standardize the
//! JSON content shape used by built-in coding tools without making `agent/core`
//! depend on a product-specific output format.

const std = @import("std");
const tool = @import("../core/tool.zig");
const encoding = @import("../../util/encoding.zig");

/// Builds a successful JSON tool result for file mutations.
///
/// The built-in mutation tools use the same small response shape so the model
/// can reason about successful workspace changes without tool-specific parsing.
pub fn okPathAction(
    allocator: std.mem.Allocator,
    path: []const u8,
    action: []const u8,
) !tool.Result {
    const esc_path = try encoding.jsonEscapeAlloc(allocator, path);
    defer allocator.free(esc_path);
    const esc_action = try encoding.jsonEscapeAlloc(allocator, action);
    defer allocator.free(esc_action);
    const content = try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"ok\",\"path\":\"{s}\",\"action\":\"{s}\"}}\n",
        .{ esc_path, esc_action },
    );
    return .{ .content = content, .owns_content = true };
}

/// Builds a recoverable, model-visible JSON tool error.
///
/// Tool errors are part of the transcript rather than Zig control-flow errors:
/// the next provider turn sees `error_code` and `message` and can choose a
/// different tool call.
pub fn fail(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
) !tool.Result {
    return failWithControl(allocator, code, message, .continue_run);
}

/// Builds a JSON tool error that also carries runtime control.
///
/// This is used for tool outcomes such as `Discuss`, where the model-visible
/// result should be recorded but the automatic run loop must stop afterward.
pub fn failWithControl(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
    control: tool.Control,
) !tool.Result {
    const esc_code = try encoding.jsonEscapeAlloc(allocator, code);
    defer allocator.free(esc_code);
    const esc_message = try encoding.jsonEscapeAlloc(allocator, message);
    defer allocator.free(esc_message);
    const content = try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"error\",\"error_code\":\"{s}\",\"message\":\"{s}\"}}\n",
        .{ esc_code, esc_message },
    );
    return .{
        .content = content,
        .owns_content = true,
        .is_error = true,
        .control = control,
    };
}
