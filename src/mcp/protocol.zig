const std = @import("std");
const lib = @import("clumsies_lib");
const encoding = lib.encoding;

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
