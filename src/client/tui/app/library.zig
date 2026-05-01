const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const w = @import("../widgets.zig");
const api = @import("../api.zig");
const data = @import("../models/view_types.zig");
const TableRow = w.TableRow;
const Column = w.Column;
const rule_detail_panel = @import("rule_detail.zig");

const MAX_TREE_ROWS = 128;

pub fn drawRoot(
    self: anytype,
    ctx: vxfw.DrawContext,
    list_surface: vxfw.Surface,
    detail_surface: vxfw.Surface,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    return w.splitHorizontal(ctx, self.widget(), theme.PANEL, list_surface, detail_surface, size.width / 3);
}

pub fn drawListPanel(
    self: anytype,
    ctx: vxfw.DrawContext,
    bundle_label: []const u8,
    rule_count: usize,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    const border_color = theme.focusBorder(!self.detail_focus_content);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);

    // Inner tab strip sits on the top border line (row 0), the same
    // shape the right panel uses for its section badges. The subtitle
    // goes on row 0 top-right only if what's left after the tab strip
    // has room for it — otherwise drop it rather than stomp the tabs.
    var tab_col: u16 = 2;
    const tabs = [_]@TypeOf(self.detail_tab){ .content, .pull_requests };
    for (tabs) |tab| {
        tab_col = w.drawInnerTabBadge(&surface, ctx, 0, tab_col, listTabLabel(tab), tab == self.detail_tab);
        tab_col +|= 1;
    }

    const hint = switch (self.detail_tab) {
        .content => try std.fmt.allocPrint(
            ctx.arena,
            "{d} rules  bundle: {s}  / search  b filter",
            .{ rule_count, bundle_label },
        ),
        .pull_requests => blk: {
            const rules = self.getRules();
            const sel_idx = @min(self.selected_rule, if (rules.len > 0) rules.len - 1 else 0);
            if (rules.len == 0) break :blk @as([]const u8, "no rules");
            const prs = self.getPrsForRule(rules[sel_idx].path);
            break :blk try std.fmt.allocPrint(
                ctx.arena,
                "{d} PRs  filter:{s}  f cycle",
                .{ prs.len, @tagName(self.pr_filter) },
            );
        },
    };
    const hint_w: u16 = @intCast(ctx.stringWidth(hint));
    if (hint_w > 0 and hint_w < size.width -| tab_col -| 2) {
        w.writeRightText(&surface, ctx, 0, hint, theme.textOn(theme.PANEL, theme.MUTED));
    }

    // Body sits one row below the top border (row 1) and two
    // columns in (col=2). The cursor bar is written directly onto
    // the outer surface at col=1 — the left-border inside — so it
    // does not overlap tree text, which starts at col=2.
    const body_origin_row: u16 = 1;
    const body_origin_col: u16 = 2;
    const body_h: u16 = size.height -| body_origin_row -| 1;
    const body_w: u16 = size.width -| body_origin_col -| 1;
    const body_ctx = ctx.withConstraints(
        .{ .width = body_w, .height = body_h },
        .{ .width = body_w, .height = body_h },
    );

    switch (self.detail_tab) {
        .content => {
            if (self.library_tree.rowCount() == 0) {
                const status = blk: {
                    self.api_state.mutex.lock();
                    defer self.api_state.mutex.unlock();
                    break :blk self.api_state.status;
                };
                // Write on the outer panel surface: the ScrollBars
                // composite returns a buffer-less surface whose
                // writeCell would trip the vxfw assert.
                w.drawEmptyState(&surface, ctx, body_origin_col, body_origin_row, status, "rules");
            } else {
                self.library_scroll_bars.scroll_view.draw_cursor = false;
                defer self.library_scroll_bars.scroll_view.draw_cursor = true;
                const body = try self.library_scroll_bars.widget().draw(body_ctx);
                const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                children[0] = .{ .origin = .{ .row = body_origin_row, .col = body_origin_col }, .surface = body };
                surface.children = children;
                writeCursorBar(&surface, &self.library_scroll_bars.scroll_view, body_origin_row, body_h);
            }
        },
        .pull_requests => {
            rule_detail_panel.syncPrWidgets(self);
            if (self.pr_row_count == 0) {
                w.writeText(&surface, ctx, body_origin_col, body_origin_row, "No pull requests for this rule.", theme.fg(theme.MUTED));
            } else {
                self.pr_scroll_bars.scroll_view.draw_cursor = false;
                defer self.pr_scroll_bars.scroll_view.draw_cursor = true;
                const body = try self.pr_scroll_bars.widget().draw(body_ctx);
                const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                children[0] = .{ .origin = .{ .row = body_origin_row, .col = body_origin_col }, .surface = body };
                surface.children = children;
                writeCursorBar(&surface, &self.pr_scroll_bars.scroll_view, body_origin_row, body_h);
            }
        },
    }
    return surface;
}

/// Draw the accent cursor bar directly on the panel surface at
/// col=1, which is the one-cell gutter between the left border and
/// the body at col=2. Keeping the cursor on the outer surface lets
/// the body render tree text from col=0 without the bar colliding
/// with the first character of each row.
fn writeCursorBar(
    surface: *vxfw.Surface,
    scroll_view: *const vxfw.ScrollView,
    body_origin_row: u16,
    body_h: u16,
) void {
    const cursor_pos = scroll_view.cursor;
    const scroll_top = scroll_view.scroll.top;
    if (cursor_pos < scroll_top) return;
    const visible_row = cursor_pos - scroll_top;
    if (visible_row >= body_h) return;
    const row = body_origin_row + @as(u16, @intCast(visible_row));
    surface.writeCell(1, row, .{
        .char = .{ .grapheme = "▌", .width = 1 },
        .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
    });
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
        resetScrollView(&self.library_scroll_bars.scroll_view);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(']', .{})) {
        self.shiftDetailTab(1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('[', .{})) {
        self.shiftDetailTab(-1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('n', .{}) and self.detail_tab == .content and !self.detail_focus_content) {
        self.openNewDraftForm(.rule);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('y', .{}) and self.detail_tab == .content) {
        if (self.copySelectedContentId()) {
            ctx.consumeAndRedraw();
        } else {
            self.status_line = "No id to copy.";
            ctx.consumeAndRedraw();
        }
        return;
    }
    if (key.matches(vaxis.Key.tab, .{})) {
        self.detail_focus_content = !self.detail_focus_content;
        ctx.consumeAndRedraw();
        return;
    }

    if (self.detail_focus_content) {
        try rule_detail_panel.handleEmbeddedPaneEvent(self, ctx, event, key);
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
            self.library_scroll_bars.scroll_view.ensureScroll();
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

    if (self.library_tree.leafIndexAt(pos)) |rule_idx| {
        if (self.selected_rule != rule_idx) {
            self.selected_rule = rule_idx;
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
        rule_detail_panel.fetchSelectedPrDetail(self);
        ctx.consumeAndRedraw();
        return;
    }

    rule_detail_panel.syncPrWidgets(self);
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
                rule_detail_panel.fetchSelectedPrDetail(self);
            }
        }
    }
}

pub fn syncLibraryWidgets(self: anytype) void {
    const rules = self.getRules();
    const bundles = self.getBundles();
    const create_paths = self.drafts_create_rule_paths;
    const filter_name: ?[]const u8 = if (self.library_bundle_filter == 0)
        null
    else if (self.library_bundle_filter - 1 < bundles.len)
        bundles[self.library_bundle_filter - 1].name
    else
        null;

    var filtered_paths: [MAX_TREE_ROWS][]const u8 = undefined;
    var filtered_orig: [MAX_TREE_ROWS]usize = undefined;
    var filtered_len: usize = 0;
    for (rules, 0..) |p, pidx| {
        if (filter_name) |fname| {
            if (std.mem.indexOf(u8, p.bundle_names, fname) == null) continue;
        }
        if (filtered_len >= MAX_TREE_ROWS) break;
        filtered_paths[filtered_len] = p.path;
        filtered_orig[filtered_len] = pidx;
        filtered_len += 1;
    }

    // Append local create-op drafts as virtual rows. Tree-leaf index
    // is `rules.len + k` so selectedDraftTarget can tell virtual
    // rows from server-backed rows by the index range. Bundle filter
    // does not constrain create drafts — the user created them
    // locally, they should always be visible.
    for (create_paths, 0..) |path, k| {
        if (filtered_len >= MAX_TREE_ROWS) break;
        filtered_paths[filtered_len] = path;
        filtered_orig[filtered_len] = rules.len + k;
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
            const is_virtual = orig_pidx >= rules.len;
            const row_path: []const u8 = if (is_virtual) blk: {
                const k = orig_pidx - rules.len;
                if (k >= create_paths.len) continue;
                break :blk create_paths[k];
            } else rules[orig_pidx].path;
            const pr_label: []const u8 = if (is_virtual) "" else switch (rules[orig_pidx].open_pr_count) {
                0 => "",
                1 => "\xe2\x80\xa21",
                2 => "\xe2\x80\xa22",
                3 => "\xe2\x80\xa23",
                else => "\xe2\x80\xa2+",
            };
            const row_sel = i == selected_row;
            const draft_status_opt = self.draftStatusFor(self.libraryCategoryForPath(row_path), row_path);
            const labeled_text = if (draft_status_opt != null)
                (std.fmt.allocPrint(self.viewAllocator(), "{s} *", .{row_text}) catch row_text)
            else
                row_text;
            const row_style = w.draftRowStyle(row_sel, draft_status_opt);
            self.library_table_cols[i] = .{
                .{ .text = labeled_text, .flex = 1 },
                .{ .text = pr_label, .flex = 0, .min_width = 2, .alignment = .right },
            };
            self.library_table_rows[i] = .{
                .columns = &self.library_table_cols[i],
                .style = row_style,
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
    clampScrollTop(&self.library_scroll_bars.scroll_view, row_count);
    if (cur < row_count) {
        if (self.library_tree.leafIndexAt(cur)) |pi| {
            self.selected_rule = pi;
        }
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
