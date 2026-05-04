//! Workspace feature container. Owns workspace tree state, content detail
//! rendering, drawer interaction, and workspace creation flow.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../../theme.zig");
const w = @import("../../widgets.zig");
const data = @import("../../models/view_types.zig");
const api = @import("../../api.zig");
const drafts_mod = @import("../../../drafts.zig");
const rule_detail = @import("../review/root.zig");
const content_actions = @import("../content_actions.zig");
const Modal = w.Modal;
const TextInput = w.TextInput;

const MAX_TREE_ROWS = 128;
pub const PathTreeState = @import("../../models.zig").path_tree.State(MAX_TREE_ROWS, 96);

pub const Tab = enum(u8) {
    context,
    rules,

    pub fn label(self: Tab) []const u8 {
        return switch (self) {
            .context => "Context",
            .rules => "Rules",
        };
    }
};

pub const tabs = [_]Tab{ .context, .rules };

pub const Focus = enum { list, content };

pub const State = struct {
    tab: Tab = .context,
    focus: Focus = .list,
    sel: usize = 0,
    show_drawer: bool = false,
    drawer_cursor: usize = 0,
    list_sel: usize = 0,
    hide_diff: bool = false,
    list_scroll_bars: vxfw.ScrollBars,
    context_tree: PathTreeState = .{},
    rules_tree: PathTreeState = .{},
    list_widgets: [MAX_TREE_ROWS]vxfw.Widget = undefined,
    list_rows: [MAX_TREE_ROWS]vxfw.Text = undefined,
    local_arena: std.heap.ArenaAllocator,
    local_cache_id: ?[]const u8 = null,
    local_detail: ?api.model.WsDetail = null,
    local_load_failed: bool = false,

    show_create: bool = false,
    create_phase: CreateWsPhase = .form,
    create_focus: CreateWsFocus = .name,
    create_name_buf: [64]u8 = undefined,
    create_name_len: usize = 0,
    create_desc_buf: [256]u8 = undefined,
    create_desc_len: usize = 0,
    create_selected_bundle: ?usize = null,
    create_bundle_cursor: usize = 0,
    create_error_kind: CreateWsErrorKind = .none,
    create_error_buf: [160]u8 = undefined,
    create_error_len: usize = 0,
    create_created_id_buf: [64]u8 = undefined,
    create_created_id_len: usize = 0,
    create_created_name_buf: [64]u8 = undefined,
    create_created_name_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .list_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .local_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.local_arena.deinit();
        self.context_tree.deinit(allocator);
        self.rules_tree.deinit(allocator);
    }
};

pub const CreateWsPhase = enum { form, submitting, success };

pub const CreateWsFocus = enum {
    name,
    description,
    bundle,
    submit,

    pub fn next(self: CreateWsFocus, bundle_count: usize) CreateWsFocus {
        return switch (self) {
            .name => .description,
            .description => if (bundle_count == 0) .submit else .bundle,
            .bundle => .submit,
            .submit => .name,
        };
    }

    pub fn prev(self: CreateWsFocus, bundle_count: usize) CreateWsFocus {
        return switch (self) {
            .name => .submit,
            .description => .name,
            .bundle => .description,
            .submit => if (bundle_count == 0) .description else .bundle,
        };
    }
};

pub const CreateWsErrorKind = enum {
    none,
    name_required,
    api,
    network,
    invalid_response,
};

pub const DetailArgs = struct {
    live_ws: ?api.model.WsDetail,
    dir_sel: ?[]const u8,
    /// Server-side index into `live_ws.context_files`. Null when
    /// the selection is a virtual (create-op) draft.
    context_sel: ?usize,
    context_sel_id: ?[]const u8,
    /// Path of the selected context file — set for both server-side
    /// files and virtual create-op drafts. drawDetail treats this as
    /// the primary identity and only uses `context_sel` to pull
    /// hub-side metadata (hash / author / updated_at).
    context_sel_path: ?[]const u8,
    rule_sel_idx: ?usize,
    rule_sel_id: ?[]const u8,
    rule_sel_path: ?[]const u8,
};

pub fn drawStatus(
    self: anytype,
    ctx: vxfw.DrawContext,
    list_surface: vxfw.Surface,
    detail_surface: vxfw.Surface,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.PANEL);

    const list_w: u16 = size.width / 3;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = list_surface };
    children[1] = .{ .origin = .{ .row = 0, .col = list_w + 1 }, .surface = detail_surface };
    root.children = children;
    return root;
}

pub fn drawList(
    self: anytype,
    ctx: vxfw.DrawContext,
    ws_tree: anytype,
    live_ws: ?api.model.WsDetail,
) std.mem.Allocator.Error!vxfw.Surface {
    const list_border = theme.focusBorder(self.workspace.focus == .list);
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, list_border, theme.PANEL);
    const row_col: u16 = 2;

    var tab_col: u16 = 2;
    const ws_tabs = [_]@TypeOf(self.workspace.tab){ .context, .rules };
    for (ws_tabs) |tab| {
        tab_col = w.drawInnerTabBadge(&surface, ctx, 0, tab_col, wsTabLabel(tab), tab == self.workspace.tab);
        tab_col +|= 1;
    }
    _ = w.writeHeaderRightIfFits(&surface, ctx, 0, tab_col + 1, self.activeWorkspaceName(), theme.fg(theme.TEXT_SOFT));

    const body_origin_row: u16 = 1;
    const body_origin_col: u16 = 2;
    const body_h: u16 = ctx.max.height.? -| body_origin_row -| 1;
    const body_w: u16 = ctx.max.width.? -| body_origin_col -| 1;
    if (ws_tree.rowCount() == 0) {
        const empty_msg = if (self.activeWsId()) |ws_id| switch (self.workspace.tab) {
            .context => if (self.api_state.ws_context_files_pending.isInflight())
                "Loading context files..."
            else if (self.api_state.ws_context_files_cache.isFailed(.{ .value = ws_id }))
                "Context failed to load."
            else
                "No context files.",
            .rules => if (self.api_state.ws_manifest_pending.isInflight())
                "Loading workspace rules..."
            else if (self.api_state.ws_manifest_cache.isFailed(.{ .value = ws_id }))
                "Workspace rules failed to load."
            else
                "No workspace rules.",
        } else switch (self.workspace.tab) {
            .context => "No context files.",
            .rules => "No workspace rules.",
        };
        w.writeText(&surface, ctx, row_col, 1, empty_msg, theme.fg(theme.MUTED));
        return surface;
    }
    try syncListWidgets(self, ctx, ws_tree, live_ws);
    const body_ctx = ctx.withConstraints(
        .{ .width = body_w, .height = body_h },
        .{ .width = body_w, .height = body_h },
    );
    const body = try self.workspace.list_scroll_bars.widget().draw(body_ctx);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = body_origin_row, .col = body_origin_col }, .surface = body };
    surface.children = children;
    writeCursorBar(&surface, &self.workspace.list_scroll_bars.scroll_view, body_origin_row, body_h);

    return surface;
}

pub fn drawDetail(
    self: anytype,
    ctx: vxfw.DrawContext,
    args: DetailArgs,
) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    const content_border = theme.focusBorder(self.workspace.focus == .content);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, content_border, theme.PANEL);

    const has_local_selection = args.dir_sel != null or args.context_sel_path != null or args.rule_sel_path != null;
    if (args.live_ws == null and !has_local_selection) {
        w.writeText(&surface, ctx, 2, 0, "Content", theme.boldOn(theme.PANEL, theme.TEXT));
        w.writeText(&surface, ctx, 2, 2, "No workspace data loaded.", theme.fg(theme.MUTED));
        return surface;
    }

    const title: []const u8 = switch (self.workspace.tab) {
        .context => if (args.dir_sel != null) "Directory" else if (args.context_sel_id) |id| id else if (args.context_sel_path) |path| draftIdentity(self, .context, path) else "No context selected",
        .rules => if (args.dir_sel != null) "Directory" else if (args.rule_sel_id) |id| id else if (args.rule_sel_path) |path| draftIdentity(self, .rule, path) else "No rule selected",
    };
    w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
    // Reserve min_col past the title (plus one space) so the
    // right-aligned metadata badge never overlaps the path.
    const title_w: u16 = @intCast(ctx.stringWidth(title));
    const meta_min_col: u16 = 2 + title_w + 2;
    if (workspaceDetailShowsDiff(self, args)) {
        w.writeText(&surface, ctx, meta_min_col, 0, "diff", theme.boldOn(theme.PANEL, theme.ACCENT));
    } else if (args.dir_sel == null) if (args.live_ws) |ws_d| {
        try writeWsMetaOnHeader(&surface, ctx, meta_min_col, self, ws_d, args);
    };

    const kv_row: u16 = 2;
    const max_row = ctx.max.height.? -| 1;

    switch (self.workspace.tab) {
        .context => {
            if (args.dir_sel != null) {
                try drawDirSelected(&surface, ctx, kv_row, max_row);
            } else if (args.context_sel_path) |sel_path| {
                try drawContextFileDetail(self, &surface, ctx, kv_row, max_row, args.live_ws, sel_path);
            } else {
                w.writeText(&surface, ctx, 2, kv_row, "No context files.", theme.fg(theme.MUTED));
            }
        },
        .rules => {
            if (args.dir_sel != null) {
                try drawDirSelected(&surface, ctx, kv_row, max_row);
            } else if (args.rule_sel_path) |p| {
                try drawRuleFileDetail(self, &surface, ctx, kv_row, max_row, p);
            } else {
                w.writeText(&surface, ctx, 2, kv_row, "No workspace rules.", theme.fg(theme.MUTED));
            }
        },
    }

    return surface;
}

/// Render a one-line metadata badge at the top-right of the header,
/// mirroring Library's `rev{N} pr{N} c{N} {updated}` convention. For
/// context files we render `hash7 author updated`; for workspace
/// rules the hash is all we have from the manifest.
fn writeWsMetaOnHeader(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    min_col: u16,
    self: anytype,
    ws_d: api.model.WsDetail,
    args: DetailArgs,
) !void {
    switch (self.workspace.tab) {
        .context => {
            if (args.context_sel) |idx| {
                if (idx >= ws_d.context_files.len) return;
                const f = &ws_d.context_files[idx];
                const updated_short = try w.formatShortTimestamp(ctx.arena, f.updated_at);
                const meta = if (updated_short.len > 0)
                    try std.fmt.allocPrint(ctx.arena, "updated {s}", .{updated_short})
                else
                    "";
                _ = w.writeHeaderRightIfFits(surface, ctx, 0, min_col, meta, theme.fg(theme.MUTED));
            }
        },
        .rules => {
            if (args.rule_sel_path) |path| {
                if (self.lookupRuleViewByPath(path)) |rule| {
                    try writeRuleMetaOnHeader(surface, ctx, min_col, rule);
                }
            }
        },
    }
}

fn draftIdentity(self: anytype, category: drafts_mod.DraftCategory, path: []const u8) []const u8 {
    return self.draftLocalIdFor(category, path).?;
}

fn drawDirSelected(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    start_row: u16,
    max_row: u16,
) !void {
    w.writeText(surface, ctx, 2, start_row, "Directory selected.", theme.fg(theme.TEXT_SOFT));
    if (start_row + 1 < max_row) {
        w.writeText(surface, ctx, 2, start_row + 1, "Enter toggles expansion. Left collapses or jumps to parent. Right expands.", theme.fg(theme.MUTED));
    }
}

fn drawContextFileDetail(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    start_row: u16,
    max_row: u16,
    ws_d: ?api.model.WsDetail,
    path: []const u8,
) !void {
    const ws_id = if (ws_d) |live| live.ws_id else self.activeWsId() orelse return;
    try attachContentSurface(self, surface, ctx, start_row, max_row, .{
        .context = .{ .ws_id = ws_id, .path = path },
    }, !self.workspace.hide_diff);
}

fn drawRuleFileDetail(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    start_row: u16,
    max_row: u16,
    rule_path: []const u8,
) !void {
    try attachContentSurface(self, surface, ctx, start_row, max_row, .{
        .rule = .{ .path = rule_path },
    }, !self.workspace.hide_diff);
}

fn workspaceDetailShowsDiff(self: anytype, args: DetailArgs) bool {
    if (self.workspace.hide_diff or args.dir_sel != null) return false;
    return switch (self.workspace.tab) {
        .context => if (args.context_sel_path) |path|
            self.draftContentForView(.context, path) != null
        else
            false,
        .rules => if (args.rule_sel_path) |path|
            self.draftContentForView(self.libraryCategoryForPath(path), path) != null
        else
            false,
    };
}

const ContentSource = union(enum) {
    context: struct { ws_id: []const u8, path: []const u8 },
    rule: struct { path: []const u8 },
};

/// Seed the shared content_scroll_bars for the source and attach it
/// below the metadata rows. Normal mode renders the draft working copy
/// as flat text; diff mode renders cache-vs-draft with gutters.
/// Library's rule_detail path uses the same scroll bars, so switching
/// modules redraws content into the same widget state — no per-module
/// scroll state today.
fn attachContentSurface(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    start_row: u16,
    max_row: u16,
    source: ContentSource,
    show_diff: bool,
) !void {
    switch (source) {
        .context => |c| rule_detail.syncWsContextContentWidget(self, c.ws_id, c.path, show_diff),
        .rule => |p| rule_detail.syncWsRuleContentWidget(self, p.path, show_diff),
    }
    const content_h: u16 = if (max_row > start_row) max_row - start_row else 0;
    if (content_h == 0) return;
    const width_pad: u16 = 4;
    const inner_ctx = ctx.withConstraints(
        .{ .width = ctx.max.width.?, .height = content_h },
        .{ .width = ctx.max.width.?, .height = content_h },
    );
    const body = try rule_detail.buildContentSurface(self, inner_ctx, width_pad, content_h);
    const prev = surface.children;
    const children = try ctx.arena.alloc(vxfw.SubSurface, prev.len + 1);
    for (prev, 0..) |c, i| children[i] = c;
    children[prev.len] = .{ .origin = .{ .row = start_row, .col = 2 }, .surface = body };
    surface.children = children;
}

fn syncListWidgets(
    self: anytype,
    ctx: vxfw.DrawContext,
    ws_tree: anytype,
    live_ws: ?api.model.WsDetail,
) std.mem.Allocator.Error!void {
    const row_count = ws_tree.rowCount();
    const list_rows = try ctx.arena.alloc(vxfw.Text, row_count);
    const list_widgets = try ctx.arena.alloc(vxfw.Widget, row_count);
    for (0..row_count) |r| {
        const sel = r == self.workspace.list_sel;
        const rendered = ws_tree.rowText(r);
        if (ws_tree.dirPathAt(r) != null) {
            list_rows[r] = .{
                .text = rendered,
                .style = if (sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.boldOn(theme.PANEL, theme.TEXT_SOFT),
                .softwrap = false,
            };
        } else {
            const draft_status = draftStatusForRow(self, ws_tree, r, live_ws);
            const row_style = w.draftRowStyle(sel, draft_status);
            const is_stale = isStaleRow(self, ws_tree, r, live_ws);
            const text = if (is_stale)
                std.fmt.allocPrint(self.viewAllocator(), "{s} *", .{rendered}) catch rendered
            else
                rendered;
            list_rows[r] = .{
                .text = text,
                .style = row_style,
                .softwrap = false,
            };
        }
        list_widgets[r] = list_rows[r].widget();
    }
    self.workspace.list_scroll_bars.scroll_view.children = .{ .slice = list_widgets };
    self.workspace.list_scroll_bars.estimated_content_height = @intCast(row_count);
    var cur = @as(usize, @intCast(self.workspace.list_scroll_bars.scroll_view.cursor));
    if (row_count == 0) {
        cur = 0;
    } else if (cur >= row_count) {
        cur = row_count - 1;
    }
    self.workspace.list_scroll_bars.scroll_view.cursor = @intCast(cur);
    clampScrollTop(&self.workspace.list_scroll_bars.scroll_view, row_count);
    self.workspace.list_sel = cur;
}

fn isStaleRow(
    self: anytype,
    ws_tree: anytype,
    row: usize,
    live_ws: ?api.model.WsDetail,
) bool {
    _ = ws_tree;
    const selection = self.workspaceFileAtRow(row, live_ws) orelse return false;
    const hash = switch (selection) {
        .context => |c| c.hash,
        .rule => |r| r.hash,
    } orelse return false;
    return !self.isLocalContentFresh(selection.draftCategory(), selection.path(), hash);
}

fn draftStatusForRow(
    self: anytype,
    ws_tree: anytype,
    row: usize,
    live_ws: ?api.model.WsDetail,
) ?drafts_mod.DraftStatus {
    _ = ws_tree;
    const selection = self.workspaceFileAtRow(row, live_ws) orelse return null;
    return self.draftStatusFor(selection.draftCategory(), selection.path());
}

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

fn writeRuleMetaOnHeader(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    min_col: u16,
    rule: *const data.RuleEntry,
) !void {
    const updated = try w.formatShortTimestamp(ctx.arena, rule.updated);
    const meta = if (updated.len > 0)
        try std.fmt.allocPrint(
            ctx.arena,
            "rev{d} pr{d} c{d} {s}",
            .{ rule.revision, rule.open_pr_count, rule.constraint_count, updated },
        )
    else
        try std.fmt.allocPrint(
            ctx.arena,
            "rev{d} pr{d} c{d}",
            .{ rule.revision, rule.open_pr_count, rule.constraint_count },
        );
    _ = w.writeHeaderRightIfFits(surface, ctx, 0, min_col, meta, theme.fg(theme.MUTED));
}

pub fn drawWorkspaceDrawer(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
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

    const workspaces: []const api.model.WsData = blk: {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const user = self.api_state.current_user orelse break :blk &.{};
        const snapshot = try ctx.arena.alloc(api.model.WsData, user.workspaces.len);
        @memcpy(snapshot, user.workspaces);
        break :blk snapshot;
    };
    if (workspaces.len == 0) {
        w.writeText(&body, ctx, 1, 1, "No workspaces.", theme.textOn(theme.PANEL_SOFT, theme.MUTED));
    } else {
        if (self.workspace.drawer_cursor >= workspaces.len) self.workspace.drawer_cursor = workspaces.len - 1;
        const max_rows: usize = @intCast(body_h);
        const visible_rows = if (max_rows > 2) max_rows - 2 else max_rows;
        const start = if (self.workspace.drawer_cursor >= visible_rows)
            self.workspace.drawer_cursor - visible_rows + 1
        else
            0;
        var out_row: u16 = 0;
        var i = start;
        while (i < workspaces.len and out_row < body_h) : ({
            i += 1;
            out_row += 1;
        }) {
            const entry = workspaces[i];
            const is_cursor = i == self.workspace.drawer_cursor;
            const is_active = i == self.workspace.sel;
            if (is_cursor) {
                w.writeText(&body, ctx, 0, out_row, "\xe2\x96\x8c", theme.textOn(theme.PANEL_SOFT, theme.ACCENT_SOFT));
            }
            const name_style = if (is_cursor)
                theme.boldOn(theme.PANEL_SOFT, theme.TEXT)
            else
                theme.textOn(theme.PANEL_SOFT, theme.TEXT_SOFT);
            w.writeText(&body, ctx, 2, out_row, entry.name, name_style);

            if (is_active) {
                w.writeRightText(&body, ctx, out_row, "active", theme.boldOn(theme.PANEL_SOFT, theme.ACCENT_SOFT));
            }
        }
    }

    const drawer = w.Drawer{
        .title = "Workspaces",
        .border_color = theme.ACCENT_SOFT,
        .background = theme.PANEL_SOFT,
        .body = body,
    };
    return drawer.draw(ctx, self.widget());
}

pub fn handleWorkspaceDrawerKey(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    const count = self.wsCount();
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('w', .{})) {
        self.workspace.show_drawer = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (self.workspace.drawer_cursor + 1 < count) self.workspace.drawer_cursor += 1;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.workspace.drawer_cursor > 0) self.workspace.drawer_cursor -= 1;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (count > 0) {
            self.selectWorkspaceIndex(self.workspace.drawer_cursor);
        }
        ctx.consumeAndRedraw();
        return;
    }
    ctx.consumeEvent();
}

pub fn handleModuleEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) anyerror!void {
    if (key.matches(vaxis.Key.tab, .{})) {
        self.workspace.focus = switch (self.workspace.focus) {
            .list => .content,
            .content => .list,
        };
        ctx.consumeAndRedraw();
        return;
    }

    if (key.matches('w', .{})) {
        self.workspace.drawer_cursor = self.workspace.sel;
        self.workspace.show_drawer = true;
        ctx.consumeAndRedraw();
        return;
    }

    if (key.matches('c', .{})) {
        openCreate(self);
        ctx.consumeAndRedraw();
        return;
    }

    if (self.workspace.focus == .list and key.matches('l', .{})) {
        self.shiftWsTab(1);
        self.workspace.list_sel = 0;
        resetScrollView(&self.workspace.list_scroll_bars.scroll_view);
        self.workspace.hide_diff = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (self.workspace.focus == .list and key.matches('h', .{})) {
        self.shiftWsTab(-1);
        self.workspace.list_sel = 0;
        resetScrollView(&self.workspace.list_scroll_bars.scroll_view);
        self.workspace.hide_diff = false;
        ctx.consumeAndRedraw();
        return;
    }

    // `n` creates a new context-file draft. Bound at module level
    // (like Library's `n`) so both workspace focus modes can reach it.
    // Rules are org-owned — workspace does not create them, so `n` is
    // gated on the Context tab.
    if (key.matches('n', .{}) and self.workspace.tab == .context) {
        self.openNewDraftForm(.context);
        ctx.consumeAndRedraw();
        return;
    }
    if (content_actions.handle(self, ctx, key, .workspace)) return;

    switch (self.workspace.focus) {
        .list => try handleListFocusEvent(self, ctx, key),
        .content => try handleContentFocusEvent(self, ctx, key),
    }

    if (key.matches('r', .{})) {
        api.state.invalidateOnDemandCaches(self.api_state);
        self.invalidateRemoteDetailRequests();
        self.resetLocalWorkspaceDetail();
        self.ensureActiveWorkspaceDetailRequested();
        api.fetch.refetchAllAsync(self.api_state);
        ctx.consumeAndRedraw();
    }
}

pub fn shortcuts(self: anytype) []const w.Shortcut {
    return content_actions.workspaceShortcuts(self.workspace.tab == .context);
}

fn wsTabLabel(tab: anytype) []const u8 {
    return switch (tab) {
        .context => "Context",
        .rules => "Rules",
    };
}

fn handleListFocusEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) anyerror!void {
    syncWsRows(self);
    const ws_tree = self.currentWsTree();

    if (key.matches(vaxis.Key.enter, .{})) {
        if (ws_tree.dirPathAt(self.workspace.list_sel)) |dir| {
            ws_tree.toggleDir(self.api_state.allocator(), dir);
            self.workspace.hide_diff = false;
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeEvent();
        return;
    }
    if (key.matches('z', .{})) {
        ws_tree.toggleAll(self.api_state.allocator());
        self.workspace.hide_diff = false;
        syncWsRows(self);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        self.workspace.drawer_cursor = self.workspace.sel;
        self.workspace.show_drawer = true;
        ctx.consumeAndRedraw();
        return;
    }
    if (ws_tree.rowCount() == 0) {
        ctx.consumeEvent();
        return;
    }
    const count = ws_tree.rowCount();
    const step = w.stepForKey(key, &self.workspace.list_scroll_bars.scroll_view) orelse return;
    _ = w.moveCursorBy(&self.workspace.list_sel, count, step);
    w.syncScrollCursor(&self.workspace.list_scroll_bars.scroll_view, self.workspace.list_sel, count);
    w.scrollCursorIntoView(&self.workspace.list_scroll_bars.scroll_view, count);
    self.workspace.hide_diff = false;
    ctx.consumeAndRedraw();
}

fn handleContentFocusEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) anyerror!void {
    if (key.matches(vaxis.Key.escape, .{})) {
        self.workspace.focus = .list;
        ctx.consumeAndRedraw();
        return;
    }
    // Forward scroll keys to the shared content_view so j/k,
    // arrow keys, PgUp/PgDn, g/G drive the content panel identically
    // to the Library rule-detail pane. vxfw's ScrollView consumes
    // the ones it knows and ignores the rest, so this is safe as a
    // catch-all.
    try self.review.content_view.handleEvent(ctx, .{ .key_press = key });
}

/// Trigger the workspace-detail compound fetch. Issues two dispatches
/// (context files + manifest) that land independently in their
/// respective PendingRequest slots; `syncWsRows` composes them once
/// both caches are populated via `state.wsDetail`.
pub fn requestWorkspaceDetail(self: anytype, ws_id: []const u8) void {
    if (self.api_state.ws_context_files_cache.shouldDispatch(.{ .value = ws_id }) and
        !self.api_state.ws_context_files_pending.isInflight())
    {
        api.specs.dispatchFromState(
            api.specs.WsIdParams,
            api.specs.WsContextFilesPayload,
            api.specs.workspace_context_files,
            &self.api_state.ws_context_files_pending,
            self.api_state,
            .{ .ws_id = ws_id },
        );
    }
    if (self.api_state.ws_manifest_cache.shouldDispatch(.{ .value = ws_id }) and
        !self.api_state.ws_manifest_pending.isInflight())
    {
        api.specs.dispatchFromState(
            api.specs.WsIdParams,
            api.specs.WsManifestPayload,
            api.specs.workspace_manifest,
            &self.api_state.ws_manifest_pending,
            self.api_state,
            .{ .ws_id = ws_id },
        );
    }
}

pub fn syncWsRows(self: anytype) void {
    const live_ws = if (self.activeWsId()) |ws_id|
        self.workspaceDetailForView(ws_id)
    else
        null;

    const allocator = self.api_state.allocator();
    const path_capacity = switch (self.workspace.tab) {
        .context => blk: {
            const context_count = if (live_ws) |ws_d| ws_d.context_files.len else 0;
            break :blk context_count + self.drafts.create_context_paths.len;
        },
        .rules => blk: {
            const rule_count = if (live_ws) |ws_d| ws_d.ws_rules.len else 0;
            break :blk rule_count + self.drafts.create_rule_paths.len;
        },
    };
    const paths_buf = allocator.alloc([]const u8, path_capacity) catch return;
    defer allocator.free(paths_buf);
    const orig_idx = allocator.alloc(usize, path_capacity) catch return;
    defer allocator.free(orig_idx);
    var item_count: usize = 0;

    switch (self.workspace.tab) {
        .context => {
            const context_count = if (live_ws) |ws_d| ws_d.context_files.len else 0;
            item_count = context_count;
            if (live_ws) |ws_d| {
                for (0..item_count) |i| {
                    paths_buf[i] = ws_d.context_files[i].path;
                    orig_idx[i] = i;
                }
            }
            // Append local create-op context drafts as virtual rows.
            // Leaf index is offset by the live context count so
            // selectedDraftTarget can distinguish server rows from
            // create-only drafts.
            const create_paths = self.drafts.create_context_paths;
            for (create_paths, 0..) |path, k| {
                paths_buf[item_count] = path;
                orig_idx[item_count] = context_count + k;
                item_count += 1;
            }
        },
        .rules => {
            const rule_count = if (live_ws) |ws_d| ws_d.ws_rules.len else 0;
            if (live_ws) |ws_d| {
                item_count = rule_count;
                for (0..item_count) |i| {
                    const wp = ws_d.ws_rules[i];
                    paths_buf[i] = self.pathForWorkspaceRule(wp);
                    orig_idx[i] = i;
                }
            }
            // Append local create-op rule drafts as virtual rows so
            // workspace-scoped drafts remain visible even before the
            // hub manifest knows about them.
            const create_paths = self.drafts.create_rule_paths;
            for (create_paths, 0..) |path, k| {
                paths_buf[item_count] = path;
                orig_idx[item_count] = rule_count + k;
                item_count += 1;
            }
        },
    }

    const ws_tree = self.currentWsTree();
    ws_tree.sync(self.api_state.allocator(), paths_buf[0..item_count], orig_idx[0..item_count]);
    if (ws_tree.rowCount() == 0) {
        self.workspace.list_sel = 0;
        resetScrollView(&self.workspace.list_scroll_bars.scroll_view);
    } else if (self.workspace.list_sel >= ws_tree.rowCount()) {
        self.workspace.list_sel = ws_tree.rowCount() - 1;
        self.workspace.list_scroll_bars.scroll_view.cursor = @intCast(self.workspace.list_sel);
        w.scrollCursorIntoView(&self.workspace.list_scroll_bars.scroll_view, ws_tree.rowCount());
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

const CREATE_BOX_W: u16 = 76;
const CREATE_FORM_BOX_H: u16 = 24;
const CREATE_SUCCESS_BOX_H: u16 = 14;

pub fn drawCreateOverlay(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    return switch (self.workspace.create_phase) {
        .form, .submitting => drawCreateForm(self, ctx),
        .success => drawCreateSuccess(self, ctx),
    };
}

fn resetCreate(self: anytype) void {
    self.workspace.create_phase = .form;
    self.workspace.create_focus = .name;
    self.workspace.create_name_len = 0;
    self.workspace.create_desc_len = 0;
    self.workspace.create_selected_bundle = null;
    self.workspace.create_bundle_cursor = 0;
    self.workspace.create_error_kind = .none;
    self.workspace.create_error_len = 0;
    self.workspace.create_created_id_len = 0;
    self.workspace.create_created_name_len = 0;
}

pub fn openCreate(self: anytype) void {
    resetCreate(self);
    self.workspace.show_create = true;
}

fn closeCreate(self: anytype) void {
    self.workspace.show_create = false;
    resetCreate(self);
}

pub fn handleCreateKey(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    switch (self.workspace.create_phase) {
        .form => handleCreateFormKey(self, ctx, key),
        .submitting => handleCreateSubmittingKey(self, ctx, key),
        .success => handleCreateSuccessKey(self, ctx, key),
    }
}

fn handleCreateFormKey(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches(vaxis.Key.escape, .{})) {
        closeCreate(self);
        ctx.consumeAndRedraw();
        return;
    }

    const bundles_n = createBundleCount(self);

    if (key.matches(vaxis.Key.tab, .{})) {
        self.workspace.create_focus = self.workspace.create_focus.next(bundles_n);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
        self.workspace.create_focus = self.workspace.create_focus.prev(bundles_n);
        ctx.consumeAndRedraw();
        return;
    }

    switch (self.workspace.create_focus) {
        .name => routeCreateTextInput(
            self,
            ctx,
            key,
            &self.workspace.create_name_buf,
            &self.workspace.create_name_len,
        ),
        .description => routeCreateTextInput(
            self,
            ctx,
            key,
            &self.workspace.create_desc_buf,
            &self.workspace.create_desc_len,
        ),
        .bundle => handleCreateBundleKey(self, ctx, key),
        .submit => handleCreateSubmitKey(self, ctx, key),
    }
}

fn routeCreateTextInput(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
    buf: []u8,
    len: *usize,
) void {
    var input = TextInput{ .buf = buf, .len = len };
    switch (input.handleKey(key)) {
        .submit => {
            const bundles_n = createBundleCount(self);
            self.workspace.create_focus = self.workspace.create_focus.next(bundles_n);
            ctx.consumeAndRedraw();
        },
        .consumed => {
            self.workspace.create_error_kind = .none;
            self.workspace.create_error_len = 0;
            ctx.consumeAndRedraw();
        },
        .cancel, .ignored => ctx.consumeEvent(),
    }
}

fn handleCreateBundleKey(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    const count = createBundleCount(self);
    if (count == 0) {
        ctx.consumeEvent();
        return;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (self.workspace.create_bundle_cursor + 1 < count) self.workspace.create_bundle_cursor += 1;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.workspace.create_bundle_cursor > 0) self.workspace.create_bundle_cursor -= 1;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(' ', .{}) or key.matches(vaxis.Key.enter, .{})) {
        if (self.workspace.create_selected_bundle) |idx| {
            if (idx == self.workspace.create_bundle_cursor) {
                self.workspace.create_selected_bundle = null;
            } else {
                self.workspace.create_selected_bundle = self.workspace.create_bundle_cursor;
            }
        } else {
            self.workspace.create_selected_bundle = self.workspace.create_bundle_cursor;
        }
        ctx.consumeAndRedraw();
        return;
    }
    ctx.consumeEvent();
}

fn handleCreateSubmitKey(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(' ', .{})) {
        submitCreate(self);
        ctx.consumeAndRedraw();
        return;
    }
    ctx.consumeEvent();
}

fn submitCreate(self: anytype) void {
    const name = self.workspace.create_name_buf[0..self.workspace.create_name_len];
    if (name.len == 0) {
        setCreateNameRequired(self);
        self.workspace.create_focus = .name;
        return;
    }

    self.workspace.create_phase = .submitting;
    self.workspace.create_error_kind = .none;
    self.workspace.create_error_len = 0;

    api.specs.dispatchFromState(
        workspace_api.CreateWorkspaceRequest,
        workspace_api.CreateWorkspaceResponse,
        api.specs.create_workspace,
        &self.api_state.create_ws_pending,
        self.api_state,
        .{
            .name = name,
            .bundle_id = createSelectedBundleName(self),
        },
    );
}

fn handleCreateSubmittingKey(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches(vaxis.Key.escape, .{})) {
        // Abandon the in-flight result; the background thread can finish and
        // consumeCreateResult will drop it because the overlay is closed.
        closeCreate(self);
        ctx.consumeAndRedraw();
        return;
    }
    ctx.consumeEvent();
}

fn handleCreateSuccessKey(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches(vaxis.Key.escape, .{})) {
        closeCreate(self);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('c', .{})) {
        copyCreateInitCommand(self);
        self.notifyOp(.success, "Copied clumsies init command to clipboard.");
        ctx.consumeAndRedraw();
        return;
    }
    ctx.consumeEvent();
}

pub fn consumeCreateResult(self: anytype) bool {
    const result = self.api_state.create_ws_pending.consume() orelse return false;
    if (!self.workspace.show_create or self.workspace.create_phase != .submitting) {
        return false;
    }
    applyCreateResult(self, result);
    return true;
}

fn createBundleCount(self: anytype) usize {
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    if (self.api_state.bundles) |list| return list.len;
    return 0;
}

fn createSelectedBundleName(self: anytype) ?[]const u8 {
    const idx = self.workspace.create_selected_bundle orelse return null;
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    const bundles = self.api_state.bundles orelse return null;
    if (idx >= bundles.len) return null;
    return bundles[idx].name;
}

fn setCreateNameRequired(self: anytype) void {
    self.workspace.create_error_kind = .name_required;
    writeErrorMessage(self, "Name is required");
}

const workspace_api = @import("clumsies_lib").protocol.workspace_api;

pub fn applyCreateResult(
    self: anytype,
    result: api.dispatcher.Result(workspace_api.CreateWorkspaceResponse),
) void {
    switch (result) {
        .ok => |resp| {
            writeFixedBuf(&self.workspace.create_created_id_buf, &self.workspace.create_created_id_len, resp.ws_id);
            writeFixedBuf(&self.workspace.create_created_name_buf, &self.workspace.create_created_name_len, resp.name);
            self.workspace.create_phase = .success;
            self.workspace.create_error_kind = .none;
            self.workspace.create_error_len = 0;
            // Refresh the cached workspace list so the new workspace
            // appears in the grid once the background fetch completes.
            api.fetch.refetchAllAsync(self.api_state);
        },
        .api_error => |err| {
            self.workspace.create_phase = .form;
            self.workspace.create_error_kind = .api;
            writeErrorMessage(self, err.message);
            if (err.status == .conflict) self.workspace.create_focus = .name;
        },
        .network_error => {
            self.workspace.create_phase = .form;
            self.workspace.create_error_kind = .network;
            writeErrorMessage(self, "Network error. Check connection and retry.");
        },
        .invalid_response => {
            self.workspace.create_phase = .form;
            self.workspace.create_error_kind = .invalid_response;
            writeErrorMessage(self, "Unexpected response from Hub.");
        },
    }
}

fn copyCreateInitCommand(self: anytype) void {
    const alloc = self.api_state.backing_allocator;
    const id = self.workspace.create_created_id_buf[0..self.workspace.create_created_id_len];
    const cmd = std.fmt.allocPrint(alloc, "clumsies init --ws-id {s}", .{id}) catch return;
    defer alloc.free(cmd);
    copyTextToClipboard(alloc, cmd);
}

fn writeErrorMessage(self: anytype, message: []const u8) void {
    writeFixedBuf(&self.workspace.create_error_buf, &self.workspace.create_error_len, message);
}

fn writeFixedBuf(buf: []u8, len: *usize, src: []const u8) void {
    const n = @min(buf.len, src.len);
    @memcpy(buf[0..n], src[0..n]);
    len.* = n;
}

pub fn copyTextToClipboard(alloc: std.mem.Allocator, text: []const u8) void {
    const argv: []const []const u8 = switch (@import("builtin").os.tag) {
        .macos => &[_][]const u8{"pbcopy"},
        .linux => &[_][]const u8{ "xclip", "-selection", "clipboard" },
        else => return,
    };

    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;

    if (child.stdin) |stdin| {
        var buf: [128]u8 = undefined;
        var writer = std.fs.File.Writer.init(stdin, &buf);
        writer.interface.writeAll(text) catch {};
        writer.interface.flush() catch {};
        stdin.close();
        child.stdin = null;
    }

    _ = child.wait() catch {};
}

fn drawCreateForm(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    const footer = if (self.workspace.create_phase == .submitting)
        "Submitting... Esc to cancel"
    else
        "Tab next  Enter advance  Space toggle bundle  Esc cancel";

    const modal = Modal{
        .title = "Create Workspace",
        .box_width = CREATE_BOX_W,
        .box_height = CREATE_FORM_BOX_H,
        .footer = footer,
    };
    const dr = try modal.draw(ctx, self.widget());
    var surface = dr.surface;
    const c0 = dr.content_col;
    const r0 = dr.content_row;
    const bg = theme.PANEL_ALT;

    var row: u16 = r0;
    const label_w: u16 = 14;

    row = w.writeKv(
        &surface,
        ctx,
        c0,
        row,
        "Name *",
        self.workspace.create_name_buf[0..self.workspace.create_name_len],
        label_w,
    );
    if (self.workspace.create_focus == .name) w.writeCursorMarker(&surface, c0 - 1, row - 1);
    row += 1;

    row = w.writeKv(
        &surface,
        ctx,
        c0,
        row,
        "Description",
        self.workspace.create_desc_buf[0..self.workspace.create_desc_len],
        label_w,
    );
    if (self.workspace.create_focus == .description) w.writeCursorMarker(&surface, c0 - 1, row - 1);
    row += 1;

    w.writeText(&surface, ctx, c0, row, "Bundle", theme.textOn(bg, theme.MUTED));
    w.writeText(
        &surface,
        ctx,
        c0 + label_w,
        row,
        "(optional) seeds workspace with a rule set",
        theme.textOn(bg, theme.MUTED),
    );
    row += 1;
    drawCreateBundleList(self, &surface, ctx, c0, row, CREATE_BOX_W - 4, 8, bg);
    row += 9;

    const focused = self.workspace.create_focus == .submit;
    const button_label = if (self.workspace.create_phase == .submitting)
        "[ Submitting... ]"
    else
        "[ Create Workspace ]";
    const button_style: vaxis.Style = if (focused)
        theme.boldOn(theme.ACCENT, theme.CANVAS)
    else
        theme.boldOn(theme.PANEL_SOFT, theme.TEXT);
    w.writeText(&surface, ctx, c0, row, button_label, button_style);

    if (self.workspace.create_error_kind != .none) {
        const err_row = r0 + CREATE_FORM_BOX_H - 4;
        const err_text = self.workspace.create_error_buf[0..self.workspace.create_error_len];
        w.writeText(&surface, ctx, c0, err_row, err_text, theme.textOn(bg, theme.DANGER));
    }

    return surface;
}

fn drawCreateBundleList(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    col: u16,
    row: u16,
    width: u16,
    height: u16,
    bg: vaxis.Color,
) void {
    _ = width;
    self.api_state.mutex.lock();
    const bundles_opt = self.api_state.bundles;
    self.api_state.mutex.unlock();

    const list_focused = self.workspace.create_focus == .bundle;

    const bundles = bundles_opt orelse {
        w.writeText(surface, ctx, col + 2, row + 1, "(loading bundles...)", theme.textOn(bg, theme.MUTED));
        return;
    };
    if (bundles.len == 0) {
        w.writeText(surface, ctx, col + 2, row + 1, "(no bundles available)", theme.textOn(bg, theme.MUTED));
        return;
    }

    const visible_rows: u16 = height - 2;
    const cursor = self.workspace.create_bundle_cursor;
    const scroll_start: usize = if (cursor >= visible_rows) cursor - visible_rows + 1 else 0;
    const end: usize = @min(bundles.len, scroll_start + @as(usize, visible_rows));

    var i: usize = scroll_start;
    while (i < end) : (i += 1) {
        const b = bundles[i];
        const is_cursor = i == cursor;
        const is_selected = self.workspace.create_selected_bundle != null and
            self.workspace.create_selected_bundle.? == i;
        const marker: []const u8 = if (is_selected) "\xe2\x97\x8f " else "  ";

        const text = std.fmt.allocPrint(
            ctx.arena,
            "{s}{s}  ({d} rules)",
            .{ marker, b.name, b.rule_count },
        ) catch continue;

        const render_row: u16 = row + 1 + @as(u16, @intCast(i - scroll_start));
        if (is_cursor and list_focused) w.writeCursorMarker(surface, col, render_row);
        const row_style: vaxis.Style = if (is_cursor and list_focused)
            theme.boldOn(bg, theme.TEXT)
        else if (is_selected)
            theme.boldOn(bg, theme.ACCENT_SOFT)
        else
            theme.textOn(bg, theme.TEXT_SOFT);
        w.writeText(surface, ctx, col + 2, render_row, text, row_style);
    }
}

fn drawCreateSuccess(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    const modal = Modal{
        .title = "Workspace Created",
        .box_width = CREATE_BOX_W,
        .box_height = CREATE_SUCCESS_BOX_H,
        .footer = "c copy cmd  Esc close",
        .border_color = theme.OK,
    };
    const dr = try modal.draw(ctx, self.widget());
    var surface = dr.surface;
    const c0 = dr.content_col;
    const r0 = dr.content_row;
    const bg = theme.PANEL_ALT;

    var row: u16 = r0;
    const ws_id = self.workspace.create_created_id_buf[0..self.workspace.create_created_id_len];
    const ws_name = self.workspace.create_created_name_buf[0..self.workspace.create_created_name_len];

    row = w.writeKv(&surface, ctx, c0, row, "ws_id", ws_id, 10);
    row = w.writeKv(&surface, ctx, c0, row, "name", ws_name, 10);
    row += 1;

    w.writeText(
        &surface,
        ctx,
        c0,
        row,
        "To bind this workspace to a local directory, run from the target dir:",
        theme.textOn(bg, theme.TEXT),
    );
    row += 2;

    const cmd = try std.fmt.allocPrint(
        ctx.arena,
        "  $ clumsies init --ws-id {s}",
        .{ws_id},
    );
    w.writeText(&surface, ctx, c0, row, cmd, theme.boldOn(bg, theme.ACCENT));
    row += 2;

    w.writeText(
        &surface,
        ctx,
        c0,
        row,
        "c Copy command    Esc Close",
        theme.textOn(bg, theme.TEXT_SOFT),
    );

    return surface;
}

test "CreateWsFocus.next cycles through form fields when no bundles" {
    try std.testing.expectEqual(CreateWsFocus.description, CreateWsFocus.name.next(0));
    try std.testing.expectEqual(CreateWsFocus.submit, CreateWsFocus.description.next(0));
    try std.testing.expectEqual(CreateWsFocus.name, CreateWsFocus.submit.next(0));
}

test "CreateWsFocus.next includes bundle when bundles available" {
    try std.testing.expectEqual(CreateWsFocus.bundle, CreateWsFocus.description.next(3));
    try std.testing.expectEqual(CreateWsFocus.submit, CreateWsFocus.bundle.next(3));
}

test "CreateWsFocus.prev mirrors next" {
    try std.testing.expectEqual(CreateWsFocus.submit, CreateWsFocus.name.prev(0));
    try std.testing.expectEqual(CreateWsFocus.description, CreateWsFocus.submit.prev(0));
    try std.testing.expectEqual(CreateWsFocus.bundle, CreateWsFocus.submit.prev(3));
}
