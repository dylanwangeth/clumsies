const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

pub const Anchor = enum { center, bottom_right };
pub const Backdrop = enum { canvas, none };

pub const Modal = struct {
    title: []const u8,
    box_width: u16,
    box_height: u16,
    border_color: vaxis.Color = theme.BORDER_MUTED,
    title_color: vaxis.Color = theme.ACCENT_SOFT,
    footer: []const u8 = "",
    anchor: Anchor = .center,
    backdrop: Backdrop = .canvas,

    pub const DrawResult = struct {
        surface: vxfw.Surface,
        content_col: u16,
        content_row: u16,
        content_width: u16,
    };

    pub fn draw(self: *const Modal, ctx: vxfw.DrawContext, owner: vxfw.Widget) std.mem.Allocator.Error!DrawResult {
        const full_size = ctx.max.size();
        const size: vxfw.Size = switch (self.backdrop) {
            .canvas => full_size,
            .none => .{ .width = @min(self.box_width, full_size.width), .height = @min(self.box_height, full_size.height) },
        };
        var surface = try vxfw.Surface.init(ctx.arena, owner, size);
        if (self.backdrop == .canvas) d.fillSurface(&surface, theme.CANVAS);

        const start_col: u16 = switch (self.anchor) {
            .center => if (self.backdrop == .canvas) (size.width -| self.box_width) / 2 else 0,
            .bottom_right => if (self.backdrop == .canvas) size.width -| self.box_width -| 2 else 0,
        };
        const start_row: u16 = switch (self.anchor) {
            .center => if (self.backdrop == .canvas) (size.height -| self.box_height) / 2 else 0,
            .bottom_right => if (self.backdrop == .canvas) size.height -| self.box_height -| 1 else 0,
        };
        const box_width = @min(self.box_width, size.width -| start_col);
        const box_height = @min(self.box_height, size.height -| start_row);
        if (box_width < 2 or box_height < 2) {
            return .{
                .surface = surface,
                .content_col = 0,
                .content_row = 0,
                .content_width = 0,
            };
        }

        var row: u16 = 0;
        while (row < box_height) : (row += 1) {
            var col: u16 = 0;
            while (col < box_width) : (col += 1) {
                surface.writeCell(start_col + col, start_row + row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .fg = theme.TEXT, .bg = theme.PANEL_ALT },
                });
            }
        }

        const s = vaxis.Style{ .fg = self.border_color, .bg = theme.PANEL_ALT };
        surface.writeCell(start_col, start_row, .{ .char = .{ .grapheme = "\xe2\x95\xad", .width = 1 }, .style = s });
        surface.writeCell(start_col + box_width - 1, start_row, .{ .char = .{ .grapheme = "\xe2\x95\xae", .width = 1 }, .style = s });
        surface.writeCell(start_col, start_row + box_height - 1, .{ .char = .{ .grapheme = "\xe2\x95\xb0", .width = 1 }, .style = s });
        surface.writeCell(start_col + box_width - 1, start_row + box_height - 1, .{ .char = .{ .grapheme = "\xe2\x95\xaf", .width = 1 }, .style = s });
        var c: u16 = 1;
        while (c < box_width - 1) : (c += 1) {
            surface.writeCell(start_col + c, start_row, .{ .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, .style = s });
            surface.writeCell(start_col + c, start_row + box_height - 1, .{ .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, .style = s });
        }
        var r: u16 = 1;
        while (r < box_height - 1) : (r += 1) {
            surface.writeCell(start_col, start_row + r, .{ .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, .style = s });
            surface.writeCell(start_col + box_width - 1, start_row + r, .{ .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, .style = s });
        }

        const content_col = start_col + @min(@as(u16, 4), box_width -| 2);
        const content_width = box_width -| 8;
        d.writeTextMax(&surface, ctx, content_col, start_row + 2, content_width, self.title, theme.boldOn(theme.PANEL_ALT, self.title_color));

        if (self.footer.len > 0 and box_height > 4) {
            d.writeTextMax(&surface, ctx, content_col, start_row + box_height - 3, content_width, self.footer, theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT));
        }

        return .{
            .surface = surface,
            .content_col = content_col,
            .content_row = start_row + 4,
            .content_width = content_width,
        };
    }
};
