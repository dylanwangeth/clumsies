const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const w = @import("../widgets.zig");
const data = @import("../view_types.zig");

pub fn drawRoot(
    self: anytype,
    ctx: vxfw.DrawContext,
    insights: *const data.AnalysisData,
    available: bool,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.CANVAS);

    const members_w: u16 = 18;
    const rules_w: u16 = size.width -| members_w;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);

    const main_surface = if (self.analysis_show_member_detail)
        try drawMemberDetail(self, ctx, rules_w, size.height, insights)
    else
        try drawRules(self, ctx, rules_w, size.height, insights, available);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = main_surface };
    children[1] = .{
        .origin = .{ .row = 0, .col = rules_w },
        .surface = try drawMembers(self, ctx, members_w, size.height, insights, available),
    };

    root.children = children;
    return root;
}

pub fn drawRules(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    insights: *const data.AnalysisData,
    available: bool,
) std.mem.Allocator.Error!vxfw.Surface {
    const border_color = theme.focusBorder(self.analysis_focus == .rules);
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);

    w.writeText(&surface, ctx, 3, 0, "Rules Rank", theme.boldOn(theme.PANEL, theme.TEXT));
    const col_reach: u16 = width -| 24;
    const col_trend: u16 = width -| 16;
    const col_last: u16 = width -| 8;
    w.writeText(&surface, ctx, col_reach, 0, "reach", theme.fg(theme.MUTED));
    w.writeText(&surface, ctx, col_trend, 0, "trend", theme.fg(theme.MUTED));
    w.writeText(&surface, ctx, col_last, 0, "last", theme.fg(theme.MUTED));

    if (!available) {
        w.writeText(&surface, ctx, 2, 2, "Remote analysis unavailable.", theme.fg(theme.MUTED));
        w.writeText(
            &surface,
            ctx,
            2,
            3,
            "Analysis now uses hub stats only. Press r to refresh after /api/stats loads.",
            theme.fg(theme.DIM),
        );
        return surface;
    }

    if (insights.rules.len == 0) {
        w.writeText(&surface, ctx, 2, 2, "No rule analysis data returned by the hub.", theme.fg(theme.MUTED));
        return surface;
    }

    var max_refer: u32 = 1;
    for (insights.rules) |rule| {
        if (rule.refer_count > max_refer) max_refer = rule.refer_count;
    }

    const name_col: u16 = 2;
    const min_name_w: u16 = 18;
    const max_name_w: u16 = @max(min_name_w, @min(@as(u16, 40), col_reach -| name_col -| 24));
    var measured_name_w: u16 = min_name_w;
    for (insights.rules) |rule| {
        const candidate = @as(u16, @intCast(ctx.stringWidth(firstLineTrimmed(rule.name, max_name_w))));
        if (candidate > measured_name_w) measured_name_w = candidate;
    }
    const name_w: u16 = @min(max_name_w, measured_name_w);
    const bar_start: u16 = name_col + name_w + 1;
    const bar_end: u16 = col_reach -| 2;
    const bar_max_w: u16 = bar_end -| bar_start;

    const focused = self.analysis_focus == .rules;
    var row: u16 = 1;
    for (insights.rules, 0..) |rule, rule_idx| {
        if (row >= height -| 1) break;
        const is_idle = rule.refer_count == 0;
        const is_sel = rule_idx == self.analysis_rule_cursor and focused;

        if (is_sel) {
            w.writeCursorMarker(&surface, 1, row);
        }

        const name_style: vaxis.Style = if (is_idle)
            (if (is_sel) theme.boldOn(theme.PANEL, theme.DANGER) else .{ .fg = theme.DANGER, .bg = theme.PANEL })
        else if (is_sel)
            theme.boldOn(theme.PANEL, theme.TEXT)
        else
            theme.fg(theme.TEXT_SOFT);
        w.writeText(&surface, ctx, name_col, row, firstLineTrimmed(rule.name, name_w), name_style);

        if (!is_idle) {
            const bar_w_raw: u16 = @intCast(@as(u32, bar_max_w) * rule.refer_count / max_refer);
            const bar_w: u16 = if (rule.refer_count > 0 and bar_w_raw == 0 and bar_max_w > 0) 1 else bar_w_raw;
            for (0..bar_w) |offset| {
                const bc: u16 = bar_start + @as(u16, @intCast(offset));
                if (bc >= bar_end) break;
                const t: f32 = if (bar_w > 1)
                    @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(bar_w - 1))
                else
                    0.5;
                surface.writeCell(bc, row, .{
                    .char = .{ .grapheme = "\xe2\x96\x88", .width = 1 },
                    .style = .{ .fg = theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, t), .bg = theme.PANEL },
                });
            }
            const ref_text = try std.fmt.allocPrint(ctx.arena, " {d}", .{rule.refer_count});
            const ref_col: u16 = bar_start + bar_w;
            if (ref_col + @as(u16, @intCast(ctx.stringWidth(ref_text))) < col_reach) {
                w.writeText(&surface, ctx, ref_col, row, ref_text, theme.fg(theme.TEXT));
            }
        }

        const reach_txt = try std.fmt.allocPrint(ctx.arena, "{d}", .{rule.workspace_count});
        w.writeText(&surface, ctx, col_reach, row, reach_txt, theme.fg(theme.MUTED));
        const trend_summary = try ruleTrendSummary(ctx.arena, rule.trend);
        const trend_style: vaxis.Style = switch (trend_summary.kind) {
            .up => theme.fg(theme.OK),
            .down => theme.fg(theme.DANGER),
            .flat => theme.fg(theme.MUTED),
            .none => theme.fg(theme.DIM),
        };
        w.writeText(&surface, ctx, col_trend, row, trend_summary.text, trend_style);
        const last_txt = if (rule.last_referred_days_ago) |days|
            (try std.fmt.allocPrint(ctx.arena, "{d}d", .{days}))
        else
            "\xe2\x80\x94";
        w.writeText(&surface, ctx, col_last, row, last_txt, theme.fg(theme.MUTED));
        row += 1;

        if (self.analysis_expanded_rule == rule_idx) {
            var constraint_max: u32 = 1;
            for (rule.constraints) |constraint| {
                if (constraint.refer_count > constraint_max) constraint_max = constraint.refer_count;
            }
            for (rule.constraints, 0..) |constraint, constraint_idx| {
                if (row >= height -| 1) break;
                const is_constraint_idle = constraint.refer_count == 0;
                const is_last = constraint_idx + 1 == rule.constraints.len;
                const show_child_id = !std.mem.eql(u8, constraint.id, constraint.label);
                const child_label_col: u16 = if (show_child_id) 12 else 9;
                const child_label = firstLineTrimmed(constraint.label, bar_start -| child_label_col -| 2);
                const child_bar_start: u16 = bar_start + 2;
                const tree_char: []const u8 = if (is_last) "\xe2\x94\x94" else "\xe2\x94\x9c";
                w.writeText(&surface, ctx, 5, row, tree_char, theme.fg(theme.DIM));
                if (show_child_id) {
                    w.writeText(&surface, ctx, 7, row, firstLineTrimmed(constraint.id, 4), theme.fg(theme.MUTED));
                }
                w.writeText(
                    &surface,
                    ctx,
                    child_label_col,
                    row,
                    child_label,
                    if (is_constraint_idle) theme.fg(theme.DANGER) else theme.fg(theme.TEXT_SOFT),
                );
                if (!is_constraint_idle) {
                    const child_bar_max_w: u16 = bar_max_w / 2;
                    const c_bar_w_raw: u16 = @intCast(@min(
                        @as(u32, child_bar_max_w) * constraint.refer_count / constraint_max,
                        child_bar_max_w,
                    ));
                    const c_bar_w: u16 = if (constraint.refer_count > 0 and c_bar_w_raw == 0 and child_bar_max_w > 0) 1 else c_bar_w_raw;
                    for (0..c_bar_w) |offset| {
                        const bc: u16 = child_bar_start + @as(u16, @intCast(offset));
                        if (bc >= col_reach -| 2) break;
                        const t: f32 = if (c_bar_w > 1)
                            @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(c_bar_w - 1))
                        else
                            0.5;
                        surface.writeCell(bc, row, .{
                            .char = .{ .grapheme = "\xe2\x96\x88", .width = 1 },
                            .style = .{ .fg = theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, t), .bg = theme.PANEL },
                        });
                    }
                    const c_ref = try std.fmt.allocPrint(ctx.arena, " {d}", .{constraint.refer_count});
                    w.writeText(&surface, ctx, col_reach, row, c_ref, theme.fg(theme.MUTED));
                } else {
                    const idle_txt = if (constraint.idle_days) |days|
                        try std.fmt.allocPrint(ctx.arena, "idle {d}d \xe2\x9a\xa0", .{days})
                    else
                        "idle \xe2\x9a\xa0";
                    w.writeText(&surface, ctx, col_reach, row, idle_txt, .{ .fg = theme.DANGER, .bg = theme.PANEL });
                }
                row += 1;
            }
        }
    }

    return surface;
}

pub fn drawMembers(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    insights: *const data.AnalysisData,
    available: bool,
) std.mem.Allocator.Error!vxfw.Surface {
    const border_color = theme.focusBorder(self.analysis_focus == .members);
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);

    w.writeText(&surface, ctx, 2, 0, "User Activity", theme.boldOn(theme.PANEL, theme.TEXT));

    if (!available) {
        w.writeText(&surface, ctx, 2, 2, "No", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 2, 3, "stats", theme.fg(theme.MUTED));
        return surface;
    }

    if (insights.members.len == 0) {
        w.writeText(&surface, ctx, 2, 2, "No", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 2, 3, "users", theme.fg(theme.MUTED));
        return surface;
    }

    var member_max: u16 = 1;
    for (insights.members) |member| {
        for (member.trend) |value| {
            if (value > member_max) member_max = value;
        }
    }

    var row: u16 = 1;
    const num_weeks: u16 = (30 + 6) / 7;
    const grid_col: u16 = 2;

    for (insights.members, 0..) |member, member_idx| {
        if (row + 8 >= height) break;
        const is_sel = member_idx == self.analysis_member_cursor and self.analysis_focus == .members;
        if (is_sel) {
            w.writeCursorMarker(&surface, 1, row);
        }
        const name_style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
        w.writeText(&surface, ctx, 2, row, member.username, name_style);
        row += 1;

        var week: u16 = 0;
        while (week < num_weeks) : (week += 1) {
            if (row >= height -| 1) break;
            var day: u16 = 0;
            while (day < 7) : (day += 1) {
                const data_idx = week * 7 + day;
                if (data_idx >= 30) break;
                const value = member.trend[data_idx];
                const max_f: f32 = @floatFromInt(@max(member_max, 1));
                const fg = if (value == 0)
                    theme.rgb(0xffe8b8)
                else
                    theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, @as(f32, @floatFromInt(value)) / max_f);
                const col = grid_col + day * 2;
                if (col < width -| 1) {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = "\xe2\x96\xa0", .width = 1 },
                        .style = .{ .fg = fg, .bg = theme.PANEL },
                    });
                }
            }
            row += 1;
        }
        row += 1;
    }

    return surface;
}

pub fn drawMemberDetail(
    self: anytype,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    insights: *const data.AnalysisData,
) std.mem.Allocator.Error!vxfw.Surface {
    if (insights.members.len == 0) {
        var empty_surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        w.fillSurface(&empty_surface, theme.PANEL);
        w.drawBorder(&empty_surface, theme.BORDER, theme.PANEL);
        w.writeText(&empty_surface, ctx, 2, 2, "No member data available.", theme.fg(theme.MUTED));
        return empty_surface;
    }

    const member_idx = @min(self.analysis_member_cursor, insights.members.len - 1);
    const member = &insights.members[member_idx];
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.ACCENT, theme.PANEL);

    const title = try std.fmt.allocPrint(ctx.arena, "{s}'s Activity", .{member.username});
    w.writeText(&surface, ctx, 3, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
    w.writeRightText(&surface, ctx, 0, "Esc back", theme.fg(theme.MUTED));

    var row: u16 = 2;
    const summary = try std.fmt.allocPrint(ctx.arena, "{d} refs  {d}d active", .{ member.refer_count, member.active_days });
    w.writeText(&surface, ctx, 3, row, summary, theme.fg(theme.TEXT));
    row += 2;

    w.writeText(&surface, ctx, 3, row, "Top Rules", theme.fgBold(theme.TEXT));
    row += 1;
    var max_ref: u32 = 1;
    for (member.top_rules) |top_rule| {
        if (top_rule.refer_count > max_ref) max_ref = top_rule.refer_count;
    }
    const name_col: u16 = 5;
    const count_col: u16 = width -| 7;
    const min_name_w: u16 = 14;
    const max_name_w: u16 = @max(min_name_w, @min(@as(u16, 32), count_col -| name_col -| 12));
    var measured_name_w: u16 = min_name_w;
    for (member.top_rules) |top_rule| {
        const candidate = @as(u16, @intCast(ctx.stringWidth(firstLineTrimmed(top_rule.name, max_name_w))));
        if (candidate > measured_name_w) measured_name_w = candidate;
    }
    const name_w: u16 = @min(max_name_w, measured_name_w);
    const bar_start: u16 = name_col + name_w + 1;
    const bar_end: u16 = count_col -| 1;
    const bar_max_w: u16 = bar_end -| bar_start;
    for (member.top_rules) |top_rule| {
        if (row >= height -| 5) break;
        w.writeText(&surface, ctx, name_col, row, firstLineTrimmed(top_rule.name, name_w), theme.fg(theme.TEXT_SOFT));
        const bar_w_raw: u16 = @intCast(@as(u32, bar_max_w) * top_rule.refer_count / max_ref);
        const bar_w: u16 = if (top_rule.refer_count > 0 and bar_w_raw == 0 and bar_max_w > 0) 1 else bar_w_raw;
        for (0..bar_w) |offset| {
            const bc: u16 = bar_start + @as(u16, @intCast(offset));
            if (bc >= bar_end) break;
            const t: f32 = if (bar_w > 1)
                @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(bar_w - 1))
            else
                0.5;
            surface.writeCell(bc, row, .{
                .char = .{ .grapheme = "\xe2\x96\x88", .width = 1 },
                .style = .{ .fg = theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, t), .bg = theme.PANEL },
            });
        }
        const ref_txt = try std.fmt.allocPrint(ctx.arena, "{d}", .{top_rule.refer_count});
        w.writeText(&surface, ctx, count_col, row, ref_txt, theme.fg(theme.MUTED));
        row += 1;
    }

    return surface;
}

pub fn handleModuleEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
    rule_count: usize,
    member_count: usize,
) anyerror!void {
    if (key.matches(vaxis.Key.tab, .{})) {
        self.analysis_focus = switch (self.analysis_focus) {
            .rules => .members,
            else => .rules,
        };
        self.analysis_expanded_rule = null;
        self.analysis_show_member_detail = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        switch (self.analysis_focus) {
            .rules => {
                if (rule_count > 0 and self.analysis_rule_cursor < rule_count - 1)
                    self.analysis_rule_cursor += 1;
                ctx.consumeAndRedraw();
                return;
            },
            .members => {
                if (member_count > 0 and self.analysis_member_cursor < member_count - 1)
                    self.analysis_member_cursor += 1;
                ctx.consumeAndRedraw();
                return;
            },
            else => {},
        }
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        switch (self.analysis_focus) {
            .rules => {
                self.analysis_rule_cursor -|= 1;
                ctx.consumeAndRedraw();
                return;
            },
            .members => {
                self.analysis_member_cursor -|= 1;
                ctx.consumeAndRedraw();
                return;
            },
            else => {},
        }
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        switch (self.analysis_focus) {
            .rules => {
                if (self.analysis_expanded_rule == self.analysis_rule_cursor) {
                    self.analysis_expanded_rule = null;
                } else {
                    self.analysis_expanded_rule = self.analysis_rule_cursor;
                }
                ctx.consumeAndRedraw();
                return;
            },
            .members => {
                self.analysis_show_member_detail = !self.analysis_show_member_detail;
                ctx.consumeAndRedraw();
                return;
            },
            else => {},
        }
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        if (self.analysis_expanded_rule != null) {
            self.analysis_expanded_rule = null;
        } else if (self.analysis_show_member_detail) {
            self.analysis_show_member_detail = false;
        } else {
            self.analysis_focus = .rules;
        }
        ctx.consumeAndRedraw();
    }
}

const TrendSummaryKind = enum {
    up,
    down,
    flat,
    none,
};

const TrendSummary = struct {
    text: []const u8,
    kind: TrendSummaryKind,
};

fn ruleTrendSummary(
    arena: std.mem.Allocator,
    trend: [30]u16,
) std.mem.Allocator.Error!TrendSummary {
    const window = 7;
    var recent: u32 = 0;
    var previous: u32 = 0;

    for (trend[trend.len - window ..]) |value| recent += value;
    for (trend[trend.len - window * 2 .. trend.len - window]) |value| previous += value;

    if (recent == 0 and previous == 0) {
        return .{ .text = try arena.dupe(u8, "\xe2\x80\x94"), .kind = .none };
    }
    if (previous == 0 and recent > 0) {
        return .{ .text = try arena.dupe(u8, "new"), .kind = .up };
    }
    if (recent == previous) {
        return .{ .text = try arena.dupe(u8, "flat"), .kind = .flat };
    }
    if (recent > previous) {
        const pct = @min(@divTrunc((recent - previous) * 100, previous), 999);
        return .{
            .text = try std.fmt.allocPrint(arena, "+{d}%", .{pct}),
            .kind = .up,
        };
    }

    const pct = @min(@divTrunc((previous - recent) * 100, previous), 999);
    return .{
        .text = try std.fmt.allocPrint(arena, "-{d}%", .{pct}),
        .kind = .down,
    };
}

fn firstLineTrimmed(text: []const u8, max_cells: u16) []const u8 {
    var end: usize = text.len;
    if (std.mem.indexOfScalar(u8, text, '\n')) |newline| end = newline;
    var slice = text[0..end];
    const cap: usize = @intCast(max_cells);
    if (slice.len > cap) slice = slice[0..cap];
    return slice;
}
