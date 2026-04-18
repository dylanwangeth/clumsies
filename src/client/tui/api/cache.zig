//! Per-endpoint cache slot. Lookup / store / invalidate with an optional
//! key. Decoupled from `PendingRequest` so that "is a request in flight"
//! and "do we have cached data" are two orthogonal questions: cache hit
//! means we already have fresh enough data to draw; `PendingRequest.consume`
//! only moves a newly arrived result into the cache.
//!
//! Key comparison is type-based: the caller picks a key type that exposes
//! an `eql(other: K) bool` method, or uses a slice/scalar that works with
//! `std.meta.eql`. For string keys, wrap them in a struct with a custom
//! `eql` that calls `std.mem.eql` — plain `[]const u8` equality via pointer
//! comparison is not useful here.

const std = @import("std");

pub fn CacheSlot(comptime K: type, comptime V: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        key: ?K = null,
        value: V = undefined,

        /// Look up the cached value for `k`. Returns null on miss.
        /// Matches by calling `key.eql(k)` when `K` declares an `eql`
        /// method; otherwise falls back to `std.meta.eql`.
        pub fn lookup(self: *@This(), k: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();
            const current = self.key orelse return null;
            if (!keysEqual(current, k)) return null;
            return self.value;
        }

        /// Store a value, replacing any previous entry.
        pub fn store(self: *@This(), k: K, v: V) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.key = k;
            self.value = v;
        }

        /// Drop any cached entry. Subsequent lookups miss until the next
        /// store.
        pub fn invalidate(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.key = null;
            self.value = undefined;
        }

        /// Whether the slot currently holds any entry.
        pub fn isPopulated(self: *@This()) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.key != null;
        }

        /// Equality check for `K`. Uses `K.eql(other)` when the type
        /// declares it, otherwise falls back to `std.meta.eql`.
        ///
        /// The custom method matters for slice-bearing keys such as
        /// `StringKey`, where `std.meta.eql` would compare slice pointers
        /// rather than contents. `@hasDecl` is only legal on container
        /// types, so the `@typeInfo` switch gates the lookup — probing
        /// `@hasDecl` on a scalar `K` would fail at comptime.
        fn keysEqual(a: K, b: K) bool {
            const info = @typeInfo(K);
            const has_eql = switch (info) {
                .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(K, "eql"),
                else => false,
            };
            if (has_eql) return a.eql(b);
            return std.meta.eql(a, b);
        }
    };
}

/// String-key wrapper for caches keyed by a `[]const u8` path or id.
/// Necessary because `std.meta.eql` on a slice compares pointers, not
/// contents.
pub const StringKey = struct {
    value: []const u8,

    pub fn eql(self: StringKey, other: StringKey) bool {
        return std.mem.eql(u8, self.value, other.value);
    }
};

test "CacheSlot scalar key: miss, store, hit, invalidate" {
    var cache: CacheSlot(u32, u32) = .{};

    try std.testing.expect(cache.lookup(1) == null);

    cache.store(1, 100);
    try std.testing.expectEqual(@as(u32, 100), cache.lookup(1).?);
    try std.testing.expect(cache.lookup(2) == null);

    cache.invalidate();
    try std.testing.expect(cache.lookup(1) == null);
}

test "CacheSlot store replaces previous key-value atomically" {
    var cache: CacheSlot(u32, u32) = .{};
    cache.store(1, 100);
    cache.store(2, 200);
    try std.testing.expect(cache.lookup(1) == null);
    try std.testing.expectEqual(@as(u32, 200), cache.lookup(2).?);
}

test "CacheSlot with StringKey compares slice contents" {
    var cache: CacheSlot(StringKey, u32) = .{};

    const path_a1 = StringKey{ .value = "foo/bar" };
    const path_a2 = StringKey{ .value = "foo/bar" }; // different pointer, same contents
    const path_b = StringKey{ .value = "foo/baz" };

    cache.store(path_a1, 42);
    try std.testing.expectEqual(@as(u32, 42), cache.lookup(path_a2).?);
    try std.testing.expect(cache.lookup(path_b) == null);
}

test "CacheSlot composite struct key uses std.meta.eql when no eql method" {
    const Key = struct { ws_id: u32, prompt_id: u32 };
    var cache: CacheSlot(Key, u32) = .{};

    cache.store(.{ .ws_id = 1, .prompt_id = 10 }, 1010);
    try std.testing.expectEqual(@as(u32, 1010), cache.lookup(.{ .ws_id = 1, .prompt_id = 10 }).?);
    try std.testing.expect(cache.lookup(.{ .ws_id = 1, .prompt_id = 11 }) == null);
    try std.testing.expect(cache.lookup(.{ .ws_id = 2, .prompt_id = 10 }) == null);
}

test "CacheSlot isPopulated tracks lifecycle" {
    var cache: CacheSlot(u32, u32) = .{};
    try std.testing.expect(!cache.isPopulated());

    cache.store(1, 100);
    try std.testing.expect(cache.isPopulated());

    cache.invalidate();
    try std.testing.expect(!cache.isPopulated());
}
