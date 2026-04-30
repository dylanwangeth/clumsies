const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

pub const Drawer = struct {
    title: []const u8,
    border_color: vaxis.Color = theme.ACCENT_SOFT,
    background: vaxis.Color = theme.PANEL_SOFT,
    body: vxfw.Surface,

    pub fn draw(self: *const Drawer, ctx: vxfw.DrawContext, owner: vxfw.Widget) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, owner, size);
        d.fillSurface(&surface, self.background);

        var row: u16 = 0;
        while (row < size.height) : (row += 1) {
            surface.writeCell(0, row, .{
                .char = .{ .grapheme = "▌", .width = 1 },
                .style = .{ .fg = self.border_color, .bg = self.background },
            });
            surface.writeCell(1, row, .{
                .char = .{ .grapheme = "┊", .width = 1 },
                .style = .{ .fg = theme.BORDER_MUTED, .bg = self.background },
            });
            surface.writeCell(2, row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .fg = theme.TEXT, .bg = self.background },
            });
        }

        d.writeText(&surface, ctx, 4, 1, "╴", theme.textOn(self.background, self.border_color));
        d.writeText(&surface, ctx, 6, 1, self.title, theme.boldOn(self.background, theme.TEXT));
        d.writeRightText(&surface, ctx, 1, "Esc", theme.textOn(self.background, theme.TEXT_SOFT));

        var col: u16 = 4;
        const divider_row: u16 = 2;
        while (col < size.width -| 1) : (col += 1) {
            surface.writeCell(col, divider_row, .{
                .char = .{ .grapheme = "╌", .width = 1 },
                .style = .{ .fg = theme.BORDER_MUTED, .bg = self.background },
            });
        }

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 4, .col = 4 }, .surface = self.body };
        surface.children = children;
        return surface;
    }
};
