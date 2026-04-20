const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const w = @import("../widgets.zig");
const api = @import("../api.zig");
const data = @import("../view_types.zig");
const TableRow = @import("../table_row.zig").TableRow;
const Column = @import("../table_row.zig").Column;
const prompt_detail_panel = @import("prompt_detail.zig");

const MAX_TREE_ROWS = 128;

pub fn drawRoot(
    self: anytype,
    ctx: vxfw.DrawContext,
    list_surface: vxfw.Surface,
    detail_surface: vxfw.Surface,
) std.mem.Allocator.Error!vxfw.Surface {
    return w.splitHorizontal(ctx, self.widget(), theme.PANEL, list_surface, detail_surface, ctx.max.size().width / 3);
}

pub fn drawListPanel(
    self: anytype,
    ctx: vxfw.DrawContext,
    bundle_label: []const u8,
    prompt_count: usize,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    const border_color = w.focusBorder(!self.detail_focus_content);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Library", theme.boldOn(theme.PANEL, theme.TEXT));

    const hint = switch (self.detail_tab) {
        .content => try std.fmt.allocPrint(
            ctx.arena,
            "{d} prompts  bundle: {s}  / search  b filter",
            .{ prompt_count, bundle_label },
        ),
        .pull_requests => blk: {
            const prompts = self.getPrompts();
            const sel_idx = @min(self.selected_prompt, if (prompts.len > 0) prompts.len - 1 else 0);
            if (prompts.len == 0) break :blk @as([]const u8, "no prompts");
            const prs = self.getPrsForPrompt(prompts[sel_idx].path);
            break :blk try std.fmt.allocPrint(
                ctx.arena,
                "{d} PRs  filter:{s}  f cycle",
                .{ prs.len, @tagName(self.pr_filter) },
            );
        },
    };
    w.writeRightText(&surface, ctx, 0, hint, theme.textOn(theme.PANEL, theme.MUTED));

    var tab_col: u16 = 2;
    const tabs = [_]@TypeOf(self.detail_tab){ .content, .pull_requests };
    for (tabs) |tab| {
        tab_col = w.drawInnerTabBadge(&surface, ctx, 2, tab_col, listTabLabel(tab), tab == self.detail_tab);
        tab_col +|= 1;
    }

    const body_origin_row: i17 = 4;
    const body_h: u16 = size.height -| @as(u16, @intCast(body_origin_row)) -| 1;
    const body_w: u16 = size.width -| 3;
    const body_ctx = ctx.withConstraints(
        .{ .width = body_w, .height = body_h },
        .{ .width = body_w, .height = body_h },
    );

    switch (self.detail_tab) {
        .content => {
            self.library_scroll_bars.scroll_view.draw_cursor = false;
            defer self.library_scroll_bars.scroll_view.draw_cursor = true;
            var body = try self.library_scroll_bars.widget().draw(body_ctx);
            if (self.library_tree.rowCount() == 0) {
                const status = blk: {
                    self.api_state.mutex.lock();
                    defer self.api_state.mutex.unlock();
                    break :blk self.api_state.status;
                };
                w.drawEmptyState(&body, ctx, 0, 0, status, "prompts");
            } else {
                try drawListCursor(ctx, &body, &self.library_scroll_bars.scroll_view, theme.PANEL);
            }
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{ .origin = .{ .row = body_origin_row, .col = 2 }, .surface = body };
            surface.children = children;
        },
        .pull_requests => {
            prompt_detail_panel.syncPrWidgets(self);
            self.pr_scroll_bars.scroll_view.draw_cursor = false;
            defer self.pr_scroll_bars.scroll_view.draw_cursor = true;
            var body = try self.pr_scroll_bars.widget().draw(body_ctx);
            if (self.pr_row_count == 0) {
                w.writeText(&body, ctx, 0, 0, "No pull requests for this prompt.", theme.fg(theme.MUTED));
            } else {
                try drawListCursor(ctx, &body, &self.pr_scroll_bars.scroll_view, theme.PANEL);
            }
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{ .origin = .{ .row = body_origin_row, .col = 1 }, .surface = body };
            surface.children = children;
        },
    }
    return surface;
}

fn drawListCursor(
    ctx: vxfw.DrawContext,
    body: *vxfw.Surface,
    scroll_view: *const vxfw.ScrollView,
    bg: vaxis.Color,
) std.mem.Allocator.Error!void {
    const cursor_pos = scroll_view.cursor;
    const scroll_top = scroll_view.scroll.top;
    if (cursor_pos < scroll_top) return;
    const visible_row: i17 = @intCast(cursor_pos - scroll_top);
    if (visible_row >= body.size.height) return;
    const cbuf = try ctx.arena.alloc(vaxis.Cell, 1);
    cbuf[0] = .{
        .char = .{ .grapheme = "▌", .width = 1 },
        .style = .{ .fg = theme.ACCENT_SOFT, .bg = bg },
    };
    const csurface: vxfw.Surface = .{
        .size = .{ .width = 1, .height = 1 },
        .widget = body.widget,
        .buffer = cbuf,
        .children = &.{},
    };
    const old = body.children;
    const new_children = try ctx.arena.alloc(vxfw.SubSurface, old.len + 1);
    @memcpy(new_children[0..old.len], old);
    new_children[old.len] = .{
        .origin = .{ .col = 0, .row = visible_row },
        .surface = csurface,
        .z_index = 1,
    };
    body.children = new_children;
}

fn listTabLabel(tab: anytype) []const u8 {
    return switch (tab) {
        .content => "Files",
        .pull_requests => "Pull Requests",
    };
}

pub fn handleModuleEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    if (key.matches('r', .{})) {
        api.state.invalidateOnDemandCaches(self.api_state);
        self.invalidateRemoteDetailRequests();
        api.fetch.refetchAllAsync(self.api_state);
        self.status_line = "Refreshing data...";
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('b', .{}) and self.detail_tab == .content) {
        const bundle_count = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.bundles) |bundles| break :blk bundles.len;
            break :blk 0;
        };
        self.library_bundle_filter = (self.library_bundle_filter + 1) % (bundle_count + 1);
        self.library_scroll_bars.scroll_view.cursor = 0;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('T', .{ .shift = true }) or key.matches('t', .{ .shift = true })) {
        self.shiftDetailTab(1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.tab, .{})) {
        self.detail_focus_content = !self.detail_focus_content;
        ctx.consumeAndRedraw();
        return;
    }

    if (self.detail_focus_content) {
        try prompt_detail_panel.handleEmbeddedPaneEvent(self, ctx, event, key);
        return;
    }
    switch (self.detail_tab) {
        .content => try handleFileListEvent(self, ctx, event, key),
        .pull_requests => try handlePrListEvent(self, ctx, event, key),
    }
}

fn handleFileListEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    if (key.matches(vaxis.Key.enter, .{})) {
        syncLibraryWidgets(self);
        const pos = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
        if (self.library_tree.dirPathAt(pos)) |dir| {
            self.library_tree.toggleDir(self.api_state.allocator(), dir);
            ctx.consumeAndRedraw();
            return;
        }
        self.detail_focus_content = true;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        syncLibraryWidgets(self);
        const pos = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
        if (self.library_tree.dirPathAt(pos)) |dir| {
            if (self.library_tree.expandDir(self.api_state.allocator(), dir)) {
                ctx.consumeAndRedraw();
                return;
            }
        }
    }
    if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        syncLibraryWidgets(self);
        const pos = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
        if (self.library_tree.dirPathAt(pos)) |dir| {
            if (self.library_tree.collapseDir(dir)) {
                ctx.consumeAndRedraw();
                return;
            }
        }
        if (self.library_tree.parentRow(pos)) |parent| {
            self.library_scroll_bars.scroll_view.cursor = @intCast(parent);
            ctx.consumeAndRedraw();
            return;
        }
    }

    if (self.library_tree.rowCount() == 0) {
        ctx.consumeEvent();
        return;
    }
    try self.library_scroll_bars.scroll_view.handleEvent(ctx, event);

    var pos = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
    if (pos >= self.library_tree.rowCount()) pos = self.library_tree.rowCount() - 1;
    self.library_scroll_bars.scroll_view.cursor = @intCast(pos);

    if (self.library_tree.leafIndexAt(pos)) |prompt_idx| {
        if (self.selected_prompt != prompt_idx) {
            self.selected_prompt = prompt_idx;
            self.selected_pr_idx = 0;
            self.pr_scroll_bars.scroll_view.cursor = 0;
            self.pr_filter = .open;
        }
    }
}

fn handlePrListEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    if (key.matches('f', .{})) {
        self.pr_filter = switch (self.pr_filter) {
            .open => .all,
            .all => .closed,
            .closed => .open,
        };
        self.pr_scroll_bars.scroll_view.cursor = 0;
        self.selected_pr_idx = 0;
        prompt_detail_panel.fetchSelectedPrDetail(self);
        ctx.consumeAndRedraw();
        return;
    }

    prompt_detail_panel.syncPrWidgets(self);
    if (self.pr_row_count == 0) {
        ctx.consumeEvent();
        return;
    }

    const prev = self.pr_scroll_bars.scroll_view.cursor;
    try self.pr_scroll_bars.scroll_view.handleEvent(ctx, event);

    var pos = @as(usize, @intCast(self.pr_scroll_bars.scroll_view.cursor));
    if (pos >= self.pr_row_count) pos = if (self.pr_row_count > 0) self.pr_row_count - 1 else 0;
    if (pos < self.pr_row_count and self.pr_indices[pos] == null) {
        const moving_down = self.pr_scroll_bars.scroll_view.cursor > prev;
        if (moving_down and pos + 1 < self.pr_row_count and self.pr_indices[pos + 1] != null) {
            pos += 1;
        } else {
            pos = @intCast(prev);
        }
    }
    self.pr_scroll_bars.scroll_view.cursor = @intCast(pos);
    if (pos < self.pr_row_count) {
        if (self.pr_indices[pos]) |pr_idx| {
            if (self.selected_pr_idx != pr_idx) {
                self.selected_pr_idx = pr_idx;
                prompt_detail_panel.fetchSelectedPrDetail(self);
            }
        }
    }
}

pub fn syncLibraryWidgets(self: anytype) void {
    const prompts = self.getPrompts();
    const bundles = self.getBundles();
    const filter_name: ?[]const u8 = if (self.library_bundle_filter == 0)
        null
    else if (self.library_bundle_filter - 1 < bundles.len)
        bundles[self.library_bundle_filter - 1].name
    else
        null;

    var filtered_paths: [MAX_TREE_ROWS][]const u8 = undefined;
    var filtered_orig: [MAX_TREE_ROWS]usize = undefined;
    var filtered_len: usize = 0;
    for (prompts, 0..) |p, pidx| {
        if (filter_name) |fname| {
            if (std.mem.indexOf(u8, p.bundle_names, fname) == null) continue;
        }
        if (filtered_len >= MAX_TREE_ROWS) break;
        filtered_paths[filtered_len] = p.path;
        filtered_orig[filtered_len] = pidx;
        filtered_len += 1;
    }

    self.library_tree.sync(self.api_state.allocator(), filtered_paths[0..filtered_len], filtered_orig[0..filtered_len]);

    const row_count = self.library_tree.rowCount();
    const selected_row: usize = if (row_count > 0)
        @min(@as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor)), row_count - 1)
    else
        0;

    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row_text = self.library_tree.rowText(i);
        if (self.library_tree.dirPathAt(i) != null) {
            const row_sel = i == selected_row;
            self.library_text_rows[i] = .{
                .text = row_text,
                .style = theme.boldOn(theme.PANEL, if (row_sel) theme.TEXT else theme.TEXT_SOFT),
            };
            self.library_widgets[i] = self.library_text_rows[i].widget();
        } else {
            const orig_pidx = self.library_tree.leafIndexAt(i) orelse continue;
            const p = prompts[orig_pidx];
            const pr_label: []const u8 = switch (p.open_pr_count) {
                0 => "",
                1 => "\xe2\x80\xa21",
                2 => "\xe2\x80\xa22",
                3 => "\xe2\x80\xa23",
                else => "\xe2\x80\xa2+",
            };
            const row_sel = i == selected_row;
            self.library_table_cols[i] = .{
                .{ .text = row_text, .flex = 1 },
                .{ .text = pr_label, .flex = 0, .min_width = 2, .alignment = .right },
            };
            self.library_table_rows[i] = .{
                .columns = &self.library_table_cols[i],
                .style = theme.textOn(theme.PANEL, if (row_sel) theme.TEXT else theme.TEXT_SOFT),
                .gap = 2,
                .padding_left = 0,
            };
            self.library_widgets[i] = self.library_table_rows[i].widget();
        }
    }
    self.library_scroll_bars.scroll_view.children = .{ .slice = self.library_widgets[0..row_count] };
    self.library_scroll_bars.estimated_content_height = @intCast(row_count);

    var cur = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
    if (cur >= row_count) cur = if (row_count > 0) row_count - 1 else 0;
    self.library_scroll_bars.scroll_view.cursor = @intCast(cur);
    if (cur < row_count) {
        if (self.library_tree.leafIndexAt(cur)) |pi| {
            self.selected_prompt = pi;
        }
    }
}
