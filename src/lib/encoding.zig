const std = @import("std");
const testing = std.testing;

/// Encode bytes to hexadecimal string.
pub fn hexEncode(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
}

/// Escape a string for safe inclusion as a JSON string value.
pub fn jsonEscapeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var needs_escape = false;
    for (input) |c| {
        if (c == '"' or c == '\\' or c < 0x20) {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return try allocator.dupe(u8, input);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try result.appendSlice(allocator, &[_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] });
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Check if a string consists entirely of hexadecimal characters.
pub fn isHexString(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
            return false;
        }
    }
    return true;
}

test "hexEncode: known bytes" {
    var out: [6]u8 = undefined;
    hexEncode(&[_]u8{ 0xde, 0xad, 0xbe }, &out);
    try testing.expectEqualStrings("deadbe", &out);
}

test "hexEncode: all zeros" {
    var out: [4]u8 = undefined;
    hexEncode(&[_]u8{ 0x00, 0x00 }, &out);
    try testing.expectEqualStrings("0000", &out);
}

test "hexEncode: all ff" {
    var out: [4]u8 = undefined;
    hexEncode(&[_]u8{ 0xff, 0xff }, &out);
    try testing.expectEqualStrings("ffff", &out);
}

test "isHexString: valid lowercase" {
    try testing.expect(isHexString("abcdef0123"));
}

test "isHexString: valid uppercase" {
    try testing.expect(isHexString("ABCDEF"));
}

test "isHexString: mixed case" {
    try testing.expect(isHexString("aAbB01"));
}

test "isHexString: invalid chars" {
    try testing.expect(!isHexString("ghij"));
}

test "isHexString: empty string" {
    try testing.expect(!isHexString(""));
}

test "isHexString: with space" {
    try testing.expect(!isHexString("ab cd"));
}

test "jsonEscapeAlloc: plain string no escape" {
    const result = try jsonEscapeAlloc(testing.allocator, "hello world");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello world", result);
}

test "jsonEscapeAlloc: quotes" {
    const result = try jsonEscapeAlloc(testing.allocator, "say \"hi\"");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("say \\\"hi\\\"", result);
}

test "jsonEscapeAlloc: backslashes" {
    const result = try jsonEscapeAlloc(testing.allocator, "a\\b");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a\\\\b", result);
}

test "jsonEscapeAlloc: newline and tab" {
    const result = try jsonEscapeAlloc(testing.allocator, "a\nb\tc");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a\\nb\\tc", result);
}

test "jsonEscapeAlloc: carriage return" {
    const result = try jsonEscapeAlloc(testing.allocator, "a\rb");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a\\rb", result);
}

test "jsonEscapeAlloc: control character" {
    const result = try jsonEscapeAlloc(testing.allocator, &[_]u8{0x01});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("\\u0001", result);
}

test "jsonEscapeAlloc: empty string" {
    const result = try jsonEscapeAlloc(testing.allocator, "");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}
