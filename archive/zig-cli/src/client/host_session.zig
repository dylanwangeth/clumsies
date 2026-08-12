//! Host CLI session identity resolution for attestation events.
const std = @import("std");
const env_util = @import("clumsies_lib").util.env_util;

pub const HOST_SESSION_ENV_NAME = "CLUMSIES_HOST_SESSION_ID";

pub fn resolveHookSessionId(allocator: std.mem.Allocator) ?[]u8 {
    const value = env_util.getOwned(allocator, HOST_SESSION_ENV_NAME) catch return null;
    if (!isSafeSessionId(value)) {
        allocator.free(value);
        return null;
    }
    return value;
}

pub fn isSafeSessionId(session_id: []const u8) bool {
    if (session_id.len == 0 or session_id.len > 128) return false;
    for (session_id) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => return false,
        }
    }
    return true;
}

test "isSafeSessionId accepts host CLI ids and rejects path-like input" {
    try std.testing.expect(isSafeSessionId("019dba93-8214-7d50-a089-9690b4ce6b9e"));
    try std.testing.expect(isSafeSessionId("host_session_123"));
    try std.testing.expect(!isSafeSessionId(""));
    try std.testing.expect(!isSafeSessionId("../session"));
    try std.testing.expect(!isSafeSessionId("session.json"));
}
