const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

// Initialize ScrollBars for selectable lists. Cursor movement is handled by
// our own key handlers, so draw_cursor stays false and ScrollView only owns
// viewport scrolling and scrollbar interaction. This keeps wheel scrolling
// independent from the selected row and avoids ScrollView pulling the
// viewport back to the cursor.
pub fn initCursorScrollBars(background: vaxis.Color) vxfw.ScrollBars {
    return .{
        .scroll_view = .{
            .children = .{ .slice = &.{} },
            .wheel_scroll = 1,
            .draw_cursor = false,
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

// Render a cursor indicator on a Panel surface at the selected row.
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
// We keep draw_cursor=false so ScrollView never creates the buggy
// cursor_surf. Instead, after Panel.draw() produces the final surface
// (with ScrollBars content as z_index=0 children), we append a 1x1
// surface at z_index=1. vxfw's Surface.render sorts children by z_index
// before drawing, so our overlay paints on top of the list content at
// the exact row of the selected item.
//
// This approach does not touch ScrollView internals. It reads two
// public fields (scroll_view.cursor for the selected index and
// scroll_view.scroll.top for the viewport offset) to compute the
// visible row, then composites via the standard SubSurface z_index
// mechanism.
//
// TODO: Revisit this overlay if libvaxis merges PR #256 and we update the
// dependency. Do not re-enable ScrollView cursor handling unless its event
// model no longer couples wheel scrolling to the selected row.
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

pub fn clampScrollTop(scroll_view: *vxfw.ScrollView, row_count: usize) void {
    if (row_count == 0) {
        scroll_view.scroll.top = 0;
        scroll_view.scroll.vertical_offset = 0;
        return;
    }
    if (scroll_view.scroll.top >= row_count) {
        scroll_view.scroll.top = @intCast(row_count - 1);
        scroll_view.scroll.vertical_offset = 0;
    }
}

pub fn scrollCursorIntoView(scroll_view: *vxfw.ScrollView, row_count: usize) void {
    if (row_count == 0) {
        scroll_view.cursor = 0;
        clampScrollTop(scroll_view, row_count);
        return;
    }
    if (scroll_view.cursor >= row_count) scroll_view.cursor = @intCast(row_count - 1);
    const cursor = @as(usize, @intCast(scroll_view.cursor));
    const visible_rows = visibleRowCount(scroll_view);
    var top = @as(usize, @intCast(scroll_view.scroll.top));
    if (cursor < top) {
        top = cursor;
    } else if (cursor >= top + visible_rows) {
        top = cursor - visible_rows + 1;
    }
    scroll_view.scroll.top = @intCast(top);
    scroll_view.scroll.vertical_offset = 0;
    clampScrollTop(scroll_view, row_count);
}

pub fn syncScrollCursor(scroll_view: *vxfw.ScrollView, cursor: usize, row_count: usize) void {
    if (row_count == 0) {
        scroll_view.cursor = 0;
    } else {
        scroll_view.cursor = @intCast(@min(cursor, row_count - 1));
    }
    clampScrollTop(scroll_view, row_count);
}

pub fn moveCursorBy(cursor: *usize, count: usize, delta: isize) bool {
    if (count == 0) {
        cursor.* = 0;
        return false;
    }
    const old = @min(cursor.*, count - 1);
    const next = if (delta < 0)
        old -| @as(usize, @intCast(-delta))
    else
        @min(count - 1, old + @as(usize, @intCast(delta)));
    cursor.* = next;
    return next != old;
}

pub fn pageStepRows(scroll_view: *const vxfw.ScrollView) usize {
    return @max(@as(usize, 1), visibleRowCount(scroll_view) -| 1);
}

pub fn halfPageStepRows(scroll_view: *const vxfw.ScrollView) usize {
    return @max(@as(usize, 1), visibleRowCount(scroll_view) / 2);
}

pub fn stepForKey(key: vaxis.Key, scroll_view: *const vxfw.ScrollView) ?isize {
    if (isJumpDownKey(key)) return @intCast(pageStepRows(scroll_view));
    if (isJumpUpKey(key)) return -@as(isize, @intCast(pageStepRows(scroll_view)));
    if (isHalfPageDownKey(key)) return @intCast(halfPageStepRows(scroll_view));
    if (isHalfPageUpKey(key)) return -@as(isize, @intCast(halfPageStepRows(scroll_view)));
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) return 1;
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) return -1;
    return null;
}

pub fn moveSelectableRowByVisualRows(
    cursor: usize,
    row_count: usize,
    selectable_rows: []const ?usize,
    row_delta: isize,
) usize {
    if (row_count == 0) return 0;
    const bounded_cursor = @min(cursor, row_count - 1);
    if (row_delta == 0) return bounded_cursor;

    const target = if (row_delta < 0)
        bounded_cursor -| @as(usize, @intCast(-row_delta))
    else
        @min(row_count - 1, bounded_cursor + @as(usize, @intCast(row_delta)));

    if (row_delta < 0) {
        var pos = target + 1;
        while (pos > 0) {
            pos -= 1;
            if (pos < selectable_rows.len and selectable_rows[pos] != null) return pos;
        }
    } else {
        var pos = target;
        while (pos < row_count) : (pos += 1) {
            if (pos < selectable_rows.len and selectable_rows[pos] != null) return pos;
        }
    }

    return bounded_cursor;
}

pub fn isJumpDownKey(key: vaxis.Key) bool {
    return key.matches('J', .{}) or key.matches('j', .{ .shift = true });
}

pub fn isJumpUpKey(key: vaxis.Key) bool {
    return key.matches('K', .{}) or key.matches('k', .{ .shift = true });
}

pub fn isHalfPageDownKey(key: vaxis.Key) bool {
    return key.matches('d', .{ .ctrl = true });
}

pub fn isHalfPageUpKey(key: vaxis.Key) bool {
    return key.matches('u', .{ .ctrl = true });
}

fn visibleRowCount(scroll_view: *const vxfw.ScrollView) usize {
    return @max(@as(usize, @intCast(scroll_view.last_height)), 1);
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

test "scrollCursorIntoView does not move viewport when cursor is visible" {
    var scroll_view = vxfw.ScrollView{ .children = .{ .slice = &.{} } };
    scroll_view.last_height = 5;
    scroll_view.cursor = 4;
    scroll_view.scroll.top = 2;
    scrollCursorIntoView(&scroll_view, 20);
    try std.testing.expectEqual(@as(u32, 2), scroll_view.scroll.top);
}

test "scrollCursorIntoView brings cursor below viewport into view" {
    var scroll_view = vxfw.ScrollView{ .children = .{ .slice = &.{} } };
    scroll_view.last_height = 5;
    scroll_view.cursor = 8;
    scroll_view.scroll.top = 2;
    scrollCursorIntoView(&scroll_view, 20);
    try std.testing.expectEqual(@as(u32, 4), scroll_view.scroll.top);
}

test "moveCursorBy clamps to list bounds" {
    var cursor: usize = 2;
    try std.testing.expect(moveCursorBy(&cursor, 5, 10));
    try std.testing.expectEqual(@as(usize, 4), cursor);
    try std.testing.expect(moveCursorBy(&cursor, 5, -10));
    try std.testing.expectEqual(@as(usize, 0), cursor);
}

test "clampScrollTop allows bottom anchoring inside content" {
    var scroll_view = vxfw.ScrollView{ .children = .{ .slice = &.{} } };
    scroll_view.last_height = 5;
    scroll_view.scroll.top = 25;
    clampScrollTop(&scroll_view, 20);
    try std.testing.expectEqual(@as(u32, 19), scroll_view.scroll.top);
}

test "clampScrollTop preserves valid short content position" {
    var scroll_view = vxfw.ScrollView{ .children = .{ .slice = &.{} } };
    scroll_view.last_height = 5;
    scroll_view.scroll.top = 2;
    clampScrollTop(&scroll_view, 3);
    try std.testing.expectEqual(@as(u32, 2), scroll_view.scroll.top);
    try std.testing.expectEqual(@as(i17, 0), scroll_view.scroll.vertical_offset);
}

test "page step helpers use viewport height" {
    var scroll_view = vxfw.ScrollView{ .children = .{ .slice = &.{} } };
    scroll_view.last_height = 10;
    try std.testing.expectEqual(@as(usize, 9), pageStepRows(&scroll_view));
    try std.testing.expectEqual(@as(usize, 5), halfPageStepRows(&scroll_view));
}

test "moveSelectableRowByVisualRows lands on selectable visual rows" {
    const selectable = [_]?usize{ 0, null, 1, null, 2, null };
    try std.testing.expectEqual(
        @as(usize, 4),
        moveSelectableRowByVisualRows(0, selectable.len, selectable[0..], 3),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        moveSelectableRowByVisualRows(4, selectable.len, selectable[0..], -3),
    );
}

test "shifted jump keys can also match lowercase movement keys" {
    const shift_j = vaxis.Key{
        .codepoint = 'J',
        .text = "J",
        .shifted_codepoint = 'j',
        .mods = .{ .shift = true },
    };
    try std.testing.expect(isJumpDownKey(shift_j));
    try std.testing.expect(shift_j.matches('j', .{}));
}
