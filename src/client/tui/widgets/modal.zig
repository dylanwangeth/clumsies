const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

pub const Anchor = enum { center, bottom_right };

pub const Modal = struct {
    title: []const u8,
    box_width: u16,
    box_height: u16,
    border_color: vaxis.Color = theme.ACCENT,
    footer: []const u8 = "",
    anchor: Anchor = .center,

    pub const DrawResult = struct {
        surface: vxfw.Surface,
        content_col: u16,
        content_row: u16,
    };

    pub fn draw(self: *const Modal, ctx: vxfw.DrawContext, owner: vxfw.Widget) std.mem.Allocator.Error!DrawResult {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, owner, size);
        d.fillSurface(&surface, theme.PANEL);

        const start_col: u16 = switch (self.anchor) {
            .center => (size.width -| self.box_width) / 2,
            .bottom_right => size.width -| self.box_width -| 2,
        };
        const start_row: u16 = switch (self.anchor) {
            .center => (size.height -| self.box_height) / 2,
            .bottom_right => size.height -| self.box_height -| 1,
        };

        var row: u16 = 0;
        while (row < self.box_height) : (row += 1) {
            var col: u16 = 0;
            while (col < self.box_width) : (col += 1) {
                surface.writeCell(start_col + col, start_row + row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .fg = theme.TEXT, .bg = theme.PANEL_ALT },
                });
            }
        }

        const s = vaxis.Style{ .fg = self.border_color, .bg = theme.PANEL_ALT };
        surface.writeCell(start_col, start_row, .{ .char = .{ .grapheme = "\xe2\x95\xad", .width = 1 }, .style = s });
        surface.writeCell(start_col + self.box_width - 1, start_row, .{ .char = .{ .grapheme = "\xe2\x95\xae", .width = 1 }, .style = s });
        surface.writeCell(start_col, start_row + self.box_height - 1, .{ .char = .{ .grapheme = "\xe2\x95\xb0", .width = 1 }, .style = s });
        surface.writeCell(start_col + self.box_width - 1, start_row + self.box_height - 1, .{ .char = .{ .grapheme = "\xe2\x95\xaf", .width = 1 }, .style = s });
        var c: u16 = 1;
        while (c < self.box_width - 1) : (c += 1) {
            surface.writeCell(start_col + c, start_row, .{ .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, .style = s });
            surface.writeCell(start_col + c, start_row + self.box_height - 1, .{ .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, .style = s });
        }
        var r: u16 = 1;
        while (r < self.box_height - 1) : (r += 1) {
            surface.writeCell(start_col, start_row + r, .{ .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, .style = s });
            surface.writeCell(start_col + self.box_width - 1, start_row + r, .{ .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, .style = s });
        }

        const title_text = try std.fmt.allocPrint(ctx.arena, " {s} ", .{self.title});
        d.writeText(&surface, ctx, start_col + 2, start_row, title_text, theme.boldOn(theme.PANEL_ALT, self.border_color));

        if (self.footer.len > 0) {
            d.writeText(&surface, ctx, start_col + 2, start_row + self.box_height - 1, self.footer, theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT));
        }

        return .{
            .surface = surface,
            .content_col = start_col + 2,
            .content_row = start_row + 2,
        };
    }
};
