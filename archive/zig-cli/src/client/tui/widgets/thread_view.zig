const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const cursor = @import("cursor.zig");

pub const ItemKind = enum { primary, reply };

pub const Item = struct {
    kind: ItemKind = .reply,
    title: []const u8,
    meta: []const u8,
    body: []const u8,
};

pub const ThreadView = struct {
    scroll_bars: vxfw.ScrollBars,
    rows: []vxfw.Widget = &.{},
    texts: []vxfw.Text = &.{},

    pub fn init() ThreadView {
        return .{
            .scroll_bars = cursor.initPlainScrollBars(theme.PANEL, 3),
        };
    }

    pub fn syncItems(
        self: *ThreadView,
        arena: std.mem.Allocator,
        ctx: vxfw.DrawContext,
        items: []const Item,
        width: u16,
        height: u16,
    ) std.mem.Allocator.Error!void {
        var lines: std.ArrayListUnmanaged(Line) = .empty;
        const content_w = @max(@as(u16, 1), width -| @intFromBool(self.scroll_bars.draw_vertical_scrollbar));
        for (items, 0..) |item, idx| {
            if (idx > 0) {
                try lines.append(arena, .{ .text = "", .style = theme.fg(theme.DIM) });
                try lines.append(arena, .{ .text = "", .style = theme.fg(theme.DIM) });
            }
            try appendItemLines(arena, ctx, &lines, item, content_w);
        }

        const row_count = @max(lines.items.len, 1);
        const widgets = try arena.alloc(vxfw.Widget, row_count);
        const texts = try arena.alloc(vxfw.Text, row_count);
        if (lines.items.len == 0) {
            texts[0] = .{ .text = "", .style = theme.fg(theme.MUTED), .softwrap = false };
            widgets[0] = texts[0].widget();
        } else {
            for (lines.items, 0..) |line, i| {
                texts[i] = .{ .text = line.text, .style = line.style, .softwrap = false };
                widgets[i] = texts[i].widget();
            }
        }

        self.rows = widgets;
        self.texts = texts;
        self.scroll_bars.scroll_view.children = .{ .slice = widgets };
        self.scroll_bars.estimated_content_height = @intCast(row_count);
        self.scroll_bars.estimated_content_width = null;
        clampScroll(&self.scroll_bars.scroll_view, row_count, height);
    }

    pub fn draw(self: *ThreadView, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        return self.scroll_bars.widget().draw(ctx);
    }

    pub fn handleEvent(self: *ThreadView, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
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
};

const Line = struct {
    text: []const u8,
    style: vaxis.Style,
};

fn appendItemLines(
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    out: *std.ArrayListUnmanaged(Line),
    item: Item,
    width: u16,
) std.mem.Allocator.Error!void {
    const meta_style = theme.fg(theme.MUTED);
    const body_style = theme.fg(theme.TEXT_SOFT);
    switch (item.kind) {
        .primary => {
            try appendSingleLine(arena, ctx, out, item.title, theme.fgBold(theme.TEXT), width);
            if (item.meta.len > 0) try appendSingleLine(arena, ctx, out, item.meta, meta_style, width);
        },
        .reply => {
            const header = if (item.meta.len > 0)
                try std.fmt.allocPrint(arena, "{s} · {s}", .{ item.title, item.meta })
            else
                item.title;
            try appendSingleLine(arena, ctx, out, header, meta_style, width);
        },
    }
    if (item.body.len > 0) {
        try appendWrappedParagraphs(arena, ctx, out, item.body, body_style, width);
    }
}

fn appendSingleLine(
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    out: *std.ArrayListUnmanaged(Line),
    text: []const u8,
    style: vaxis.Style,
    width: u16,
) std.mem.Allocator.Error!void {
    try out.append(arena, .{
        .text = try trimToWidth(arena, ctx, text, @max(@as(u16, 1), width)),
        .style = style,
    });
}

fn appendWrappedParagraphs(
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    out: *std.ArrayListUnmanaged(Line),
    body: []const u8,
    style: vaxis.Style,
    width: u16,
) std.mem.Allocator.Error!void {
    var iter = LineIterator{ .buf = body };
    var any = false;
    while (iter.next()) |line| {
        any = true;
        try appendWrappedLine(arena, ctx, out, "", "", line, style, width);
    }
    if (!any) try out.append(arena, .{ .text = "", .style = style });
}

fn appendWrappedLine(
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    out: *std.ArrayListUnmanaged(Line),
    first_prefix: []const u8,
    continuation_prefix: []const u8,
    text: []const u8,
    style: vaxis.Style,
    width: u16,
) std.mem.Allocator.Error!void {
    const base_limit = @max(@as(u16, 1), width);
    var rest = text;
    var prefix = first_prefix;
    var prefix_w = ctx.stringWidth(prefix);
    if (rest.len == 0) {
        try out.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s}", .{prefix}), .style = style });
        return;
    }
    while (true) {
        const available = @max(@as(u16, 1), base_limit -| @as(u16, @intCast(prefix_w)));
        const consumed = wrapBytesForWidth(ctx, rest, available);
        try out.append(arena, .{
            .text = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, rest[0..consumed] }),
            .style = style,
        });
        if (consumed >= rest.len) break;
        rest = rest[consumed..];
        prefix = continuation_prefix;
        prefix_w = ctx.stringWidth(prefix);
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

fn trimToWidth(arena: std.mem.Allocator, ctx: vxfw.DrawContext, text: []const u8, max_width: u16) std.mem.Allocator.Error![]const u8 {
    if (ctx.stringWidth(text) <= max_width) return arena.dupe(u8, text);
    if (max_width <= 3) return arena.dupe(u8, text[0..wrapBytesForWidth(ctx, text, max_width)]);
    const consumed = wrapBytesForWidth(ctx, text, max_width - 3);
    return std.fmt.allocPrint(arena, "{s}...", .{text[0..consumed]});
}

fn clampScroll(scroll_view: *vxfw.ScrollView, row_count: usize, height: u16) void {
    const max_top: usize = if (row_count > height) row_count - height else 0;
    if (max_top == 0) {
        scroll_view.scroll.top = 0;
        scroll_view.scroll.vertical_offset = 0;
    } else if (scroll_view.scroll.top > max_top) {
        scroll_view.scroll.top = @intCast(max_top);
        scroll_view.scroll.vertical_offset = 0;
    }
    scroll_view.scroll.left = 0;
}

const LineIterator = struct {
    buf: []const u8,
    idx: usize = 0,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.idx >= self.buf.len) return null;
        const start = self.idx;
        while (self.idx < self.buf.len and self.buf[self.idx] != '\n' and self.buf[self.idx] != '\r') {
            self.idx += 1;
        }
        const end = self.idx;
        if (self.idx < self.buf.len and self.buf[self.idx] == '\r') self.idx += 1;
        if (self.idx < self.buf.len and self.buf[self.idx] == '\n') self.idx += 1;
        return self.buf[start..end];
    }
};
