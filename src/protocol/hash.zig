const std = @import("std");

pub const ContentHash = struct {
    value: []const u8,

    pub fn compute(content: []const u8) [71]u8 {
        var out: [71]u8 = undefined;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
        @memcpy(out[0..7], "sha256:");
        for (digest, 0..) |byte, i| {
            const hex = "0123456789abcdef";
            out[7 + i * 2] = hex[byte >> 4];
            out[7 + i * 2 + 1] = hex[byte & 0x0f];
        }
        return out;
    }
};

test "ContentHash compute" {
    const result = ContentHash.compute("hello");
    try std.testing.expect(std.mem.startsWith(u8, &result, "sha256:"));
    try std.testing.expectEqual(@as(usize, 71), result.len);
}
