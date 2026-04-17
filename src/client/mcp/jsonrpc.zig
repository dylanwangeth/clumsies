//! JSON-RPC 2.0 message encoding. The MCP protocol runs over JSON-RPC — this module builds
//! the response envelopes (result and error) that the server sends back to the agent via stdio.
const std = @import("std");
const encoding = @import("clumsies_lib").util.encoding;

pub const JSONRPC_VERSION = "2.0";
pub const PROTOCOL_VERSION = "2025-06-18";
pub const MAX_MESSAGE_SIZE = 1024 * 1024;

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    server_not_initialized = -32002,
};

pub fn buildResultAlloc(allocator: std.mem.Allocator, id: std.json.Value, result_json: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.writer(allocator).writeAll("{\"jsonrpc\":\"" ++ JSONRPC_VERSION ++ "\",\"id\":");
    try appendJsonId(allocator, &buf, id);
    try buf.writer(allocator).writeAll(",\"result\":");
    try buf.writer(allocator).writeAll(result_json);
    try buf.writer(allocator).writeAll("}\n");

    return try buf.toOwnedSlice(allocator);
}

pub fn buildErrorAlloc(allocator: std.mem.Allocator, id: ?std.json.Value, code: ErrorCode, message: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const esc_message = try encoding.jsonEscapeAlloc(allocator, message);
    defer allocator.free(esc_message);

    try buf.writer(allocator).writeAll("{\"jsonrpc\":\"" ++ JSONRPC_VERSION ++ "\",\"id\":");
    if (id) |req_id| {
        try appendJsonId(allocator, &buf, req_id);
    } else {
        try buf.writer(allocator).writeAll("null");
    }
    try buf.writer(allocator).print(",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}\n", .{ @intFromEnum(code), esc_message });

    return try buf.toOwnedSlice(allocator);
}

test "buildResultAlloc wraps result with jsonrpc envelope" {
    const result = try buildResultAlloc(std.testing.allocator, .{ .integer = 1 }, "{\"ok\":true}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"result\":{\"ok\":true}") != null);
}

test "buildResultAlloc handles string id" {
    const result = try buildResultAlloc(std.testing.allocator, .{ .string = "abc" }, "42");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"abc\"") != null);
}

test "buildErrorAlloc includes error code and message" {
    const result = try buildErrorAlloc(std.testing.allocator, .{ .integer = 5 }, .method_not_found, "unknown method");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"message\":\"unknown method\"") != null);
}

test "buildErrorAlloc with null id" {
    const result = try buildErrorAlloc(std.testing.allocator, null, .parse_error, "bad json");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"code\":-32700") != null);
}

test "buildErrorAlloc escapes message with special characters" {
    const result = try buildErrorAlloc(std.testing.allocator, .{ .integer = 1 }, .internal_error, "line1\nline2\"quote");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "line1\\nline2\\\"quote") != null);
}

fn appendJsonId(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .integer => |num| try buf.writer(allocator).print("{d}", .{num}),
        .float => |num| try buf.writer(allocator).print("{d}", .{num}),
        .number_string => |num| try buf.writer(allocator).print("{s}", .{num}),
        .string => |str| {
            const esc = try encoding.jsonEscapeAlloc(allocator, str);
            defer allocator.free(esc);
            try buf.writer(allocator).print("\"{s}\"", .{esc});
        },
        else => try buf.appendSlice(allocator, "null"),
    }
}
