const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

// Initialize ScrollBars for selectable lists. draw_cursor is set to true
// so that j/k keys trigger nextItem/prevItem (cursor movement) rather
// than bare viewport scrolling. However, draw_cursor=true also activates
// a buggy rendering path in libvaxis 0.5.1 that clips the selected row
// to zero width (see applyCursorOverlay for the full explanation).
//
// The rendering workaround: each draw*() call-site temporarily sets
// draw_cursor=false via defer before Panel.draw(), then calls
// applyCursorOverlay() to paint the indicator as a z_index=1 overlay.
// This decouples event handling (needs draw_cursor=true) from rendering
// (needs draw_cursor=false to avoid the bug).
//
// Upstream fix: https://github.com/rockorager/libvaxis/pull/256
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

// Render a cursor indicator on a Panel surface at the ScrollView's
// selected row. This is our workaround for a libvaxis rendering bug.
//
// The problem: ScrollView.draw_cursor wraps the selected row in a
// cursor_surf with width=2, then places the text child at col=2 inside
// it. During compositing, Window.initChild clamps the text window to
// max_width = parent_width(2) - x_off(2) = 0. The text is invisible.
// Only the indicator at col=0 of cursor_surf survives.
//
// The fix PR has been open since 2025-10-13 with no review:
// https://github.com/rockorager/libvaxis/pull/256
//
// Our workaround: keep draw_cursor=false so ScrollView never creates
// the buggy cursor_surf. Instead, after Panel.draw() produces the
// final surface (with ScrollBars content as z_index=0 children), we
// append a 1x1 surface at z_index=1. vxfw's Surface.render sorts
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
// and delete the applyCursorOverlay calls in shell.zig.
//
// Constraints: Panel must have a 1-cell border (content starts at
// col=1, row=1). Each ScrollView child must be exactly 1 row tall
// (softwrap=false single-line Text).
pub fn applyCursorOverlay(
    ctx: vxfw.DrawContext,
    surface: *vxfw.Surface,
    scroll_view: *const vxfw.ScrollView,
    bg: vaxis.Color,
) std.mem.Allocator.Error!vxfw.Surface {
    const cursor_pos = scroll_view.cursor;
    const scroll_top = scroll_view.scroll.top;
    if (cursor_pos < scroll_top) return surface.*;

    const visible_row = cursor_pos - scroll_top;
    const target_u16: u16 = @intCast(1 + visible_row);

    if (target_u16 >= surface.size.height -| 1) return surface.*;

    const cursor_buf = try ctx.arena.alloc(vaxis.Cell, 1);
    cursor_buf[0] = .{
        .char = .{ .grapheme = "▌", .width = 1 },
        .style = .{ .fg = theme.ACCENT_SOFT, .bg = bg },
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
        .origin = .{ .col = 1, .row = @as(i17, @intCast(target_u16)) },
        .surface = cursor_surface,
        .z_index = 1,
    };
    surface.children = new_children;

    return surface.*;
}

/// Move cursor down by one. Returns true if the event was consumed.
pub fn cursorDown(cursor: *usize, count: usize, ctx: *vxfw.EventContext) bool {
    if (count > 0 and cursor.* + 1 < count) {
        cursor.* += 1;
        ctx.consumeAndRedraw();
        return true;
    }
    return false;
}

/// Move cursor up by one. Returns true if the event was consumed.
pub fn cursorUp(cursor: *usize, ctx: *vxfw.EventContext) bool {
    if (cursor.* > 0) {
        cursor.* -= 1;
        ctx.consumeAndRedraw();
        return true;
    }
    return false;
}

/// Handle j/Down and k/Up keys for list cursor navigation.
/// Returns true if the event was consumed.
pub fn handleCursorKeys(key: vaxis.Key, cursor: *usize, count: usize, ctx: *vxfw.EventContext) bool {
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{}))
        return cursorDown(cursor, count, ctx);
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{}))
        return cursorUp(cursor, ctx);
    return false;
}

/// Handle h/j/k/l + arrow keys for 2D grid cursor navigation.
/// Returns true if the event was consumed.
pub fn handleGridKeys(key: vaxis.Key, cursor: *usize, count: usize, cols: u16, ctx: *vxfw.EventContext) bool {
    if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        if (cursor.* + 1 < count) {
            cursor.* += 1;
            ctx.consumeAndRedraw();
            return true;
        }
        return false;
    }
    if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        if (cursor.* > 0) {
            cursor.* -= 1;
            ctx.consumeAndRedraw();
            return true;
        }
        return false;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (cursor.* + cols < count) {
            cursor.* += cols;
            ctx.consumeAndRedraw();
            return true;
        }
        return false;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (cursor.* >= cols) {
            cursor.* -= cols;
            ctx.consumeAndRedraw();
            return true;
        }
        return false;
    }
    return false;
}

test "writeCursorMarker does not crash on out-of-bounds" {
    const alloc = std.testing.allocator;
    var surface = try vxfw.Surface.init(alloc, undefined, .{ .width = 2, .height = 2 });
    defer alloc.free(surface.buffer);
    // In-bounds: should write without panic
    d.writeCursorMarker(&surface, 0, 0);
    // Out-of-bounds: should be a no-op
    d.writeCursorMarker(&surface, 5, 5);
}
