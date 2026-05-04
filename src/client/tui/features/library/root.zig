//! Library feature container. Owns rule/bundle navigation state and syncs
//! list widgets for the organization rule collection.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../../theme.zig");
const w = @import("../../widgets.zig");
const api = @import("../../api.zig");
const data = @import("../../models/view_types.zig");
const TableRow = w.TableRow;
const Column = w.Column;
const rule_detail_panel = @import("../review/root.zig");
const content_actions = @import("../content_actions.zig");

const MAX_TREE_ROWS = 128;
const PathTreeState = @import("../../models.zig").path_tree.State(MAX_TREE_ROWS, 96);

pub const State = struct {
    selected_rule: usize = 0,
    bundle_filter: usize = 0,
    scroll_bars: vxfw.ScrollBars,
    tree: PathTreeState = .{},

    pub fn init() State {
        return .{ .scroll_bars = w.initCursorScrollBars(theme.PANEL) };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.tree.deinit(allocator);
    }
};

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
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    const border_color = theme.focusBorder(!self.review.detail_focus_content);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);

    w.writeText(&surface, ctx, 2, 0, "Rules", theme.boldOn(theme.PANEL, theme.TEXT));

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

    if (self.library.tree.rowCount() == 0) {
        const status = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            break :blk self.api_state.status;
        };
        w.drawEmptyState(&surface, ctx, body_origin_col, body_origin_row, status, "rules");
    } else {
        const body = try self.library.scroll_bars.widget().draw(body_ctx);
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = body_origin_row, .col = body_origin_col }, .surface = body };
        surface.children = children;
        writeCursorBar(&surface, &self.library.scroll_bars.scroll_view, body_origin_row, body_h);
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

pub fn handleModuleEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    self.review.detail_tab = .content;
    if (key.matches('r', .{})) {
        api.state.invalidateOnDemandCaches(self.api_state);
        self.invalidateRemoteDetailRequests();
        api.fetch.refetchAllAsync(self.api_state);
        self.notifyOp(.loading, "Reloading remote metadata...");
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('b', .{})) {
        const bundle_count = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.bundles) |bundles| break :blk bundles.len;
            break :blk 0;
        };
        self.library.bundle_filter = (self.library.bundle_filter + 1) % (bundle_count + 1);
        resetScrollView(&self.library.scroll_bars.scroll_view);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('n', .{})) {
        self.openNewDraftForm(.rule);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('y', .{})) {
        _ = content_actions.handle(self, ctx, key, .library);
        return;
    }
    if (content_actions.handle(self, ctx, key, .library)) return;
    if (key.matches(vaxis.Key.tab, .{})) {
        self.review.detail_focus_content = !self.review.detail_focus_content;
        ctx.consumeAndRedraw();
        return;
    }

    if (self.review.detail_focus_content) {
        try rule_detail_panel.handleEmbeddedPaneEvent(self, ctx, event, key);
        return;
    }
    try handleFileListEvent(self, ctx, event, key);
}

pub fn shortcuts(self: anytype) []const w.Shortcut {
    _ = self;
    return content_actions.libraryContentShortcuts();
}

fn handleFileListEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    _ = event;
    if (key.matches(vaxis.Key.enter, .{})) {
        syncLibraryTree(self);
        const pos = @as(usize, @intCast(self.library.scroll_bars.scroll_view.cursor));
        if (self.library.tree.dirPathAt(pos)) |dir| {
            self.library.tree.toggleDir(self.api_state.allocator(), dir);
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('z', .{})) {
        syncLibraryTree(self);
        self.library.tree.toggleAll(self.api_state.allocator());
        syncLibraryTree(self);
        ctx.consumeAndRedraw();
        return;
    }

    if (self.library.tree.rowCount() == 0) {
        ctx.consumeEvent();
        return;
    }
    const count = self.library.tree.rowCount();
    const step = w.stepForKey(key, &self.library.scroll_bars.scroll_view) orelse return;

    var pos = @as(usize, @intCast(self.library.scroll_bars.scroll_view.cursor));
    _ = w.moveCursorBy(&pos, count, step);
    self.library.scroll_bars.scroll_view.cursor = @intCast(pos);
    w.scrollCursorIntoView(&self.library.scroll_bars.scroll_view, count);

    if (self.library.tree.leafIndexAt(pos)) |rule_idx| {
        if (self.library.selected_rule != rule_idx) {
            self.library.selected_rule = rule_idx;
            self.review.selected_pr_idx = 0;
            self.review.pr_scroll_bars.scroll_view.cursor = 0;
            self.review.pr_filter = .open;
            self.review.hide_diff = false;
        }
    }
    ctx.consumeAndRedraw();
}

fn handlePrListEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    _ = event;
    if (key.matches('f', .{})) {
        self.review.pr_filter = switch (self.review.pr_filter) {
            .open => .all,
            .all => .closed,
            .closed => .open,
        };
        self.review.pr_scroll_bars.scroll_view.cursor = 0;
        self.review.selected_pr_idx = 0;
        rule_detail_panel.fetchSelectedPrDetail(self);
        ctx.consumeAndRedraw();
        return;
    }

    rule_detail_panel.syncPrWidgets(self);
    if (self.review.pr_row_count == 0) {
        ctx.consumeEvent();
        return;
    }

    var pos = @as(usize, @intCast(self.review.pr_scroll_bars.scroll_view.cursor));
    if (pos >= self.review.pr_row_count) pos = if (self.review.pr_row_count > 0) self.review.pr_row_count - 1 else 0;
    const step = w.stepForKey(key, &self.review.pr_scroll_bars.scroll_view) orelse return;
    pos = w.moveSelectableRowByVisualRows(pos, self.review.pr_row_count, self.review.pr_indices[0..self.review.pr_row_count], step);
    self.review.pr_scroll_bars.scroll_view.cursor = @intCast(pos);
    w.scrollCursorIntoView(&self.review.pr_scroll_bars.scroll_view, self.review.pr_row_count);
    if (pos < self.review.pr_row_count) {
        if (self.review.pr_indices[pos]) |pr_idx| {
            if (self.review.selected_pr_idx != pr_idx) {
                self.review.selected_pr_idx = pr_idx;
                rule_detail_panel.fetchSelectedPrDetail(self);
            }
        }
    }
    ctx.consumeAndRedraw();
}

pub fn syncLibraryTree(self: anytype) void {
    const rules = self.getRules();
    const bundles = self.getBundles();
    const create_paths = self.drafts.create_rule_paths;
    const filter_name: ?[]const u8 = if (self.library.bundle_filter == 0)
        null
    else if (self.library.bundle_filter - 1 < bundles.len)
        bundles[self.library.bundle_filter - 1].name
    else
        null;

    const allocator = self.api_state.allocator();
    const path_capacity = rules.len + create_paths.len;
    const filtered_paths = allocator.alloc([]const u8, path_capacity) catch return;
    defer allocator.free(filtered_paths);
    const filtered_orig = allocator.alloc(usize, path_capacity) catch return;
    defer allocator.free(filtered_orig);
    var filtered_len: usize = 0;
    for (rules, 0..) |p, pidx| {
        if (filter_name) |fname| {
            if (std.mem.indexOf(u8, p.bundle_names, fname) == null) continue;
        }
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
        filtered_paths[filtered_len] = path;
        filtered_orig[filtered_len] = rules.len + k;
        filtered_len += 1;
    }

    self.library.tree.sync(allocator, filtered_paths[0..filtered_len], filtered_orig[0..filtered_len]);
}

pub fn syncLibraryWidgets(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!void {
    syncLibraryTree(self);

    const rules = self.getRules();
    const create_paths = self.drafts.create_rule_paths;
    const row_count = self.library.tree.rowCount();
    const widgets = try ctx.arena.alloc(vxfw.Widget, row_count);
    const text_rows = try ctx.arena.alloc(vxfw.Text, row_count);
    const table_rows = try ctx.arena.alloc(TableRow, row_count);
    const table_cols = try ctx.arena.alloc([2]Column, row_count);
    const selected_row: usize = if (row_count > 0)
        @min(@as(usize, @intCast(self.library.scroll_bars.scroll_view.cursor)), row_count - 1)
    else
        0;

    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row_text = self.library.tree.rowText(i);
        if (self.library.tree.dirPathAt(i) != null) {
            const row_sel = i == selected_row;
            text_rows[i] = .{
                .text = row_text,
                .style = theme.boldOn(theme.PANEL, if (row_sel) theme.TEXT else theme.TEXT_SOFT),
            };
            widgets[i] = text_rows[i].widget();
        } else {
            const orig_pidx = self.library.tree.leafIndexAt(i) orelse continue;
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
            const category = self.libraryCategoryForPath(row_path);
            const draft_status_opt = self.draftStatusFor(category, row_path);
            const row_style = w.draftRowStyle(row_sel, draft_status_opt);
            table_cols[i] = .{
                .{ .text = row_text, .flex = 1 },
                .{ .text = pr_label, .flex = 0, .min_width = 2, .alignment = .right },
            };
            table_rows[i] = .{
                .columns = &table_cols[i],
                .style = row_style,
                .gap = 2,
                .padding_left = 0,
            };
            widgets[i] = table_rows[i].widget();
        }
    }
    self.library.scroll_bars.scroll_view.children = .{ .slice = widgets };
    self.library.scroll_bars.estimated_content_height = @intCast(row_count);

    var cur = @as(usize, @intCast(self.library.scroll_bars.scroll_view.cursor));
    if (cur >= row_count) cur = if (row_count > 0) row_count - 1 else 0;
    self.library.scroll_bars.scroll_view.cursor = @intCast(cur);
    clampScrollTop(&self.library.scroll_bars.scroll_view, row_count);
    if (cur < row_count) {
        if (self.library.tree.leafIndexAt(cur)) |pi| {
            if (self.library.selected_rule != pi) {
                self.library.selected_rule = pi;
                self.review.hide_diff = false;
            }
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
    w.clampScrollTop(scroll_view, row_count);
}
