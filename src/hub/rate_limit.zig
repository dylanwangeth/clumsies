//! Token-bucket rate limiter. Tracks per-client request counts within sliding time windows.
//! Protects the Hub from excessive sync polling — the ETag 304 fast path is lightweight, but
//! clients should not hammer it.
const std = @import("std");

const Entry = struct {
    count: u32,
    window_start: i64,
};

allocator: std.mem.Allocator,
buckets: std.StringHashMap(Entry),
mutex: std.Io.Mutex,
window_seconds: i64,
max_requests: u32,

const RateLimiter = @This();

pub fn init(allocator: std.mem.Allocator, window_seconds: u32, max_requests: u32) RateLimiter {
    return .{
        .allocator = allocator,
        .buckets = std.StringHashMap(Entry).init(allocator),
        .mutex = .init,
        .window_seconds = @intCast(window_seconds),
        .max_requests = max_requests,
    };
}

pub fn deinit(self: *RateLimiter) void {
    var it = self.buckets.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
    }
    self.buckets.deinit();
}

pub fn check(self: *RateLimiter, key: []const u8) bool {
    self.mutex.lockUncancelable(std.Options.debug_io);
    defer self.mutex.unlock(std.Options.debug_io);

    const now = @import("clumsies_lib").util.time_util.nowSeconds();

    if (self.buckets.getPtr(key)) |entry| {
        if (now - entry.window_start >= self.window_seconds) {
            entry.count = 1;
            entry.window_start = now;
            return true;
        }
        if (entry.count >= self.max_requests) {
            return false;
        }
        entry.count += 1;
        return true;
    }

    const owned_key = self.allocator.dupe(u8, key) catch return false;
    self.buckets.put(owned_key, .{ .count = 1, .window_start = now }) catch {
        self.allocator.free(owned_key);
        return false;
    };
    return true;
}

test "first request for new key is allowed" {
    var rl = init(std.testing.allocator, 60, 5);
    defer rl.deinit();
    try std.testing.expect(rl.check("user-1"));
}

test "requests up to max are allowed then denied" {
    var rl = init(std.testing.allocator, 3600, 3);
    defer rl.deinit();
    try std.testing.expect(rl.check("user-1"));
    try std.testing.expect(rl.check("user-1"));
    try std.testing.expect(rl.check("user-1"));
    try std.testing.expect(!rl.check("user-1")); // 4th denied
    try std.testing.expect(!rl.check("user-1")); // still denied
}

test "different keys have independent limits" {
    var rl = init(std.testing.allocator, 3600, 1);
    defer rl.deinit();
    try std.testing.expect(rl.check("user-1"));
    try std.testing.expect(!rl.check("user-1")); // user-1 exhausted
    try std.testing.expect(rl.check("user-2")); // user-2 independent
}
