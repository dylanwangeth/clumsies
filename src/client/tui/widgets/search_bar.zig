const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");
const text_input = @import("text_input.zig");

pub const SearchBar = struct {
    buf: []u8,
    len: *usize,
    active: bool,
    placeholder: []const u8 = "Search",

    pub fn handleKey(self: *SearchBar, key: vaxis.Key) text_input.TextInputResult {
        var input = text_input.TextInput{
            .buf = self.buf,
            .len = self.len,
            .bg = theme.PANEL,
        };
        return input.handleKey(key);
    }

    pub fn drawRight(
        self: *const SearchBar,
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        row: u16,
        min_col: u16,
        preferred_width: u16,
    ) void {
        if (row == 0 or row + 1 >= surface.size.height or surface.size.width <= min_col + 8) return;

        const max_width = surface.size.width - min_col - 1;
        const width = @min(preferred_width, max_width);
        if (width < 12) return;

        const col = surface.size.width - width - 1;
        const bg = theme.PANEL;
        paintSlot(surface, col, row - 1, width, bg);
        paintSlot(surface, col, row, width, bg);
        paintSlot(surface, col, row + 1, width, bg);
        drawFrame(surface, col, row - 1, width, 3, bg, theme.ACCENT_SOFT);

        const icon = "⌕";
        const is_placeholder = self.len.* == 0 and !self.active;
        const icon_fg = if (is_placeholder) theme.DIM else theme.TEXT_SOFT;
        d.writeText(surface, ctx, col + 2, row, icon, .{ .fg = icon_fg, .bg = bg });
        const icon_width: u16 = @intCast(ctx.stringWidth(icon));
        const text_col = col + 2 + icon_width + 1;
        const text_width = width -| 5 -| icon_width;
        const text = self.buf[0..self.len.*];
        if (is_placeholder) {
            d.writeTextMax(surface, ctx, text_col, row, text_width, self.placeholder, .{
                .fg = theme.DIM,
                .bg = bg,
            });
            return;
        }

        text_input.drawValue(surface, ctx, text_col, row, text_width, text, bg, theme.TEXT, self.active);
    }
};

fn paintSlot(surface: *vxfw.Surface, col: u16, row: u16, width: u16, bg: vaxis.Color) void {
    var i: u16 = 0;
    while (i < width and col + i < surface.size.width and row < surface.size.height) : (i += 1) {
        surface.writeCell(col + i, row, theme.blank(bg));
    }
}

fn drawFrame(
    surface: *vxfw.Surface,
    col: u16,
    row: u16,
    width: u16,
    height: u16,
    bg: vaxis.Color,
    fg: vaxis.Color,
) void {
    if (width < 2 or height < 2) return;
    const right = col + width - 1;
    const bottom = row + height - 1;
    if (right >= surface.size.width or bottom >= surface.size.height) return;

    const style = vaxis.Style{ .fg = fg, .bg = bg, .bold = true };
    surface.writeCell(col, row, .{ .char = .{ .grapheme = "╭", .width = 1 }, .style = style });
    surface.writeCell(right, row, .{ .char = .{ .grapheme = "╮", .width = 1 }, .style = style });
    surface.writeCell(col, bottom, .{ .char = .{ .grapheme = "╰", .width = 1 }, .style = style });
    surface.writeCell(right, bottom, .{ .char = .{ .grapheme = "╯", .width = 1 }, .style = style });

    var x = col + 1;
    while (x < right) : (x += 1) {
        surface.writeCell(x, row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
        surface.writeCell(x, bottom, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
    }

    var y = row + 1;
    while (y < bottom) : (y += 1) {
        surface.writeCell(col, y, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style });
        surface.writeCell(right, y, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style });
    }
}

test "SearchBar handleKey updates buffer" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var search = SearchBar{ .buf = &buf, .len = &len, .active = true };

    try std.testing.expectEqual(text_input.TextInputResult.consumed, search.handleKey(.{ .codepoint = 'x' }));
    try std.testing.expectEqualStrings("x", buf[0..len]);
}
