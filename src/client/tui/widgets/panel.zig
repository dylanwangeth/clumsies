const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

// Wraps an already-rendered Surface into a Widget for passing to containers.
pub const SurfaceWidget = struct {
    surface: vxfw.Surface,
    widget_ref: vxfw.Widget,

    pub fn widget(self: *const SurfaceWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const SurfaceWidget = @ptrCast(@alignCast(ptr));
        var surface = self.surface;
        surface.widget = self.widget_ref;
        return surface;
    }
};

// Wraps a widget reference with stable identity for containers that need it.
pub const WidgetBox = struct {
    widget_ref: vxfw.Widget,

    pub fn widget(self: *const WidgetBox) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const WidgetBox = @ptrCast(@alignCast(ptr));
        var surface = try self.widget_ref.draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
};

// Reusable bordered panel with title, subtitle, padding, and child widget.
pub const Panel = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    background: vaxis.Color,
    border_color: vaxis.Color,
    child: vxfw.Widget,
    padding: Padding = .{},

    pub const Padding = struct {
        left: u16 = 0,
        right: u16 = 0,
        top: u16 = 0,
        bottom: u16 = 0,
    };

    pub fn widget(self: *const Panel) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const Panel = @ptrCast(@alignCast(ptr));
        return draw(self, ctx);
    }

    fn draw(self: *const Panel, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        d.fillSurface(&surface, self.background);
        d.drawBorder(&surface, self.border_color, self.background);

        // Title takes priority. Subtitle only renders if enough space
        // remains after title + 2 cell gap. Prevents overlap on narrow panels.
        const title_w: u16 = @intCast(ctx.stringWidth(self.title));
        d.writeText(&surface, ctx, 2, 0, self.title, theme.boldOn(self.background, theme.TEXT));
        if (self.subtitle.len > 0) {
            const sub_w: u16 = @intCast(ctx.stringWidth(self.subtitle));
            const title_end = 2 + title_w + 2;
            const sub_start = size.width -| sub_w -| 1;
            if (sub_start > title_end) {
                d.writeRightText(&surface, ctx, 0, self.subtitle, theme.textOn(self.background, theme.MUTED));
            }
        }

        const inner_width = size.width -| 2 -| self.padding.left -| self.padding.right;
        const inner_height = size.height -| 2 -| self.padding.top -| self.padding.bottom;
        const child_ctx = ctx.withConstraints(
            .{ .width = inner_width, .height = inner_height },
            .{ .width = inner_width, .height = inner_height },
        );
        const child_surface = try self.child.draw(child_ctx);
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{
                .row = 1 + self.padding.top,
                .col = 1 + self.padding.left,
            },
            .surface = child_surface,
        };
        surface.children = children;
        return surface;
    }
};
