//! Content hashing with SHA-256. Content hashes are the version identity of prompts and context
//! files — same hash means same content, no ambiguity. Output format: "sha256:{hex}".
const std = @import("std");
const encoding = @import("encoding.zig");

/// Compute SHA256 content hash with "sha256:" prefix.
/// Returns a fixed [71]u8: 7-char prefix + 64-char hex digest.
pub fn contentHash(content: []const u8) [71]u8 {
    var out: [71]u8 = undefined;
    @memcpy(out[0..7], "sha256:");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    encoding.hexEncode(&digest, out[7..71]);
    return out;
}

/// Compute SHA256 hex digest, heap-allocated. No prefix.
pub fn sha256HexAlloc(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    var hex: [64]u8 = undefined;
    encoding.hexEncode(&digest, &hex);
    return try allocator.dupe(u8, &hex);
}

test "contentHash prefixes sha256 and is stable" {
    const hash = contentHash("hello");
    try std.testing.expectEqualStrings(
        "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &hash,
    );
}

test "sha256HexAlloc returns hex without prefix" {
    const hash = try sha256HexAlloc(std.testing.allocator, "hello");
    defer std.testing.allocator.free(hash);
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        hash,
    );
}
