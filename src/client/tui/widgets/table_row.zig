const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");

// A table row widget that distributes columns across the available width.
// Uses ctx.min.width (set by ScrollView from the parent Panel's inner width)
// as the total row width, solving the flex layout problem inside ScrollView
// where ctx.max.width is null.
//
// Column model inspired by CSS grid-template-columns:
//   flex = 0  -> column uses its content width (like `auto`)
//   flex = N  -> column gets N shares of remaining space (like `Nfr`)
//
// Unlike vxfw.FlexRow, this widget reads min.width instead of max.width,
// making it safe to use as a ScrollView child.
pub const Column = struct {
    text: []const u8,
    flex: u16 = 0,
    min_width: u16 = 0,
    alignment: enum { left, right } = .left,
    style: ?vaxis.Style = null,
    gap_after: ?u16 = null,
};

pub const TableRow = struct {
    columns: []const Column,
    style: vaxis.Style = .{},
    gap: u16 = 1,
    padding_left: u16 = 1,

    pub fn widget(self: *const TableRow) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const TableRow = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const TableRow, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        // Use min.width as the row width. ScrollView sets this to the
        // Panel's inner width. If min.width is 0, fall back to a
        // reasonable default.
        const total_width: u16 = if (ctx.min.width > 0) ctx.min.width else if (ctx.max.width) |w| w else 80;

        // First pass: measure fixed columns and count flex units
        var fixed_total: u16 = 0;
        var total_flex: u16 = 0;
        for (self.columns, 0..) |col, i| {
            if (col.flex == 0) {
                const text_w: u16 = @intCast(@min(ctx.stringWidth(col.text), total_width));
                fixed_total += @max(text_w, col.min_width);
            }
            total_flex += col.flex;
            if (i < self.columns.len - 1) fixed_total += col.gap_after orelse self.gap;
        }

        const content_width = total_width -| self.padding_left;
        const remaining = content_width -| fixed_total;

        // Second pass: render each column at its computed position
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = total_width,
            .height = 1,
        });
        const bg_color: vaxis.Color = switch (self.style.bg) {
            .default => theme.PANEL,
            else => self.style.bg,
        };
        @memset(surface.buffer, theme.blank(bg_color));

        var col_x: u16 = self.padding_left;
        for (self.columns, 0..) |col, i| {
            const col_width: u16 = if (col.flex == 0) blk: {
                const text_w: u16 = @intCast(@min(ctx.stringWidth(col.text), total_width));
                break :blk @max(text_w, col.min_width);
            } else if (i == self.columns.len - 1)
                total_width -| col_x
            else if (total_flex > 0) (remaining * col.flex) / total_flex else 0;

            // Write text into this column region
            const text_width: u16 = @intCast(@min(ctx.stringWidth(col.text), col_width));
            const start_x: u16 = switch (col.alignment) {
                .left => col_x,
                .right => col_x + col_width -| text_width,
            };

            var cursor = start_x;
            var iter = ctx.graphemeIterator(col.text);
            while (iter.next()) |grapheme| {
                if (cursor >= col_x + col_width) break;
                const bytes = grapheme.bytes(col.text);
                const gwidth: u16 = @intCast(ctx.stringWidth(bytes));
                if (gwidth == 0 or cursor + gwidth > col_x + col_width) break;
                surface.writeCell(cursor, 0, .{
                    .char = .{ .grapheme = bytes, .width = @intCast(gwidth) },
                    .style = col.style orelse self.style,
                });
                cursor += gwidth;
            }

            col_x += col_width + if (i < self.columns.len - 1) col.gap_after orelse self.gap else 0;
        }

        return surface;
    }
};
