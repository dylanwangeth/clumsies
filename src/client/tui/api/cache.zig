//! Per-endpoint cache slot. Lookup / store / invalidate / markFailed with
//! an optional key. Decoupled from `PendingRequest` so that "is a request
//! in flight" and "do we have cached data (or a remembered failure)" are
//! two orthogonal questions: cache hit means we already have fresh enough
//! data to draw; `PendingRequest.consume` moves a newly arrived result
//! into the slot as either an `ok` value or a remembered `failed` marker.
//!
//! The slot has three states — empty, ok(key, value), and failed(key).
//! `shouldDispatch(k)` folds both hit kinds together so widget-sync code
//! does not re-dispatch a request that has just failed: without the
//! failure arm, a persistently failing endpoint would spawn a fresh
//! worker on every UI tick until the user navigated away. Invalidation
//! clears both arms.
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
        state: State = .empty,

        const Self = @This();

        /// A slot is in one of three states. `failed` exists so that a
        /// consume-time failure can be remembered against its key: the
        /// next `shouldDispatch` for the same key returns false, which
        /// breaks the retry loop that otherwise fires a fresh worker on
        /// every UI tick until the user navigates away. Invalidation
        /// clears both `ok` and `failed`.
        pub const State = union(enum) {
            empty,
            ok: struct { key: K, value: V },
            failed: struct { key: K },
        };

        /// Look up the cached value for `k`. Returns null on miss or
        /// when the slot holds a remembered failure for `k`. Matches by
        /// calling `key.eql(k)` when `K` declares an `eql` method;
        /// otherwise falls back to `std.meta.eql`.
        pub fn lookup(self: *Self, k: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();
            switch (self.state) {
                .ok => |entry| if (keysEqual(entry.key, k)) return entry.value,
                else => {},
            }
            return null;
        }

        /// Whether the slot is remembering a failed fetch for `k`.
        /// Widget-sync code uses this together with `lookup` to avoid
        /// re-dispatching on every tick when a fetch keeps failing.
        pub fn isFailed(self: *Self, k: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return switch (self.state) {
                .failed => |entry| keysEqual(entry.key, k),
                else => false,
            };
        }

        /// Whether widget-sync code should dispatch a fresh request for
        /// `k`. False when the slot already has a cached value for `k`
        /// or is remembering a failure for `k`; true otherwise.
        pub fn shouldDispatch(self: *Self, k: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return switch (self.state) {
                .empty => true,
                .ok => |entry| !keysEqual(entry.key, k),
                .failed => |entry| !keysEqual(entry.key, k),
            };
        }

        /// Store a value, replacing any previous entry or failure.
        pub fn store(self: *Self, k: K, v: V) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.state = .{ .ok = .{ .key = k, .value = v } };
        }

        /// Remember that a fetch for `k` failed. Subsequent
        /// `shouldDispatch(k)` calls return false until `invalidate`
        /// clears the slot or a different key is requested.
        pub fn markFailed(self: *Self, k: K) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.state = .{ .failed = .{ .key = k } };
        }

        /// Drop any cached entry or remembered failure.
        pub fn invalidate(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.state = .empty;
        }

        /// Clear a remembered failure while preserving an ok value.
        /// Refresh flows that keep the last successful snapshot use this
        /// to allow a retry without dropping the drawable data.
        pub fn clearFailure(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            switch (self.state) {
                .failed => self.state = .empty,
                else => {},
            }
        }

        /// Whether the slot currently holds any entry — value or
        /// failure.
        pub fn isPopulated(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.state != .empty;
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

pub fn MultiCacheSlot(comptime K: type, comptime V: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        entries: std.ArrayList(Entry) = .empty,

        const Self = @This();

        const EntryState = union(enum) {
            ok: V,
            failed,
            inflight,
        };

        const Entry = struct {
            key: K,
            state: EntryState,
        };

        pub fn lookup(self: *Self, k: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();

            const idx = self.findIndexLocked(k) orelse return null;
            return switch (self.entries.items[idx].state) {
                .ok => |value| value,
                else => null,
            };
        }

        pub fn isFailed(self: *Self, k: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            const idx = self.findIndexLocked(k) orelse return false;
            return self.entries.items[idx].state == .failed;
        }

        pub fn shouldDispatch(self: *Self, k: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.findIndexLocked(k) == null;
        }

        pub fn reserve(self: *Self, allocator: std.mem.Allocator, k: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.findIndexLocked(k) != null) return false;
            self.entries.append(allocator, .{
                .key = k,
                .state = .inflight,
            }) catch return false;
            return true;
        }

        pub fn store(self: *Self, allocator: std.mem.Allocator, k: K, v: V) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.findIndexLocked(k)) |idx| {
                self.entries.items[idx].state = .{ .ok = v };
                return;
            }
            self.entries.append(allocator, .{
                .key = k,
                .state = .{ .ok = v },
            }) catch {};
        }

        pub fn markFailed(self: *Self, allocator: std.mem.Allocator, k: K) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.findIndexLocked(k)) |idx| {
                self.entries.items[idx].state = .failed;
                return;
            }
            self.entries.append(allocator, .{
                .key = k,
                .state = .failed,
            }) catch {};
        }

        pub fn invalidate(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.entries.clearRetainingCapacity();
        }

        pub fn invalidateKey(self: *Self, k: K) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const idx = self.findIndexLocked(k) orelse return;
            _ = self.entries.orderedRemove(idx);
        }

        pub fn clearFailure(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var i: usize = 0;
            while (i < self.entries.items.len) {
                if (self.entries.items[i].state == .failed) {
                    _ = self.entries.orderedRemove(i);
                    continue;
                }
                i += 1;
            }
        }

        pub fn markInflightFailed(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.entries.items) |*entry| {
                if (entry.state == .inflight) entry.state = .failed;
            }
        }

        pub fn isPopulated(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.entries.items.len > 0;
        }

        fn findIndexLocked(self: *Self, k: K) ?usize {
            for (self.entries.items, 0..) |entry, idx| {
                if (keysEqual(entry.key, k)) return idx;
            }
            return null;
        }

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
    const Key = struct { ws_id: u32, rule_id: u32 };
    var cache: CacheSlot(Key, u32) = .{};

    cache.store(.{ .ws_id = 1, .rule_id = 10 }, 1010);
    try std.testing.expectEqual(@as(u32, 1010), cache.lookup(.{ .ws_id = 1, .rule_id = 10 }).?);
    try std.testing.expect(cache.lookup(.{ .ws_id = 1, .rule_id = 11 }) == null);
    try std.testing.expect(cache.lookup(.{ .ws_id = 2, .rule_id = 10 }) == null);
}

test "CacheSlot isPopulated tracks lifecycle" {
    var cache: CacheSlot(u32, u32) = .{};
    try std.testing.expect(!cache.isPopulated());

    cache.store(1, 100);
    try std.testing.expect(cache.isPopulated());

    cache.invalidate();
    try std.testing.expect(!cache.isPopulated());
}

test "CacheSlot markFailed gates shouldDispatch for the same key" {
    var cache: CacheSlot(u32, u32) = .{};
    try std.testing.expect(cache.shouldDispatch(1));

    cache.markFailed(1);
    try std.testing.expect(cache.isFailed(1));
    try std.testing.expect(!cache.shouldDispatch(1));
    try std.testing.expect(cache.lookup(1) == null);

    // A different key should still be dispatchable.
    try std.testing.expect(cache.shouldDispatch(2));

    // invalidate clears the remembered failure.
    cache.invalidate();
    try std.testing.expect(!cache.isFailed(1));
    try std.testing.expect(cache.shouldDispatch(1));
}

test "CacheSlot store clears a prior failure for the same key" {
    var cache: CacheSlot(u32, u32) = .{};
    cache.markFailed(1);
    try std.testing.expect(cache.isFailed(1));

    cache.store(1, 100);
    try std.testing.expect(!cache.isFailed(1));
    try std.testing.expectEqual(@as(u32, 100), cache.lookup(1).?);
    try std.testing.expect(!cache.shouldDispatch(1));
}

test "CacheSlot clearFailure preserves ok values" {
    var cache: CacheSlot(u32, u32) = .{};
    cache.store(1, 100);
    cache.clearFailure();
    try std.testing.expectEqual(@as(u32, 100), cache.lookup(1).?);

    cache.markFailed(1);
    cache.clearFailure();
    try std.testing.expect(cache.lookup(1) == null);
    try std.testing.expect(cache.shouldDispatch(1));
}

test "MultiCacheSlot keeps multiple keys and gates inflight retries" {
    var cache: MultiCacheSlot(StringKey, u32) = .{};
    const alloc = std.testing.allocator;

    try std.testing.expect(cache.reserve(alloc, .{ .value = "a" }));
    try std.testing.expect(!cache.shouldDispatch(.{ .value = "a" }));
    try std.testing.expect(cache.reserve(alloc, .{ .value = "b" }));

    cache.store(alloc, .{ .value = "a" }, 10);
    cache.store(alloc, .{ .value = "b" }, 20);
    try std.testing.expectEqual(@as(u32, 10), cache.lookup(.{ .value = "a" }).?);
    try std.testing.expectEqual(@as(u32, 20), cache.lookup(.{ .value = "b" }).?);

    cache.invalidate();
    cache.entries.deinit(alloc);
}

test "MultiCacheSlot converts unresolved inflight entries to failures" {
    var cache: MultiCacheSlot(StringKey, u32) = .{};
    const alloc = std.testing.allocator;

    try std.testing.expect(cache.reserve(alloc, .{ .value = "a" }));
    try std.testing.expect(cache.reserve(alloc, .{ .value = "b" }));
    cache.store(alloc, .{ .value = "a" }, 10);

    cache.markInflightFailed();
    try std.testing.expectEqual(@as(u32, 10), cache.lookup(.{ .value = "a" }).?);
    try std.testing.expect(cache.isFailed(.{ .value = "b" }));
    try std.testing.expect(!cache.shouldDispatch(.{ .value = "b" }));

    cache.invalidate();
    cache.entries.deinit(alloc);
}
