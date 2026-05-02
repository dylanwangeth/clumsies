//! Review feature container. Owns pull-request detail, diff, comments, and
//! action state for rule review workflows.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../../theme.zig");
const w = @import("../../widgets.zig");
const api = @import("../../api.zig");
const data = @import("../../models/view_types.zig");
const diff_viewer = @import("../../widgets/diff_viewer.zig");

const RuleDetailLayout = struct {
    inner_h_pad: u16,
    inner_w_pad: u16,
    content_origin_col: i17,
    content_origin_row: i17,
    pr_diff_origin_col: i17,
    pr_diff_origin_row: i17,
};

pub const PrFilter = enum {
    open,
    all,
    closed,

    pub fn label(self: PrFilter) []const u8 {
        return switch (self) {
            .open => "open",
            .all => "all",
            .closed => "closed",
        };
    }

    pub fn next(self: PrFilter) PrFilter {
        return switch (self) {
            .open => .all,
            .all => .closed,
            .closed => .open,
        };
    }
};

pub const DetailTab = enum(u8) {
    content,
    pull_requests,

    pub fn label(self: DetailTab) []const u8 {
        return switch (self) {
            .content => "Content",
            .pull_requests => "Pull Requests",
        };
    }
};

pub const detail_tabs = [_]DetailTab{ .content, .pull_requests };

pub const State = struct {
    detail_tab: DetailTab = .content,
    detail_focus_content: bool = false,
    content_view: w.ContentView,
    pr_filter: PrFilter = .open,
    pr_scroll_bars: vxfw.ScrollBars,
    pr_widgets: [64 * 2]vxfw.Widget = undefined,
    pr_table_rows: [64]w.TableRow = undefined,
    pr_table_cols: [64][4]w.Column = undefined,
    pr_text_rows: [64]vxfw.Text = undefined,
    pr_indices: [64 * 2]?usize = .{null} ** (64 * 2),
    pr_desc_bufs: [64][160]u8 = undefined,
    pr_row_count: usize = 0,
    selected_pr_idx: usize = 0,
    pr_diff_scroll_bars: vxfw.ScrollBars,
    pr_diff_widgets: [32]vxfw.Widget = undefined,
    pr_diff_rows: [32]vxfw.Text = undefined,
    pr_diff_count: usize = 0,
    show_comment_editor: bool = false,
    comment_input_buf: [256]u8 = .{0} ** 256,
    comment_input_len: usize = 0,

    pub fn init() State {
        return .{
            .content_view = w.ContentView.init(),
            .pr_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .pr_diff_scroll_bars = w.initPlainScrollBars(theme.PANEL, 2),
        };
    }
};

const embedded_layout: RuleDetailLayout = .{
    .inner_h_pad = 2,
    .inner_w_pad = 4,
    .content_origin_col = 2,
    .content_origin_row = 1,
    .pr_diff_origin_col = 2,
    .pr_diff_origin_row = 3,
};

const DetailBody = union(enum) {
    content: vxfw.Surface,
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
    const border_color = theme.focusBorder(self.review.detail_focus_content);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Detail", theme.boldOn(theme.PANEL, theme.TEXT));
    w.writeText(&surface, ctx, 2, 2, "No rules loaded.", theme.fg(theme.MUTED));
    return surface;
}

pub fn drawEmbedded(
    self: anytype,
    ctx: vxfw.DrawContext,
    rule: *const data.RuleEntry,
) std.mem.Allocator.Error!vxfw.Surface {
    const body = try buildRuleDetailBody(self, ctx, rule, embedded_layout);

    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    const border_color = theme.focusBorder(self.review.detail_focus_content);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, border_color, theme.PANEL);
    try fillRuleDetailSurface(self, &surface, ctx, rule, embedded_layout, body);
    return surface;
}

pub fn handleEmbeddedPaneEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    if (key.matches(vaxis.Key.escape, .{})) {
        self.review.detail_focus_content = false;
        ctx.consumeAndRedraw();
        return;
    }
    switch (self.review.detail_tab) {
        .content => {
            if (key.matches('y', .{})) {
                if (self.copySelectedContentId()) {
                    ctx.consumeAndRedraw();
                } else {
                    self.notifyOp(.warning, "No id to copy.");
                    ctx.consumeAndRedraw();
                }
                return;
            }
            if (key.matches('e', .{})) {
                self.editSelectedDraft();
                ctx.consumeAndRedraw();
                return;
            }
            if (key.matches('D', .{}) or key.matches('d', .{ .shift = true })) {
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
            try self.review.content_view.handleEvent(ctx, event);
        },
        .pull_requests => try handlePrDiffEvent(self, ctx, event, key),
    }
}

fn buildRuleContentSurface(
    self: anytype,
    ctx: vxfw.DrawContext,
    width_pad: u16,
    child_height: u16,
) std.mem.Allocator.Error!vxfw.Surface {
    syncContentWidget(self);
    return buildContentSurface(self, ctx, width_pad, child_height);
}

fn buildRuleDetailBody(
    self: anytype,
    ctx: vxfw.DrawContext,
    rule: *const data.RuleEntry,
    layout: RuleDetailLayout,
) std.mem.Allocator.Error!DetailBody {
    switch (self.review.detail_tab) {
        .content => {
            return .{
                .content = try buildRuleContentSurface(self, ctx, layout.inner_w_pad, ctx.max.height.? -| 2),
            };
        },
        .pull_requests => {
            const prs = self.getPrsForRule(rule.path);
            if (prs.len == 0) return .pull_request_empty;

            const inner_h = ctx.max.height.? -| layout.inner_h_pad;
            const inner_w = ctx.max.width.? -| layout.inner_w_pad;

            const pr_idx = @min(self.review.selected_pr_idx, prs.len - 1);
            const pr = &prs[pr_idx];
            // Title matches design/04 drill-down layout:
            // "{pr_id} ─ {rule_path} ─ {status} ─ {author} ─ {created}"
            // Dropped `refer:N` — it's not in the design.
            const created_short = w.formatShortTimestamp(ctx.arena, pr.created) catch pr.created;
            const title = try std.fmt.allocPrint(
                ctx.arena,
                "{s} ─ {s} ─ {s} ─ {s} ─ {s}",
                .{ pr.id, pr.rule_name, pr.status, pr.author, created_short },
            );
            const op_line = try buildPrSubtitle(ctx.arena, pr);

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
                    .surface = try self.review.pr_diff_scroll_bars.widget().draw(diff_ctx),
                },
            };
        },
    }
}

/// Compose the PR drill-down subtitle in the design/04 shape:
/// "{op_desc}   base: sha256:abc…   comments: N". When the operation
/// metadata has not been populated yet (detail fetch in flight),
/// fall back to just the base_hash + comments segment so the bar
/// still conveys review-context even with op fields empty.
fn buildPrSubtitle(
    arena: std.mem.Allocator,
    pr: *const data.PullRequestEntry,
) std.mem.Allocator.Error![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    if (pr.operation_count > 0) {
        try parts.append(arena, try opDescriptor(arena, pr));
    }
    if (pr.base_hash.len > 0) {
        try parts.append(arena, try std.fmt.allocPrint(arena, "base: {s}", .{shortHash(pr.base_hash)}));
    }
    try parts.append(arena, try std.fmt.allocPrint(arena, "comments: {d}", .{pr.comments.len}));
    return std.mem.join(arena, "   ", parts.items);
}

fn opDescriptor(
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

/// Trim a "sha256:HEX…" hash to the first 7 hex chars, matching the
/// workspace panel header convention (see workspace.zig::hashBadge).
fn shortHash(raw: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, raw, ':');
    const start = if (colon) |c| c + 1 else 0;
    const slice = raw[start..];
    return slice[0..@min(7, slice.len)];
}

fn fillRuleDetailSurface(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    rule: *const data.RuleEntry,
    layout: RuleDetailLayout,
    body: DetailBody,
) std.mem.Allocator.Error!void {
    switch (body) {
        .content => |content_surface| {
            const title = self.lookupRuleId(rule.path) orelse "(new)";
            w.writeText(surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
            try writeRuleMetaOnPanelChrome(surface, ctx, @intCast(2 + ctx.stringWidth(title) + 2), rule);
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
            w.writeText(surface, ctx, 2, 0, "Pull Requests", theme.boldOn(theme.PANEL, theme.TEXT));
            w.writeText(surface, ctx, 2, 2, "No pull requests for this rule.", theme.fg(theme.MUTED));
        },
        .pull_request_diff => |diff| {
            w.writeText(surface, ctx, 2, 0, diff.title, theme.boldOn(theme.PANEL, theme.TEXT));
            if (diff.op_line) |line| {
                w.writeText(surface, ctx, 2, 1, line, theme.fg(theme.TEXT_SOFT));
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
    }
}

fn writeRuleMetaOnPanelChrome(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    min_col: u16,
    rule: *const data.RuleEntry,
) std.mem.Allocator.Error!void {
    // Virtual row (local create-op draft not yet submitted) has
    // zero revision / prs / constraints / updated. Rendering
    // `rev0 pr0 c0` would be technically accurate but misleading
    // beside a file that is genuinely new. Show `(new)` instead,
    // mirroring the workspace context panel convention.
    if (rule.revision == 0 and rule.content_hash.len == 0 and rule.updated.len == 0) {
        _ = w.writeHeaderRightIfFits(surface, ctx, 0, min_col, "(new)", theme.fg(theme.ACCENT));
        return;
    }

    const full = try formatRuleMeta(ctx.arena, rule, true);
    if (w.writeHeaderRightIfFits(surface, ctx, 0, min_col, full, theme.fg(theme.MUTED))) return;

    const compact = try formatRuleMeta(ctx.arena, rule, false);
    _ = w.writeHeaderRightIfFits(surface, ctx, 0, min_col, compact, theme.fg(theme.MUTED));
}

fn formatRuleMeta(
    arena: std.mem.Allocator,
    rule: *const data.RuleEntry,
    include_updated: bool,
) std.mem.Allocator.Error![]const u8 {
    if (!include_updated) {
        return std.fmt.allocPrint(
            arena,
            "rev{d} pr{d} c{d}",
            .{ rule.revision, rule.open_pr_count, rule.constraint_count },
        );
    }
    const updated = try w.formatShortTimestamp(arena, rule.updated);
    if (updated.len == 0) {
        return std.fmt.allocPrint(
            arena,
            "rev{d} pr{d} c{d}",
            .{ rule.revision, rule.open_pr_count, rule.constraint_count },
        );
    }
    return std.fmt.allocPrint(
        arena,
        "rev{d} pr{d} c{d} {s}",
        .{ rule.revision, rule.open_pr_count, rule.constraint_count, updated },
    );
}

fn handlePrDiffEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
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
        self.review.show_comment_editor = true;
        self.review.comment_input_len = 0;
        ctx.consumeAndRedraw();
        return;
    }
    if (self.review.pr_diff_count == 0) return;
    try self.review.pr_diff_scroll_bars.scroll_view.handleEvent(ctx, event);
}

pub fn fetchSelectedPrDetail(self: anytype) void {
    const rules = self.getRules();
    const rule_idx = @min(self.library.selected_rule, if (rules.len > 0) rules.len - 1 else 0);
    if (rules.len == 0) return;

    const prs = self.getPrsForRule(rules[rule_idx].path);
    const pr_idx = @min(self.review.selected_pr_idx, if (prs.len > 0) prs.len - 1 else 0);
    if (prs.len == 0) return;

    const pr_id = prs[pr_idx].id;
    if (self.api_state.pr_detail_cache.shouldDispatch(.{ .value = pr_id })) {
        api.specs.dispatchFromState(
            api.specs.PrIdParams,
            @import("clumsies_lib").protocol.collab_api.RulePrDetailResponse,
            api.specs.pr_detail,
            &self.api_state.pr_detail_pending,
            self.api_state,
            .{ .pr_id = pr_id },
        );
    }
    if (self.api_state.pr_comments_cache.shouldDispatch(.{ .value = pr_id })) {
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

pub fn syncContentWidget(self: anytype) void {
    const rules = self.getRules();
    // Virtual rows (create-op drafts) land at indices past
    // rules.len and have no server-side entry — their path lives
    // in drafts_create_rule_paths. Without this branch the
    // content panel renders empty for any draft created via `n`.
    const selected_path: ?[]const u8 = if (self.library.selected_rule < rules.len)
        rules[self.library.selected_rule].path
    else blk: {
        const k = self.library.selected_rule - rules.len;
        if (k >= self.drafts.create_rule_paths.len) break :blk null;
        break :blk self.drafts.create_rule_paths[k];
    };
    const category = if (selected_path) |path| self.libraryCategoryForPath(path) else .rule;
    const cache_content: []const u8 = if (selected_path) |path|
        self.cachedLibraryRuleBody(category, path) orelse ""
    else
        "";
    const draft_content: ?[]const u8 = if (selected_path) |path| self.draftContentForView(category, path) else null;
    syncContentWidgetBytes(self, cache_content, draft_content);
    self.requestSelectedRuleDetail();
}

/// Render the working-copy view for an arbitrary (cache, draft)
/// byte pair into Shell.content_scroll_bars. Shared by the
/// Library rule detail pane and the Workspace context / rules
/// content panes so both surfaces scroll identically and use the
/// same DiffViewer gutter formatter. When draft_content is null the
/// cache bytes are rendered flat (no diff symbols); otherwise we
/// compute an inline gutter against the cache.
pub fn syncContentWidgetBytes(
    self: anytype,
    cache_content: []const u8,
    draft_content: ?[]const u8,
) void {
    self.review.content_view.syncBytes(self.viewAllocator(), cache_content, draft_content);
}

/// Workspace-side entrypoint: render a workspace context file at
/// `path`. Pulls cache bytes from the ws_context_content cache and
/// overlays the local context draft if one exists. Normal mode renders
/// the current working copy as flat text; diff mode compares cached
/// content against the draft. Empty cache bytes are valid for pure
/// create-op drafts with no cache backing.
pub fn syncWsContextContentWidget(
    self: anytype,
    ws_id: []const u8,
    path: []const u8,
    show_diff: bool,
) void {
    const cache_content: []const u8 = self.cachedWorkspaceContextBody(ws_id, path) orelse "";
    const draft_content: ?[]const u8 = self.draftContentForView(.context, path);
    const visible_content = draft_content orelse cache_content;
    if (show_diff) {
        syncContentWidgetBytes(self, cache_content, draft_content);
    } else {
        syncContentWidgetBytes(self, visible_content, null);
    }
}

/// Workspace-side entrypoint mirroring syncWsContextContentWidget for
/// the Rules tab. Workspace rule bodies come from the same org-wide
/// rule_content cache that Library reads, but the draft overlay is
/// keyed by rule path. Normal mode renders the working copy as flat
/// text; diff mode threads both cache and draft bytes into the shared
/// renderer.
pub fn syncWsRuleContentWidget(
    self: anytype,
    path: []const u8,
    show_diff: bool,
) void {
    const category = self.libraryCategoryForPath(path);
    const cache_content: []const u8 = self.cachedLibraryRuleBody(category, path) orelse "";
    const draft_content: ?[]const u8 = self.draftContentForView(category, path);
    const visible_content = draft_content orelse cache_content;
    if (show_diff) {
        syncContentWidgetBytes(self, cache_content, draft_content);
    } else {
        syncContentWidgetBytes(self, visible_content, null);
    }
}

/// Build the scrollable content surface against the current
/// Shell.content_scroll_bars state. Call syncContentWidgetBytes
/// before this (or another `sync*` variant) so the scroll view's
/// children slice is populated. Layout params match
/// buildRuleContentSurface's contract.
pub fn buildContentSurface(
    self: anytype,
    ctx: vxfw.DrawContext,
    width_pad: u16,
    child_height: u16,
) std.mem.Allocator.Error!vxfw.Surface {
    return self.review.content_view.buildSurface(self.viewAllocator(), ctx, width_pad, child_height);
}

pub fn syncPrWidgets(self: anytype) void {
    const all_rules = self.getRules();
    if (all_rules.len == 0) {
        self.review.pr_row_count = 0;
        self.review.pr_scroll_bars.scroll_view.children = .{ .slice = self.review.pr_widgets[0..0] };
        self.review.pr_scroll_bars.estimated_content_height = 0;
        return;
    }
    const sel_idx = @min(self.library.selected_rule, all_rules.len - 1);
    const p = &all_rules[sel_idx];
    const prs = self.getPrsForRule(p.path);
    const view_alloc = self.viewAllocator();
    var row_idx: usize = 0;
    for (prs, 0..) |pr, pi| {
        if (row_idx + 1 >= self.review.pr_widgets.len) break;
        const show = switch (self.review.pr_filter) {
            .open => std.mem.eql(u8, pr.status, "open"),
            .closed => !std.mem.eql(u8, pr.status, "open"),
            .all => true,
        };
        if (!show) continue;
        const sel = pi == self.review.selected_pr_idx;
        const created_short = w.formatShortTimestamp(view_alloc, pr.created) catch pr.created;
        // Row 1: id, status, author, created. padding_left = 0 so
        // the first cell of the row sits immediately to the right
        // of the cursor bar, matching the Library file list.
        self.review.pr_table_cols[pi] = .{
            .{ .text = pr.id, .flex = 0 },
            .{ .text = pr.status, .flex = 0 },
            .{ .text = pr.author, .flex = 0 },
            .{ .text = created_short, .flex = 1, .alignment = .right },
        };
        self.review.pr_table_rows[pi] = .{
            .columns = &self.review.pr_table_cols[pi],
            .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT),
            .gap = 2,
            .padding_left = 0,
        };
        self.review.pr_widgets[row_idx] = self.review.pr_table_rows[pi].widget();
        self.review.pr_indices[row_idx] = pi;
        row_idx += 1;
        // Row 2: description + multi-op hint (muted)
        const desc_text: []const u8 = if (pr.operation_count > 1) blk: {
            const buf = &self.review.pr_desc_bufs[pi];
            const written = std.fmt.bufPrint(buf, "{s}  \xc2\xb7 {d} ops", .{ pr.description, pr.operation_count }) catch break :blk pr.description;
            break :blk written;
        } else pr.description;
        self.review.pr_text_rows[pi] = .{
            .text = desc_text,
            .style = theme.textOn(theme.PANEL, theme.MUTED),
        };
        self.review.pr_widgets[row_idx] = self.review.pr_text_rows[pi].widget();
        self.review.pr_indices[row_idx] = null; // skip on cursor
        row_idx += 1;
    }
    self.review.pr_row_count = row_idx;
    self.review.pr_scroll_bars.scroll_view.children = .{ .slice = self.review.pr_widgets[0..row_idx] };
    self.review.pr_scroll_bars.estimated_content_height = @intCast(row_idx);
    // Ensure cursor is on a TableRow, not a description
    var cur = @as(usize, @intCast(self.review.pr_scroll_bars.scroll_view.cursor));
    while (cur < row_idx and self.review.pr_indices[cur] == null) cur += 1;
    self.review.pr_scroll_bars.scroll_view.cursor = @intCast(cur);
    if (cur < row_idx) {
        if (self.review.pr_indices[cur]) |pi| self.review.selected_pr_idx = pi;
    }
    // Kick a detail fetch for the current selection so the diff /
    // description / comment count populate without requiring the
    // user to move the cursor or press Enter. shouldDispatch de-dupes
    // concurrent requests, so this is cheap on re-renders.
    if (row_idx > 0) fetchSelectedPrDetail(self);
}

pub fn syncPrDiffAndComments(self: anytype, allocator: std.mem.Allocator) void {
    const all_rules = self.getRules();
    if (all_rules.len == 0) {
        self.review.pr_diff_count = 0;
        return;
    }
    const sel_idx = @min(self.library.selected_rule, all_rules.len - 1);
    const p = &all_rules[sel_idx];
    const prs = self.getPrsForRule(p.path);
    if (prs.len == 0) {
        self.review.pr_diff_count = 0;
        return;
    }
    const pr_idx = @min(self.review.selected_pr_idx, prs.len - 1);
    const pr = &prs[pr_idx];
    var count: usize = 0;
    for (pr.diff) |line| {
        if (count >= self.review.pr_diff_rows.len) break;
        self.review.pr_diff_rows[count] = .{
            .text = line,
            .style = diff_viewer.styleLine(line),
        };
        self.review.pr_diff_widgets[count] = self.review.pr_diff_rows[count].widget();
        count += 1;
    }
    // Comment section
    if (pr.comments.len > 0) {
        if (count < self.review.pr_diff_rows.len) {
            self.review.pr_diff_rows[count] = .{
                .text = "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 Comments \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80",
                .style = theme.fg(theme.MUTED),
            };
            self.review.pr_diff_widgets[count] = self.review.pr_diff_rows[count].widget();
            count += 1;
        }
        for (pr.comments) |comment| {
            // Header: "author · created". Timestamp is compacted
            // through the shared formatter so comment rows match PR
            // list + rule panel timestamp layout.
            if (count < self.review.pr_diff_rows.len) {
                const created_short = w.formatShortTimestamp(allocator, comment.created) catch comment.created;
                const header = std.fmt.allocPrint(allocator, "{s} \xc2\xb7 {s}", .{ comment.author, created_short }) catch "??";
                self.review.pr_diff_rows[count] = .{
                    .text = header,
                    .style = theme.fgBold(theme.TEXT_SOFT),
                };
                self.review.pr_diff_widgets[count] = self.review.pr_diff_rows[count].widget();
                count += 1;
            }
            // Body
            if (count < self.review.pr_diff_rows.len) {
                self.review.pr_diff_rows[count] = .{
                    .text = comment.body,
                    .style = theme.fg(theme.TEXT_SOFT),
                };
                self.review.pr_diff_widgets[count] = self.review.pr_diff_rows[count].widget();
                count += 1;
            }
            // Blank line for spacing
            if (count < self.review.pr_diff_rows.len) {
                self.review.pr_diff_rows[count] = .{
                    .text = " ",
                    .style = theme.fg(theme.MUTED),
                };
                self.review.pr_diff_widgets[count] = self.review.pr_diff_rows[count].widget();
                count += 1;
            }
        }
    }
    self.review.pr_diff_count = count;
    self.review.pr_diff_scroll_bars.scroll_view.children = .{ .slice = self.review.pr_diff_widgets[0..count] };
    self.review.pr_diff_scroll_bars.estimated_content_height = @intCast(count);
}
