//! Review feature container. Owns pull-request detail, diff, comments, and
//! action state for rule review workflows.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../../theme.zig");
const w = @import("../../widgets.zig");
const api = @import("../../api.zig");
const data = @import("../../models/view_types.zig");
const cursor_mod = @import("../../widgets/cursor.zig");
const drafts_mod = @import("../../../drafts.zig");
const PathTreeState = @import("../../models.zig").path_tree.State(128, 96);

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

pub const ReviewMode = enum { list, detail };

pub const ReviewFocus = enum { filters, queue, detail };

pub const ReviewDetailPane = enum { changes, diff, comments };

pub const PrSort = enum {
    updated,
    created,

    pub fn label(self: PrSort) []const u8 {
        return switch (self) {
            .updated => "updated",
            .created => "created",
        };
    }
};

pub const FilterCursor = struct {
    group_idx: usize = 0,
    chip_idx: usize = 0,
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
    hide_diff: bool = false,
    content_view: w.ContentView,
    mode: ReviewMode = .list,
    focus: ReviewFocus = .queue,
    detail_pane: ReviewDetailPane = .diff,
    filter_cursor: FilterCursor = .{},
    sort: PrSort = .updated,
    pr_filter: PrFilter = .open,
    target_filter: ?data.PrTargetKind = null,
    pr_scroll_bars: vxfw.ScrollBars,
    pr_widgets: [64 * 2]vxfw.Widget = undefined,
    pr_table_rows: [64]w.TableRow = undefined,
    pr_table_cols: [64][5]w.Column = undefined,
    pr_text_rows: [64]vxfw.Text = undefined,
    pr_indices: [64 * 2]?usize = .{null} ** (64 * 2),
    pr_desc_bufs: [64][160]u8 = undefined,
    pr_row_count: usize = 0,
    filtered_pr_count: usize = 0,
    total_pr_count: usize = 0,
    selected_pr_idx: usize = 0,
    changes_tree: PathTreeState = .{},
    changes_machine: w.TreeList.Machine = .{},
    changes_scroll_bars: vxfw.ScrollBars,
    selected_change_idx: usize = 0,
    pr_diff_view: w.ContentView,
    pr_discussion_view: w.ThreadView,
    show_comment_editor: bool = false,
    comment_input_buf: [256]u8 = .{0} ** 256,
    comment_input_len: usize = 0,

    pub fn init() State {
        return .{
            .content_view = w.ContentView.init(),
            .pr_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .changes_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .pr_diff_view = w.ContentView.init(),
            .pr_discussion_view = w.ThreadView.init(),
        };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.changes_tree.deinit(allocator);
        self.changes_machine.deinit(allocator);
    }
};

const embedded_layout: RuleDetailLayout = .{
    .inner_h_pad = 2,
    .inner_w_pad = 4,
    .content_origin_col = 2,
    .content_origin_row = 1,
    .pr_diff_origin_col = 2,
    .pr_diff_origin_row = 2,
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
    w.writeText(&surface, ctx, 2, 1, "No rules loaded.", theme.fg(theme.MUTED));
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
            if (@import("../content_actions.zig").handle(self, ctx, key, .artifact)) return;
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
                    .surface = try self.review.pr_diff_view.buildSurface(ctx.arena, diff_ctx, 0, diff_h),
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
            const title = ruleDetailTitle(self, rule);
            w.writeText(surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
            const meta_min_col: u16 = @intCast(2 + ctx.stringWidth(title) + 2);
            if (selectedArtifactRuleDraftStatus(self)) |status| {
                _ = w.writeHeaderRightIfFits(
                    surface,
                    ctx,
                    0,
                    meta_min_col,
                    w.draftStatusLabel(status),
                    w.draftStatusHeaderStyle(status),
                );
            } else {
                try writeRuleMetaOnPanelChrome(surface, ctx, meta_min_col, rule);
            }
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
            w.writeText(surface, ctx, 2, 1, "No pull requests for this rule.", theme.fg(theme.MUTED));
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
    // Virtual row (local create-op draft not yet submitted) has no
    // hub metadata yet. Its local identity is already shown in the
    // title, so leave the right side empty.
    if (rule.revision == 0 and rule.content_hash.len == 0 and rule.updated.len == 0) {
        return;
    }

    const meta = try formatRuleMeta(ctx.arena, rule);
    _ = w.writeHeaderRightIfFits(surface, ctx, 0, min_col, meta, theme.fg(theme.MUTED));
}

fn ruleDetailTitle(self: anytype, rule: *const data.RuleEntry) []const u8 {
    if (self.lookupRuleId(rule.path)) |rule_id| return rule_id;
    if (isVirtualCreateRule(rule)) return self.draftLocalIdFor(.rule, rule.path) orelse "No rule selected";
    return rule.path;
}

fn isVirtualCreateRule(rule: *const data.RuleEntry) bool {
    return rule.revision == 0 and rule.content_hash.len == 0 and rule.updated.len == 0;
}

fn formatRuleMeta(
    arena: std.mem.Allocator,
    rule: *const data.RuleEntry,
) std.mem.Allocator.Error![]const u8 {
    const updated = try w.formatShortTimestamp(arena, rule.updated);
    if (updated.len == 0) return "";
    return std.fmt.allocPrint(arena, "updated {s}", .{updated});
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
    if (self.review.pr_diff_view.cache_bytes.len == 0 and self.review.pr_diff_view.draft_bytes == null) return;
    try self.review.pr_diff_view.handleEvent(ctx, event);
}

fn nextReviewDetailPane(pane: ReviewDetailPane) ReviewDetailPane {
    return switch (pane) {
        .changes => .diff,
        .diff => .comments,
        .comments => .changes,
    };
}

fn nextReviewDetailPaneForPr(pr: *const data.PullRequestEntry, pane: ReviewDetailPane) ReviewDetailPane {
    if (!isBundleReviewPr(pr)) return nextReviewDetailPane(pane);
    return switch (pane) {
        .changes, .comments => .diff,
        .diff => .comments,
    };
}

fn handleReviewDetailEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    const current_pr = selectedReviewPr(self);
    if (current_pr) |pr| {
        if (isBundleReviewPr(pr) and self.review.detail_pane == .changes) {
            self.review.detail_pane = .diff;
        }
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
        self.review.show_comment_editor = true;
        self.review.comment_input_len = 0;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.tab, .{})) {
        self.review.detail_pane = if (current_pr) |pr|
            nextReviewDetailPaneForPr(pr, self.review.detail_pane)
        else
            nextReviewDetailPane(self.review.detail_pane);
        ctx.consumeAndRedraw();
        return;
    }
    switch (self.review.detail_pane) {
        .changes => {
            try handleReviewChangesEvent(self, ctx, key);
        },
        .diff => {
            if (self.review.pr_diff_view.cache_bytes.len == 0 and self.review.pr_diff_view.draft_bytes == null) return;
            try self.review.pr_diff_view.handleEvent(ctx, event);
        },
        .comments => {
            try self.review.pr_discussion_view.handleEvent(ctx, event);
        },
    }
}

fn selectedReviewPr(self: anytype) ?*const data.PullRequestEntry {
    const prs = self.getReviewPrs();
    if (prs.len == 0) return null;
    return &prs[@min(self.review.selected_pr_idx, prs.len - 1)];
}

fn handleReviewChangesEvent(self: anytype, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!void {
    const row_count = self.review.changes_tree.rowCount();
    if (row_count == 0) {
        ctx.consumeEvent();
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (self.review.changes_machine.toggleDirAtCursor(self.api_state.allocator(), &self.review.changes_tree)) {
            syncSelectedReviewChange(self);
            ctx.consumeAndRedraw();
        }
        return;
    }
    if (key.matches('z', .{})) {
        self.review.changes_machine.toggleAllDirs(self.api_state.allocator(), &self.review.changes_tree);
        syncSelectedReviewChange(self);
        ctx.consumeAndRedraw();
        return;
    }
    const step = w.stepForKey(key, &self.review.changes_scroll_bars.scroll_view) orelse return;
    self.review.changes_machine.cursor = @intCast(self.review.changes_scroll_bars.scroll_view.cursor);
    if (self.review.changes_machine.moveBy(&self.review.changes_tree, step)) {
        self.review.changes_scroll_bars.scroll_view.cursor = @intCast(self.review.changes_machine.cursor);
        w.scrollCursorIntoView(&self.review.changes_scroll_bars.scroll_view, row_count);
        syncSelectedReviewChange(self);
        ctx.consumeAndRedraw();
    }
}

pub fn drawRoot(
    self: anytype,
    ctx: vxfw.DrawContext,
) std.mem.Allocator.Error!vxfw.Surface {
    syncReviewPrWidgets(self);

    const size = ctx.max.size();
    if (self.review.mode == .detail) return drawReviewDetailPanel(self, ctx);

    const filter_w = reviewFilterPanelWidth(size.width);
    const queue_w: u16 = size.width - filter_w -| 1;
    const filter_ctx = ctx.withConstraints(.{ .width = filter_w, .height = size.height }, .{ .width = filter_w, .height = size.height });
    const queue_ctx = ctx.withConstraints(.{ .width = queue_w, .height = size.height }, .{ .width = queue_w, .height = size.height });
    const filter_surface = try drawReviewFilterPanel(self, filter_ctx);
    const queue_surface = try drawReviewListPanel(self, queue_ctx);
    return w.splitHorizontal(ctx, self.widget(), theme.PANEL, filter_surface, queue_surface, filter_w);
}

fn reviewFilterPanelWidth(total_width: u16) u16 {
    if (total_width < 4) return 1;
    if (total_width < 70) return @min(@as(u16, 28), total_width / 2);
    return @min(@as(u16, 34), @max(@as(u16, 28), total_width / 4));
}

fn drawReviewFilterPanel(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(self.review.focus == .filters), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Filters", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 1;
    row = drawFilterGroup(self, &surface, ctx, row, 0, "Status", &status_chips);
    row = drawFilterGroup(self, &surface, ctx, row, 1, "Target", &target_chips);
    _ = drawFilterGroup(self, &surface, ctx, row, 2, "Sort", &sort_chips);
    return surface;
}

const FilterChip = struct {
    label: []const u8,
    status: ?PrFilter = null,
    target: ?data.PrTargetKind = null,
    target_all: bool = false,
    sort: ?PrSort = null,
};

const status_chips = [_]FilterChip{
    .{ .label = "Open", .status = .open },
    .{ .label = "Closed", .status = .closed },
    .{ .label = "All", .status = .all },
};

const target_chips = [_]FilterChip{
    .{ .label = "All", .target_all = true },
    .{ .label = "Context", .target = .context },
    .{ .label = "Rule", .target = .rule },
    .{ .label = "Bundle", .target = .bundle },
    .{ .label = "MPF", .target = .mpf },
};

const sort_chips = [_]FilterChip{
    .{ .label = "Updated", .sort = .updated },
    .{ .label = "Created", .sort = .created },
};

fn chipsForGroup(group_idx: usize) []const FilterChip {
    return switch (group_idx) {
        0 => &status_chips,
        1 => &target_chips,
        else => &sort_chips,
    };
}

fn drawFilterGroup(
    self: anytype,
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    start_row: u16,
    group_idx: usize,
    title: []const u8,
    chips: []const FilterChip,
) u16 {
    var row = start_row;
    w.writeText(surface, ctx, 2, row, title, theme.fgBold(theme.TEXT_SOFT));
    row += 1;
    var col: u16 = 2;
    const max_w: u16 = surface.size.width -| 4;
    for (chips, 0..) |chip, chip_idx| {
        const label_w: u16 = @intCast(ctx.stringWidth(chip.label));
        const chip_w = label_w + 4;
        if (col > 2 and col + chip_w > max_w + 2) {
            row += 1;
            col = 2;
        }
        const focused = self.review.focus == .filters and self.review.filter_cursor.group_idx == group_idx and self.review.filter_cursor.chip_idx == chip_idx;
        const selected = chipSelected(self, chip);
        const style = chipStyle(selected, focused);
        const text = std.fmt.allocPrint(ctx.arena, "[ {s} ]", .{chip.label}) catch chip.label;
        w.writeText(surface, ctx, col, row, text, style);
        col += chip_w + 1;
    }
    return row + 1;
}

fn chipWrapRowCount(width: u16, labels: []const []const u8) u16 {
    if (labels.len == 0) return 0;
    const max_w = @max(@as(u16, 1), width);
    var rows: u16 = 1;
    var col: u16 = 0;
    for (labels) |label| {
        const chip_w: u16 = @intCast(label.len + 4);
        if (col > 0 and col + chip_w > max_w) {
            rows += 1;
            col = 0;
        }
        col += chip_w + 1;
    }
    return rows;
}

fn chipStyle(selected: bool, focused: bool) vaxis.Style {
    if (focused) return theme.boldOn(theme.ACCENT, theme.CANVAS);
    if (selected) return theme.boldOn(theme.PANEL_SOFT, theme.ACCENT_SOFT);
    return theme.textOn(theme.PANEL, theme.TEXT_SOFT);
}

fn chipSelected(self: anytype, chip: FilterChip) bool {
    if (chip.status) |status| return self.review.pr_filter == status;
    if (chip.sort) |sort| return self.review.sort == sort;
    if (chip.target_all) return self.review.target_filter == null;
    if (chip.target) |target| return self.review.target_filter != null and self.review.target_filter.? == target;
    return false;
}

fn drawReviewListPanel(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(self.review.focus == .queue), theme.PANEL);
    const title = if (self.review.filtered_pr_count == self.review.total_pr_count)
        "Review queue"
    else
        std.fmt.allocPrint(ctx.arena, "Review queue {d}/{d}", .{ self.review.filtered_pr_count, self.review.total_pr_count }) catch "Review queue";
    w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));

    const body_origin_row: u16 = 1;
    const body_origin_col: u16 = 2;
    const body_h: u16 = size.height -| body_origin_row -| 1;
    const body_w: u16 = size.width -| body_origin_col -| 1;
    const row_w = body_w -| 1;
    writeReviewQueueColumnHeader(&surface, ctx, body_origin_col, row_w);
    if (self.review.pr_row_count == 0) {
        if (self.api_state.review_prs_pending.isInflight()) return surface;
        const empty = if (self.review.total_pr_count == 0) "No review requests." else "No PRs match current filters.";
        w.writeText(&surface, ctx, body_origin_col, body_origin_row, empty, theme.fg(theme.MUTED));
        return surface;
    }

    const body_ctx = ctx.withConstraints(.{ .width = body_w, .height = body_h }, .{ .width = body_w, .height = body_h });
    const body = try self.review.pr_scroll_bars.widget().draw(body_ctx);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = body_origin_row, .col = body_origin_col }, .surface = body };
    surface.children = children;
    writeReviewCursorBar(&surface, &self.review.pr_scroll_bars.scroll_view, body_origin_row, body_h);
    return surface;
}

fn writeReviewQueueColumnHeader(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    origin_col: u16,
    body_w: u16,
) void {
    const comments_w: u16 = 10;
    const op_w: u16 = 10;
    const status_w: u16 = 8;
    const gap: u16 = 2;
    const comments_col = origin_col + body_w -| comments_w;
    const op_col = comments_col -| gap -| op_w;
    const status_col = op_col -| gap -| status_w;

    writeRightAlignedHeader(surface, ctx, status_col, status_w, "status");
    writeRightAlignedHeader(surface, ctx, op_col, op_w, "operation");
    writeRightAlignedHeader(surface, ctx, comments_col, comments_w, "comments");
}

fn writeRightAlignedHeader(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    col: u16,
    width: u16,
    text: []const u8,
) void {
    const text_w: u16 = @intCast(@min(ctx.stringWidth(text), width));
    const start_col = col + width -| text_w;
    w.writeText(surface, ctx, start_col, 0, text, theme.fg(theme.MUTED));
}

fn drawReviewDetailPanel(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const prs = self.getReviewPrs();
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    if (prs.len == 0) {
        w.drawBorder(&surface, theme.focusBorder(self.review.focus == .detail), theme.PANEL);
        w.writeText(&surface, ctx, 2, 0, "Review", theme.boldOn(theme.PANEL, theme.TEXT));
        w.writeText(&surface, ctx, 2, 1, "Select a pull request to review.", theme.fg(theme.MUTED));
        return surface;
    }

    const pr = &prs[@min(self.review.selected_pr_idx, prs.len - 1)];
    const created_short = w.formatShortTimestamp(ctx.arena, pr.created) catch pr.created;
    const title = pr.id;
    const subtitle = try std.fmt.allocPrint(
        ctx.arena,
        "{s} · {s} · {s}",
        .{ pr.status, pr.author, created_short },
    );

    syncReviewChangeTree(self, ctx, pr);
    syncReviewPrDiffAndComments(self, ctx.arena);
    const body_h: u16 = size.height;
    const body_w: u16 = size.width;
    if (isBundleReviewPr(pr)) {
        return drawBundleReviewDetailPanel(self, ctx, pr, body_w, body_h);
    }

    const widths = reviewDetailPanelWidths(body_w);
    const changes_w = widths.changes;
    const diff_w = widths.diff;
    const comment_w = widths.comments;
    const changes_ctx = ctx.withConstraints(.{ .width = changes_w, .height = body_h }, .{ .width = changes_w, .height = body_h });
    const diff_ctx = ctx.withConstraints(.{ .width = diff_w, .height = body_h }, .{ .width = diff_w, .height = body_h });
    const comment_ctx = ctx.withConstraints(.{ .width = comment_w, .height = body_h }, .{ .width = comment_w, .height = body_h });
    const changes_panel = try drawReviewChangesPanel(self, changes_ctx, pr);
    const diff_title = try selectedReviewChangeTitle(self, ctx.arena, pr, title);
    const diff_subtitle = selectedReviewChangeSubtitle(self, pr, subtitle);
    const diff_panel = try drawReviewDiffPanel(self, diff_ctx, diff_title, diff_subtitle);
    const comment_panel = try drawReviewCommentPanel(self, comment_ctx, pr);

    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = changes_panel };
    children[1] = .{ .origin = .{ .row = 0, .col = @as(i17, @intCast(changes_w + 1)) }, .surface = diff_panel };
    children[2] = .{ .origin = .{ .row = 0, .col = @as(i17, @intCast(changes_w + diff_w + 2)) }, .surface = comment_panel };
    surface.children = children;
    return surface;
}

fn drawBundleReviewDetailPanel(
    self: anytype,
    ctx: vxfw.DrawContext,
    pr: *const data.PullRequestEntry,
    body_w: u16,
    body_h: u16,
) std.mem.Allocator.Error!vxfw.Surface {
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    w.fillSurface(&surface, theme.PANEL);

    const comment_w = reviewCommentPanelWidth(body_w);
    const change_w = body_w -| comment_w -| 1;
    const change_ctx = ctx.withConstraints(.{ .width = change_w, .height = body_h }, .{ .width = change_w, .height = body_h });
    const comment_ctx = ctx.withConstraints(.{ .width = comment_w, .height = body_h }, .{ .width = comment_w, .height = body_h });
    const op_label = bundlePrOpLabel(pr);
    const bundle_title = if (op_label.len > 0)
        try std.fmt.allocPrint(ctx.arena, "Bundle Change · {s}", .{op_label})
    else
        "Bundle Change";
    const change_panel = try drawReviewDiffPanel(self, change_ctx, bundle_title, bundleNameForPr(pr));
    const comment_panel = try drawReviewCommentPanel(self, comment_ctx, pr);

    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = change_panel };
    children[1] = .{ .origin = .{ .row = 0, .col = @as(i17, @intCast(change_w + 1)) }, .surface = comment_panel };
    surface.children = children;
    return surface;
}

pub fn reviewChangesPanelWidth(body_w: u16) u16 {
    if (body_w < 90) return @min(@as(u16, 28), body_w / 3);
    return @min(@as(u16, 36), @max(@as(u16, 28), body_w / 5));
}

pub fn reviewCommentPanelWidth(body_w: u16) u16 {
    if (body_w < 72) return @min(@as(u16, 32), body_w / 3);
    return @min(@as(u16, 52), @max(@as(u16, 40), body_w / 3));
}

pub const ReviewDetailWidths = struct {
    changes: u16,
    diff: u16,
    comments: u16,
};

pub fn reviewDetailPanelWidths(body_w: u16) ReviewDetailWidths {
    if (body_w <= 4) return .{ .changes = 1, .diff = 1, .comments = 1 };
    if (body_w < 72) {
        const changes_w = @max(@as(u16, 1), body_w / 3);
        const remaining = body_w -| changes_w -| 2;
        const comment_w = @max(@as(u16, 1), remaining / 3);
        return .{
            .changes = changes_w,
            .diff = @max(@as(u16, 1), body_w - changes_w -| comment_w -| 2),
            .comments = comment_w,
        };
    }
    var changes_w = reviewChangesPanelWidth(body_w);
    var comment_w = reviewCommentPanelWidth(body_w);
    const min_diff_w: u16 = if (body_w >= 96) 32 else @max(@as(u16, 1), body_w / 4);

    while (changes_w + comment_w + 2 + min_diff_w > body_w and comment_w > 32) {
        comment_w -= 1;
    }
    while (changes_w + comment_w + 2 + min_diff_w > body_w and changes_w > 24) {
        changes_w -= 1;
    }
    const diff_w = body_w - changes_w -| comment_w -| 2;
    return .{
        .changes = @max(@as(u16, 1), changes_w),
        .diff = @max(@as(u16, 1), diff_w),
        .comments = @max(@as(u16, 1), comment_w),
    };
}

fn drawReviewChangesPanel(self: anytype, ctx: vxfw.DrawContext, pr: *const data.PullRequestEntry) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(self.review.detail_pane == .changes), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Changes", theme.boldOn(theme.PANEL, theme.TEXT));
    const header = selectedReviewChangeHeader(self, ctx.arena, pr) catch "";
    if (header.len > 0) {
        _ = w.writeHeaderRightIfFits(&surface, ctx, 0, 12, header, reviewChangeHeaderStyle(self, pr));
    }

    const body_origin_row: u16 = 1;
    const body_origin_col: u16 = 2;
    const body_h: u16 = size.height -| body_origin_row -| 1;
    const body_w: u16 = size.width -| body_origin_col -| 1;
    if (self.review.changes_tree.rowCount() == 0) {
        w.writeText(&surface, ctx, body_origin_col, body_origin_row, "No changes loaded.", theme.fg(theme.MUTED));
        return surface;
    }
    const body_ctx = ctx.withConstraints(.{ .width = body_w, .height = body_h }, .{ .width = body_w, .height = body_h });
    const body = try self.review.changes_scroll_bars.widget().draw(body_ctx);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = body_origin_row, .col = body_origin_col }, .surface = body };
    surface.children = children;
    writeReviewCursorBar(&surface, &self.review.changes_scroll_bars.scroll_view, body_origin_row, body_h);
    return surface;
}

fn reviewChangeHeaderStyle(self: anytype, pr: *const data.PullRequestEntry) vaxis.Style {
    if (selectedReviewChange(pr, self.review.selected_change_idx)) |change| {
        if (change.conflict) return theme.fgBold(theme.DANGER);
    }
    return theme.fg(theme.MUTED);
}

fn drawReviewDiffPanel(
    self: anytype,
    ctx: vxfw.DrawContext,
    title: []const u8,
    subtitle: []const u8,
) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(self.review.detail_pane == .diff), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
    const meta_min_col: u16 = @intCast(2 + ctx.stringWidth(title) + 2);
    if (subtitle.len > 0) {
        _ = w.writeHeaderRightIfFits(&surface, ctx, 0, meta_min_col, subtitle, theme.fg(theme.MUTED));
    }
    if (self.review.pr_diff_view.cache_bytes.len == 0 and self.review.pr_diff_view.draft_bytes == null) {
        w.writeText(&surface, ctx, 2, 1, "No diff loaded.", theme.fg(theme.MUTED));
        return surface;
    }
    const body_origin_row: i17 = 1;
    const body_h = size.height -| @as(u16, @intCast(body_origin_row)) -| 1;
    const body_w = size.width -| 4;
    const body_ctx = ctx.withConstraints(.{ .width = body_w, .height = body_h }, .{ .width = body_w, .height = body_h });
    const body = try self.review.pr_diff_view.buildSurface(ctx.arena, body_ctx, 0, body_h);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = body_origin_row, .col = 2 }, .surface = body };
    surface.children = children;
    return surface;
}

fn drawReviewCommentPanel(self: anytype, ctx: vxfw.DrawContext, pr: *const data.PullRequestEntry) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(self.review.detail_pane == .comments), theme.PANEL);
    const title = try std.fmt.allocPrint(ctx.arena, "Discussion ({d})", .{pr.comments.len});
    w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
    const body_origin_row: i17 = 1;
    const body_h = size.height -| @as(u16, @intCast(body_origin_row)) -| 1;
    const body_w = size.width -| 4;
    const body_ctx = ctx.withConstraints(.{ .width = body_w, .height = body_h }, .{ .width = body_w, .height = body_h });
    try syncReviewDiscussionView(self, ctx.arena, body_ctx, pr, body_w, body_h);
    const body = try self.review.pr_discussion_view.draw(body_ctx);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = body_origin_row, .col = 2 }, .surface = body };
    surface.children = children;
    return surface;
}

fn syncReviewChangeTree(self: anytype, ctx: vxfw.DrawContext, pr: *const data.PullRequestEntry) void {
    const allocator = self.api_state.allocator();
    if (pr.changes.len == 0) {
        self.review.changes_tree.sync(allocator, &.{}, &.{});
        const empty_widgets = ctx.arena.alloc(vxfw.Widget, 0) catch return;
        self.review.changes_scroll_bars.scroll_view.children = .{ .slice = empty_widgets };
        self.review.changes_scroll_bars.estimated_content_height = 0;
        self.review.selected_change_idx = 0;
        return;
    }

    const paths = ctx.arena.alloc([]const u8, pr.changes.len) catch return;
    const indices = ctx.arena.alloc(usize, pr.changes.len) catch return;
    for (pr.changes, 0..) |change, idx| {
        paths[idx] = if (change.path.len > 0)
            change.path
        else
            std.fmt.allocPrint(ctx.arena, "change-{d}", .{idx + 1}) catch "change";
        indices[idx] = idx;
    }
    self.review.changes_tree.sync(allocator, paths, indices);

    const row_count = self.review.changes_tree.rowCount();
    const rows = ctx.arena.alloc(w.TreeList.RowWidget, row_count) catch return;
    const widgets = ctx.arena.alloc(vxfw.Widget, row_count) catch return;
    self.review.changes_machine.cursor = @intCast(self.review.changes_scroll_bars.scroll_view.cursor);
    self.review.changes_machine.sync(&self.review.changes_tree);
    for (0..row_count) |row| {
        const selected = row == self.review.changes_machine.cursor;
        const row_text = self.review.changes_tree.rowText(row);
        if (self.review.changes_tree.dirPathAt(row) != null) {
            rows[row] = .{
                .item = .{
                    .text = row_text,
                    .cursor = selected,
                    .active = true,
                    .style = if (selected)
                        theme.boldOn(theme.PANEL, theme.TEXT)
                    else
                        theme.boldOn(theme.PANEL, theme.TEXT_SOFT),
                },
                .options = .{ .background = theme.PANEL, .text_col = 0, .show_cursor_marker = false },
            };
        } else {
            rows[row] = .{
                .item = .{
                    .text = row_text,
                    .cursor = selected,
                    .style = if (selected)
                        theme.boldOn(theme.PANEL, theme.TEXT)
                    else
                        theme.textOn(theme.PANEL, theme.TEXT_SOFT),
                },
                .options = .{ .background = theme.PANEL, .text_col = 0, .show_cursor_marker = false },
            };
        }
        widgets[row] = rows[row].widget();
    }
    self.review.changes_scroll_bars.scroll_view.children = .{ .slice = widgets };
    self.review.changes_scroll_bars.estimated_content_height = @intCast(row_count);
    self.review.changes_scroll_bars.scroll_view.cursor = @intCast(self.review.changes_machine.cursor);
    syncSelectedReviewChange(self);
}

fn syncSelectedReviewChange(self: anytype) void {
    if (self.review.changes_machine.active_leaf) |idx| {
        if (self.review.selected_change_idx != idx) {
            self.review.selected_change_idx = idx;
            self.review.pr_diff_view.scroll_bars.scroll_view.scroll.top = 0;
        }
    }
}

fn selectedReviewChange(pr: *const data.PullRequestEntry, idx: usize) ?*const data.PrChangeEntry {
    if (pr.changes.len == 0) return null;
    return &pr.changes[@min(idx, pr.changes.len - 1)];
}

fn selectedReviewChangeHeader(self: anytype, arena: std.mem.Allocator, pr: *const data.PullRequestEntry) std.mem.Allocator.Error![]const u8 {
    if (pr.changes.len == 0) return "";
    if (self.review.changes_tree.dirPathAt(self.review.changes_machine.cursor)) |dir| {
        return std.fmt.allocPrint(arena, "{d} changes", .{self.review.changes_tree.leafCountUnderDir(dir)});
    }
    const change = selectedReviewChange(pr, self.review.selected_change_idx) orelse return "";
    if (change.conflict) return std.fmt.allocPrint(arena, "{s} · conflict", .{changeOpLabel(change.op_type)});
    return changeOpLabel(change.op_type);
}

fn selectedReviewChangeTitle(self: anytype, arena: std.mem.Allocator, pr: *const data.PullRequestEntry, fallback: []const u8) std.mem.Allocator.Error![]const u8 {
    const change = selectedReviewChange(pr, self.review.selected_change_idx) orelse return fallback;
    if (change.path.len == 0) return fallback;
    const op_label = if (change.conflict)
        try std.fmt.allocPrint(arena, "{s} · conflict", .{changeOpLabel(change.op_type)})
    else
        changeOpLabel(change.op_type);
    return std.fmt.allocPrint(arena, "{s} · {s}", .{ change.path, op_label });
}

fn selectedReviewChangeSubtitle(self: anytype, pr: *const data.PullRequestEntry, fallback: []const u8) []const u8 {
    const change = selectedReviewChange(pr, self.review.selected_change_idx) orelse return fallback;
    if (change.base_hash.len > 0) return change.base_hash;
    return fallback;
}

fn changeOpLabel(op_type: []const u8) []const u8 {
    if (std.mem.eql(u8, op_type, "modify")) return "update";
    if (std.mem.eql(u8, op_type, "bundle_add")) return "update";
    if (std.mem.eql(u8, op_type, "bundle_remove")) return "update";
    if (std.mem.eql(u8, op_type, "bundle_create")) return "create";
    return op_type;
}

fn writeReviewCursorBar(
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
        .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
        .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
    });
}

pub fn handleModuleEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    switch (self.review.mode) {
        .detail => {
            if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.backspace, .{})) {
                self.review.mode = .list;
                self.review.focus = .queue;
                ctx.consumeAndRedraw();
                return;
            }
            try handleReviewDetailEvent(self, ctx, event, key);
            return;
        },
        .list => {},
    }

    if (key.matches(vaxis.Key.tab, .{})) {
        self.review.focus = if (self.review.focus == .filters) .queue else .filters;
        ctx.consumeAndRedraw();
        return;
    }

    if (self.review.focus == .filters) {
        handleReviewFilterEvent(self, ctx, key);
        return;
    }
    try handleReviewPrListEvent(self, ctx, event, key);
}

pub fn shortcuts(self: anytype) []const w.Shortcut {
    if (self.review.mode == .detail) return &.{
        .{ .key = "Esc", .label = "back" },
        .{ .key = "j/k", .label = "scroll" },
        .{ .key = "Tab", .label = "pane" },
        .{ .key = "a", .label = "accept" },
        .{ .key = "x", .label = "reject" },
        .{ .key = "c", .label = "comment" },
        .{ .key = "q", .label = "quit" },
    };
    if (self.review.focus == .filters) return &.{
        .{ .key = "h/l", .label = "chip" },
        .{ .key = "j/k", .label = "group" },
        .{ .key = "Enter", .label = "select" },
        .{ .key = "x", .label = "clear" },
        .{ .key = "Tab", .label = "queue" },
        .{ .key = "q", .label = "quit" },
    };
    return &.{
        .{ .key = "j/k", .label = "move" },
        .{ .key = "Enter", .label = "open" },
        .{ .key = "Tab", .label = "filters" },
        .{ .key = "q", .label = "quit" },
    };
}

fn handleReviewFilterEvent(self: anytype, ctx: *vxfw.EventContext, key: vaxis.Key) void {
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        moveFilterGroup(&self.review.filter_cursor, 1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        moveFilterGroup(&self.review.filter_cursor, -1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        moveFilterChip(&self.review.filter_cursor, 1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        moveFilterChip(&self.review.filter_cursor, -1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(' ', .{})) {
        applyFocusedFilterChip(self);
        resetReviewSelection(self);
        syncReviewPrWidgets(self);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('x', .{})) {
        clearFocusedFilterFacet(self);
        resetReviewSelection(self);
        syncReviewPrWidgets(self);
        ctx.consumeAndRedraw();
        return;
    }
    ctx.consumeEvent();
}

fn moveFilterGroup(cursor: *FilterCursor, delta: i8) void {
    const group_count: usize = 3;
    const current: i16 = @intCast(cursor.group_idx);
    const next = std.math.clamp(current + delta, 0, @as(i16, @intCast(group_count - 1)));
    cursor.group_idx = @intCast(next);
    cursor.chip_idx = @min(cursor.chip_idx, chipsForGroup(cursor.group_idx).len - 1);
}

fn moveFilterChip(cursor: *FilterCursor, delta: i8) void {
    const chips = chipsForGroup(cursor.group_idx);
    const current: i16 = @intCast(cursor.chip_idx);
    const next = std.math.clamp(current + delta, 0, @as(i16, @intCast(chips.len - 1)));
    cursor.chip_idx = @intCast(next);
}

fn applyFocusedFilterChip(self: anytype) void {
    const chips = chipsForGroup(self.review.filter_cursor.group_idx);
    const chip = chips[@min(self.review.filter_cursor.chip_idx, chips.len - 1)];
    if (chip.status) |status| self.review.pr_filter = status;
    if (chip.sort) |sort| self.review.sort = sort;
    if (chip.target_all) self.review.target_filter = null;
    if (chip.target) |target| self.review.target_filter = target;
}

fn clearFocusedFilterFacet(self: anytype) void {
    switch (self.review.filter_cursor.group_idx) {
        0 => self.review.pr_filter = .open,
        1 => self.review.target_filter = null,
        2 => self.review.sort = .updated,
        else => {},
    }
}

fn resetReviewSelection(self: anytype) void {
    self.review.selected_pr_idx = 0;
    self.review.selected_change_idx = 0;
    self.review.pr_scroll_bars.scroll_view.cursor = 0;
    self.review.changes_scroll_bars.scroll_view.cursor = 0;
    self.review.changes_machine.reset();
    self.review.pr_diff_view.scroll_bars.scroll_view.scroll.top = 0;
    self.review.pr_discussion_view.scroll_bars.scroll_view.scroll.top = 0;
    api.state.resetPrDetailState(self.api_state);
}

fn handleReviewPrListEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
    key: vaxis.Key,
) anyerror!void {
    _ = event;
    syncReviewPrWidgets(self);
    if (self.review.pr_row_count == 0) {
        ctx.consumeEvent();
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        self.review.mode = .detail;
        self.review.focus = .detail;
        const pr = selectedReviewPr(self);
        self.review.detail_pane = if (pr) |p|
            if (isBundleReviewPr(p)) .diff else .changes
        else
            .changes;
        self.review.selected_change_idx = 0;
        self.review.changes_scroll_bars.scroll_view.cursor = 0;
        self.review.changes_machine.reset();
        self.review.pr_diff_view.scroll_bars.scroll_view.scroll.top = 0;
        self.review.pr_discussion_view.scroll_bars.scroll_view.scroll.top = 0;
        fetchSelectedReviewPrDetail(self);
        ctx.consumeAndRedraw();
        return;
    }
    var pos = @as(usize, @intCast(self.review.pr_scroll_bars.scroll_view.cursor));
    if (pos >= self.review.pr_row_count) pos = self.review.pr_row_count - 1;
    const step = w.stepForKey(key, &self.review.pr_scroll_bars.scroll_view) orelse return;
    pos = w.moveSelectableRowByVisualRows(pos, self.review.pr_row_count, self.review.pr_indices[0..self.review.pr_row_count], step);
    self.review.pr_scroll_bars.scroll_view.cursor = @intCast(pos);
    w.scrollCursorIntoView(&self.review.pr_scroll_bars.scroll_view, self.review.pr_row_count);
    if (self.review.pr_indices[pos]) |idx| {
        if (self.review.selected_pr_idx != idx) {
            self.review.selected_pr_idx = idx;
            self.review.selected_change_idx = 0;
            self.review.changes_scroll_bars.scroll_view.cursor = 0;
            self.review.changes_machine.reset();
            api.state.resetPrDetailState(self.api_state);
            fetchSelectedReviewPrDetail(self);
        }
    }
    ctx.consumeAndRedraw();
}

pub fn fetchSelectedPrDetail(self: anytype) void {
    const rules = self.getRules();
    const rule_idx = @min(self.artifact.selected_rule, if (rules.len > 0) rules.len - 1 else 0);
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

pub fn fetchSelectedReviewPrDetail(self: anytype) void {
    const prs = self.getReviewPrs();
    if (prs.len == 0) return;
    const pr = prs[@min(self.review.selected_pr_idx, prs.len - 1)];
    if (self.api_state.pr_detail_cache.shouldDispatch(.{ .value = pr.id })) {
        api.specs.dispatchFromState(
            api.specs.PrIdParams,
            @import("clumsies_lib").protocol.collab_api.RulePrDetailResponse,
            api.specs.pr_detail,
            &self.api_state.pr_detail_pending,
            self.api_state,
            .{ .pr_id = pr.id, .target_kind = pr.target_kind, .ws_id = pr.workspace_id },
        );
    }
    if (self.api_state.pr_comments_cache.shouldDispatch(.{ .value = pr.id })) {
        api.specs.dispatchFromState(
            api.specs.PrIdParams,
            api.specs.PrCommentsPayload,
            api.specs.pr_comments,
            &self.api_state.pr_comments_pending,
            self.api_state,
            .{ .pr_id = pr.id, .target_kind = pr.target_kind, .ws_id = pr.workspace_id },
        );
    }
}

pub fn syncContentWidget(self: anytype) void {
    syncContentWidgetForMode(self, !self.review.hide_diff);
    self.requestSelectedRuleDetail();
}

pub fn syncContentWidgetForMode(self: anytype, show_diff: bool) void {
    const selected_path = selectedArtifactRulePath(self);
    const category = if (selected_path) |path| self.artifactCategoryForPath(path) else .rule;
    const cache_content: []const u8 = if (selected_path) |path|
        self.cachedArtifactRuleBody(category, path) orelse ""
    else
        "";
    const draft_content: ?[]const u8 = if (selected_path) |path| self.draftContentForView(category, path) else null;
    const visible_content = draft_content orelse cache_content;
    if (show_diff) {
        syncContentWidgetBytes(self, cache_content, draft_content);
    } else {
        syncContentWidgetBytes(self, visible_content, null);
    }
}

fn selectedArtifactRulePath(self: anytype) ?[]const u8 {
    const rules = self.getRules();
    // Virtual rows (create-op drafts) land at indices past
    // rules.len and have no server-side entry — their path lives
    // in drafts_create_rule_paths. Without this branch the
    // content panel renders empty for any draft created via `n`.
    if (self.artifact.selected_rule < rules.len) {
        return rules[self.artifact.selected_rule].path;
    }
    const k = self.artifact.selected_rule - rules.len;
    if (k >= self.drafts.create_rule_paths.len) return null;
    return self.drafts.create_rule_paths[k];
}

fn selectedArtifactRuleDraftStatus(self: anytype) ?drafts_mod.DraftStatus {
    const path = selectedArtifactRulePath(self) orelse return null;
    return self.draftStatusFor(self.artifactCategoryForPath(path), path);
}

/// Render the working-copy view for an arbitrary (cache, draft)
/// byte pair into Shell.content_scroll_bars. Shared by the
/// Artifact rule detail pane and the Workspace context / rules
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
/// `path`. The base bytes come from the materialized local cache; the
/// remote body cache is reserved for pull/download flows. Normal mode
/// renders the current working copy as flat text; diff mode compares
/// cached content against the draft. Empty cache bytes are valid for
/// pure create-op drafts with no cache backing.
pub fn syncWsContextContentWidget(
    self: anytype,
    ws_id: []const u8,
    path: []const u8,
    local_path: ?[]const u8,
    remote_hash: ?[]const u8,
    show_diff: bool,
) void {
    _ = remote_hash;
    const cache_path = local_path orelse path;
    const cache_content: []const u8 = self.localWorkspaceContextBody(ws_id, cache_path) orelse "";
    const draft_content: ?[]const u8 = self.draftContentForView(.context, path);
    const visible_content = draft_content orelse cache_content;
    if (show_diff) {
        syncContentWidgetBytes(self, cache_content, draft_content);
    } else {
        syncContentWidgetBytes(self, visible_content, null);
    }
}

/// Workspace-side entrypoint mirroring syncWsContextContentWidget for
/// the Rules tab. Workspace rule bodies come from the materialized
/// local cache; remote artifact bodies are only used for pull/download
/// flows. Normal mode renders the working copy as flat text; diff mode
/// threads both cache and draft bytes into the shared renderer.
pub fn syncWsRuleContentWidget(
    self: anytype,
    path: []const u8,
    local_path: ?[]const u8,
    remote_hash: ?[]const u8,
    show_diff: bool,
) void {
    _ = remote_hash;
    const category = self.artifactCategoryForPath(path);
    const cache_path = local_path orelse path;
    const cache_category = self.artifactCategoryForPath(cache_path);
    const cache_content: []const u8 = self.localArtifactRuleBody(cache_category, cache_path) orelse "";
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
    const sel_idx = @min(self.artifact.selected_rule, all_rules.len - 1);
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
        // of the cursor bar, matching the Artifact file list.
        self.review.pr_table_cols[pi] = .{
            .{ .text = pr.id, .flex = 0 },
            .{ .text = pr.status, .flex = 0 },
            .{ .text = pr.author, .flex = 0 },
            .{ .text = created_short, .flex = 1, .alignment = .right },
            .{ .text = "", .flex = 0 },
            .{ .text = "", .flex = 0 },
        };
        self.review.pr_table_rows[pi] = .{
            .columns = self.review.pr_table_cols[pi][0..4],
            .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT),
            .gap = 2,
            .padding_left = 0,
        };
        self.review.pr_widgets[row_idx] = self.review.pr_table_rows[pi].widget();
        self.review.pr_indices[row_idx] = pi;
        row_idx += 1;
        // Row 2: title + multi-op hint (muted)
        const desc_text: []const u8 = if (pr.operation_count > 1) blk: {
            const buf = &self.review.pr_desc_bufs[pi];
            const written = std.fmt.bufPrint(buf, "{s}  \xc2\xb7 {d} ops", .{ pr.title, pr.operation_count }) catch break :blk pr.title;
            break :blk written;
        } else pr.title;
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
    // Ensure cursor is on a TableRow, not a title row
    var cur = @as(usize, @intCast(self.review.pr_scroll_bars.scroll_view.cursor));
    while (cur < row_idx and self.review.pr_indices[cur] == null) cur += 1;
    self.review.pr_scroll_bars.scroll_view.cursor = @intCast(cur);
    if (cur < row_idx) {
        if (self.review.pr_indices[cur]) |pi| {
            if (self.review.selected_pr_idx != pi) {
                self.review.selected_pr_idx = pi;
                api.state.resetPrDetailState(self.api_state);
            }
        }
    }
    // Kick a detail fetch for the current selection so the diff /
    // title / comment count populate without requiring the
    // user to move the cursor or press Enter. shouldDispatch de-dupes
    // concurrent requests, so this is cheap on re-renders.
    if (row_idx > 0) fetchSelectedPrDetail(self);
}

pub fn syncReviewPrWidgets(self: anytype) void {
    const prs = self.getReviewPrs();
    self.review.total_pr_count = prs.len;
    if (prs.len == 0) {
        self.review.filtered_pr_count = 0;
        self.review.pr_row_count = 0;
        self.review.pr_scroll_bars.scroll_view.children = .{ .slice = self.review.pr_widgets[0..0] };
        self.review.pr_scroll_bars.estimated_content_height = 0;
        return;
    }

    var filtered_indices: [64]usize = undefined;
    var filtered_count: usize = 0;
    for (prs, 0..) |pr, pi| {
        if (filtered_count >= filtered_indices.len) break;
        if (!reviewPrMatchesFilters(self.review.pr_filter, self.review.target_filter, pr)) continue;
        filtered_indices[filtered_count] = pi;
        filtered_count += 1;
    }
    self.review.filtered_pr_count = filtered_count;
    sortReviewPrIndices(prs, filtered_indices[0..filtered_count], self.review.sort);

    var row_idx: usize = 0;
    for (filtered_indices[0..filtered_count]) |pi| {
        const pr = prs[pi];
        if (row_idx + 1 >= self.review.pr_widgets.len) break;
        const sel = pi == self.review.selected_pr_idx;
        const created_short = w.formatShortTimestamp(self.viewAllocator(), pr.created) catch pr.created;
        const status = reviewStatusLabel(pr.status);
        const op_label = reviewOpLabel(self.viewAllocator(), pr) catch "";
        const comments_label = std.fmt.allocPrint(self.viewAllocator(), "{d}", .{pr.comment_count}) catch "";
        const target_label = std.fmt.allocPrint(
            self.viewAllocator(),
            "[{s}]",
            .{pr.target_kind.label()},
        ) catch pr.target_kind.label();
        self.review.pr_table_cols[pi] = .{
            .{ .text = target_label, .flex = 0, .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT), .gap_after = 0 },
            .{ .text = pr.title, .flex = 1, .min_width = 12, .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT) },
            .{ .text = status, .flex = 0, .min_width = 8, .alignment = .right, .style = reviewStatusStyle(pr.status) },
            .{ .text = op_label, .flex = 0, .min_width = 10, .alignment = .right, .style = reviewOpStyle(pr.has_conflict) },
            .{ .text = comments_label, .flex = 0, .min_width = 10, .alignment = .right, .style = reviewCommentsStyle() },
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

        const desc_text = std.fmt.bufPrint(
            &self.review.pr_desc_bufs[pi],
            "{s} · {s} · {s}",
            .{
                pr.target_path,
                pr.author,
                created_short,
            },
        ) catch pr.target_path;
        self.review.pr_text_rows[pi] = .{
            .text = desc_text,
            .style = theme.textOn(theme.PANEL, theme.MUTED),
        };
        self.review.pr_widgets[row_idx] = self.review.pr_text_rows[pi].widget();
        self.review.pr_indices[row_idx] = null;
        row_idx += 1;
    }

    self.review.pr_row_count = row_idx;
    self.review.pr_scroll_bars.scroll_view.children = .{ .slice = self.review.pr_widgets[0..row_idx] };
    self.review.pr_scroll_bars.estimated_content_height = @intCast(row_idx);
    var cur = @as(usize, @intCast(self.review.pr_scroll_bars.scroll_view.cursor));
    while (cur < row_idx and self.review.pr_indices[cur] == null) cur += 1;
    self.review.pr_scroll_bars.scroll_view.cursor = @intCast(cur);
    if (cur < row_idx) {
        if (self.review.pr_indices[cur]) |pi| {
            if (self.review.selected_pr_idx != pi) {
                self.review.selected_pr_idx = pi;
                api.state.resetPrDetailState(self.api_state);
            }
        }
    }
    if (row_idx == 0) {
        self.review.pr_scroll_bars.scroll_view.cursor = 0;
    }
}

fn reviewStatusLabel(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "accepted")) return "merged";
    return status;
}

fn reviewStatusStyle(status: []const u8) vaxis.Style {
    if (std.mem.eql(u8, status, "open")) return theme.fgBold(theme.ACCENT);
    if (std.mem.eql(u8, status, "merged")) return theme.fgBold(theme.MERGED);
    if (std.mem.eql(u8, status, "accepted")) return theme.fgBold(theme.MERGED);
    if (std.mem.eql(u8, status, "rejected")) return theme.fgBold(theme.DANGER);
    return theme.fgBold(theme.MUTED);
}

fn reviewOpStyle(has_conflict: bool) vaxis.Style {
    if (has_conflict) return theme.fgBold(theme.DANGER);
    return theme.fg(theme.TEXT);
}

fn reviewCommentsStyle() vaxis.Style {
    return theme.fg(theme.TEXT);
}

fn reviewOpLabel(allocator: std.mem.Allocator, pr: data.PullRequestEntry) std.mem.Allocator.Error![]const u8 {
    if (pr.has_conflict) return allocator.dupe(u8, "conflict");
    if (pr.target_kind == .bundle) {
        const op_label = reviewBundleOpLabel(pr.op_type);
        if (op_label.len > 0) return allocator.dupe(u8, op_label);
    }
    if (pr.operation_count > 1) {
        return std.fmt.allocPrint(allocator, "{d} ops", .{pr.operation_count});
    }
    if (pr.op_type.len > 0) {
        return allocator.dupe(u8, pr.op_type);
    }
    return "";
}

fn reviewBundleOpLabel(op_type: []const u8) []const u8 {
    if (std.mem.eql(u8, op_type, "bundle_create")) return "create";
    if (std.mem.eql(u8, op_type, "bundle_add")) return "modify";
    if (std.mem.eql(u8, op_type, "bundle_remove")) return "modify";
    return "";
}

fn reviewPrMatchesFilters(
    status_filter: PrFilter,
    target_filter: ?data.PrTargetKind,
    pr: data.PullRequestEntry,
) bool {
    const status_ok = switch (status_filter) {
        .open => std.mem.eql(u8, pr.status, "open"),
        .closed => !std.mem.eql(u8, pr.status, "open"),
        .all => true,
    };
    if (!status_ok) return false;
    if (target_filter) |target| return pr.target_kind == target;
    return true;
}

fn sortReviewPrIndices(prs: []const data.PullRequestEntry, indices: []usize, sort: PrSort) void {
    const Ctx = struct {
        prs: []const data.PullRequestEntry,
        sort: PrSort,

        fn lessThan(ctx: @This(), a_idx: usize, b_idx: usize) bool {
            const a = ctx.prs[a_idx];
            const b = ctx.prs[b_idx];
            _ = ctx.sort;
            return std.mem.order(u8, a.created, b.created) == .gt;
        }
    };
    std.mem.sort(usize, indices, Ctx{ .prs = prs, .sort = sort }, Ctx.lessThan);
}

pub fn syncPrDiffAndComments(self: anytype, allocator: std.mem.Allocator) void {
    const all_rules = self.getRules();
    if (all_rules.len == 0) {
        self.review.pr_diff_view.syncBytes(allocator, "", null);
        return;
    }
    const sel_idx = @min(self.artifact.selected_rule, all_rules.len - 1);
    const p = &all_rules[sel_idx];
    const prs = self.getPrsForRule(p.path);
    if (prs.len == 0) {
        self.review.pr_diff_view.syncBytes(allocator, "", null);
        return;
    }
    const pr_idx = @min(self.review.selected_pr_idx, prs.len - 1);
    const pr = &prs[pr_idx];
    self.review.pr_diff_view.syncBytes(allocator, pr.base_content, pr.proposed_content);
}

pub fn syncReviewPrDiffAndComments(self: anytype, allocator: std.mem.Allocator) void {
    const prs = self.getReviewPrs();
    if (prs.len == 0) {
        self.review.pr_diff_view.syncBytes(allocator, "", null);
        return;
    }
    const pr = &prs[@min(self.review.selected_pr_idx, prs.len - 1)];
    syncReviewDetailRows(self, allocator, pr);
}

fn syncReviewDetailRows(self: anytype, allocator: std.mem.Allocator, pr: *const data.PullRequestEntry) void {
    if (isBundleReviewPr(pr)) {
        const summary = buildBundleReviewSummary(allocator, pr) catch "";
        self.review.pr_diff_view.syncBytes(allocator, summary, null);
        return;
    }
    if (selectedReviewChange(pr, self.review.selected_change_idx)) |change| {
        const proposed = if (change.proposed_content.len > 0 or change.target_kind != .bundle)
            change.proposed_content
        else
            std.fmt.allocPrint(allocator, "bundle: {s}\noperation: {s}\n", .{ change.path, changeOpLabel(change.op_type) }) catch "";
        self.review.pr_diff_view.syncBytes(allocator, change.base_content, proposed);
        return;
    }
    self.review.pr_diff_view.syncBytes(allocator, pr.base_content, pr.proposed_content);
}

fn isBundleReviewPr(pr: *const data.PullRequestEntry) bool {
    if (pr.target_kind == .bundle) return true;
    for (pr.changes) |change| {
        if (change.target_kind == .bundle) return true;
    }
    return false;
}

fn bundleNameForPr(pr: *const data.PullRequestEntry) []const u8 {
    for (pr.changes) |change| {
        if (change.bundle_name.len > 0) return change.bundle_name;
    }
    if (pr.target_path.len > 0) return pr.target_path;
    return pr.title;
}

fn bundlePrOpLabel(pr: *const data.PullRequestEntry) []const u8 {
    var has_create = false;
    var has_add = false;
    var has_remove = false;
    for (pr.changes) |change| {
        if (std.mem.eql(u8, change.op_type, "bundle_create")) has_create = true;
        if (std.mem.eql(u8, change.op_type, "bundle_add")) has_add = true;
        if (std.mem.eql(u8, change.op_type, "bundle_remove")) has_remove = true;
    }
    if (has_create) return "create";
    if (has_add or has_remove) return "update";
    return changeOpLabel(pr.op_type);
}

fn buildBundleReviewSummary(
    allocator: std.mem.Allocator,
    pr: *const data.PullRequestEntry,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "Bundle\n");
    try out.appendSlice(allocator, bundleNameForPr(pr));
    try out.appendSlice(allocator, "\n\n");

    const label = bundlePrOpLabel(pr);
    if (label.len > 0) {
        try out.appendSlice(allocator, "Operation\n");
        try out.appendSlice(allocator, label);
        try out.appendSlice(allocator, "\n\n");
    }

    const add_count = countBundleOps(pr, "bundle_add");
    const remove_count = countBundleOps(pr, "bundle_remove");
    if (std.mem.eql(u8, label, "create")) {
        try appendBundleRuleSection(allocator, &out, "Included rules", pr, "bundle_add", add_count);
    } else {
        try appendBundleRuleSection(allocator, &out, "Added rules", pr, "bundle_add", add_count);
        try out.appendSlice(allocator, "\n");
        try appendBundleRuleSection(allocator, &out, "Removed rules", pr, "bundle_remove", remove_count);
    }
    return out.toOwnedSlice(allocator);
}

fn countBundleOps(pr: *const data.PullRequestEntry, op_type: []const u8) usize {
    var count: usize = 0;
    for (pr.changes) |change| {
        if (std.mem.eql(u8, change.op_type, op_type)) count += 1;
    }
    return count;
}

fn appendBundleRuleSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    title: []const u8,
    pr: *const data.PullRequestEntry,
    op_type: []const u8,
    count: usize,
) std.mem.Allocator.Error!void {
    try out.appendSlice(allocator, title);
    try out.appendSlice(allocator, "\n");
    if (count == 0) {
        try out.appendSlice(allocator, "none\n");
        return;
    }
    for (pr.changes) |change| {
        if (!std.mem.eql(u8, change.op_type, op_type)) continue;
        const rule_path = if (change.rule_path.len > 0) change.rule_path else change.base_hash;
        if (std.mem.eql(u8, op_type, "bundle_remove")) {
            try out.appendSlice(allocator, "- ");
        } else {
            try out.appendSlice(allocator, "+ ");
        }
        try out.appendSlice(allocator, rule_path);
        try out.appendSlice(allocator, "\n");
    }
}

fn syncReviewDiscussionView(
    self: anytype,
    allocator: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    pr: *const data.PullRequestEntry,
    width: u16,
    height: u16,
) std.mem.Allocator.Error!void {
    const items = try allocator.alloc(w.ThreadItem, 1 + pr.comments.len);
    const created_short = w.formatShortTimestamp(allocator, pr.created) catch pr.created;
    items[0] = .{
        .kind = .primary,
        .title = pr.title,
        .meta = try std.fmt.allocPrint(allocator, "{s} · {s}", .{ pr.author, created_short }),
        .body = pr.body,
    };
    for (pr.comments, 0..) |comment, idx| {
        const comment_created = w.formatShortTimestamp(allocator, comment.created) catch comment.created;
        items[idx + 1] = .{
            .kind = .reply,
            .title = comment.author,
            .meta = comment_created,
            .body = comment.body,
        };
    }
    try self.review.pr_discussion_view.syncItems(allocator, ctx, items, width, height);
}

test "review filter predicate handles status and target facets" {
    const testing = std.testing;
    const open_rule = data.PullRequestEntry{
        .id = "pr_1",
        .target_kind = .rule,
        .target_path = "rule/a.md",
        .rule_name = "rule/a.md",
        .status = "open",
        .author = "alice",
        .created = "2026-01-03T00:00:00Z",
        .title = "Update rule",
        .body = "Update rule",
        .base_hash = "",
        .base_content = "",
        .proposed_content = "",
        .attestation_refers = 0,
        .attestation_sessions = 0,
    };
    const closed_context = data.PullRequestEntry{
        .id = "pr_2",
        .target_kind = .context,
        .target_path = "research/a.md",
        .rule_name = "research/a.md",
        .status = "closed",
        .author = "bob",
        .created = "2026-01-02T00:00:00Z",
        .title = "Close context",
        .body = "Close context",
        .base_hash = "",
        .base_content = "",
        .proposed_content = "",
        .attestation_refers = 0,
        .attestation_sessions = 0,
    };
    const bundle = data.PullRequestEntry{
        .id = "pr_3",
        .target_kind = .bundle,
        .target_path = "zig",
        .rule_name = "zig",
        .status = "open",
        .author = "carol",
        .created = "2026-01-04T00:00:00Z",
        .title = "Create bundle",
        .body = "Create bundle",
        .base_hash = "",
        .base_content = "",
        .proposed_content = "",
        .attestation_refers = 0,
        .attestation_sessions = 0,
    };

    try testing.expect(reviewPrMatchesFilters(.open, null, open_rule));
    try testing.expect(!reviewPrMatchesFilters(.closed, null, open_rule));
    try testing.expect(reviewPrMatchesFilters(.all, .rule, open_rule));
    try testing.expect(!reviewPrMatchesFilters(.all, .mpf, open_rule));
    try testing.expect(reviewPrMatchesFilters(.closed, .context, closed_context));
    try testing.expect(reviewPrMatchesFilters(.open, .bundle, bundle));
    try testing.expect(!reviewPrMatchesFilters(.open, .rule, bundle));
}

test "review sort orders newest timestamps first" {
    const testing = std.testing;
    const prs = [_]data.PullRequestEntry{
        .{
            .id = "old",
            .target_kind = .rule,
            .target_path = "a",
            .rule_name = "a",
            .status = "open",
            .author = "alice",
            .created = "2026-01-01T00:00:00Z",
            .title = "old",
            .body = "old",
            .base_hash = "",
            .base_content = "",
            .proposed_content = "",
            .attestation_refers = 0,
            .attestation_sessions = 0,
        },
        .{
            .id = "new",
            .target_kind = .rule,
            .target_path = "b",
            .rule_name = "b",
            .status = "open",
            .author = "alice",
            .created = "2026-01-03T00:00:00Z",
            .title = "new",
            .body = "new",
            .base_hash = "",
            .base_content = "",
            .proposed_content = "",
            .attestation_refers = 0,
            .attestation_sessions = 0,
        },
        .{
            .id = "mid",
            .target_kind = .rule,
            .target_path = "c",
            .rule_name = "c",
            .status = "open",
            .author = "alice",
            .created = "2026-01-02T00:00:00Z",
            .title = "mid",
            .body = "mid",
            .base_hash = "",
            .base_content = "",
            .proposed_content = "",
            .attestation_refers = 0,
            .attestation_sessions = 0,
        },
    };
    var indices = [_]usize{ 0, 1, 2 };
    sortReviewPrIndices(&prs, &indices, .updated);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, &indices);
}

test "review chips wrap for narrow and medium widths" {
    const testing = std.testing;
    const labels = [_][]const u8{ "All", "Context", "Rule", "Bundle", "MPF" };
    try testing.expectEqual(@as(u16, 5), chipWrapRowCount(10, &labels));
    try testing.expectEqual(@as(u16, 3), chipWrapRowCount(22, &labels));
}

test "review labels normalize terminal state and op display" {
    const testing = std.testing;
    try testing.expectEqualStrings("merged", reviewStatusLabel("accepted"));
    try testing.expectEqualStrings("merged", reviewStatusLabel("merged"));
    const rename = data.PullRequestEntry{
        .id = "pr",
        .target_kind = .context,
        .target_path = "a",
        .rule_name = "a",
        .status = "open",
        .author = "alice",
        .created = "2026-01-01T00:00:00Z",
        .title = "rename",
        .body = "rename",
        .base_hash = "",
        .base_content = "",
        .proposed_content = "",
        .attestation_refers = 0,
        .attestation_sessions = 0,
        .operation_count = 1,
        .op_type = "rename",
    };
    const label = try reviewOpLabel(testing.allocator, rename);
    defer testing.allocator.free(label);
    try testing.expectEqualStrings("rename", label);

    const bundle_create = data.PullRequestEntry{
        .id = "pr",
        .target_kind = .bundle,
        .target_path = "zig",
        .rule_name = "zig",
        .status = "open",
        .author = "alice",
        .created = "2026-01-01T00:00:00Z",
        .title = "create bundle",
        .body = "create bundle",
        .base_hash = "",
        .base_content = "",
        .proposed_content = "",
        .attestation_refers = 0,
        .attestation_sessions = 0,
        .operation_count = 22,
        .op_type = "bundle_create",
    };
    const bundle_label = try reviewOpLabel(testing.allocator, bundle_create);
    defer testing.allocator.free(bundle_label);
    try testing.expectEqualStrings("create", bundle_label);

    const bundle_add = data.PullRequestEntry{
        .id = "pr",
        .target_kind = .bundle,
        .target_path = "zig",
        .rule_name = "zig",
        .status = "open",
        .author = "alice",
        .created = "2026-01-01T00:00:00Z",
        .title = "add to bundle",
        .body = "add to bundle",
        .base_hash = "",
        .base_content = "",
        .proposed_content = "",
        .attestation_refers = 0,
        .attestation_sessions = 0,
        .operation_count = 3,
        .op_type = "bundle_add",
    };
    const bundle_add_label = try reviewOpLabel(testing.allocator, bundle_add);
    defer testing.allocator.free(bundle_add_label);
    try testing.expectEqualStrings("modify", bundle_add_label);
}

test "review filter cursor navigation clamps across groups and chips" {
    const testing = std.testing;
    var cursor = FilterCursor{};
    moveFilterChip(&cursor, 10);
    try testing.expectEqual(@as(usize, 2), cursor.chip_idx);
    moveFilterGroup(&cursor, 1);
    try testing.expectEqual(@as(usize, 1), cursor.group_idx);
    try testing.expectEqual(@as(usize, 2), cursor.chip_idx);
    moveFilterChip(&cursor, 10);
    try testing.expectEqual(@as(usize, 4), cursor.chip_idx);
    moveFilterGroup(&cursor, 1);
    try testing.expectEqual(@as(usize, 2), cursor.group_idx);
    try testing.expectEqual(@as(usize, 1), cursor.chip_idx);
    moveFilterGroup(&cursor, -10);
    try testing.expectEqual(@as(usize, 0), cursor.group_idx);
    try testing.expectEqual(@as(usize, 1), cursor.chip_idx);
}
