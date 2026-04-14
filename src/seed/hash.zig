const std = @import("std");

pub fn contentHash(content: []const u8) [71]u8 {
    var out: [71]u8 = undefined;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});

    @memcpy(out[0..7], "sha256:");
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[7 + i * 2] = hex[byte >> 4];
        out[7 + i * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

test "contentHash prefixes sha256 and is stable" {
    const hash = contentHash("hello");
    try std.testing.expectEqualStrings(
        "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &hash,
    );
}
