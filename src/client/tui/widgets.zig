const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("theme.zig");

// Braille charts are redrawn frequently, so we keep a static UTF-8 lookup
// table for U+2800..U+28FF instead of encoding and duplicating a grapheme
// for every rendered cell on each draw.
const braille_utf8_table = initBrailleUtf8Table();

fn initBrailleUtf8Table() [256][3]u8 {
    var table: [256][3]u8 = undefined;
    for (0..table.len) |i| {
        const cp: u21 = 0x2800 + @as(u21, @intCast(i));
        // The braille block always encodes to three UTF-8 bytes. Assemble
        // them directly so comptime table generation stays simple and avoids
        // hitting std.unicode's branch quota during builds.
        table[i] = .{
            @as(u8, 0xe0) | @as(u8, @intCast(cp >> 12)),
            @as(u8, 0x80) | @as(u8, @intCast((cp >> 6) & 0x3f)),
            @as(u8, 0x80) | @as(u8, @intCast(cp & 0x3f)),
        };
    }
    return table;
}

fn brailleGrapheme(cp: u21) []const u8 {
    const idx: usize = @intCast(cp - 0x2800);
    return braille_utf8_table[idx][0..];
}

fn sampleInterpolatedValue(trend: []const f32, sample_x: f32) f32 {
    if (trend.len == 0) return 0;
    if (trend.len == 1) return trend[0];

    const max_x = @as(f32, @floatFromInt(trend.len - 1));
    const clamped_x = std.math.clamp(sample_x, 0.0, max_x);
    const left_x = @floor(clamped_x);
    const left_idx: usize = @intFromFloat(left_x);
    const right_idx = @min(left_idx + 1, trend.len - 1);
    const t = clamped_x - left_x;

    return trend[left_idx] * (1.0 - t) + trend[right_idx] * t;
}

const ChartScale = struct {
    min_val: f32,
    max_val: f32,
};

fn transformChartValue(value: f32) f32 {
    return @sqrt(@max(value, 0.0));
}

fn quantileSorted(values: []const f32, q: f32) f32 {
    if (values.len == 0) return 0;
    if (values.len == 1) return values[0];

    const clamped_q = std.math.clamp(q, 0.0, 1.0);
    const scaled_idx = clamped_q * @as(f32, @floatFromInt(values.len - 1));
    const left_idx: usize = @intFromFloat(@floor(scaled_idx));
    const right_idx = @min(left_idx + 1, values.len - 1);
    const t = scaled_idx - @as(f32, @floatFromInt(left_idx));

    return values[left_idx] * (1.0 - t) + values[right_idx] * t;
}

fn resolveChartScale(trend: []const f32) ChartScale {
    if (trend.len == 0) return .{ .min_val = 0, .max_val = 1 };

    var sorted_samples: [256]f32 = undefined;
    const sample_count = @min(trend.len, sorted_samples.len);
    if (sample_count == 0) return .{ .min_val = 0, .max_val = 1 };

    for (0..sample_count) |i| {
        const src_idx = if (sample_count == trend.len or sample_count == 1)
            i
        else
            i * (trend.len - 1) / (sample_count - 1);
        sorted_samples[i] = transformChartValue(trend[src_idx]);
    }

    std.mem.sort(f32, sorted_samples[0..sample_count], {}, struct {
        fn lessThan(_: void, a: f32, b: f32) bool {
            return a < b;
        }
    }.lessThan);

    const min_sample = sorted_samples[0];
    const max_sample = sorted_samples[sample_count - 1];
    const lower_q = quantileSorted(sorted_samples[0..sample_count], 0.12);
    const upper_q = quantileSorted(sorted_samples[0..sample_count], 0.88);
    const center = (lower_q + upper_q) * 0.5;
    const robust_span = @max(upper_q - lower_q, 0.35);

    // Use a robust band instead of raw min/max so one burst does not flatten
    // the rest of the minute, while still leaving some headroom for spikes.
    const lower_pad = @max(robust_span * 0.35, (lower_q - min_sample) * 0.5, 0.12);
    const upper_pad = @max(robust_span * 0.45, (max_sample - upper_q) * 0.4, 0.25);

    var min_val = @max(lower_q - lower_pad, 0.0);
    var max_val = upper_q + upper_pad;

    const min_display_span = @max(robust_span * 1.4, 0.9);
    if (max_val - min_val < min_display_span) {
        const half_span = min_display_span * 0.5;
        min_val = @max(center - half_span, 0.0);
        max_val = center + half_span;
    }

    if (max_val - min_val < 0.1) {
        max_val = min_val + 0.1;
    }

    return .{ .min_val = min_val, .max_val = max_val };
}

fn chartDotY(value: f32, min_val: f32, max_val: f32, rows: u32) u32 {
    const span = @max(max_val - min_val, 0.001);
    const ratio = std.math.clamp((value - min_val) / span, 0.0, 1.0);
    const max_row = @as(f32, @floatFromInt(rows - 1));
    return @intFromFloat(@round((1.0 - ratio) * max_row));
}

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

// Horizontal key-value pair: key in MUTED, value in TEXT.
// key_width is the fixed column width for the key (left-aligned, padded).
// Returns the next available row (row + 1).
pub fn writeKv(surface: *vxfw.Surface, ctx: vxfw.DrawContext, col: u16, row: u16, key: []const u8, value: []const u8, key_width: u16) u16 {
    writeText(surface, ctx, col, row, key, theme.fg(theme.MUTED));
    writeText(surface, ctx, col + key_width + 1, row, value, theme.fg(theme.TEXT));
    return row + 1;
}

// Section header: bold accent text, used before vertical KV groups.
// Returns the next available row (row + 1).
pub fn writeSectionHeader(surface: *vxfw.Surface, ctx: vxfw.DrawContext, col: u16, row: u16, text: []const u8) u16 {
    writeText(surface, ctx, col, row, text, theme.fgBold(theme.ACCENT));
    return row + 1;
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
        if (selected) theme.PANEL else theme.TEXT_SOFT,
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
        if (selected) theme.PANEL else theme.TEXT_SOFT,
        if (selected) theme.GOLD else theme.PANEL_ALT,
    );
}

// Draw a braille area chart with gradient coloring (btop-style).
// Area is filled from the data line down to the bottom, creating
// a solid "mountain" shape. Gradient: ACCENT_SOFT (bottom) → OK (top).
pub fn drawBrailleAreaChart(surface: *vxfw.Surface, trend: []const f32, x: u16, y: u16, width: u16, height: u16) void {
    if (width == 0 or height == 0 or trend.len == 0) return;

    const scale = resolveChartScale(trend);

    const braille_h: u32 = @as(u32, height) * 4;
    const cols: u32 = @min(@as(u32, width) * 2, 512);
    const rows: u32 = @min(braille_h, 128);

    var dots: [512][128]bool = undefined;
    for (&dots) |*r| @memset(r, false);

    // Sample a continuous curve across the discrete buckets so the chart
    // reads as a local activity wave rather than a stack of isolated bars.
    for (0..cols) |col_idx| {
        const sample_x = if (cols > 1)
            @as(f32, @floatFromInt(col_idx)) *
                @as(f32, @floatFromInt(trend.len - 1)) /
                @as(f32, @floatFromInt(cols - 1))
        else
            0.0;
        const val = sampleInterpolatedValue(trend, sample_x);
        const dot_y = chartDotY(transformChartValue(val), scale.min_val, scale.max_val, rows);

        // Fill from dot_y down to bottom (area fill)
        var fill_y = dot_y;
        while (fill_y < rows) : (fill_y += 1) {
            dots[col_idx][fill_y] = true;
        }
    }

    // Render braille characters with vertical gradient
    const char_cols = (cols + 1) / 2;
    const char_rows = (rows + 3) / 4;

    for (0..char_rows) |cr| {
        for (0..char_cols) |cc| {
            var cp: u21 = 0x2800;
            const dx = cc * 2;
            const dy = cr * 4;

            if (dx < cols) {
                if (dy + 0 < rows and dots[dx][dy + 0]) cp |= 0x01;
                if (dy + 1 < rows and dots[dx][dy + 1]) cp |= 0x02;
                if (dy + 2 < rows and dots[dx][dy + 2]) cp |= 0x04;
                if (dy + 3 < rows and dots[dx][dy + 3]) cp |= 0x40;
            }
            if (dx + 1 < cols) {
                if (dy + 0 < rows and dots[dx + 1][dy + 0]) cp |= 0x08;
                if (dy + 1 < rows and dots[dx + 1][dy + 1]) cp |= 0x10;
                if (dy + 2 < rows and dots[dx + 1][dy + 2]) cp |= 0x20;
                if (dy + 3 < rows and dots[dx + 1][dy + 3]) cp |= 0x80;
            }

            if (cp == 0x2800) continue;

            // Vertical gradient: top rows = ACCENT (deep amber), bottom rows = ACCENT_SOFT (light amber)
            const vert_t: f32 = if (char_rows > 1) 1.0 - @as(f32, @floatFromInt(cr)) / @as(f32, @floatFromInt(char_rows - 1)) else 0.5;
            const color = theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, vert_t);

            const col: u16 = x + @as(u16, @intCast(cc));
            const row: u16 = y + @as(u16, @intCast(cr));
            if (col < surface.size.width and row < surface.size.height) {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = brailleGrapheme(cp), .width = 1 },
                    .style = .{ .fg = color, .bg = theme.PANEL },
                });
            }
        }
    }
}

test "brailleGrapheme uses stable utf8 lookups" {
    try std.testing.expectEqualStrings("\xe2\xa0\x81", brailleGrapheme(0x2801));
    try std.testing.expectEqualStrings("\xe2\xa3\xbf", brailleGrapheme(0x28ff));
}

test "sampleInterpolatedValue blends neighboring buckets" {
    const trend = [_]f32{ 0, 10, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 5), sampleInterpolatedValue(&trend, 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), sampleInterpolatedValue(&trend, 1.5), 0.001);
}

test "resolveChartScale keeps steady low activity off the bottom edge" {
    const trend = [_]f32{ 1, 1, 1, 1, 1 };
    const scale = resolveChartScale(&trend);
    const dot_y = chartDotY(transformChartValue(1), scale.min_val, scale.max_val, 8);

    try std.testing.expect(dot_y > 1);
    try std.testing.expect(dot_y < 6);
}

test "resolveChartScale preserves low-band motion when a spike arrives" {
    const trend = [_]f32{ 1, 1, 1, 1, 100 };
    const scale = resolveChartScale(&trend);
    const low_dot_y = chartDotY(transformChartValue(1), scale.min_val, scale.max_val, 8);
    const spike_dot_y = chartDotY(transformChartValue(100), scale.min_val, scale.max_val, 8);

    try std.testing.expect(low_dot_y < 7);
    try std.testing.expectEqual(@as(u32, 0), spike_dot_y);
}

test "chartDotY maps higher values toward the top" {
    try std.testing.expectEqual(@as(u32, 7), chartDotY(0, 0, 10, 8));
    try std.testing.expectEqual(@as(u32, 0), chartDotY(10, 0, 10, 8));
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
    bg: vaxis.Color,
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
    fillSurface(&root, bg);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = left };
    children[1] = .{ .origin = .{ .row = 0, .col = @as(i17, @intCast(left_width)) + 1 }, .surface = right };
    root.children = children;
    return root;
}

/// Create a vertical two-row layout. Top section is `top_height` rows;
/// bottom section fills the rest.
pub fn splitVertical(
    ctx: vxfw.DrawContext,
    owner: vxfw.Widget,
    bg: vaxis.Color,
    top: vxfw.Surface,
    bottom: vxfw.Surface,
    top_height: u16,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, owner, size);
    fillSurface(&root, bg);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = top };
    children[1] = .{ .origin = .{ .row = @as(i17, @intCast(top_height)), .col = 0 }, .surface = bottom };
    root.children = children;
    return root;
}

/// Draw the ▌ cursor marker at (col, row) on an existing surface.
pub fn writeCursorMarker(surface: *vxfw.Surface, col: u16, row: u16) void {
    if (col >= surface.size.width or row >= surface.size.height) return;
    surface.writeCell(col, row, .{
        .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
        .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
    });
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

/// Handle j/↓ and k/↑ keys for list cursor navigation.
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

/// Return the border color for a panel based on whether it has focus.
pub fn focusBorder(has_focus: bool) vaxis.Color {
    return if (has_focus) theme.ACCENT else theme.BORDER;
}

/// Render a row of tab badges. Returns the column after the last badge.
pub fn drawTabBar(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    row: u16,
    start_col: u16,
    labels: []const []const u8,
    selected: usize,
    comptime style: enum { top_level, inner },
) u16 {
    var col = start_col;
    for (labels, 0..) |label, i| {
        col = switch (style) {
            .top_level => drawTabBadge(surface, ctx, row, col, label, i == selected),
            .inner => drawInnerTabBadge(surface, ctx, row, col, label, i == selected),
        };
    }
    return col;
}

const api_state = @import("api/state.zig");

/// Draw a gradient activity bar using █ characters. Width is proportional to
/// value/max_value. Color lerps from ACCENT_SOFT to ACCENT across the bar.
/// Always draws at least 1 cell when value > 0.
pub fn drawActivityBar(
    surface: *vxfw.Surface,
    col: u16,
    row: u16,
    value: u32,
    max_value: u32,
    width: u16,
) void {
    if (value == 0 or width == 0 or max_value == 0) return;
    const bar_w_raw: u16 = @intCast(@as(u32, width) * value / max_value);
    const bar_w: u16 = if (bar_w_raw == 0) 1 else @min(bar_w_raw, width);
    for (0..bar_w) |offset| {
        const bc = col + @as(u16, @intCast(offset));
        if (bc >= surface.size.width) break;
        const t: f32 = if (bar_w > 1)
            @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(bar_w - 1))
        else
            0.5;
        surface.writeCell(bc, row, .{
            .char = .{ .grapheme = "\xe2\x96\x88", .width = 1 },
            .style = .{ .fg = theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, t), .bg = theme.PANEL },
        });
    }
}

/// Draw a heatmap grid using ▪ characters. Color intensity represents value.
/// values are laid out row-major with `cols` items per row. Cells are spaced
/// 2 columns apart for visual breathing room.
pub fn drawHeatmap(
    surface: *vxfw.Surface,
    col: u16,
    start_row: u16,
    values: []const u16,
    cols: u16,
    max_value: u16,
) void {
    if (cols == 0) return;
    const max_f: f32 = @floatFromInt(@max(max_value, 1));
    for (values, 0..) |value, i| {
        const grid_col: u16 = @intCast(i % cols);
        const grid_row: u16 = @intCast(i / cols);
        const x = col + grid_col * 2;
        const y = start_row + grid_row;
        if (x >= surface.size.width or y >= surface.size.height) continue;
        const fg = if (value == 0)
            theme.rgb(0xffe8b8)
        else
            theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, @as(f32, @floatFromInt(value)) / max_f);
        surface.writeCell(x, y, .{
            .char = .{ .grapheme = "\xe2\x96\xa0", .width = 1 },
            .style = .{ .fg = fg, .bg = theme.PANEL },
        });
    }
}

/// Write an empty-state message based on the API connection status.
/// Produces messages like "Loading prompts..." or "Not authenticated."
pub fn drawEmptyState(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    col: u16,
    row: u16,
    status: api_state.ConnectionStatus,
    entity_name: []const u8,
) void {
    const msg: []const u8 = switch (status) {
        .connecting => blk: {
            break :blk std.fmt.allocPrint(ctx.arena, "Loading {s}...", .{entity_name}) catch "Loading...";
        },
        .error_auth => "Not authenticated. Run clumsies login.",
        .error_network => "Hub unavailable. Check clumsies-hub.",
        .disconnected => "Not connected to hub.",
        .connected => blk: {
            break :blk std.fmt.allocPrint(ctx.arena, "No {s} loaded.", .{entity_name}) catch "No data loaded.";
        },
    };
    writeText(surface, ctx, col, row, msg, .{ .fg = theme.MUTED, .bg = theme.PANEL });
}

test "writeCursorMarker does not crash on out-of-bounds" {
    const alloc = std.testing.allocator;
    var surface = try vxfw.Surface.init(alloc, undefined, .{ .width = 2, .height = 2 });
    defer alloc.free(surface.buffer);
    // In-bounds: should write without panic
    writeCursorMarker(&surface, 0, 0);
    // Out-of-bounds: should be a no-op
    writeCursorMarker(&surface, 5, 5);
}

test "focusBorder returns ACCENT when focused" {
    try std.testing.expectEqual(theme.ACCENT, focusBorder(true));
    try std.testing.expectEqual(theme.BORDER, focusBorder(false));
}

test {
    _ = @import("widgets/modal.zig");
    _ = @import("widgets/text_input.zig");
}
