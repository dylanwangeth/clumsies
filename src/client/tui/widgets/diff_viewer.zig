//! Shared diff-rendering primitive. Two call sites consume this: the PR
//! review pane renders server-side unified diffs via `styleLine`, and the
//! Content panel shows a working-copy view via `computeInlineGutter`
//! (base = cache, proposed = draft overlay). Both paths need the same
//! color classification so added / deleted / hunk / context lines look
//! identical regardless of where the diff came from.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("../theme.zig");

/// Classification of a unified-diff line. Kept separate from
/// `styleLine` so tests and non-rendering callers can reason about
/// shape without pulling in theme colors.
pub const LineKind = enum {
    context,
    addition,
    deletion,
    hunk_header,
};

pub fn classifyLine(line: []const u8) LineKind {
    if (std.mem.startsWith(u8, line, "@@")) return .hunk_header;
    if (std.mem.startsWith(u8, line, "+")) return .addition;
    if (std.mem.startsWith(u8, line, "-")) return .deletion;
    return .context;
}

pub fn styleLine(line: []const u8) vaxis.Style {
    return switch (classifyLine(line)) {
        .addition => .{ .fg = theme.OK, .bg = theme.rgb(0x1d2617) },
        .deletion => .{ .fg = theme.DANGER, .bg = theme.rgb(0x2a1b18) },
        .hunk_header => .{ .fg = theme.INFO, .bg = theme.PANEL },
        .context => .{ .fg = theme.TEXT_SOFT, .bg = theme.PANEL },
    };
}

/// Produce a unified-diff rendering (prefixed with `  ` / `- ` / `+ `)
/// between two text blobs split on newlines. Used by the PR detail
/// consumer to materialise the diff view after fetching the operation.
pub fn computeDiffLines(
    alloc: std.mem.Allocator,
    base: []const u8,
    proposed: []const u8,
) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| alloc.free(line);
        lines.deinit(alloc);
    }
    var base_it = std.mem.splitScalar(u8, base, '\n');
    var prop_it = std.mem.splitScalar(u8, proposed, '\n');

    while (true) {
        const b = base_it.next();
        const p = prop_it.next();
        if (b == null and p == null) break;
        if (b != null and p != null and std.mem.eql(u8, b.?, p.?)) {
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "  {s}", .{b.?}));
        } else {
            if (b) |bl| {
                try lines.append(alloc, try std.fmt.allocPrint(alloc, "- {s}", .{bl}));
            }
            if (p) |pl| {
                try lines.append(alloc, try std.fmt.allocPrint(alloc, "+ {s}", .{pl}));
            }
        }
    }
    return try lines.toOwnedSlice(alloc);
}

pub const Marker = enum { unchanged, added, removed };

pub const DiffRow = struct {
    text: []const u8,
    old_line: ?u32,
    new_line: ?u32,
    marker: Marker,
};

/// Ceiling on per-side line count before `computeInlineGutter` bails.
/// LCS is O(m*n) in both time and memory; at 1500 lines per side the
/// working table is roughly 9 MB, which keeps the render path
/// responsive on large files. Callers fall back to the unified diff
/// view when this returns null.
pub const MAX_DIFF_LINES_PER_SIDE: usize = 1500;

/// Compute an inline-gutter diff between `base` and `proposed`.
/// Returns a row per aligned line; caller owns the slice.
/// Returns null if either side exceeds `MAX_DIFF_LINES_PER_SIDE`.
/// The returned `text` pointers reference `base` and `proposed`
/// directly (no copy), so the inputs must outlive the returned rows.
pub fn computeInlineGutter(
    allocator: std.mem.Allocator,
    base: []const u8,
    proposed: []const u8,
) !?[]DiffRow {
    const base_lines = try splitLines(allocator, base);
    defer allocator.free(base_lines);
    const proposed_lines = try splitLines(allocator, proposed);
    defer allocator.free(proposed_lines);

    if (base_lines.len > MAX_DIFF_LINES_PER_SIDE) return null;
    if (proposed_lines.len > MAX_DIFF_LINES_PER_SIDE) return null;

    const m = base_lines.len;
    const n = proposed_lines.len;
    const stride = n + 1;
    const dp = try allocator.alloc(u32, (m + 1) * stride);
    defer allocator.free(dp);
    @memset(dp, 0);

    var i: usize = 1;
    while (i <= m) : (i += 1) {
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            if (std.mem.eql(u8, base_lines[i - 1], proposed_lines[j - 1])) {
                dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1;
            } else {
                const up = dp[(i - 1) * stride + j];
                const left = dp[i * stride + (j - 1)];
                dp[i * stride + j] = @max(up, left);
            }
        }
    }

    var rows: std.ArrayListUnmanaged(DiffRow) = .empty;
    errdefer rows.deinit(allocator);

    i = m;
    var j: usize = n;
    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, base_lines[i - 1], proposed_lines[j - 1])) {
            try rows.append(allocator, .{
                .text = base_lines[i - 1],
                .old_line = @intCast(i),
                .new_line = @intCast(j),
                .marker = .unchanged,
            });
            i -= 1;
            j -= 1;
        } else if (j > 0 and (i == 0 or dp[i * stride + (j - 1)] >= dp[(i - 1) * stride + j])) {
            try rows.append(allocator, .{
                .text = proposed_lines[j - 1],
                .old_line = null,
                .new_line = @intCast(j),
                .marker = .added,
            });
            j -= 1;
        } else {
            try rows.append(allocator, .{
                .text = base_lines[i - 1],
                .old_line = @intCast(i),
                .new_line = null,
                .marker = .removed,
            });
            i -= 1;
        }
    }

    std.mem.reverse(DiffRow, rows.items);
    return try rows.toOwnedSlice(allocator);
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    if (text.len == 0) return try lines.toOwnedSlice(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    // A trailing newline produces a trailing empty element; drop it so
    // "a\nb\n" and "a\nb" both produce 2 logical lines.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return try lines.toOwnedSlice(allocator);
}

test "classifyLine: four shapes" {
    try std.testing.expectEqual(LineKind.context, classifyLine("plain line"));
    try std.testing.expectEqual(LineKind.addition, classifyLine("+added"));
    try std.testing.expectEqual(LineKind.deletion, classifyLine("-removed"));
    try std.testing.expectEqual(LineKind.hunk_header, classifyLine("@@ -1,3 +1,4 @@"));
}

test "classifyLine: empty line is context" {
    try std.testing.expectEqual(LineKind.context, classifyLine(""));
}

test "computeDiffLines: returns owned prefixed lines" {
    const lines = try computeDiffLines(std.testing.allocator, "a\nold", "a\nnew");
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("  a", lines[0]);
    try std.testing.expectEqualStrings("- old", lines[1]);
    try std.testing.expectEqualStrings("+ new", lines[2]);
}

test "computeInlineGutter: identical input yields all unchanged" {
    const rows = (try computeInlineGutter(std.testing.allocator, "a\nb\nc\n", "a\nb\nc\n")).?;
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |r| try std.testing.expectEqual(Marker.unchanged, r.marker);
    try std.testing.expectEqualStrings("a", rows[0].text);
    try std.testing.expectEqualStrings("b", rows[1].text);
    try std.testing.expectEqualStrings("c", rows[2].text);
    try std.testing.expectEqual(@as(?u32, 1), rows[0].old_line);
    try std.testing.expectEqual(@as(?u32, 1), rows[0].new_line);
}

test "computeInlineGutter: pure addition" {
    const rows = (try computeInlineGutter(std.testing.allocator, "", "new\nline\n")).?;
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |r| {
        try std.testing.expectEqual(Marker.added, r.marker);
        try std.testing.expectEqual(@as(?u32, null), r.old_line);
    }
}

test "computeInlineGutter: pure deletion" {
    const rows = (try computeInlineGutter(std.testing.allocator, "old\nline\n", "")).?;
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |r| {
        try std.testing.expectEqual(Marker.removed, r.marker);
        try std.testing.expectEqual(@as(?u32, null), r.new_line);
    }
}

test "computeInlineGutter: middle-line modify" {
    const rows = (try computeInlineGutter(std.testing.allocator, "a\nold\nc\n", "a\nnew\nc\n")).?;
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(Marker.unchanged, rows[0].marker);
    try std.testing.expectEqualStrings("a", rows[0].text);
    try std.testing.expectEqual(Marker.unchanged, rows[rows.len - 1].marker);
    try std.testing.expectEqualStrings("c", rows[rows.len - 1].text);
    var saw_add = false;
    var saw_remove = false;
    for (rows) |r| {
        if (r.marker == .added and std.mem.eql(u8, r.text, "new")) saw_add = true;
        if (r.marker == .removed and std.mem.eql(u8, r.text, "old")) saw_remove = true;
    }
    try std.testing.expect(saw_add);
    try std.testing.expect(saw_remove);
}

test "computeInlineGutter: empty on both sides" {
    const rows = (try computeInlineGutter(std.testing.allocator, "", "")).?;
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}

test "computeInlineGutter: returns null above cap" {
    var base_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer base_buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < MAX_DIFF_LINES_PER_SIDE + 1) : (i += 1) {
        try base_buf.appendSlice(std.testing.allocator, "x\n");
    }
    const result = try computeInlineGutter(std.testing.allocator, base_buf.items, "");
    try std.testing.expect(result == null);
}
