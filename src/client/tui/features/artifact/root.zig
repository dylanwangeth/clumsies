//! Artifact feature container. Owns rule/bundle navigation state and syncs
//! list widgets for the organization rule collection.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../../theme.zig");
const w = @import("../../widgets.zig");
const api_model = @import("../../api/model.zig");
const rule_detail_panel = @import("../review/root.zig");
const content_actions = @import("../content_actions.zig");

const MAX_TREE_ROWS = 128;
const PathTreeState = @import("../../models.zig").path_tree.State(MAX_TREE_ROWS, 96);

const BundleDrawerMode = enum {
    browse,
    add_selected,
};

pub const State = struct {
    selected_rule: usize = 0,
    has_selected_rule: bool = false,
    list_machine: w.TreeList.Machine = .{},
    bundle_filter: usize = 0,
    show_bundle_drawer: bool = false,
    bundle_drawer_mode: BundleDrawerMode = .browse,
    bundle_cursor: usize = 0,
    new_bundle_name_buf: [96]u8 = undefined,
    new_bundle_name_len: usize = 0,
    show_workspace_drawer: bool = false,
    workspace_cursor: usize = 0,
    last_synced_bundle_filter: usize = std.math.maxInt(usize),
    scroll_bars: vxfw.ScrollBars,
    tree: PathTreeState = .{},

    pub fn init() State {
        return .{ .scroll_bars = w.initCursorScrollBars(theme.PANEL) };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.tree.deinit(allocator);
        self.list_machine.deinit(allocator);
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

    const title = "Rules";
    w.writeTextMax(&surface, ctx, 2, 0, size.width -| 4, title, theme.boldOn(theme.PANEL, theme.TEXT));
    if (artifactListSubtitle(self)) |subtitle| {
        const title_w: u16 = @intCast(ctx.stringWidth(title));
        _ = w.writeHeaderRightIfFits(&surface, ctx, 0, 2 + title_w + 2, subtitle, theme.textOn(theme.PANEL, theme.MUTED));
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

    if (self.artifact.tree.rowCount() == 0) {
        const status = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            break :blk self.api_state.status;
        };
        w.drawEmptyState(&surface, ctx, body_origin_col, body_origin_row, status, "rules");
    } else {
        const body = try self.artifact.scroll_bars.widget().draw(body_ctx);
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = body_origin_row, .col = body_origin_col }, .surface = body };
        surface.children = children;
        writeCursorBar(&surface, &self.artifact.scroll_bars.scroll_view, body_origin_row, body_h);
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
    if (self.artifact.show_bundle_drawer) {
        handleBundleDrawerKey(self, ctx, key);
        return;
    }
    if (self.artifact.show_workspace_drawer) {
        handleWorkspaceDrawerKey(self, ctx, key);
        return;
    }
    if (key.matches('b', .{})) {
        self.artifact.show_bundle_drawer = true;
        self.artifact.bundle_drawer_mode = .browse;
        self.artifact.bundle_cursor = self.artifact.bundle_filter;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('i', .{})) {
        if (!self.artifact.list_machine.selection_mode) {
            self.notifyOp(.warning, "Enter selection mode first.");
            ctx.consumeAndRedraw();
            return;
        }
        if (self.artifact.list_machine.selectedCount() == 0) {
            self.notifyOp(.warning, "Select rules first.");
            ctx.consumeAndRedraw();
            return;
        }
        if (workspaceChoiceCount(self) == 0) {
            self.notifyOp(.warning, "No workspace available.");
            ctx.consumeAndRedraw();
            return;
        }
        self.artifact.show_workspace_drawer = true;
        self.artifact.workspace_cursor = @min(self.workspace.sel, workspaceChoiceCount(self) - 1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('a', .{})) {
        if (!self.artifact.list_machine.selection_mode) {
            self.notifyOp(.warning, "Enter selection mode first.");
            ctx.consumeAndRedraw();
            return;
        }
        if (self.artifact.bundle_filter != 0) {
            self.notifyOp(.warning, "Switch to All rules before adding to a bundle.");
            ctx.consumeAndRedraw();
            return;
        }
        if (self.artifact.list_machine.selectedCount() == 0) {
            self.notifyOp(.warning, "Select rules first.");
            ctx.consumeAndRedraw();
            return;
        }
        self.artifact.show_bundle_drawer = true;
        self.artifact.bundle_drawer_mode = .add_selected;
        self.artifact.bundle_cursor = 0;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('x', .{})) {
        if (!self.artifact.list_machine.selection_mode) {
            self.notifyOp(.warning, "Enter selection mode first.");
            ctx.consumeAndRedraw();
            return;
        }
        if (self.artifact.bundle_filter == 0) {
            self.notifyOp(.warning, "Open a bundle before removing rules.");
            ctx.consumeAndRedraw();
            return;
        }
        if (self.artifact.list_machine.selectedCount() == 0) {
            self.notifyOp(.warning, "Select rules first.");
            ctx.consumeAndRedraw();
            return;
        }
        self.confirmRemoveSelectedRulesFromBundle();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('n', .{})) {
        self.openNewDraftForm(.rule);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('y', .{})) {
        _ = content_actions.handle(self, ctx, key, .artifact);
        return;
    }
    if (content_actions.handle(self, ctx, key, .artifact)) return;
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
    if (self.artifact.show_bundle_drawer) return &.{
        .{ .key = "j/k", .label = "move" },
        .{ .key = "Enter", .label = "select" },
        .{ .key = "Esc", .label = "close" },
    };
    if (self.artifact.show_workspace_drawer) return &.{
        .{ .key = "j/k", .label = "move" },
        .{ .key = "Enter", .label = "select" },
        .{ .key = "Esc", .label = "close" },
    };
    if (self.artifact.list_machine.selection_mode) {
        if (self.artifact.bundle_filter == 0) return &.{
            .{ .key = "j/k", .label = "move/scroll" },
            .{ .key = "Space", .label = "toggle" },
            .{ .key = "a", .label = "add to bundle" },
            .{ .key = "i", .label = "import to workspace" },
            .{ .key = "Esc", .label = "cancel" },
        };
        return &.{
            .{ .key = "j/k", .label = "move/scroll" },
            .{ .key = "Space", .label = "toggle" },
            .{ .key = "x", .label = "remove from bundle" },
            .{ .key = "i", .label = "import to workspace" },
            .{ .key = "Esc", .label = "cancel" },
        };
    }
    return content_actions.artifactContentShortcuts();
}

fn handleFileListEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    _ = event;
    if (key.matches(vaxis.Key.escape, .{})) {
        if (self.artifact.list_machine.selection_mode) {
            self.artifact.list_machine.exitSelectionMode();
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        syncArtifactTree(self);
        self.artifact.list_machine.cursor = @intCast(self.artifact.scroll_bars.scroll_view.cursor);
        if (self.artifact.list_machine.toggleDirAtCursor(self.api_state.allocator(), &self.artifact.tree)) {
            self.artifact.scroll_bars.scroll_view.cursor = @intCast(self.artifact.list_machine.cursor);
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('z', .{})) {
        syncArtifactTree(self);
        self.artifact.list_machine.toggleAllDirs(self.api_state.allocator(), &self.artifact.tree);
        syncArtifactTree(self);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(' ', .{})) {
        syncArtifactTree(self);
        self.artifact.list_machine.cursor = @intCast(self.artifact.scroll_bars.scroll_view.cursor);
        if (self.artifact.list_machine.toggleSelectedAtCursor(self.api_state.allocator(), &self.artifact.tree)) {
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeEvent();
        return;
    }

    if (self.artifact.tree.rowCount() == 0) {
        ctx.consumeEvent();
        return;
    }
    const count = self.artifact.tree.rowCount();
    const step = w.stepForKey(key, &self.artifact.scroll_bars.scroll_view) orelse return;

    const old_active_leaf = self.artifact.list_machine.active_leaf;
    self.artifact.list_machine.cursor = @intCast(self.artifact.scroll_bars.scroll_view.cursor);
    _ = self.artifact.list_machine.moveBy(&self.artifact.tree, step);
    const pos = self.artifact.list_machine.cursor;
    self.artifact.scroll_bars.scroll_view.cursor = @intCast(pos);
    w.scrollCursorIntoView(&self.artifact.scroll_bars.scroll_view, count);

    if (self.artifact.tree.leafIndexAt(pos)) |rule_idx| {
        if (self.artifact.selected_rule != rule_idx) {
            self.artifact.selected_rule = rule_idx;
            self.review.selected_pr_idx = 0;
            self.review.pr_scroll_bars.scroll_view.cursor = 0;
            self.review.pr_filter = .open;
            self.review.hide_diff = false;
        }
    } else if (self.artifact.list_machine.active_leaf != old_active_leaf) {
        if (self.artifact.list_machine.active_leaf) |rule_idx| self.artifact.selected_rule = rule_idx;
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

pub fn syncArtifactTree(self: anytype) void {
    const rules = self.getRules();
    const create_paths = self.drafts.create_rule_paths;
    const selected_bundle_rule_ids = selectedBundleRuleIds(self);
    const search_query = self.searchQuery();

    const allocator = self.api_state.allocator();
    const path_capacity = rules.len + create_paths.len;
    const filtered_paths = allocator.alloc([]const u8, path_capacity) catch return;
    defer allocator.free(filtered_paths);
    const filtered_orig = allocator.alloc(usize, path_capacity) catch return;
    defer allocator.free(filtered_orig);
    var filtered_len: usize = 0;
    for (rules, 0..) |p, pidx| {
        if (selected_bundle_rule_ids) |rule_ids| {
            if (!bundleContainsRule(rule_ids, p.rule_id)) continue;
        }
        if (search_query.len > 0 and !self.searchMatchesQuery(p.path, search_query)) continue;
        filtered_paths[filtered_len] = p.path;
        filtered_orig[filtered_len] = pidx;
        filtered_len += 1;
    }

    if (selected_bundle_rule_ids == null) {
        // Append local create-op drafts as virtual rows only in the
        // unfiltered rule list. A bundle filter means "show members of
        // this bundle"; showing unrelated draft rows there makes a
        // partially-loaded bundle look like it contains only the draft.
        for (create_paths, 0..) |path, k| {
            if (search_query.len > 0 and !self.searchMatchesQuery(path, search_query)) continue;
            filtered_paths[filtered_len] = path;
            filtered_orig[filtered_len] = rules.len + k;
            filtered_len += 1;
        }
    }

    self.artifact.tree.sync(allocator, filtered_paths[0..filtered_len], filtered_orig[0..filtered_len]);
    if (self.artifact.last_synced_bundle_filter != self.artifact.bundle_filter) {
        self.artifact.tree.expandAllDirs(allocator);
        self.artifact.tree.sync(allocator, filtered_paths[0..filtered_len], filtered_orig[0..filtered_len]);
        self.artifact.last_synced_bundle_filter = self.artifact.bundle_filter;
    }
}

pub fn syncArtifactWidgets(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!void {
    syncArtifactTree(self);

    const rules = self.getRules();
    const create_paths = self.drafts.create_rule_paths;
    const row_count = self.artifact.tree.rowCount();
    const widgets = try ctx.arena.alloc(vxfw.Widget, row_count);
    const rows = try ctx.arena.alloc(w.TreeList.RowWidget, row_count);
    const selected_row: usize = if (row_count > 0)
        @min(@as(usize, @intCast(self.artifact.scroll_bars.scroll_view.cursor)), row_count - 1)
    else
        0;

    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row_text = self.artifact.tree.rowText(i);
        if (self.artifact.tree.dirPathAt(i) != null) {
            const row_sel = i == selected_row;
            rows[i] = .{
                .item = .{
                    .text = row_text,
                    .cursor = row_sel,
                    .active = true,
                    .style = if (row_sel)
                        theme.boldOn(theme.PANEL, theme.TEXT)
                    else
                        theme.boldOn(theme.PANEL, theme.TEXT_SOFT),
                },
                .options = .{
                    .background = theme.PANEL,
                    .text_col = 0,
                    .show_cursor_marker = false,
                },
            };
            widgets[i] = rows[i].widget();
        } else {
            const orig_pidx = self.artifact.tree.leafIndexAt(i) orelse {
                rows[i] = .{
                    .item = .{ .text = row_text },
                    .options = .{ .background = theme.PANEL, .text_col = 0, .show_cursor_marker = false },
                };
                widgets[i] = rows[i].widget();
                continue;
            };
            const is_virtual = orig_pidx >= rules.len;
            const row_path: []const u8 = if (is_virtual) blk: {
                const k = orig_pidx - rules.len;
                if (k >= create_paths.len) {
                    rows[i] = .{
                        .item = .{ .text = row_text },
                        .options = .{ .background = theme.PANEL, .text_col = 0, .show_cursor_marker = false },
                    };
                    widgets[i] = rows[i].widget();
                    continue;
                }
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
            const category = self.artifactCategoryForPath(row_path);
            const draft_status_opt = self.draftStatusFor(category, row_path);
            rows[i] = .{
                .item = .{
                    .text = row_text,
                    .trailing = pr_label,
                    .cursor = row_sel,
                    .selector = self.artifact.list_machine.selectorForLeaf(orig_pidx),
                    .selector_placement = .right,
                    .style = w.draftRowStyle(row_sel, draft_status_opt),
                },
                .options = .{
                    .background = theme.PANEL,
                    .text_col = 0,
                    .show_cursor_marker = false,
                    .trailing_gap = 2,
                },
            };
            widgets[i] = rows[i].widget();
        }
    }
    self.artifact.scroll_bars.scroll_view.children = .{ .slice = widgets };
    self.artifact.scroll_bars.estimated_content_height = @intCast(row_count);

    var cur = @as(usize, @intCast(self.artifact.scroll_bars.scroll_view.cursor));
    if (cur >= row_count) cur = if (row_count > 0) row_count - 1 else 0;
    self.artifact.list_machine.cursor = cur;
    self.artifact.list_machine.sync(&self.artifact.tree);
    cur = self.artifact.list_machine.cursor;
    self.artifact.scroll_bars.scroll_view.cursor = @intCast(cur);
    clampScrollTop(&self.artifact.scroll_bars.scroll_view, row_count);
    self.artifact.has_selected_rule = false;
    if (cur < row_count) {
        if (self.artifact.tree.leafIndexAt(cur) != null) {
            self.artifact.has_selected_rule = true;
        }
    }
    if (self.artifact.list_machine.active_leaf) |pi| {
        if (self.artifact.selected_rule != pi) {
            self.artifact.selected_rule = pi;
            self.review.hide_diff = false;
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

fn artifactListSubtitle(self: anytype) ?[]const u8 {
    const bundles = self.getBundles();
    if (self.artifact.bundle_filter == 0 or self.artifact.bundle_filter - 1 >= bundles.len) {
        return null;
    }
    return bundles[self.artifact.bundle_filter - 1].name;
}

fn selectedBundleRuleIds(self: anytype) ?[]const []const u8 {
    if (self.artifact.bundle_filter == 0) return null;
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    const bundles = self.api_state.bundles orelse return null;
    const idx = self.artifact.bundle_filter - 1;
    if (idx >= bundles.len) return null;
    return bundles[idx].rule_ids;
}

fn bundleContainsRule(rule_ids: []const []const u8, rule_id: []const u8) bool {
    for (rule_ids) |id| {
        if (std.mem.eql(u8, id, rule_id)) return true;
    }
    return false;
}

fn bundleChoiceCount(self: anytype) usize {
    const bundles = self.getBundles();
    return switch (self.artifact.bundle_drawer_mode) {
        .browse => bundles.len + 1,
        .add_selected => bundles.len + 1,
    };
}

fn workspaceChoiceCount(self: anytype) usize {
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    if (self.api_state.current_user) |user| return user.workspaces.len;
    return 0;
}

fn workspaceAtIndex(self: anytype, idx: usize) ?api_model.WorkspaceData {
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    const user = self.api_state.current_user orelse return null;
    if (idx >= user.workspaces.len) return null;
    return user.workspaces[idx];
}

fn handleWorkspaceDrawerKey(self: anytype, ctx: *vxfw.EventContext, key: vaxis.Key) void {
    if (key.matches(vaxis.Key.escape, .{})) {
        self.artifact.show_workspace_drawer = false;
        ctx.consumeAndRedraw();
        return;
    }
    const count = workspaceChoiceCount(self);
    if (count == 0) {
        ctx.consumeEvent();
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        self.artifact.show_workspace_drawer = false;
        self.confirmImportSelectedRulesToWorkspace(self.artifact.workspace_cursor);
        ctx.consumeAndRedraw();
        return;
    }
    var cursor = self.artifact.workspace_cursor;
    const step = w.stepForKey(key, &self.artifact.scroll_bars.scroll_view) orelse return;
    _ = w.moveCursorBy(&cursor, count, step);
    self.artifact.workspace_cursor = cursor;
    ctx.consumeAndRedraw();
}

fn handleBundleDrawerKey(self: anytype, ctx: *vxfw.EventContext, key: vaxis.Key) void {
    if (self.artifact.bundle_drawer_mode == .add_selected and self.artifact.bundle_cursor == 0) {
        handleBundleDrawerInputKey(self, ctx, key);
        return;
    }
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('b', .{})) {
        self.artifact.show_bundle_drawer = false;
        self.artifact.new_bundle_name_len = 0;
        ctx.consumeAndRedraw();
        return;
    }
    const count = bundleChoiceCount(self);
    if (count == 0) {
        ctx.consumeEvent();
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (self.artifact.bundle_drawer_mode == .add_selected) {
            self.confirmAddSelectedRulesToBundle(self.artifact.bundle_cursor - 1);
            self.artifact.show_bundle_drawer = false;
            ctx.consumeAndRedraw();
            return;
        }
        self.artifact.bundle_filter = @min(self.artifact.bundle_cursor, count - 1);
        self.artifact.show_bundle_drawer = false;
        self.artifact.list_machine.cursor = 0;
        self.artifact.list_machine.exitSelectionMode();
        resetScrollView(&self.artifact.scroll_bars.scroll_view);
        self.review.selected_pr_idx = 0;
        self.review.pr_scroll_bars.scroll_view.cursor = 0;
        ctx.consumeAndRedraw();
        return;
    }
    var cursor = self.artifact.bundle_cursor;
    const step = w.stepForKey(key, &self.artifact.scroll_bars.scroll_view) orelse return;
    _ = w.moveCursorBy(&cursor, count, step);
    self.artifact.bundle_cursor = cursor;
    ctx.consumeAndRedraw();
}

fn handleBundleDrawerInputKey(self: anytype, ctx: *vxfw.EventContext, key: vaxis.Key) void {
    if (key.matches(vaxis.Key.escape, .{})) {
        self.artifact.show_bundle_drawer = false;
        self.artifact.new_bundle_name_len = 0;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.down, .{})) {
        const count = bundleChoiceCount(self);
        if (count > 1) {
            self.artifact.bundle_cursor = 1;
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        const name = self.artifact.new_bundle_name_buf[0..self.artifact.new_bundle_name_len];
        if (name.len == 0) {
            self.notifyOp(.warning, "Bundle name is required.");
            ctx.consumeAndRedraw();
            return;
        }
        self.confirmCreateBundleWithSelectedRules(name);
        self.artifact.show_bundle_drawer = false;
        self.artifact.new_bundle_name_len = 0;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (self.artifact.new_bundle_name_len > 0) {
            self.artifact.new_bundle_name_len -= 1;
            ctx.consumeAndRedraw();
        }
        return;
    }
    if (key.text) |text| {
        const remaining = self.artifact.new_bundle_name_buf.len - self.artifact.new_bundle_name_len;
        if (text.len > 0 and text.len <= remaining) {
            @memcpy(
                self.artifact.new_bundle_name_buf[self.artifact.new_bundle_name_len..][0..text.len],
                text,
            );
            self.artifact.new_bundle_name_len += text.len;
            ctx.consumeAndRedraw();
        }
    } else if (key.codepoint >= 0x20 and key.codepoint < 0x7f) {
        if (self.artifact.new_bundle_name_len < self.artifact.new_bundle_name_buf.len) {
            self.artifact.new_bundle_name_buf[self.artifact.new_bundle_name_len] = @intCast(key.codepoint);
            self.artifact.new_bundle_name_len += 1;
            ctx.consumeAndRedraw();
        }
    }
}

pub fn drawWorkspaceDrawer(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    if (size.width < w.Drawer.min_child_width or size.height < w.Drawer.min_child_height) {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&surface, theme.PANEL_SOFT);
        return surface;
    }

    const body_w = size.width - w.Drawer.child_origin_col;
    const body_h = size.height - w.Drawer.child_origin_row;
    var body = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = body_w, .height = body_h });
    w.fillSurface(&body, theme.PANEL_SOFT);

    const count = workspaceChoiceCount(self);
    if (count > 0) {
        if (self.artifact.workspace_cursor >= count) self.artifact.workspace_cursor = count - 1;
        const window = w.TreeList.visibleWindow(self.artifact.workspace_cursor, count, @intCast(body_h));
        var out_row: u16 = 0;
        var idx = window.start;
        while (idx < count and out_row < body_h) : ({
            idx += 1;
            out_row += 1;
        }) {
            const workspace = workspaceAtIndex(self, idx) orelse continue;
            w.TreeList.drawItem(&body, ctx, out_row, body_w, .{
                .text = workspace.name,
                .cursor = idx == self.artifact.workspace_cursor,
                .active = idx == self.workspace.sel,
                .selector = if (idx == self.workspace.sel) .on else .off,
            }, .{ .background = theme.PANEL_SOFT });
        }
    }

    const drawer = w.Drawer{
        .title = "Import to Workspace",
        .border_color = theme.ACCENT_SOFT,
        .background = theme.PANEL_SOFT,
        .body = body,
    };
    return drawer.draw(ctx, self.widget());
}

pub fn drawBundleDrawer(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    if (size.width < w.Drawer.min_child_width or size.height < w.Drawer.min_child_height) {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&surface, theme.PANEL_SOFT);
        return surface;
    }

    const body_w = size.width - w.Drawer.child_origin_col;
    const body_h = size.height - w.Drawer.child_origin_row;
    var body = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = body_w, .height = body_h });
    w.fillSurface(&body, theme.PANEL_SOFT);

    const bundles = self.getBundles();
    const count = bundleChoiceCount(self);
    if (count == 0) return body;
    if (self.artifact.bundle_cursor >= count) self.artifact.bundle_cursor = count - 1;
    const window = w.TreeList.visibleWindow(self.artifact.bundle_cursor, count, @intCast(body_h));
    var out_row: u16 = 0;
    var idx = window.start;
    while (idx < count and out_row < body_h) : ({
        idx += 1;
        out_row += 1;
    }) {
        const bundle_idx = switch (self.artifact.bundle_drawer_mode) {
            .browse => if (idx == 0) null else idx - 1,
            .add_selected => if (idx == 0) null else idx - 1,
        };
        if (self.artifact.bundle_drawer_mode == .add_selected and idx == 0) {
            const focused = idx == self.artifact.bundle_cursor;
            const name = self.artifact.new_bundle_name_buf[0..self.artifact.new_bundle_name_len];
            w.drawTextInputSlot(&body, ctx, 1, out_row, body_w -| 2, name, theme.TEXT, focused);
            if (name.len == 0) {
                w.writeText(&body, ctx, 1, out_row, "New bundle", theme.textOn(if (focused) theme.PANEL else theme.PANEL_ALT, theme.MUTED));
            }
            continue;
        }
        const text = if (bundle_idx) |bi|
            try std.fmt.allocPrint(ctx.arena, "{s} ({d})", .{
                bundles[bi].name,
                bundles[bi].count,
            })
        else if (self.artifact.bundle_drawer_mode == .add_selected)
            "New bundle..."
        else
            "All rules";
        const active = switch (self.artifact.bundle_drawer_mode) {
            .browse => idx == self.artifact.bundle_filter,
            .add_selected => false,
        };
        w.TreeList.drawItem(&body, ctx, out_row, body_w, .{
            .text = text,
            .cursor = idx == self.artifact.bundle_cursor,
            .active = active,
            .selector = if (active) .on else .off,
        }, .{ .background = theme.PANEL_SOFT });
    }

    const drawer = w.Drawer{
        .title = if (self.artifact.bundle_drawer_mode == .add_selected) "Add to Bundle" else "Bundles",
        .border_color = theme.ACCENT_SOFT,
        .background = theme.PANEL_SOFT,
        .body = body,
    };
    return drawer.draw(ctx, self.widget());
}
