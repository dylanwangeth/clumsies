//! Shortcut hint renderer for footer bars and compact overlay footers.
//! The component keeps shortcut data structured and hides later hints first
//! when the available width is too small.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

pub const Shortcut = struct {
    key: []const u8,
    label: []const u8,
};

pub const Options = struct {
    row: u16 = 0,
    col: u16 = 1,
    /// Exclusive upper bound. The renderer never writes at or beyond
    /// this column, which lets callers reserve the footer's right side
    /// for status text.
    max_col: ?u16 = null,
};

pub const DrawResult = struct {
    next_col: u16,
    hidden_count: usize,
};

pub fn sortedCopy(
    arena: std.mem.Allocator,
    shortcuts: []const Shortcut,
) std.mem.Allocator.Error![]const Shortcut {
    const out = try arena.dupe(Shortcut, shortcuts);
    sortInPlace(out);
    return out;
}

pub fn sortInPlace(shortcuts: []Shortcut) void {
    std.mem.sort(Shortcut, shortcuts, {}, shortcutLessThan);
}

pub fn drawInline(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    shortcuts: []const Shortcut,
    options: Options,
) DrawResult {
    if (options.row >= surface.size.height) return .{
        .next_col = options.col,
        .hidden_count = shortcuts.len,
    };

    const limit = @min(options.max_col orelse surface.size.width, surface.size.width);
    var col = options.col;
    var hidden: usize = 0;

    for (shortcuts, 0..) |shortcut, index| {
        const width = shortcutWidth(ctx, shortcut);
        if (width == 0) continue;
        if (col + width > limit) {
            hidden = shortcuts.len - index;
            break;
        }
        drawShortcut(surface, ctx, options.row, col, shortcut);
        col += width;
    }

    if (hidden > 0 and col + 3 <= limit) {
        d.writeText(surface, ctx, col, options.row, "...", theme.fg(theme.MUTED));
        col += 3;
    }

    return .{ .next_col = col, .hidden_count = hidden };
}

pub fn shortcutWidth(ctx: vxfw.DrawContext, shortcut: Shortcut) u16 {
    return itemWidth(
        @intCast(ctx.stringWidth(shortcut.key)),
        @intCast(ctx.stringWidth(shortcut.label)),
    );
}

pub fn itemWidth(key_width: u16, label_width: u16) u16 {
    if (key_width == 0) return 0;
    const label_part: u16 = if (label_width == 0) 0 else 1 + label_width;
    return key_width + 2 + label_part + 2;
}

fn drawShortcut(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    row: u16,
    col: u16,
    shortcut: Shortcut,
) void {
    const key_width: u16 = @intCast(ctx.stringWidth(shortcut.key));
    const key_box_width = key_width + 2;
    const key_style = keyStyle();
    var offset: u16 = 0;
    while (offset < key_box_width and col + offset < surface.size.width) : (offset += 1) {
        surface.writeCell(col + offset, row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = key_style,
        });
    }
    d.writeText(surface, ctx, col + 1, row, shortcut.key, key_style);

    if (shortcut.label.len > 0) {
        d.writeText(
            surface,
            ctx,
            col + key_box_width + 1,
            row,
            shortcut.label,
            labelStyle(),
        );
    }
}

fn keyStyle() vaxis.Style {
    return theme.boldOn(theme.ACCENT_SOFT, theme.PANEL);
}

const ShortcutSortKey = struct {
    layer: u8,
    primary: u8,
    text: []const u8,
};

fn shortcutLessThan(_: void, a: Shortcut, b: Shortcut) bool {
    const ka = shortcutSortKey(a.key);
    const kb = shortcutSortKey(b.key);
    if (ka.layer != kb.layer) return ka.layer < kb.layer;
    if (ka.primary != kb.primary) return ka.primary < kb.primary;
    return asciiLessThan(ka.text, kb.text);
}

fn shortcutSortKey(key: []const u8) ShortcutSortKey {
    if (stripModifier(key, "Ctrl")) |payload| {
        return .{ .layer = 1, .primary = firstSortByte(payload), .text = payload };
    }
    if (stripModifier(key, "Shift")) |payload| {
        return .{ .layer = 2, .primary = firstSortByte(payload), .text = payload };
    }
    if (isNamedKey(key)) {
        return .{ .layer = 3, .primary = firstSortByte(key), .text = key };
    }
    if (key.len == 1 and std.ascii.isUpper(key[0])) {
        return .{ .layer = 2, .primary = std.ascii.toLower(key[0]), .text = key };
    }
    return .{ .layer = 0, .primary = firstSortByte(key), .text = key };
}

fn stripModifier(key: []const u8, modifier: []const u8) ?[]const u8 {
    if (key.len <= modifier.len + 1) return null;
    if (!std.ascii.eqlIgnoreCase(key[0..modifier.len], modifier)) return null;
    const sep = key[modifier.len];
    if (sep != '+' and sep != '-') return null;
    return key[modifier.len + 1 ..];
}

fn isNamedKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "Enter") or
        std.mem.eql(u8, key, "Tab") or
        std.mem.eql(u8, key, "Esc") or
        std.mem.eql(u8, key, "Backspace") or
        std.mem.eql(u8, key, "Delete") or
        std.mem.eql(u8, key, "Space") or
        std.mem.eql(u8, key, "Up") or
        std.mem.eql(u8, key, "Down") or
        std.mem.eql(u8, key, "Left") or
        std.mem.eql(u8, key, "Right");
}

fn firstSortByte(key: []const u8) u8 {
    if (key.len == 0) return 0;
    return std.ascii.toLower(key[0]);
}

fn asciiLessThan(a: []const u8, b: []const u8) bool {
    const len = @min(a.len, b.len);
    for (0..len) |i| {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return ca < cb;
    }
    return a.len < b.len;
}

test "shortcut sort orders plain ctrl shift and named layers" {
    const input = [_]Shortcut{
        .{ .key = "Esc", .label = "" },
        .{ .key = "Ctrl+r", .label = "" },
        .{ .key = "?", .label = "" },
        .{ .key = "D", .label = "" },
        .{ .key = "a", .label = "" },
        .{ .key = "Shift+b", .label = "" },
        .{ .key = "Enter", .label = "" },
        .{ .key = "1", .label = "" },
    };
    const sorted = try sortedCopy(std.testing.allocator, &input);
    defer std.testing.allocator.free(sorted);

    try std.testing.expectEqualStrings("1", sorted[0].key);
    try std.testing.expectEqualStrings("?", sorted[1].key);
    try std.testing.expectEqualStrings("a", sorted[2].key);
    try std.testing.expectEqualStrings("Ctrl+r", sorted[3].key);
    try std.testing.expectEqualStrings("Shift+b", sorted[4].key);
    try std.testing.expectEqualStrings("D", sorted[5].key);
    try std.testing.expectEqualStrings("Enter", sorted[6].key);
    try std.testing.expectEqualStrings("Esc", sorted[7].key);
}

fn labelStyle() vaxis.Style {
    return theme.fg(theme.TEXT);
}

test "itemWidth includes key padding label and trailing gap" {
    try std.testing.expectEqual(@as(u16, 12), itemWidth(3, 4));
}

test "itemWidth handles key-only shortcuts" {
    try std.testing.expectEqual(@as(u16, 7), itemWidth(3, 0));
}

test "itemWidth ignores empty keys" {
    try std.testing.expectEqual(@as(u16, 0), itemWidth(0, 4));
}
