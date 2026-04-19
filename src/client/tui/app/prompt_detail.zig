const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const w = @import("../widgets.zig");
const api = @import("../api.zig");
const data = @import("../view_types.zig");

const PromptDetailLayout = struct {
    inner_h_pad: u16,
    inner_w_pad: u16,
    content_origin_col: i17,
    content_origin_row: i17,
    pr_list_origin_col: i17,
    pr_list_origin_row: i17,
    pr_diff_origin_col: i17,
    pr_diff_origin_row: i17,
};

const library_detail_layout: PromptDetailLayout = .{
    .inner_h_pad = 2,
    .inner_w_pad = 4,
    .content_origin_col = 2,
    .content_origin_row = 2,
    .pr_list_origin_col = 1,
    .pr_list_origin_row = 2,
    .pr_diff_origin_col = 2,
    .pr_diff_origin_row = 4,
};

const info_detail_layout: PromptDetailLayout = .{
    .inner_h_pad = 3,
    .inner_w_pad = 2,
    .content_origin_col = 2,
    .content_origin_row = 2,
    .pr_list_origin_col = 1,
    .pr_list_origin_row = 2,
    .pr_diff_origin_col = 2,
    .pr_diff_origin_row = 4,
};

const DetailBody = union(enum) {
    content: vxfw.Surface,
    pull_request_list: vxfw.Surface,
    pull_request_diff: struct {
        title: []const u8,
        op_line: ?[]const u8,
        surface: vxfw.Surface,
    },
    pull_request_empty,
};

pub fn drawEmbeddedEmpty(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    const border_color = w.focusBorder(self.detail_focus_content);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Detail", theme.boldOn(theme.PANEL, theme.TEXT));
    w.writeText(&surface, ctx, 2, 2, "No prompts loaded.", theme.fg(theme.MUTED));
    return surface;
}

pub fn drawEmbedded(
    self: anytype,
    ctx: vxfw.DrawContext,
    prompt: *const data.PromptEntry,
) std.mem.Allocator.Error!vxfw.Surface {
    const body = try buildPromptDetailBody(self, ctx, prompt, library_detail_layout, true);

    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    const border_color = w.focusBorder(self.detail_focus_content);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);
    try fillPromptDetailSurface(self, &surface, ctx, prompt, library_detail_layout, body);
    return surface;
}

pub fn drawRoot(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    const prompts = self.getPrompts();
    const sel_idx = @min(self.selected_prompt, if (prompts.len > 0) prompts.len - 1 else 0);
    if (prompts.len == 0) {
        return drawRootEmpty(self, ctx);
    }
    const prompt = &prompts[sel_idx];

    const size = ctx.max.size();
    const info_w: u16 = size.width / 3;
    const content_w: u16 = size.width - info_w - 1;

    const info_ctx = ctx.withConstraints(
        .{ .width = info_w, .height = size.height },
        .{ .width = info_w, .height = size.height },
    );
    const content_ctx = ctx.withConstraints(
        .{ .width = content_w, .height = size.height },
        .{ .width = content_w, .height = size.height },
    );
    const info_surface = try drawInfoPane(self, info_ctx, prompt);
    const content_surface = try drawContentPane(self, content_ctx, prompt);
    return drawRootSplit(self, ctx, info_surface, content_surface);
}

pub fn handleOverlayEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    if (key.matches(vaxis.Key.tab, .{})) {
        self.detail_focus_content = !self.detail_focus_content;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('p', .{})) {
        self.status_line = "Create PR (not yet implemented)";
        ctx.consumeAndRedraw();
        return;
    }

    if (self.detail_focus_content) {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.show_detail = false;
            self.detail_focus_content = false;
            self.selected_module = self.detail_origin;
            ctx.consumeAndRedraw();
            return;
        }
        try self.content_scroll_bars.scroll_view.handleEvent(ctx, event);
        return;
    }
    if (key.matches(vaxis.Key.escape, .{}) and !(self.detail_tab == .pull_requests and self.show_pr_diff)) {
        self.show_detail = false;
        self.detail_focus_content = false;
        self.selected_module = self.detail_origin;
        ctx.consumeAndRedraw();
        return;
    }
    try handleDetailBodyEvent(self, ctx, event, key, true);
}

pub fn handleEmbeddedPaneEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    if (self.detail_tab == .pull_requests and self.show_pr_diff) {
        try handlePrDiffEvent(self, ctx, event, key);
        return;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        self.detail_focus_content = false;
        ctx.consumeAndRedraw();
        return;
    }
    try handleDetailBodyEvent(self, ctx, event, key, false);
}

fn drawRootEmpty(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    w.fillSurface(&root, theme.PANEL);
    w.writeText(&root, ctx, 2, 1, "No prompts loaded.", theme.fg(theme.MUTED));
    return root;
}

fn drawRootSplit(
    self: anytype,
    ctx: vxfw.DrawContext,
    info_surface: vxfw.Surface,
    content_surface: vxfw.Surface,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.PANEL);

    const info_w: u16 = size.width / 3;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = info_surface };
    children[1] = .{ .origin = .{ .row = 0, .col = info_w + 1 }, .surface = content_surface };
    root.children = children;
    return root;
}

fn drawInfoPane(
    self: anytype,
    ctx: vxfw.DrawContext,
    prompt: *const data.PromptEntry,
) std.mem.Allocator.Error!vxfw.Surface {
    const body = try buildPromptDetailBody(self, ctx, prompt, info_detail_layout, false);

    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    w.fillSurface(&surface, theme.PANEL);
    const info_border = w.focusBorder(!self.detail_focus_content);
    w.drawBorder(&surface, info_border, theme.PANEL);
    try fillPromptDetailSurface(self, &surface, ctx, prompt, info_detail_layout, body);
    return surface;
}

fn drawContentPane(
    self: anytype,
    ctx: vxfw.DrawContext,
    prompt: *const data.PromptEntry,
) std.mem.Allocator.Error!vxfw.Surface {
    const content_surface = try buildPromptContentSurface(self, ctx, 4, ctx.max.height.? -| 2);

    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    w.fillSurface(&surface, theme.PANEL);
    const border_color = w.focusBorder(self.detail_focus_content);
    w.drawBorder(&surface, border_color, theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, prompt.path, theme.boldOn(theme.PANEL, theme.TEXT));

    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = 1, .col = 2 }, .surface = content_surface };
    surface.children = children;
    return surface;
}

fn buildPromptContentSurface(
    self: anytype,
    ctx: vxfw.DrawContext,
    width_pad: u16,
    child_height: u16,
) std.mem.Allocator.Error!vxfw.Surface {
    syncContentWidget(self);
    const inner_w = ctx.max.width.? -| width_pad;
    const child_ctx = ctx.withConstraints(
        .{ .width = inner_w, .height = child_height },
        .{ .width = inner_w, .height = child_height },
    );
    return self.content_scroll_bars.widget().draw(child_ctx);
}

fn buildPromptDetailBody(
    self: anytype,
    ctx: vxfw.DrawContext,
    prompt: *const data.PromptEntry,
    layout: PromptDetailLayout,
    show_operation_header: bool,
) std.mem.Allocator.Error!DetailBody {
    switch (self.detail_tab) {
        .content => {
            return .{
                .content = try buildPromptContentSurface(self, ctx, layout.inner_w_pad, ctx.max.height.? -| 3),
            };
        },
        .pull_requests => {
            const prs = self.getPrsForPrompt(prompt.path);
            if (prs.len == 0) return .pull_request_empty;

            const inner_h = ctx.max.height.? -| layout.inner_h_pad;
            const inner_w = ctx.max.width.? -| layout.inner_w_pad;

            if (self.show_pr_diff) {
                const pr_idx = @min(self.selected_pr_idx, prs.len - 1);
                const pr = &prs[pr_idx];
                const title = try std.fmt.allocPrint(
                    ctx.arena,
                    "{s} ─ {s} ─ {s} ─ {s} ─ refer:{d}",
                    .{ pr.id, pr.prompt_name, pr.author, pr.status, pr.trace_refers },
                );
                const op_line = if (show_operation_header and pr.operation_count > 0)
                    try opHeaderLine(ctx.arena, pr)
                else
                    null;

                syncPrDiffAndComments(self, ctx.arena);
                const diff_h = inner_h -| 2;
                const diff_ctx = ctx.withConstraints(
                    .{ .width = inner_w, .height = diff_h },
                    .{ .width = inner_w, .height = diff_h },
                );
                return .{
                    .pull_request_diff = .{
                        .title = title,
                        .op_line = op_line,
                        .surface = try self.pr_diff_scroll_bars.widget().draw(diff_ctx),
                    },
                };
            }

            syncPrWidgets(self);
            const list_ctx = ctx.withConstraints(
                .{ .width = inner_w, .height = inner_h },
                .{ .width = inner_w, .height = inner_h },
            );
            return .{
                .pull_request_list = try drawPrList(self, list_ctx),
            };
        },
    }
}

fn drawPrList(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    self.pr_scroll_bars.scroll_view.draw_cursor = false;
    defer self.pr_scroll_bars.scroll_view.draw_cursor = true;

    var list_surface = try self.pr_scroll_bars.widget().draw(ctx);
    const sv = &self.pr_scroll_bars.scroll_view;
    if (sv.cursor >= sv.scroll.top) {
        const vis_row = sv.cursor - sv.scroll.top;
        const crow: i17 = @intCast(vis_row);
        if (crow < list_surface.size.height) {
            const cbuf = try ctx.arena.alloc(vaxis.Cell, 1);
            cbuf[0] = .{
                .char = .{ .grapheme = "▌", .width = 1 },
                .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
            };
            const csurface: vxfw.Surface = .{
                .size = .{ .width = 1, .height = 1 },
                .widget = list_surface.widget,
                .buffer = cbuf,
                .children = &.{},
            };
            const old = list_surface.children;
            const new_children = try ctx.arena.alloc(vxfw.SubSurface, old.len + 1);
            @memcpy(new_children[0..old.len], old);
            new_children[old.len] = .{
                .origin = .{ .col = 0, .row = crow },
                .surface = csurface,
                .z_index = 1,
            };
            list_surface.children = new_children;
        }
    }
    return list_surface;
}

fn opHeaderLine(
    arena: std.mem.Allocator,
    pr: *const data.PullRequestEntry,
) std.mem.Allocator.Error![]const u8 {
    const position = if (pr.operation_count > 1)
        try std.fmt.allocPrint(arena, "op {d}/{d}", .{ pr.op_index + 1, pr.operation_count })
    else
        "op";
    if (pr.op_type.len == 0) return position;
    if (std.mem.eql(u8, pr.op_type, "rename")) {
        return std.fmt.allocPrint(
            arena,
            "{s}: rename {s} → {s}",
            .{ position, pr.op_current_path, pr.op_new_path },
        );
    }
    const target = if (pr.op_current_path.len > 0) pr.op_current_path else pr.op_new_path;
    return std.fmt.allocPrint(arena, "{s}: {s} {s}", .{ position, pr.op_type, target });
}

fn fillPromptDetailSurface(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    prompt: *const data.PromptEntry,
    layout: PromptDetailLayout,
    body: DetailBody,
) std.mem.Allocator.Error!void {
    var tab_col: u16 = 2;
    const detail_tabs = [_]@TypeOf(self.detail_tab){ .content, .pull_requests };
    for (detail_tabs) |tab| {
        tab_col = w.drawInnerTabBadge(surface, ctx, 0, tab_col, detailTabLabel(tab), tab == self.detail_tab);
        tab_col +|= 1;
    }
    if (self.detail_tab == .pull_requests) {
        w.writeRightText(surface, ctx, 0, "f filter", theme.textOn(theme.PANEL, theme.MUTED));
    } else if (self.detail_tab == .content) {
        try writePromptMetaOnPanelChrome(surface, ctx, tab_col, prompt);
    }

    switch (body) {
        .content => |content_surface| {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{
                    .row = layout.content_origin_row,
                    .col = layout.content_origin_col,
                },
                .surface = content_surface,
            };
            surface.children = children;
        },
        .pull_request_empty => {
            w.writeText(surface, ctx, 2, 2, "No pull requests for this prompt.", theme.fg(theme.MUTED));
        },
        .pull_request_diff => |diff| {
            w.writeText(surface, ctx, 2, 2, diff.title, theme.boldOn(theme.PANEL, theme.TEXT));
            if (diff.op_line) |line| {
                w.writeText(surface, ctx, 2, 3, line, theme.fg(theme.TEXT_SOFT));
            }

            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{
                    .row = layout.pr_diff_origin_row,
                    .col = layout.pr_diff_origin_col,
                },
                .surface = diff.surface,
            };
            surface.children = children;
        },
        .pull_request_list => |list_surface| {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{
                    .row = layout.pr_list_origin_row,
                    .col = layout.pr_list_origin_col,
                },
                .surface = list_surface,
            };
            surface.children = children;
        },
    }
}

fn detailTabLabel(tab: anytype) []const u8 {
    return switch (tab) {
        .content => "Content",
        .pull_requests => "Pull Requests",
    };
}

fn writePromptMetaOnPanelChrome(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    min_col: u16,
    prompt: *const data.PromptEntry,
) std.mem.Allocator.Error!void {
    const full = try formatPromptMeta(ctx.arena, prompt, true);
    if (writeHeaderRightIfFits(surface, ctx, 0, min_col, full, theme.fg(theme.MUTED))) return;

    const compact = try formatPromptMeta(ctx.arena, prompt, false);
    _ = writeHeaderRightIfFits(surface, ctx, 0, min_col, compact, theme.fg(theme.MUTED));
}

fn formatPromptMeta(
    arena: std.mem.Allocator,
    prompt: *const data.PromptEntry,
    include_updated: bool,
) std.mem.Allocator.Error![]const u8 {
    if (!include_updated) {
        return std.fmt.allocPrint(
            arena,
            "rev{d} pr{d} c{d}",
            .{ prompt.revision, prompt.open_pr_count, prompt.constraint_count },
        );
    }
    const updated = try compactPromptUpdated(arena, prompt.updated);
    if (updated.len == 0) {
        return std.fmt.allocPrint(
            arena,
            "rev{d} pr{d} c{d}",
            .{ prompt.revision, prompt.open_pr_count, prompt.constraint_count },
        );
    }
    return std.fmt.allocPrint(
        arena,
        "rev{d} pr{d} c{d} {s}",
        .{ prompt.revision, prompt.open_pr_count, prompt.constraint_count, updated },
    );
}

fn compactPromptUpdated(
    arena: std.mem.Allocator,
    raw: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len < 10) return arena.dupe(u8, trimmed);
    if (trimmed.len >= 16 and (trimmed[10] == 'T' or trimmed[10] == ' ')) {
        return std.fmt.allocPrint(arena, "{s} {s}", .{ trimmed[0..10], trimmed[11..16] });
    }
    return arena.dupe(u8, trimmed[0..10]);
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

fn handleDetailBodyEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
    fetch_pr_detail_on_enter: bool,
) anyerror!void {
    if (self.detail_tab == .pull_requests and self.show_pr_diff) {
        try handlePrDiffEvent(self, ctx, event, key);
        return;
    }

    if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        self.shiftDetailTab(-1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        self.shiftDetailTab(1);
        ctx.consumeAndRedraw();
        return;
    }

    if (self.detail_tab == .content) {
        try self.content_scroll_bars.scroll_view.handleEvent(ctx, event);
        return;
    }

    if (self.detail_tab == .pull_requests) {
        if (key.matches('f', .{})) {
            self.pr_filter = nextPrFilter(self.pr_filter);
            self.pr_scroll_bars.scroll_view.cursor = 0;
            self.selected_pr_idx = 0;
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.show_pr_diff = true;
            if (fetch_pr_detail_on_enter) fetchSelectedPrDetail(self);
            ctx.consumeAndRedraw();
            return;
        }

        syncPrWidgets(self);
        if (self.pr_row_count == 0) return;

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
                self.selected_pr_idx = pr_idx;
            }
        }
    }
}

fn handlePrDiffEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    if (key.matches(vaxis.Key.escape, .{})) {
        self.show_pr_diff = false;
        self.show_comment_editor = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('a', .{})) {
        self.doPrAction("accept");
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('x', .{})) {
        self.doPrAction("reject");
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('c', .{})) {
        self.show_comment_editor = true;
        self.comment_input_len = 0;
        ctx.consumeAndRedraw();
        return;
    }
    if (self.pr_diff_count == 0) return;
    try self.pr_diff_scroll_bars.scroll_view.handleEvent(ctx, event);
}

fn fetchSelectedPrDetail(self: anytype) void {
    const prompts = self.getPrompts();
    const prompt_idx = @min(self.selected_prompt, if (prompts.len > 0) prompts.len - 1 else 0);
    if (prompts.len == 0) return;

    const prs = self.getPrsForPrompt(prompts[prompt_idx].path);
    const pr_idx = @min(self.selected_pr_idx, if (prs.len > 0) prs.len - 1 else 0);
    if (prs.len == 0) return;

    const pr_id = prs[pr_idx].id;
    if (self.api_state.pr_detail_cache.lookup(.{ .value = pr_id }) == null) {
        api.specs.dispatchFromState(
            api.specs.PrIdParams,
            @import("clumsies_lib").protocol.collab_api.PromptPrDetailResponse,
            api.specs.pr_detail,
            &self.api_state.pr_detail_pending,
            self.api_state,
            .{ .pr_id = pr_id },
        );
    }
    if (self.api_state.pr_comments_cache.lookup(.{ .value = pr_id }) == null) {
        api.specs.dispatchFromState(
            api.specs.PrIdParams,
            api.specs.PrCommentsPayload,
            api.specs.pr_comments,
            &self.api_state.pr_comments_pending,
            self.api_state,
            .{ .pr_id = pr_id },
        );
    }
}

fn nextPrFilter(filter: anytype) @TypeOf(filter) {
    return switch (filter) {
        .open => .all,
        .all => .closed,
        .closed => .open,
    };
}

pub fn syncContentWidget(self: anytype) void {
    const prompts = self.getPrompts();
    const selected_path: ?[]const u8 = if (self.selected_prompt < prompts.len) prompts[self.selected_prompt].path else null;
    const content = if (selected_path) |path| self.cachedPromptBody(path) orelse "" else "";
    self.content_text = .{
        .text = content,
        .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT),
    };
    self.content_widget[0] = self.content_text.widget();
    self.content_scroll_bars.scroll_view.children = .{ .slice = self.content_widget[0..1] };
    self.content_scroll_bars.estimated_content_height = @intCast(@max(w.countLines(content), 24));

    self.requestSelectedPromptDetail();
}

pub fn syncPrWidgets(self: anytype) void {
    const all_prompts = self.getPrompts();
    if (all_prompts.len == 0) {
        self.pr_row_count = 0;
        self.pr_scroll_bars.scroll_view.children = .{ .slice = self.pr_widgets[0..0] };
        self.pr_scroll_bars.estimated_content_height = 0;
        return;
    }
    const sel_idx = @min(self.selected_prompt, all_prompts.len - 1);
    const p = &all_prompts[sel_idx];
    const prs = self.getPrsForPrompt(p.path);
    var row_idx: usize = 0;
    for (prs, 0..) |pr, pi| {
        if (row_idx + 1 >= self.pr_widgets.len) break;
        const show = switch (self.pr_filter) {
            .open => std.mem.eql(u8, pr.status, "open"),
            .closed => !std.mem.eql(u8, pr.status, "open"),
            .all => true,
        };
        if (!show) continue;
        const sel = pi == self.selected_pr_idx;
        // Row 1: id, status, author, created
        self.pr_table_cols[pi] = .{
            .{ .text = pr.id, .flex = 0 },
            .{ .text = pr.status, .flex = 0 },
            .{ .text = pr.author, .flex = 0 },
            .{ .text = pr.created, .flex = 1, .alignment = .right },
        };
        self.pr_table_rows[pi] = .{
            .columns = &self.pr_table_cols[pi],
            .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT),
            .gap = 2,
        };
        self.pr_widgets[row_idx] = self.pr_table_rows[pi].widget();
        self.pr_indices[row_idx] = pi;
        row_idx += 1;
        // Row 2: description + multi-op hint (muted)
        const desc_text: []const u8 = if (pr.operation_count > 1) blk: {
            const buf = &self.pr_desc_bufs[pi];
            const written = std.fmt.bufPrint(buf, "{s}  \xc2\xb7 {d} ops", .{ pr.description, pr.operation_count }) catch break :blk pr.description;
            break :blk written;
        } else pr.description;
        self.pr_text_rows[pi] = .{
            .text = desc_text,
            .style = theme.textOn(theme.PANEL, theme.MUTED),
        };
        self.pr_widgets[row_idx] = self.pr_text_rows[pi].widget();
        self.pr_indices[row_idx] = null; // skip on cursor
        row_idx += 1;
    }
    self.pr_row_count = row_idx;
    self.pr_scroll_bars.scroll_view.children = .{ .slice = self.pr_widgets[0..row_idx] };
    self.pr_scroll_bars.estimated_content_height = @intCast(row_idx);
    // Ensure cursor is on a TableRow, not a description
    var cur = @as(usize, @intCast(self.pr_scroll_bars.scroll_view.cursor));
    while (cur < row_idx and self.pr_indices[cur] == null) cur += 1;
    self.pr_scroll_bars.scroll_view.cursor = @intCast(cur);
    if (cur < row_idx) {
        if (self.pr_indices[cur]) |pi| self.selected_pr_idx = pi;
    }
}

pub fn syncPrDiffAndComments(self: anytype, allocator: std.mem.Allocator) void {
    const all_prompts = self.getPrompts();
    if (all_prompts.len == 0) {
        self.pr_diff_count = 0;
        return;
    }
    const sel_idx = @min(self.selected_prompt, all_prompts.len - 1);
    const p = &all_prompts[sel_idx];
    const prs = self.getPrsForPrompt(p.path);
    if (prs.len == 0) {
        self.pr_diff_count = 0;
        return;
    }
    const pr_idx = @min(self.selected_pr_idx, prs.len - 1);
    const pr = &prs[pr_idx];
    var count: usize = 0;
    for (pr.diff) |line| {
        if (count >= self.pr_diff_rows.len) break;
        self.pr_diff_rows[count] = .{
            .text = line,
            .style = .{ .fg = diffFg(line), .bg = diffBg(line) },
        };
        self.pr_diff_widgets[count] = self.pr_diff_rows[count].widget();
        count += 1;
    }
    // Comment section
    if (pr.comments.len > 0) {
        if (count < self.pr_diff_rows.len) {
            self.pr_diff_rows[count] = .{
                .text = "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 Comments \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80",
                .style = theme.fg(theme.MUTED),
            };
            self.pr_diff_widgets[count] = self.pr_diff_rows[count].widget();
            count += 1;
        }
        for (pr.comments) |comment| {
            // Header: "author · created"
            if (count < self.pr_diff_rows.len) {
                const header = std.fmt.allocPrint(allocator, "{s} \xc2\xb7 {s}", .{ comment.author, comment.created }) catch "??";
                self.pr_diff_rows[count] = .{
                    .text = header,
                    .style = theme.fgBold(theme.TEXT_SOFT),
                };
                self.pr_diff_widgets[count] = self.pr_diff_rows[count].widget();
                count += 1;
            }
            // Body
            if (count < self.pr_diff_rows.len) {
                self.pr_diff_rows[count] = .{
                    .text = comment.body,
                    .style = theme.fg(theme.TEXT_SOFT),
                };
                self.pr_diff_widgets[count] = self.pr_diff_rows[count].widget();
                count += 1;
            }
            // Blank line for spacing
            if (count < self.pr_diff_rows.len) {
                self.pr_diff_rows[count] = .{
                    .text = " ",
                    .style = theme.fg(theme.MUTED),
                };
                self.pr_diff_widgets[count] = self.pr_diff_rows[count].widget();
                count += 1;
            }
        }
    }
    self.pr_diff_count = count;
    self.pr_diff_scroll_bars.scroll_view.children = .{ .slice = self.pr_diff_widgets[0..count] };
    self.pr_diff_scroll_bars.estimated_content_height = @intCast(count);
}

fn diffBg(line: []const u8) vaxis.Color {
    if (std.mem.startsWith(u8, line, "+")) return theme.rgb(0x1d2617);
    if (std.mem.startsWith(u8, line, "-")) return theme.rgb(0x2a1b18);
    return theme.PANEL;
}

fn diffFg(line: []const u8) vaxis.Color {
    if (std.mem.startsWith(u8, line, "+")) return theme.OK;
    if (std.mem.startsWith(u8, line, "-")) return theme.DANGER;
    if (std.mem.startsWith(u8, line, "@@")) return theme.INFO;
    return theme.TEXT_SOFT;
}
