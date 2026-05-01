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
