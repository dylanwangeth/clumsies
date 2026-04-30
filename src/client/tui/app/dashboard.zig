const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const w = @import("../widgets.zig");
const attestation_reader = @import("../attestation_reader.zig");
const workspace_rule = @import("../../rule.zig");
pub const ARENA_HEIGHT: u16 = 7;
const ROUND_ROW_COUNT = 5;
const ROUND_CURSOR_HEIGHT = ROUND_ROW_COUNT - 1;
const BAR_HEIGHT: u16 = 5;
const BAR_WIDTH: u16 = 2;
const BAR_GAP: u16 = 1;
const TRACE_GUIDE_PREFIX = "         \xe2\x94\x82  ";
const TRACE_USER = theme.rgb(0xc7a0b9);
const TRACE_SETUP = theme.rgb(0x8fa9bf);
const TRACE_LOAD = theme.rgb(0xd7a85a);
const TRACE_REFER = theme.rgb(0xd9905f);
const TRACE_AGENT = theme.OK;
const TRACE_REJECT = theme.DANGER;
const TRACE_DISCOVER = theme.rgb(0x8fb8a5);
const TRACE_DRAFT = theme.rgb(0xb4a36a);
const TRACE_OTHER = theme.TEXT_SOFT;

pub fn drawRoot(
    self: anytype,
    ctx: vxfw.DrawContext,
    arena_surface: vxfw.Surface,
    rounds_surface: vxfw.Surface,
    trace_surface: vxfw.Surface,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.CANVAS);

    const arena_h: u16 = ARENA_HEIGHT;
    const preferred_rounds_w: u16 = @intCast(@divTrunc(@as(u32, size.width) * 38, 100));
    const rounds_w: u16 = @min(size.width, @max(@as(u16, 64), @min(@as(u16, 96), preferred_rounds_w)));

    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = arena_surface };
    children[1] = .{ .origin = .{ .row = arena_h, .col = 0 }, .surface = rounds_surface };
    children[2] = .{ .origin = .{ .row = arena_h, .col = rounds_w }, .surface = trace_surface };
    root.children = children;
    return root;
}

pub const DashboardSummary = struct {
    round_count: usize = 0,
    submitted_count: usize = 0,
    referred_count: usize = 0,
    rejected_count: usize = 0,
    open_count: usize = 0,
    session_count: usize = 0,
    refer_count: usize = 0,
    exception_count: usize = 0,
};

pub fn drawArena(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    summary: DashboardSummary,
    rounds: []const attestation_reader.RoundEvent,
    selected_index: usize,
) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.CANVAS);

    const card_w: u16 = 24;
    const gap: u16 = 1;
    const show_cards = width >= 96;
    const fingerprint_w = if (show_cards) width -| (card_w * 2) -| (gap * 2) else width;

    var children = try ctx.arena.alloc(vxfw.SubSurface, if (show_cards) 3 else 1);
    children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = try drawFingerprintPanel(self, ctx, fingerprint_w, height, rounds, selected_index),
    };
    if (show_cards) {
        children[1] = .{
            .origin = .{ .row = 0, .col = fingerprint_w + gap },
            .surface = try drawRptPanel(self, ctx, card_w, height, summary),
        };
        children[2] = .{
            .origin = .{ .row = 0, .col = fingerprint_w + card_w + gap * 2 },
            .surface = try drawExceptionPanel(self, ctx, card_w, height, summary),
        };
    }
    surface.children = children;
    return surface;
}

fn drawFingerprintPanel(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    rounds: []const attestation_reader.RoundEvent,
    selected_index: usize,
) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.BORDER, theme.PANEL);

    const breath_t: f32 = blk: {
        const phase = self.breathing_phase;
        const half: f32 = if (phase <= 10)
            @as(f32, @floatFromInt(phase)) / 10.0
        else
            @as(f32, @floatFromInt(20 - phase)) / 10.0;
        break :blk 0.3 + half * 0.7;
    };
    const dot_color = theme.lerpColor(theme.rgb(0x2d4a1f), theme.OK, breath_t);
    w.writeText(&surface, ctx, 2, 0, "\u{25cf}", .{ .fg = dot_color, .bg = theme.PANEL });

    w.writeText(&surface, ctx, 3, 0, firstLineTrimmed(" Protocol Fingerprint", width -| 5), theme.boldOn(theme.PANEL, theme.TEXT));

    if (rounds.len == 0) {
        w.writeText(&surface, ctx, 3, 3, "No protocol events captured yet.", theme.fg(theme.MUTED));
        return surface;
    }

    drawProtocolBars(&surface, 3, 1, width -| 6, rounds, selected_index);
    return surface;
}

fn drawRptPanel(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    summary: DashboardSummary,
) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.BORDER, theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "RPT", theme.boldOn(theme.PANEL, theme.ACCENT_SOFT));

    const rpt_tenths = if (summary.round_count == 0)
        0
    else
        @divTrunc(summary.refer_count * 10, summary.round_count);
    const value_txt = try std.fmt.allocPrint(ctx.arena, "{d}.{d}", .{ rpt_tenths / 10, rpt_tenths % 10 });
    drawMetricValue(&surface, ctx, value_txt, theme.ACCENT_SOFT);
    w.writeRightText(&surface, ctx, height -| 1, "refs / turn", theme.fg(theme.MUTED));
    return surface;
}

fn drawExceptionPanel(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    summary: DashboardSummary,
) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.BORDER, theme.PANEL);
    const color = if (summary.exception_count > 0) theme.WARN else theme.MUTED;
    w.writeText(&surface, ctx, 2, 0, "Exception", theme.boldOn(theme.PANEL, color));

    const pct = if (summary.round_count == 0) 0 else @divTrunc(summary.exception_count * 100, summary.round_count);
    const value_txt = try std.fmt.allocPrint(ctx.arena, "{d}%", .{pct});
    drawMetricValue(&surface, ctx, value_txt, color);
    w.writeRightText(&surface, ctx, height -| 1, "exception turns", theme.fg(theme.MUTED));
    return surface;
}

fn drawMetricValue(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    value: []const u8,
    color: vaxis.Color,
) void {
    const inner_width = surface.size.width -| 2;
    const inner_height = surface.size.height -| 2;
    const text = firstLineTrimmed(value, inner_width);
    const text_width: u16 = @intCast(ctx.stringWidth(text));
    const col: u16 = 1 + (inner_width -| text_width) / 2;
    const row: u16 = 1 + inner_height / 2;
    w.writeText(surface, ctx, col, row, text, theme.boldOn(theme.PANEL, color));
}

pub fn isExceptionRound(round: attestation_reader.RoundEvent) bool {
    if (round.missing_user_prompt) return true;
    if (round.reject_count > 0) return true;
    return round.load_count > 0 and round.refer_count == 0;
}

const ProtocolCounts = struct {
    user: u16 = 0,
    setup: u16 = 0,
    discover: u16 = 0,
    load: u16 = 0,
    refer: u16 = 0,
    reject: u16 = 0,
    draft: u16 = 0,
    agent: u16 = 0,
    other: u16 = 0,
};

const ProtocolSegment = struct {
    count: u16,
    color: vaxis.Color,
};

fn drawProtocolBars(
    surface: *vxfw.Surface,
    start_col: u16,
    start_row: u16,
    width: u16,
    rounds: []const attestation_reader.RoundEvent,
    selected_index: usize,
) void {
    const stride = BAR_WIDTH + BAR_GAP;
    const capacity = @as(usize, @intCast(@max(@as(u16, 1), (width + BAR_GAP) / stride)));
    const selected = @min(selected_index, rounds.len - 1);
    const start = if (selected >= capacity) selected - capacity + 1 else 0;
    const end = @min(rounds.len, start + capacity);

    var idx = start;
    while (idx < end) : (idx += 1) {
        const col = start_col + @as(u16, @intCast((idx - start) * stride));
        if (col + BAR_WIDTH > surface.size.width -| 1) break;
        drawProtocolBar(surface, col, start_row, protocolCounts(rounds[idx]));
    }
}

fn drawProtocolBar(
    surface: *vxfw.Surface,
    col: u16,
    row: u16,
    counts: ProtocolCounts,
) void {
    const segments = [_]ProtocolSegment{
        .{ .count = counts.user, .color = TRACE_USER },
        .{ .count = counts.setup, .color = TRACE_SETUP },
        .{ .count = counts.discover, .color = TRACE_DISCOVER },
        .{ .count = counts.load, .color = TRACE_LOAD },
        .{ .count = counts.refer, .color = TRACE_REFER },
        .{ .count = counts.reject, .color = TRACE_REJECT },
        .{ .count = counts.draft, .color = TRACE_DRAFT },
        .{ .count = counts.agent, .color = TRACE_AGENT },
        .{ .count = counts.other, .color = TRACE_OTHER },
    };
    const slot_count: usize = BAR_HEIGHT * BAR_WIDTH;
    var slots: [slot_count]vaxis.Color = undefined;
    fillProtocolSlots(slots[0..], segments[0..]);

    for (slots, 0..) |color, slot| {
        const slot_row: u16 = @intCast(slot / BAR_WIDTH);
        const slot_col: u16 = @intCast(slot % BAR_WIDTH);
        const cell_row = row + (BAR_HEIGHT - 1 - slot_row);
        surface.writeCell(col + slot_col, cell_row, .{
            .char = .{ .grapheme = "\xe2\x96\x88", .width = 1 },
            .style = .{ .fg = color, .bg = theme.PANEL },
        });
    }
}

fn fillProtocolSlots(slots: []vaxis.Color, segments: []const ProtocolSegment) void {
    const total = protocolSegmentTotal(segments);
    if (total == 0) {
        @memset(slots, theme.DIM);
        return;
    }

    var allocated: [9]usize = .{0} ** 9;
    var remainders: [9]usize = .{0} ** 9;
    var assigned: usize = 0;
    for (segments, 0..) |segment, idx| {
        const weighted = @as(usize, segment.count) * slots.len;
        allocated[idx] = weighted / total;
        remainders[idx] = weighted % total;
        assigned += allocated[idx];
    }
    for (segments, 0..) |segment, idx| {
        if (segment.count > 0 and allocated[idx] == 0 and assigned < slots.len) {
            allocated[idx] = 1;
            assigned += 1;
        }
    }
    while (assigned < slots.len) {
        const idx = largestRemainderIndex(segments, remainders);
        allocated[idx] += 1;
        remainders[idx] = 0;
        assigned += 1;
    }

    var out: usize = 0;
    for (segments, 0..) |segment, idx| {
        var n: usize = 0;
        while (n < allocated[idx] and out < slots.len) : (n += 1) {
            slots[out] = segment.color;
            out += 1;
        }
    }
    while (out < slots.len) : (out += 1) slots[out] = theme.DIM;
}

fn largestRemainderIndex(segments: []const ProtocolSegment, remainders: [9]usize) usize {
    var best: usize = 0;
    var best_value: usize = 0;
    for (segments, 0..) |segment, idx| {
        if (segment.count == 0) continue;
        if (remainders[idx] >= best_value) {
            best = idx;
            best_value = remainders[idx];
        }
    }
    return best;
}

fn protocolSegmentTotal(segments: []const ProtocolSegment) usize {
    var total: usize = 0;
    for (segments) |segment| total += segment.count;
    return total;
}

fn protocolCounts(round: attestation_reader.RoundEvent) ProtocolCounts {
    var counts: ProtocolCounts = .{ .user = if (round.missing_user_prompt) 0 else 1 };
    for (round.tools) |tool| {
        if (std.mem.eql(u8, tool.kind, "setup")) {
            counts.setup += 1;
        } else if (std.mem.eql(u8, tool.kind, "discover") or std.mem.eql(u8, tool.kind, "search")) {
            counts.discover += 1;
        } else if (std.mem.eql(u8, tool.kind, "load")) {
            counts.load += 1;
        } else if (std.mem.eql(u8, tool.kind, "refer")) {
            counts.refer += 1;
        } else if (std.mem.eql(u8, tool.kind, "reject")) {
            counts.reject += 1;
        } else if (isProposeTool(tool.kind)) {
            counts.draft += 1;
        } else if (std.mem.eql(u8, tool.kind, "agent_report")) {
            counts.agent += 1;
        } else {
            counts.other += 1;
        }
    }
    return counts;
}

pub fn drawRounds(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    rounds: []const attestation_reader.RoundEvent,
) std.mem.Allocator.Error!vxfw.Surface {
    const border_color = theme.focusBorder(self.analysis_focus == .inputs);
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);

    w.writeText(&surface, ctx, 2, 0, "Rounds", theme.boldOn(theme.PANEL, theme.TEXT));

    if (rounds.len == 0) {
        w.writeText(&surface, ctx, 2, 2, "No interaction rounds captured.", theme.fg(theme.MUTED));
        return surface;
    }

    const body_origin_row: u16 = 1;
    const body_origin_col: u16 = 2;
    const body_h: u16 = height -| body_origin_row -| 1;
    const body_w: u16 = width -| body_origin_col -| 1;
    try syncRoundWidgets(self, ctx, rounds, body_w);
    self.dashboard_round_scroll_bars.scroll_view.draw_cursor = false;
    defer self.dashboard_round_scroll_bars.scroll_view.draw_cursor = true;
    const body_ctx = ctx.withConstraints(
        .{ .width = body_w, .height = body_h },
        .{ .width = body_w, .height = body_h },
    );
    const body = try self.dashboard_round_scroll_bars.widget().draw(body_ctx);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = body_origin_row, .col = body_origin_col }, .surface = body };
    surface.children = children;
    writeDoubleCursorBar(&surface, &self.dashboard_round_scroll_bars.scroll_view, body_origin_row, body_h);

    return surface;
}

fn writeDoubleCursorBar(surface: *vxfw.Surface, scroll_view: *const vxfw.ScrollView, origin_row: u16, height: u16) void {
    const cursor_row = @as(usize, @intCast(scroll_view.cursor));
    const top = @as(usize, @intCast(scroll_view.scroll.top));
    if (cursor_row < top) return;
    const visible_row = cursor_row - top;
    if (visible_row >= height) return;
    const row: u16 = origin_row + @as(u16, @intCast(visible_row));
    var offset: u16 = 0;
    while (offset < ROUND_CURSOR_HEIGHT and visible_row + offset < height) : (offset += 1) {
        w.writeCursorMarker(surface, 1, row + offset);
    }
}

pub fn drawProtocolTrace(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    selected_round: ?attestation_reader.RoundEvent,
) std.mem.Allocator.Error!vxfw.Surface {
    const border_color = theme.focusBorder(self.analysis_focus == .chart);
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Attestation Trail", theme.boldOn(theme.PANEL, theme.TEXT));
    const round = selected_round orelse {
        w.writeText(&surface, ctx, 2, 2, "Select a round to inspect clumsies attestation.", theme.fg(theme.MUTED));
        return surface;
    };

    const inner_w = width -| 5;
    const body_origin_row: u16 = 1;
    const body_origin_col: u16 = 3;
    const body_h: u16 = height -| body_origin_row -| 1;
    const body_w: u16 = inner_w -| 1;
    try syncChainWidgets(self, ctx, round, body_w);
    const body_ctx = ctx.withConstraints(
        .{ .width = body_w, .height = body_h },
        .{ .width = body_w, .height = body_h },
    );
    const body = try self.dashboard_chain_scroll_bars.widget().draw(body_ctx);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = body_origin_row, .col = body_origin_col }, .surface = body };
    surface.children = children;
    return surface;
}

pub fn handleModuleEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
    round_count: usize,
) anyerror!void {
    if (key.matches('F', .{ .shift = true })) {
        self.flushAttestation();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.tab, .{})) {
        self.analysis_focus = switch (self.analysis_focus) {
            .chart => .inputs,
            else => .chart,
        };
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (self.analysis_focus == .inputs) {
            if (round_count > 0 and self.analysis_input_cursor < round_count - 1) {
                self.analysis_input_cursor += 1;
                self.dashboard_chain_cursor = 0;
                resetChainExpansion(self);
                resetScrollView(&self.dashboard_chain_scroll_bars.scroll_view);
            }
            ctx.consumeAndRedraw();
            return;
        }
        if (self.analysis_focus == .chart) {
            self.dashboard_chain_cursor += 1;
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.analysis_focus == .inputs) {
            const old_cursor = self.analysis_input_cursor;
            self.analysis_input_cursor -|= 1;
            if (self.analysis_input_cursor != old_cursor) {
                self.dashboard_chain_cursor = 0;
                resetChainExpansion(self);
                resetScrollView(&self.dashboard_chain_scroll_bars.scroll_view);
            }
            ctx.consumeAndRedraw();
            return;
        }
        if (self.analysis_focus == .chart) {
            self.dashboard_chain_cursor -|= 1;
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (self.analysis_focus == .chart) {
            const idx = @min(self.dashboard_chain_cursor, self.dashboard_chain_expanded_items.len - 1);
            self.dashboard_chain_expanded_items[idx] = !self.dashboard_chain_expanded_items[idx];
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        self.analysis_focus = .chart;
        ctx.consumeAndRedraw();
    }
}

fn resetChainExpansion(self: anytype) void {
    @memset(self.dashboard_chain_expanded_items[0..], false);
}

fn resetScrollView(scroll_view: *vxfw.ScrollView) void {
    scroll_view.cursor = 0;
    scroll_view.scroll.top = 0;
    scroll_view.scroll.vertical_offset = 0;
    scroll_view.scroll.left = 0;
}

fn clampScrollTop(scroll_view: *vxfw.ScrollView, row_count: usize) void {
    const visible_rows: usize = @max(@as(usize, scroll_view.last_height), 1);
    const max_top: usize = if (row_count > visible_rows) row_count - visible_rows else 0;
    if (max_top == 0) {
        scroll_view.scroll.top = 0;
        scroll_view.scroll.vertical_offset = 0;
        return;
    }
    if (scroll_view.scroll.top > max_top) {
        scroll_view.scroll.top = @intCast(max_top);
        scroll_view.scroll.vertical_offset = 0;
    }
}

fn syncRoundWidgets(
    self: anytype,
    ctx: vxfw.DrawContext,
    rounds: []const attestation_reader.RoundEvent,
    width: u16,
) std.mem.Allocator.Error!void {
    const row_count = @min(rounds.len * ROUND_ROW_COUNT, self.dashboard_round_rows.len);
    var out: usize = 0;
    var idx: usize = 0;
    while (idx < rounds.len and out + ROUND_ROW_COUNT <= row_count) : (idx += 1) {
        const round = rounds[idx];
        const is_sel = idx == self.analysis_input_cursor;
        const row_bg = if (is_sel) theme.PANEL_ALT else theme.PANEL;
        const time_txt = try formatHm(ctx.arena, round.timestamp);
        const exception = isExceptionRound(round);
        if (exception) {
            try appendExceptionRoundHeader(self, ctx, &out, width, round.session_id, time_txt, row_bg, is_sel);
        } else {
            const head = try flexBetween(ctx, round.session_id, time_txt, width -| 3);
            const head_line = try std.fmt.allocPrint(ctx.arena, " {s}", .{head});
            self.dashboard_round_rows[out] = .{
                .text = try padLine(ctx, firstLineTrimmed(head_line, width), width),
                .style = if (is_sel)
                    theme.boldOn(row_bg, theme.ACCENT_SOFT)
                else
                    .{ .fg = theme.MUTED, .bg = row_bg },
                .softwrap = false,
            };
            self.dashboard_round_widgets[out] = self.dashboard_round_rows[out].widget();
            out += 1;
        }

        var remaining = if (round.missing_user_prompt)
            "Per-session log has MCP calls, but no user_prompt. Reinstall or rebuild the adapter hook."
        else
            round.content;
        var line_idx: usize = 0;
        while (line_idx < 3) : (line_idx += 1) {
            const text = nextPromptPreviewLine(&remaining, width -| 3);
            const snippet = try std.fmt.allocPrint(ctx.arena, "  {s}", .{text});
            self.dashboard_round_rows[out] = .{
                .text = try padLine(ctx, snippet, width),
                .style = if (is_sel) theme.boldOn(row_bg, theme.TEXT) else .{ .fg = theme.TEXT_SOFT, .bg = row_bg },
                .softwrap = false,
            };
            self.dashboard_round_widgets[out] = self.dashboard_round_rows[out].widget();
            out += 1;
        }

        const sep = try ctx.arena.alloc(u8, width);
        @memset(sep, ' ');
        if (idx + 1 < rounds.len) {
            self.dashboard_round_rows[out] = .{
                .text = try padLine(ctx, " \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80", width),
                .style = .{ .fg = theme.BORDER, .bg = theme.PANEL },
                .softwrap = false,
            };
        } else {
            self.dashboard_round_rows[out] = .{
                .text = sep,
                .style = .{ .fg = theme.PANEL, .bg = theme.PANEL },
                .softwrap = false,
            };
        }
        self.dashboard_round_widgets[out] = self.dashboard_round_rows[out].widget();
        out += 1;
    }
    self.dashboard_round_scroll_bars.scroll_view.children = .{ .slice = self.dashboard_round_widgets[0..out] };
    self.dashboard_round_scroll_bars.estimated_content_height = @intCast(out);
    clampScrollTop(&self.dashboard_round_scroll_bars.scroll_view, out);
}

fn appendExceptionRoundHeader(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    session_id: []const u8,
    time_txt: []const u8,
    row_bg: vaxis.Color,
    is_selected: bool,
) std.mem.Allocator.Error!void {
    if (out.* >= self.dashboard_round_rich_rows.len) return;

    const time_w: u16 = @intCast(ctx.stringWidth(time_txt));
    const session_budget = width -| time_w -| 3;
    const session_text = firstLineTrimmed(session_id, session_budget);
    const session_w: u16 = @intCast(ctx.stringWidth(session_text));
    const used_w = 1 + session_w + time_w;
    const gap_w = width -| used_w;
    const gap = try ctx.arena.alloc(u8, gap_w);
    @memset(gap, ' ');

    const spans = try ctx.arena.alloc(vaxis.Segment, 4);
    const session_style = if (is_selected)
        theme.boldOn(row_bg, theme.DANGER)
    else
        theme.textOn(row_bg, theme.DANGER);
    spans[0] = .{ .text = " ", .style = theme.textOn(row_bg, theme.TEXT) };
    spans[1] = .{ .text = session_text, .style = session_style };
    spans[2] = .{ .text = gap, .style = theme.textOn(row_bg, theme.MUTED) };
    spans[3] = .{ .text = time_txt, .style = theme.textOn(row_bg, theme.MUTED) };
    self.dashboard_round_rich_rows[out.*] = .{
        .text = spans,
        .base_style = theme.textOn(row_bg, theme.MUTED),
        .softwrap = false,
        .overflow = .clip,
        .width_basis = .longest_line,
    };
    self.dashboard_round_widgets[out.*] = self.dashboard_round_rich_rows[out.*].widget();
    out.* += 1;
}

fn syncChainWidgets(
    self: anytype,
    ctx: vxfw.DrawContext,
    round: attestation_reader.RoundEvent,
    width: u16,
) std.mem.Allocator.Error!void {
    var out: usize = 0;
    const item_count = 1 + countTraceItems(round.tools);
    if (self.dashboard_chain_cursor >= item_count) {
        self.dashboard_chain_cursor = item_count - 1;
    }
    var selected_row: usize = 0;
    var item_index: usize = 0;

    if (self.analysis_focus == .chart and self.dashboard_chain_cursor == item_index) selected_row = out;
    try appendUserPromptTool(self, ctx, &out, width, round, item_index);
    item_index += 1;

    if (round.tools.len > 0) {
        var idx: usize = 0;
        while (idx < round.tools.len) {
            if (out >= self.dashboard_chain_rows.len) break;
            const tool = round.tools[idx];
            if (self.analysis_focus == .chart and item_index == self.dashboard_chain_cursor) selected_row = out;
            if (std.mem.eql(u8, tool.kind, "load")) {
                idx = try appendLoadGroup(self, ctx, &out, width, round.ws_id, round.tools, idx, item_index);
            } else {
                try appendChainTool(self, ctx, &out, width, round.ws_id, tool, idx + 1 == round.tools.len, item_index);
                idx += 1;
            }
            item_index += 1;
        }
    }
    self.dashboard_chain_scroll_bars.scroll_view.cursor = @intCast(@min(selected_row, @as(usize, std.math.maxInt(u32))));
    self.dashboard_chain_scroll_bars.scroll_view.ensureScroll();
    if (out == 0) appendChainLine(self, &out, "", theme.fg(theme.MUTED), false);
    self.dashboard_chain_scroll_bars.scroll_view.children = .{ .slice = self.dashboard_chain_widgets[0..out] };
    self.dashboard_chain_scroll_bars.estimated_content_height = @intCast(out);
    self.dashboard_chain_scroll_bars.estimated_content_width = null;
    clampScrollTop(&self.dashboard_chain_scroll_bars.scroll_view, out);
    self.dashboard_chain_scroll_bars.scroll_view.scroll.left = 0;
}

fn countTraceItems(tools: []const attestation_reader.RoundTool) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (idx < tools.len) {
        if (std.mem.eql(u8, tools[idx].kind, "load")) {
            while (idx < tools.len and std.mem.eql(u8, tools[idx].kind, "load")) : (idx += 1) {}
        } else {
            idx += 1;
        }
        count += 1;
    }
    return count;
}

fn chainItemExpanded(self: anytype, item_index: usize) bool {
    if (item_index >= self.dashboard_chain_expanded_items.len) return false;
    return self.dashboard_chain_expanded_items[item_index];
}

fn nextPromptPreviewLine(remaining: *[]const u8, width: u16) []const u8 {
    if (remaining.*.len == 0 or width == 0) return "";
    const line_end = std.mem.indexOfScalar(u8, remaining.*, '\n') orelse remaining.*.len;
    const max_len: usize = @intCast(width);
    var take: usize = @min(line_end, max_len);
    var line = remaining.*[0..take];
    while (line.len > 0 and !std.unicode.utf8ValidateSlice(line)) {
        take -= 1;
        line = remaining.*[0..take];
    }
    if (take == line_end and line_end < remaining.*.len) {
        remaining.* = remaining.*[line_end + 1 ..];
    } else {
        remaining.* = remaining.*[take..];
        if (remaining.*.len > 0 and remaining.*[0] == '\n') remaining.* = remaining.*[1..];
    }
    return line;
}

fn appendUserPromptTool(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    round: attestation_reader.RoundEvent,
    item_index: usize,
) std.mem.Allocator.Error!void {
    const is_selected = self.analysis_focus == .chart and item_index == self.dashboard_chain_cursor;
    const is_expanded = chainItemExpanded(self, item_index);
    const time_txt = try formatHm(ctx.arena, round.timestamp);
    const marker = if (is_selected) "\xe2\x96\x8c" else " ";
    const exp_icon = if (is_expanded) "[-]" else "[+]";
    const head = try std.fmt.allocPrint(ctx.arena, "{s} {s} {s} USER", .{ marker, time_txt, exp_icon });
    const head_text = firstLineTrimmed(head, width);
    appendChainLine(
        self,
        out,
        if (is_selected) try padLine(ctx, head_text, width) else head_text,
        traceHeaderStyle("user_prompt", is_selected),
        is_selected,
    );

    if (is_expanded) {
        try appendEvidenceText(self, ctx, out, width, "prompt", round.content, is_selected);
    } else {
        try appendBriefText(self, ctx, out, width, "prompt", round.content, is_selected);
    }
    if (out.* < self.dashboard_chain_rows.len) {
        appendChainLine(self, out, "", theme.fg(theme.DIM), false);
    }
}

fn appendBriefText(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    label: []const u8,
    text: []const u8,
    is_selected: bool,
) std.mem.Allocator.Error!void {
    if (text.len == 0 or out.* >= self.dashboard_chain_rows.len) return;
    const label_col = try traceFieldPrefix(ctx, label);
    const label_w = @as(u16, @intCast(ctx.stringWidth(label_col)));
    const continuation = try traceFieldPrefix(ctx, "");
    var remaining = text;
    var line_idx: usize = 0;
    while (line_idx < 2 and remaining.len > 0 and out.* < self.dashboard_chain_rows.len) : (line_idx += 1) {
        const prefix = if (line_idx == 0) label_col else continuation;
        const body = nextPromptPreviewLine(&remaining, width -| label_w);
        const line = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, body });
        appendChainLine(self, out, firstLineTrimmed(line, width), traceDetailStyle(), is_selected);
    }
}

fn appendLoadGroup(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    ws_id: []const u8,
    tools: []const attestation_reader.RoundTool,
    start: usize,
    item_index: usize,
) std.mem.Allocator.Error!usize {
    const is_selected = self.analysis_focus == .chart and item_index == self.dashboard_chain_cursor;
    const is_expanded = chainItemExpanded(self, item_index);
    const first = tools[start];
    var end = start;
    while (end < tools.len and std.mem.eql(u8, tools[end].kind, "load")) : (end += 1) {}

    const time_txt = try formatHm(ctx.arena, first.timestamp);
    const count = end - start;
    const marker = if (is_selected) "\xe2\x96\x8c" else " ";
    const exp_icon = if (is_expanded) "[-]" else "[+]";
    const counts = loadGroupCounts(ctx, ws_id, tools[start..end]);
    const label = loadGroupLabel(counts);
    const preview = try loadGroupPreview(ctx, ws_id, tools[start..end]);
    const head = try std.fmt.allocPrint(ctx.arena, "{s} {s} {s} LOAD  {d} {s}", .{ marker, time_txt, exp_icon, count, label });
    const head_text = firstLineTrimmed(head, width);
    appendChainLine(self, out, if (is_selected) try padLine(ctx, head_text, width) else head_text, traceHeaderStyle("load", is_selected), is_selected);

    if (is_expanded) {
        var idx: usize = 0;
        while (idx < count and out.* < self.dashboard_chain_rows.len) : (idx += 1) {
            const tool = tools[start + idx];
            if (loadToolId(tool)) |id| {
                const item = try resolveRulePreview(ctx, ws_id, id);
                try appendLoadItemHeader(self, ctx, out, width, idx, count, item, is_selected);
                try appendRulePreview(self, ctx, out, width, item, .expanded, is_selected, false);
                if (idx + 1 < count and out.* < self.dashboard_chain_rows.len) {
                    appendTraceGuideBlank(self, out, is_selected);
                }
            }
        }
    } else {
        try appendBriefText(self, ctx, out, width, label, preview, is_selected);
    }
    if (end < tools.len and out.* < self.dashboard_chain_rows.len) {
        appendChainLine(self, out, "", theme.fg(theme.DIM), false);
    }
    return end;
}

const LoadGroupCounts = struct {
    rules: usize = 0,
    workflows: usize = 0,
    contexts: usize = 0,
    unknown: usize = 0,
};

fn loadGroupCounts(
    ctx: vxfw.DrawContext,
    ws_id: []const u8,
    tools: []const attestation_reader.RoundTool,
) LoadGroupCounts {
    var counts: LoadGroupCounts = .{};
    for (tools) |tool| {
        const id = loadToolId(tool) orelse {
            counts.unknown += 1;
            continue;
        };
        const item = resolveRulePreview(ctx, ws_id, id) catch {
            counts.unknown += 1;
            continue;
        };
        switch (item.kind) {
            .rule => counts.rules += 1,
            .workflow => counts.workflows += 1,
            .context => counts.contexts += 1,
        }
    }
    return counts;
}

fn loadGroupLabel(counts: LoadGroupCounts) []const u8 {
    if (counts.contexts > 0 and counts.rules == 0 and counts.workflows == 0 and counts.unknown == 0) return "context";
    if (counts.rules > 0 and counts.contexts == 0 and counts.workflows == 0 and counts.unknown == 0) return "rules";
    if (counts.workflows > 0 and counts.contexts == 0 and counts.rules == 0 and counts.unknown == 0) return "workflows";
    return "items";
}

fn loadToolId(tool: attestation_reader.RoundTool) ?[]const u8 {
    if (tool.rule_id) |rule_id| return rule_id;
    if (tool.context_id) |context_id| return context_id;
    return null;
}

fn appendLoadItemHeader(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    index: usize,
    count: usize,
    item: RulePreview,
    is_selected: bool,
) std.mem.Allocator.Error!void {
    const text = try std.fmt.allocPrint(ctx.arena, "[{d}/{d}] {s}", .{ index + 1, count, item.name });
    try appendTraceChildColoredLine(self, ctx, out, width, "", text, theme.fg(TRACE_LOAD), is_selected);
}

fn loadGroupPreview(
    ctx: vxfw.DrawContext,
    ws_id: []const u8,
    tools: []const attestation_reader.RoundTool,
) std.mem.Allocator.Error![]const u8 {
    var preview: std.ArrayList(u8) = .empty;
    var shown: usize = 0;
    for (tools) |tool| {
        const id = loadToolId(tool) orelse continue;
        const rule = try resolveRulePreview(ctx, ws_id, id);
        if (shown > 0) try preview.appendSlice(ctx.arena, ", ");
        try preview.appendSlice(ctx.arena, rule.name);
        shown += 1;
        if (shown == 2) break;
    }
    if (shown == 0) return "";
    if (tools.len > shown) try preview.appendSlice(ctx.arena, ", ...");
    return preview.items;
}

fn toolHeaderSubject(
    ctx: vxfw.DrawContext,
    ws_id: []const u8,
    tool: attestation_reader.RoundTool,
) std.mem.Allocator.Error![]const u8 {
    if (std.mem.eql(u8, tool.kind, "setup")) return "bootstrap";
    if (std.mem.eql(u8, tool.kind, "discover")) {
        if (tool.discover_result_count) |count| {
            return try std.fmt.allocPrint(ctx.arena, "{d} matches", .{count});
        }
        return "catalog";
    }
    if (std.mem.eql(u8, tool.kind, "refer")) {
        if (toolConstraintName(ctx, ws_id, tool)) |name| return name;
        if (tool.constraint_id) |constraint_id| return constraint_id;
        return "constraint";
    }
    if (isProposeTool(tool.kind)) {
        if (tool.new_path) |path| return path;
        if (tool.path) |path| return path;
        if (tool.rule_id) |rule_id| return rule_id;
        if (tool.context_id) |context_id| return context_id;
        return "draft";
    }
    if (tool.rule_id) |rule_id| {
        const rule = try resolveRulePreview(ctx, ws_id, rule_id);
        return rule.name;
    }
    return "";
}

fn appendChainTool(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    ws_id: []const u8,
    tool: attestation_reader.RoundTool,
    is_last: bool,
    item_index: usize,
) std.mem.Allocator.Error!void {
    if (out.* >= self.dashboard_chain_rows.len) return;
    const is_selected = self.analysis_focus == .chart and item_index == self.dashboard_chain_cursor;
    const is_expanded = chainItemExpanded(self, item_index);
    const time_txt = try formatHm(ctx.arena, tool.timestamp);
    const verb = toolVerb(tool.kind);

    const marker = if (is_selected) "\xe2\x96\x8c" else " ";
    const exp_icon = if (is_expanded) "[-]" else "[+]";
    const subject = try toolHeaderSubject(ctx, ws_id, tool);
    const preview = toolBriefText(tool) orelse subject;

    const head = if (subject.len > 0)
        try std.fmt.allocPrint(ctx.arena, "{s} {s} {s} {s:<6} {s}", .{ marker, time_txt, exp_icon, verb, subject })
    else
        try std.fmt.allocPrint(ctx.arena, "{s} {s} {s} {s}", .{ marker, time_txt, exp_icon, verb });

    const head_text = firstLineTrimmed(head, width);
    appendChainLine(self, out, if (is_selected) try padLine(ctx, head_text, width) else head_text, traceHeaderStyle(tool.kind, is_selected), is_selected);

    if (is_expanded) {
        try appendToolMetadata(self, ctx, out, width, tool, is_selected);

        if (std.mem.eql(u8, tool.kind, "refer")) {
            if (toolConstraintName(ctx, ws_id, tool)) |name| {
                try appendDetailField(self, ctx, out, width, "name", name, is_selected);
            }
        }

        if (tool.rule_id) |rule_id| {
            const rule = try resolveRulePreview(ctx, ws_id, rule_id);
            if (std.mem.eql(u8, tool.kind, "refer")) {
                try appendDetailField(self, ctx, out, width, "rule", rule.name, is_selected);
            } else {
                try appendRulePreview(self, ctx, out, width, rule, .expanded, is_selected, true);
            }
        }
        if (!std.mem.eql(u8, tool.kind, "refer") and tool.constraint_name != null) {
            const name = tool.constraint_name.?;
            try appendDetailField(self, ctx, out, width, "constraint", name, is_selected);
        }

        const expanded = toolExpandedText(tool);
        if (expanded) |text| {
            if (text.len > 0) {
                const field = if (std.mem.eql(u8, tool.kind, "reject"))
                    "reason"
                else if (std.mem.eql(u8, tool.kind, "refer"))
                    "action"
                else
                    "summary";
                try appendEvidenceText(self, ctx, out, width, field, text, is_selected);
            }
        }
    } else {
        try appendBriefText(self, ctx, out, width, briefLabel(tool.kind), preview, is_selected);
    }

    if (!is_last and out.* < self.dashboard_chain_rows.len) {
        appendChainLine(self, out, "", theme.fg(theme.DIM), false);
    }
}

fn appendToolMetadata(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    tool: attestation_reader.RoundTool,
    is_selected: bool,
) std.mem.Allocator.Error!void {
    if (std.mem.eql(u8, tool.kind, "setup")) {
        if (tool.session_id.len > 0) {
            try appendDetailField(self, ctx, out, width, "session", tool.session_id, is_selected);
        } else {
            try appendDetailField(self, ctx, out, width, "session", "unknown", is_selected);
        }
        if (tool.mpf_hash) |hash| {
            try appendDetailField(self, ctx, out, width, "MPF hash", hash, is_selected);
        }
        if (tool.mpf_content) |content| {
            try appendDetailField(self, ctx, out, width, "MPF text", content, is_selected);
        }
        return;
    }

    if (std.mem.eql(u8, tool.kind, "discover")) {
        if (tool.discover_kind) |kind| {
            try appendDetailField(self, ctx, out, width, "kind", kind, is_selected);
        }
        if (tool.discover_group) |group| {
            try appendDetailField(self, ctx, out, width, "group", group, is_selected);
        }
        if (tool.discover_query) |query| {
            try appendDetailField(self, ctx, out, width, "query", query, is_selected);
        }
        if (tool.discover_result_names) |names| {
            try appendDiscoverMatches(self, ctx, out, width, names, is_selected);
        }
        return;
    }

    if (isProposeTool(tool.kind)) {
        try appendDetailField(self, ctx, out, width, "category", proposeCategory(tool.kind), is_selected);
        try appendDetailField(self, ctx, out, width, "operation", proposeOperation(tool.kind), is_selected);
        if (tool.path) |path| {
            const label = if (tool.new_path == null) "draft" else "current";
            try appendDetailField(self, ctx, out, width, label, path, is_selected);
        }
        if (tool.new_path) |new_path| {
            try appendDetailField(self, ctx, out, width, "draft", new_path, is_selected);
        }
        if (tool.rule_id) |rule_id| {
            try appendDetailField(self, ctx, out, width, "rule id", rule_id, is_selected);
        }
        if (tool.context_id) |context_id| {
            try appendDetailField(self, ctx, out, width, "context id", context_id, is_selected);
        }
    }
}

const RulePreview = struct {
    kind: workspace_rule.RuleKind = .rule,
    name: []const u8,
    path: []const u8 = "",
    excerpt: []const u8 = "",
};

const RulePreviewDensity = enum {
    compact,
    expanded,
};

fn resolveRulePreview(ctx: vxfw.DrawContext, ws_id: []const u8, rule_id: []const u8) std.mem.Allocator.Error!RulePreview {
    if (ws_id.len > 0) {
        if (workspaceDir(ctx.arena, ws_id)) |ws_dir| {
            const ids = [_][]const u8{rule_id};
            var loaded = workspace_rule.loadRules(ctx.arena, ws_dir, ids[0..], &.{}) catch null;
            if (loaded) |*result| {
                if (result.items.items.len > 0) {
                    const item = result.items.items[0];
                    const excerpt = if (item.content) |content| firstMeaningfulLine(content) else "";
                    return .{
                        .kind = item.kind,
                        .name = item.name,
                        .path = item.path,
                        .excerpt = excerpt,
                    };
                }
            }
        }
    }
    return .{ .name = rule_id };
}

fn toolConstraintName(
    ctx: vxfw.DrawContext,
    ws_id: []const u8,
    tool: attestation_reader.RoundTool,
) ?[]const u8 {
    if (tool.constraint_name) |name| return name;
    const rule_id = tool.rule_id orelse return null;
    const constraint_id = tool.constraint_id orelse return null;
    return resolveConstraintName(ctx, ws_id, rule_id, constraint_id);
}

fn resolveConstraintName(
    ctx: vxfw.DrawContext,
    ws_id: []const u8,
    rule_id: []const u8,
    constraint_id: []const u8,
) ?[]const u8 {
    if (ws_id.len == 0) return null;
    const ws_dir = workspaceDir(ctx.arena, ws_id) orelse return null;
    const ids = [_][]const u8{rule_id};
    const loaded = workspace_rule.loadRules(ctx.arena, ws_dir, ids[0..], &.{}) catch return null;
    if (loaded.items.items.len == 0) return null;
    const content = loaded.items.items[0].content orelse return null;
    const parsed = workspace_rule.parseConstraints(ctx.arena, content) catch return null;
    for (parsed.constraints.items) |constraint| {
        if (std.mem.eql(u8, constraint.id, constraint_id)) return constraint.name;
    }
    return null;
}

fn workspaceDir(arena: std.mem.Allocator, ws_id: []const u8) ?[]const u8 {
    const home = std.process.getEnvVarOwned(arena, "HOME") catch
        std.process.getEnvVarOwned(arena, "USERPROFILE") catch return null;
    return std.fs.path.join(arena, &.{ home, ".clumsies", "workspaces", ws_id }) catch null;
}

fn firstMeaningfulLine(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "---")) continue;
        if (std.mem.startsWith(u8, trimmed, "[")) continue;
        if (std.mem.startsWith(u8, trimmed, "# ")) continue;
        if (std.mem.startsWith(u8, trimmed, "## ")) continue;
        return trimmed;
    }
    return "";
}

fn appendRulePreview(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    rule: RulePreview,
    density: RulePreviewDensity,
    is_selected: bool,
    show_name: bool,
) std.mem.Allocator.Error!void {
    if (show_name) {
        try appendDetailField(self, ctx, out, width, "rule", rule.name, is_selected);
    }

    if (rule.path.len > 0) {
        try appendDetailField(self, ctx, out, width, "path", rule.path, is_selected);
    }
    if (density == .expanded and rule.excerpt.len > 0) {
        try appendDetailField(self, ctx, out, width, "desc", rule.excerpt, is_selected);
    }
}

fn appendDetailField(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    label: []const u8,
    text: []const u8,
    is_selected: bool,
) std.mem.Allocator.Error!void {
    const prefix = try traceFieldPrefix(ctx, label);
    const continuation = try traceFieldPrefix(ctx, "");
    const prefix_w = ctx.stringWidth(prefix);
    const body_w = width -| @as(u16, @intCast(prefix_w));
    if (body_w == 0) return;
    var remaining = text;
    var line_idx: usize = 0;
    while (remaining.len > 0 and out.* < self.dashboard_chain_rows.len) {
        const line_prefix = if (line_idx == 0) prefix else continuation;
        const before_len = remaining.len;
        const chunk = nextPromptPreviewLine(&remaining, body_w);
        if (chunk.len == 0 and remaining.len == before_len) break;
        const line = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ line_prefix, chunk });
        appendChainLine(self, out, firstLineTrimmed(line, width), traceDetailStyle(), is_selected);
        line_idx += 1;
    }
}

fn traceFieldPrefix(ctx: vxfw.DrawContext, label: []const u8) std.mem.Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(ctx.arena, "{s}{s:<10}", .{ TRACE_GUIDE_PREFIX, label });
}

fn traceDetailStyle() vaxis.Style {
    return theme.fg(theme.MUTED);
}

fn appendTraceChildColoredLine(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    label: []const u8,
    text: []const u8,
    text_style: vaxis.Style,
    is_selected: bool,
) std.mem.Allocator.Error!void {
    const prefix = try traceFieldPrefix(ctx, label);
    const prefix_w = @as(u16, @intCast(ctx.stringWidth(prefix)));
    const body = firstLineTrimmed(text, width -| prefix_w);
    const body_w = @as(u16, @intCast(ctx.stringWidth(body)));
    const pad_w = width -| prefix_w -| body_w;
    const spans_len: usize = if (pad_w > 0) 3 else 2;
    const spans = try ctx.arena.alloc(vaxis.Segment, spans_len);
    spans[0] = .{ .text = prefix, .style = traceDetailStyle() };
    spans[1] = .{ .text = body, .style = text_style };
    if (pad_w > 0) {
        const padding = try ctx.arena.alloc(u8, pad_w);
        @memset(padding, ' ');
        spans[2] = .{ .text = padding, .style = traceDetailStyle() };
    }
    appendChainRichLine(self, ctx, out, spans, is_selected);
}

fn appendTraceGuideBlank(self: anytype, out: *usize, is_selected: bool) void {
    appendChainLine(self, out, TRACE_GUIDE_PREFIX, traceDetailStyle(), is_selected);
}

fn appendDiscoverMatches(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    names: []const u8,
    is_selected: bool,
) std.mem.Allocator.Error!void {
    var split = std.mem.splitSequence(u8, names, ", ");
    var idx: usize = 0;
    while (split.next()) |name| {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len == 0) continue;
        const badge = try std.fmt.allocPrint(ctx.arena, "\xe2\x97\x86 {s}", .{trimmed});
        try appendTraceChildColoredLine(self, ctx, out, width, if (idx == 0) "matches" else "", badge, theme.fg(TRACE_DISCOVER), is_selected);
        idx += 1;
    }
}

fn appendEvidenceText(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    label: []const u8,
    text: []const u8,
    is_selected: bool,
) std.mem.Allocator.Error!void {
    try appendDetailField(self, ctx, out, width, label, text, is_selected);
}

fn briefLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "setup")) return "MPF";
    if (std.mem.eql(u8, kind, "discover")) return "query";
    if (std.mem.eql(u8, kind, "refer")) return "action";
    if (std.mem.eql(u8, kind, "agent_report")) return "summary";
    if (std.mem.eql(u8, kind, "reject")) return "reason";
    if (isProposeTool(kind)) return "draft";
    return "detail";
}

fn toolBriefText(tool: attestation_reader.RoundTool) ?[]const u8 {
    if (std.mem.eql(u8, tool.kind, "agent_report")) return tool.summary;
    if (std.mem.eql(u8, tool.kind, "reject")) return tool.reason;
    if (std.mem.eql(u8, tool.kind, "setup")) {
        if (tool.mpf_content) |content| {
            const line = firstMeaningfulLine(content);
            if (line.len > 0) return line;
        }
        return "session bound";
    }
    if (std.mem.eql(u8, tool.kind, "discover")) {
        if (tool.discover_result_names) |names| return names;
        if (tool.discover_query) |query| return query;
        if (tool.discover_group) |group| return group;
        if (tool.discover_kind) |kind| return kind;
        return "catalog query";
    }
    if (std.mem.eql(u8, tool.kind, "refer")) {
        if (tool.reason) |reason| return reason;
        if (tool.constraint_name) |name| return name;
    }
    if (isProposeTool(tool.kind)) {
        if (tool.new_path) |path| return path;
        if (tool.path) |path| return path;
        if (tool.rule_id) |rule_id| return rule_id;
        if (tool.context_id) |context_id| return context_id;
    }
    return null;
}

fn toolVerb(kind: []const u8) []const u8 {
    if (isProposeTool(kind)) return "DRAFT";
    if (std.mem.eql(u8, kind, "agent_report")) return "AGENT";
    if (std.mem.eql(u8, kind, "refer")) return "REFER";
    if (std.mem.eql(u8, kind, "reject")) return "REJECT";
    if (std.mem.eql(u8, kind, "load")) return "LOAD";
    if (std.mem.eql(u8, kind, "discover")) return "DISCOVER";
    if (std.mem.eql(u8, kind, "search")) return "DISCOVER";
    if (std.mem.eql(u8, kind, "setup")) return "SETUP";
    return kind;
}

fn appendChainLine(self: anytype, out: *usize, text: []const u8, style: vaxis.Style, is_selected: bool) void {
    if (out.* >= self.dashboard_chain_rows.len) return;
    var final_style = style;
    if (is_selected) final_style.bg = theme.PANEL_ALT;
    self.dashboard_chain_rows[out.*] = .{ .text = text, .style = final_style, .softwrap = false };
    self.dashboard_chain_widgets[out.*] = self.dashboard_chain_rows[out.*].widget();
    out.* += 1;
}

fn appendChainRichLine(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    spans: []const vaxis.Segment,
    is_selected: bool,
) void {
    if (out.* >= self.dashboard_chain_rich_rows.len) return;
    const final_spans = ctx.arena.alloc(vaxis.Segment, spans.len) catch return;
    for (spans, 0..) |span, idx| {
        final_spans[idx] = span;
        if (is_selected) final_spans[idx].style.bg = theme.PANEL_ALT;
    }
    self.dashboard_chain_rich_rows[out.*] = .{
        .text = final_spans,
        .softwrap = false,
        .overflow = .ellipsis,
        .width_basis = .longest_line,
    };
    self.dashboard_chain_widgets[out.*] = self.dashboard_chain_rich_rows[out.*].widget();
    out.* += 1;
}

fn traceHeaderStyle(kind: []const u8, is_selected: bool) vaxis.Style {
    const color = traceVerbColor(kind);
    return if (is_selected) theme.boldOn(theme.PANEL_ALT, color) else theme.fg(color);
}

fn traceVerbColor(kind: []const u8) vaxis.Color {
    if (std.mem.eql(u8, kind, "user_prompt")) return TRACE_USER;
    if (std.mem.eql(u8, kind, "setup")) return TRACE_SETUP;
    if (std.mem.eql(u8, kind, "load")) return TRACE_LOAD;
    if (std.mem.eql(u8, kind, "refer")) return TRACE_REFER;
    if (std.mem.eql(u8, kind, "agent_report")) return TRACE_AGENT;
    if (std.mem.eql(u8, kind, "reject")) return TRACE_REJECT;
    if (std.mem.eql(u8, kind, "discover") or std.mem.eql(u8, kind, "search")) return TRACE_DISCOVER;
    if (isProposeTool(kind)) return TRACE_DRAFT;
    return theme.TEXT_SOFT;
}

fn toolExpandedText(tool: attestation_reader.RoundTool) ?[]const u8 {
    if (std.mem.eql(u8, tool.kind, "agent_report")) return tool.summary;
    if (std.mem.eql(u8, tool.kind, "reject")) return tool.reason;
    if (std.mem.eql(u8, tool.kind, "refer")) return tool.reason;
    return null;
}

fn isProposeTool(kind: []const u8) bool {
    return std.mem.startsWith(u8, kind, "context_propose_") or
        std.mem.startsWith(u8, kind, "rule_propose_");
}

fn proposeCategory(kind: []const u8) []const u8 {
    if (std.mem.startsWith(u8, kind, "context_propose_")) return "context";
    if (std.mem.startsWith(u8, kind, "rule_propose_")) return "rule";
    return "draft";
}

fn proposeOperation(kind: []const u8) []const u8 {
    if (std.mem.endsWith(u8, kind, "_create")) return "create";
    if (std.mem.endsWith(u8, kind, "_update")) return "update";
    if (std.mem.endsWith(u8, kind, "_rename")) return "rename";
    if (std.mem.endsWith(u8, kind, "_delete")) return "delete";
    return "propose";
}

fn formatHm(arena: std.mem.Allocator, ts_ms: i64) std.mem.Allocator.Error![]const u8 {
    const secs = @divTrunc(ts_ms, 1000);
    const day_secs: i64 = 86400;
    const day_offset = @mod(secs, day_secs);
    const hh = @divTrunc(day_offset, 3600);
    const mm = @divTrunc(@mod(day_offset, 3600), 60);
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(hh)),
        @as(u32, @intCast(mm)),
    });
}

test "protocolCounts groups rule and context proposals as draft tools" {
    const round = attestation_reader.RoundEvent{
        .timestamp = 1000,
        .content = "ask",
        .tools = &.{
            .{ .kind = "context_propose_create", .timestamp = 1001 },
            .{ .kind = "context_propose_update", .timestamp = 1002 },
            .{ .kind = "context_propose_rename", .timestamp = 1003 },
            .{ .kind = "context_propose_delete", .timestamp = 1004 },
            .{ .kind = "rule_propose_create", .timestamp = 1005 },
            .{ .kind = "rule_propose_update", .timestamp = 1006 },
            .{ .kind = "rule_propose_rename", .timestamp = 1007 },
            .{ .kind = "rule_propose_delete", .timestamp = 1008 },
        },
    };

    const counts = protocolCounts(round);

    try std.testing.expectEqual(@as(u16, 1), counts.user);
    try std.testing.expectEqual(@as(u16, 8), counts.draft);
    try std.testing.expectEqual(@as(u16, 0), counts.other);
}

fn firstLineTrimmed(text: []const u8, max_cells: u16) []const u8 {
    var end: usize = text.len;
    if (std.mem.indexOfScalar(u8, text, '\n')) |newline| end = newline;
    var slice = text[0..end];
    const cap: usize = @intCast(max_cells);
    if (slice.len > cap) slice = slice[0..cap];
    while (slice.len > 0 and !std.unicode.utf8ValidateSlice(slice)) {
        slice = slice[0 .. slice.len - 1];
    }
    return slice;
}

fn flexBetween(ctx: vxfw.DrawContext, left: []const u8, right: []const u8, width: u16) std.mem.Allocator.Error![]const u8 {
    const left_trimmed = firstLineTrimmed(left, width);
    const left_w = @as(u16, @intCast(ctx.stringWidth(left_trimmed)));
    const right_w = @as(u16, @intCast(ctx.stringWidth(right)));
    if (left_w + right_w >= width) {
        return try std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ firstLineTrimmed(left_trimmed, width -| right_w -| 1), right });
    }
    const spaces_len: usize = @intCast(width - left_w - right_w);
    const spaces = try ctx.arena.alloc(u8, spaces_len);
    @memset(spaces, ' ');
    return try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ left_trimmed, spaces, right });
}

fn padLine(ctx: vxfw.DrawContext, text: []const u8, width: u16) std.mem.Allocator.Error![]const u8 {
    const current_width = ctx.stringWidth(text);
    if (current_width >= width) return text;
    const missing: usize = @intCast(width - @as(u16, @intCast(current_width)));
    const padded = try ctx.arena.alloc(u8, text.len + missing);
    @memcpy(padded[0..text.len], text);
    @memset(padded[text.len..], ' ');
    return padded;
}
