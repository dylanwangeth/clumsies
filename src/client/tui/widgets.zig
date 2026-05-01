const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("theme.zig");

const draw = @import("widgets/draw.zig");
const chart = @import("widgets/chart.zig");
const badge = @import("widgets/badge.zig");
const panel = @import("widgets/panel.zig");
const drawer = @import("widgets/drawer.zig");
const fixed_split = @import("widgets/fixed_split.zig");
const cursor = @import("widgets/cursor.zig");
const empty_state = @import("widgets/empty_state.zig");
const modal_mod = @import("widgets/modal.zig");
const text_input = @import("widgets/text_input.zig");
const content_view = @import("widgets/content_view.zig");
const system_notice = @import("widgets/system_notice.zig");
const table_row = @import("widgets/table_row.zig");
const surface_size = @import("widgets/surface_size.zig");
const diff_viewer = @import("widgets/diff_viewer.zig");

pub const fillSurface = draw.fillSurface;
pub const paintBand = draw.paintBand;
pub const drawBorder = draw.drawBorder;
pub const writeText = draw.writeText;
pub const writeRightText = draw.writeRightText;
pub const writeHeaderRightIfFits = draw.writeHeaderRightIfFits;
pub const writeKv = draw.writeKv;
pub const writeSectionHeader = draw.writeSectionHeader;
pub const writeCursorMarker = draw.writeCursorMarker;

pub const drawBrailleAreaChart = chart.drawBrailleAreaChart;

pub const Badge = badge.Badge;
pub const badgeTopLevel = badge.badgeTopLevel;
pub const badgeInnerTab = badge.badgeInnerTab;
pub const drawFilledBadge = badge.drawFilledBadge;
pub const drawTabBadge = badge.drawTabBadge;
pub const drawInnerTabBadge = badge.drawInnerTabBadge;

pub const SurfaceWidget = panel.SurfaceWidget;
pub const WidgetBox = panel.WidgetBox;
pub const Panel = panel.Panel;
pub const Drawer = drawer.Drawer;

pub const splitHorizontal = fixed_split.splitHorizontal;
pub const FixedSplit = fixed_split.FixedSplit;

pub const initCursorScrollBars = cursor.initCursorScrollBars;
pub const initPlainScrollBars = cursor.initPlainScrollBars;
pub const applyCursorOverlay = cursor.applyCursorOverlay;
pub const cursorDown = cursor.cursorDown;
pub const cursorUp = cursor.cursorUp;
pub const handleCursorKeys = cursor.handleCursorKeys;
pub const handleGridKeys = cursor.handleGridKeys;

pub const EmptyState = empty_state.EmptyState;
pub const drawEmptyState = empty_state.drawEmptyState;

pub const Anchor = modal_mod.Anchor;
pub const Modal = modal_mod.Modal;

pub const TextInputResult = text_input.TextInputResult;
pub const TextInput = text_input.TextInput;
pub const ContentView = content_view.ContentView;
pub const SystemNoticeQueue = system_notice.Queue;
pub const SystemNotice = system_notice.Notice;
pub const SystemNoticeKind = system_notice.Kind;
pub const SystemNoticePersistence = system_notice.Persistence;
pub const SystemNoticeKey = system_notice.Key;
pub const systemNoticeHeaderStyle = system_notice.headerStyle;
pub const TableRow = table_row.TableRow;
pub const Column = table_row.Column;
pub const sanitizeSurfaceSize = surface_size.sanitize;
pub const computeDiffLines = diff_viewer.computeDiffLines;

pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    return 1 + std.mem.count(u8, text, "\n");
}

pub fn formatShortTimestamp(arena: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len < 10) return arena.dupe(u8, trimmed);
    if (trimmed.len >= 16 and (trimmed[10] == 'T' or trimmed[10] == ' ')) {
        return std.fmt.allocPrint(arena, "{s} {s}", .{ trimmed[0..10], trimmed[11..16] });
    }
    return arena.dupe(u8, trimmed[0..10]);
}

pub fn draftRowStyle(selected: bool, draft_status: anytype) vaxis.Style {
    const fg = if (draft_status != null)
        theme.draftStatusColor(draft_status.?)
    else if (selected)
        theme.TEXT
    else
        theme.TEXT_SOFT;
    return if (selected) theme.boldOn(theme.PANEL, fg) else theme.fg(fg);
}

pub fn writeDraftMarker(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    col: u16,
    row: u16,
    name: []const u8,
    has_draft: bool,
    style: vaxis.Style,
) void {
    writeText(surface, ctx, col, row, name, style);
    if (has_draft) {
        const nw: u16 = @intCast(ctx.stringWidth(name));
        writeText(surface, ctx, col + nw + 1, row, "*", style);
    }
}

test "focusBorder returns ACCENT when focused" {
    try std.testing.expectEqual(theme.ACCENT, theme.focusBorder(true));
    try std.testing.expectEqual(theme.BORDER, theme.focusBorder(false));
}

test "draftRowStyle uses draft color when draft present" {
    const DraftStatus = @import("../drafts.zig").DraftStatus;
    const style = draftRowStyle(true, @as(?DraftStatus, .editing));
    try std.testing.expectEqual(theme.WARN, style.fg);
    try std.testing.expectEqual(theme.PANEL, style.bg);
    try std.testing.expect(style.bold);
}

test "draftRowStyle uses TEXT when selected without draft" {
    const style = draftRowStyle(true, @as(?@import("../drafts.zig").DraftStatus, null));
    try std.testing.expectEqual(theme.TEXT, style.fg);
    try std.testing.expect(style.bold);
}

test "draftRowStyle uses TEXT_SOFT when unselected without draft" {
    const style = draftRowStyle(false, @as(?@import("../drafts.zig").DraftStatus, null));
    try std.testing.expectEqual(theme.TEXT_SOFT, style.fg);
    try std.testing.expect(!style.bold);
}

test {
    _ = @import("widgets/draw.zig");
    _ = @import("widgets/chart.zig");
    _ = @import("widgets/badge.zig");
    _ = @import("widgets/panel.zig");
    _ = @import("widgets/drawer.zig");
    _ = @import("widgets/fixed_split.zig");
    _ = @import("widgets/cursor.zig");
    _ = @import("widgets/empty_state.zig");
    _ = @import("widgets/modal.zig");
    _ = @import("widgets/text_input.zig");
    _ = @import("widgets/diff_viewer.zig");
    _ = @import("widgets/content_view.zig");
    _ = @import("widgets/system_notice.zig");
}
