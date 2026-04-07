const vaxis = @import("vaxis");

pub fn rgb(hex: u24) vaxis.Color {
    return vaxis.Color.rgbFromUint(hex);
}

pub fn style(fg: vaxis.Color, bg: vaxis.Color) vaxis.Style {
    return .{ .fg = fg, .bg = bg };
}

pub fn textOn(bg: vaxis.Color, fg: vaxis.Color) vaxis.Style {
    return .{ .fg = fg, .bg = bg };
}

pub fn boldOn(bg: vaxis.Color, fg: vaxis.Color) vaxis.Style {
    return .{ .fg = fg, .bg = bg, .bold = true };
}

// Zig-themed warm palette: amber primary on calm dark surfaces.
// Surface hierarchy: CANVAS < HEADER < PANEL < PANEL_ALT < PANEL_SOFT
pub const CANVAS = rgb(0x1a1816);
pub const HEADER = rgb(0x1c1a18);
pub const PANEL = rgb(0x1f1c19);
pub const PANEL_ALT = rgb(0x24201d);
pub const PANEL_SOFT = rgb(0x2c2722);
pub const RAIL = rgb(0x1b1917);
pub const BORDER = rgb(0x5e4b31);
pub const BORDER_MUTED = rgb(0x463929);

// Text tones
pub const TEXT = rgb(0xe7ddd0);
pub const TEXT_SOFT = rgb(0xcdbca8);
pub const MUTED = rgb(0xa08f7b);
pub const DIM = rgb(0x756755);

// Accent colors (Zig amber family)
pub const ACCENT = rgb(0xf7a41d);
pub const ACCENT_SOFT = rgb(0xffcf78);
pub const GOLD = rgb(0xd7a032);
pub const MINT = rgb(0xe8b04a);
pub const CYAN = rgb(0xd08a3c);

// Module accents
pub const ACCENT_LIBRARY = ACCENT;
pub const ACCENT_PROPOSAL = GOLD;
pub const ACCENT_WORKSPACE = rgb(0xb3ba73);
pub const ACCENT_INSIGHTS = rgb(0xe7b868);

// Semantic status
pub const OK = rgb(0xa9bf6f);
pub const WARN = rgb(0xe0b14b);
pub const DANGER = rgb(0xd3745a);
pub const INFO = rgb(0xe7b868);

// Sparkline block characters
pub const SPARKLINE = [8][]const u8{ "\xe2\x96\x81", "\xe2\x96\x82", "\xe2\x96\x83", "\xe2\x96\x84", "\xe2\x96\x85", "\xe2\x96\x86", "\xe2\x96\x87", "\xe2\x96\x88" };

pub const CANVAS_CELL: vaxis.Cell = .{
    .char = .{ .grapheme = " ", .width = 1 },
    .style = style(TEXT, CANVAS),
};

pub fn blank(bg: vaxis.Color) vaxis.Cell {
    return .{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .fg = TEXT, .bg = bg },
    };
}
