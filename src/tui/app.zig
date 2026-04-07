const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("theme.zig");
const w = @import("widgets.zig");
const data = @import("mock_data.zig");
const TableRow = @import("table_row.zig").TableRow;
const Column = @import("table_row.zig").Column;

const WsTab = enum(u8) {
    prompts,
    context,
    overrides,

    fn label(self: WsTab) []const u8 {
        return switch (self) {
            .prompts => "Prompts",
            .context => "Context",
            .overrides => "Overrides",
        };
    }
};

const ws_tabs = [_]WsTab{ .prompts, .context, .overrides };

const Period = enum(u8) {
    daily,
    weekly,
    monthly,

    fn label(self: Period) []const u8 {
        return switch (self) {
            .daily => "daily",
            .weekly => "weekly",
            .monthly => "monthly",
        };
    }

    fn next(self: Period) Period {
        return switch (self) {
            .daily => .weekly,
            .weekly => .monthly,
            .monthly => .daily,
        };
    }
};

const SettingsTab = enum(u8) {
    members,
    bundles,
    workspaces,
    token,

    fn label(self: SettingsTab) []const u8 {
        return switch (self) {
            .members => "Members",
            .bundles => "Bundles",
            .workspaces => "Workspaces",
            .token => "Token",
        };
    }
};

const settings_tabs = [_]SettingsTab{ .members, .bundles, .workspaces, .token };

const ConfirmAction = enum {
    none,
    remove_member,
    delete_bundle,
    delete_workspace,
};

const TopModule = enum(u8) {
    library,
    proposals,
    workspace,
    insights,

    fn label(self: TopModule) []const u8 {
        return switch (self) {
            .library => "Library",
            .proposals => "Proposals",
            .workspace => "Workspace",
            .insights => "Insights",
        };
    }
};

const DetailTab = enum(u8) {
    overview,
    content,
    history,

    fn label(self: DetailTab) []const u8 {
        return switch (self) {
            .overview => "Overview",
            .content => "Content",
            .history => "History",
        };
    }
};

const top_tabs = [_]TopModule{ .library, .proposals, .workspace, .insights };

// 12 prompts + up to 12 group headers = 24 max rows in Library
const MAX_LIBRARY_ROWS = data.PROMPTS.len + 12;
const detail_tabs = [_]DetailTab{ .overview, .content, .history };

pub const Dashboard = struct {
    selected_module: TopModule = .library,
    selected_prompt: usize = 0,
    show_help: bool = false,
    show_detail: bool = false,
    show_settings: bool = false,
    show_confirm: bool = false,
    confirm_message: []const u8 = "",
    confirm_action: ConfirmAction = .none,
    detail_origin: TopModule = .library,
    detail_tab: DetailTab = .overview,
    settings_tab: SettingsTab = .members,
    status_line: []const u8 = "Ready.",

    // Settings
    settings_member_scroll: vxfw.ScrollBars,
    settings_member_widgets: [data.MEMBERS.len]vxfw.Widget = undefined,
    settings_member_rows: [data.MEMBERS.len]TableRow = undefined,
    settings_member_cols: [data.MEMBERS.len][3]Column = undefined,

    // Library: grouped display with bundle filter
    library_bundle_filter: usize = 0,
    library_scroll_bars: vxfw.ScrollBars,
    library_row_count: usize = 0,
    library_prompt_indices: [MAX_LIBRARY_ROWS]?usize = .{null} ** MAX_LIBRARY_ROWS,
    library_widgets: [MAX_LIBRARY_ROWS]vxfw.Widget = undefined,
    library_text_rows: [MAX_LIBRARY_ROWS]vxfw.Text = undefined,
    library_table_rows: [MAX_LIBRARY_ROWS]TableRow = undefined,
    library_table_cols: [MAX_LIBRARY_ROWS][3]Column = undefined,

    content_scroll_bars: vxfw.ScrollBars,
    content_widget: [1]vxfw.Widget = undefined,
    content_text: vxfw.Text = .{ .text = "" },

    history_scroll_bars: vxfw.ScrollBars,
    history_widgets: [data.HISTORY.len]vxfw.Widget = undefined,
    history_rows: [data.HISTORY.len]TableRow = undefined,
    history_cols: [data.HISTORY.len][3]Column = undefined,

    review_scroll_bars: vxfw.ScrollBars,
    review_widgets: [data.PROPOSALS.len]vxfw.Widget = undefined,
    review_rows: [data.PROPOSALS.len]TableRow = undefined,
    review_cols: [data.PROPOSALS.len][2]Column = undefined,

    review_diff_scroll_bars: vxfw.ScrollBars,
    review_diff_widgets: [8]vxfw.Widget = undefined,
    review_diff_rows: [8]vxfw.Text = undefined,
    review_diff_count: usize = 0,

    // Workspace Status
    ws_tab: WsTab = .prompts,
    workspace_scroll_bars: vxfw.ScrollBars,
    workspace_widgets: [data.WORKSPACES.len]vxfw.Widget = undefined,
    workspace_rows: [data.WORKSPACES.len]TableRow = undefined,
    workspace_cols: [data.WORKSPACES.len][3]Column = undefined,

    // Insights
    insights_period: Period = .daily,
    insights_scroll_bars: vxfw.ScrollBars,
    insights_widgets: [data.INSIGHTS_WS.len]vxfw.Widget = undefined,
    insights_rows: [data.INSIGHTS_WS.len]TableRow = undefined,
    insights_cols: [data.INSIGHTS_WS.len][3]Column = undefined,

    pub fn init() Dashboard {
        return .{
            .library_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .content_scroll_bars = w.initPlainScrollBars(theme.PANEL, 3),
            .history_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .review_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .review_diff_scroll_bars = w.initPlainScrollBars(theme.PANEL, 2),
            .workspace_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .insights_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .settings_member_scroll = w.initCursorScrollBars(theme.PANEL),
        };
    }

    pub fn widget(self: *Dashboard) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Dashboard = @ptrCast(@alignCast(ptr));
        try self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Dashboard = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn handleEvent(self: *Dashboard, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                // Confirm overlay absorbs all keys
                if (self.show_confirm) {
                    if (key.matches('y', .{})) {
                        switch (self.confirm_action) {
                            .remove_member => {
                                self.status_line = "Member removed (mock).";
                            },
                            .delete_bundle => {
                                self.status_line = "Bundle deleted (mock).";
                            },
                            .delete_workspace => {
                                self.status_line = "Workspace deleted (mock).";
                            },
                            .none => {},
                        }
                        self.show_confirm = false;
                        self.confirm_action = .none;
                        ctx.consumeAndRedraw();
                    }
                    if (key.matches('n', .{}) or key.matches(vaxis.Key.escape, .{})) {
                        self.show_confirm = false;
                        self.confirm_action = .none;
                        self.status_line = "Cancelled.";
                        ctx.consumeAndRedraw();
                    }
                    return;
                }

                // Help overlay absorbs all keys
                if (self.show_help) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('?', .{}) or key.matches('q', .{})) {
                        self.show_help = false;
                        ctx.consumeAndRedraw();
                    }
                    return;
                }

                // Global quit
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.consumeEvent();
                    ctx.quit = true;
                    return;
                }
                if (key.matches('q', .{}) and !self.show_detail and !self.show_settings) {
                    ctx.consumeEvent();
                    ctx.quit = true;
                    return;
                }

                // Help toggle
                if (key.matches('?', .{})) {
                    self.show_help = true;
                    ctx.consumeAndRedraw();
                    return;
                }

                // Settings mode
                if (self.show_settings) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
                        self.show_settings = false;
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
                        self.shiftSettingsTab(-1);
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
                        self.shiftSettingsTab(1);
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (self.settings_tab == .members) {
                        // r: toggle role of selected member
                        if (key.matches('r', .{})) {
                            const sel = @min(@as(usize, @intCast(self.settings_member_scroll.scroll_view.cursor)), data.MEMBERS.len - 1);
                            const m = &data.MEMBERS[sel];
                            const new_role: []const u8 = if (std.mem.eql(u8, m.role, "member")) "maintainer" else "member";
                            _ = new_role;
                            self.status_line = "Role change requires Hub API (mock).";
                            ctx.consumeAndRedraw();
                            return;
                        }
                        // x: remove selected member (confirm)
                        if (key.matches('x', .{})) {
                            const sel = @min(@as(usize, @intCast(self.settings_member_scroll.scroll_view.cursor)), data.MEMBERS.len - 1);
                            self.confirm_message = data.MEMBERS[sel].username;
                            self.confirm_action = .remove_member;
                            self.show_confirm = true;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        // a: invite (placeholder)
                        if (key.matches('a', .{})) {
                            self.status_line = "Invite requires TextField input (next iteration).";
                            ctx.consumeAndRedraw();
                            return;
                        }
                        try self.settings_member_scroll.scroll_view.handleEvent(ctx, event);
                    }
                    if (self.settings_tab == .bundles) {
                        if (key.matches('x', .{})) {
                            self.confirm_message = "selected bundle";
                            self.confirm_action = .delete_bundle;
                            self.show_confirm = true;
                            ctx.consumeAndRedraw();
                            return;
                        }
                    }
                    if (self.settings_tab == .workspaces) {
                        if (key.matches('x', .{})) {
                            self.confirm_message = "selected workspace";
                            self.confirm_action = .delete_workspace;
                            self.show_confirm = true;
                            ctx.consumeAndRedraw();
                            return;
                        }
                    }
                    return;
                }

                // Settings toggle (S key)
                if (key.matches('S', .{})) {
                    self.show_settings = true;
                    ctx.consumeAndRedraw();
                    return;
                }

                // Detail mode: Esc returns to origin
                if (self.show_detail) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
                        self.show_detail = false;
                        self.selected_module = self.detail_origin;
                        self.status_line = "Returned.";
                        ctx.consumeAndRedraw();
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
                    if (key.matches('p', .{})) {
                        self.status_line = "Propose: disabled until Hub contracts land (Phase 2).";
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (self.detail_tab == .content) {
                        try self.content_scroll_bars.scroll_view.handleEvent(ctx, event);
                        return;
                    }
                    if (self.detail_tab == .history) {
                        try self.history_scroll_bars.scroll_view.handleEvent(ctx, event);
                        return;
                    }
                    return;
                }

                // Top-level tab switching
                if (key.matches('1', .{})) return self.selectTab(ctx, .library);
                if (key.matches('2', .{})) return self.selectTab(ctx, .proposals);
                if (key.matches('3', .{})) return self.selectTab(ctx, .workspace);
                if (key.matches('4', .{})) return self.selectTab(ctx, .insights);

                // Module-specific input
                switch (self.selected_module) {
                    .library => {
                        if (key.matches('b', .{})) {
                            self.library_bundle_filter = (self.library_bundle_filter + 1) % (data.BUNDLES.len + 1);
                            self.library_scroll_bars.scroll_view.cursor = 0;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        const prev = self.library_scroll_bars.scroll_view.cursor;
                        try self.library_scroll_bars.scroll_view.handleEvent(ctx, event);
                        // If cursor landed on a group header, skip in the
                        // direction of movement to the next prompt row.
                        const cursor_pos = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
                        if (cursor_pos < self.library_row_count) {
                            if (self.library_prompt_indices[cursor_pos]) |pi| {
                                self.selected_prompt = pi;
                            } else if (self.library_scroll_bars.scroll_view.cursor != prev) {
                                const moving_down = self.library_scroll_bars.scroll_view.cursor > prev;
                                if (moving_down) {
                                    if (cursor_pos + 1 < self.library_row_count) {
                                        self.library_scroll_bars.scroll_view.cursor += 1;
                                        if (self.library_prompt_indices[cursor_pos + 1]) |pi| {
                                            self.selected_prompt = pi;
                                        }
                                    }
                                } else {
                                    if (cursor_pos > 0) {
                                        self.library_scroll_bars.scroll_view.cursor -= 1;
                                        if (self.library_prompt_indices[cursor_pos - 1]) |pi| {
                                            self.selected_prompt = pi;
                                        }
                                    }
                                }
                                ctx.consumeAndRedraw();
                            }
                        }
                        if (key.matches(vaxis.Key.enter, .{})) {
                            self.openDetail(ctx, self.selected_prompt, .library, .overview);
                        }
                    },
                    .proposals => {
                        const prev = self.review_scroll_bars.scroll_view.cursor;
                        try self.review_scroll_bars.scroll_view.handleEvent(ctx, event);
                        if (self.review_scroll_bars.scroll_view.cursor != prev) {
                            self.status_line = "Proposal selected.";
                        }
                        if (key.matches('a', .{})) {
                            self.status_line = "Accept: maintainer-only, disabled until Hub API.";
                            ctx.consumeAndRedraw();
                        }
                        if (key.matches('x', .{})) {
                            self.status_line = "Reject: maintainer-only, disabled until Hub API.";
                            ctx.consumeAndRedraw();
                        }
                    },
                    .workspace => {
                        if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
                            self.shiftWsTab(-1);
                            ctx.consumeAndRedraw();
                            return;
                        }
                        if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
                            self.shiftWsTab(1);
                            ctx.consumeAndRedraw();
                            return;
                        }
                        try self.workspace_scroll_bars.scroll_view.handleEvent(ctx, event);
                        if (key.matches('r', .{})) {
                            self.status_line = "Sync: requires Hub client core (Phase 2).";
                            ctx.consumeAndRedraw();
                        }
                    },
                    .insights => {
                        try self.insights_scroll_bars.scroll_view.handleEvent(ctx, event);
                        if (key.matches('t', .{})) {
                            self.insights_period = self.insights_period.next();
                            ctx.consumeAndRedraw();
                        }
                        if (key.matches(vaxis.Key.enter, .{})) {
                            const cidx = @min(@as(usize, @intCast(self.insights_scroll_bars.scroll_view.cursor)), data.INSIGHTS_WS.len - 1);
                            _ = cidx;
                            self.status_line = "Drill-down to workspace detail (future).";
                            ctx.consumeAndRedraw();
                        }
                    },
                }
            },
            else => {},
        }
    }

    fn draw(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        if (size.width < 96 or size.height < 24) {
            return self.drawTooSmall(ctx, size);
        }

        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        const header_h: u16 = 4;
        const footer_h: u16 = 1;
        const body_h = size.height - header_h - footer_h;

        const header_ctx = ctx.withConstraints(
            .{ .width = size.width, .height = header_h },
            .{ .width = size.width, .height = header_h },
        );
        const body_ctx = ctx.withConstraints(
            .{ .width = size.width, .height = body_h },
            .{ .width = size.width, .height = body_h },
        );
        const footer_ctx = ctx.withConstraints(
            .{ .width = size.width, .height = footer_h },
            .{ .width = size.width, .height = footer_h },
        );

        var child_count: usize = 3;
        if (self.show_help or self.show_confirm) child_count = 4;

        const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawHeader(header_ctx) };
        children[1] = .{ .origin = .{ .row = header_h, .col = 0 }, .surface = try self.drawBody(body_ctx) };
        children[2] = .{ .origin = .{ .row = header_h + body_h, .col = 0 }, .surface = try self.drawFooter(footer_ctx) };

        if (self.show_help) {
            const help_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[3] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawHelpOverlay(help_ctx) };
        }
        if (self.show_confirm) {
            const confirm_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[3] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawConfirmOverlay(confirm_ctx) };
        }

        root.children = children;
        return root;
    }

    fn drawHeader(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        w.fillSurface(&surface, theme.PANEL);

        // Row 0: App title in accent, context in muted
        w.writeText(&surface, ctx, 1, 0, "clumsies", theme.boldOn(theme.PANEL, theme.ACCENT));
        w.writeText(&surface, ctx, 10, 0, "\xe2\x94\x80 acme \xe2\x94\x80 payments-api \xe2\x94\x80 alice (maintainer)", theme.fg(theme.MUTED));
        _ = w.drawFilledBadge(&surface, ctx, 0, surface.size.width -| 8, "FRESH", theme.PANEL, theme.OK);

        // Row 2: Tab badges (row 1 and 3 are padding)
        var col: u16 = 1;
        for (top_tabs, 0..) |tab, idx| {
            const label = try std.fmt.allocPrint(ctx.arena, "{d} {s}", .{ idx + 1, tab.label() });
            const is_active = if (self.show_detail or self.show_settings) false else (tab == self.selected_module);
            col = w.drawTabBadge(&surface, ctx, 2, col, label, is_active);
            col +|= 1;
        }

        return surface;
    }

    fn drawBody(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        if (self.show_settings) return self.drawSettings(ctx);
        if (self.show_detail) return self.drawPromptDetail(ctx);
        return switch (self.selected_module) {
            .library => self.drawLibrary(ctx),
            .proposals => self.drawProposalReview(ctx),
            .workspace => self.drawWorkspaceStatus(ctx),
            .insights => self.drawInsights(ctx),
        };
    }

    fn drawFooter(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        w.fillSurface(&surface, theme.PANEL);

        const keys = if (self.show_help)
            "Esc close help"
        else if (self.show_confirm)
            "y confirm  n cancel  Esc cancel"
        else if (self.show_settings)
            "h/l tab  j/k move  a add  r role  x remove  Esc back"
        else if (self.show_detail)
            "h/l tab  j/k move  Enter diff  p propose  Esc back  ? help"
        else switch (self.selected_module) {
            .library => "j/k move  Enter open  b bundle  S settings  ? help  q quit",
            .proposals => "j/k move  a accept  x reject  S settings  ? help  q quit",
            .workspace => "h/l tab  j/k move  r sync  S settings  ? help  q quit",
            .insights => "j/k move  t period  S settings  ? help  q quit",
        };
        w.writeText(&surface, ctx, 1, 0, keys, theme.fg(theme.MUTED));
        return surface;
    }

    // Library: two-column (prompt list + preview sidebar).
    // Bundle facet deferred to Phase 2 when filter interaction is implemented.
    fn drawLibrary(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        self.syncLibraryWidgets();

        const preview_w: u16 = if (size.width > 118) 30 else 26;
        const list_w: u16 = size.width - preview_w - 1;

        const list_ctx = ctx.withConstraints(.{ .width = list_w, .height = size.height }, .{ .width = list_w, .height = size.height });
        const preview_ctx = ctx.withConstraints(.{ .width = preview_w, .height = size.height }, .{ .width = preview_w, .height = size.height });

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawPromptTable(list_ctx) };
        children[1] = .{ .origin = .{ .row = 0, .col = list_w + 1 }, .surface = try self.drawPromptPreview(preview_ctx) };
        root.children = children;
        return root;
    }

    fn drawPromptTable(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        // Suppress draw_cursor during rendering to avoid libvaxis #256 clipping.
        // Restored by defer so event handling still gets cursor movement.
        self.library_scroll_bars.scroll_view.draw_cursor = false;
        defer self.library_scroll_bars.scroll_view.draw_cursor = true;

        const bundle_label: []const u8 = if (self.library_bundle_filter == 0)
            "All"
        else
            data.BUNDLES[self.library_bundle_filter - 1].name;
        const subtitle = try std.fmt.allocPrint(ctx.arena, "bundle: {s}  b cycle", .{bundle_label});
        const panel: w.Panel = .{
            .owner = self.widget(),
            .title = "Library Prompts",
            .subtitle = subtitle,
            .background = theme.PANEL,
            .border_color = theme.BORDER,
            .child = self.library_scroll_bars.widget(),
        };
        var surface = try panel.draw(ctx);
        return w.applyCursorOverlay(ctx, &surface, &self.library_scroll_bars.scroll_view);
    }

    // Preview shows only info NOT in the main table:
    // sparkline trend, constraint count, bundle membership, action hint.
    fn drawPromptPreview(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const p = &data.PROMPTS[self.selected_prompt];
        const spark = try w.sparkline(ctx.arena, p.trend[0..8]);
        const preview = try std.fmt.allocPrint(ctx.arena,
            \\last 7d
            \\{s}
            \\
            \\constraints  {d}
            \\bundles      {s}
            \\
            \\Enter  open detail
        , .{ spark, p.constraint_count, p.bundle_names });

        const text_widget: vxfw.Text = .{
            .text = preview,
            .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT),
            .width_basis = .parent,
        };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{
            .owner = self.widget(),
            .title = "Selected",
            .subtitle = "",
            .background = theme.PANEL,
            .border_color = theme.BORDER,
            .child = wrapper.widget(),
            .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
        };
        return panel.draw(ctx);
    }

    // Prompt Detail: meta header + inner tabs + sidebar
    fn drawPromptDetail(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const p = &data.PROMPTS[self.selected_prompt];

        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        const meta_h: u16 = 5;
        const sidebar_w: u16 = if (size.width > 118) 30 else 26;
        const main_w: u16 = size.width - sidebar_w - 1;
        const lower_h: u16 = size.height - meta_h - 1;

        const meta_ctx = ctx.withConstraints(.{ .width = size.width, .height = meta_h }, .{ .width = size.width, .height = meta_h });
        const main_ctx = ctx.withConstraints(.{ .width = main_w, .height = lower_h }, .{ .width = main_w, .height = lower_h });
        const side_ctx = ctx.withConstraints(.{ .width = sidebar_w, .height = lower_h }, .{ .width = sidebar_w, .height = lower_h });

        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawDetailMeta(meta_ctx, p) };
        children[1] = .{ .origin = .{ .row = meta_h + 1, .col = 0 }, .surface = try self.drawDetailMain(main_ctx, p) };
        children[2] = .{ .origin = .{ .row = meta_h + 1, .col = main_w + 1 }, .surface = try self.drawDetailSidebar(side_ctx, p) };
        root.children = children;
        return root;
    }

    fn drawDetailMeta(self: *Dashboard, ctx: vxfw.DrawContext, p: *const data.PromptEntry) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        w.fillSurface(&surface, theme.PANEL);
        w.drawBorder(&surface, theme.BORDER, theme.PANEL);

        w.writeText(&surface, ctx, 2, 0, p.canonical_name, theme.boldOn(theme.PANEL, theme.TEXT));
        w.writeRightText(&surface, ctx, 0, p.content_hash, theme.textOn(theme.PANEL, theme.MUTED));

        var col: u16 = 2;
        col = w.drawFilledBadge(&surface, ctx, 1, col, p.kind, theme.PANEL, theme.GOLD);
        col +|= 1;
        _ = w.drawFilledBadge(&surface, ctx, 1, col, p.bundle_names, theme.PANEL, theme.CYAN);

        // Row 2: override / proposal status
        var status_col: u16 = 2;
        status_col = w.drawFilledBadge(&surface, ctx, 2, status_col, "LOCAL", theme.PANEL, theme.WARN);
        status_col +|= 1;
        _ = w.drawFilledBadge(&surface, ctx, 2, status_col, "NO PROPOSAL", theme.TEXT_SOFT, theme.PANEL_ALT);

        const metrics = try std.fmt.allocPrint(ctx.arena, "refer {s}   constraints {d}   bundles {d}", .{ p.refer_count, p.constraint_count, p.bundle_count });
        w.writeText(&surface, ctx, 2, 3, metrics, theme.boldOn(theme.PANEL, theme.TEXT));
        return surface;
    }

    fn drawDetailMain(self: *Dashboard, ctx: vxfw.DrawContext, p: *const data.PromptEntry) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        w.fillSurface(&surface, theme.PANEL);

        // Inner tab strip
        var col: u16 = 0;
        for (detail_tabs) |tab| {
            col = w.drawInnerTabBadge(&surface, ctx, 0, col, tab.label(), tab == self.detail_tab);
            col +|= 1;
        }

        const inner_h = ctx.max.height.? -| 2;
        const inner_w = ctx.max.width.?;

        switch (self.detail_tab) {
            .overview => {
                const spark = try w.sparkline(ctx.arena, p.trend[0..8]);
                const kw: u16 = 12;
                const kv_col: u16 = 2;
                var kv_row: u16 = 3;
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "canonical", p.canonical_name, kw);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "kind", p.kind, kw);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "bundles", p.bundle_names, kw);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "hash", p.content_hash, kw);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "updated", p.updated, kw);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "constraints", try std.fmt.allocPrint(ctx.arena, "{d}", .{p.constraint_count}), kw);
                kv_row += 1;
                kv_row = w.writeSectionHeader(&surface, ctx, kv_col, kv_row, "Trend (last 7d)");
                w.writeText(&surface, ctx, kv_col, kv_row, spark, theme.fg(theme.ACCENT));
                kv_row += 2;
                kv_row = w.writeSectionHeader(&surface, ctx, kv_col, kv_row, "Local Override");
                w.writeText(&surface, ctx, kv_col, kv_row, "Detected in ws: payments-api. Press p to propose.", theme.fg(theme.TEXT_SOFT));
            },
            .content => {
                self.syncContentWidget();
                const child_ctx = ctx.withConstraints(
                    .{ .width = inner_w, .height = inner_h },
                    .{ .width = inner_w, .height = inner_h },
                );
                const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                children[0] = .{ .origin = .{ .row = 2, .col = 0 }, .surface = try self.content_scroll_bars.widget().draw(child_ctx) };
                surface.children = children;
            },
            .history => {
                self.syncHistoryWidgets();
                const list_w: u16 = if (inner_w > 76) 34 else inner_w / 2;
                const detail_w = inner_w - list_w - 1;

                const list_ctx = ctx.withConstraints(.{ .width = list_w, .height = inner_h }, .{ .width = list_w, .height = inner_h });
                const det_ctx = ctx.withConstraints(.{ .width = detail_w, .height = inner_h }, .{ .width = detail_w, .height = inner_h });

                self.history_scroll_bars.scroll_view.draw_cursor = false;
                defer self.history_scroll_bars.scroll_view.draw_cursor = true;

                var list_surface = try self.history_scroll_bars.widget().draw(list_ctx);
                // No Panel border here, so cursor overlay targets row directly
                const sv = &self.history_scroll_bars.scroll_view;
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
                        const new = try ctx.arena.alloc(vxfw.SubSurface, old.len + 1);
                        @memcpy(new[0..old.len], old);
                        new[old.len] = .{
                            .origin = .{ .col = 0, .row = crow },
                            .surface = csurface,
                            .z_index = 1,
                        };
                        list_surface.children = new;
                    }
                }

                const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
                children[0] = .{ .origin = .{ .row = 2, .col = 0 }, .surface = list_surface };
                children[1] = .{ .origin = .{ .row = 2, .col = list_w + 1 }, .surface = try self.drawHistoryDetail(det_ctx) };
                surface.children = children;
            },
        }

        // Wrap in panel
        const sw = try ctx.arena.create(w.SurfaceWidget);
        sw.* = .{ .surface = surface, .widget_ref = self.widget() };
        const panel: w.Panel = .{
            .owner = self.widget(),
            .title = "Prompt Detail",
            .subtitle = p.canonical_name,
            .background = theme.PANEL,
            .border_color = theme.BORDER,
            .child = sw.widget(),
            .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
        };
        return panel.draw(ctx);
    }

    fn drawDetailSidebar(self: *Dashboard, ctx: vxfw.DrawContext, p: *const data.PromptEntry) std.mem.Allocator.Error!vxfw.Surface {
        const spark = try w.sparkline(ctx.arena, p.trend[0..8]);
        const size = ctx.max.size();
        const inner_w = size.width -| 4;
        _ = inner_w;

        // Build sidebar surface with structured KV
        var sb = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = size.width, .height = size.height });
        w.fillSurface(&sb, theme.PANEL_ALT);
        const kw: u16 = 11;
        const col: u16 = 1;
        var row: u16 = 0;
        row = w.writeKv(&sb, ctx, col, row, "refer", p.refer_count, kw);
        row = w.writeKv(&sb, ctx, col, row, "constraints", try std.fmt.allocPrint(ctx.arena, "{d}", .{p.constraint_count}), kw);
        row = w.writeKv(&sb, ctx, col, row, "workspaces", "API pending", kw);
        row += 1;
        row = w.writeSectionHeader(&sb, ctx, col, row, "Trend");
        w.writeText(&sb, ctx, col, row, spark, theme.fg(theme.ACCENT));
        row += 2;
        row = w.writeSectionHeader(&sb, ctx, col, row, "Actions");
        w.writeText(&sb, ctx, col, row, "p  propose", theme.fg(theme.TEXT_SOFT));
        row += 1;
        w.writeText(&sb, ctx, col, row, "Enter  diff", theme.fg(theme.TEXT_SOFT));
        row += 1;
        const back_text = try std.fmt.allocPrint(ctx.arena, "Esc  back to {s}", .{self.detail_origin.label()});
        w.writeText(&sb, ctx, col, row, back_text, theme.fg(theme.TEXT_SOFT));

        const wrapper = try ctx.arena.create(w.SurfaceWidget);
        wrapper.* = .{ .surface = sb, .widget_ref = self.widget() };
        const panel: w.Panel = .{
            .owner = self.widget(),
            .title = "Usage Summary",
            .subtitle = "",
            .background = theme.PANEL_ALT,
            .border_color = theme.BORDER,
            .child = wrapper.widget(),
        };
        return panel.draw(ctx);
    }

    fn drawHistoryDetail(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const idx = @min(@as(usize, @intCast(self.history_scroll_bars.scroll_view.cursor)), data.HISTORY.len - 1);
        const h = &data.HISTORY[idx];
        const detail = try std.fmt.allocPrint(ctx.arena,
            \\Date
            \\{s}
            \\
            \\Hash
            \\{s}
            \\
            \\Label
            \\{s}
            \\
            \\Next
            \\Enter opens a diff overlay vs current (Phase 2).
        , .{ h.date, h.hash, h.label });

        const text_widget: vxfw.Text = .{
            .text = detail,
            .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT),
            .width_basis = .parent,
        };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{
            .owner = self.widget(),
            .title = "Version Detail",
            .subtitle = if (idx == 0) "current" else "history",
            .background = theme.PANEL,
            .border_color = theme.BORDER,
            .child = wrapper.widget(),
            .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
        };
        return panel.draw(ctx);
    }

    // Proposal Review: queue + diff + sidebar (three-column)
    fn drawProposalReview(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        self.syncReviewWidgets();
        const proposal = &data.PROPOSALS[self.selectedProposalIdx()];
        self.syncDiffWidgets(proposal);

        const queue_w: u16 = if (size.width > 112) 28 else 24;
        const side_w: u16 = if (size.width > 112) 28 else 24;
        const diff_w: u16 = size.width - queue_w - side_w - 2;

        const q_ctx = ctx.withConstraints(.{ .width = queue_w, .height = size.height }, .{ .width = queue_w, .height = size.height });
        const d_ctx = ctx.withConstraints(.{ .width = diff_w, .height = size.height }, .{ .width = diff_w, .height = size.height });
        const s_ctx = ctx.withConstraints(.{ .width = side_w, .height = size.height }, .{ .width = side_w, .height = size.height });

        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawReviewQueue(q_ctx) };
        children[1] = .{ .origin = .{ .row = 0, .col = queue_w + 1 }, .surface = try self.drawReviewDiff(d_ctx, proposal) };
        children[2] = .{ .origin = .{ .row = 0, .col = queue_w + diff_w + 2 }, .surface = try self.drawReviewSidebar(s_ctx, proposal) };
        root.children = children;
        return root;
    }

    fn drawReviewQueue(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        self.review_scroll_bars.scroll_view.draw_cursor = false;
        defer self.review_scroll_bars.scroll_view.draw_cursor = true;

        const panel: w.Panel = .{ .owner = self.widget(), .title = "Proposal Queue", .subtitle = "status: open", .background = theme.PANEL, .border_color = theme.BORDER, .child = self.review_scroll_bars.widget() };
        var surface = try panel.draw(ctx);
        return w.applyCursorOverlay(ctx, &surface, &self.review_scroll_bars.scroll_view);
    }

    fn drawReviewDiff(self: *Dashboard, ctx: vxfw.DrawContext, proposal: *const data.ProposalEntry) std.mem.Allocator.Error!vxfw.Surface {
        const panel: w.Panel = .{ .owner = self.widget(), .title = proposal.prompt_name, .subtitle = proposal.id, .background = theme.PANEL, .border_color = theme.BORDER, .child = self.review_diff_scroll_bars.widget() };
        return panel.draw(ctx);
    }

    fn drawReviewSidebar(self: *Dashboard, ctx: vxfw.DrawContext, proposal: *const data.ProposalEntry) std.mem.Allocator.Error!vxfw.Surface {
        const sidebar = try std.fmt.allocPrint(ctx.arena,
            \\Status
            \\{s}
            \\
            \\Author
            \\{s}
            \\
            \\Created
            \\{s}
            \\
            \\Base Hash
            \\{s}
            \\
            \\Trace Summary
            \\refer {d}   sessions {d}
            \\
            \\Actions
            \\a  accept (maintainer only)
            \\x  reject (maintainer only)
            \\c  comment (Phase 2)
        , .{ proposal.status, proposal.author, proposal.created, proposal.base_hash, proposal.trace_refers, proposal.trace_sessions });

        const text_widget: vxfw.Text = .{ .text = sidebar, .style = theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT), .width_basis = .parent };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{ .owner = self.widget(), .title = "Review Lens", .subtitle = proposal.author, .background = theme.PANEL_ALT, .border_color = theme.BORDER, .child = wrapper.widget(), .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } };
        return panel.draw(ctx);
    }

    // Workspace Status: list + detail (two-column)
    fn drawWorkspaceStatus(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        self.syncWorkspaceWidgets();
        const ws_idx = @min(@as(usize, @intCast(self.workspace_scroll_bars.scroll_view.cursor)), data.WORKSPACES.len - 1);
        const ws = &data.WORKSPACES[ws_idx];

        // Summary bar (2 rows)
        const summary_h: u16 = 3;
        var summary = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = size.width, .height = summary_h });
        w.fillSurface(&summary, theme.PANEL);
        w.drawBorder(&summary, theme.BORDER, theme.PANEL);
        w.writeText(&summary, ctx, 2, 0, "Workspace Status", theme.boldOn(theme.PANEL, theme.TEXT));
        w.writeRightText(&summary, ctx, 0, ws.name, theme.textOn(theme.PANEL, theme.MUTED));
        const summary_text = try std.fmt.allocPrint(ctx.arena, " paths: {d}   prompts: {d}   context: {d}   overrides: {d}   rev: {d}/{d}   state: {s}", .{ ws.paths, ws.prompts, ws.contexts, ws.overrides, ws.local_rev, ws.remote_rev, data.syncStateLabel(ws) });
        w.writeText(&summary, ctx, 1, 1, summary_text, theme.textOn(theme.PANEL, theme.TEXT_SOFT));

        // Inner tab strip + content area
        const body_h = size.height - summary_h;
        const body_ctx = ctx.withConstraints(.{ .width = size.width, .height = body_h }, .{ .width = size.width, .height = body_h });
        const body_surface = try self.drawWsBody(body_ctx, ws);

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = summary };
        children[1] = .{ .origin = .{ .row = summary_h, .col = 0 }, .surface = body_surface };
        root.children = children;
        return root;
    }

    fn drawWsBody(self: *Dashboard, ctx: vxfw.DrawContext, ws: *const data.WorkspaceEntry) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&surface, theme.PANEL);

        // Inner tabs
        var tab_col: u16 = 1;
        for (ws_tabs) |tab| {
            tab_col = w.drawInnerTabBadge(&surface, ctx, 0, tab_col, tab.label(), tab == self.ws_tab);
            tab_col +|= 1;
        }

        const content_h = size.height -| 2;
        const left_w: u16 = if (size.width > 100) size.width -| 36 else size.width;
        const right_w: u16 = if (size.width > 100) 35 else 0;

        const left_ctx = ctx.withConstraints(.{ .width = left_w, .height = content_h }, .{ .width = left_w, .height = content_h });
        const right_ctx = ctx.withConstraints(.{ .width = right_w, .height = content_h }, .{ .width = right_w, .height = content_h });

        const tab_content = switch (self.ws_tab) {
            .prompts => try self.drawWsPrompts(left_ctx),
            .context => try self.drawWsContext(left_ctx),
            .overrides => try self.drawWsOverrides(left_ctx),
        };

        if (right_w > 0) {
            const detail = try self.drawWsDetail(right_ctx, ws);
            const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
            children[0] = .{ .origin = .{ .row = 2, .col = 0 }, .surface = tab_content };
            children[1] = .{ .origin = .{ .row = 2, .col = left_w + 1 }, .surface = detail };
            surface.children = children;
        } else {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{ .origin = .{ .row = 2, .col = 0 }, .surface = tab_content };
            surface.children = children;
        }
        return surface;
    }

    fn drawWsPrompts(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(ctx.arena, " NAME                KIND  OVR  STATE\n");
        for (data.WS_PROMPTS) |p| {
            const ovr: []const u8 = if (p.has_override) "yes" else " no";
            const line = try std.fmt.allocPrint(ctx.arena, " {s:<18}  {s:<4}  {s}  {s}\n", .{ p.name, p.kind, ovr, p.state });
            try buf.appendSlice(ctx.arena, line);
        }
        const text_widget: vxfw.Text = .{ .text = try ctx.arena.dupe(u8, buf.items), .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT), .width_basis = .parent };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{ .owner = self.widget(), .title = "Prompts", .subtitle = "a add  x remove", .background = theme.PANEL, .border_color = theme.BORDER, .child = wrapper.widget(), .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 } };
        return panel.draw(ctx);
    }

    fn drawWsContext(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(ctx.arena, " PATH                      SIZE  STATE\n");
        for (data.WS_CONTEXT) |f| {
            const line = try std.fmt.allocPrint(ctx.arena, " {s:<24}  {s:<4}  {s}\n", .{ f.path, f.size, f.state });
            try buf.appendSlice(ctx.arena, line);
        }
        const text_widget: vxfw.Text = .{ .text = try ctx.arena.dupe(u8, buf.items), .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT), .width_basis = .parent };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{ .owner = self.widget(), .title = "Context Files", .subtitle = "read-only", .background = theme.PANEL, .border_color = theme.BORDER, .child = wrapper.widget(), .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 } };
        return panel.draw(ctx);
    }

    fn drawWsOverrides(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(ctx.arena, " PROMPT              BASE  CUR   STATUS\n");
        for (data.WS_OVERRIDES) |o| {
            const line = try std.fmt.allocPrint(ctx.arena, " {s:<18}  {s:<4}  {s:<4}  {s}\n", .{ o.prompt_name, o.base_hash, o.current_hash, o.status });
            try buf.appendSlice(ctx.arena, line);
        }
        const text_widget: vxfw.Text = .{ .text = try ctx.arena.dupe(u8, buf.items), .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT), .width_basis = .parent };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{ .owner = self.widget(), .title = "Overrides", .subtitle = "conflict detection", .background = theme.PANEL, .border_color = theme.BORDER, .child = wrapper.widget(), .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 } };
        return panel.draw(ctx);
    }

    fn drawWsDetail(self: *Dashboard, ctx: vxfw.DrawContext, ws: *const data.WorkspaceEntry) std.mem.Allocator.Error!vxfw.Surface {
        const detail = try std.fmt.allocPrint(ctx.arena,
            \\Workspace
            \\{s}
            \\
            \\Rev (local / remote)
            \\{d} / {d}
            \\
            \\Sync State
            \\{s}
            \\
            \\Bound Paths
            \\{d}
            \\
            \\Actions
            \\r  sync
            \\a  add prompt (Phase 2)
            \\x  remove prompt (Phase 2)
        , .{ ws.name, ws.local_rev, ws.remote_rev, data.syncStateLabel(ws), ws.paths });

        const text_widget: vxfw.Text = .{ .text = detail, .style = theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT), .width_basis = .parent };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{ .owner = self.widget(), .title = ws.name, .subtitle = data.syncStateLabel(ws), .background = theme.PANEL_ALT, .border_color = theme.BORDER, .child = wrapper.widget(), .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } };
        return panel.draw(ctx);
    }

    // Insights: workspace-first refer coverage analysis
    fn drawInsights(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        self.syncInsightsWidgets();

        // Org summary bar (3 rows)
        const summary_h: u16 = 3;
        var summary = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = size.width, .height = summary_h });
        w.fillSurface(&summary, theme.PANEL);
        w.drawBorder(&summary, theme.BORDER, theme.PANEL);
        const title = try std.fmt.allocPrint(ctx.arena, "Insights \xe2\x94\x80 org: acme \xe2\x94\x80 period: {s}", .{self.insights_period.label()});
        w.writeText(&summary, ctx, 2, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
        w.writeRightText(&summary, ctx, 0, "t cycle period", theme.textOn(theme.PANEL, theme.MUTED));

        // Compute org totals from mock data
        var total_refer: u32 = 0;
        for (data.INSIGHTS_WS) |cw| {
            var val: u32 = 0;
            for (cw.refer_count) |c| {
                if (c >= '0' and c <= '9') {
                    val = val * 10 + (c - '0');
                }
            }
            total_refer += val;
        }
        const org_spark = try w.sparkline(ctx.arena, &data.INSIGHTS_WS[0].trend);
        const org_line = try std.fmt.allocPrint(ctx.arena, " workspaces {d}   prompts {d}   total refer ~{d}   org trend {s}", .{ data.INSIGHTS_WS.len, data.PROMPTS.len, total_refer, org_spark });
        w.writeText(&summary, ctx, 1, 1, org_line, theme.textOn(theme.PANEL, theme.TEXT_SOFT));

        // Two-column: workspace rank (left) + selected detail (right)
        const body_h = size.height - summary_h;
        const left_w: u16 = if (size.width > 108) 44 else 36;
        const right_w: u16 = size.width - left_w - 1;

        const l_ctx = ctx.withConstraints(.{ .width = left_w, .height = body_h }, .{ .width = left_w, .height = body_h });
        const r_ctx = ctx.withConstraints(.{ .width = right_w, .height = body_h }, .{ .width = right_w, .height = body_h });

        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = summary };
        children[1] = .{ .origin = .{ .row = summary_h, .col = 0 }, .surface = try self.drawInsightsList(l_ctx) };
        children[2] = .{ .origin = .{ .row = summary_h, .col = left_w + 1 }, .surface = try self.drawInsightsDetail(r_ctx) };
        root.children = children;
        return root;
    }

    fn drawInsightsList(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        self.insights_scroll_bars.scroll_view.draw_cursor = false;
        defer self.insights_scroll_bars.scroll_view.draw_cursor = true;

        const panel: w.Panel = .{ .owner = self.widget(), .title = "Workspace Coverage", .subtitle = "j/k select", .background = theme.PANEL, .border_color = theme.BORDER, .child = self.insights_scroll_bars.widget() };
        var surface = try panel.draw(ctx);
        return w.applyCursorOverlay(ctx, &surface, &self.insights_scroll_bars.scroll_view);
    }

    fn drawInsightsDetail(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const cidx = @min(@as(usize, @intCast(self.insights_scroll_bars.scroll_view.cursor)), data.INSIGHTS_WS.len - 1);
        const cw = &data.INSIGHTS_WS[cidx];
        const spark = try w.sparkline(ctx.arena, cw.trend[0..8]);

        var buf: std.ArrayList(u8) = .empty;
        // Selected workspace detail
        try buf.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, "Workspace\n{s}\n\nCoverage\n{d}%\n\nRefer Count\n{s}\n\nTrend\n{s}\n\n", .{ cw.name, cw.coverage, cw.refer_count, spark }));

        // Hotspots section
        try buf.appendSlice(ctx.arena, "Prompt Hotspots\n");
        for (data.HOTSPOTS) |h| {
            try buf.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, " {s:<24} {s}\n", .{ h.name, h.refer_count }));
        }
        try buf.appendSlice(ctx.arena, "\nMember Grouping\nAPI pending (s1-4 expansion needed)");

        const text_widget: vxfw.Text = .{ .text = try ctx.arena.dupe(u8, buf.items), .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT), .width_basis = .parent };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{ .owner = self.widget(), .title = cw.name, .subtitle = try std.fmt.allocPrint(ctx.arena, "coverage {d}%", .{cw.coverage}), .background = theme.PANEL, .border_color = theme.BORDER, .child = wrapper.widget(), .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } };
        return panel.draw(ctx);
    }

    // Settings: drill-down view with inner tabs (Members/Bundles/Workspaces/Token)
    fn drawSettings(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        // Inner tab strip
        var tab_surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = size.width, .height = 1 });
        w.fillSurface(&tab_surface, theme.PANEL);
        var tab_col: u16 = 1;
        for (settings_tabs) |tab| {
            tab_col = w.drawInnerTabBadge(&tab_surface, ctx, 0, tab_col, tab.label(), tab == self.settings_tab);
            tab_col +|= 1;
        }

        // Content area
        const content_h = size.height -| 2;
        const content_ctx = ctx.withConstraints(
            .{ .width = size.width, .height = content_h },
            .{ .width = size.width, .height = content_h },
        );
        const content = switch (self.settings_tab) {
            .members => try self.drawSettingsMembers(content_ctx),
            .bundles => try self.drawSettingsBundles(content_ctx),
            .workspaces => try self.drawSettingsWorkspaces(content_ctx),
            .token => try self.drawSettingsToken(content_ctx),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = tab_surface };
        children[1] = .{ .origin = .{ .row = 2, .col = 0 }, .surface = content };
        root.children = children;
        return root;
    }

    fn drawSettingsMembers(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        self.syncSettingsMemberWidgets();

        const list_w: u16 = if (size.width > 100) size.width -| 32 else size.width;
        const detail_w: u16 = if (size.width > 100) 31 else 0;

        // Member list
        self.settings_member_scroll.scroll_view.draw_cursor = false;
        defer self.settings_member_scroll.scroll_view.draw_cursor = true;

        const list_ctx = ctx.withConstraints(.{ .width = list_w, .height = size.height }, .{ .width = list_w, .height = size.height });
        const panel: w.Panel = .{ .owner = self.widget(), .title = "Org Members", .subtitle = "maintainer: invite/remove", .background = theme.PANEL, .border_color = theme.BORDER, .child = self.settings_member_scroll.widget() };
        var list_surface = try panel.draw(list_ctx);
        list_surface = try w.applyCursorOverlay(list_ctx, &list_surface, &self.settings_member_scroll.scroll_view);

        if (detail_w > 0) {
            const sel_idx = @min(@as(usize, @intCast(self.settings_member_scroll.scroll_view.cursor)), data.MEMBERS.len - 1);
            const m = &data.MEMBERS[sel_idx];
            const detail_text = try std.fmt.allocPrint(ctx.arena,
                \\User
                \\{s}
                \\
                \\Role
                \\{s}
                \\
                \\Joined
                \\{s}
                \\
                \\Actions
                \\PATCH role (maintainer only)
                \\DELETE remove (maintainer only)
            , .{ m.username, m.role, m.joined });
            const text_widget: vxfw.Text = .{ .text = detail_text, .style = theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT), .width_basis = .parent };
            const wrapper = try ctx.arena.create(w.WidgetBox);
            wrapper.* = .{ .widget_ref = text_widget.widget() };
            const detail_ctx = ctx.withConstraints(.{ .width = detail_w, .height = size.height }, .{ .width = detail_w, .height = size.height });
            const detail_panel: w.Panel = .{ .owner = self.widget(), .title = m.username, .subtitle = m.role, .background = theme.PANEL_ALT, .border_color = theme.BORDER, .child = wrapper.widget(), .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } };

            const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
            children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = list_surface };
            children[1] = .{ .origin = .{ .row = 0, .col = list_w + 1 }, .surface = try detail_panel.draw(detail_ctx) };
            root.children = children;
        } else {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = list_surface };
            root.children = children;
        }
        return root;
    }

    fn drawSettingsBundles(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(ctx.arena, "Bundle management (maintainer only)\n\n");
        for (data.BUNDLES) |bundle| {
            const line = try std.fmt.allocPrint(ctx.arena, "{s:<16} {d} prompts\n", .{ bundle.name, bundle.count });
            try buf.appendSlice(ctx.arena, line);
        }
        try buf.appendSlice(ctx.arena, "\nActions\nPOST create  PUT update  DELETE remove");
        const text_widget: vxfw.Text = .{ .text = try ctx.arena.dupe(u8, buf.items), .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT), .width_basis = .parent };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{ .owner = self.widget(), .title = "Bundles", .subtitle = "org-level groups", .background = theme.PANEL, .border_color = theme.BORDER, .child = wrapper.widget(), .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } };
        return panel.draw(ctx);
    }

    fn drawSettingsWorkspaces(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(ctx.arena, "Workspace management\n\n");
        for (data.WORKSPACES) |ws| {
            const line = try std.fmt.allocPrint(ctx.arena, "{s:<16} {d}p {d}c {d}o  {s}\n", .{ ws.name, ws.prompts, ws.contexts, ws.overrides, data.syncStateLabel(&ws) });
            try buf.appendSlice(ctx.arena, line);
        }
        try buf.appendSlice(ctx.arena, "\nActions\nPATCH rename  DELETE remove (maintainer)\nMembers: list / add / remove");
        const text_widget: vxfw.Text = .{ .text = try ctx.arena.dupe(u8, buf.items), .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT), .width_basis = .parent };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{ .owner = self.widget(), .title = "Workspaces", .subtitle = "project-level", .background = theme.PANEL, .border_color = theme.BORDER, .child = wrapper.widget(), .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } };
        return panel.draw(ctx);
    }

    fn drawSettingsToken(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const t = data.CURRENT_TOKEN;
        const text = try std.fmt.allocPrint(ctx.arena,
            \\Current Token
            \\
            \\Scopes
            \\{s}
            \\
            \\Expires
            \\{s}
            \\
            \\Note
            \\Token scopes limit what this session can do.
            \\Actual permissions = min(role, scopes).
            \\Use DELETE /api/auth/token to revoke.
        , .{ t.scope, t.expires });
        const text_widget: vxfw.Text = .{ .text = text, .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT), .width_basis = .parent };
        const wrapper = try ctx.arena.create(w.WidgetBox);
        wrapper.* = .{ .widget_ref = text_widget.widget() };
        const panel: w.Panel = .{ .owner = self.widget(), .title = "Token", .subtitle = "current session", .background = theme.PANEL, .border_color = theme.BORDER, .child = wrapper.widget(), .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } };
        return panel.draw(ctx);
    }

    fn syncSettingsMemberWidgets(self: *Dashboard) void {
        self.settings_member_scroll.scroll_view.cursor = @min(self.settings_member_scroll.scroll_view.cursor, data.MEMBERS.len - 1);
        const sel_idx = @as(usize, @intCast(self.settings_member_scroll.scroll_view.cursor));
        for (data.MEMBERS, 0..) |m, idx| {
            const sel = idx == sel_idx;
            self.settings_member_cols[idx] = .{
                .{ .text = m.username, .flex = 1 },
                .{ .text = m.role, .flex = 0 },
                .{ .text = m.joined, .flex = 0, .alignment = .right },
            };
            self.settings_member_rows[idx] = .{
                .columns = &self.settings_member_cols[idx],
                .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT),
                .gap = 2,
            };
            self.settings_member_widgets[idx] = self.settings_member_rows[idx].widget();
        }
        self.settings_member_scroll.scroll_view.children = .{ .slice = self.settings_member_widgets[0..] };
        self.settings_member_scroll.estimated_content_height = data.MEMBERS.len;
    }

    fn shiftSettingsTab(self: *Dashboard, delta: i8) void {
        const current: i8 = @intCast(@intFromEnum(self.settings_tab));
        const count: i8 = @intCast(settings_tabs.len);
        const next = @mod(current + delta + count, count);
        self.settings_tab = @enumFromInt(@as(u8, @intCast(next)));
    }

    fn drawHelpOverlay(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        // Semi-transparent overlay: paint dimmed background
        w.fillSurface(&surface, theme.PANEL);

        const box_w: u16 = 52;
        const box_h: u16 = 19;
        const start_col = (size.width -| box_w) / 2;
        const start_row = (size.height -| box_h) / 2;

        // Draw box background
        var row: u16 = 0;
        while (row < box_h) : (row += 1) {
            var col: u16 = 0;
            while (col < box_w) : (col += 1) {
                surface.writeCell(start_col + col, start_row + row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .fg = theme.TEXT, .bg = theme.PANEL_ALT },
                });
            }
        }

        // Border
        const s = vaxis.Style{ .fg = theme.ACCENT, .bg = theme.PANEL_ALT };
        surface.writeCell(start_col, start_row, .{ .char = .{ .grapheme = "╭", .width = 1 }, .style = s });
        surface.writeCell(start_col + box_w - 1, start_row, .{ .char = .{ .grapheme = "╮", .width = 1 }, .style = s });
        surface.writeCell(start_col, start_row + box_h - 1, .{ .char = .{ .grapheme = "╰", .width = 1 }, .style = s });
        surface.writeCell(start_col + box_w - 1, start_row + box_h - 1, .{ .char = .{ .grapheme = "╯", .width = 1 }, .style = s });
        var c: u16 = 1;
        while (c < box_w - 1) : (c += 1) {
            surface.writeCell(start_col + c, start_row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = s });
            surface.writeCell(start_col + c, start_row + box_h - 1, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = s });
        }
        var r: u16 = 1;
        while (r < box_h - 1) : (r += 1) {
            surface.writeCell(start_col, start_row + r, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = s });
            surface.writeCell(start_col + box_w - 1, start_row + r, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = s });
        }

        // Title
        w.writeText(&surface, ctx, start_col + 2, start_row, " Keyboard Reference ", theme.boldOn(theme.PANEL_ALT, theme.ACCENT));

        const lines = [_][]const u8{
            "1-4            Switch top-level module",
            "j / \xe2\x86\x93           Move down / next row",
            "k / \xe2\x86\x91           Move up / previous row",
            "h / \xe2\x86\x90           Previous tab / region",
            "l / \xe2\x86\x92           Next tab / region",
            "Enter          Open selected / confirm",
            "Esc            Back / close overlay",
            "g              Jump to first row",
            "G              Jump to last row",
            "a              Accept proposal (maintainer)",
            "x              Reject proposal (maintainer)",
            "r              Refresh / sync",
            "w              Workspace switcher (future)",
            "p              Propose from override",
            "?              Toggle this help",
            "q / Ctrl+C     Quit",
        };
        for (lines, 0..) |line, i| {
            w.writeText(&surface, ctx, start_col + 2, @intCast(start_row + 2 + i), line, theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT));
        }

        return surface;
    }

    fn drawConfirmOverlay(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&surface, theme.PANEL);

        const box_w: u16 = 44;
        const box_h: u16 = 7;
        const start_col = (size.width -| box_w) / 2;
        const start_row = (size.height -| box_h) / 2;

        // Box background
        var row: u16 = 0;
        while (row < box_h) : (row += 1) {
            var col: u16 = 0;
            while (col < box_w) : (col += 1) {
                surface.writeCell(start_col + col, start_row + row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .fg = theme.TEXT, .bg = theme.PANEL_ALT },
                });
            }
        }

        // Border
        const s = vaxis.Style{ .fg = theme.DANGER, .bg = theme.PANEL_ALT };
        surface.writeCell(start_col, start_row, .{ .char = .{ .grapheme = "\xe2\x95\xad", .width = 1 }, .style = s });
        surface.writeCell(start_col + box_w - 1, start_row, .{ .char = .{ .grapheme = "\xe2\x95\xae", .width = 1 }, .style = s });
        surface.writeCell(start_col, start_row + box_h - 1, .{ .char = .{ .grapheme = "\xe2\x95\xb0", .width = 1 }, .style = s });
        surface.writeCell(start_col + box_w - 1, start_row + box_h - 1, .{ .char = .{ .grapheme = "\xe2\x95\xaf", .width = 1 }, .style = s });
        var c: u16 = 1;
        while (c < box_w - 1) : (c += 1) {
            surface.writeCell(start_col + c, start_row, .{ .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, .style = s });
            surface.writeCell(start_col + c, start_row + box_h - 1, .{ .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, .style = s });
        }
        var r: u16 = 1;
        while (r < box_h - 1) : (r += 1) {
            surface.writeCell(start_col, start_row + r, .{ .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, .style = s });
            surface.writeCell(start_col + box_w - 1, start_row + r, .{ .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, .style = s });
        }

        w.writeText(&surface, ctx, start_col + 2, start_row, " Confirm ", theme.boldOn(theme.PANEL_ALT, theme.DANGER));

        const action_label: []const u8 = switch (self.confirm_action) {
            .remove_member => "Remove member:",
            .delete_bundle => "Delete bundle:",
            .delete_workspace => "Delete workspace:",
            .none => "Confirm:",
        };
        w.writeText(&surface, ctx, start_col + 2, start_row + 2, action_label, theme.textOn(theme.PANEL_ALT, theme.TEXT));
        w.writeText(&surface, ctx, start_col + 2, start_row + 3, self.confirm_message, theme.boldOn(theme.PANEL_ALT, theme.ACCENT));
        w.writeText(&surface, ctx, start_col + 2, start_row + 5, "y confirm    n / Esc cancel", theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT));

        return surface;
    }

    fn drawTooSmall(self: *Dashboard, ctx: vxfw.DrawContext, size: vxfw.Size) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&surface, theme.PANEL);
        w.writeText(&surface, ctx, 1, 0, "clumsies", theme.boldOn(theme.PANEL, theme.ACCENT));
        w.writeText(&surface, ctx, 2, 2, "Terminal too small. Need at least 96x24.", theme.fgBold(theme.TEXT));
        w.writeText(&surface, ctx, 2, 4, "Resize the terminal, or press q / Ctrl-C to exit.", theme.fg(theme.TEXT_SOFT));
        return surface;
    }

    // Library: grouped by path prefix with optional bundle filter.
    // Builds a mixed list of group headers (Text) and prompt rows (TableRow).
    // library_prompt_indices maps each row index to the PROMPTS array index
    // (null for group header rows, so cursor can skip them).
    fn syncLibraryWidgets(self: *Dashboard) void {
        const filter_name: ?[]const u8 = if (self.library_bundle_filter == 0)
            null
        else
            data.BUNDLES[self.library_bundle_filter - 1].name;

        var row_idx: usize = 0;
        var last_prefix: []const u8 = "";

        for (data.PROMPTS, 0..) |p, pidx| {
            // Apply bundle filter
            if (filter_name) |fname| {
                if (std.mem.indexOf(u8, p.bundle_names, fname) == null) continue;
            }

            const prefix = data.pathPrefix(p.canonical_name);
            const name = data.promptName(p.canonical_name);

            // Insert group header when prefix changes
            if (!std.mem.eql(u8, prefix, last_prefix)) {
                if (row_idx < MAX_LIBRARY_ROWS) {
                    // Prefix headers use static padded strings to avoid
                    // needing an allocator in sync functions.
                    self.library_text_rows[row_idx] = .{
                        .text = prefixWithPad(prefix),
                        .style = theme.boldOn(theme.PANEL, theme.ACCENT),
                    };
                    self.library_widgets[row_idx] = self.library_text_rows[row_idx].widget();
                    self.library_prompt_indices[row_idx] = null;
                    row_idx += 1;
                }
                last_prefix = prefix;
            }

            // Insert prompt row
            if (row_idx < MAX_LIBRARY_ROWS) {
                const sel = pidx == self.selected_prompt;
                self.library_table_cols[row_idx] = .{
                    .{ .text = name, .flex = 1 },
                    .{ .text = p.refer_count, .flex = 0, .min_width = 4, .alignment = .right },
                    .{ .text = p.age, .flex = 0, .min_width = 3, .alignment = .right },
                };
                self.library_table_rows[row_idx] = .{
                    .columns = &self.library_table_cols[row_idx],
                    .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT),
                    .gap = 2,
                };
                self.library_widgets[row_idx] = self.library_table_rows[row_idx].widget();
                self.library_prompt_indices[row_idx] = pidx;
                row_idx += 1;
            }
        }

        self.library_row_count = row_idx;
        self.library_scroll_bars.scroll_view.children = .{ .slice = self.library_widgets[0..row_idx] };
        self.library_scroll_bars.estimated_content_height = @intCast(row_idx);
    }

    fn syncContentWidget(self: *Dashboard) void {
        self.content_text = .{
            .text = data.SAMPLE_CONTENT,
            .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT),
        };
        self.content_widget[0] = self.content_text.widget();
        self.content_scroll_bars.scroll_view.children = .{ .slice = self.content_widget[0..1] };
        self.content_scroll_bars.estimated_content_height = @intCast(@max(w.countLines(data.SAMPLE_CONTENT), 24));
    }

    fn syncHistoryWidgets(self: *Dashboard) void {
        for (data.HISTORY, 0..) |h, idx| {
            const sel = idx == @as(usize, @intCast(self.history_scroll_bars.scroll_view.cursor));
            self.history_cols[idx] = .{
                .{ .text = h.date, .flex = 0 },
                .{ .text = h.hash, .flex = 0 },
                .{ .text = h.label, .flex = 1 },
            };
            self.history_rows[idx] = .{
                .columns = &self.history_cols[idx],
                .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT),
                .gap = 2,
            };
            self.history_widgets[idx] = self.history_rows[idx].widget();
        }
        self.history_scroll_bars.scroll_view.children = .{ .slice = self.history_widgets[0..data.HISTORY.len] };
        self.history_scroll_bars.estimated_content_height = data.HISTORY.len;
    }

    // Inner width budget: panel=24min → border=2 → inner=22.
    // Row format: 1 + 9 id + 1 + 6 status + 1 = 18 fixed + truncated name. Fits.
    fn syncReviewWidgets(self: *Dashboard) void {
        self.review_scroll_bars.scroll_view.cursor = @min(self.review_scroll_bars.scroll_view.cursor, data.PROPOSALS.len - 1);
        const sel_idx = self.selectedProposalIdx();
        for (data.PROPOSALS, 0..) |p, idx| {
            const sel = idx == sel_idx;
            self.review_cols[idx] = .{
                .{ .text = p.id, .flex = 0 },
                .{ .text = p.status, .flex = 1 },
            };
            self.review_rows[idx] = .{
                .columns = &self.review_cols[idx],
                .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT),
                .gap = 2,
            };
            self.review_widgets[idx] = self.review_rows[idx].widget();
        }
        self.review_scroll_bars.scroll_view.children = .{ .slice = self.review_widgets[0..] };
        self.review_scroll_bars.estimated_content_height = data.PROPOSALS.len;
    }

    fn syncDiffWidgets(self: *Dashboard, proposal: *const data.ProposalEntry) void {
        self.review_diff_count = @min(proposal.diff.len, self.review_diff_widgets.len);
        for (0..self.review_diff_count) |idx| {
            const line = proposal.diff[idx];
            self.review_diff_rows[idx] = .{
                .text = line,
                .style = theme.textOn(diffBg(line), diffFg(line)),
                .softwrap = false,
            };
            self.review_diff_widgets[idx] = self.review_diff_rows[idx].widget();
        }
        self.review_diff_scroll_bars.scroll_view.children = .{ .slice = self.review_diff_widgets[0..self.review_diff_count] };
        self.review_diff_scroll_bars.estimated_content_height = @intCast(self.review_diff_count);
    }

    fn syncWorkspaceWidgets(self: *Dashboard) void {
        self.workspace_scroll_bars.scroll_view.cursor = @min(self.workspace_scroll_bars.scroll_view.cursor, data.WORKSPACES.len - 1);
        const ws_sel = @as(usize, @intCast(self.workspace_scroll_bars.scroll_view.cursor));
        for (data.WORKSPACES, 0..) |ws, idx| {
            const sel = idx == ws_sel;
            const sync_label = data.syncStateLabel(&ws);
            self.workspace_cols[idx] = .{
                .{ .text = ws.name, .flex = 1 },
                .{ .text = sync_label, .flex = 0 },
                .{ .text = std.fmt.bufPrint(&workspace_buf[idx], "{d}p {d}o", .{ ws.prompts, ws.overrides }) catch "?", .flex = 0, .alignment = .right },
            };
            self.workspace_rows[idx] = .{
                .columns = &self.workspace_cols[idx],
                .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT),
                .gap = 1,
            };
            self.workspace_widgets[idx] = self.workspace_rows[idx].widget();
        }
        self.workspace_scroll_bars.scroll_view.children = .{ .slice = self.workspace_widgets[0..] };
        self.workspace_scroll_bars.estimated_content_height = data.WORKSPACES.len;
    }

    // Inner width budget: panel=36min → border=2 → inner=34.
    // Row format: 1 + 16 name + 1 + 3 pct + 1 + % + 2 + 4 count = ~29. Fits.
    fn syncInsightsWidgets(self: *Dashboard) void {
        self.insights_scroll_bars.scroll_view.cursor = @min(self.insights_scroll_bars.scroll_view.cursor, data.INSIGHTS_WS.len - 1);
        const sel_idx = @as(usize, @intCast(self.insights_scroll_bars.scroll_view.cursor));
        for (data.INSIGHTS_WS, 0..) |cw, idx| {
            const sel = idx == sel_idx;
            self.insights_cols[idx] = .{
                .{ .text = cw.name, .flex = 1 },
                .{ .text = std.fmt.bufPrint(&insights_buf[idx], "{d}%", .{cw.coverage}) catch "?", .flex = 0, .alignment = .right },
                .{ .text = cw.refer_count, .flex = 0, .alignment = .right },
            };
            self.insights_rows[idx] = .{
                .columns = &self.insights_cols[idx],
                .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT),
                .gap = 2,
            };
            self.insights_widgets[idx] = self.insights_rows[idx].widget();
        }
        self.insights_scroll_bars.scroll_view.children = .{ .slice = self.insights_widgets[0..] };
        self.insights_scroll_bars.estimated_content_height = data.INSIGHTS_WS.len;
    }

    fn selectedProposalIdx(self: *const Dashboard) usize {
        return @min(@as(usize, @intCast(self.review_scroll_bars.scroll_view.cursor)), data.PROPOSALS.len - 1);
    }

    fn contextHint(self: *const Dashboard) []const u8 {
        if (self.show_help) return "Keyboard reference overlay.";
        if (self.show_detail) return switch (self.detail_tab) {
            .overview => "Prompt metadata, usage summary, and override status.",
            .content => "Full prompt body. j/k to scroll.",
            .history => "Revision list left, version detail right.",
        };
        return switch (self.selected_module) {
            .library => "Bundle facet, prompt list, and passive preview.",
            .proposals => "Proposal queue left, diff center, review lens right.",
            .workspace => "Workspace list and sync status detail.",
            .insights => "Refer coverage analysis (Phase 3, API pending).",
        };
    }

    fn selectTab(self: *Dashboard, ctx: *vxfw.EventContext, tab: TopModule) void {
        self.show_detail = false;
        self.selected_module = tab;
        self.status_line = tab.label();
        ctx.consumeAndRedraw();
    }

    fn openDetail(self: *Dashboard, ctx: *vxfw.EventContext, prompt_idx: usize, origin: TopModule, initial_tab: DetailTab) void {
        self.selected_prompt = @min(prompt_idx, data.PROMPTS.len - 1);
        self.library_scroll_bars.scroll_view.cursor = @intCast(self.selected_prompt);
        self.history_scroll_bars.scroll_view.cursor = 0;
        self.detail_origin = origin;
        self.detail_tab = initial_tab;
        self.show_detail = true;
        self.status_line = "Prompt detail opened.";
        ctx.consumeAndRedraw();
    }

    fn shiftDetailTab(self: *Dashboard, delta: i8) void {
        const current: i8 = @intCast(@intFromEnum(self.detail_tab));
        const count: i8 = @intCast(detail_tabs.len);
        const next = @mod(current + delta + count, count);
        self.detail_tab = @enumFromInt(@as(u8, @intCast(next)));
    }

    fn shiftWsTab(self: *Dashboard, delta: i8) void {
        const current: i8 = @intCast(@intFromEnum(self.ws_tab));
        const count: i8 = @intCast(ws_tabs.len);
        const next = @mod(current + delta + count, count);
        self.ws_tab = @enumFromInt(@as(u8, @intCast(next)));
    }
};

// Static row buffers to avoid per-frame allocation
// Small buffers for inline-formatted column values (counts, percentages)
fn prefixWithPad(prefix: []const u8) []const u8 {
    // Map known path prefixes to static padded strings
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "arch", " arch" },
        .{ "cmd", " cmd" },
        .{ "coding", " coding" },
        .{ "style", " style" },
        .{ "wf", " wf" },
        .{ "zig", " zig" },
    });
    return map.get(prefix) orelse prefix;
}

var workspace_buf: [data.WORKSPACES.len][32]u8 = undefined;
var insights_buf: [data.INSIGHTS_WS.len][16]u8 = undefined;

fn diffFg(line: []const u8) vaxis.Color {
    if (std.mem.startsWith(u8, line, "+")) return theme.OK;
    if (std.mem.startsWith(u8, line, "-")) return theme.DANGER;
    if (std.mem.startsWith(u8, line, "@@")) return theme.GOLD;
    return theme.TEXT_SOFT;
}

fn diffBg(line: []const u8) vaxis.Color {
    if (std.mem.startsWith(u8, line, "+")) return theme.rgb(0x1d2617);
    if (std.mem.startsWith(u8, line, "-")) return theme.rgb(0x2a1b18);
    if (std.mem.startsWith(u8, line, "@@")) return theme.PANEL_ALT;
    return theme.PANEL;
}
