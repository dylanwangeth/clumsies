const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const diff_viewer = @import("diff_viewer.zig");
const cursor = @import("cursor.zig");

pub const ContentView = struct {
    scroll_bars: vxfw.ScrollBars,
    cache_bytes: []const u8 = "",
    draft_bytes: ?[]const u8 = null,

    pub fn init() ContentView {
        return .{
            .scroll_bars = cursor.initPlainScrollBars(theme.PANEL, 3),
        };
    }

    pub fn syncBytes(
        self: *ContentView,
        arena: std.mem.Allocator,
        cache_content: []const u8,
        draft_content: ?[]const u8,
    ) void {
        self.cache_bytes = arena.dupe(u8, cache_content) catch "";
        self.draft_bytes = if (draft_content) |content|
            arena.dupe(u8, content) catch self.cache_bytes
        else
            null;
    }

    pub fn buildSurface(
        self: *ContentView,
        arena: std.mem.Allocator,
        ctx: vxfw.DrawContext,
        width_pad: u16,
        child_height: u16,
    ) std.mem.Allocator.Error!vxfw.Surface {
        const inner_w = ctx.max.width.? -| width_pad;
        // ScrollBars always reserves one column for the vertical bar when that
        // feature is enabled, so wrap against the actual visible content width.
        const content_w = @max(@as(u16, 1), inner_w -| @intFromBool(self.scroll_bars.draw_vertical_scrollbar));
        try self.rebuildWidgets(arena, ctx, content_w, child_height);
        const child_ctx = ctx.withConstraints(
            .{ .width = inner_w, .height = child_height },
            .{ .width = inner_w, .height = child_height },
        );
        return self.scroll_bars.widget().draw(child_ctx);
    }

    pub fn handleEvent(self: *ContentView, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        switch (event) {
            .key_press => |key| {
                if (cursor.isJumpDownKey(key)) {
                    const step = cursor.pageStepRows(&self.scroll_bars.scroll_view);
                    const content_h: u32 = self.scroll_bars.estimated_content_height orelse 0;
                    const visible = @as(u32, @intCast(cursor.visibleRowCount(&self.scroll_bars.scroll_view)));
                    const max_top = content_h -| visible;
                    self.scroll_bars.scroll_view.scroll.top = @min(max_top, self.scroll_bars.scroll_view.scroll.top + @as(u32, @intCast(step)));
                    self.scroll_bars.scroll_view.scroll.vertical_offset = 0;
                    ctx.consumeAndRedraw();
                    return;
                }
                if (cursor.isJumpUpKey(key)) {
                    const step = cursor.pageStepRows(&self.scroll_bars.scroll_view);
                    self.scroll_bars.scroll_view.scroll.top = self.scroll_bars.scroll_view.scroll.top -| @as(u32, @intCast(step));
                    self.scroll_bars.scroll_view.scroll.vertical_offset = 0;
                    ctx.consumeAndRedraw();
                    return;
                }
            },
            else => {},
        }
        try self.scroll_bars.scroll_view.handleEvent(ctx, event);
        self.scroll_bars.scroll_view.scroll.left = 0;
    }

    fn rebuildWidgets(
        self: *ContentView,
        arena: std.mem.Allocator,
        ctx: vxfw.DrawContext,
        inner_w: u16,
        child_height: u16,
    ) !void {
        const proposed = self.draft_bytes orelse self.cache_bytes;
        const diff_rows = diff_viewer.computeInlineGutter(arena, self.cache_bytes, proposed) catch null;

        var lines: std.ArrayListUnmanaged(DisplayLine) = .empty;
        if (diff_rows) |rows| {
            try appendWrappedDiffLines(arena, ctx, &lines, rows, inner_w);
        } else {
            try appendWrappedFlatLines(arena, ctx, &lines, proposed, theme.textOn(theme.PANEL, theme.TEXT_SOFT), inner_w);
        }

        const row_count = @max(lines.items.len, 1);
        const widgets_buf = try arena.alloc(vxfw.Widget, row_count);
        const texts = try arena.alloc(vxfw.Text, row_count);
        if (lines.items.len == 0) {
            texts[0] = .{
                .text = "",
                .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT),
                .softwrap = false,
            };
            widgets_buf[0] = texts[0].widget();
        } else {
            for (lines.items, 0..) |line, idx| {
                texts[idx] = .{
                    .text = line.text,
                    .style = line.style,
                    .softwrap = false,
                };
                widgets_buf[idx] = texts[idx].widget();
            }
        }
        self.scroll_bars.scroll_view.children = .{ .slice = widgets_buf };
        self.scroll_bars.estimated_content_height = @intCast(row_count);
        self.scroll_bars.estimated_content_width = null;
        const max_top: usize = if (row_count > child_height) row_count - child_height else 0;
        if (max_top == 0) {
            self.scroll_bars.scroll_view.scroll.top = 0;
            self.scroll_bars.scroll_view.scroll.vertical_offset = 0;
        } else if (self.scroll_bars.scroll_view.scroll.top > max_top) {
            self.scroll_bars.scroll_view.scroll.top = @intCast(max_top);
            self.scroll_bars.scroll_view.scroll.vertical_offset = 0;
        }
        self.scroll_bars.scroll_view.scroll.left = 0;
    }
};

const DisplayLine = struct {
    text: []const u8,
    style: vaxis.Style,
};

fn appendWrappedDiffLines(
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    out: *std.ArrayListUnmanaged(DisplayLine),
    rows: []const diff_viewer.DiffRow,
    max_width: u16,
) !void {
    for (rows) |row| {
        const marker: u8 = switch (row.marker) {
            .unchanged => ' ',
            .added => '+',
            .removed => '-',
        };
        const lineno = row.new_line orelse row.old_line orelse 0;
        const prefix = try std.fmt.allocPrint(arena, "{d:>4} {c} ", .{ lineno, marker });
        const continuation = "       ";
        try appendWrappedLine(out, arena, ctx, prefix, continuation, row.text, gutterRowStyle(row.marker), max_width);
    }
}

fn appendWrappedFlatLines(
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    out: *std.ArrayListUnmanaged(DisplayLine),
    content: []const u8,
    style: vaxis.Style,
    max_width: u16,
) !void {
    var iter = LocalLineIterator{ .buf = content };
    while (iter.next()) |line| {
        try appendWrappedLine(out, arena, ctx, "", "", line, style, max_width);
    }
    if (content.len == 0) {
        try out.append(arena, .{ .text = "", .style = style });
    }
}

fn appendWrappedLine(
    out: *std.ArrayListUnmanaged(DisplayLine),
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    first_prefix: []const u8,
    continuation_prefix: []const u8,
    text: []const u8,
    style: vaxis.Style,
    max_width: u16,
) !void {
    const first_prefix_w = ctx.stringWidth(first_prefix);
    const continuation_prefix_w = ctx.stringWidth(continuation_prefix);
    const base_limit = @max(@as(u16, 1), max_width);
    var rest = text;
    var prefix = first_prefix;
    var prefix_w = first_prefix_w;

    if (rest.len == 0) {
        try out.append(arena, .{
            .text = try std.fmt.allocPrint(arena, "{s}", .{prefix}),
            .style = style,
        });
        return;
    }

    while (true) {
        const available = @max(@as(u16, 1), base_limit -| @as(u16, @intCast(prefix_w)));
        const consumed = wrapBytesForWidth(ctx, rest, available);
        const slice = rest[0..consumed];
        try out.append(arena, .{
            .text = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, slice }),
            .style = style,
        });
        if (consumed >= rest.len) break;
        rest = rest[consumed..];
        prefix = continuation_prefix;
        prefix_w = continuation_prefix_w;
    }
}

fn wrapBytesForWidth(ctx: vxfw.DrawContext, text: []const u8, max_width: u16) usize {
    if (text.len == 0) return 0;
    var iter = ctx.graphemeIterator(text);
    var width: u16 = 0;
    var last_end: usize = 0;
    while (iter.next()) |item| {
        const grapheme = item.bytes(text);
        const grapheme_w: u16 = @intCast(ctx.stringWidth(grapheme));
        if (width + grapheme_w > max_width) {
            return if (last_end > 0) last_end else grapheme.len;
        }
        width += grapheme_w;
        last_end += grapheme.len;
    }
    return text.len;
}

const LocalLineIterator = struct {
    buf: []const u8,
    index: usize = 0,

    fn next(self: *LocalLineIterator) ?[]const u8 {
        if (self.index >= self.buf.len) return null;

        const start = self.index;
        const end = std.mem.indexOfAnyPos(u8, self.buf, self.index, "\r\n") orelse {
            self.index = self.buf.len;
            return self.buf[start..];
        };

        self.index = end;
        self.consumeCR();
        self.consumeLF();
        return self.buf[start..end];
    }

    fn consumeLF(self: *LocalLineIterator) void {
        if (self.index >= self.buf.len) return;
        if (self.buf[self.index] == '\n') self.index += 1;
    }

    fn consumeCR(self: *LocalLineIterator) void {
        if (self.index >= self.buf.len) return;
        if (self.buf[self.index] == '\r') self.index += 1;
    }
};

fn gutterRowStyle(marker: diff_viewer.Marker) vaxis.Style {
    return switch (marker) {
        .unchanged => theme.textOn(theme.PANEL, theme.TEXT_SOFT),
        .added => .{ .fg = theme.OK, .bg = theme.rgb(0x1d2617) },
        .removed => .{ .fg = theme.DANGER, .bg = theme.rgb(0x2a1b18) },
    };
}
