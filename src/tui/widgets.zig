const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("theme.zig");

// Fill entire surface buffer with a background color.
pub fn fillSurface(surface: *vxfw.Surface, bg: vaxis.Color) void {
    @memset(surface.buffer, theme.blank(bg));
}

// Paint a full-width band on a single row with a background color.
pub fn paintBand(surface: *vxfw.Surface, row: u16, bg: vaxis.Color, fg: vaxis.Color) void {
    for (0..surface.size.width) |col| {
        surface.writeCell(@intCast(col), row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .fg = fg, .bg = bg },
        });
    }
}

// Draw a rounded border (╭╮╰╯─│) around the entire surface.
pub fn drawBorder(surface: *vxfw.Surface, fg: vaxis.Color, bg: vaxis.Color) void {
    const right = surface.size.width -| 1;
    const bottom = surface.size.height -| 1;
    const s = vaxis.Style{ .fg = fg, .bg = bg };

    surface.writeCell(0, 0, .{ .char = .{ .grapheme = "╭", .width = 1 }, .style = s });
    surface.writeCell(right, 0, .{ .char = .{ .grapheme = "╮", .width = 1 }, .style = s });
    surface.writeCell(right, bottom, .{ .char = .{ .grapheme = "╯", .width = 1 }, .style = s });
    surface.writeCell(0, bottom, .{ .char = .{ .grapheme = "╰", .width = 1 }, .style = s });

    var col: u16 = 1;
    while (col < right) : (col += 1) {
        surface.writeCell(col, 0, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = s });
        surface.writeCell(col, bottom, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = s });
    }
    var row: u16 = 1;
    while (row < bottom) : (row += 1) {
        surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = s });
        surface.writeCell(right, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = s });
    }
}

// Write text at (col, row) using grapheme-aware width.
pub fn writeText(surface: *vxfw.Surface, ctx: vxfw.DrawContext, col: u16, row: u16, text: []const u8, s: vaxis.Style) void {
    var cursor = col;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (cursor >= surface.size.width or row >= surface.size.height) break;
        const bytes = grapheme.bytes(text);
        if (std.mem.eql(u8, bytes, "\n")) break;
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        if (width == 0 or cursor + width > surface.size.width) break;
        surface.writeCell(cursor, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = s,
        });
        cursor += width;
    }
}

// Write text right-aligned on a given row.
pub fn writeRightText(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, text: []const u8, s: vaxis.Style) void {
    const width: u16 = @intCast(ctx.stringWidth(text));
    if (width >= surface.size.width) return;
    writeText(surface, ctx, surface.size.width - width - 1, row, text, s);
}

// Draw a filled badge (pill) with background. Returns the column after the badge.
pub fn drawFilledBadge(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, col: u16, text: []const u8, fg: vaxis.Color, bg: vaxis.Color) u16 {
    const width = @as(u16, @intCast(ctx.stringWidth(text))) + 2;
    for (0..width) |offset| {
        if (col + offset >= surface.size.width) break;
        surface.writeCell(@intCast(col + offset), row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .fg = fg, .bg = bg },
        });
    }
    writeText(surface, ctx, col + 1, row, text, .{ .fg = fg, .bg = bg, .bold = true });
    return col + width;
}

// Draw a tab-style badge: selected = gold bg, unselected = panel_alt bg.
pub fn drawTabBadge(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, col: u16, text: []const u8, selected: bool) u16 {
    return drawFilledBadge(
        surface,
        ctx,
        row,
        col,
        text,
        if (selected) theme.CANVAS else theme.TEXT_SOFT,
        if (selected) theme.MINT else theme.PANEL_ALT,
    );
}

// Draw an inner tab badge (smaller emphasis): selected = gold, unselected = panel_alt.
pub fn drawInnerTabBadge(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, col: u16, text: []const u8, selected: bool) u16 {
    return drawFilledBadge(
        surface,
        ctx,
        row,
        col,
        text,
        if (selected) theme.CANVAS else theme.TEXT_SOFT,
        if (selected) theme.GOLD else theme.PANEL_ALT,
    );
}

// Build a sparkline string from raw values (0-based, max determines scale).
pub fn sparkline(allocator: std.mem.Allocator, values: []const u8) ![]const u8 {
    var max: u8 = 1;
    for (values) |v| {
        if (v > max) max = v;
    }
    var list: std.ArrayList(u8) = .empty;
    for (values, 0..) |v, idx| {
        if (idx > 0) try list.append(allocator, ' ');
        const normalized: usize = @min(@as(usize, v) * theme.SPARKLINE.len / (@as(usize, max) + 1), theme.SPARKLINE.len - 1);
        try list.appendSlice(allocator, theme.SPARKLINE[normalized]);
    }
    return try list.toOwnedSlice(allocator);
}

// Initialize ScrollBars for selectable lists. draw_cursor is set to true
// so that j/k keys trigger nextItem/prevItem (cursor movement) rather
// than bare viewport scrolling. However, draw_cursor=true also activates
// a buggy rendering path in libvaxis 0.5.1 that clips the selected row
// to zero width (see applyCursorOverlay for the full explanation).
//
// The rendering workaround: each draw*() call-site temporarily sets
// draw_cursor=false via defer before Panel.draw(), then calls
// applyCursorOverlay() to paint the ▌ indicator as a z_index=1 overlay.
// This decouples event handling (needs draw_cursor=true) from rendering
// (needs draw_cursor=false to avoid the bug).
//
// Upstream fix: https://github.com/rockorager/libvaxis/pull/256
// See .prompts/context/issues/001_scrollview_cursor_clipping.md
pub fn initCursorScrollBars(background: vaxis.Color) vxfw.ScrollBars {
    return .{
        .scroll_view = .{
            .children = .{ .slice = &.{} },
            .wheel_scroll = 1,
            .draw_cursor = true,
        },
        .draw_horizontal_scrollbar = false,
        .vertical_scrollbar_thumb = .{
            .char = .{ .grapheme = "▐", .width = 1 },
            .style = .{ .fg = theme.BORDER, .bg = background },
        },
        .vertical_scrollbar_hover_thumb = .{
            .char = .{ .grapheme = "█", .width = 1 },
            .style = .{ .fg = theme.GOLD, .bg = background },
        },
        .vertical_scrollbar_drag_thumb = .{
            .char = .{ .grapheme = "█", .width = 1 },
            .style = .{ .fg = theme.ACCENT, .bg = background },
        },
    };
}

// Initialize ScrollBars without cursor (for content scrolling).
pub fn initPlainScrollBars(background: vaxis.Color, wheel_scroll: u8) vxfw.ScrollBars {
    return .{
        .scroll_view = .{
            .children = .{ .slice = &.{} },
            .wheel_scroll = wheel_scroll,
        },
        .draw_horizontal_scrollbar = false,
        .vertical_scrollbar_thumb = .{
            .char = .{ .grapheme = "▐", .width = 1 },
            .style = .{ .fg = theme.BORDER, .bg = background },
        },
        .vertical_scrollbar_hover_thumb = .{
            .char = .{ .grapheme = "█", .width = 1 },
            .style = .{ .fg = theme.GOLD, .bg = background },
        },
        .vertical_scrollbar_drag_thumb = .{
            .char = .{ .grapheme = "█", .width = 1 },
            .style = .{ .fg = theme.ACCENT, .bg = background },
        },
    };
}

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
    owner: vxfw.Widget,
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

    pub fn draw(self: *const Panel, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.owner, size);
        fillSurface(&surface, self.background);
        drawBorder(&surface, self.border_color, self.background);

        // Title takes priority. Subtitle only renders if enough space
        // remains after title + 2 cell gap. Prevents overlap on narrow panels.
        const title_w: u16 = @intCast(ctx.stringWidth(self.title));
        writeText(&surface, ctx, 2, 0, self.title, theme.boldOn(self.background, theme.TEXT));
        if (self.subtitle.len > 0) {
            const sub_w: u16 = @intCast(ctx.stringWidth(self.subtitle));
            const title_end = 2 + title_w + 2;
            const sub_start = size.width -| sub_w -| 1;
            if (sub_start > title_end) {
                writeRightText(&surface, ctx, 0, self.subtitle, theme.textOn(self.background, theme.MUTED));
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

// Render a ▌ cursor indicator on a Panel surface at the ScrollView's
// selected row. This is our workaround for a libvaxis rendering bug.
//
// The problem: ScrollView.draw_cursor wraps the selected row in a
// cursor_surf with width=2, then places the text child at col=2 inside
// it. During compositing, Window.initChild clamps the text window to
// max_width = parent_width(2) - x_off(2) = 0. The text is invisible.
// Only the ▌ at col=0 of cursor_surf survives.
//
// The fix PR has been open since 2025-10-13 with no review:
// https://github.com/rockorager/libvaxis/pull/256
//
// Our workaround: keep draw_cursor=false so ScrollView never creates
// the buggy cursor_surf. Instead, after Panel.draw() produces the
// final surface (with ScrollBars content as z_index=0 children), we
// append a 1×1 ▌ surface at z_index=1. vxfw's Surface.render sorts
// children by z_index before drawing, so our overlay paints on top of
// the list content at the exact row of the selected item.
//
// This approach does not touch ScrollView internals. It reads two
// public fields (scroll_view.cursor for the selected index and
// scroll_view.scroll.top for the viewport offset) to compute the
// visible row, then composites via the standard SubSurface z_index
// mechanism.
//
// TODO: Remove this workaround when libvaxis merges PR #256 and we
// update the dependency. Re-enable draw_cursor in initCursorScrollBars
// and delete the applyCursorOverlay calls in app.zig.
//
// Constraints: Panel must have a 1-cell border (content starts at
// col=1, row=1). Each ScrollView child must be exactly 1 row tall
// (softwrap=false single-line Text).
pub fn applyCursorOverlay(
    ctx: vxfw.DrawContext,
    surface: *vxfw.Surface,
    scroll_view: *const vxfw.ScrollView,
) std.mem.Allocator.Error!vxfw.Surface {
    const cursor_pos = scroll_view.cursor;
    const scroll_top = scroll_view.scroll.top;
    if (cursor_pos < scroll_top) return surface.*;

    const visible_row = cursor_pos - scroll_top;
    const target_row: i17 = @intCast(1 + visible_row);

    if (target_row >= surface.size.height -| 1) return surface.*;

    const cursor_buf = try ctx.arena.alloc(vaxis.Cell, 1);
    cursor_buf[0] = .{
        .char = .{ .grapheme = "▌", .width = 1 },
        .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
    };
    const cursor_surface: vxfw.Surface = .{
        .size = .{ .width = 1, .height = 1 },
        .widget = surface.widget,
        .buffer = cursor_buf,
        .children = &.{},
    };

    const old_children = surface.children;
    const new_children = try ctx.arena.alloc(vxfw.SubSurface, old_children.len + 1);
    @memcpy(new_children[0..old_children.len], old_children);
    new_children[old_children.len] = .{
        .origin = .{ .col = 1, .row = target_row },
        .surface = cursor_surface,
        .z_index = 1,
    };
    surface.children = new_children;

    return surface.*;
}

pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    return 1 + std.mem.count(u8, text, "\n");
}
