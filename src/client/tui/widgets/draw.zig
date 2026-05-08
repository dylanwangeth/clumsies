const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");

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

// Write text with an explicit width budget so panel content cannot
// overwrite borders or neighboring fields.
pub fn writeTextMax(surface: *vxfw.Surface, ctx: vxfw.DrawContext, col: u16, row: u16, max_width: u16, text: []const u8, s: vaxis.Style) void {
    var cursor = col;
    const right = col +| max_width;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (cursor >= surface.size.width or cursor >= right or row >= surface.size.height) break;
        const bytes = grapheme.bytes(text);
        if (std.mem.eql(u8, bytes, "\n")) break;
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        if (width == 0 or cursor + width > surface.size.width or cursor + width > right) break;
        surface.writeCell(cursor, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = s,
        });
        cursor += width;
    }
}

/// Write text across multiple rows within an explicit width budget.
/// Returns the row after the last rendered line.
pub fn writeWrappedTextMax(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    col: u16,
    row: u16,
    max_width: u16,
    max_lines: u16,
    text: []const u8,
    s: vaxis.Style,
) u16 {
    if (max_width == 0 or max_lines == 0) return row;

    var out_row = row;
    var rest = text;
    var lines_left = max_lines;
    while (rest.len > 0 and lines_left > 0 and out_row < surface.size.height -| 1) {
        const line_len = wrappedLineLen(ctx, rest, max_width);
        if (line_len == 0) break;
        writeTextMax(surface, ctx, col, out_row, max_width, rest[0..line_len], s);
        rest = trimLeadingSpaces(rest[line_len..]);
        out_row += 1;
        lines_left -= 1;
    }
    return out_row;
}

pub fn wrappedLineLen(ctx: vxfw.DrawContext, text: []const u8, max_width: u16) usize {
    var iter = ctx.graphemeIterator(text);
    var byte_len: usize = 0;
    var width: u16 = 0;
    var last_space: usize = 0;
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const grapheme_width: u16 = @intCast(ctx.stringWidth(bytes));
        if (std.mem.eql(u8, bytes, "\n")) return byte_len;
        if (width + grapheme_width > max_width) {
            if (last_space > 0) return last_space;
            return if (byte_len > 0) byte_len else bytes.len;
        }
        byte_len += bytes.len;
        width += grapheme_width;
        if (bytes.len == 1 and bytes[0] == ' ') last_space = byte_len - 1;
    }
    return text.len;
}

pub fn trimLeadingSpaces(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    return text[i..];
}

// Write text right-aligned on a given row.
pub fn writeRightText(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, text: []const u8, s: vaxis.Style) void {
    const width: u16 = @intCast(ctx.stringWidth(text));
    if (width >= surface.size.width) return;
    writeText(surface, ctx, surface.size.width - width - 1, row, text, s);
}

/// Write right-aligned text if it fits without overlapping min_col.
/// Returns true if the text was written.
pub fn writeHeaderRightIfFits(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    row: u16,
    min_col: u16,
    text: []const u8,
    style: vaxis.Style,
) bool {
    const width: u16 = @intCast(ctx.stringWidth(text));
    if (width == 0 or width >= surface.size.width) return false;
    const start_col = surface.size.width - width - 1;
    if (start_col <= min_col) return false;
    writeText(surface, ctx, start_col, row, text, style);
    return true;
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

/// Draw the ▌ cursor marker at (col, row) on an existing surface.
pub fn writeCursorMarker(surface: *vxfw.Surface, col: u16, row: u16) void {
    if (col >= surface.size.width or row >= surface.size.height) return;
    surface.writeCell(col, row, .{
        .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
        .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
    });
}
