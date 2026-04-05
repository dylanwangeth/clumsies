const std = @import("std");

const Entry = struct {
    count: u32,
    window_start: i64,
};

allocator: std.mem.Allocator,
buckets: std.StringHashMap(Entry),
mutex: std.Thread.Mutex,
window_seconds: i64,
max_requests: u32,

const RateLimiter = @This();

pub fn init(allocator: std.mem.Allocator, window_seconds: u32, max_requests: u32) RateLimiter {
    return .{
        .allocator = allocator,
        .buckets = std.StringHashMap(Entry).init(allocator),
        .mutex = .{},
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
    self.mutex.lock();
    defer self.mutex.unlock();

    const now = std.time.timestamp();

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
