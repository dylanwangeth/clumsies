const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const w = @import("../widgets.zig");
const data = @import("../view_types.zig");
const api = @import("../api.zig");
const drafts_mod = @import("../../drafts.zig");
const prompt_detail = @import("prompt_detail.zig");
const Modal = @import("../widgets/modal.zig").Modal;

const MAX_TREE_ROWS = 128;

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
    /// Path of the selected context file — set for both server-side
    /// files and virtual create-op drafts. drawDetail treats this as
    /// the primary identity and only uses `context_sel` to pull
    /// hub-side metadata (hash / author / updated_at).
    context_sel_path: ?[]const u8,
    prompt_sel_idx: ?usize,
    prompt_sel_path: ?[]const u8,
};

pub fn drawStatus(
    self: anytype,
    ctx: vxfw.DrawContext,
    wss: []const data.WorkspaceEntry,
    list_surface: vxfw.Surface,
    detail_surface: vxfw.Surface,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.PANEL);

    const inner_w = size.width -| 2;
    const cols: u16 = if (inner_w >= 120) 4 else if (inner_w >= 80) 3 else 2;
    self.ws_grid_cols = cols;
    const card_w: u16 = inner_w / cols;
    const ws_count: u16 = @intCast(if (wss.len > 0) wss.len else 1);
    const grid_rows: u16 = (ws_count + cols - 1) / cols;
    const bar_h: u16 = 1 + grid_rows + 1;

    const bar_border = w.focusBorder(self.ws_focus == .bar);
    var bar = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = size.width, .height = bar_h });
    w.fillSurface(&bar, theme.PANEL);
    w.drawBorder(&bar, bar_border, theme.PANEL);
    w.writeText(&bar, ctx, 2, 0, "Workspaces", theme.boldOn(theme.PANEL, theme.TEXT));

    if (wss.len == 0) {
        const status = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            break :blk self.api_state.status;
        };
        w.drawEmptyState(&bar, ctx, 2, 1, status, "workspaces");
    }

    const ws_idx = if (wss.len > 0) @min(self.ws_sel, wss.len - 1) else 0;
    for (wss, 0..) |wsi, i| {
        const is_sel = i == ws_idx;
        const grid_col: u16 = @intCast(i % cols);
        const grid_row: u16 = @intCast(i / cols);
        const x = 1 + grid_col * card_w;
        const y = 1 + grid_row;

        if (is_sel) {
            w.writeCursorMarker(&bar, x, y);
        }

        const name_x = x + 1;
        const needs_sync = wsi.local_rev != wsi.remote_rev;
        const label = if (needs_sync)
            try std.fmt.allocPrint(ctx.arena, "{s} *", .{wsi.name})
        else
            wsi.name;

        if (is_sel) {
            w.writeText(&bar, ctx, name_x, y, label, theme.boldOn(theme.PANEL, theme.TEXT));
        } else {
            w.writeText(&bar, ctx, name_x, y, wsi.name, theme.fg(theme.TEXT_SOFT));
            if (needs_sync) {
                const nw: u16 = @intCast(ctx.stringWidth(wsi.name));
                w.writeText(&bar, ctx, name_x + nw + 1, y, "*", theme.fg(theme.WARN));
            }
        }
    }

    const list_w: u16 = size.width / 3;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = bar };
    children[1] = .{ .origin = .{ .row = bar_h, .col = 0 }, .surface = list_surface };
    children[2] = .{ .origin = .{ .row = bar_h, .col = list_w + 1 }, .surface = detail_surface };
    root.children = children;
    return root;
}

pub fn drawList(
    self: anytype,
    ctx: vxfw.DrawContext,
    ws_tree: anytype,
    live_ws: ?api.model.WsDetail,
    lib_prompts: []const data.PromptEntry,
) std.mem.Allocator.Error!vxfw.Surface {
    const list_border = w.focusBorder(self.ws_focus == .list);
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, list_border, theme.PANEL);
    const row_col: u16 = 2;
    const cursor_col: u16 = 1;

    var tab_col: u16 = 2;
    const ws_tabs = [_]@TypeOf(self.ws_tab){ .context, .prompts };
    for (ws_tabs) |tab| {
        tab_col = w.drawInnerTabBadge(&surface, ctx, 0, tab_col, wsTabLabel(tab), tab == self.ws_tab);
        tab_col +|= 1;
    }

    const inner_h = ctx.max.height.? -| 2;
    if (ws_tree.rowCount() == 0) {
        const empty_msg = switch (self.ws_tab) {
            .context => "No context files.",
            .prompts => "No workspace prompts.",
        };
        w.writeText(&surface, ctx, row_col, 1, empty_msg, theme.fg(theme.MUTED));
        return surface;
    }

    var kv_row: u16 = 1;
    var r: usize = 0;
    while (r < ws_tree.rowCount() and kv_row < inner_h + 1) : (r += 1) {
        const sel = r == self.ws_list_sel;
        if (sel) {
            w.writeCursorMarker(&surface, cursor_col, kv_row);
        }

        const rendered = ws_tree.rowText(r);
        if (ws_tree.dirPathAt(r) != null) {
            const style = if (sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.boldOn(theme.PANEL, theme.TEXT_SOFT);
            w.writeText(&surface, ctx, row_col, kv_row, rendered, style);
        } else {
            const draft_status = blk: {
                const ws_d = live_ws orelse break :blk null;
                const leaf = ws_tree.leafIndexAt(r) orelse break :blk null;
                const MarkerInfo = struct {
                    category: drafts_mod.DraftCategory,
                    path: []const u8,
                };
                const marker_info: ?MarkerInfo = switch (self.ws_tab) {
                    .context => inner: {
                        if (leaf < ws_d.context_files.len) {
                            break :inner MarkerInfo{
                                .category = .context,
                                .path = ws_d.context_files[leaf].path,
                            };
                        }
                        // Virtual row: create-op draft. Path lives
                        // in drafts_create_context_paths, offset past
                        // the server-side context file count.
                        const k = leaf - ws_d.context_files.len;
                        if (k >= self.drafts_create_context_paths.len) break :inner null;
                        break :inner MarkerInfo{
                            .category = .context,
                            .path = self.drafts_create_context_paths[k],
                        };
                    },
                    .prompts => inner: {
                        if (leaf >= ws_d.ws_prompts.len) break :inner null;
                        const wp = ws_d.ws_prompts[leaf];
                        const prompt_path = if (wp.path.len > 0)
                            wp.path
                        else for (lib_prompts) |lp| {
                            if (std.mem.eql(u8, lp.content_hash, wp.content_hash)) break lp.path;
                        } else wp.prompt_id;
                        break :inner MarkerInfo{ .category = .prompt, .path = prompt_path };
                    },
                };
                const m = marker_info orelse break :blk null;
                break :blk self.draftStatusFor(m.category, m.path);
            };
            const row_fg = if (draft_status) |s|
                theme.draftStatusColor(s)
            else if (sel)
                theme.TEXT
            else
                theme.TEXT_SOFT;
            const row_style = if (sel) theme.boldOn(theme.PANEL, row_fg) else theme.fg(row_fg);
            w.writeText(&surface, ctx, row_col, kv_row, rendered, row_style);
            if (draft_status != null) {
                const nw: u16 = @intCast(ctx.stringWidth(rendered));
                w.writeText(&surface, ctx, row_col + nw + 1, kv_row, "*", row_style);
            }
        }
        kv_row += 1;
    }

    return surface;
}

pub fn drawDetail(
    self: anytype,
    ctx: vxfw.DrawContext,
    args: DetailArgs,
) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    const content_border = w.focusBorder(self.ws_focus == .content);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, content_border, theme.PANEL);

    if (args.live_ws == null) {
        w.writeText(&surface, ctx, 2, 0, "Content", theme.boldOn(theme.PANEL, theme.TEXT));
        w.writeText(&surface, ctx, 2, 2, "No workspace data loaded.", theme.fg(theme.MUTED));
        return surface;
    }
    const ws_d = args.live_ws.?;

    const title: []const u8 = switch (self.ws_tab) {
        .context => if (args.dir_sel) |dir| dir else if (args.context_sel_path) |p| p else "no files",
        .prompts => if (args.dir_sel) |dir| dir else if (args.prompt_sel_path) |path| path else "no prompts",
    };
    w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
    // Reserve min_col past the title (plus one space) so the
    // right-aligned metadata badge never overlaps the path.
    const title_w: u16 = @intCast(ctx.stringWidth(title));
    const meta_min_col: u16 = 2 + title_w + 2;
    if (self.ws_show_diff) {
        w.writeText(&surface, ctx, meta_min_col, 0, "diff", theme.boldOn(theme.PANEL, theme.ACCENT));
    } else if (args.dir_sel == null) {
        try writeWsMetaOnHeader(&surface, ctx, meta_min_col, self, ws_d, args);
    }

    const kv_row: u16 = 2;
    const max_row = ctx.max.height.? -| 1;

    switch (self.ws_tab) {
        .context => {
            if (args.dir_sel != null) {
                try drawDirSelected(&surface, ctx, kv_row, max_row);
            } else if (args.context_sel_path) |sel_path| {
                try drawContextFileDetail(self, &surface, ctx, kv_row, max_row, ws_d, sel_path);
            } else {
                w.writeText(&surface, ctx, 2, kv_row, "No context files.", theme.fg(theme.MUTED));
            }
        },
        .prompts => {
            if (args.dir_sel != null) {
                try drawDirSelected(&surface, ctx, kv_row, max_row);
            } else if (args.prompt_sel_path) |p| {
                try drawPromptFileDetail(self, &surface, ctx, kv_row, max_row, p);
            } else {
                w.writeText(&surface, ctx, 2, kv_row, "No workspace prompts.", theme.fg(theme.MUTED));
            }
        },
    }

    return surface;
}

/// Render a one-line metadata badge at the top-right of the header,
/// mirroring Library's `rev{N} pr{N} c{N} {updated}` convention. For
/// context files we render `hash7 author updated`; for workspace
/// prompts the hash is all we have from the manifest; for virtual
/// (create-op) drafts we render an accent-colored `(new)` banner so
/// the user knows the file is unsubmitted.
fn writeWsMetaOnHeader(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    min_col: u16,
    self: anytype,
    ws_d: api.model.WsDetail,
    args: DetailArgs,
) !void {
    switch (self.ws_tab) {
        .context => {
            if (args.context_sel) |idx| {
                if (idx >= ws_d.context_files.len) return;
                const f = &ws_d.context_files[idx];
                const hash7 = hashBadge(f.hash);
                const updated_short = try w.formatShortTimestamp(ctx.arena, f.updated_at);
                const meta = try std.fmt.allocPrint(
                    ctx.arena,
                    "{s}  {s}  {s}",
                    .{ hash7, f.author, updated_short },
                );
                _ = writeHeaderRightIfFits(surface, ctx, 0, min_col, meta, theme.fg(theme.MUTED));
            } else if (args.context_sel_path != null) {
                // Virtual row: local create-op draft, no hub metadata.
                _ = writeHeaderRightIfFits(surface, ctx, 0, min_col, "(new)", theme.fg(theme.ACCENT));
            }
        },
        .prompts => {
            if (args.prompt_sel_idx) |idx| {
                if (idx >= ws_d.ws_prompts.len) return;
                const p = &ws_d.ws_prompts[idx];
                const hash7 = hashBadge(p.content_hash);
                _ = writeHeaderRightIfFits(surface, ctx, 0, min_col, hash7, theme.fg(theme.MUTED));
            }
        },
    }
}

fn hashBadge(raw: []const u8) []const u8 {
    // Hashes usually arrive as "sha256:hex"; keep 7 hex chars after
    // the colon so they land roughly in git's abbreviated-SHA range
    // without padding the header badge.
    const colon = std.mem.indexOfScalar(u8, raw, ':');
    const start = if (colon) |c| c + 1 else 0;
    const slice = raw[start..];
    return slice[0..@min(7, slice.len)];
}

fn writeHeaderRightIfFits(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    row: u16,
    min_col: u16,
    text: []const u8,
    style: vaxis.Style,
) bool {
    const width: u16 = @intCast(ctx.stringWidth(text));
    if (width == 0 or width >= surface.size.width) return false;
    const start_col = surface.size.width - width - 1;
    if (start_col <= min_col) return false;
    w.writeText(surface, ctx, start_col, row, text, style);
    return true;
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
    ws_d: api.model.WsDetail,
    path: []const u8,
) !void {
    if (self.ws_show_diff) {
        w.writeText(surface, ctx, 2, start_row, "No diff available", theme.fg(theme.MUTED));
        return;
    }
    try attachContentSurface(self, surface, ctx, start_row, max_row, .{
        .context = .{ .ws_id = ws_d.ws_id, .path = path },
    });
}

fn drawPromptFileDetail(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    start_row: u16,
    max_row: u16,
    prompt_path: []const u8,
) !void {
    if (self.ws_show_diff) {
        w.writeText(surface, ctx, 2, start_row, "No diff available", theme.fg(theme.MUTED));
        return;
    }
    try attachContentSurface(self, surface, ctx, start_row, max_row, .{
        .prompt = .{ .path = prompt_path },
    });
}

const ContentSource = union(enum) {
    context: struct { ws_id: []const u8, path: []const u8 },
    prompt: struct { path: []const u8 },
};

/// Seed the shared content_scroll_bars with working-copy bytes for
/// the source and attach the scroll view as a child surface below
/// the metadata rows. Library's prompt_detail path uses the same
/// scroll bars, so switching modules redraws content into the same
/// widget state — no per-module scroll state today.
fn attachContentSurface(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    start_row: u16,
    max_row: u16,
    source: ContentSource,
) !void {
    switch (source) {
        .context => |c| prompt_detail.syncWsContextContentWidget(self, c.ws_id, c.path),
        .prompt => |p| prompt_detail.syncWsPromptContentWidget(self, p.path),
    }
    const content_h: u16 = if (max_row > start_row) max_row - start_row else 0;
    if (content_h == 0) return;
    const width_pad: u16 = 4;
    const inner_ctx = ctx.withConstraints(
        .{ .width = ctx.max.width.? -| width_pad, .height = content_h },
        .{ .width = ctx.max.width.? -| width_pad, .height = content_h },
    );
    const body = try prompt_detail.buildContentSurface(self, inner_ctx, width_pad, content_h);
    const prev = surface.children;
    const children = try ctx.arena.alloc(vxfw.SubSurface, prev.len + 1);
    for (prev, 0..) |c, i| children[i] = c;
    children[prev.len] = .{ .origin = .{ .row = start_row, .col = 2 }, .surface = body };
    surface.children = children;
}

pub fn handleModuleEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) anyerror!void {
    if (key.matches(vaxis.Key.tab, .{})) {
        self.ws_focus = switch (self.ws_focus) {
            .bar => .list,
            .list => .content,
            .content => .bar,
        };
        ctx.consumeAndRedraw();
        return;
    }

    if (key.matches('c', .{})) {
        self.openCreateWorkspace();
        ctx.consumeAndRedraw();
        return;
    }

    if (key.matches(']', .{})) {
        self.shiftWsTab(1);
        self.ws_list_sel = 0;
        self.ws_show_diff = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('[', .{})) {
        self.shiftWsTab(-1);
        self.ws_list_sel = 0;
        self.ws_show_diff = false;
        ctx.consumeAndRedraw();
        return;
    }

    // `n` creates a new context-file draft. Bound at module level
    // (like Library's `n`) rather than inside list-focus so users
    // can still reach it from the workspace bar without tabbing
    // into the list first. Prompts are org-owned — workspace does
    // not create them, so `n` is gated on the Context tab.
    if (key.matches('n', .{}) and self.ws_tab == .context) {
        self.openNewDraftForm(.context);
        ctx.consumeAndRedraw();
        return;
    }

    switch (self.ws_focus) {
        .bar => try handleBarFocusEvent(self, ctx, key),
        .list => try handleListFocusEvent(self, ctx, key),
        .content => try handleContentFocusEvent(self, ctx, key),
    }

    if (key.matches('r', .{})) {
        api.state.invalidateOnDemandCaches(self.api_state);
        self.invalidateRemoteDetailRequests();
        api.fetch.refetchAllAsync(self.api_state);
        self.status_line = "Refreshing data...";
        ctx.consumeAndRedraw();
    }
}

fn wsTabLabel(tab: anytype) []const u8 {
    return switch (tab) {
        .context => "Context",
        .prompts => "Prompts",
    };
}

fn handleBarFocusEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) anyerror!void {
    const ws_count = self.wsCount();
    const cols = self.ws_grid_cols;

    if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        if (self.ws_sel + 1 < ws_count) {
            self.ws_sel += 1;
            ctx.consumeAndRedraw();
        }
        return;
    }
    if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        if (self.ws_sel > 0) {
            self.ws_sel -= 1;
            ctx.consumeAndRedraw();
        }
        return;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (self.ws_sel + cols < ws_count) {
            self.ws_sel += cols;
            ctx.consumeAndRedraw();
        }
        return;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.ws_sel >= cols) {
            self.ws_sel -= cols;
            ctx.consumeAndRedraw();
        }
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        self.ws_focus = .list;
        self.ws_list_sel = 0;
        self.ws_show_diff = false;
        self.resetWorkspaceTrees();

        self.api_state.mutex.lock();
        const ws_list = if (self.api_state.current_user) |user| user.workspaces else &.{};
        if (self.ws_sel < ws_list.len) {
            const ws_id = ws_list[self.ws_sel].ws_id;
            self.api_state.mutex.unlock();
            requestWorkspaceDetail(self, ws_id);
        } else {
            self.api_state.mutex.unlock();
        }
        ctx.consumeAndRedraw();
    }
}

fn handleListFocusEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) anyerror!void {
    syncWsRows(self);
    const ws_tree = self.currentWsTree();

    if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        if (ws_tree.dirPathAt(self.ws_list_sel)) |dir| {
            if (ws_tree.collapseDir(dir)) {
                self.ws_show_diff = false;
                ctx.consumeAndRedraw();
                return;
            }
        }
        if (ws_tree.parentRow(self.ws_list_sel)) |parent| {
            self.ws_list_sel = parent;
            self.ws_show_diff = false;
            ctx.consumeAndRedraw();
            return;
        }
        return;
    }
    if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        if (ws_tree.dirPathAt(self.ws_list_sel)) |dir| {
            if (ws_tree.expandDir(self.api_state.allocator(), dir)) {
                self.ws_show_diff = false;
                ctx.consumeAndRedraw();
                return;
            }
        }
        return;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (self.ws_list_sel + 1 < ws_tree.rowCount()) {
            self.ws_list_sel += 1;
            self.ws_show_diff = false;
            ctx.consumeAndRedraw();
        }
        return;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.ws_list_sel > 0) {
            self.ws_list_sel -= 1;
            self.ws_show_diff = false;
            ctx.consumeAndRedraw();
        }
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (ws_tree.dirPathAt(self.ws_list_sel)) |dir| {
            ws_tree.toggleDir(self.api_state.allocator(), dir);
            self.ws_show_diff = false;
            ctx.consumeAndRedraw();
            return;
        }
        self.ws_focus = .content;
        self.ws_show_diff = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        self.ws_focus = .bar;
        ctx.consumeAndRedraw();
    }
}

fn handleContentFocusEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) anyerror!void {
    if (key.matches(vaxis.Key.escape, .{})) {
        self.ws_focus = .list;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('d', .{})) {
        self.ws_show_diff = !self.ws_show_diff;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('e', .{})) {
        self.editSelectedDraft();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('D', .{ .shift = true })) {
        self.requestDiscardSelectedDraft();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('m', .{})) {
        self.toggleSelectedDraftReady();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('p', .{})) {
        self.openPrComposer();
        ctx.consumeAndRedraw();
        return;
    }
    // Forward scroll keys to the shared content_scroll_bars so j/k,
    // arrow keys, PgUp/PgDn, g/G drive the content panel identically
    // to the Library prompt-detail pane. vxfw's ScrollView consumes
    // the ones it knows and ignores the rest, so this is safe as a
    // catch-all.
    try self.content_scroll_bars.scroll_view.handleEvent(ctx, .{ .key_press = key });
}

/// Trigger the workspace-detail compound fetch. Issues two dispatches
/// (context files + manifest) that land independently in their
/// respective PendingRequest slots; `syncWsRows` composes them once
/// both caches are populated via `state.wsDetail`.
pub fn requestWorkspaceDetail(self: anytype, ws_id: []const u8) void {
    if (self.api_state.ws_context_files_cache.shouldDispatch(.{ .value = ws_id })) {
        api.specs.dispatchFromState(
            api.specs.WsIdParams,
            api.specs.WsContextFilesPayload,
            api.specs.workspace_context_files,
            &self.api_state.ws_context_files_pending,
            self.api_state,
            .{ .ws_id = ws_id },
        );
    }
    if (self.api_state.ws_manifest_cache.shouldDispatch(.{ .value = ws_id })) {
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
        api.state.wsDetail(self.api_state, ws_id)
    else
        null;

    if (live_ws == null) {
        self.currentWsTree().sync(self.api_state.allocator(), &.{}, &.{});
        self.ws_list_sel = 0;
        return;
    }
    const ws_d = live_ws.?;

    var paths_buf: [MAX_TREE_ROWS][]const u8 = undefined;
    var orig_idx: [MAX_TREE_ROWS]usize = undefined;
    var item_count: usize = 0;

    switch (self.ws_tab) {
        .context => {
            item_count = @min(ws_d.context_files.len, MAX_TREE_ROWS);
            for (0..item_count) |i| {
                paths_buf[i] = ws_d.context_files[i].path;
                orig_idx[i] = i;
            }
            // Append local create-op context drafts as virtual rows.
            // Leaf index is offset by ws_d.context_files.len so
            // selectedDraftTarget can distinguish server rows from
            // create-only drafts.
            const create_paths = self.drafts_create_context_paths;
            var k: usize = 0;
            while (k < create_paths.len and item_count < MAX_TREE_ROWS) : (k += 1) {
                paths_buf[item_count] = create_paths[k];
                orig_idx[item_count] = ws_d.context_files.len + k;
                item_count += 1;
            }
        },
        .prompts => {
            const lib_prompts = self.getPrompts();
            item_count = @min(ws_d.ws_prompts.len, MAX_TREE_ROWS);
            for (0..item_count) |i| {
                const wp = ws_d.ws_prompts[i];
                paths_buf[i] = if (wp.path.len > 0)
                    wp.path
                else for (lib_prompts) |lp| {
                    if (std.mem.eql(u8, lp.content_hash, wp.content_hash)) break lp.path;
                } else wp.prompt_id;
                orig_idx[i] = i;
            }
            // Workspace does not own prompt creation, so no virtual
            // rows are appended here. Library is the place to create
            // a new prompt draft; once submitted and merged it shows
            // up through the workspace manifest.
        },
    }

    const ws_tree = self.currentWsTree();
    ws_tree.sync(self.api_state.allocator(), paths_buf[0..item_count], orig_idx[0..item_count]);
    if (ws_tree.rowCount() == 0) {
        self.ws_list_sel = 0;
    } else if (self.ws_list_sel >= ws_tree.rowCount()) {
        self.ws_list_sel = ws_tree.rowCount() - 1;
    }
}

const CREATE_BOX_W: u16 = 76;
const CREATE_FORM_BOX_H: u16 = 24;
const CREATE_SUCCESS_BOX_H: u16 = 14;

pub fn drawCreateOverlay(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    return switch (self.create_ws_phase) {
        .form, .submitting => drawCreateForm(self, ctx),
        .success => drawCreateSuccess(self, ctx),
    };
}

pub fn resetCreate(self: anytype) void {
    self.create_ws_phase = .form;
    self.create_ws_focus = .name;
    self.create_ws_name_len = 0;
    self.create_ws_desc_len = 0;
    self.create_ws_selected_bundle = null;
    self.create_ws_bundle_cursor = 0;
    self.create_ws_error_kind = .none;
    self.create_ws_error_len = 0;
    self.create_ws_created_id_len = 0;
    self.create_ws_created_name_len = 0;
}

pub fn createBundleCount(self: anytype) usize {
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    if (self.api_state.bundles) |list| return list.len;
    return 0;
}

pub fn createSelectedBundleName(self: anytype) ?[]const u8 {
    const idx = self.create_ws_selected_bundle orelse return null;
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    const bundles = self.api_state.bundles orelse return null;
    if (idx >= bundles.len) return null;
    return bundles[idx].name;
}

pub fn setCreateNameRequired(self: anytype) void {
    self.create_ws_error_kind = .name_required;
    writeErrorMessage(self, "Name is required");
}

const workspace_api = @import("clumsies_lib").protocol.workspace_api;

pub fn applyCreateResult(
    self: anytype,
    result: api.dispatcher.Result(workspace_api.CreateWorkspaceResponse),
) void {
    switch (result) {
        .ok => |resp| {
            writeFixedBuf(&self.create_ws_created_id_buf, &self.create_ws_created_id_len, resp.ws_id);
            writeFixedBuf(&self.create_ws_created_name_buf, &self.create_ws_created_name_len, resp.name);
            self.create_ws_phase = .success;
            self.create_ws_error_kind = .none;
            self.create_ws_error_len = 0;
            // Refresh the cached workspace list so the new workspace
            // appears in the grid once the background fetch completes.
            api.fetch.refetchAllAsync(self.api_state);
        },
        .api_error => |err| {
            self.create_ws_phase = .form;
            self.create_ws_error_kind = .api;
            writeErrorMessage(self, err.message);
            if (err.status == .conflict) self.create_ws_focus = .name;
        },
        .network_error => {
            self.create_ws_phase = .form;
            self.create_ws_error_kind = .network;
            writeErrorMessage(self, "Network error. Check connection and retry.");
        },
        .invalid_response => {
            self.create_ws_phase = .form;
            self.create_ws_error_kind = .invalid_response;
            writeErrorMessage(self, "Unexpected response from Hub.");
        },
    }
}

pub fn copyCreateInitCommand(self: anytype) void {
    const alloc = self.api_state.backing_allocator;
    const id = self.create_ws_created_id_buf[0..self.create_ws_created_id_len];
    const cmd = std.fmt.allocPrint(alloc, "clumsies init --ws-id {s}", .{id}) catch return;
    defer alloc.free(cmd);
    spawnClipboardCopy(alloc, cmd);
}

fn writeErrorMessage(self: anytype, message: []const u8) void {
    writeFixedBuf(&self.create_ws_error_buf, &self.create_ws_error_len, message);
}

fn writeFixedBuf(buf: []u8, len: *usize, src: []const u8) void {
    const n = @min(buf.len, src.len);
    @memcpy(buf[0..n], src[0..n]);
    len.* = n;
}

fn spawnClipboardCopy(alloc: std.mem.Allocator, text: []const u8) void {
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
    const footer = if (self.create_ws_phase == .submitting)
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
        self.create_ws_name_buf[0..self.create_ws_name_len],
        label_w,
    );
    if (self.create_ws_focus == .name) w.writeCursorMarker(&surface, c0 - 1, row - 1);
    row += 1;

    row = w.writeKv(
        &surface,
        ctx,
        c0,
        row,
        "Description",
        self.create_ws_desc_buf[0..self.create_ws_desc_len],
        label_w,
    );
    if (self.create_ws_focus == .description) w.writeCursorMarker(&surface, c0 - 1, row - 1);
    row += 1;

    w.writeText(&surface, ctx, c0, row, "Bundle", theme.textOn(bg, theme.MUTED));
    w.writeText(
        &surface,
        ctx,
        c0 + label_w,
        row,
        "(optional) seeds workspace with a prompt set",
        theme.textOn(bg, theme.MUTED),
    );
    row += 1;
    drawCreateBundleList(self, &surface, ctx, c0, row, CREATE_BOX_W - 4, 8, bg);
    row += 9;

    const focused = self.create_ws_focus == .submit;
    const button_label = if (self.create_ws_phase == .submitting)
        "[ Submitting... ]"
    else
        "[ Create Workspace ]";
    const button_style: vaxis.Style = if (focused)
        theme.boldOn(theme.ACCENT, theme.CANVAS)
    else
        theme.boldOn(theme.PANEL_SOFT, theme.TEXT);
    w.writeText(&surface, ctx, c0, row, button_label, button_style);

    if (self.create_ws_error_kind != .none) {
        const err_row = r0 + CREATE_FORM_BOX_H - 4;
        const err_text = self.create_ws_error_buf[0..self.create_ws_error_len];
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

    const list_focused = self.create_ws_focus == .bundle;

    const bundles = bundles_opt orelse {
        w.writeText(surface, ctx, col + 2, row + 1, "(loading bundles...)", theme.textOn(bg, theme.MUTED));
        return;
    };
    if (bundles.len == 0) {
        w.writeText(surface, ctx, col + 2, row + 1, "(no bundles available)", theme.textOn(bg, theme.MUTED));
        return;
    }

    const visible_rows: u16 = height - 2;
    const cursor = self.create_ws_bundle_cursor;
    const scroll_start: usize = if (cursor >= visible_rows) cursor - visible_rows + 1 else 0;
    const end: usize = @min(bundles.len, scroll_start + @as(usize, visible_rows));

    var i: usize = scroll_start;
    while (i < end) : (i += 1) {
        const b = bundles[i];
        const is_cursor = i == cursor;
        const is_selected = self.create_ws_selected_bundle != null and
            self.create_ws_selected_bundle.? == i;
        const marker: []const u8 = if (is_selected) "\xe2\x97\x8f " else "  ";

        const text = std.fmt.allocPrint(
            ctx.arena,
            "{s}{s}  ({d} prompts)",
            .{ marker, b.name, b.prompt_count },
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
    const ws_id = self.create_ws_created_id_buf[0..self.create_ws_created_id_len];
    const ws_name = self.create_ws_created_name_buf[0..self.create_ws_created_name_len];

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
