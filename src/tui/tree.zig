// Tree flattening for path-structured lists.
//
// Given a sorted list of slash-separated paths and a set of expanded
// directory prefixes, produces a flat sequence of visible rows: directory
// headers whose ancestors are all expanded, and leaves whose full ancestor
// chain is expanded. Siblings are adjacent so tree connectors (├/└) can be
// computed with a single forward sweep.
//
// Callers own the output buffer. Pass `expanded = null` to render the
// whole tree as fully expanded (useful for non-interactive nested views).

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
