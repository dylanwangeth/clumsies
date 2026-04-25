const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const w = @import("../widgets.zig");
const attestation_reader = @import("../attestation_reader.zig");
const workspace_rule = @import("../../rule.zig");
const Modal = w.Modal;
const ROUND_ROW_COUNT = 3;

pub fn drawRoot(
    self: anytype,
    ctx: vxfw.DrawContext,
    arena_surface: vxfw.Surface,
    rounds_surface: vxfw.Surface,
    exchange_surface: vxfw.Surface,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.CANVAS);

    const arena_h: u16 = 4;
    const preferred_rounds_w: u16 = @intCast(@divTrunc(@as(u32, size.width) * 38, 100));
    const rounds_w: u16 = @min(size.width, @max(@as(u16, 64), @min(@as(u16, 96), preferred_rounds_w)));

    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = arena_surface };
    children[1] = .{ .origin = .{ .row = arena_h, .col = 0 }, .surface = rounds_surface };
    children[2] = .{ .origin = .{ .row = arena_h, .col = rounds_w }, .surface = exchange_surface };
    root.children = children;
    return root;
}

pub const DashboardSummary = struct {
    round_count: usize = 0,
    submitted_count: usize = 0,
    referred_count: usize = 0,
    rejected_count: usize = 0,
    open_count: usize = 0,
    active_session_count: usize = 0,
};

pub fn drawArena(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    scope_label: []const u8,
    summary: DashboardSummary,
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
    const dark_green = theme.rgb(0x2d4a1f);
    const dot_color = theme.lerpColor(dark_green, theme.OK, breath_t);
    w.writeText(&surface, ctx, 2, 0, "\u{25cf}", .{ .fg = dot_color, .bg = theme.PANEL });

    const right_hint = "w scope  Tab focus  Shift-F flush";
    const right_hint_w: u16 = @intCast(ctx.stringWidth(right_hint));
    const right_limit: u16 = width -| right_hint_w -| 2;
    const header_col: u16 = 3;
    const title_txt = try std.fmt.allocPrint(ctx.arena, " Session Arena  \xc2\xb7 {s}", .{scope_label});
    if (header_col < right_limit) {
        w.writeText(&surface, ctx, header_col, 0, firstLineTrimmed(title_txt, right_limit -| header_col), theme.boldOn(theme.PANEL, theme.TEXT));
    }
    w.writeRightText(&surface, ctx, 0, right_hint, theme.fg(theme.MUTED));

    var col: u16 = 3;
    col = try drawMetric(ctx, &surface, col, 2, "ROUNDS", summary.round_count, theme.TEXT);
    col = try drawMetric(ctx, &surface, col + 2, 2, "CLOSED", summary.submitted_count, theme.OK);
    col = try drawMetric(ctx, &surface, col + 2, 2, "REFERRED", summary.referred_count, theme.ACCENT_SOFT);
    col = try drawMetric(ctx, &surface, col + 2, 2, "REJECTED", summary.rejected_count, theme.DANGER);
    _ = try drawMetric(ctx, &surface, col + 2, 2, "OPEN", summary.open_count, theme.MUTED);
    const live_txt = try std.fmt.allocPrint(ctx.arena, "{d} live", .{summary.active_session_count});
    w.writeRightText(&surface, ctx, 2, live_txt, .{ .fg = if (summary.active_session_count > 0) theme.OK else theme.MUTED, .bg = theme.PANEL });

    return surface;
}

pub fn drawRounds(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    rounds: []const attestation_reader.RoundEvent,
    scope_label: []const u8,
) std.mem.Allocator.Error!vxfw.Surface {
    const border_color = theme.focusBorder(self.analysis_focus == .inputs);
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);

    const title_txt = try std.fmt.allocPrint(
        ctx.arena,
        "Rounds  \xc2\xb7 {s}",
        .{scope_label},
    );
    w.writeText(&surface, ctx, 2, 0, title_txt, theme.boldOn(theme.PANEL, theme.TEXT));

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
    while (offset < ROUND_ROW_COUNT and visible_row + offset < height) : (offset += 1) {
        w.writeCursorMarker(surface, 1, row + offset);
    }
}

pub fn drawExchange(
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
    w.writeText(&surface, ctx, 2, 0, "Attestation Chain", theme.boldOn(theme.PANEL, theme.TEXT));

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

pub fn drawInputDetailOverlay(
    self: anytype,
    ctx: vxfw.DrawContext,
    content: []const u8,
    timestamp_ms: i64,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const box_w: u16 = @min(size.width -| 4, @as(u16, 100));
    const box_h: u16 = @min(size.height -| 4, @as(u16, 24));

    const time_txt = try formatHm(ctx.arena, timestamp_ms);
    const title = try std.fmt.allocPrint(ctx.arena, "User Input @ {s}", .{time_txt});

    const modal = Modal{
        .title = title,
        .box_width = box_w,
        .box_height = box_h,
        .footer = " Esc close ",
    };
    const result = try modal.draw(ctx, self.widget());
    var surface = result.surface;
    const col = result.content_col;
    const start_row = result.content_row;

    const inner_w: u16 = box_w -| 4;
    const inner_h: u16 = box_h -| 3;
    var out_row: u16 = 0;
    var remaining = content;
    while (remaining.len > 0 and out_row < inner_h) {
        const line_end = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
        var line = remaining[0..line_end];
        while (line.len > 0 and out_row < inner_h) {
            const take: usize = @min(line.len, @as(usize, @intCast(inner_w)));
            w.writeText(&surface, ctx, col, start_row + out_row, line[0..take], theme.textOn(theme.PANEL_ALT, theme.TEXT));
            line = line[take..];
            out_row += 1;
        }
        if (line_end < remaining.len) {
            remaining = remaining[line_end + 1 ..];
        } else {
            remaining = &.{};
        }
    }
    return surface;
}

pub fn handleModuleEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
    round_count: usize,
) anyerror!void {
    if (key.matches('w', .{})) {
        const scope = self.cycleAnalysisScope();
        const alloc = self.api_state.allocator();
        self.analysis_input_cursor = 0;
        self.analysis_show_input_detail = false;
        self.status_line = std.fmt.allocPrint(alloc, "Dashboard scope: {s}", .{scope.label}) catch "Dashboard scope updated.";
        ctx.consumeAndRedraw();
        return;
    }
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
        self.analysis_show_input_detail = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (self.analysis_focus == .inputs) {
            if (round_count > 0 and self.analysis_input_cursor < round_count - 1) {
                self.analysis_input_cursor += 1;
                resetScrollView(&self.dashboard_chain_scroll_bars.scroll_view);
            }
            ctx.consumeAndRedraw();
            return;
        }
        if (self.analysis_focus == .chart) {
            try self.dashboard_chain_scroll_bars.scroll_view.handleEvent(ctx, .{ .key_press = key });
            self.dashboard_chain_scroll_bars.scroll_view.scroll.left = 0;
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.analysis_focus == .inputs) {
            const old_cursor = self.analysis_input_cursor;
            self.analysis_input_cursor -|= 1;
            if (self.analysis_input_cursor != old_cursor) resetScrollView(&self.dashboard_chain_scroll_bars.scroll_view);
            ctx.consumeAndRedraw();
            return;
        }
        if (self.analysis_focus == .chart) {
            try self.dashboard_chain_scroll_bars.scroll_view.handleEvent(ctx, .{ .key_press = key });
            self.dashboard_chain_scroll_bars.scroll_view.scroll.left = 0;
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (self.analysis_focus == .inputs) {
            self.analysis_show_input_detail = !self.analysis_show_input_detail;
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        if (self.analysis_show_input_detail) {
            self.analysis_show_input_detail = false;
        } else {
            self.analysis_focus = .chart;
        }
        ctx.consumeAndRedraw();
    }
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

fn drawMetric(
    ctx: vxfw.DrawContext,
    surface: *vxfw.Surface,
    col: u16,
    row: u16,
    label: []const u8,
    value: usize,
    color: vaxis.Color,
) std.mem.Allocator.Error!u16 {
    const text = try std.fmt.allocPrint(ctx.arena, "{s} {d}", .{ label, value });
    w.writeText(surface, ctx, col, row, text, .{ .fg = color, .bg = theme.PANEL });
    return col + @as(u16, @intCast(ctx.stringWidth(text)));
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
        const status = roundStatus(round);
        const time_txt = try formatHm(ctx.arena, round.timestamp);
        const head = try std.fmt.allocPrint(ctx.arena, "{s} {s}  ses {s}  refer {d}", .{
            time_txt,
            status.icon,
            compactSessionId(round.session_id),
            round.refer_count,
        });
        self.dashboard_round_rows[out] = .{
            .text = try padLine(ctx, firstLineTrimmed(head, width), width),
            .style = if (is_sel) theme.boldOn(row_bg, status.color) else .{ .fg = status.color, .bg = row_bg },
            .softwrap = false,
        };
        self.dashboard_round_widgets[out] = self.dashboard_round_rows[out].widget();
        out += 1;

        var remaining = round.content;
        var line_idx: usize = 0;
        while (line_idx < ROUND_ROW_COUNT - 1) : (line_idx += 1) {
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
    }
    self.dashboard_round_scroll_bars.scroll_view.children = .{ .slice = self.dashboard_round_widgets[0..out] };
    self.dashboard_round_scroll_bars.estimated_content_height = @intCast(out);
    clampScrollTop(&self.dashboard_round_scroll_bars.scroll_view, out);
}

fn syncChainWidgets(
    self: anytype,
    ctx: vxfw.DrawContext,
    round: attestation_reader.RoundEvent,
    width: u16,
) std.mem.Allocator.Error!void {
    var out: usize = 0;
    if (round.tools.len == 0) {
        appendChainLine(self, &out, "No MCP tool calls attached to this round.", theme.fg(theme.MUTED));
        appendChainLine(self, &out, "Select another round or wait for the agent to call clumsies tools.", theme.fg(theme.DIM));
    } else {
        var idx: usize = 0;
        while (idx < round.tools.len) {
            if (out >= self.dashboard_chain_rows.len) break;
            const tool = round.tools[idx];
            if (std.mem.eql(u8, tool.kind, "load")) {
                idx = try appendLoadGroup(self, ctx, &out, width, round.ws_id, round.tools, idx);
            } else {
                try appendChainTool(self, ctx, &out, width, round.ws_id, tool, idx + 1 == round.tools.len);
                idx += 1;
            }
        }
    }
    if (out == 0) appendChainLine(self, &out, "", theme.fg(theme.MUTED));
    self.dashboard_chain_scroll_bars.scroll_view.children = .{ .slice = self.dashboard_chain_widgets[0..out] };
    self.dashboard_chain_scroll_bars.estimated_content_height = @intCast(out);
    self.dashboard_chain_scroll_bars.estimated_content_width = null;
    clampScrollTop(&self.dashboard_chain_scroll_bars.scroll_view, out);
    self.dashboard_chain_scroll_bars.scroll_view.scroll.left = 0;
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

fn appendLoadGroup(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    ws_id: []const u8,
    tools: []const attestation_reader.RoundTool,
    start: usize,
) std.mem.Allocator.Error!usize {
    const first = tools[start];
    var end = start;
    while (end < tools.len and std.mem.eql(u8, tools[end].kind, "load")) : (end += 1) {}

    const time_txt = try formatHm(ctx.arena, first.timestamp);
    const count = end - start;
    const head = try std.fmt.allocPrint(ctx.arena, "{s}  PREP   loaded {d} rules", .{ time_txt, count });
    appendChainLine(self, out, firstLineTrimmed(head, width), theme.fg(theme.ACCENT_SOFT));

    const preview_count = @min(count, @as(usize, 4));
    var idx: usize = 0;
    while (idx < preview_count and out.* < self.dashboard_chain_rows.len) : (idx += 1) {
        const tool = tools[start + idx];
        if (tool.rule_id) |rule_id| {
            const rule = try resolveRulePreview(ctx, ws_id, rule_id);
            try appendRulePreview(self, ctx, out, width, rule, .compact);
        }
    }
    if (count > preview_count and out.* < self.dashboard_chain_rows.len) {
        const more = try std.fmt.allocPrint(ctx.arena, "+{d} more", .{count - preview_count});
        try appendIndentedText(self, ctx, out, width, more, theme.fg(theme.DIM));
    }
    if (end < tools.len and out.* < self.dashboard_chain_rows.len) appendChainLine(self, out, "", theme.fg(theme.DIM));
    return end;
}

fn appendChainTool(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    ws_id: []const u8,
    tool: attestation_reader.RoundTool,
    is_last: bool,
) std.mem.Allocator.Error!void {
    if (out.* >= self.dashboard_chain_rows.len) return;
    const time_txt = try formatHm(ctx.arena, tool.timestamp);
    const verb = toolVerb(tool.kind);
    const head = if (tool.constraint_id) |constraint_id|
        try std.fmt.allocPrint(ctx.arena, "{s}  {s:<6} {s}", .{ time_txt, verb, constraint_id })
    else
        try std.fmt.allocPrint(ctx.arena, "{s}  {s}", .{ time_txt, verb });
    appendChainLine(self, out, firstLineTrimmed(head, width), toolStyle(tool.kind));

    if (tool.rule_id) |rule_id| {
        const rule = try resolveRulePreview(ctx, ws_id, rule_id);
        try appendRulePreview(self, ctx, out, width, rule, .expanded);
    }

    const expanded = toolExpandedText(tool) orelse return;
    if (expanded.len == 0) return;
    const field = if (std.mem.eql(u8, tool.kind, "reject") or std.mem.eql(u8, tool.kind, "refer"))
        "reason"
    else
        "summary";
    try appendEvidenceText(self, ctx, out, width, field, expanded, theme.fg(toolDetailColor(tool.kind)));
    if (!is_last and out.* < self.dashboard_chain_rows.len) {
        appendChainLine(self, out, "", theme.fg(theme.DIM));
    }
}

const RulePreview = struct {
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
) std.mem.Allocator.Error!void {
    const title = try std.fmt.allocPrint(ctx.arena, "  {s}", .{rule.name});
    appendChainLine(self, out, firstLineTrimmed(title, width), theme.fg(theme.TEXT));

    if (rule.path.len > 0) {
        const path = try std.fmt.allocPrint(ctx.arena, "    {s}", .{rule.path});
        appendChainLine(self, out, firstLineTrimmed(path, width), theme.fg(theme.DIM));
    }
    if (density == .expanded and rule.excerpt.len > 0) {
        try appendIndentedText(self, ctx, out, width, rule.excerpt, theme.fg(theme.MUTED));
    }
}

fn appendIndentedText(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    text: []const u8,
    style: vaxis.Style,
) std.mem.Allocator.Error!void {
    const body_w = width -| 4;
    if (body_w == 0) return;
    var remaining = text;
    while (remaining.len > 0 and out.* < self.dashboard_chain_rows.len) {
        var chunk = remaining[0..@min(remaining.len, @as(usize, @intCast(body_w)))];
        while (chunk.len > 0 and !std.unicode.utf8ValidateSlice(chunk)) {
            chunk = chunk[0 .. chunk.len - 1];
        }
        if (chunk.len == 0) break;
        const line = try std.fmt.allocPrint(ctx.arena, "    {s}", .{chunk});
        appendChainLine(self, out, firstLineTrimmed(line, width), style);
        remaining = remaining[chunk.len..];
    }
}

fn appendEvidenceText(
    self: anytype,
    ctx: vxfw.DrawContext,
    out: *usize,
    width: u16,
    label: []const u8,
    text: []const u8,
    style: vaxis.Style,
) std.mem.Allocator.Error!void {
    const head = try std.fmt.allocPrint(ctx.arena, "  {s}", .{label});
    appendChainLine(self, out, firstLineTrimmed(head, width), theme.fg(theme.DIM));
    try appendIndentedText(self, ctx, out, width, text, style);
}

fn toolVerb(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "agent_report")) return "SUBMIT";
    if (std.mem.eql(u8, kind, "refer")) return "REFER";
    if (std.mem.eql(u8, kind, "reject")) return "REJECT";
    if (std.mem.eql(u8, kind, "load")) return "LOAD";
    if (std.mem.eql(u8, kind, "discover")) return "DISCOVER";
    if (std.mem.eql(u8, kind, "search")) return "DISCOVER";
    if (std.mem.eql(u8, kind, "setup")) return "SETUP";
    return kind;
}

fn appendChainLine(self: anytype, out: *usize, text: []const u8, style: vaxis.Style) void {
    if (out.* >= self.dashboard_chain_rows.len) return;
    self.dashboard_chain_rows[out.*] = .{ .text = text, .style = style, .softwrap = false };
    self.dashboard_chain_widgets[out.*] = self.dashboard_chain_rows[out.*].widget();
    out.* += 1;
}

fn toolStyle(kind: []const u8) vaxis.Style {
    if (std.mem.eql(u8, kind, "reject")) return theme.fg(theme.DANGER);
    if (std.mem.eql(u8, kind, "agent_report")) return theme.fg(theme.OK);
    if (std.mem.eql(u8, kind, "refer")) return theme.fg(theme.ACCENT_SOFT);
    return theme.fg(theme.TEXT_SOFT);
}

fn toolExpandedText(tool: attestation_reader.RoundTool) ?[]const u8 {
    if (std.mem.eql(u8, tool.kind, "agent_report")) return tool.summary;
    if (std.mem.eql(u8, tool.kind, "reject")) return tool.reason;
    if (std.mem.eql(u8, tool.kind, "refer")) return tool.reason;
    return null;
}

fn toolDetailColor(kind: []const u8) vaxis.Color {
    if (std.mem.eql(u8, kind, "reject")) return theme.DANGER;
    if (std.mem.eql(u8, kind, "agent_report")) return theme.TEXT_SOFT;
    if (std.mem.eql(u8, kind, "refer")) return theme.ACCENT_SOFT;
    return theme.MUTED;
}

const RoundStatus = struct {
    icon: []const u8,
    color: vaxis.Color,
};

fn roundStatus(round: attestation_reader.RoundEvent) RoundStatus {
    if (round.reject_count > 0) return .{ .icon = "\xc3\x97", .color = theme.DANGER };
    if (round.submit_count > 0 and round.refer_count == 0) return .{ .icon = "\xe2\x97\x87", .color = theme.MUTED };
    if (round.submit_count > 0) return .{ .icon = "\xe2\x97\x86", .color = theme.OK };
    return .{ .icon = "\xe2\x97\x89", .color = theme.ACCENT_SOFT };
}

fn compactSessionId(session_id: []const u8) []const u8 {
    if (session_id.len <= 12) return session_id;
    if (std.mem.startsWith(u8, session_id, "ses-") and session_id.len >= 10) {
        return session_id[0..10];
    }
    return session_id[0..@min(session_id.len, 12)];
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

fn padLine(ctx: vxfw.DrawContext, text: []const u8, width: u16) std.mem.Allocator.Error![]const u8 {
    const current_width = ctx.stringWidth(text);
    if (current_width >= width) return text;
    const missing: usize = @intCast(width - @as(u16, @intCast(current_width)));
    const padded = try ctx.arena.alloc(u8, text.len + missing);
    @memcpy(padded[0..text.len], text);
    @memset(padded[text.len..], ' ');
    return padded;
}
