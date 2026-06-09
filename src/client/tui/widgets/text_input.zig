const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");

pub const TextInputResult = enum {
    consumed,
    submit,
    cancel,
    ignored,
};

pub const TextInput = struct {
    buf: []u8,
    len: *usize,
    cursor: u16 = 0,
    bg: vaxis.Color = theme.PANEL_ALT,

    pub fn handleKey(self: *TextInput, key: vaxis.Key) TextInputResult {
        if (key.matches(vaxis.Key.enter, .{})) return .submit;
        if (key.matches(vaxis.Key.escape, .{})) return .cancel;

        if (key.matches(vaxis.Key.backspace, .{})) return self.backspace();
        if (key.matches(vaxis.Key.delete, .{})) return self.deleteForward();
        if (key.matches(vaxis.Key.left, .{})) return self.moveCursorLeft();
        if (key.matches(vaxis.Key.right, .{})) return self.moveCursorRight();
        if (key.matches(vaxis.Key.home, .{})) return self.moveCursorHome();
        if (key.matches(vaxis.Key.end, .{})) return self.moveCursorEnd();

        if (key.text) |text| {
            _ = self.insertText(text);
            return .consumed;
        } else if (key.codepoint >= 0x20 and key.codepoint < 0x7f) {
            const byte: u8 = @intCast(key.codepoint);
            _ = self.insertText(&[_]u8{byte});
            return .consumed;
        }

        return .ignored;
    }

    fn backspace(self: *TextInput) TextInputResult {
        if (self.cursor == 0) return .consumed;
        const before = self.buf[0..self.cursor];
        const gl = lastGraphemeLen(before) orelse return .consumed;
        const start: u16 = self.cursor - gl;
        std.mem.copyForwards(u8, self.buf[start..], self.buf[self.cursor..self.len.*]);
        self.len.* -= gl;
        self.cursor = start;
        return .consumed;
    }

    fn deleteForward(self: *TextInput) TextInputResult {
        if (self.cursor >= self.len.*) return .consumed;
        const after = self.buf[self.cursor..self.len.*];
        const gl = firstGraphemeLen(after) orelse return .consumed;
        std.mem.copyForwards(u8, self.buf[self.cursor..], self.buf[self.cursor + gl .. self.len.*]);
        self.len.* -= gl;
        return .consumed;
    }

    fn moveCursorLeft(self: *TextInput) TextInputResult {
        if (self.cursor == 0) return .consumed;
        const before = self.buf[0..self.cursor];
        const gl = lastGraphemeLen(before) orelse return .consumed;
        self.cursor -= gl;
        return .consumed;
    }

    fn moveCursorRight(self: *TextInput) TextInputResult {
        if (self.cursor >= self.len.*) return .consumed;
        const after = self.buf[self.cursor..self.len.*];
        const gl = firstGraphemeLen(after) orelse return .consumed;
        self.cursor += gl;
        return .consumed;
    }

    fn moveCursorHome(self: *TextInput) TextInputResult {
        self.cursor = 0;
        return .consumed;
    }

    fn moveCursorEnd(self: *TextInput) TextInputResult {
        self.cursor = @intCast(self.len.*);
        return .consumed;
    }

    fn insertText(self: *TextInput, text: []const u8) bool {
        const n: u16 = @intCast(text.len);
        if (self.len.* + n > self.buf.len) return false;
        var i: u16 = @intCast(self.len.* + n);
        while (i > self.cursor + n) {
            i -= 1;
            self.buf[i] = self.buf[i - n];
        }
        @memcpy(self.buf[self.cursor..][0..text.len], text);
        self.cursor += n;
        self.len.* += n;
        return true;
    }

    pub fn drawOnSurface(
        self: *const TextInput,
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        col: u16,
        row: u16,
        max_width: u16,
    ) void {
        const text = self.buf[0..self.len.*];
        drawValueAt(surface, ctx, col, row, max_width, text, self.bg, theme.TEXT, true, self.cursor);
    }

    pub fn clear(self: *TextInput) void {
        self.cursor = 0;
        self.len.* = 0;
    }

    pub fn content(self: *const TextInput) []const u8 {
        return self.buf[0..self.len.*];
    }
};

pub fn drawValue(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    col: u16,
    row: u16,
    max_width: u16,
    text: []const u8,
    bg: vaxis.Color,
    fg: vaxis.Color,
    focused: bool,
) void {
    if (max_width == 0) return;
    const visible = trailingTextForWidth(ctx, text, max_width -| 1);
    d.writeText(surface, ctx, col, row, visible, .{ .fg = fg, .bg = bg });
    if (focused) {
        const visible_width: u16 = @intCast(ctx.stringWidth(visible));
        const cursor_col = @min(col + visible_width, surface.size.width -| 1);
        surface.cursor = .{
            .row = row,
            .col = cursor_col,
            .shape = .block_blink,
        };
    }
}

pub fn drawValueAt(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    col: u16,
    row: u16,
    max_width: u16,
    text: []const u8,
    bg: vaxis.Color,
    fg: vaxis.Color,
    focused: bool,
    cursor_byte: u16,
) void {
    if (max_width == 0) return;
    const visible = trailingTextForWidth(ctx, text, max_width -| 1);
    d.writeText(surface, ctx, col, row, visible, .{ .fg = fg, .bg = bg });
    if (focused) {
        const text_len: u16 = @intCast(text.len);
        const visible_len: u16 = @intCast(visible.len);
        const visible_start = text_len - visible_len;
        if (cursor_byte > visible_start) {
            const visible_cursor = cursor_byte - visible_start;
            const clamped = @min(visible_cursor, visible_len);
            const cursor_width: u16 = @intCast(ctx.stringWidth(visible[0..clamped]));
            const cursor_col = @min(col + cursor_width, surface.size.width -| 1);
            surface.cursor = .{ .row = row, .col = cursor_col, .shape = .block_blink };
        } else {
            surface.cursor = .{ .row = row, .col = col, .shape = .block_blink };
        }
    }
}

pub fn drawSlot(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    col: u16,
    row: u16,
    max_width: u16,
    text: []const u8,
    fg: vaxis.Color,
    focused: bool,
) void {
    const bg = if (focused) theme.PANEL else theme.PANEL_ALT;
    paintSlot(surface, col -| 1, row, max_width +| 1, bg);
    drawValue(surface, ctx, col, row, max_width, text, bg, fg, focused);
}

fn paintSlot(surface: *vxfw.Surface, col: u16, row: u16, width: u16, bg: vaxis.Color) void {
    var i: u16 = 0;
    while (i < width and col + i < surface.size.width -| 1 and row < surface.size.height) : (i += 1) {
        surface.writeCell(col + i, row, theme.blank(bg));
    }
}

pub fn trailingTextForWidth(ctx: vxfw.DrawContext, text: []const u8, max_width: u16) []const u8 {
    if (max_width == 0 or text.len == 0) return "";
    if (ctx.stringWidth(text) <= max_width) return text;

    var start: usize = text.len;
    while (start > 0) {
        start -= 1;
        while (start > 0 and (text[start] & 0xc0) == 0x80) : (start -= 1) {}
        if (ctx.stringWidth(text[start..]) > max_width) {
            const seq_len: usize = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
            const next = start + seq_len;
            return text[@min(next, text.len)..];
        }
    }
    return text[start..];
}

fn firstGraphemeLen(s: []const u8) ?u8 {
    if (s.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    return @intCast(@min(len, s.len));
}

fn lastGraphemeLen(s: []const u8) ?u8 {
    if (s.len == 0) return null;
    var i: usize = s.len - 1;
    while (i > 0 and (s[i] & 0xc0) == 0x80) : (i -= 1) {}
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return @intCast(@min(s.len - i, len));
}

test "insert and backspace ASCII" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var input = TextInput{ .buf = &buf, .len = &len };
    try std.testing.expectEqual(TextInputResult.consumed, input.handleKey(vaxis.Key{ .codepoint = 'a' }));
    try std.testing.expectEqualStrings("a", input.content());
    try std.testing.expectEqual(TextInputResult.consumed, input.handleKey(vaxis.Key{ .codepoint = 'b' }));
    try std.testing.expectEqualStrings("ab", input.content());
    try std.testing.expectEqual(TextInputResult.consumed, input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqualStrings("a", input.content());
}

test "submit and cancel" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var input = TextInput{ .buf = &buf, .len = &len };
    try std.testing.expectEqual(TextInputResult.submit, input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.enter }));
    try std.testing.expectEqual(TextInputResult.cancel, input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.escape }));
}

test "clear resets length and cursor" {
    var buf: [16]u8 = undefined;
    var len: usize = 5;
    var input = TextInput{ .buf = &buf, .len = &len, .cursor = 2 };
    input.clear();
    try std.testing.expectEqual(@as(usize, 0), len);
    try std.testing.expectEqual(@as(u16, 0), input.cursor);
}

test "cursor moves with arrows" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var input = TextInput{ .buf = &buf, .len = &len };
    _ = input.handleKey(vaxis.Key{ .codepoint = 'a' });
    _ = input.handleKey(vaxis.Key{ .codepoint = 'b' });
    _ = input.handleKey(vaxis.Key{ .codepoint = 'c' });
    try std.testing.expectEqual(@as(u16, 3), input.cursor);
    try std.testing.expectEqual(TextInputResult.consumed, input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.left }));
    try std.testing.expectEqual(@as(u16, 2), input.cursor);
    try std.testing.expectEqual(TextInputResult.consumed, input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(@as(u16, 3), input.cursor);
}

test "backspace at mid-cursor position" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var input = TextInput{ .buf = &buf, .len = &len };
    _ = input.handleKey(vaxis.Key{ .codepoint = 'a' });
    _ = input.handleKey(vaxis.Key{ .codepoint = 'b' });
    _ = input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.left });
    try std.testing.expectEqual(@as(u16, 1), input.cursor);
    _ = input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.backspace });
    try std.testing.expectEqualStrings("b", input.content());
    try std.testing.expectEqual(@as(u16, 0), input.cursor);
}

test "home and end" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var input = TextInput{ .buf = &buf, .len = &len };
    _ = input.handleKey(vaxis.Key{ .codepoint = 'a' });
    _ = input.handleKey(vaxis.Key{ .codepoint = 'b' });
    try std.testing.expectEqual(TextInputResult.consumed, input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.home }));
    try std.testing.expectEqual(@as(u16, 0), input.cursor);
    try std.testing.expectEqual(TextInputResult.consumed, input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.end }));
    try std.testing.expectEqual(@as(u16, 2), input.cursor);
}

test "delete forward" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var input = TextInput{ .buf = &buf, .len = &len };
    _ = input.handleKey(vaxis.Key{ .codepoint = 'a' });
    _ = input.handleKey(vaxis.Key{ .codepoint = 'b' });
    _ = input.handleKey(vaxis.Key{ .codepoint = 'c' });
    _ = input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.home });
    _ = input.handleKey(vaxis.Key{ .codepoint = vaxis.Key.delete });
    try std.testing.expectEqualStrings("bc", input.content());
}
