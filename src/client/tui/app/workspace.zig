const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const w = @import("../widgets.zig");
const data = @import("../view_types.zig");
const api = @import("../api.zig");

const MAX_TREE_ROWS = 128;

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

            if (self.ws_tab == .prompts) {
                if (live_ws) |ws_d| {
                    if (ws_tree.leafIndexAt(r)) |idx| {
                        const wp = ws_d.ws_prompts[idx];
                        const prompt_path = if (wp.path.len > 0)
                            wp.path
                        else for (lib_prompts) |lp| {
                            if (std.mem.eql(u8, lp.content_hash, wp.content_hash)) break lp.path;
                        } else wp.prompt_id;

                        if (hasDraftFor(self, prompt_path)) {
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

fn hasDraftFor(self: anytype, prompt_path: []const u8) bool {
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    const drafts = self.api_state.drafts orelse return false;
    for (drafts) |d| {
        if (!std.mem.eql(u8, d.category, "prompt")) continue;
        if (std.mem.eql(u8, d.status, "merged")) continue;
        if (d.current_path) |cp| {
            if (std.mem.eql(u8, cp, prompt_path)) return true;
        }
        if (std.mem.eql(u8, d.draft_path, prompt_path)) return true;
    }
    return false;
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
            api.fetch.fetchWorkspaceAsync(self.api_state, ws_id);
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
}

pub fn syncWsRows(self: anytype) void {
    self.api_state.mutex.lock();
    const live_ws = self.api_state.ws_detail;
    self.api_state.mutex.unlock();

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
