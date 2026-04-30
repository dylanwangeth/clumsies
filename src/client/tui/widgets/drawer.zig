const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

pub const Drawer = struct {
    pub const child_origin_row: u16 = 4;
    pub const child_origin_col: u16 = 4;
    pub const min_child_width: u16 = child_origin_col + 1;
    pub const min_child_height: u16 = child_origin_row + 1;

    title: []const u8,
    border_color: vaxis.Color = theme.ACCENT_SOFT,
    background: vaxis.Color = theme.PANEL_SOFT,
    body: vxfw.Surface,

    pub fn draw(self: *const Drawer, ctx: vxfw.DrawContext, owner: vxfw.Widget) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, owner, size);
        d.fillSurface(&surface, self.background);
        if (size.width == 0 or size.height == 0) return surface;

        var row: u16 = 0;
        while (row < size.height) : (row += 1) {
            surface.writeCell(0, row, .{
                .char = .{ .grapheme = "▌", .width = 1 },
                .style = .{ .fg = self.border_color, .bg = self.background },
            });
            if (size.width > 1) {
                surface.writeCell(1, row, .{
                    .char = .{ .grapheme = "┊", .width = 1 },
                    .style = .{ .fg = theme.BORDER_MUTED, .bg = self.background },
                });
            }
            if (size.width > 2) {
                surface.writeCell(2, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .fg = theme.TEXT, .bg = self.background },
                });
            }
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

        if (size.width < min_child_width or size.height < min_child_height) return surface;
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = child_origin_row, .col = child_origin_col }, .surface = self.body };
        surface.children = children;
        return surface;
    }
};
