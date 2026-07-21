//! MCP tool response envelopes. Domain payloads are produced by the Rust daemon;
//! Zig only wraps them in the standard MCP content and structuredContent fields.
const std = @import("std");
const encoding = @import("clumsies_lib").util.encoding;

pub fn buildSuccessResult(allocator: std.mem.Allocator, structured_json: []const u8) ![]u8 {
    const esc_text = try encoding.jsonEscapeAlloc(allocator, structured_json);
    defer allocator.free(esc_text);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"structuredContent\":{s},\"isError\":false}}",
        .{ esc_text, structured_json },
    );
}

pub fn buildErrorResult(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const esc_message = try encoding.jsonEscapeAlloc(allocator, message);
    defer allocator.free(esc_message);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"structuredContent\":{{\"error\":\"{s}\"}},\"isError\":true}}",
        .{ esc_message, esc_message },
    );
}

pub fn buildStructuredErrorResult(
    allocator: std.mem.Allocator,
    message: []const u8,
    structured_json: []const u8,
) ![]u8 {
    const esc_message = try encoding.jsonEscapeAlloc(allocator, message);
    defer allocator.free(esc_message);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"structuredContent\":{s},\"isError\":true}}",
        .{ esc_message, structured_json },
    );
}

test "buildSuccessResult wraps JSON in content envelope" {
    const result = try buildSuccessResult(std.testing.allocator, "{\"count\":3}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"structuredContent\":{\"count\":3}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"isError\":false") != null);
}

test "buildErrorResult escapes its message" {
    const result = try buildErrorResult(std.testing.allocator, "path \"foo\\bar\"\nnewline");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"foo\\\\bar\\\"") != null);
}
