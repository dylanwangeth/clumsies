const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const w = @import("../widgets.zig");
const attestation_reader = @import("../attestation_reader.zig");
const Modal = w.Modal;

pub fn drawRoot(
    self: anytype,
    ctx: vxfw.DrawContext,
    chart_surface: vxfw.Surface,
    inputs_surface: vxfw.Surface,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.CANVAS);

    const chart_h: u16 = if (size.height > 40) 10 else 8;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = chart_surface };
    children[1] = .{ .origin = .{ .row = chart_h, .col = 0 }, .surface = inputs_surface };
    root.children = children;
    return root;
}

pub fn drawChart(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    signal_value_text: []const u8,
    series: anytype,
    scope_label: []const u8,
    active_session_count: usize,
) std.mem.Allocator.Error!vxfw.Surface {
    const border_color = theme.focusBorder(self.analysis_focus == .chart);
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);

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

    const right_hint = "w scope  Shift-F flush";
    const right_hint_w: u16 = @intCast(ctx.stringWidth(right_hint));
    const right_limit: u16 = width -| right_hint_w -| 2;

    var header_col: u16 = 3;
    const lead_gap = " ";
    if (header_col < right_limit) {
        w.writeText(&surface, ctx, header_col, 0, lead_gap, theme.textOn(theme.PANEL, theme.TEXT));
        header_col +|= @intCast(ctx.stringWidth(lead_gap));
    }
    const title_txt = "Signal Trend";
    if (header_col < right_limit) {
        w.writeText(&surface, ctx, header_col, 0, title_txt, theme.boldOn(theme.PANEL, theme.TEXT));
        header_col +|= @intCast(ctx.stringWidth(title_txt));
    }
    const sep_txt = "  \xc2\xb7 ";
    if (header_col < right_limit) {
        w.writeText(&surface, ctx, header_col, 0, sep_txt, theme.fg(theme.MUTED));
        header_col +|= @intCast(ctx.stringWidth(sep_txt));
    }
    if (header_col < right_limit) {
        w.writeText(&surface, ctx, header_col, 0, scope_label, theme.boldOn(theme.PANEL, theme.TEXT));
        header_col +|= @intCast(ctx.stringWidth(scope_label));
    }
    if (header_col < right_limit) {
        w.writeText(&surface, ctx, header_col, 0, sep_txt, theme.fg(theme.MUTED));
        header_col +|= @intCast(ctx.stringWidth(sep_txt));
    }
    if (header_col < right_limit) {
        w.writeText(&surface, ctx, header_col, 0, "signal", theme.boldOn(theme.PANEL, theme.TEXT));
        header_col +|= @intCast(ctx.stringWidth("signal"));
    }
    if (header_col < right_limit) {
        w.writeText(&surface, ctx, header_col, 0, " ", theme.fg(theme.MUTED));
        header_col +|= 1;
    }
    if (header_col < right_limit) {
        const signal_style = if (std.mem.eql(u8, signal_value_text, "n/a"))
            theme.fg(theme.MUTED)
        else
            theme.fg(theme.TEXT_SOFT);
        w.writeText(&surface, ctx, header_col, 0, signal_value_text, signal_style);
        header_col +|= @intCast(ctx.stringWidth(signal_value_text));
    }

    if (active_session_count > 0) {
        const session_txt = try std.fmt.allocPrint(ctx.arena, "{d} live", .{active_session_count});
        if (header_col < right_limit) {
            w.writeText(&surface, ctx, header_col, 0, sep_txt, theme.fg(theme.MUTED));
            header_col +|= @intCast(ctx.stringWidth(sep_txt));
        }
        if (header_col < right_limit) {
            w.writeText(&surface, ctx, header_col, 0, session_txt, .{ .fg = theme.OK, .bg = theme.PANEL });
        }
    }

    w.writeRightText(&surface, ctx, 0, right_hint, theme.fg(theme.MUTED));

    const chart_x: u16 = 1;
    const chart_w: u16 = width -| 2;
    const chart_rows: u16 = height -| 3;
    w.drawBrailleAreaChart(&surface, series.values, chart_x, 1, chart_w, chart_rows);
    w.writeText(&surface, ctx, chart_x, height -| 2, series.left_label, theme.fg(theme.DIM));
    w.writeRightText(&surface, ctx, height -| 2, series.right_label, theme.fg(theme.DIM));

    return surface;
}

pub fn drawInputs(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    visible_inputs: []const attestation_reader.InputEvent,
    scope_label: []const u8,
) std.mem.Allocator.Error!vxfw.Surface {
    const border_color = theme.focusBorder(self.analysis_focus == .inputs);
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);

    const title_txt = try std.fmt.allocPrint(
        ctx.arena,
        "Recent Inputs  \xc2\xb7 {s}  \xc2\xb7 live feed",
        .{scope_label},
    );
    w.writeText(&surface, ctx, 2, 0, title_txt, theme.boldOn(theme.PANEL, theme.TEXT));

    if (visible_inputs.len == 0) {
        w.writeText(&surface, ctx, 2, 2, "No recent user rules captured.", theme.fg(theme.MUTED));
        return surface;
    }

    const focused = self.analysis_focus == .inputs;
    const inner_w: u16 = width -| 4;
    const body_col: u16 = 3;
    const content_w: u16 = inner_w -| 4;
    var row: u16 = 1;
    var index: usize = 0;
    while (index < visible_inputs.len and row + 1 < height -| 1) : (index += 1) {
        const input = visible_inputs[index];
        const is_sel = focused and index == self.analysis_input_cursor;
        const ws_label = workspaceNameForId(self, input.ws_id);
        const session_label = compactSessionId(input.session_id);
        const time_txt = try formatHm(ctx.arena, input.timestamp);
        const meta_label = if (std.mem.eql(u8, scope_label, "All Workspaces"))
            try std.fmt.allocPrint(ctx.arena, "{s}  \xc2\xb7 {s}  \xc2\xb7 input", .{ ws_label, session_label })
        else
            try std.fmt.allocPrint(ctx.arena, "{s}  \xc2\xb7 input", .{session_label});
        const meta_style: vaxis.Style = if (is_sel)
            theme.boldOn(theme.PANEL, theme.ACCENT_SOFT)
        else
            .{ .fg = theme.MUTED, .bg = theme.PANEL };
        w.writeText(&surface, ctx, body_col, row, firstLineTrimmed(meta_label, content_w), meta_style);
        w.writeRightText(&surface, ctx, row, time_txt, .{
            .fg = if (is_sel) theme.ACCENT_SOFT else theme.MUTED,
            .bg = theme.PANEL,
        });

        const snippet = firstLineTrimmed(input.content, content_w);
        const body_style: vaxis.Style = if (is_sel)
            theme.boldOn(theme.PANEL, theme.TEXT)
        else
            .{ .fg = theme.TEXT_SOFT, .bg = theme.PANEL };
        w.writeText(&surface, ctx, body_col, row + 1, snippet, body_style);

        if (index + 1 < visible_inputs.len and row + 2 < height -| 1) {
            var sep_col: u16 = 2;
            while (sep_col < width -| 2) : (sep_col += 1) {
                surface.writeCell(sep_col, row + 2, .{
                    .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 },
                    .style = .{
                        .fg = if (is_sel) theme.ACCENT_SOFT else theme.BORDER,
                        .bg = theme.PANEL,
                    },
                });
            }
        }
        row += 3;
    }

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
    input_count: usize,
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
            if (input_count > 0 and self.analysis_input_cursor < input_count - 1)
                self.analysis_input_cursor += 1;
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.analysis_focus == .inputs) {
            self.analysis_input_cursor -|= 1;
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

fn workspaceNameForId(self: anytype, ws_id: []const u8) []const u8 {
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    const user = self.api_state.current_user orelse return ws_id;
    for (user.workspaces) |ws| {
        if (std.mem.eql(u8, ws.ws_id, ws_id)) return ws.name;
    }
    return ws_id;
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
    return slice;
}
