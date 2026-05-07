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
    bg: vaxis.Color = theme.PANEL_ALT,

    pub fn handleKey(self: *TextInput, key: vaxis.Key) TextInputResult {
        if (key.matches(vaxis.Key.enter, .{})) return .submit;
        if (key.matches(vaxis.Key.escape, .{})) return .cancel;
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.len.* > 0) self.len.* -= 1;
            return .consumed;
        }
        if (key.text) |text| {
            if (self.len.* + text.len <= self.buf.len) {
                @memcpy(self.buf[self.len.*..][0..text.len], text);
                self.len.* += text.len;
                return .consumed;
            }
        } else if (key.codepoint >= 0x20 and key.codepoint < 0x7f) {
            if (self.len.* < self.buf.len) {
                self.buf[self.len.*] = @intCast(key.codepoint);
                self.len.* += 1;
                return .consumed;
            }
        }
        return .ignored;
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
        drawValue(surface, ctx, col, row, max_width, text, self.bg, theme.TEXT, true);
    }

    pub fn clear(self: *TextInput) void {
        self.len.* = 0;
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

test "TextInput handleKey appends printable characters" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var input = TextInput{ .buf = &buf, .len = &len };
    const key_a = vaxis.Key{ .codepoint = 'a' };
    try std.testing.expectEqual(TextInputResult.consumed, input.handleKey(key_a));
    try std.testing.expectEqual(@as(usize, 1), len);
    try std.testing.expectEqual(@as(u8, 'a'), buf[0]);
}

test "TextInput handleKey reports submit on Enter" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var input = TextInput{ .buf = &buf, .len = &len };
    const key_enter = vaxis.Key{ .codepoint = vaxis.Key.enter };
    try std.testing.expectEqual(TextInputResult.submit, input.handleKey(key_enter));
}

test "TextInput handleKey reports cancel on Esc" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var input = TextInput{ .buf = &buf, .len = &len };
    const key_esc = vaxis.Key{ .codepoint = vaxis.Key.escape };
    try std.testing.expectEqual(TextInputResult.cancel, input.handleKey(key_esc));
}

test "TextInput clear resets length" {
    var buf: [16]u8 = undefined;
    var len: usize = 5;
    var input = TextInput{ .buf = &buf, .len = &len };
    input.clear();
    try std.testing.expectEqual(@as(usize, 0), len);
}
