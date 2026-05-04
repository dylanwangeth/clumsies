const vaxis = @import("vaxis");

pub fn rgb(hex: u24) vaxis.Color {
    return vaxis.Color.rgbFromUint(hex);
}

pub fn style(foreground: vaxis.Color, background: vaxis.Color) vaxis.Style {
    return .{ .fg = foreground, .bg = background };
}

pub fn textOn(background: vaxis.Color, foreground: vaxis.Color) vaxis.Style {
    return .{ .fg = foreground, .bg = background };
}

pub fn boldOn(background: vaxis.Color, foreground: vaxis.Color) vaxis.Style {
    return .{ .fg = foreground, .bg = background, .bold = true };
}

// Default styles: foreground color on PANEL background.
// Use instead of raw .{ .fg = color } to prevent terminal black bg.
pub fn fg(color: vaxis.Color) vaxis.Style {
    return .{ .fg = color, .bg = PANEL };
}

pub fn fgBold(color: vaxis.Color) vaxis.Style {
    return .{ .fg = color, .bg = PANEL, .bold = true };
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
pub const ACCENT_PR = GOLD;
pub const ACCENT_WORKSPACE = rgb(0xb3ba73);
pub const ACCENT_INSIGHTS = rgb(0xe7b868);

// Semantic status
pub const OK = rgb(0xa9bf6f);
pub const WARN = rgb(0xe0b14b);
pub const DANGER = rgb(0xd3745a);
pub const INFO = rgb(0xe7b868);
pub const MERGED = rgb(0x8957e5);

/// Foreground color for a draft marker (and the row name when a row
/// has a draft), keyed by draft status. Kept in this file so every
/// renderer — Artifact Files rows, Workspace list rows — maps the
/// same status onto the same hue. See `design/12_CONTENT_EDITING.md`
/// for the spec.
pub fn draftStatusColor(status: anytype) vaxis.Color {
    return switch (status) {
        .draft => WARN,
        .in_review => ACCENT,
        .applied => MERGED,
        .declined => DANGER,
        .conflicted => DANGER,
    };
}

pub const CANVAS_CELL: vaxis.Cell = .{
    .char = .{ .grapheme = " ", .width = 1 },
    .style = style(TEXT, CANVAS),
};

pub fn lerpColor(a: vaxis.Color, b: vaxis.Color, t: f32) vaxis.Color {
    const a_rgb = switch (a) {
        .rgb => |v| v,
        else => [3]u8{ 0, 0, 0 },
    };
    const b_rgb = switch (b) {
        .rgb => |v| v,
        else => [3]u8{ 0, 0, 0 },
    };
    const inv = 1.0 - t;
    return .{
        .rgb = .{
            @intFromFloat(@as(f32, @floatFromInt(a_rgb[0])) * inv + @as(f32, @floatFromInt(b_rgb[0])) * t),
            @intFromFloat(@as(f32, @floatFromInt(a_rgb[1])) * inv + @as(f32, @floatFromInt(b_rgb[1])) * t),
            @intFromFloat(@as(f32, @floatFromInt(a_rgb[2])) * inv + @as(f32, @floatFromInt(b_rgb[2])) * t),
        },
    };
}

pub fn blank(bg: vaxis.Color) vaxis.Cell {
    return .{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .fg = TEXT, .bg = bg },
    };
}

pub fn focusBorder(has_focus: bool) vaxis.Color {
    return if (has_focus) ACCENT else BORDER;
}
