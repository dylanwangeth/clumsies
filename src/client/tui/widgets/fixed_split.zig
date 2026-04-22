const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

/// Create a horizontal two-column layout. Left column is `left_width` cells;
/// right column fills the rest, separated by a 1-cell gap.
pub fn splitHorizontal(
    ctx: vxfw.DrawContext,
    owner: vxfw.Widget,
    bg: vaxis.Color,
    left: vxfw.Surface,
    right: vxfw.Surface,
    left_width: u16,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, owner, size);
    d.fillSurface(&root, bg);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = left };
    children[1] = .{ .origin = .{ .row = 0, .col = @as(i17, @intCast(left_width)) + 1 }, .surface = right };
    root.children = children;
    return root;
}

pub const FixedSplit = struct {
    primary: vxfw.Widget,
    secondary: vxfw.Widget,
    split_at: u16,
    direction: enum { horizontal, vertical },
    background: vaxis.Color,

    pub fn widget(self: *const FixedSplit) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = fixedSplitTypeErasedDrawFn,
        };
    }

    fn fixedSplitTypeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const FixedSplit = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        d.fillSurface(&root, self.background);

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        switch (self.direction) {
            .horizontal => {
                const left_ctx = ctx.withConstraints(
                    .{ .width = 0, .height = 0 },
                    .{ .width = self.split_at, .height = size.height },
                );
                const right_col: i17 = @as(i17, @intCast(self.split_at)) + 1;
                const right_w = size.width -| @as(u16, @intCast(right_col));
                const right_ctx = ctx.withConstraints(
                    .{ .width = 0, .height = 0 },
                    .{ .width = right_w, .height = size.height },
                );
                children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.primary.draw(left_ctx) };
                children[1] = .{ .origin = .{ .row = 0, .col = right_col }, .surface = try self.secondary.draw(right_ctx) };
            },
            .vertical => {
                const top_ctx = ctx.withConstraints(
                    .{ .width = 0, .height = 0 },
                    .{ .width = size.width, .height = self.split_at },
                );
                const bot_row: i17 = @as(i17, @intCast(self.split_at)) + 1;
                const bot_h = size.height -| @as(u16, @intCast(bot_row));
                const bot_ctx = ctx.withConstraints(
                    .{ .width = 0, .height = 0 },
                    .{ .width = size.width, .height = bot_h },
                );
                children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.primary.draw(top_ctx) };
                children[1] = .{ .origin = .{ .row = bot_row, .col = 0 }, .surface = try self.secondary.draw(bot_ctx) };
            },
        }
        root.children = children;
        return root;
    }
};
