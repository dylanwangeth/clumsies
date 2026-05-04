const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const draw = @import("draw.zig");

const CAPACITY = 8;
const TRANSIENT_TICKS = 100;
const WIDTH: u16 = 56;
const MIN_WIDTH: u16 = 28;
const MAX_VISIBLE_HEIGHT: u16 = 18;
const CARD_GAP: u16 = 0;

pub const Kind = enum {
    info,
    loading,
    success,
    warning,
    failure,
};

pub const Persistence = enum {
    transient,
    persistent,
};

pub const Key = enum {
    connection,
    operation,
    workspace_context,
    workspace_manifest,
    workspace_context_content,
    workspace_local_cache,
    attestation_upload,
};

pub const Notice = struct {
    key: Key,
    kind: Kind,
    persistence: Persistence,
    text: []const u8,
    created_tick: u64,
};

pub const Queue = struct {
    notices: [CAPACITY]Notice = undefined,
    count: usize = 0,
    current_tick: u64 = 0,

    pub fn tick(self: *Queue) void {
        self.current_tick +%= 1;
    }

    pub fn now(self: *const Queue) u64 {
        return self.current_tick;
    }

    pub fn push(
        self: *Queue,
        key: Key,
        kind: Kind,
        persistence: Persistence,
        text: []const u8,
    ) void {
        const notice = Notice{
            .key = key,
            .kind = kind,
            .persistence = persistence,
            .text = text,
            .created_tick = self.current_tick,
        };
        if (coalescesByKey(key)) {
            for (0..self.count) |i| {
                if (self.notices[i].key == key) {
                    self.notices[i] = notice;
                    return;
                }
            }
        }
        if (self.count < self.notices.len) {
            self.notices[self.count] = notice;
            self.count += 1;
        } else {
            for (self.notices[0 .. self.notices.len - 1], 0..) |_, i| {
                self.notices[i] = self.notices[i + 1];
            }
            self.notices[self.notices.len - 1] = notice;
        }
    }

    pub fn clear(self: *Queue, key: Key) void {
        var write_idx: usize = 0;
        for (0..self.count) |read_idx| {
            if (self.notices[read_idx].key == key) continue;
            if (write_idx != read_idx) self.notices[write_idx] = self.notices[read_idx];
            write_idx += 1;
        }
        self.count = write_idx;
    }

    pub fn pruneExpired(self: *Queue) void {
        var write_idx: usize = 0;
        for (0..self.count) |read_idx| {
            const notice = self.notices[read_idx];
            if (notice.persistence == .transient and
                self.current_tick -| notice.created_tick >= TRANSIENT_TICKS)
            {
                continue;
            }
            if (write_idx != read_idx) self.notices[write_idx] = notice;
            write_idx += 1;
        }
        self.count = write_idx;
    }

    pub fn hasVisible(self: *Queue) bool {
        self.pruneExpired();
        return self.count > 0;
    }

    pub fn overlaySize(self: *Queue, ctx: vxfw.DrawContext, max_size: vxfw.Size) vxfw.Size {
        self.pruneExpired();
        const width = @min(WIDTH, max_size.width -| 4);
        if (width < MIN_WIDTH or max_size.height < 3 or self.count == 0) return .{ .width = 0, .height = 0 };

        var height: u16 = 0;
        for (0..self.count) |i| {
            const card_h = noticeHeight(ctx, self.notices[i], width);
            const next_h = if (height == 0) card_h else height + CARD_GAP + card_h;
            if (next_h > max_size.height -| 2 or next_h > MAX_VISIBLE_HEIGHT) break;
            height = next_h;
        }
        if (height == 0) height = @min(@as(u16, 3), max_size.height);
        return .{ .width = width, .height = height };
    }

    pub fn drawOverlay(
        self: *Queue,
        owner: vxfw.Widget,
        ctx: vxfw.DrawContext,
    ) std.mem.Allocator.Error!vxfw.Surface {
        self.pruneExpired();
        var surface = try vxfw.Surface.init(ctx.arena, owner, ctx.max.size());
        draw.fillSurface(&surface, theme.PANEL);

        var out_row: u16 = 1;
        var shown: usize = 0;
        for (0..self.count) |i| {
            const notice = self.notices[i];
            const card_h = noticeHeight(ctx, notice, ctx.max.width.?);
            if (out_row + card_h > ctx.max.height.? + 1) break;
            try drawNoticeCard(&surface, ctx, out_row - 1, card_h, notice);
            shown += 1;
            out_row += card_h + CARD_GAP;
        }
        if (self.count > shown and out_row <= ctx.max.height.?) {
            const more = try std.fmt.allocPrint(ctx.arena, "+{d} more", .{self.count - shown});
            draw.writeText(&surface, ctx, 2, out_row - 1, more, theme.textOn(theme.PANEL, theme.MUTED));
        }
        return surface;
    }
};

fn coalescesByKey(key: Key) bool {
    return key != .operation;
}

pub fn headerStyle(kind: Kind) vaxis.Style {
    return switch (kind) {
        .info, .loading, .success, .warning, .failure => .{ .fg = theme.PANEL, .bg = theme.ACCENT, .bold = true },
    };
}

fn overlayStyle(kind: Kind) vaxis.Style {
    return switch (kind) {
        .info => theme.textOn(theme.HEADER, theme.INFO),
        .loading => theme.textOn(theme.HEADER, theme.ACCENT_SOFT),
        .success => theme.textOn(theme.HEADER, theme.OK),
        .warning => theme.textOn(theme.HEADER, theme.WARN),
        .failure => theme.textOn(theme.HEADER, theme.DANGER),
    };
}

fn label(kind: Kind) []const u8 {
    return switch (kind) {
        .info => "INFO",
        .loading => "LOAD",
        .success => "OK",
        .warning => "WARN",
        .failure => "ERR",
    };
}

fn noticeHeight(ctx: vxfw.DrawContext, notice: Notice, width: u16) u16 {
    const inner_w = width -| 4;
    const body_w = inner_w -| @as(u16, @intCast(label(notice.kind).len + 1));
    return 2 + @as(u16, @intCast(wrappedLineCount(ctx, notice.text, @max(@as(u16, 1), body_w))));
}

fn drawNoticeCard(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    row: u16,
    height: u16,
    notice: Notice,
) !void {
    const bg = theme.HEADER;
    const frame = frameColor(notice.kind);
    const node = statusColor(notice.kind);
    fillRect(surface, row, height, bg);
    drawNoticeFrame(surface, row, height, frame, node, bg);

    const label_text = label(notice.kind);
    draw.writeText(surface, ctx, 2, row + 1, label_text, overlayStyle(notice.kind));
    const label_w: u16 = @intCast(ctx.stringWidth(label_text));
    const text_col = 2 + label_w + 1;
    const text_w = surface.size.width -| text_col -| 2;
    var text_row = row + 1;
    var rest = notice.text;
    while (rest.len > 0 and text_row < row + height - 1) : (text_row += 1) {
        const consumed = wrapBytesForWidth(ctx, rest, @max(@as(u16, 1), text_w));
        draw.writeText(surface, ctx, text_col, text_row, rest[0..consumed], theme.textOn(bg, theme.TEXT_SOFT));
        rest = rest[consumed..];
    }
}

fn fillRect(surface: *vxfw.Surface, row: u16, height: u16, bg: vaxis.Color) void {
    var y = row;
    while (y < row + height and y < surface.size.height) : (y += 1) {
        var x: u16 = 0;
        while (x < surface.size.width) : (x += 1) {
            surface.writeCell(x, y, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .fg = theme.TEXT, .bg = bg },
            });
        }
    }
}

fn drawNoticeFrame(
    surface: *vxfw.Surface,
    row: u16,
    height: u16,
    frame_fg: vaxis.Color,
    node_fg: vaxis.Color,
    bg: vaxis.Color,
) void {
    if (height < 2 or row >= surface.size.height) return;
    const right = surface.size.width -| 1;
    const bottom = @min(row + height - 1, surface.size.height - 1);
    const style = vaxis.Style{ .fg = frame_fg, .bg = bg, .bold = true };
    const node_style = vaxis.Style{ .fg = node_fg, .bg = bg, .bold = true };

    surface.writeCell(0, row, .{ .char = .{ .grapheme = "╭", .width = 1 }, .style = style });
    surface.writeCell(right, row, .{ .char = .{ .grapheme = "○", .width = 1 }, .style = node_style });
    surface.writeCell(0, bottom, .{ .char = .{ .grapheme = "╰", .width = 1 }, .style = style });
    surface.writeCell(right, bottom, .{ .char = .{ .grapheme = "╯", .width = 1 }, .style = style });

    var x: u16 = 1;
    while (x < right) : (x += 1) {
        surface.writeCell(x, row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
        surface.writeCell(x, bottom, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
    }
    var y = row + 1;
    while (y < bottom) : (y += 1) {
        surface.writeCell(0, y, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style });
        surface.writeCell(right, y, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style });
    }
}

fn frameColor(kind: Kind) vaxis.Color {
    return switch (kind) {
        .info, .loading, .success => theme.ACCENT_SOFT,
        .warning => theme.WARN,
        .failure => theme.DANGER,
    };
}

fn statusColor(kind: Kind) vaxis.Color {
    return switch (kind) {
        .info => theme.INFO,
        .loading => theme.ACCENT_SOFT,
        .success => theme.GOLD,
        .warning => theme.WARN,
        .failure => theme.DANGER,
    };
}

fn wrappedLineCount(ctx: vxfw.DrawContext, text: []const u8, max_width: u16) usize {
    if (text.len == 0) return 1;
    var count: usize = 0;
    var rest = text;
    while (rest.len > 0) {
        const consumed = wrapBytesForWidth(ctx, rest, max_width);
        rest = rest[consumed..];
        count += 1;
    }
    return count;
}

fn wrapBytesForWidth(ctx: vxfw.DrawContext, text: []const u8, max_width: u16) usize {
    if (text.len == 0) return 0;
    var iter = ctx.graphemeIterator(text);
    var width: u16 = 0;
    var last_end: usize = 0;
    while (iter.next()) |item| {
        const grapheme = item.bytes(text);
        if (std.mem.eql(u8, grapheme, "\n")) return if (last_end > 0) last_end else grapheme.len;
        const grapheme_w: u16 = @intCast(ctx.stringWidth(grapheme));
        if (width + grapheme_w > max_width) {
            return if (last_end > 0) last_end else grapheme.len;
        }
        width += grapheme_w;
        last_end += grapheme.len;
    }
    return text.len;
}

test "system notices coalesce keyed status updates" {
    var queue: Queue = .{};

    queue.push(.workspace_manifest, .loading, .persistent, "Loading manifest");
    queue.push(.workspace_manifest, .failure, .persistent, "Manifest failed");

    try std.testing.expectEqual(@as(usize, 1), queue.count);
    try std.testing.expectEqual(Key.workspace_manifest, queue.notices[0].key);
    try std.testing.expectEqual(Kind.failure, queue.notices[0].kind);
    try std.testing.expectEqualStrings("Manifest failed", queue.notices[0].text);
}

test "operation notices preserve repeated events" {
    var queue: Queue = .{};

    queue.push(.operation, .warning, .transient, "Draft is not editable.");
    queue.push(.operation, .warning, .transient, "Draft is not editable.");

    try std.testing.expectEqual(@as(usize, 2), queue.count);
    try std.testing.expectEqualStrings("Draft is not editable.", queue.notices[0].text);
    try std.testing.expectEqualStrings("Draft is not editable.", queue.notices[1].text);
}

test "operation notices drop oldest event at capacity" {
    var queue: Queue = .{};
    const labels = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7" };

    var i: usize = 0;
    while (i < CAPACITY) : (i += 1) {
        queue.push(.operation, .info, .transient, labels[i]);
    }
    queue.push(.operation, .success, .transient, "new");

    try std.testing.expectEqual(@as(usize, CAPACITY), queue.count);
    try std.testing.expectEqualStrings("1", queue.notices[0].text);
    try std.testing.expectEqualStrings("new", queue.notices[CAPACITY - 1].text);
    try std.testing.expectEqual(Kind.success, queue.notices[CAPACITY - 1].kind);
}
