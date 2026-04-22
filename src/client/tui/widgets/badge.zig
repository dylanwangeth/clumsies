const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

// Draw a filled badge (pill) with background. Returns the column after the badge.
pub const Badge = struct {
    text: []const u8,
    fg: vaxis.Color,
    bg: vaxis.Color,
    bold: bool = true,

    pub fn widget(self: *const Badge) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = badgeTypeErasedDrawFn,
        };
    }

    /// Width in cells: text + 1 cell padding on each side.
    pub fn width(self: *const Badge, ctx: vxfw.DrawContext) u16 {
        return @as(u16, @intCast(ctx.stringWidth(self.text))) + 2;
    }

    fn badgeTypeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const Badge = @ptrCast(@alignCast(ptr));
        const text_w: u16 = @intCast(ctx.stringWidth(self.text));
        const badge_w = text_w + 2;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = badge_w, .height = 1 });
        const style: vaxis.Style = .{ .fg = self.fg, .bg = self.bg, .bold = self.bold };
        for (0..badge_w) |c| {
            surface.writeCell(@intCast(c), 0, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = style,
            });
        }
        d.writeText(&surface, ctx, 1, 0, self.text, style);
        return surface;
    }
};

pub fn badgeTopLevel(text: []const u8, selected: bool) Badge {
    return .{
        .text = text,
        .fg = if (selected) theme.PANEL else theme.TEXT_SOFT,
        .bg = if (selected) theme.MINT else theme.PANEL_ALT,
    };
}

pub fn badgeInnerTab(text: []const u8, selected: bool) Badge {
    return .{
        .text = text,
        .fg = if (selected) theme.PANEL else theme.TEXT_SOFT,
        .bg = if (selected) theme.GOLD else theme.PANEL_ALT,
    };
}

/// Draw a filled badge directly onto a surface. Returns the column after the badge.
pub fn drawFilledBadge(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, col: u16, text: []const u8, fg: vaxis.Color, bg: vaxis.Color) u16 {
    const width = @as(u16, @intCast(ctx.stringWidth(text))) + 2;
    for (0..width) |offset| {
        if (col + offset >= surface.size.width) break;
        surface.writeCell(@intCast(col + offset), row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .fg = fg, .bg = bg },
        });
    }
    d.writeText(surface, ctx, col + 1, row, text, .{ .fg = fg, .bg = bg, .bold = true });
    return col + width;
}

pub fn drawTabBadge(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, col: u16, text: []const u8, selected: bool) u16 {
    const b = badgeTopLevel(text, selected);
    return drawFilledBadge(surface, ctx, row, col, b.text, b.fg, b.bg);
}

pub fn drawInnerTabBadge(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, col: u16, text: []const u8, selected: bool) u16 {
    const b = badgeInnerTab(text, selected);
    return drawFilledBadge(surface, ctx, row, col, b.text, b.fg, b.bg);
}

test "badgeTopLevel uses MINT bg when selected" {
    const sel = badgeTopLevel("test", true);
    try std.testing.expectEqual(theme.MINT, sel.bg);
    try std.testing.expectEqual(theme.PANEL, sel.fg);
    const unsel = badgeTopLevel("test", false);
    try std.testing.expectEqual(theme.PANEL_ALT, unsel.bg);
    try std.testing.expectEqual(theme.TEXT_SOFT, unsel.fg);
}

test "badgeInnerTab uses GOLD bg when selected" {
    const sel = badgeInnerTab("tab", true);
    try std.testing.expectEqual(theme.GOLD, sel.bg);
    const unsel = badgeInnerTab("tab", false);
    try std.testing.expectEqual(theme.PANEL_ALT, unsel.bg);
}
