//! Host CLI session identity resolution for attestation events.
const std = @import("std");
const encoding = @import("clumsies_lib").util.encoding;

const HOST_SESSION_ENV_NAMES = [_][]const u8{
    "CLUMSIES_HOST_SESSION_ID",
    "CODEX_THREAD_ID",
    "GEMINI_SESSION_ID",
    "CLAUDE_CODE_REMOTE_SESSION_ID",
};

pub fn resolveSessionId(allocator: std.mem.Allocator) ?[32]u8 {
    for (HOST_SESSION_ENV_NAMES) |name| {
        const value = std.process.getEnvVarOwned(allocator, name) catch continue;
        defer allocator.free(value);
        if (value.len == 0) continue;
        return deriveSessionId(value);
    }
    return null;
}

pub fn deriveSessionId(host_session_id: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(host_session_id, &digest, .{});

    var hex: [64]u8 = undefined;
    encoding.hexEncode(&digest, &hex);

    var session_id: [32]u8 = undefined;
    @memcpy(session_id[0..], hex[0..32]);
    return session_id;
}

test "deriveSessionId returns stable 32-byte hex id" {
    const first = deriveSessionId("host-session");
    const second = deriveSessionId("host-session");

    try std.testing.expectEqualStrings(first[0..], second[0..]);
    try std.testing.expectEqual(@as(usize, 32), first.len);
    try std.testing.expect(encoding.isHexString(first[0..]));
}
