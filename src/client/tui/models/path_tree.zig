//! Tree flattening for path-structured lists.
//!
//! Given a sorted list of slash-separated paths and a set of expanded
//! directory prefixes, produces a flat sequence of visible rows: directory
//! headers whose ancestors are all expanded, and leaves whose full ancestor
//! chain is expanded. Siblings are adjacent so tree connectors (├/└) can be
//! computed with a single forward sweep.
//!
//! Callers own the output buffer. Pass `expanded = null` to render the
//! whole tree as fully expanded (useful for non-interactive nested views).

const std = @import("std");

pub const MAX_DEPTH = 8;

pub const RowKind = enum { dir, leaf };

pub const Row = struct {
    depth: u8,
    ancestor_mask: u16,
    is_last: bool,
    kind: RowKind,
    label: []const u8,
    dir_prefix: []const u8,
    leaf_idx: usize,
};

/// Flattens `paths` into `out`. Returns the number of rows written.
/// `paths` must be sorted lexicographically so siblings are adjacent.
pub fn flatten(
    paths: []const []const u8,
    expanded: ?*const std.StringHashMapUnmanaged(void),
    out: []Row,
) usize {
    var row_count: usize = 0;
    var stack: [MAX_DEPTH][]const u8 = undefined;
    var stack_len: usize = 0;

    for (paths, 0..) |path, idx| {
        var parents: [MAX_DEPTH][]const u8 = undefined;
        var parents_len: usize = 0;
        {
            var scan: usize = 0;
            while (std.mem.indexOfScalarPos(u8, path, scan, '/')) |slash| {
                if (parents_len >= MAX_DEPTH) break;
                parents[parents_len] = path[0 .. slash + 1];
                parents_len += 1;
                scan = slash + 1;
            }
        }

        var common: usize = 0;
        while (common < stack_len and common < parents_len and std.mem.eql(u8, stack[common], parents[common])) : (common += 1) {}
        stack_len = common;

        while (stack_len < parents_len) {
            const depth: usize = stack_len;
            const this_prefix = parents[depth];
            stack[stack_len] = this_prefix;
            stack_len += 1;

            var ancestors_open = true;
            var j: usize = 0;
            while (j < depth) : (j += 1) {
                if (!isExpanded(expanded, stack[j])) {
                    ancestors_open = false;
                    break;
                }
            }
            if (!ancestors_open) continue;
            if (row_count >= out.len) break;

            const without_slash = this_prefix[0 .. this_prefix.len - 1];
            const label_start: usize = if (std.mem.lastIndexOfScalar(u8, without_slash, '/')) |s| s + 1 else 0;
            out[row_count] = .{
                .depth = @intCast(depth),
                .ancestor_mask = 0,
                .is_last = false,
                .kind = .dir,
                .label = without_slash[label_start..],
                .dir_prefix = this_prefix,
                .leaf_idx = 0,
            };
            row_count += 1;
        }

        var leaf_visible = true;
        var k: usize = 0;
        while (k < parents_len) : (k += 1) {
            if (!isExpanded(expanded, parents[k])) {
                leaf_visible = false;
                break;
            }
        }
        if (!leaf_visible) continue;
        if (row_count >= out.len) continue;

        out[row_count] = .{
            .depth = @intCast(parents_len),
            .ancestor_mask = 0,
            .is_last = false,
            .kind = .leaf,
            .label = basename(path),
            .dir_prefix = "",
            .leaf_idx = idx,
        };
        row_count += 1;
    }

    var r: usize = 0;
    while (r < row_count) : (r += 1) {
        const d = out[r].depth;
        var last = true;
        var s: usize = r + 1;
        while (s < row_count) : (s += 1) {
            const d2 = out[s].depth;
            if (d2 < d) break;
            if (d2 == d) {
                last = false;
                break;
            }
        }
        out[r].is_last = last;
    }

    var ancestor_last: [MAX_DEPTH]bool = .{true} ** MAX_DEPTH;
    var ancestor_len: usize = 0;
    r = 0;
    while (r < row_count) : (r += 1) {
        const d = out[r].depth;
        while (ancestor_len > d) {
            ancestor_len -= 1;
        }

        var mask: u16 = 0;
        var level: usize = 0;
        while (level < d) : (level += 1) {
            if (!ancestor_last[level]) {
                mask |= @as(u16, 1) << @intCast(level);
            }
        }
        out[r].ancestor_mask = mask;

        if (d < MAX_DEPTH) {
            ancestor_last[d] = out[r].is_last;
            ancestor_len = d + 1;
        }
    }

    return row_count;
}

fn flattenDynamic(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    expanded: ?*const std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(Row),
) !void {
    var stack: [MAX_DEPTH][]const u8 = undefined;
    var stack_len: usize = 0;

    for (paths, 0..) |path, idx| {
        var parents: [MAX_DEPTH][]const u8 = undefined;
        var parents_len: usize = 0;
        {
            var scan: usize = 0;
            while (std.mem.indexOfScalarPos(u8, path, scan, '/')) |slash| {
                if (parents_len >= MAX_DEPTH) break;
                parents[parents_len] = path[0 .. slash + 1];
                parents_len += 1;
                scan = slash + 1;
            }
        }

        var common: usize = 0;
        while (common < stack_len and common < parents_len and std.mem.eql(u8, stack[common], parents[common])) : (common += 1) {}
        stack_len = common;

        while (stack_len < parents_len) {
            const depth: usize = stack_len;
            const this_prefix = parents[depth];
            stack[stack_len] = this_prefix;
            stack_len += 1;

            var ancestors_open = true;
            var j: usize = 0;
            while (j < depth) : (j += 1) {
                if (!isExpanded(expanded, stack[j])) {
                    ancestors_open = false;
                    break;
                }
            }
            if (!ancestors_open) continue;

            const without_slash = this_prefix[0 .. this_prefix.len - 1];
            const label_start: usize = if (std.mem.lastIndexOfScalar(u8, without_slash, '/')) |s| s + 1 else 0;
            try out.append(allocator, .{
                .depth = @intCast(depth),
                .ancestor_mask = 0,
                .is_last = false,
                .kind = .dir,
                .label = without_slash[label_start..],
                .dir_prefix = this_prefix,
                .leaf_idx = 0,
            });
        }

        var leaf_visible = true;
        var k: usize = 0;
        while (k < parents_len) : (k += 1) {
            if (!isExpanded(expanded, parents[k])) {
                leaf_visible = false;
                break;
            }
        }
        if (!leaf_visible) continue;

        try out.append(allocator, .{
            .depth = @intCast(parents_len),
            .ancestor_mask = 0,
            .is_last = false,
            .kind = .leaf,
            .label = basename(path),
            .dir_prefix = "",
            .leaf_idx = idx,
        });
    }

    var r: usize = 0;
    while (r < out.items.len) : (r += 1) {
        const d = out.items[r].depth;
        var last = true;
        var s: usize = r + 1;
        while (s < out.items.len) : (s += 1) {
            const d2 = out.items[s].depth;
            if (d2 < d) break;
            if (d2 == d) {
                last = false;
                break;
            }
        }
        out.items[r].is_last = last;
    }

    var ancestor_last: [MAX_DEPTH]bool = .{true} ** MAX_DEPTH;
    var ancestor_len: usize = 0;
    r = 0;
    while (r < out.items.len) : (r += 1) {
        const d = out.items[r].depth;
        while (ancestor_len > d) {
            ancestor_len -= 1;
        }

        var mask: u16 = 0;
        var level: usize = 0;
        while (level < d) : (level += 1) {
            if (!ancestor_last[level]) {
                mask |= @as(u16, 1) << @intCast(level);
            }
        }
        out.items[r].ancestor_mask = mask;

        if (d < MAX_DEPTH) {
            ancestor_last[d] = out.items[r].is_last;
            ancestor_len = d + 1;
        }
    }
}

fn isExpanded(set: ?*const std.StringHashMapUnmanaged(void), key: []const u8) bool {
    const s = set orelse return true;
    return s.contains(key);
}

fn basename(path: []const u8) []const u8 {
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return stripMd(path);
    return stripMd(path[last_slash + 1 ..]);
}

fn stripMd(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".md")) return name[0 .. name.len - 3];
    return name;
}

/// Writes tree guides + connector + optional chevron into `buf`.
/// Depth-1 rows start directly with the branch connector instead of an extra
/// blank indent segment, which keeps the tree visually aligned with the root.
/// Returns the number of bytes written. Safe against buffer overflow.
pub fn renderPrefix(
    buf: []u8,
    depth: u8,
    ancestor_mask: u16,
    is_last: bool,
    chevron: ?Chevron,
) usize {
    var len: usize = 0;
    var pad: u8 = 1;
    while (pad < depth) : (pad += 1) {
        const guide: []const u8 = if ((ancestor_mask & (@as(u16, 1) << @intCast(pad))) == 0)
            "  "
        else
            "\xe2\x94\x82 "; // "│ "
        if (len + guide.len > buf.len) return len;
        @memcpy(buf[len .. len + guide.len], guide);
        len += guide.len;
    }
    if (depth > 0) {
        const connector: []const u8 = if (is_last)
            "\xe2\x94\x94\xe2\x94\x80 " // "└─ "
        else
            "\xe2\x94\x9c\xe2\x94\x80 "; // "├─ "
        if (len + connector.len > buf.len) return len;
        @memcpy(buf[len .. len + connector.len], connector);
        len += connector.len;
    }
    if (chevron) |ch| {
        const g: []const u8 = switch (ch) {
            .expanded => "\xe2\x96\xbc ", // "▼ "
            .collapsed => "\xe2\x96\xb6 ", // "▶ "
        };
        if (len + g.len > buf.len) return len;
        @memcpy(buf[len .. len + g.len], g);
        len += g.len;
    }
    return len;
}

pub const Chevron = enum { collapsed, expanded };

pub fn appendText(buf: []u8, start: usize, text: []const u8) usize {
    const cap = buf.len -| start;
    const take = @min(text.len, cap);
    if (take > 0) @memcpy(buf[start .. start + take], text[0..take]);
    return start + take;
}

pub fn State(comptime max_rows: usize, comptime text_buf_len: usize) type {
    return struct {
        const Self = @This();
        const _max_rows_compat = max_rows;

        leaf_indices: std.ArrayListUnmanaged(?usize) = .empty,
        dir_paths: std.ArrayListUnmanaged(?[]const u8) = .empty,
        depths: std.ArrayListUnmanaged(u8) = .empty,
        text_lens: std.ArrayListUnmanaged(usize) = .empty,
        text_bufs: std.ArrayListUnmanaged([text_buf_len]u8) = .empty,
        all_dir_paths: std.ArrayListUnmanaged([]const u8) = .empty,
        expanded: std.StringHashMapUnmanaged(void) = .empty,
        seen_dir_paths: std.StringHashMapUnmanaged(void) = .empty,
        initialized: bool = false,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.leaf_indices.deinit(allocator);
            self.dir_paths.deinit(allocator);
            self.depths.deinit(allocator);
            self.text_lens.deinit(allocator);
            self.text_bufs.deinit(allocator);
            self.freeAllDirPaths(allocator);
            self.all_dir_paths.deinit(allocator);
            freeMapKeys(allocator, &self.expanded);
            self.expanded.deinit(allocator);
            freeMapKeys(allocator, &self.seen_dir_paths);
            self.seen_dir_paths.deinit(allocator);
        }

        pub fn reset(self: *Self, allocator: std.mem.Allocator) void {
            self.freeAllDirPaths(allocator);
            freeMapKeys(allocator, &self.expanded);
            freeMapKeys(allocator, &self.seen_dir_paths);
            self.initialized = false;
            self.clearRows();
        }

        pub fn rowCount(self: *const Self) usize {
            return self.text_lens.items.len;
        }

        pub fn rowText(self: *const Self, row: usize) []const u8 {
            if (row >= self.rowCount()) return "";
            return self.text_bufs.items[row][0..self.text_lens.items[row]];
        }

        pub fn dirPathAt(self: *const Self, row: usize) ?[]const u8 {
            if (row >= self.rowCount()) return null;
            return self.dir_paths.items[row];
        }

        pub fn leafIndexAt(self: *const Self, row: usize) ?usize {
            if (row >= self.rowCount()) return null;
            return self.leaf_indices.items[row];
        }

        pub fn depthAt(self: *const Self, row: usize) u8 {
            if (row >= self.rowCount()) return 0;
            return self.depths.items[row];
        }

        pub fn parentRow(self: *const Self, row: usize) ?usize {
            if (row >= self.rowCount() or row == 0) return null;
            const cur_depth = self.depthAt(row);
            if (cur_depth == 0) return null;

            var pos = row;
            while (pos > 0) {
                pos -= 1;
                if (self.depthAt(pos) < cur_depth) return pos;
            }
            return null;
        }

        pub fn isExpanded(self: *const Self, prefix: []const u8) bool {
            return self.expanded.contains(prefix);
        }

        pub fn expandDir(self: *Self, allocator: std.mem.Allocator, prefix: []const u8) bool {
            if (self.expanded.contains(prefix)) return false;
            putOwnedMapKey(allocator, &self.expanded, prefix) catch return false;
            return true;
        }

        pub fn collapseDir(self: *Self, allocator: std.mem.Allocator, prefix: []const u8) bool {
            if (self.expanded.fetchRemove(prefix)) |kv| {
                allocator.free(kv.key);
                return true;
            }
            return false;
        }

        pub fn toggleDir(self: *Self, allocator: std.mem.Allocator, prefix: []const u8) void {
            if (self.collapseDir(allocator, prefix)) return;
            _ = self.expandDir(allocator, prefix);
        }

        pub fn toggleAll(self: *Self, allocator: std.mem.Allocator) void {
            if (self.all_dir_paths.items.len == 0) return;
            if (self.currentExpandedDirCount() < self.all_dir_paths.items.len) {
                freeMapKeys(allocator, &self.expanded);
                for (self.all_dir_paths.items) |path| {
                    putOwnedMapKey(allocator, &self.expanded, path) catch return;
                }
            } else {
                freeMapKeys(allocator, &self.expanded);
            }
        }

        fn currentExpandedDirCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.all_dir_paths.items) |path| {
                if (self.expanded.contains(path)) count += 1;
            }
            return count;
        }

        pub fn sync(
            self: *Self,
            allocator: std.mem.Allocator,
            paths: []const []const u8,
            original_leaf_indices: []const usize,
        ) void {
            const item_count = @min(paths.len, original_leaf_indices.len);
            if (item_count == 0) {
                self.clearRows();
                return;
            }

            self.expandNewDirPrefixes(allocator, paths[0..item_count]);
            self.initialized = true;

            const sort_idx = allocator.alloc(usize, item_count) catch {
                self.clearRows();
                return;
            };
            defer allocator.free(sort_idx);
            sortPathIndices(paths[0..item_count], sort_idx);

            const sorted_paths = allocator.alloc([]const u8, item_count) catch {
                self.clearRows();
                return;
            };
            defer allocator.free(sorted_paths);
            const sorted_orig = allocator.alloc(usize, item_count) catch {
                self.clearRows();
                return;
            };
            defer allocator.free(sorted_orig);
            for (0..item_count) |i| {
                sorted_paths[i] = paths[sort_idx[i]];
                sorted_orig[i] = original_leaf_indices[sort_idx[i]];
            }
            self.syncAllDirPaths(allocator, sorted_paths[0..item_count]);

            var rows_buf: std.ArrayListUnmanaged(Row) = .empty;
            defer rows_buf.deinit(allocator);
            flattenDynamic(allocator, sorted_paths[0..item_count], &self.expanded, &rows_buf) catch {
                self.clearRows();
                return;
            };

            var next_leaf_indices: std.ArrayListUnmanaged(?usize) = .empty;
            defer next_leaf_indices.deinit(allocator);
            var next_dir_paths: std.ArrayListUnmanaged(?[]const u8) = .empty;
            defer next_dir_paths.deinit(allocator);
            var next_depths: std.ArrayListUnmanaged(u8) = .empty;
            defer next_depths.deinit(allocator);
            var next_text_lens: std.ArrayListUnmanaged(usize) = .empty;
            defer next_text_lens.deinit(allocator);
            var next_text_bufs: std.ArrayListUnmanaged([text_buf_len]u8) = .empty;
            defer next_text_bufs.deinit(allocator);

            var i: usize = 0;
            while (i < rows_buf.items.len) : (i += 1) {
                const tr = rows_buf.items[i];
                var buf: [text_buf_len]u8 = undefined;

                var len = renderPrefix(&buf, tr.depth, tr.ancestor_mask, tr.is_last, null);
                len = appendText(&buf, len, tr.label);
                if (tr.kind == .dir and len < buf.len) {
                    buf[len] = '/';
                    len += 1;
                }

                switch (tr.kind) {
                    .dir => {
                        next_leaf_indices.append(allocator, null) catch return;
                        next_dir_paths.append(allocator, tr.dir_prefix) catch return;
                    },
                    .leaf => {
                        next_leaf_indices.append(allocator, sorted_orig[tr.leaf_idx]) catch return;
                        next_dir_paths.append(allocator, null) catch return;
                    },
                }
                next_depths.append(allocator, tr.depth) catch return;
                next_text_lens.append(allocator, len) catch return;
                next_text_bufs.append(allocator, buf) catch return;
            }

            self.clearRows();
            self.leaf_indices.appendSlice(allocator, next_leaf_indices.items) catch return;
            self.dir_paths.appendSlice(allocator, next_dir_paths.items) catch {
                self.clearRows();
                return;
            };
            self.depths.appendSlice(allocator, next_depths.items) catch {
                self.clearRows();
                return;
            };
            self.text_lens.appendSlice(allocator, next_text_lens.items) catch {
                self.clearRows();
                return;
            };
            self.text_bufs.appendSlice(allocator, next_text_bufs.items) catch {
                self.clearRows();
                return;
            };
        }

        fn clearRows(self: *Self) void {
            self.leaf_indices.clearRetainingCapacity();
            self.dir_paths.clearRetainingCapacity();
            self.depths.clearRetainingCapacity();
            self.text_lens.clearRetainingCapacity();
            self.text_bufs.clearRetainingCapacity();
        }

        fn syncAllDirPaths(self: *Self, allocator: std.mem.Allocator, paths: []const []const u8) void {
            self.freeAllDirPaths(allocator);
            for (paths) |path| {
                var scan: usize = 0;
                while (std.mem.indexOfScalarPos(u8, path, scan, '/')) |slash| {
                    const prefix = path[0 .. slash + 1];
                    if (!self.hasDirPath(prefix)) {
                        const owned = allocator.dupe(u8, prefix) catch return;
                        self.all_dir_paths.append(allocator, owned) catch {
                            allocator.free(owned);
                            return;
                        };
                    }
                    scan = slash + 1;
                }
            }
        }

        fn hasDirPath(self: *const Self, prefix: []const u8) bool {
            for (self.all_dir_paths.items) |path| {
                if (std.mem.eql(u8, path, prefix)) return true;
            }
            return false;
        }

        fn expandNewDirPrefixes(self: *Self, allocator: std.mem.Allocator, paths: []const []const u8) void {
            for (paths) |path| {
                var scan: usize = 0;
                while (std.mem.indexOfScalarPos(u8, path, scan, '/')) |slash| {
                    const prefix = path[0 .. slash + 1];
                    scan = slash + 1;
                    if (self.seen_dir_paths.contains(prefix)) continue;
                    putOwnedMapKey(allocator, &self.seen_dir_paths, prefix) catch continue;
                    putOwnedMapKey(allocator, &self.expanded, prefix) catch {};
                }
            }
        }

        fn freeAllDirPaths(self: *Self, allocator: std.mem.Allocator) void {
            for (self.all_dir_paths.items) |path| allocator.free(path);
            self.all_dir_paths.clearRetainingCapacity();
        }
    };
}

fn putOwnedMapKey(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(void),
    key: []const u8,
) !void {
    if (map.contains(key)) return;
    const owned = try allocator.dupe(u8, key);
    errdefer allocator.free(owned);
    try map.put(allocator, owned, {});
}

fn freeMapKeys(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(void),
) void {
    var it = map.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
    map.clearRetainingCapacity();
}

fn sortPathIndices(paths: []const []const u8, out: []usize) void {
    for (0..paths.len) |i| out[i] = i;
    const SortCtx = struct {
        paths: []const []const u8,

        fn lt(cx: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, cx.paths[a], cx.paths[b]);
        }
    };
    std.mem.sort(usize, out[0..paths.len], SortCtx{ .paths = paths }, SortCtx.lt);
}

test "flatten marks nested rows and last siblings correctly" {
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;

    const paths = [_][]const u8{
        "rule/api/NAMING.md",
        "rule/db/E2E.md",
        "workflow/GEN_PR.md",
    };
    var rows: [16]Row = undefined;

    const count = flatten(paths[0..], null, &rows);
    try expectEqual(@as(usize, 7), count);

    try expectEqual(RowKind.dir, rows[0].kind);
    try expectEqual(@as(u8, 0), rows[0].depth);
    try expectEqual(false, rows[0].is_last);
    try expectEqualStrings("rule", rows[0].label);

    try expectEqual(RowKind.dir, rows[1].kind);
    try expectEqual(@as(u8, 1), rows[1].depth);
    try expectEqual(false, rows[1].is_last);
    try expectEqualStrings("api", rows[1].label);

    try expectEqual(RowKind.leaf, rows[2].kind);
    try expectEqual(@as(u8, 2), rows[2].depth);
    try expectEqual(true, rows[2].is_last);
    try expectEqualStrings("NAMING", rows[2].label);

    try expectEqual(RowKind.dir, rows[3].kind);
    try expectEqual(@as(u8, 1), rows[3].depth);
    try expectEqual(true, rows[3].is_last);
    try expectEqualStrings("db", rows[3].label);

    try expectEqual(RowKind.leaf, rows[4].kind);
    try expectEqual(@as(u8, 2), rows[4].depth);
    try expectEqual(true, rows[4].is_last);
    try expectEqualStrings("E2E", rows[4].label);

    try expectEqual(RowKind.dir, rows[5].kind);
    try expectEqual(@as(u8, 0), rows[5].depth);
    try expectEqual(true, rows[5].is_last);
    try expectEqualStrings("workflow", rows[5].label);

    try expectEqual(RowKind.leaf, rows[6].kind);
    try expectEqual(@as(u8, 1), rows[6].depth);
    try expectEqual(true, rows[6].is_last);
    try expectEqualStrings("GEN_PR", rows[6].label);
}

test "flatten respects expansion state and hides collapsed leaves" {
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;

    const paths = [_][]const u8{
        "rule/api/NAMING.md",
        "rule/db/E2E.md",
        "workflow/GEN_PR.md",
    };
    var expanded: std.StringHashMapUnmanaged(void) = .empty;
    defer expanded.deinit(std.testing.allocator);
    try expanded.put(std.testing.allocator, "rule/", {});

    var rows: [16]Row = undefined;
    const count = flatten(paths[0..], &expanded, &rows);

    try expectEqual(@as(usize, 4), count);
    try expectEqualStrings("rule", rows[0].label);
    try expectEqualStrings("api", rows[1].label);
    try expectEqualStrings("db", rows[2].label);
    try expectEqualStrings("workflow", rows[3].label);
    try expectEqual(RowKind.dir, rows[1].kind);
    try expectEqual(RowKind.dir, rows[2].kind);
    try expectEqual(RowKind.dir, rows[3].kind);
}

test "flatten caps directory depth at MAX_DEPTH" {
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;

    const paths = [_][]const u8{"a/b/c/d/e/f/g/h/i/j.md"};
    var rows: [16]Row = undefined;

    const count = flatten(paths[0..], null, &rows);
    try expectEqual(@as(usize, 9), count);
    try expectEqual(RowKind.dir, rows[7].kind);
    try expectEqual(@as(u8, 7), rows[7].depth);
    try expectEqualStrings("h", rows[7].label);
    try expectEqual(RowKind.leaf, rows[8].kind);
    try expectEqual(@as(u8, MAX_DEPTH), rows[8].depth);
    try expectEqualStrings("j", rows[8].label);
}

test "renderPrefix draws guides connectors and chevrons" {
    var buf: [32]u8 = undefined;
    const len = renderPrefix(&buf, 3, 0b0010, false, .collapsed);
    try std.testing.expectEqualStrings("\xe2\x94\x82   \xe2\x94\x9c\xe2\x94\x80 \xe2\x96\xb6 ", buf[0..len]);
}

test "State sync default-expands top level prefixes and maps leaf indices" {
    const TreeState = State(8, 64);
    var state: TreeState = .{};
    defer state.deinit(std.testing.allocator);

    const paths = [_][]const u8{
        "rule/api/NAMING.md",
        "rule/db/E2E.md",
        "workflow/GEN_PR.md",
    };
    const orig = [_]usize{ 10, 20, 30 };

    state.sync(std.testing.allocator, paths[0..], orig[0..]);

    try std.testing.expectEqual(@as(usize, 7), state.rowCount());
    try std.testing.expectEqualStrings("rule/", state.rowText(0));
    try std.testing.expect(std.mem.endsWith(u8, state.rowText(1), "api/"));
    try std.testing.expectEqualStrings("workflow/", state.rowText(5));
    try std.testing.expect(std.mem.endsWith(u8, state.rowText(6), "GEN_PR"));
    try std.testing.expectEqual(@as(?usize, 30), state.leafIndexAt(6));
    try std.testing.expect(state.isExpanded("rule/"));
    try std.testing.expect(state.isExpanded("rule/api/"));
    try std.testing.expect(state.isExpanded("rule/db/"));
    try std.testing.expect(state.isExpanded("workflow/"));
}

test "State sync keeps rows beyond legacy fixed capacity" {
    const TreeState = State(2, 64);
    var state: TreeState = .{};
    defer state.deinit(std.testing.allocator);

    const paths = [_][]const u8{
        "adr/ADR-001.md",
        "research/R1.md",
        "spec/s1.md",
        "todo/A.md",
        "todo/B.md",
        "todo/C.md",
    };
    const orig = [_]usize{ 0, 1, 2, 3, 4, 5 };

    state.sync(std.testing.allocator, paths[0..], orig[0..]);

    try std.testing.expect(state.rowCount() > 2);
    try std.testing.expectEqual(@as(?usize, 5), state.leafIndexAt(state.rowCount() - 1));
    try std.testing.expect(std.mem.endsWith(u8, state.rowText(state.rowCount() - 1), "C"));
}

test "State sync expands top level prefixes that appear after first sync" {
    const TreeState = State(16, 64);
    var state: TreeState = .{};
    defer state.deinit(std.testing.allocator);

    const draft_paths = [_][]const u8{
        "research/R20.md",
        "todo/WORK.md",
    };
    const draft_orig = [_]usize{ 0, 1 };
    state.sync(std.testing.allocator, draft_paths[0..], draft_orig[0..]);

    const live_paths = [_][]const u8{
        "adr/ADR-001.md",
        "research/R1.md",
        "spec/s1.md",
        "todo/WORK.md",
    };
    const live_orig = [_]usize{ 10, 11, 12, 13 };
    state.sync(std.testing.allocator, live_paths[0..], live_orig[0..]);

    try std.testing.expect(state.isExpanded("adr/"));
    try std.testing.expect(state.isExpanded("research/"));
    try std.testing.expect(state.isExpanded("spec/"));
    try std.testing.expect(state.isExpanded("todo/"));
}

test "State sync expands nested prefixes that appear after first sync" {
    const TreeState = State(16, 64);
    var state: TreeState = .{};
    defer state.deinit(std.testing.allocator);

    const initial_paths = [_][]const u8{
        "research/R1.md",
    };
    const initial_orig = [_]usize{0};
    state.sync(std.testing.allocator, initial_paths[0..], initial_orig[0..]);

    const next_paths = [_][]const u8{
        "research/R1.md",
        "research/log/zig-std-log.md",
        "vxfw/WIDGET_API.md",
    };
    const next_orig = [_]usize{ 0, 1, 2 };
    state.sync(std.testing.allocator, next_paths[0..], next_orig[0..]);

    try std.testing.expect(state.isExpanded("research/"));
    try std.testing.expect(state.isExpanded("research/log/"));
    try std.testing.expect(state.isExpanded("vxfw/"));
    var found_log = false;
    for (0..state.rowCount()) |row| {
        if (state.dirPathAt(row)) |dir| {
            if (!std.mem.eql(u8, dir, "research/log/")) continue;
            found_log = true;
            break;
        }
    }
    try std.testing.expect(found_log);
}

test "State sync does not re-expand a top level prefix after user collapse" {
    const TreeState = State(16, 64);
    var state: TreeState = .{};
    defer state.deinit(std.testing.allocator);

    const first_paths = [_][]const u8{
        "research/R20.md",
    };
    const first_orig = [_]usize{0};
    state.sync(std.testing.allocator, first_paths[0..], first_orig[0..]);
    try std.testing.expect(state.collapseDir(std.testing.allocator, "research/"));

    const next_paths = [_][]const u8{
        "research/R1.md",
        "research/R20.md",
    };
    const next_orig = [_]usize{ 0, 1 };
    state.sync(std.testing.allocator, next_paths[0..], next_orig[0..]);

    try std.testing.expect(!state.isExpanded("research/"));
}

test "State owns expanded prefix keys across caller buffer reuse" {
    const TreeState = State(16, 64);
    var state: TreeState = .{};
    defer state.deinit(std.testing.allocator);

    var path_buf = [_]u8{ 'a', 'l', 'p', 'h', 'a', '/', 'A', '.', 'm', 'd' };
    var paths = [_][]const u8{path_buf[0..]};
    const orig = [_]usize{0};
    state.sync(std.testing.allocator, paths[0..], orig[0..]);
    try std.testing.expect(state.isExpanded("alpha/"));

    @memcpy(path_buf[0..4], "beta");
    path_buf[4] = '/';
    path_buf[5] = 'B';
    path_buf[6] = '.';
    path_buf[7] = 'm';
    path_buf[8] = 'd';
    paths[0] = path_buf[0..9];
    state.sync(std.testing.allocator, paths[0..], orig[0..]);

    try std.testing.expect(state.isExpanded("alpha/"));
    try std.testing.expect(state.isExpanded("beta/"));
}

test "State toggleAll expands and collapses every known directory" {
    const TreeState = State(16, 64);
    var state: TreeState = .{};
    defer state.deinit(std.testing.allocator);

    const paths = [_][]const u8{
        "rule/api/NAMING.md",
        "rule/db/E2E.md",
        "workflow/release/SHIP.md",
    };
    const orig = [_]usize{ 0, 1, 2 };
    state.sync(std.testing.allocator, paths[0..], orig[0..]);

    state.toggleAll(std.testing.allocator);
    try std.testing.expect(!state.isExpanded("rule/"));
    try std.testing.expect(!state.isExpanded("workflow/"));

    state.toggleAll(std.testing.allocator);
    try std.testing.expect(state.isExpanded("rule/"));
    try std.testing.expect(state.isExpanded("rule/api/"));
    try std.testing.expect(state.isExpanded("rule/db/"));
    try std.testing.expect(state.isExpanded("workflow/"));
    try std.testing.expect(state.isExpanded("workflow/release/"));
}

test "State parentRow returns the nearest shallower visible ancestor" {
    const TreeState = State(8, 64);
    var state: TreeState = .{};
    defer state.deinit(std.testing.allocator);

    const paths = [_][]const u8{
        "rule/api/NAMING.md",
        "rule/db/E2E.md",
    };
    const orig = [_]usize{ 0, 1 };

    state.sync(std.testing.allocator, paths[0..], orig[0..]);
    try std.testing.expectEqual(@as(?usize, 0), state.parentRow(1));
    try std.testing.expectEqual(@as(?usize, 1), state.parentRow(2));
    try std.testing.expectEqual(@as(?usize, 0), state.parentRow(3));
}
