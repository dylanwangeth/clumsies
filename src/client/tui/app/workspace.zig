const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const w = @import("../widgets.zig");
const data = @import("../view_types.zig");
const api = @import("../api.zig");
const drafts_mod = @import("../../drafts.zig");
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
    context_sel: ?usize,
    prompt_sel_idx: ?usize,
    prompt_sel_path: ?[]const u8,
    context_body: ?[]const u8,
    prompt_body: ?[]const u8,
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
            const style = if (sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
            w.writeText(&surface, ctx, row_col, kv_row, rendered, style);

            if (live_ws) |ws_d| {
                if (ws_tree.leafIndexAt(r)) |idx| {
                    const MarkerInfo = struct {
                        category: drafts_mod.DraftCategory,
                        path: []const u8,
                    };
                    const marker_info: ?MarkerInfo = switch (self.ws_tab) {
                        .context => if (idx < ws_d.context_files.len) MarkerInfo{
                            .category = .context,
                            .path = ws_d.context_files[idx].path,
                        } else null,
                        .prompts => blk: {
                            if (idx >= ws_d.ws_prompts.len) break :blk null;
                            const wp = ws_d.ws_prompts[idx];
                            const prompt_path = if (wp.path.len > 0)
                                wp.path
                            else for (lib_prompts) |lp| {
                                if (std.mem.eql(u8, lp.content_hash, wp.content_hash)) break lp.path;
                            } else wp.prompt_id;
                            break :blk MarkerInfo{ .category = .prompt, .path = prompt_path };
                        },
                    };
                    if (marker_info) |m| {
                        if (self.draftStatusFor(m.category, m.path)) |_| {
                            const nw: u16 = @intCast(ctx.stringWidth(rendered));
                            w.writeText(&surface, ctx, row_col + nw + 1, kv_row, "*", theme.fg(theme.WARN));
                        }
                    }
                }
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
        .context => if (args.dir_sel) |dir| dir else if (args.context_sel) |sel| ws_d.context_files[sel].path else "no files",
        .prompts => if (args.dir_sel) |dir| dir else if (args.prompt_sel_path) |path| path else "no prompts",
    };
    const has_diff = false;
    w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, if (has_diff) theme.WARN else theme.TEXT));
    if (self.ws_show_diff) {
        const tw: u16 = @intCast(ctx.stringWidth(title));
        w.writeText(&surface, ctx, 2 + tw + 2, 0, "diff", theme.boldOn(theme.PANEL, theme.ACCENT));
    }

    var kv_row: u16 = 2;
    const max_row = ctx.max.height.? -| 1;

    switch (self.ws_tab) {
        .context => {
            if (args.dir_sel != null) {
                w.writeText(&surface, ctx, 2, kv_row, "Directory selected.", theme.fg(theme.TEXT_SOFT));
                kv_row += 1;
                if (kv_row < max_row) {
                    w.writeText(&surface, ctx, 2, kv_row, "Enter toggles expansion. Left collapses or jumps to parent. Right expands.", theme.fg(theme.MUTED));
                }
            } else if (args.context_sel) |sel| {
                const f = &ws_d.context_files[sel];
                if (self.ws_show_diff) {
                    w.writeText(&surface, ctx, 2, kv_row, "No diff available", theme.fg(theme.MUTED));
                } else {
                    w.writeText(&surface, ctx, 2, kv_row, f.path, theme.fg(theme.TEXT_SOFT));
                    kv_row += 1;
                    if (kv_row < max_row) {
                        const hash_label = try std.fmt.allocPrint(ctx.arena, "hash: {s}", .{f.hash});
                        w.writeText(&surface, ctx, 2, kv_row, hash_label, theme.fg(theme.MUTED));
                        kv_row += 1;
                    }
                    if (kv_row < max_row and f.author.len > 0) {
                        const author_label = try std.fmt.allocPrint(ctx.arena, "author: {s}", .{f.author});
                        w.writeText(&surface, ctx, 2, kv_row, author_label, theme.fg(theme.MUTED));
                        kv_row += 1;
                    }
                    if (kv_row < max_row and f.updated_at.len > 0) {
                        const updated_label = try std.fmt.allocPrint(ctx.arena, "updated: {s}", .{f.updated_at});
                        w.writeText(&surface, ctx, 2, kv_row, updated_label, theme.fg(theme.MUTED));
                        kv_row += 1;
                    }
                    if (kv_row < max_row) kv_row += 1;
                    if (kv_row < max_row) {
                        if (args.context_body) |body| {
                            drawTextBlock(&surface, ctx, 2, kv_row, max_row, body, theme.textOn(theme.PANEL, theme.TEXT_SOFT));
                        } else {
                            w.writeText(&surface, ctx, 2, kv_row, "Loading context content...", theme.fg(theme.MUTED));
                        }
                    }
                }
            } else {
                w.writeText(&surface, ctx, 2, kv_row, "No context files.", theme.fg(theme.MUTED));
            }
        },
        .prompts => {
            if (args.dir_sel != null) {
                w.writeText(&surface, ctx, 2, kv_row, "Directory selected.", theme.fg(theme.TEXT_SOFT));
                kv_row += 1;
                if (kv_row < max_row) {
                    w.writeText(&surface, ctx, 2, kv_row, "Enter toggles expansion. Left collapses or jumps to parent. Right expands.", theme.fg(theme.MUTED));
                }
            } else if (args.prompt_sel_idx) |prompt_idx| {
                const p = &ws_d.ws_prompts[prompt_idx];
                if (self.ws_show_diff) {
                    w.writeText(&surface, ctx, 2, kv_row, "No diff available", theme.fg(theme.MUTED));
                } else {
                    const prompt_path = args.prompt_sel_path orelse "no prompts";
                    w.writeText(&surface, ctx, 2, kv_row, prompt_path, theme.fg(theme.TEXT_SOFT));
                    kv_row += 1;
                    if (kv_row < max_row) {
                        const hash_label = try std.fmt.allocPrint(ctx.arena, "hash: {s}", .{p.content_hash});
                        w.writeText(&surface, ctx, 2, kv_row, hash_label, theme.fg(theme.MUTED));
                        kv_row += 1;
                    }
                    if (kv_row < max_row) kv_row += 1;
                    if (kv_row < max_row) {
                        if (args.prompt_body) |body| {
                            drawTextBlock(&surface, ctx, 2, kv_row, max_row, body, theme.textOn(theme.PANEL, theme.TEXT_SOFT));
                        } else {
                            w.writeText(&surface, ctx, 2, kv_row, "Loading prompt content...", theme.fg(theme.MUTED));
                        }
                    }
                }
            } else {
                w.writeText(&surface, ctx, 2, kv_row, "No workspace prompts.", theme.fg(theme.MUTED));
            }
        },
    }

    return surface;
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

fn drawTextBlock(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    col: u16,
    start_row: u16,
    max_row: u16,
    text: []const u8,
    style: vaxis.Style,
) void {
    var row = start_row;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (row >= max_row) break;
        w.writeText(surface, ctx, col, row, line, style);
        row += 1;
    }
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

    if (key.matches('h', .{})) {
        self.shiftWsTab(-1);
        self.ws_list_sel = 0;
        self.ws_show_diff = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('l', .{})) {
        self.shiftWsTab(1);
        self.ws_list_sel = 0;
        self.ws_show_diff = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.left, .{})) {
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
    if (key.matches(vaxis.Key.right, .{})) {
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
    if (key.matches('n', .{}) and self.ws_tab == .context) {
        self.openNewDraftForm(.context);
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
