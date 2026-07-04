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
const local_content = @import("../../../local_content.zig");
const workspace_config = @import("../../../workspace_config.zig");
const rule_detail = @import("../review/root.zig");
const content_actions = @import("../content_actions.zig");
const artifact_api = @import("clumsies_lib").protocol.artifact_api;
const util_hash = @import("clumsies_lib").util.hash;
const Modal = w.Modal;
const TextInput = w.TextInput;
const log = std.log.scoped(.tui_event);

const MAX_TREE_ROWS = 128;
const MAX_PULL_ALL_RESUME_ATTEMPTS = 3;
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

const PendingPullAll = struct {
    tab: Tab,
    ws_id_buf: [80]u8 = .{0} ** 80,
    ws_id_len: usize = 0,
    resume_attempts: u8 = 0,

    pub fn wsId(self: *const PendingPullAll) []const u8 {
        return self.ws_id_buf[0..self.ws_id_len];
    }

    pub fn recordResumeAttempt(self: *PendingPullAll) bool {
        if (self.resume_attempts >= MAX_PULL_ALL_RESUME_ATTEMPTS) return false;
        self.resume_attempts += 1;
        return true;
    }
};

const PullAllSummary = struct {
    changed: usize = 0,
    missing: usize = 0,
    failed: usize = 0,
};

pub const State = struct {
    tab: Tab = .context,
    focus: Focus = .list,
    sel: usize = 0,
    show_drawer: bool = false,
    drawer_cursor: usize = 0,
    list_sel: usize = 0,
    list_machine: w.TreeList.Machine = .{},
    last_context_file_row: ?usize = null,
    last_rule_file_row: ?usize = null,
    hide_diff: bool = false,
    list_scroll_bars: vxfw.ScrollBars,
    context_tree: PathTreeState = .{},
    rules_tree: PathTreeState = .{},
    rows_signature: u64 = 0,
    rows_signature_valid: bool = false,
    local_arena: std.heap.ArenaAllocator,
    local_cache_id: ?[]const u8 = null,
    local_detail: ?api.model.WorkspaceDetail = null,
    local_load_failed: bool = false,
    pending_pull_all: ?PendingPullAll = null,

    show_create: bool = false,
    create_mode: CreateWsMode = .create,
    create_phase: CreateWsPhase = .form,
    create_focus: CreateWsFocus = .name,
    create_name_buf: [64]u8 = undefined,
    create_name_len: usize = 0,
    create_desc_buf: [256]u8 = undefined,
    create_desc_len: usize = 0,
    create_path_buf: [512]u8 = undefined,
    create_path_len: usize = 0,
    create_selected_bundle: ?usize = null,
    create_bundle_cursor: usize = 0,
    create_error_kind: CreateWsErrorKind = .none,
    create_error_buf: [160]u8 = undefined,
    create_error_len: usize = 0,
    create_created_id_buf: [64]u8 = undefined,
    create_created_id_len: usize = 0,
    create_created_name_buf: [64]u8 = undefined,
    create_created_name_len: usize = 0,
    create_bound_path_buf: [512]u8 = undefined,
    create_bound_path_len: usize = 0,
    create_bound_ok: bool = false,
    create_init_copied: bool = false,
    create_edit_ws_id_buf: [64]u8 = undefined,
    create_edit_ws_id_len: usize = 0,

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
        self.list_machine.deinit(allocator);
    }
};

pub const CreateWsPhase = enum { form, submitting, success };
pub const CreateWsMode = enum { create, edit };

pub const CreateWsFocus = enum {
    name,
    description,
    path,
    bundle,
    submit,

    pub fn next(self: CreateWsFocus, bundle_count: usize, include_path: bool) CreateWsFocus {
        return switch (self) {
            .name => .description,
            .description => if (include_path) .path else if (bundle_count == 0) .submit else .bundle,
            .path => if (bundle_count == 0) .submit else .bundle,
            .bundle => .submit,
            .submit => .name,
        };
    }

    pub fn prev(self: CreateWsFocus, bundle_count: usize, include_path: bool) CreateWsFocus {
        return switch (self) {
            .name => .submit,
            .description => .name,
            .path => .description,
            .bundle => if (include_path) .path else .description,
            .submit => if (bundle_count == 0) if (include_path) .path else .description else .bundle,
        };
    }
};

pub const CreateWsErrorKind = enum {
    none,
    name_required,
    api,
    network,
    invalid_response,
    invalid_path,
};

pub const DetailArgs = struct {
    live_ws: ?api.model.WorkspaceDetail,
    /// Server-side index into `live_ws.workspace_context`. Null when
    /// the selection is a virtual (create-op) draft.
    context_sel: ?usize,
    context_sel_id: ?[]const u8,
    /// Path of the selected context file — set for both server-side
    /// files and virtual create-op drafts. drawDetail treats this as
    /// the primary identity and only uses `context_sel` to pull
    /// hub-side metadata (hash / author / updated_at).
    context_sel_path: ?[]const u8,
    context_sel_hash: ?[]const u8,
    context_local_path: ?[]const u8,
    rule_sel_idx: ?usize,
    rule_sel_id: ?[]const u8,
    rule_sel_path: ?[]const u8,
    rule_sel_hash: ?[]const u8,
    rule_local_path: ?[]const u8,
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
    live_ws: ?api.model.WorkspaceDetail,
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
            .context => if (self.api_state.workspace_context_pending.isInflight())
                "Loading context files..."
            else if (self.api_state.workspace_context_cache.isFailed(.{ .value = ws_id }))
                "Context failed to load."
            else
                "No context files.",
            .rules => if (self.api_state.workspace_manifest_pending.isInflight())
                "Loading workspace rules..."
            else if (self.api_state.workspace_manifest_cache.isFailed(.{ .value = ws_id }))
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

    const has_local_selection = args.context_sel_path != null or args.rule_sel_path != null;
    if (args.live_ws == null and !has_local_selection) {
        w.writeText(&surface, ctx, 2, 0, "Content", theme.boldOn(theme.PANEL, theme.TEXT));
        w.writeText(&surface, ctx, 2, 1, "No workspace data loaded.", theme.fg(theme.MUTED));
        return surface;
    }

    const title: []const u8 = switch (self.workspace.tab) {
        .context => if (args.context_sel_id) |id| id else if (args.context_sel_path) |path| draftIdentity(self, .context, path) orelse "No context selected" else "No context selected",
        .rules => if (args.rule_sel_id) |id| id else if (args.rule_sel_path) |path| draftIdentity(self, .rule, path) orelse "No rule selected" else "No rule selected",
    };
    w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
    // Reserve min_col past the title (plus one space) so the
    // right-aligned metadata badge never overlaps the path.
    const title_w: u16 = @intCast(ctx.stringWidth(title));
    const meta_min_col: u16 = 2 + title_w + 2;
    if (workspaceDetailDraftStatus(self, args)) |status| {
        const label = try workspaceDetailDraftLabel(self, ctx.arena, args, status);
        _ = w.writeHeaderRightIfFits(
            &surface,
            ctx,
            0,
            meta_min_col,
            label,
            w.draftStatusHeaderStyle(status),
        );
    } else if (workspaceDetailPullLabel(self, ctx.arena, args)) |label| {
        _ = w.writeHeaderRightIfFits(
            &surface,
            ctx,
            0,
            meta_min_col,
            label,
            theme.boldOn(theme.PANEL, theme.INFO),
        );
    } else if (args.live_ws) |ws_d| {
        try writeWsMetaOnHeader(&surface, ctx, meta_min_col, self, ws_d, args);
    }

    const kv_row: u16 = 1;
    const max_row = ctx.max.height.? -| 1;

    switch (self.workspace.tab) {
        .context => {
            if (args.context_sel_path) |sel_path| {
                try drawContextFileDetail(self, &surface, ctx, kv_row, max_row, args.live_ws, sel_path, args.context_local_path, args.context_sel_hash);
            } else {
                w.writeText(&surface, ctx, 2, kv_row, "No context files.", theme.fg(theme.MUTED));
            }
        },
        .rules => {
            if (args.rule_sel_path) |p| {
                try drawRuleFileDetail(self, &surface, ctx, kv_row, max_row, p, args.rule_local_path, args.rule_sel_hash);
            } else {
                w.writeText(&surface, ctx, 2, kv_row, "No workspace rules.", theme.fg(theme.MUTED));
            }
        },
    }

    return surface;
}

/// Render a one-line metadata badge at the top-right of the header.
/// Workspace content details keep this compact and consistent across
/// Context and Rules; org-level revision/review counts stay in Artifact.
fn writeWsMetaOnHeader(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    min_col: u16,
    self: anytype,
    ws_d: api.model.WorkspaceDetail,
    args: DetailArgs,
) !void {
    switch (self.workspace.tab) {
        .context => {
            if (args.context_sel) |idx| {
                if (idx >= ws_d.workspace_context.len) return;
                const f = &ws_d.workspace_context[idx];
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

fn draftIdentity(self: anytype, category: drafts_mod.DraftCategory, path: []const u8) ?[]const u8 {
    return self.draftLocalIdFor(category, path);
}

fn drawContextFileDetail(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    start_row: u16,
    max_row: u16,
    ws_d: ?api.model.WorkspaceDetail,
    path: []const u8,
    local_path: ?[]const u8,
    remote_hash: ?[]const u8,
) !void {
    const ws_id = if (ws_d) |live| live.ws_id else self.activeWsId() orelse return;
    try attachContentSurface(self, surface, ctx, start_row, max_row, .{
        .context = .{ .ws_id = ws_id, .path = path, .local_path = local_path, .remote_hash = remote_hash },
    }, !self.workspace.hide_diff);
}

fn drawRuleFileDetail(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    start_row: u16,
    max_row: u16,
    rule_path: []const u8,
    local_path: ?[]const u8,
    remote_hash: ?[]const u8,
) !void {
    try attachContentSurface(self, surface, ctx, start_row, max_row, .{
        .rule = .{ .path = rule_path, .local_path = local_path, .remote_hash = remote_hash },
    }, !self.workspace.hide_diff);
}

fn workspaceDetailDraftStatus(self: anytype, args: DetailArgs) ?drafts_mod.DraftStatus {
    return switch (self.workspace.tab) {
        .context => if (args.context_sel_path) |path|
            self.draftStatusFor(.context, path)
        else
            null,
        .rules => if (args.rule_sel_path) |path|
            self.draftStatusFor(self.artifactCategoryForPath(path), path)
        else
            null,
    };
}

fn workspaceDetailPullLabel(self: anytype, arena: std.mem.Allocator, args: DetailArgs) ?[]const u8 {
    return switch (self.workspace.tab) {
        .context => if (args.context_sel_path) |path|
            self.workspaceSelectionPullLabel(arena, .{ .context = .{
                .path = path,
                .context_id = args.context_sel_id,
                .idx = args.context_sel,
                .hash = args.context_sel_hash,
            } }) catch "pull available"
        else
            null,
        .rules => if (args.rule_sel_path) |path|
            self.workspaceSelectionPullLabel(arena, .{ .rule = .{
                .path = path,
                .rule_id = args.rule_sel_id,
                .idx = args.rule_sel_idx,
                .hash = args.rule_sel_hash,
                .category = self.artifactCategoryForPath(path),
            } }) catch "pull available"
        else
            null,
    };
}

fn workspaceDetailDraftLabel(
    self: anytype,
    arena: std.mem.Allocator,
    args: DetailArgs,
    status: drafts_mod.DraftStatus,
) std.mem.Allocator.Error![]const u8 {
    const status_label = w.draftStatusLabel(status);
    const op = switch (self.workspace.tab) {
        .context => if (args.context_sel_path) |path|
            self.draftOperationForView(.context, path)
        else
            null,
        .rules => if (args.rule_sel_path) |path|
            self.draftOperationForView(self.artifactCategoryForPath(path), path)
        else
            null,
    } orelse return status_label;
    return std.fmt.allocPrint(arena, "{s} [op:{s}]", .{ status_label, draftOperationLabel(op) });
}

fn draftOperationLabel(op: drafts_mod.DraftOperation) []const u8 {
    return switch (op) {
        .create => "create",
        .update => "update",
        .rename => "rename",
        .delete => "delete",
    };
}

const ContentSource = union(enum) {
    context: struct { ws_id: []const u8, path: []const u8, local_path: ?[]const u8, remote_hash: ?[]const u8 },
    rule: struct { path: []const u8, local_path: ?[]const u8, remote_hash: ?[]const u8 },
};

/// Seed the shared content_scroll_bars for the source and attach it
/// below the metadata rows. Normal mode renders the draft working copy
/// as flat text; diff mode renders cache-vs-draft with gutters.
/// Artifact's rule_detail path uses the same scroll bars, so switching
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
        .context => |c| rule_detail.syncWsContextContentWidget(self, c.ws_id, c.path, c.local_path, c.remote_hash, show_diff),
        .rule => |p| rule_detail.syncWsRuleContentWidget(self, p.path, p.local_path, p.remote_hash, show_diff),
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
    live_ws: ?api.model.WorkspaceDetail,
) std.mem.Allocator.Error!void {
    const row_count = ws_tree.rowCount();
    const rows = try ctx.arena.alloc(w.TreeList.RowWidget, row_count);
    const list_widgets = try ctx.arena.alloc(vxfw.Widget, row_count);
    self.workspace.list_machine.cursor = self.workspace.list_sel;
    self.workspace.list_machine.sync(ws_tree);
    self.workspace.list_sel = self.workspace.list_machine.cursor;
    for (0..row_count) |r| {
        const sel = r == self.workspace.list_sel;
        const rendered = ws_tree.rowText(r);
        if (ws_tree.dirPathAt(r) != null) {
            rows[r] = .{
                .item = .{
                    .text = rendered,
                    .cursor = sel,
                    .active = true,
                    .style = if (sel)
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
        } else {
            const draft_status = draftStatusForRow(self, ws_tree, r, live_ws);
            const pull_available = draft_status == null and isStaleRow(self, ws_tree, r, live_ws);
            const text = if (pull_available)
                std.fmt.allocPrint(self.viewAllocator(), "{s} *", .{rendered}) catch rendered
            else
                rendered;
            rows[r] = .{
                .item = .{
                    .text = text,
                    .cursor = sel,
                    .selector = if (ws_tree.leafIndexAt(r)) |leaf|
                        self.workspace.list_machine.selectorForLeaf(leaf)
                    else
                        .none,
                    .selector_placement = .right,
                    .style = w.contentRowStyle(sel, draft_status, pull_available),
                },
                .options = .{
                    .background = theme.PANEL,
                    .text_col = 0,
                    .show_cursor_marker = false,
                },
            };
        }
        list_widgets[r] = rows[r].widget();
    }
    self.workspace.list_scroll_bars.scroll_view.children = .{ .slice = list_widgets };
    self.workspace.list_scroll_bars.estimated_content_height = @intCast(row_count);
    const cur = if (row_count == 0) 0 else @min(self.workspace.list_sel, row_count - 1);
    self.workspace.list_sel = cur;
    self.workspace.list_machine.cursor = cur;
    self.workspace.list_machine.sync(ws_tree);
    self.workspace.list_sel = self.workspace.list_machine.cursor;
    self.workspace.list_scroll_bars.scroll_view.cursor = @intCast(self.workspace.list_sel);
    clampScrollTop(&self.workspace.list_scroll_bars.scroll_view, row_count);
}

fn isStaleRow(
    self: anytype,
    ws_tree: anytype,
    row: usize,
    live_ws: ?api.model.WorkspaceDetail,
) bool {
    _ = ws_tree;
    const selection = self.workspaceFileAtRow(row, live_ws) orelse return false;
    return self.workspaceSelectionHasPullAvailable(selection);
}

fn draftStatusForRow(
    self: anytype,
    ws_tree: anytype,
    row: usize,
    live_ws: ?api.model.WorkspaceDetail,
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
        try std.fmt.allocPrint(ctx.arena, "updated {s}", .{updated})
    else
        "";
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

    const workspaces: []const api.model.WorkspaceData = blk: {
        self.api_state.mutex.lockUncancelable(std.Options.debug_io);
        defer self.api_state.mutex.unlock(std.Options.debug_io);
        const user = self.api_state.current_user orelse break :blk &.{};
        const snapshot = try ctx.arena.alloc(api.model.WorkspaceData, user.workspaces.len);
        @memcpy(snapshot, user.workspaces);
        break :blk snapshot;
    };
    if (workspaces.len == 0) {
        w.writeText(&body, ctx, 1, 1, "No workspaces.", theme.textOn(theme.PANEL_SOFT, theme.MUTED));
    } else {
        if (self.workspace.drawer_cursor >= workspaces.len) self.workspace.drawer_cursor = workspaces.len - 1;
        const window = w.TreeList.visibleWindow(
            self.workspace.drawer_cursor,
            workspaces.len,
            @intCast(body_h),
        );
        var out_row: u16 = 0;
        var i = window.start;
        while (i < workspaces.len and out_row < body_h) : ({
            i += 1;
            out_row += 1;
        }) {
            const entry = workspaces[i];
            w.TreeList.drawItem(&body, ctx, out_row, body_w, .{
                .text = entry.name,
                .trailing = entry.owner,
                .cursor = i == self.workspace.drawer_cursor,
                .active = i == self.workspace.sel,
                .selector = if (i == self.workspace.sel) .on else .off,
            }, .{ .background = theme.PANEL_SOFT });
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

    if (self.workspace.focus == .list and key.matches('l', .{})) {
        self.shiftWsTab(1);
        self.workspace.list_sel = 0;
        self.workspace.list_machine.reset();
        resetScrollView(&self.workspace.list_scroll_bars.scroll_view);
        self.workspace.hide_diff = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (self.workspace.focus == .list and key.matches('h', .{})) {
        self.shiftWsTab(-1);
        self.workspace.list_sel = 0;
        self.workspace.list_machine.reset();
        resetScrollView(&self.workspace.list_scroll_bars.scroll_view);
        self.workspace.hide_diff = false;
        ctx.consumeAndRedraw();
        return;
    }

    // `n` creates a new context-file draft. Bound at module level
    // (like Artifact's `n`) so both workspace focus modes can reach it.
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
}

pub fn shortcuts(self: anytype) []const w.Shortcut {
    if (self.workspace.tab == .rules and self.workspace.list_machine.selection_mode) return &.{
        .{ .key = "j/k", .label = "move/scroll" },
        .{ .key = "Space", .label = "toggle" },
        .{ .key = "x", .label = "detach" },
        .{ .key = "Esc", .label = "cancel" },
    };
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
        self.workspace.list_machine.cursor = self.workspace.list_sel;
        if (self.workspace.list_machine.toggleDirAtCursor(self.api_state.allocator(), ws_tree)) {
            self.workspace.list_sel = self.workspace.list_machine.cursor;
            self.workspace.list_scroll_bars.scroll_view.cursor = @intCast(self.workspace.list_sel);
            self.workspace.hide_diff = false;
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeEvent();
        return;
    }
    if (key.matches('z', .{})) {
        self.workspace.list_machine.cursor = self.workspace.list_sel;
        self.workspace.list_machine.toggleAllDirs(self.api_state.allocator(), ws_tree);
        self.workspace.list_sel = self.workspace.list_machine.cursor;
        self.workspace.hide_diff = false;
        syncWsRows(self);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(' ', .{})) {
        self.workspace.list_machine.cursor = self.workspace.list_sel;
        if (self.workspace.list_machine.toggleSelectedAtCursor(self.api_state.allocator(), ws_tree)) {
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeEvent();
        return;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        if (self.workspace.list_machine.selection_mode) {
            self.workspace.list_machine.exitSelectionMode();
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeEvent();
        return;
    }
    if (key.matches('x', .{})) {
        if (self.workspace.tab != .rules or !self.workspace.list_machine.selection_mode) {
            ctx.consumeEvent();
            return;
        }
        self.confirmDetachSelectedWorkspaceRules();
        ctx.consumeAndRedraw();
        return;
    }
    if (ws_tree.rowCount() == 0) {
        ctx.consumeEvent();
        return;
    }
    const count = ws_tree.rowCount();
    const step = w.stepForKey(key, &self.workspace.list_scroll_bars.scroll_view) orelse return;
    self.workspace.list_machine.cursor = self.workspace.list_sel;
    _ = self.workspace.list_machine.moveBy(ws_tree, step);
    self.workspace.list_sel = self.workspace.list_machine.cursor;
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
    // to the Artifact rule-detail pane. vxfw's ScrollView consumes
    // the ones it knows and ignores the rest, so this is safe as a
    // catch-all.
    try self.review.content_view.handleEvent(ctx, .{ .key_press = key });
}

pub fn pullAllWorkspaceContent(self: anytype) void {
    pullAllWorkspaceContentForTab(self, self.workspace.tab, true);
}

fn pullAllWorkspaceContentForTab(self: anytype, tab: Tab, allow_fetch: bool) void {
    const ws_id = self.activeWsId() orelse {
        self.notifyOp(.warning, "No workspace selected.");
        return;
    };
    const ws_d = self.workspaceDetailForView(ws_id) orelse {
        self.ensureActiveWorkspaceDetailRequested();
        self.notifyOp(.loading, "Workspace metadata is still loading.");
        return;
    };

    self.refreshDraftsCache();
    const arena = self.viewAllocator();
    const ws_dir = workspace_config.getWsDir(arena, ws_id) catch {
        self.notifyOp(.failure, "Pull failed: local workspace path unavailable.");
        return;
    };

    const summary = switch (tab) {
        .context => pullAllWorkspaceContexts(self, arena, ws_dir, &ws_d),
        .rules => pullAllWorkspaceRules(self, arena, ws_dir, &ws_d),
    };

    if (summary.changed > 0) self.resetLocalWorkspaceDetail();
    if (summary.failed > 0) {
        self.workspace.pending_pull_all = null;
        self.notifyOp(.failure, formatPullAllSummary(self, "Pull finished with failures", summary));
        return;
    }
    if (summary.missing > 0) {
        if (!allow_fetch) {
            self.workspace.pending_pull_all = null;
            self.notifyOp(.failure, formatPullAllSummary(self, "Pull failed: content still missing", summary));
            return;
        }
        rememberPendingWorkspacePullAll(self, ws_id, tab);
        self.notifyOp(.loading, formatPullAllSummary(self, "Fetching content", summary));
        return;
    }
    self.workspace.pending_pull_all = null;
    if (summary.changed > 0) {
        self.notifyOp(.success, formatPullAllSummary(self, "Pulled workspace content", summary));
        return;
    }
    self.notifyOp(.success, "Workspace content is already current.");
}

fn rememberPendingWorkspacePullAll(self: anytype, ws_id: []const u8, tab: Tab) void {
    var pending = PendingPullAll{ .tab = tab };
    if (self.workspace.pending_pull_all) |existing| {
        if (existing.tab == tab and std.mem.eql(u8, existing.wsId(), ws_id)) {
            pending.resume_attempts = existing.resume_attempts;
        }
    }
    const len = @min(ws_id.len, pending.ws_id_buf.len);
    @memcpy(pending.ws_id_buf[0..len], ws_id[0..len]);
    pending.ws_id_len = len;
    self.workspace.pending_pull_all = pending;
}

pub fn completePendingWorkspacePullAll(self: anytype, tab: Tab) void {
    const pending = self.workspace.pending_pull_all orelse return;
    if (pending.tab != tab) return;
    const active_ws_id = self.activeWsId() orelse {
        self.workspace.pending_pull_all = null;
        return;
    };
    if (!std.mem.eql(u8, active_ws_id, pending.wsId())) {
        self.workspace.pending_pull_all = null;
        return;
    }
    if (!recordPendingWorkspacePullAllResume(self)) {
        self.workspace.pending_pull_all = null;
        self.notifyOp(.failure, "Pull failed: content still missing after retries.");
        return;
    }
    pullAllWorkspaceContentForTab(self, tab, true);
}

pub fn failPendingWorkspacePullAll(self: anytype, tab: Tab, message: []const u8) void {
    if (self.workspace.pending_pull_all) |pending| {
        if (pending.tab != tab) return;
        self.workspace.pending_pull_all = null;
        self.notifyOp(.failure, message);
    }
}

fn recordPendingWorkspacePullAllResume(self: anytype) bool {
    if (self.workspace.pending_pull_all) |*pending| return pending.recordResumeAttempt();
    return false;
}

fn pullAllWorkspaceContexts(
    self: anytype,
    arena: std.mem.Allocator,
    ws_dir: []const u8,
    ws_d: *const api.model.WorkspaceDetail,
) PullAllSummary {
    var summary: PullAllSummary = .{};
    var missing_paths: std.ArrayList([]const u8) = .empty;
    defer missing_paths.deinit(arena);

    for (ws_d.workspace_context) |remote| {
        if (self.draftStatusFor(.context, remote.path) != null) continue;
        const local = self.localContextEntryFor(remote.path, remote.context_id);
        if (local) |local_item| {
            if (self.draftStatusFor(.context, local_item.path) != null) continue;
        }
        if (local) |local_item| {
            if (std.mem.eql(u8, local_item.path, remote.path) and local_content.hashesEqual(local_item.hash, remote.hash)) continue;
        }

        const body = workspaceContextBodyForPull(self, ws_d.ws_id, remote) orelse {
            if (!appendUniquePullPath(arena, &missing_paths, remote.path)) summary.failed += 1;
            continue;
        };
        local_content.write(arena, ws_dir, .context, remote.path, body) catch {
            summary.failed += 1;
            continue;
        };
        local_content.writeManifestContextEntry(arena, ws_dir, ws_d.ws_id, self.activeWorkspaceName(), remote.context_id, remote.path, remote.hash) catch {
            summary.failed += 1;
            continue;
        };
        summary.changed += 1;
    }

    if (self.workspace.local_detail) |local| {
        for (local.workspace_context) |local_item| {
            if (self.draftStatusFor(.context, local_item.path) != null) continue;
            if (contextExistsRemotely(ws_d.workspace_context, local_item)) continue;
            local_content.removeManifestContextEntry(arena, ws_dir, ws_d.ws_id, self.activeWorkspaceName(), local_item.context_id, local_item.path) catch {
                summary.failed += 1;
                continue;
            };
            summary.changed += 1;
        }
    }

    summary.missing += missing_paths.items.len;
    if (missing_paths.items.len > 0) requestWorkspaceContextContentBatch(self, ws_d.ws_id, missing_paths.items);
    return summary;
}

fn pullAllWorkspaceRules(
    self: anytype,
    arena: std.mem.Allocator,
    ws_dir: []const u8,
    ws_d: *const api.model.WorkspaceDetail,
) PullAllSummary {
    var summary: PullAllSummary = .{};
    var missing_rule_ids: std.ArrayList([]const u8) = .empty;
    defer missing_rule_ids.deinit(arena);

    for (ws_d.workspace_rules) |remote| {
        const remote_path = self.pathForWorkspaceRule(remote);
        const category = self.artifactCategoryForPath(remote_path);
        if (self.draftStatusFor(category, remote_path) != null) continue;
        const local = self.localRuleEntryFor(remote_path, remote.rule_id);
        if (local) |local_item| {
            if (self.draftStatusFor(self.artifactCategoryForPath(local_item.path), local_item.path) != null) continue;
        }
        if (local) |local_item| {
            if (std.mem.eql(u8, local_item.path, remote_path) and local_content.hashesEqual(local_item.content_hash, remote.content_hash)) continue;
        }

        const body = workspaceRuleBodyForPull(self, remote_path, remote.content_hash) orelse {
            if (remote.rule_id.len == 0) {
                summary.failed += 1;
                continue;
            }
            if (!appendUniquePullPath(arena, &missing_rule_ids, remote.rule_id)) summary.failed += 1;
            continue;
        };
        local_content.write(arena, ws_dir, category, remote_path, body) catch {
            summary.failed += 1;
            continue;
        };
        local_content.writeManifestRuleEntry(arena, ws_dir, ws_d.ws_id, self.activeWorkspaceName(), remote.rule_id, remote_path, remote.content_hash) catch {
            summary.failed += 1;
            continue;
        };
        summary.changed += 1;
    }

    if (self.workspace.local_detail) |local| {
        for (local.workspace_rules) |local_item| {
            if (self.draftStatusFor(self.artifactCategoryForPath(local_item.path), local_item.path) != null) continue;
            if (self.findRuleFor(ws_d.workspace_rules, local_item.path, local_item.rule_id) != null) continue;
            local_content.removeManifestRuleEntry(arena, ws_dir, ws_d.ws_id, self.activeWorkspaceName(), local_item.rule_id, local_item.path) catch {
                summary.failed += 1;
                continue;
            };
            summary.changed += 1;
        }
    }

    summary.missing += missing_rule_ids.items.len;
    if (missing_rule_ids.items.len > 0) requestWorkspaceRuleContentBatch(self, ws_d.ws_id, missing_rule_ids.items);
    return summary;
}

fn workspaceContextBodyForPull(
    self: anytype,
    ws_id: []const u8,
    remote: api.model.WorkspaceContextData,
) ?[]const u8 {
    const key = api.state.WorkspacePathKey{ .ws_id = ws_id, .path = remote.path };
    const body = self.api_state.workspace_context_content_cache.lookup(key) orelse return null;
    if (remote.hash.len > 0) {
        const body_hash = util_hash.contentHash(body);
        if (!local_content.hashesEqual(body_hash[0..], remote.hash)) {
            self.api_state.workspace_context_content_cache.invalidateKey(key);
            self.api_state.workspace_context_content_batch_pending.cancel();
            return null;
        }
    }
    return body;
}

fn workspaceRuleBodyForPull(
    self: anytype,
    path: []const u8,
    remote_hash: []const u8,
) ?[]const u8 {
    const key = api.cache.StringKey{ .value = path };
    const resp = self.api_state.rule_content_cache.lookup(key) orelse return null;
    if (remote_hash.len > 0) {
        const body_hash = util_hash.contentHash(resp.body);
        if (!local_content.hashesEqual(body_hash[0..], remote_hash)) {
            self.api_state.rule_content_cache.invalidateKey(key);
            self.api_state.rule_content_batch_pending.cancel();
            return null;
        }
    }
    return resp.body;
}

fn requestWorkspaceContextContentBatch(self: anytype, ws_id: []const u8, paths: []const []const u8) void {
    if (self.api_state.workspace_context_content_batch_pending.isInflight()) return;
    api.specs.dispatchFromState(
        api.specs.BatchWorkspaceContextContentParams,
        api.specs.WorkspaceContextContentBatchPayload,
        api.specs.workspace_context_content_batch,
        &self.api_state.workspace_context_content_batch_pending,
        self.api_state,
        .{ .ws_id = ws_id, .paths = paths },
    );
}

fn requestWorkspaceRuleContentBatch(self: anytype, ws_id: []const u8, rule_ids: []const []const u8) void {
    if (self.api_state.rule_content_batch_pending.isInflight()) return;
    api.specs.dispatchFromState(
        api.specs.BatchWorkspaceRuleContentParams,
        artifact_api.BatchRuleContentResponse,
        api.specs.workspace_rule_content_batch,
        &self.api_state.rule_content_batch_pending,
        self.api_state,
        .{ .ws_id = ws_id, .rule_ids = rule_ids },
    );
}

fn formatPullAllSummary(self: anytype, prefix: []const u8, summary: PullAllSummary) []const u8 {
    const alloc = self.api_state.allocator();
    if (summary.failed > 0) {
        return std.fmt.allocPrint(alloc, "{s}: pulled {d}, fetching {d}, failed {d}.", .{
            prefix,
            summary.changed,
            summary.missing,
            summary.failed,
        }) catch prefix;
    }
    if (summary.missing > 0 and summary.changed > 0) {
        return std.fmt.allocPrint(alloc, "{s}: pulled {d}, fetching {d}.", .{
            prefix,
            summary.changed,
            summary.missing,
        }) catch prefix;
    }
    if (summary.missing > 0) {
        return std.fmt.allocPrint(alloc, "{s}: {d} item(s).", .{
            prefix,
            summary.missing,
        }) catch prefix;
    }
    return std.fmt.allocPrint(alloc, "{s}: {d} item(s).", .{
        prefix,
        summary.changed,
    }) catch prefix;
}

fn appendUniquePullPath(
    allocator: std.mem.Allocator,
    items: *std.ArrayList([]const u8),
    value: []const u8,
) bool {
    if (value.len == 0) return true;
    for (items.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return true;
    }
    items.append(allocator, value) catch return false;
    return true;
}

fn contextExistsRemotely(
    remote_items: []const api.model.WorkspaceContextData,
    local_item: api.model.WorkspaceContextData,
) bool {
    for (remote_items) |remote| {
        if (local_item.context_id.len > 0 and remote.context_id.len > 0 and std.mem.eql(u8, local_item.context_id, remote.context_id)) return true;
        if (std.mem.eql(u8, local_item.path, remote.path)) return true;
    }
    return false;
}

/// Trigger the workspace-detail compound fetch. Issues two dispatches
/// (context files + manifest) that land independently in their
/// respective PendingRequest slots; `syncWsRows` composes them once
/// both caches are populated via `state.wsDetail`.
pub fn requestWorkspaceDetail(self: anytype, ws_id: []const u8) void {
    const dispatch_context =
        !self.api_state.workspace_context_pending.isInflight() and
        self.api_state.workspace_context_cache.beginRefresh(.{ .value = ws_id }, self.tick_count, api.cache.DEFAULT_SNAPSHOT_REFRESH_TICKS);
    const dispatch_manifest =
        !self.api_state.workspace_manifest_pending.isInflight() and
        self.api_state.workspace_manifest_cache.beginRefresh(.{ .value = ws_id }, self.tick_count, api.cache.DEFAULT_SNAPSHOT_REFRESH_TICKS);
    if (!dispatch_context and !dispatch_manifest) return;

    log.info("requestWorkspaceDetail module={s} ws_id={s} context={} manifest={}", .{
        @tagName(self.selected_module),
        ws_id,
        dispatch_context,
        dispatch_manifest,
    });
    if (dispatch_context) {
        api.specs.dispatchFromState(
            api.specs.WorkspaceIdParams,
            api.specs.WorkspaceContextPayload,
            api.specs.workspace_context,
            &self.api_state.workspace_context_pending,
            self.api_state,
            .{ .ws_id = ws_id },
        );
    }
    if (dispatch_manifest) {
        api.specs.dispatchFromState(
            api.specs.WorkspaceIdParams,
            api.specs.WorkspaceManifestPayload,
            api.specs.workspace_manifest,
            &self.api_state.workspace_manifest_pending,
            self.api_state,
            .{ .ws_id = ws_id },
        );
    }
}

pub fn refreshWorkspaceDetail(self: anytype, ws_id: []const u8) void {
    const dispatch_context = !self.api_state.workspace_context_pending.isInflight();
    const dispatch_manifest = !self.api_state.workspace_manifest_pending.isInflight();
    log.info("refreshWorkspaceDetail module={s} ws_id={s} context={} manifest={}", .{
        @tagName(self.selected_module),
        ws_id,
        dispatch_context,
        dispatch_manifest,
    });
    if (dispatch_context) {
        api.specs.dispatchFromState(
            api.specs.WorkspaceIdParams,
            api.specs.WorkspaceContextPayload,
            api.specs.workspace_context,
            &self.api_state.workspace_context_pending,
            self.api_state,
            .{ .ws_id = ws_id },
        );
    }
    if (dispatch_manifest) {
        api.specs.dispatchFromState(
            api.specs.WorkspaceIdParams,
            api.specs.WorkspaceManifestPayload,
            api.specs.workspace_manifest,
            &self.api_state.workspace_manifest_pending,
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
    const search_query = self.searchQuery();
    const signature = workspaceRowsSignature(self, live_ws, search_query);
    if (self.workspace.rows_signature_valid and self.workspace.rows_signature == signature) return;

    const allocator = self.api_state.allocator();
    const path_capacity = switch (self.workspace.tab) {
        .context => blk: {
            const context_count = if (live_ws) |ws_d| ws_d.workspace_context.len else 0;
            break :blk context_count + self.drafts.create_context_paths.len;
        },
        .rules => blk: {
            const rule_count = if (live_ws) |ws_d| ws_d.workspace_rules.len else 0;
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
            const context_count = if (live_ws) |ws_d| ws_d.workspace_context.len else 0;
            if (live_ws) |ws_d| {
                for (ws_d.workspace_context, 0..) |item, i| {
                    const path = self.displayPathForWorkspaceContext(item.path);
                    if (search_query.len > 0 and !self.searchMatchesQuery(path, search_query)) continue;
                    paths_buf[item_count] = path;
                    orig_idx[item_count] = i;
                    item_count += 1;
                }
            }
            // Append local create-op context drafts as virtual rows.
            // Leaf index is offset by the live context count so
            // selectedDraftTarget can distinguish server rows from
            // create-only drafts.
            const create_paths = self.drafts.create_context_paths;
            for (create_paths, 0..) |path, k| {
                if (search_query.len > 0 and !self.searchMatchesQuery(path, search_query)) continue;
                paths_buf[item_count] = path;
                orig_idx[item_count] = context_count + k;
                item_count += 1;
            }
        },
        .rules => {
            const rule_count = if (live_ws) |ws_d| ws_d.workspace_rules.len else 0;
            if (live_ws) |ws_d| {
                for (ws_d.workspace_rules, 0..) |wp, i| {
                    const path = self.displayPathForWorkspaceRule(wp);
                    if (search_query.len > 0 and !self.searchMatchesQuery(path, search_query)) continue;
                    paths_buf[item_count] = path;
                    orig_idx[item_count] = i;
                    item_count += 1;
                }
            }
            // Append local create-op rule drafts as virtual rows so
            // workspace-scoped drafts remain visible even before the
            // hub manifest knows about them.
            const create_paths = self.drafts.create_rule_paths;
            for (create_paths, 0..) |path, k| {
                if (search_query.len > 0 and !self.searchMatchesQuery(path, search_query)) continue;
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
        self.workspace.list_machine.reset();
        resetScrollView(&self.workspace.list_scroll_bars.scroll_view);
    } else if (self.workspace.list_sel >= ws_tree.rowCount()) {
        self.workspace.list_sel = ws_tree.rowCount() - 1;
        self.workspace.list_scroll_bars.scroll_view.cursor = @intCast(self.workspace.list_sel);
        w.scrollCursorIntoView(&self.workspace.list_scroll_bars.scroll_view, ws_tree.rowCount());
    }
    self.workspace.rows_signature = signature;
    self.workspace.rows_signature_valid = true;
}

pub fn invalidateRows(self: anytype) void {
    self.workspace.rows_signature_valid = false;
}

fn workspaceRowsSignature(
    self: anytype,
    live_ws: ?api.model.WorkspaceDetail,
    search_query: []const u8,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(@tagName(self.workspace.tab));
    hasher.update(search_query);
    if (self.activeWsId()) |ws_id| hasher.update(ws_id);
    const expanded = &self.currentWsTree().expanded;
    hashInt(&hasher, expanded.count());
    var expanded_it = expanded.keyIterator();
    while (expanded_it.next()) |key| hasher.update(key.*);
    hashInt(&hasher, self.drafts.create_context_paths.len);
    hashInt(&hasher, self.drafts.create_rule_paths.len);

    switch (self.workspace.tab) {
        .context => {
            if (live_ws) |ws_d| {
                hashInt(&hasher, ws_d.workspace_context.len);
                for (ws_d.workspace_context) |item| {
                    hasher.update(item.context_id);
                    hasher.update(self.displayPathForWorkspaceContext(item.path));
                    hasher.update(item.hash);
                }
            } else {
                hashInt(&hasher, 0);
            }
            for (self.drafts.create_context_paths) |path| hasher.update(path);
        },
        .rules => {
            if (live_ws) |ws_d| {
                hashInt(&hasher, ws_d.workspace_rules.len);
                for (ws_d.workspace_rules) |item| {
                    hasher.update(item.rule_id);
                    hasher.update(self.displayPathForWorkspaceRule(item));
                    hasher.update(item.content_hash);
                }
            } else {
                hashInt(&hasher, 0);
            }
            for (self.drafts.create_rule_paths) |path| hasher.update(path);
        },
    }

    return hasher.final();
}

fn hashInt(hasher: *std.hash.Wyhash, value: usize) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @intCast(value), .little);
    hasher.update(&buf);
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
const CREATE_SUCCESS_BOX_H: u16 = 13;

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
    self.workspace.create_mode = .create;
    self.workspace.create_focus = .name;
    self.workspace.create_name_len = 0;
    self.workspace.create_desc_len = 0;
    self.workspace.create_path_len = 0;
    self.workspace.create_selected_bundle = null;
    self.workspace.create_bundle_cursor = 0;
    self.workspace.create_error_kind = .none;
    self.workspace.create_error_len = 0;
    self.workspace.create_created_id_len = 0;
    self.workspace.create_created_name_len = 0;
    self.workspace.create_bound_path_len = 0;
    self.workspace.create_bound_ok = false;
    self.workspace.create_init_copied = false;
    self.workspace.create_edit_ws_id_len = 0;
}

pub fn openCreate(self: anytype) void {
    resetCreate(self);
    seedCreatePathFromCwd(self);
    self.workspace.show_create = true;
}

pub fn openEdit(self: anytype, ws_id: []const u8, name: []const u8, description: []const u8) void {
    resetCreate(self);
    self.workspace.create_mode = .edit;
    writeFixedBuf(&self.workspace.create_edit_ws_id_buf, &self.workspace.create_edit_ws_id_len, ws_id);
    writeFixedBuf(&self.workspace.create_name_buf, &self.workspace.create_name_len, name);
    writeFixedBuf(&self.workspace.create_desc_buf, &self.workspace.create_desc_len, description);
    self.workspace.show_create = true;
}

fn seedCreatePathFromCwd(self: anytype) void {
    const alloc = self.api_state.backing_allocator;
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", alloc) catch return;
    defer alloc.free(cwd);
    writeFixedBuf(&self.workspace.create_path_buf, &self.workspace.create_path_len, cwd);
}

pub fn closeCreate(self: anytype) void {
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
    const include_path = self.workspace.create_mode == .create;

    if (self.workspace.create_focus == .path and key.matches(vaxis.Key.tab, .{ .shift = true })) {
        ctx.consumeEvent();
        return;
    }
    if (self.workspace.create_focus == .path and key.matches(vaxis.Key.tab, .{})) {
        if (completeCreatePath(self)) {
            self.workspace.create_error_kind = .none;
            self.workspace.create_error_len = 0;
        }
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.tab, .{})) {
        self.workspace.create_focus = self.workspace.create_focus.next(bundles_n, include_path);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
        self.workspace.create_focus = self.workspace.create_focus.prev(bundles_n, include_path);
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
        .path => routeCreateTextInput(
            self,
            ctx,
            key,
            &self.workspace.create_path_buf,
            &self.workspace.create_path_len,
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
            const include_path = self.workspace.create_mode == .create;
            self.workspace.create_focus = self.workspace.create_focus.next(bundles_n, include_path);
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

fn completeCreatePath(self: anytype) bool {
    const raw = self.workspace.create_path_buf[0..self.workspace.create_path_len];
    const parent = if (raw.len > 0 and raw[raw.len - 1] == '/')
        raw
    else
        std.fs.path.dirname(raw) orelse ".";
    const prefix = if (raw.len > 0 and raw[raw.len - 1] == '/')
        ""
    else
        std.fs.path.basename(raw);

    var dir = if (std.fs.path.isAbsolute(parent))
        std.Io.Dir.openDirAbsolute(std.Options.debug_io, parent, .{ .iterate = true }) catch return false
    else
        std.Io.Dir.cwd().openDir(std.Options.debug_io, parent, .{ .iterate = true }) catch return false;
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();
    var count: usize = 0;
    var common: [256]u8 = undefined;
    var common_len: usize = 0;
    var single_is_dir = false;
    while (iter.next() catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (count == 0) {
            common_len = @min(entry.name.len, common.len);
            @memcpy(common[0..common_len], entry.name[0..common_len]);
            single_is_dir = entry.kind == .directory;
        } else {
            common_len = commonPrefixLen(common[0..common_len], entry.name);
            single_is_dir = false;
        }
        count += 1;
    }
    if (count == 0 or common_len <= prefix.len) return false;

    var completed: [512]u8 = undefined;
    var next_len: usize = 0;
    if (!std.mem.eql(u8, parent, ".")) {
        const parent_len = @min(parent.len, completed.len);
        @memcpy(completed[0..parent_len], parent[0..parent_len]);
        next_len = parent_len;
        if (next_len < completed.len and (next_len == 0 or completed[next_len - 1] != '/')) {
            completed[next_len] = '/';
            next_len += 1;
        }
    }
    const room = completed.len - next_len;
    const name_len = @min(common_len, room);
    @memcpy(completed[next_len..][0..name_len], common[0..name_len]);
    next_len += name_len;
    if (count == 1 and single_is_dir and next_len < completed.len) {
        completed[next_len] = '/';
        next_len += 1;
    }
    @memcpy(self.workspace.create_path_buf[0..next_len], completed[0..next_len]);
    self.workspace.create_path_len = next_len;
    return true;
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return i;
}

fn handleCreateSubmitKey(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches(vaxis.Key.enter, .{})) {
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
    if (self.workspace.create_mode == .create) {
        if (!normalizeCreatePath(self)) {
            self.workspace.create_error_kind = .invalid_path;
            self.workspace.create_focus = .path;
            writeErrorMessage(self, "Path does not exist.");
            return;
        }
    }

    self.workspace.create_phase = .submitting;
    self.workspace.create_error_kind = .none;
    self.workspace.create_error_len = 0;

    if (self.workspace.create_mode == .edit) {
        const ws_id = self.workspace.create_edit_ws_id_buf[0..self.workspace.create_edit_ws_id_len];
        api.specs.dispatchFromState(
            api.specs.UpdateWorkspaceParams,
            workspace_api.CreateWorkspaceResponse,
            api.specs.update_workspace,
            &self.api_state.update_ws_pending,
            self.api_state,
            .{
                .ws_id = ws_id,
                .name = name,
                .description = self.workspace.create_desc_buf[0..self.workspace.create_desc_len],
            },
        );
        return;
    }

    api.specs.dispatchFromState(
        workspace_api.CreateWorkspaceRequest,
        workspace_api.CreateWorkspaceResponse,
        api.specs.create_workspace,
        &self.api_state.create_ws_pending,
        self.api_state,
        .{
            .name = name,
            .description = self.workspace.create_desc_buf[0..self.workspace.create_desc_len],
            .bundle_id = createSelectedBundleId(self),
        },
    );
}

fn normalizeCreatePath(self: anytype) bool {
    const raw = self.workspace.create_path_buf[0..self.workspace.create_path_len];
    if (raw.len == 0) return false;
    const alloc = self.api_state.backing_allocator;
    const real = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, raw, alloc) catch return false;
    defer alloc.free(real);
    writeFixedBuf(&self.workspace.create_path_buf, &self.workspace.create_path_len, real);
    return true;
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
    if (!self.workspace.create_bound_ok and key.matches('c', .{})) {
        copyCreateInitCommand(self);
        self.workspace.create_init_copied = true;
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
    if (self.workspace.create_mode == .edit) return 0;
    self.api_state.mutex.lockUncancelable(std.Options.debug_io);
    defer self.api_state.mutex.unlock(std.Options.debug_io);
    if (self.api_state.bundles) |list| return list.len;
    return 0;
}

fn createSelectedBundleId(self: anytype) ?[]const u8 {
    const idx = self.workspace.create_selected_bundle orelse return null;
    self.api_state.mutex.lockUncancelable(std.Options.debug_io);
    defer self.api_state.mutex.unlock(std.Options.debug_io);
    const bundles = self.api_state.bundles orelse return null;
    if (idx >= bundles.len) return null;
    if (bundles[idx].bundle_id.len == 0) return null;
    return bundles[idx].bundle_id;
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
            self.workspace.create_init_copied = false;
            self.workspace.create_phase = .success;
            self.workspace.create_error_kind = .none;
            self.workspace.create_error_len = 0;
            if (self.workspace.create_mode == .create) {
                const bind_path = self.workspace.create_path_buf[0..self.workspace.create_path_len];
                self.bindWorkspacePath(resp.name, resp.ws_id, bind_path) catch |err| {
                    self.notifyOp(.warning, "Workspace created, but path binding failed.");
                    std.log.scoped(.workspace).warn("create_bind_path_failed ws_id={s} error={s}", .{ resp.ws_id, @errorName(err) });
                    return;
                };
                writeFixedBuf(&self.workspace.create_bound_path_buf, &self.workspace.create_bound_path_len, bind_path);
                self.workspace.create_bound_ok = true;
            }
            _ = self.materializeWorkspaceCache(resp.ws_id) catch |err| {
                self.notifyOp(.warning, "Workspace created, but initial sync failed.");
                std.log.scoped(.workspace).warn("create_initial_sync_failed ws_id={s} error={s}", .{ resp.ws_id, @errorName(err) });
                return;
            };
            self.notifyOp(.success, if (self.workspace.create_mode == .create) "Workspace created, bound, and synced." else "Workspace updated.");
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
        var writer = std.Io.File.Writer.init(stdin, std.Options.debug_io, &buf);
        writer.interface.writeAll(text) catch {};
        writer.interface.flush() catch {};
        stdin.close(std.Options.debug_io);
        child.stdin = null;
    }

    _ = child.wait() catch {};
}

fn drawCreateForm(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    const bundle_list_h = createBundleListHeight(self);
    const has_error = self.workspace.create_error_kind != .none;
    const path_h: u16 = if (self.workspace.create_mode == .create) 2 else 0;
    const box_h = bundle_list_h + path_h + if (has_error) @as(u16, 15) else @as(u16, 13);
    const modal = Modal{
        .title = if (self.workspace.create_mode == .edit) "Rename Workspace" else "Create Workspace",
        .box_width = CREATE_BOX_W,
        .box_height = box_h,
    };
    const dr = try modal.draw(ctx, self.widget());
    var surface = dr.surface;
    const c0 = dr.content_col;
    const r0 = dr.content_row;
    const content_w = dr.content_width;
    const bg = theme.PANEL_ALT;

    var row: u16 = r0;
    const label_w: u16 = 14;

    w.writeText(&surface, ctx, c0, row, "Name *", theme.textOn(bg, theme.MUTED));
    w.drawTextInputSlot(
        &surface,
        ctx,
        c0 + label_w + 1,
        row,
        content_w -| (label_w + 2),
        self.workspace.create_name_buf[0..self.workspace.create_name_len],
        theme.TEXT,
        self.workspace.create_focus == .name,
    );
    row += 1;
    row += 1;

    w.writeText(&surface, ctx, c0, row, "Description", theme.textOn(bg, theme.MUTED));
    w.drawTextInputSlot(
        &surface,
        ctx,
        c0 + label_w + 1,
        row,
        content_w -| (label_w + 2),
        self.workspace.create_desc_buf[0..self.workspace.create_desc_len],
        theme.TEXT,
        self.workspace.create_focus == .description,
    );
    row += 1;
    row += 1;

    if (self.workspace.create_mode == .create) {
        w.writeText(&surface, ctx, c0, row, "Path", theme.textOn(bg, theme.MUTED));
        w.drawTextInputSlot(
            &surface,
            ctx,
            c0 + label_w + 1,
            row,
            content_w -| (label_w + 2),
            self.workspace.create_path_buf[0..self.workspace.create_path_len],
            theme.TEXT,
            self.workspace.create_focus == .path,
        );
        row += 1;
        row += 1;
    }

    if (self.workspace.create_mode == .create) {
        w.writeText(&surface, ctx, c0, row, "Bundle", theme.textOn(bg, theme.MUTED));
        w.writeTextMax(
            &surface,
            ctx,
            c0 + label_w + 1,
            row,
            content_w -| (label_w + 2),
            "Choose initial rules for this workspace.",
            theme.textOn(bg, theme.DIM),
        );
        row += 1;
        drawCreateBundleList(self, &surface, ctx, c0, row, content_w, bundle_list_h, bg);
        row += bundle_list_h + 1;
    }

    const focused = self.workspace.create_focus == .submit;
    const button_label = if (self.workspace.create_phase == .submitting)
        "[ Submitting... ]"
    else if (self.workspace.create_mode == .edit)
        "[ Save ]"
    else
        "[ Create Workspace ]";
    const button_style: vaxis.Style = if (focused)
        theme.boldOn(theme.PANEL_ALT, theme.TEXT)
    else
        theme.boldOn(theme.PANEL_ALT, theme.TEXT_SOFT);
    w.writeText(&surface, ctx, c0, row, button_label, button_style);

    if (has_error) {
        const err_row = row + 2;
        const err_text = self.workspace.create_error_buf[0..self.workspace.create_error_len];
        _ = w.writeWrappedTextMax(&surface, ctx, c0, err_row, content_w, 2, err_text, theme.textOn(bg, theme.DANGER));
    }

    return surface;
}

fn createBundleListHeight(self: anytype) u16 {
    if (self.workspace.create_mode == .edit) return 0;
    self.api_state.mutex.lockUncancelable(std.Options.debug_io);
    const bundles_opt = self.api_state.bundles;
    self.api_state.mutex.unlock(std.Options.debug_io);
    const count = if (bundles_opt) |bundles| bundles.len else 1;
    if (count == 0) return 3;
    return @intCast(@min(count + 2, 6));
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
    self.api_state.mutex.lockUncancelable(std.Options.debug_io);
    const bundles_opt = self.api_state.bundles;
    self.api_state.mutex.unlock(std.Options.debug_io);

    const list_focused = self.workspace.create_focus == .bundle;

    const bundles = bundles_opt orelse {
        w.writeTextMax(surface, ctx, col + 2, row + 1, width -| 4, "loading bundles...", theme.textOn(bg, theme.MUTED));
        return;
    };
    if (bundles.len == 0) {
        w.writeTextMax(surface, ctx, col + 2, row + 1, width -| 4, "No bundles available.", theme.textOn(bg, theme.MUTED));
        return;
    }

    const visible_rows: u16 = height - 2;
    const cursor = self.workspace.create_bundle_cursor;
    const window = w.TreeList.visibleWindow(cursor, bundles.len, visible_rows);

    var i: usize = window.start;
    while (i < bundles.len and i < window.start + window.len) : (i += 1) {
        const b = bundles[i];
        const is_cursor = i == cursor;
        const is_selected = self.workspace.create_selected_bundle != null and
            self.workspace.create_selected_bundle.? == i;
        const bundle_text = std.fmt.allocPrint(
            ctx.arena,
            "{s} ({d} rules)",
            .{ b.name, b.rule_count },
        ) catch continue;

        const render_row: u16 = row + 1 + @as(u16, @intCast(i - window.start));
        w.TreeList.drawItem(surface, ctx, render_row, col + width, .{
            .text = bundle_text,
            .cursor = is_cursor and list_focused,
            .active = is_selected,
            .selector = if (is_selected) .on else .off,
        }, .{
            .background = bg,
            .text_col = col,
            .show_cursor_marker = false,
        });
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

    if (self.workspace.create_bound_ok) {
        const bound_path = self.workspace.create_bound_path_buf[0..self.workspace.create_bound_path_len];
        w.writeText(&surface, ctx, c0, row, "Bound path", theme.textOn(bg, theme.MUTED));
        row += 1;
        row = w.writeWrappedTextMax(&surface, ctx, c0, row, dr.content_width, 2, bound_path, theme.textOn(bg, theme.TEXT_SOFT));
        row += 1;
        w.writeText(&surface, ctx, c0, row, "Local cache synced.", theme.textOn(bg, theme.OK));
        return surface;
    }

    w.writeTextMax(
        &surface,
        ctx,
        c0,
        row,
        dr.content_width,
        "To bind this workspace to a local directory, run from the target dir:",
        theme.textOn(bg, theme.TEXT),
    );
    row += 2;

    const copy_hint = if (self.workspace.create_init_copied) "copied" else "c copy command";
    const copy_hint_w: u16 = @intCast(@min(ctx.stringWidth(copy_hint), dr.content_width));
    const copy_hint_style = if (self.workspace.create_init_copied)
        theme.textOn(bg, theme.OK)
    else
        theme.textOn(bg, theme.MUTED);
    w.writeText(&surface, ctx, c0, row, "Command", theme.textOn(bg, theme.MUTED));
    w.writeText(&surface, ctx, c0 + dr.content_width -| copy_hint_w, row, copy_hint, copy_hint_style);
    row += 1;

    const cmd = try std.fmt.allocPrint(
        ctx.arena,
        "$ clumsies init --ws-id {s}",
        .{ws_id},
    );
    _ = w.writeWrappedTextMax(&surface, ctx, c0, row, dr.content_width, 2, cmd, theme.boldOn(bg, theme.ACCENT));
    return surface;
}

test "CreateWsFocus.next cycles through form fields when no bundles" {
    try std.testing.expectEqual(CreateWsFocus.description, CreateWsFocus.name.next(0, false));
    try std.testing.expectEqual(CreateWsFocus.submit, CreateWsFocus.description.next(0, false));
    try std.testing.expectEqual(CreateWsFocus.name, CreateWsFocus.submit.next(0, false));
}

test "CreateWsFocus.next includes bundle when bundles available" {
    try std.testing.expectEqual(CreateWsFocus.bundle, CreateWsFocus.description.next(3, false));
    try std.testing.expectEqual(CreateWsFocus.submit, CreateWsFocus.bundle.next(3, false));
}

test "CreateWsFocus.next includes path for create flow" {
    try std.testing.expectEqual(CreateWsFocus.path, CreateWsFocus.description.next(0, true));
    try std.testing.expectEqual(CreateWsFocus.submit, CreateWsFocus.path.next(0, true));
    try std.testing.expectEqual(CreateWsFocus.bundle, CreateWsFocus.path.next(3, true));
}

test "CreateWsFocus.prev mirrors next" {
    try std.testing.expectEqual(CreateWsFocus.submit, CreateWsFocus.name.prev(0, false));
    try std.testing.expectEqual(CreateWsFocus.description, CreateWsFocus.submit.prev(0, false));
    try std.testing.expectEqual(CreateWsFocus.bundle, CreateWsFocus.submit.prev(3, false));
    try std.testing.expectEqual(CreateWsFocus.path, CreateWsFocus.submit.prev(0, true));
}

test "PendingPullAll recordResumeAttempt caps retries" {
    var pending = PendingPullAll{ .tab = .context };

    var attempt: usize = 0;
    while (attempt < MAX_PULL_ALL_RESUME_ATTEMPTS) : (attempt += 1) {
        try std.testing.expect(pending.recordResumeAttempt());
    }

    try std.testing.expect(!pending.recordResumeAttempt());
    try std.testing.expectEqual(@as(u8, MAX_PULL_ALL_RESUME_ATTEMPTS), pending.resume_attempts);
}

test "appendUniquePullPath skips empty and duplicate values" {
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(std.testing.allocator);

    try std.testing.expect(appendUniquePullPath(std.testing.allocator, &items, ""));
    try std.testing.expectEqual(@as(usize, 0), items.items.len);

    try std.testing.expect(appendUniquePullPath(std.testing.allocator, &items, "specs/ONE.md"));
    try std.testing.expect(appendUniquePullPath(std.testing.allocator, &items, "specs/ONE.md"));
    try std.testing.expect(appendUniquePullPath(std.testing.allocator, &items, "specs/TWO.md"));

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqualStrings("specs/ONE.md", items.items[0]);
    try std.testing.expectEqualStrings("specs/TWO.md", items.items[1]);
}

test "contextExistsRemotely matches by context id or path" {
    const remote = [_]api.model.WorkspaceContextData{
        .{ .context_id = "ctx-one", .path = "specs/ONE.md", .hash = "h1", .size = 1 },
        .{ .context_id = "ctx-two", .path = "specs/TWO.md", .hash = "h2", .size = 2 },
    };

    try std.testing.expect(contextExistsRemotely(&remote, .{
        .context_id = "ctx-one",
        .path = "specs/RENAMED.md",
        .hash = "old",
        .size = 1,
    }));
    try std.testing.expect(contextExistsRemotely(&remote, .{
        .context_id = "",
        .path = "specs/TWO.md",
        .hash = "old",
        .size = 2,
    }));
    try std.testing.expect(!contextExistsRemotely(&remote, .{
        .context_id = "ctx-missing",
        .path = "specs/MISSING.md",
        .hash = "old",
        .size = 3,
    }));
}
