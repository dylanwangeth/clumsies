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

pub fn drawPromptTable(
    self: anytype,
    ctx: vxfw.DrawContext,
    bundle_label: []const u8,
    prompt_count: usize,
) std.mem.Allocator.Error!vxfw.Surface {
    self.library_scroll_bars.scroll_view.draw_cursor = false;
    defer self.library_scroll_bars.scroll_view.draw_cursor = true;

    const subtitle = try std.fmt.allocPrint(
        ctx.arena,
        "{d} prompts  bundle: {s}  / search  b filter",
        .{ prompt_count, bundle_label },
    );
    const list_border = w.focusBorder(!self.detail_focus_content);
    const panel: w.Panel = .{
        .owner = self.widget(),
        .title = "Library",
        .subtitle = subtitle,
        .background = theme.PANEL,
        .border_color = list_border,
        .child = self.library_scroll_bars.widget(),
        .padding = .{ .left = 1 },
    };
    var surface = try panel.draw(ctx);
    if (self.library_tree.rowCount() == 0) {
        const status = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            break :blk self.api_state.status;
        };
        w.drawEmptyState(&surface, ctx, 2, 2, status, "prompts");
        return surface;
    }
    return w.applyCursorOverlay(ctx, &surface, &self.library_scroll_bars.scroll_view, theme.PANEL);
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
    if (key.matches('b', .{})) {
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
    if (key.matches(vaxis.Key.tab, .{})) {
        self.detail_focus_content = !self.detail_focus_content;
        ctx.consumeAndRedraw();
        return;
    }

    if (self.detail_focus_content) {
        try prompt_detail_panel.handleEmbeddedPaneEvent(self, ctx, event, key);
        return;
    }
    try handleListPaneEvent(self, ctx, event, key);
}

fn handleListPaneEvent(
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
            self.show_pr_diff = false;
            self.show_comment_editor = false;
            self.selected_pr_idx = 0;
            self.pr_scroll_bars.scroll_view.cursor = 0;
            self.pr_filter = .open;
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
