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

pub const DEFAULT_SNAPSHOT_REFRESH_TICKS: u64 = 600;

pub fn CacheSlot(comptime K: type, comptime V: type) type {
    return struct {
        mutex: std.Io.Mutex = .init,
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
            ok: Entry,
            ok_refreshing: Entry,
            failed: FailedEntry,
        };

        const Entry = struct {
            key: K,
            value: V,
            updated_tick: u64 = 0,
        };

        const FailedEntry = struct {
            key: K,
            updated_tick: u64 = 0,
        };

        /// Look up the cached value for `k`. Returns null on miss or
        /// when the slot holds a remembered failure for `k`. Matches by
        /// calling `key.eql(k)` when `K` declares an `eql` method;
        /// otherwise falls back to `std.meta.eql`.
        pub fn lookup(self: *Self, k: K) ?V {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            switch (self.state) {
                .ok, .ok_refreshing => |entry| if (keysEqual(entry.key, k)) return entry.value,
                else => {},
            }
            return null;
        }

        /// Whether the slot is remembering a failed fetch for `k`.
        /// Widget-sync code uses this together with `lookup` to avoid
        /// re-dispatching on every tick when a fetch keeps failing.
        pub fn isFailed(self: *Self, k: K) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            return switch (self.state) {
                .failed => |entry| keysEqual(entry.key, k),
                else => false,
            };
        }

        /// Whether widget-sync code should dispatch a fresh request for
        /// `k`. False when the slot already has a cached value for `k`
        /// or is remembering a failure for `k`; true otherwise.
        pub fn shouldDispatch(self: *Self, k: K) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            return switch (self.state) {
                .empty => true,
                .ok, .ok_refreshing => |entry| !keysEqual(entry.key, k),
                .failed => |entry| !keysEqual(entry.key, k),
            };
        }

        /// Whether the cached entry is missing or stale enough for a
        /// background refresh. Unlike `invalidate`, this preserves the
        /// current value so UI can keep drawing old data while the new
        /// request is in flight.
        pub fn shouldRefresh(self: *Self, k: K, now_tick: u64, ttl_ticks: u64) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            return switch (self.state) {
                .empty => true,
                .ok => |entry| !keysEqual(entry.key, k) or isStale(entry.updated_tick, now_tick, ttl_ticks),
                .ok_refreshing => |entry| !keysEqual(entry.key, k),
                .failed => |entry| !keysEqual(entry.key, k) or isStale(entry.updated_tick, now_tick, ttl_ticks),
            };
        }

        /// Store a value, replacing any previous entry or failure.
        pub fn store(self: *Self, k: K, v: V) void {
            self.storeAt(k, v, 0);
        }

        /// Store a value and remember the UI tick that produced it.
        pub fn storeAt(self: *Self, k: K, v: V, now_tick: u64) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            self.state = .{ .ok = .{ .key = k, .value = v, .updated_tick = now_tick } };
        }

        /// Mark a stale value as being refreshed. The old value remains
        /// visible through `lookup`; callers use this before dispatching
        /// a stale-while-revalidate request.
        pub fn beginRefresh(self: *Self, k: K, now_tick: u64, ttl_ticks: u64) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            switch (self.state) {
                .empty => return true,
                .ok => |entry| {
                    if (!keysEqual(entry.key, k)) return true;
                    if (!isStale(entry.updated_tick, now_tick, ttl_ticks)) return false;
                    self.state = .{ .ok_refreshing = entry };
                    return true;
                },
                .ok_refreshing => |entry| return !keysEqual(entry.key, k),
                .failed => |entry| return !keysEqual(entry.key, k) or isStale(entry.updated_tick, now_tick, ttl_ticks),
            }
        }

        /// Remember that a fetch for `k` failed. Subsequent
        /// `shouldDispatch(k)` calls return false until `invalidate`
        /// clears the slot or a different key is requested.
        pub fn markFailed(self: *Self, k: K) void {
            self.markFailedAt(k, 0);
        }

        /// Remember a failed fetch and the tick that observed it.
        pub fn markFailedAt(self: *Self, k: K, now_tick: u64) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            switch (self.state) {
                .ok => |entry| if (keysEqual(entry.key, k)) {
                    self.state = .{ .ok = .{ .key = entry.key, .value = entry.value, .updated_tick = now_tick } };
                    return;
                },
                .ok_refreshing => |entry| if (keysEqual(entry.key, k)) {
                    self.state = .{ .ok = .{ .key = entry.key, .value = entry.value, .updated_tick = now_tick } };
                    return;
                },
                else => {},
            }
            self.state = .{ .failed = .{ .key = k, .updated_tick = now_tick } };
        }

        /// Drop any cached entry or remembered failure.
        pub fn invalidate(self: *Self) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            self.state = .empty;
        }

        /// Clear a remembered failure while preserving an ok value.
        /// Refresh flows that keep the last successful snapshot use this
        /// to allow a retry without dropping the drawable data.
        pub fn clearFailure(self: *Self) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            switch (self.state) {
                .failed => self.state = .empty,
                else => {},
            }
        }

        /// Whether the slot currently holds any entry — value or
        /// failure.
        pub fn isPopulated(self: *Self) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
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

        fn isStale(updated_tick: u64, now_tick: u64, ttl_ticks: u64) bool {
            return ttl_ticks == 0 or now_tick -% updated_tick >= ttl_ticks;
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
        mutex: std.Io.Mutex = .init,
        entries: std.ArrayList(Entry) = .empty,

        const Self = @This();

        const ValueEntry = struct {
            value: V,
            updated_tick: u64 = 0,
        };

        const EntryState = union(enum) {
            ok: ValueEntry,
            ok_refreshing: ValueEntry,
            failed,
            failed_at: u64,
            inflight,
            inflight_at: u64,
        };

        const Entry = struct {
            key: K,
            state: EntryState,
        };

        pub fn lookup(self: *Self, k: K) ?V {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            const idx = self.findIndexLocked(k) orelse return null;
            return switch (self.entries.items[idx].state) {
                .ok, .ok_refreshing => |entry| entry.value,
                else => null,
            };
        }

        pub fn isFailed(self: *Self, k: K) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            const idx = self.findIndexLocked(k) orelse return false;
            return switch (self.entries.items[idx].state) {
                .failed, .failed_at => true,
                else => false,
            };
        }

        pub fn shouldDispatch(self: *Self, k: K) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            return self.findIndexLocked(k) == null;
        }

        pub fn shouldRefresh(self: *Self, k: K, now_tick: u64, ttl_ticks: u64) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            const idx = self.findIndexLocked(k) orelse return true;
            return switch (self.entries.items[idx].state) {
                .ok => |entry| isStale(entry.updated_tick, now_tick, ttl_ticks),
                .ok_refreshing => false,
                .failed => ttl_ticks == 0,
                .failed_at => |updated_tick| isStale(updated_tick, now_tick, ttl_ticks),
                .inflight, .inflight_at => false,
            };
        }

        pub fn beginRefreshAt(self: *Self, allocator: std.mem.Allocator, k: K, now_tick: u64, ttl_ticks: u64) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            const idx = self.findIndexLocked(k) orelse {
                self.entries.append(allocator, .{
                    .key = k,
                    .state = .{ .inflight_at = now_tick },
                }) catch return false;
                return true;
            };
            switch (self.entries.items[idx].state) {
                .ok => |entry| {
                    if (!isStale(entry.updated_tick, now_tick, ttl_ticks)) return false;
                    self.entries.items[idx].state = .{ .ok_refreshing = entry };
                    return true;
                },
                .failed => {
                    if (ttl_ticks != 0) return false;
                    self.entries.items[idx].state = .{ .inflight_at = now_tick };
                    return true;
                },
                .failed_at => |updated_tick| {
                    if (!isStale(updated_tick, now_tick, ttl_ticks)) return false;
                    self.entries.items[idx].state = .{ .inflight_at = now_tick };
                    return true;
                },
                .inflight, .inflight_at, .ok_refreshing => return false,
            }
        }

        pub fn reserve(self: *Self, allocator: std.mem.Allocator, k: K) bool {
            return self.reserveAt(allocator, k, 0);
        }

        pub fn reserveAt(self: *Self, allocator: std.mem.Allocator, k: K, now_tick: u64) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            if (self.findIndexLocked(k) != null) return false;
            self.entries.append(allocator, .{
                .key = k,
                .state = .{ .inflight_at = now_tick },
            }) catch return false;
            return true;
        }

        pub fn store(self: *Self, allocator: std.mem.Allocator, k: K, v: V) void {
            self.storeAt(allocator, k, v, 0);
        }

        pub fn storeAt(self: *Self, allocator: std.mem.Allocator, k: K, v: V, now_tick: u64) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            if (self.findIndexLocked(k)) |idx| {
                self.entries.items[idx].state = .{ .ok = .{ .value = v, .updated_tick = now_tick } };
                return;
            }
            self.entries.append(allocator, .{
                .key = k,
                .state = .{ .ok = .{ .value = v, .updated_tick = now_tick } },
            }) catch {};
        }

        pub fn markFailed(self: *Self, allocator: std.mem.Allocator, k: K) void {
            self.markFailedAt(allocator, k, 0);
        }

        pub fn markFailedAt(self: *Self, allocator: std.mem.Allocator, k: K, now_tick: u64) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            if (self.findIndexLocked(k)) |idx| {
                switch (self.entries.items[idx].state) {
                    .ok => |entry| {
                        self.entries.items[idx].state = .{ .ok = .{ .value = entry.value, .updated_tick = now_tick } };
                        return;
                    },
                    .ok_refreshing => |entry| {
                        self.entries.items[idx].state = .{ .ok = .{ .value = entry.value, .updated_tick = now_tick } };
                        return;
                    },
                    else => {},
                }
                self.entries.items[idx].state = .{ .failed_at = now_tick };
                return;
            }
            self.entries.append(allocator, .{
                .key = k,
                .state = .{ .failed_at = now_tick },
            }) catch {};
        }

        pub fn invalidate(self: *Self) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
            self.entries.clearRetainingCapacity();
        }

        pub fn invalidateKey(self: *Self, k: K) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            const idx = self.findIndexLocked(k) orelse return;
            _ = self.entries.orderedRemove(idx);
        }

        pub fn clearFailure(self: *Self) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            var i: usize = 0;
            while (i < self.entries.items.len) {
                switch (self.entries.items[i].state) {
                    .failed, .failed_at => {
                        _ = self.entries.orderedRemove(i);
                        continue;
                    },
                    else => {},
                }
                i += 1;
            }
        }

        pub fn markInflightFailed(self: *Self) void {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);

            for (self.entries.items) |*entry| {
                switch (entry.state) {
                    .inflight => entry.state = .failed,
                    .inflight_at => |updated_tick| entry.state = .{ .failed_at = updated_tick },
                    .ok_refreshing => |entry_value| entry.state = .{ .ok = entry_value },
                    else => {},
                }
            }
        }

        pub fn isPopulated(self: *Self) bool {
            self.mutex.lockUncancelable(std.Options.debug_io);
            defer self.mutex.unlock(std.Options.debug_io);
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

        fn isStale(updated_tick: u64, now_tick: u64, ttl_ticks: u64) bool {
            return ttl_ticks == 0 or now_tick -% updated_tick >= ttl_ticks;
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
    try std.testing.expectEqual(@as(u32, 100), cache.lookup(1).?);
    try std.testing.expect(!cache.shouldDispatch(1));

    cache.invalidate();
    cache.markFailed(1);
    cache.clearFailure();
    try std.testing.expect(cache.lookup(1) == null);
    try std.testing.expect(cache.shouldDispatch(1));
}

test "CacheSlot refresh preserves stale value while refreshing" {
    var cache: CacheSlot(u32, u32) = .{};
    cache.storeAt(1, 100, 10);

    try std.testing.expect(!cache.beginRefresh(1, 14, 5));
    try std.testing.expect(cache.beginRefresh(1, 15, 5));
    try std.testing.expectEqual(@as(u32, 100), cache.lookup(1).?);
    try std.testing.expect(!cache.beginRefresh(1, 16, 5));

    cache.markFailedAt(1, 16);
    try std.testing.expectEqual(@as(u32, 100), cache.lookup(1).?);
    try std.testing.expect(!cache.beginRefresh(1, 20, 5));
    try std.testing.expect(cache.beginRefresh(1, 21, 5));
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

test "MultiCacheSlot refresh preserves stale value while refreshing" {
    var cache: MultiCacheSlot(StringKey, u32) = .{};
    const alloc = std.testing.allocator;
    defer cache.entries.deinit(alloc);

    const key = StringKey{ .value = "a" };
    cache.storeAt(alloc, key, 10, 10);

    try std.testing.expect(!cache.beginRefreshAt(alloc, key, 14, 5));
    try std.testing.expect(cache.beginRefreshAt(alloc, key, 15, 5));
    try std.testing.expectEqual(@as(u32, 10), cache.lookup(key).?);
    try std.testing.expect(!cache.beginRefreshAt(alloc, key, 16, 5));

    cache.markFailedAt(alloc, key, 16);
    try std.testing.expectEqual(@as(u32, 10), cache.lookup(key).?);
    try std.testing.expect(!cache.beginRefreshAt(alloc, key, 20, 5));
    try std.testing.expect(cache.beginRefreshAt(alloc, key, 21, 5));
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
