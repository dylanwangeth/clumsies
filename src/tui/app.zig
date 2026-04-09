const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("theme.zig");
const w = @import("widgets.zig");
const data = @import("mock_data.zig");
const TableRow = @import("table_row.zig").TableRow;
const Column = @import("table_row.zig").Column;

const WsTab = enum(u8) {
    context,
    prompts,

    fn label(self: WsTab) []const u8 {
        return switch (self) {
            .context => "Context",
            .prompts => "Prompts",
        };
    }
};

const ws_tabs = [_]WsTab{ .context, .prompts };

const WsFocus = enum { bar, list, content };

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
    account,
    organization,
    token,

    fn label(self: SettingsTab) []const u8 {
        return switch (self) {
            .account => "Account",
            .organization => "Organization",
            .token => "Token",
        };
    }
};

const settings_tabs = [_]SettingsTab{ .account, .organization, .token };

const ConfirmAction = enum {
    none,
    remove_member,
    delete_bundle,
    delete_workspace,
};

const TopModule = enum(u8) {
    library,
    workspace,
    proposals,
    insights,

    fn label(self: TopModule) []const u8 {
        return switch (self) {
            .library => "Library",
            .workspace => "Workspace",
            .proposals => "Proposals",
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

const top_tabs = [_]TopModule{ .library, .workspace, .proposals, .insights };

// 12 prompts + up to 12 group headers = 24 max rows
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
    detail_focus_content: bool = false,
    settings_tab: SettingsTab = .account,
    settings_focus: enum { sidebar, content } = .sidebar,
    settings_content_sel: usize = 0, // cursor within content (members/teams/workspaces list)
    status_line: []const u8 = "Ready.",

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
    ws_tab: WsTab = .context,
    ws_focus: WsFocus = .bar,
    ws_sel: usize = 0,
    ws_list_sel: usize = 0,
    ws_grid_cols: u16 = 3,
    // Workspace uses manual grid + list rendering, no ScrollBars

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
            // workspace uses manual grid, no ScrollBars
            .insights_scroll_bars = w.initCursorScrollBars(theme.PANEL),
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
                                self.status_line = "Member removed (not yet implemented)";
                            },
                            .delete_bundle => {
                                self.status_line = "Bundle deleted (not yet implemented)";
                            },
                            .delete_workspace => {
                                self.status_line = "Workspace deleted (not yet implemented)";
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
                    if (key.matches('q', .{})) {
                        self.show_settings = false;
                        self.settings_focus = .sidebar;
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (self.settings_focus == .sidebar) {
                        if (key.matches(vaxis.Key.escape, .{})) {
                            self.show_settings = false;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                            self.shiftSettingsTab(1);
                            self.settings_content_sel = 0;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                            self.shiftSettingsTab(-1);
                            self.settings_content_sel = 0;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{}) or key.matches(vaxis.Key.enter, .{})) {
                            self.settings_focus = .content;
                            self.settings_content_sel = 0;
                            ctx.consumeAndRedraw();
                            return;
                        }
                    } else {
                        // Content focus
                        if (key.matches(vaxis.Key.escape, .{}) or key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
                            self.settings_focus = .sidebar;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        const max_items: usize = switch (self.settings_tab) {
                            .account => data.CURRENT_USER.workspaces.len,
                            .organization => data.MEMBERS.len + data.TEAMS.len,
                            .token => data.ALL_SCOPES.len,
                        };
                        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                            if (self.settings_content_sel + 1 < max_items)
                                self.settings_content_sel += 1;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                            if (self.settings_content_sel > 0)
                                self.settings_content_sel -= 1;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        // Action keys per section
                        if (self.settings_tab == .account) {
                            if (key.matches('c', .{})) {
                                self.status_line = "Password change (not yet implemented)";
                                ctx.consumeAndRedraw();
                                return;
                            }
                            if (key.matches(vaxis.Key.enter, .{})) {
                                const sel = @min(self.settings_content_sel, data.CURRENT_USER.workspaces.len - 1);
                                self.ws_sel = sel;
                                self.show_settings = false;
                                self.settings_focus = .sidebar;
                                self.selected_module = .workspace;
                                self.ws_focus = .list;
                                self.ws_list_sel = 0;
                                ctx.consumeAndRedraw();
                                return;
                            }
                            if (key.matches('x', .{})) {
                                self.confirm_message = "sign out";
                                self.confirm_action = .remove_member; // reuse for sign out
                                self.show_confirm = true;
                                ctx.consumeAndRedraw();
                                return;
                            }
                        }
                        if (self.settings_tab == .organization) {
                            const on_member = self.settings_content_sel < data.MEMBERS.len;
                            if (on_member) {
                                if (key.matches('r', .{})) {
                                    self.status_line = "Role change (not yet implemented)";
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches('x', .{})) {
                                    const sel = @min(self.settings_content_sel, data.MEMBERS.len - 1);
                                    self.confirm_message = data.MEMBERS[sel].username;
                                    self.confirm_action = .remove_member;
                                    self.show_confirm = true;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches('a', .{})) {
                                    self.status_line = "Invite member (not yet implemented)";
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                            } else {
                                if (key.matches('a', .{})) {
                                    self.status_line = "Create team (not yet implemented)";
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches('=', .{})) {
                                    self.status_line = "Add member to team (not yet implemented)";
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches('-', .{})) {
                                    self.status_line = "Remove member from team (not yet implemented)";
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches('x', .{})) {
                                    const team_idx = self.settings_content_sel - data.MEMBERS.len;
                                    const team_sel = @min(team_idx, data.TEAMS.len - 1);
                                    self.confirm_message = data.TEAMS[team_sel].name;
                                    self.confirm_action = .delete_bundle;
                                    self.show_confirm = true;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                            }
                        }
                        if (self.settings_tab == .token) {
                            if (key.matches('r', .{})) {
                                self.status_line = "Token refresh (not yet implemented)";
                                ctx.consumeAndRedraw();
                                return;
                            }
                            if (key.matches('x', .{})) {
                                self.confirm_message = "current token";
                                self.confirm_action = .remove_member; // reuse for revoke
                                self.show_confirm = true;
                                ctx.consumeAndRedraw();
                                return;
                            }
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

                // Detail mode: two-pane with Tab focus switching
                if (self.show_detail) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
                        self.show_detail = false;
                        self.detail_focus_content = false;
                        self.selected_module = self.detail_origin;
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (key.matches(vaxis.Key.tab, .{})) {
                        self.detail_focus_content = !self.detail_focus_content;
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (key.matches('p', .{})) {
                        self.status_line = "Propose (not yet implemented)";
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (self.detail_focus_content) {
                        // Content pane has focus: j/k scrolls content
                        try self.content_scroll_bars.scroll_view.handleEvent(ctx, event);
                    } else {
                        // Info pane has focus: h/l switches tabs, j/k for history
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
                        if (self.detail_tab == .history) {
                            try self.history_scroll_bars.scroll_view.handleEvent(ctx, event);
                        }
                    }
                    return;
                }

                // Top-level tab switching
                if (key.matches('1', .{})) return self.selectTab(ctx, .library);
                if (key.matches('2', .{})) return self.selectTab(ctx, .workspace);
                if (key.matches('3', .{})) return self.selectTab(ctx, .proposals);
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
                        // Tab toggles focus between list and detail pane
                        if (key.matches(vaxis.Key.tab, .{})) {
                            self.detail_focus_content = !self.detail_focus_content;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        // Enter from list: focus detail pane
                        if (!self.detail_focus_content and key.matches(vaxis.Key.enter, .{})) {
                            self.detail_focus_content = true;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        if (self.detail_focus_content) {
                            // Detail pane has focus
                            if (key.matches(vaxis.Key.escape, .{})) {
                                self.detail_focus_content = false;
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
                            if (self.detail_tab == .content) {
                                try self.content_scroll_bars.scroll_view.handleEvent(ctx, event);
                            }
                            if (self.detail_tab == .history) {
                                try self.history_scroll_bars.scroll_view.handleEvent(ctx, event);
                            }
                            return;
                        }
                        // List pane: j/k moves through prompts, skipping group headers.
                        const prev = self.library_scroll_bars.scroll_view.cursor;
                        try self.library_scroll_bars.scroll_view.handleEvent(ctx, event);
                        if (self.library_row_count == 0) return;

                        var pos = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
                        if (pos >= self.library_row_count) pos = self.library_row_count - 1;

                        // If landed on a group header, skip one row in direction of movement
                        if (self.library_prompt_indices[pos] == null and self.library_scroll_bars.scroll_view.cursor != prev) {
                            const moving_down = self.library_scroll_bars.scroll_view.cursor > prev;
                            if (moving_down and pos + 1 < self.library_row_count) {
                                pos += 1;
                            } else if (!moving_down and pos > 0) {
                                pos -= 1;
                            }
                            self.library_scroll_bars.scroll_view.cursor = @intCast(pos);
                            ctx.consumeAndRedraw();
                        }
                        if (self.library_prompt_indices[pos]) |pi| {
                            self.selected_prompt = pi;
                        }
                    },
                    .proposals => {
                        const prev = self.review_scroll_bars.scroll_view.cursor;
                        try self.review_scroll_bars.scroll_view.handleEvent(ctx, event);
                        if (self.review_scroll_bars.scroll_view.cursor != prev) {
                            self.status_line = "Proposal selected.";
                        }
                        if (key.matches('a', .{})) {
                            self.status_line = "Accept proposal (not yet implemented)";
                            ctx.consumeAndRedraw();
                        }
                        if (key.matches('x', .{})) {
                            self.status_line = "Reject proposal (not yet implemented)";
                            ctx.consumeAndRedraw();
                        }
                    },
                    .workspace => {
                        // Tab cycles focus: bar -> list -> content -> bar
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
                            .bar => {
                                const ws_count = data.WORKSPACES.len;
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
                                    ctx.consumeAndRedraw();
                                }
                            },
                            .list => {
                                if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
                                    self.shiftWsTab(-1);
                                    self.ws_list_sel = 0;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
                                    self.shiftWsTab(1);
                                    self.ws_list_sel = 0;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                                    const max_items: usize = switch (self.ws_tab) {
                                        .context => data.WS_CONTEXT.len,
                                        .prompts => data.WS_PROMPTS.len,
                                    };
                                    if (self.ws_list_sel + 1 < max_items) {
                                        self.ws_list_sel += 1;
                                        ctx.consumeAndRedraw();
                                    }
                                    return;
                                }
                                if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                                    if (self.ws_list_sel > 0) {
                                        self.ws_list_sel -= 1;
                                        ctx.consumeAndRedraw();
                                    }
                                    return;
                                }
                                if (key.matches(vaxis.Key.enter, .{})) {
                                    self.ws_focus = .content;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches(vaxis.Key.escape, .{})) {
                                    self.ws_focus = .bar;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                            },
                            .content => {
                                if (key.matches(vaxis.Key.escape, .{})) {
                                    self.ws_focus = .list;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                // j/k scrolls content (future: ScrollView)
                            },
                        }
                        if (key.matches('r', .{})) {
                            self.status_line = "Sync (not yet implemented)";
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
                            self.status_line = "Workspace detail (not yet implemented)";
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
        w.fillSurface(&surface, theme.PANEL_ALT);

        // Row 0: Accent band with org/ws/user context
        w.paintBand(&surface, 0, theme.ACCENT, theme.PANEL);
        w.writeText(&surface, ctx, 1, 0, "clumsies \xe2\x94\x80 acme \xe2\x94\x80 payments-api \xe2\x94\x80 alice (maintainer)", .{
            .fg = theme.PANEL,
            .bg = theme.ACCENT,
            .bold = true,
        });
        w.writeRightText(&surface, ctx, 0, "[FRESH]", .{
            .fg = theme.PANEL,
            .bg = theme.ACCENT,
            .bold = true,
        });

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
        else if (self.show_settings and self.settings_focus == .sidebar)
            "j/k section  l open  q close"
        else if (self.show_settings and self.settings_tab == .account)
            "j/k move  c change password  Enter go to workspace  x sign out  h back  q close"
        else if (self.show_settings and self.settings_tab == .organization and self.settings_content_sel < data.MEMBERS.len)
            "j/k move  a invite  r role  x remove  h back  q close"
        else if (self.show_settings and self.settings_tab == .organization)
            "j/k move  a create  = add member  - remove member  x delete  h back  q close"
        else if (self.show_settings and self.settings_tab == .token)
            "j/k move  r refresh  x revoke  h back  q close"
        else if (self.show_settings)
            "j/k move  h back  q close"
        else if (self.show_detail and self.detail_focus_content)
            "j/k scroll  g/G jump  Tab info pane  Esc back  ? help"
        else if (self.show_detail)
            "h/l tab  j/k move  Tab content pane  p propose  Esc back  ? help"
        else switch (self.selected_module) {
            .library => if (self.detail_focus_content) "h/l tab  j/k scroll  Esc list  ? help" else "j/k move  Enter detail  b bundle  S settings  ? help  q quit",
            .proposals => "j/k move  a accept  x reject  S settings  ? help  q quit",
            .workspace => switch (self.ws_focus) {
                .bar => "j/k select workspace  Tab list  r sync  ? help  q quit",
                .list => "h/l tab  j/k move  Enter content  Esc bar  ? help",
                .content => "j/k scroll  Esc list  ? help",
            },
            .insights => "j/k move  t period  S settings  ? help  q quit",
        };
        w.writeText(&surface, ctx, 1, 0, keys, theme.fg(theme.MUTED));

        // Status line on the right side of footer
        if (!std.mem.eql(u8, self.status_line, "Ready.")) {
            const sw: u16 = @intCast(ctx.stringWidth(self.status_line));
            if (ctx.max.width) |max_w| {
                if (sw + 2 < max_w) {
                    w.writeText(&surface, ctx, max_w - sw - 1, 0, self.status_line, theme.fg(theme.ACCENT_SOFT));
                }
            }
        }
        return surface;
    }

    // Library: master-detail. Left = grouped prompt list, right = selected prompt detail.
    // Enter / Tab switches focus between list and detail pane.
    fn drawLibrary(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        self.syncLibraryWidgets();

        const list_w: u16 = size.width / 3;
        const detail_w: u16 = size.width - list_w - 1;
        const p = &data.PROMPTS[self.selected_prompt];

        const list_ctx = ctx.withConstraints(.{ .width = list_w, .height = size.height }, .{ .width = list_w, .height = size.height });
        const detail_ctx = ctx.withConstraints(.{ .width = detail_w, .height = size.height }, .{ .width = detail_w, .height = size.height });

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawPromptTable(list_ctx) };
        children[1] = .{ .origin = .{ .row = 0, .col = list_w + 1 }, .surface = try self.drawLibraryDetail(detail_ctx, p) };
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
        const subtitle = try std.fmt.allocPrint(ctx.arena, "{d} prompts  bundle: {s}  / search  b filter", .{ data.PROMPTS.len, bundle_label });
        const list_border = if (!self.detail_focus_content) theme.ACCENT else theme.BORDER;
        const panel: w.Panel = .{
            .owner = self.widget(),
            .title = "Library",
            .subtitle = subtitle,
            .background = theme.PANEL,
            .border_color = list_border,
            .child = self.library_scroll_bars.widget(),
        };
        var surface = try panel.draw(ctx);
        return w.applyCursorOverlay(ctx, &surface, &self.library_scroll_bars.scroll_view);
    }

    // Library right pane: detail for selected prompt with Overview/Content/History tabs.
    fn drawLibraryDetail(self: *Dashboard, ctx: vxfw.DrawContext, p: *const data.PromptEntry) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        const border_color = if (self.detail_focus_content) theme.ACCENT else theme.BORDER;
        w.fillSurface(&surface, theme.PANEL);
        w.drawBorder(&surface, border_color, theme.PANEL);

        // Row 0: inner tabs + prompt name
        var tab_col: u16 = 2;
        for (detail_tabs) |tab| {
            tab_col = w.drawInnerTabBadge(&surface, ctx, 0, tab_col, tab.label(), tab == self.detail_tab);
            tab_col +|= 1;
        }
        w.writeRightText(&surface, ctx, 0, p.canonical_name, theme.textOn(theme.PANEL, theme.MUTED));

        const inner_h = ctx.max.height.? -| 2;
        const inner_w = ctx.max.width.? -| 4;

        switch (self.detail_tab) {
            .overview => {
                const kv_col: u16 = 2;
                var kv_row: u16 = 2;
                w.writeText(&surface, ctx, kv_col, kv_row, p.summary, theme.fg(theme.TEXT_SOFT));
                kv_row += 2;
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "hash", p.content_hash, 8);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "updated", p.updated, 8);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "source", "acme", 8);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "refer", p.refer_count, 8);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "override", "local (payments-api)", 8);
                kv_row += 1;
                kv_row = w.writeSectionHeader(&surface, ctx, kv_col, kv_row, "Top Constraints");
                const top_n = @min(p.constraint_count, 3);
                var ci: u8 = 0;
                while (ci < top_n) : (ci += 1) {
                    const cid = try std.fmt.allocPrint(ctx.arena, "c-{d}", .{ci + 1});
                    kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, cid, "(mock refer data)", 5);
                }
                if (p.constraint_count > 3) {
                    w.writeText(&surface, ctx, kv_col, kv_row, try std.fmt.allocPrint(ctx.arena, "... +{d} more", .{p.constraint_count - 3}), theme.fg(theme.MUTED));
                }
            },
            .content => {
                self.syncContentWidget();
                const child_ctx = ctx.withConstraints(.{ .width = inner_w, .height = inner_h }, .{ .width = inner_w, .height = inner_h });
                const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                children[0] = .{ .origin = .{ .row = 2, .col = 2 }, .surface = try self.content_scroll_bars.widget().draw(child_ctx) };
                surface.children = children;
            },
            .history => {
                self.syncHistoryWidgets();
                const list_ctx = ctx.withConstraints(.{ .width = inner_w, .height = inner_h }, .{ .width = inner_w, .height = inner_h });
                self.history_scroll_bars.scroll_view.draw_cursor = false;
                defer self.history_scroll_bars.scroll_view.draw_cursor = true;

                var list_surface = try self.history_scroll_bars.widget().draw(list_ctx);
                const sv = &self.history_scroll_bars.scroll_view;
                if (sv.cursor >= sv.scroll.top) {
                    const vis_row = sv.cursor - sv.scroll.top;
                    const crow: i17 = @intCast(vis_row);
                    if (crow < list_surface.size.height) {
                        const cbuf = try ctx.arena.alloc(vaxis.Cell, 1);
                        cbuf[0] = .{ .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 }, .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL } };
                        const csurface: vxfw.Surface = .{ .size = .{ .width = 1, .height = 1 }, .widget = list_surface.widget, .buffer = cbuf, .children = &.{} };
                        const old = list_surface.children;
                        const new_ch = try ctx.arena.alloc(vxfw.SubSurface, old.len + 1);
                        @memcpy(new_ch[0..old.len], old);
                        new_ch[old.len] = .{ .origin = .{ .col = 0, .row = crow }, .surface = csurface, .z_index = 1 };
                        list_surface.children = new_ch;
                    }
                }
                const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                children[0] = .{ .origin = .{ .row = 2, .col = 1 }, .surface = list_surface };
                surface.children = children;
            },
        }
        return surface;
    }

    // Old Prompt Detail (kept for non-Library drill-down from other modules)
    fn drawPromptDetail(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const p = &data.PROMPTS[self.selected_prompt];

        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        const info_w: u16 = size.width / 3;
        const content_w: u16 = size.width - info_w - 1;

        const info_ctx = ctx.withConstraints(.{ .width = info_w, .height = size.height }, .{ .width = info_w, .height = size.height });
        const content_ctx = ctx.withConstraints(.{ .width = content_w, .height = size.height }, .{ .width = content_w, .height = size.height });

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawDetailInfo(info_ctx, p) };
        children[1] = .{ .origin = .{ .row = 0, .col = info_w + 1 }, .surface = try self.drawDetailContent(content_ctx, p) };
        root.children = children;
        return root;
    }

    fn drawDetailInfo(self: *Dashboard, ctx: vxfw.DrawContext, p: *const data.PromptEntry) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        w.fillSurface(&surface, theme.PANEL);
        const info_border = if (!self.detail_focus_content) theme.ACCENT else theme.BORDER;
        w.drawBorder(&surface, info_border, theme.PANEL);

        // Row 0: inner tabs
        var col: u16 = 2;
        for (detail_tabs) |tab| {
            col = w.drawInnerTabBadge(&surface, ctx, 0, col, tab.label(), tab == self.detail_tab);
            col +|= 1;
        }

        const inner_h = ctx.max.height.? -| 3;
        const inner_w = ctx.max.width.? -| 2;

        switch (self.detail_tab) {
            .overview => {
                const kv_col: u16 = 2;
                var kv_row: u16 = 2;
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "hash", p.content_hash, 8);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "updated", p.updated, 8);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "source", "acme", 8);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "override", "local (payments-api)", 8);
                kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, "refer", p.refer_count, 8);
                kv_row += 1;
                kv_row = w.writeSectionHeader(&surface, ctx, kv_col, kv_row, "Top Constraints");
                // Mock: show constraint count, real data from GET /api/stats/prompt/{id}
                const ccount = p.constraint_count;
                const top_n = @min(ccount, 3);
                var ci: u8 = 0;
                while (ci < top_n) : (ci += 1) {
                    const cid = try std.fmt.allocPrint(ctx.arena, "c-{d}", .{ci + 1});
                    const cval = try std.fmt.allocPrint(ctx.arena, "(mock refer data)", .{});
                    kv_row = w.writeKv(&surface, ctx, kv_col, kv_row, cid, cval, 5);
                }
                if (ccount > 3) {
                    w.writeText(&surface, ctx, kv_col, kv_row, try std.fmt.allocPrint(ctx.arena, "... +{d} more", .{ccount - 3}), theme.fg(theme.MUTED));
                    kv_row += 1;
                }
                kv_row += 1;
                kv_row = w.writeSectionHeader(&surface, ctx, kv_col, kv_row, "Local Override");
                w.writeText(&surface, ctx, kv_col, kv_row, "Detected in ws: payments-api", theme.fg(theme.TEXT_SOFT));
                kv_row += 1;
                w.writeText(&surface, ctx, kv_col, kv_row, "Press p to propose this override", theme.fg(theme.MUTED));
            },
            .content => {
                self.syncContentWidget();
                const child_ctx = ctx.withConstraints(.{ .width = inner_w, .height = inner_h }, .{ .width = inner_w, .height = inner_h });
                const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                children[0] = .{ .origin = .{ .row = 2, .col = 2 }, .surface = try self.content_scroll_bars.widget().draw(child_ctx) };
                surface.children = children;
            },
            .history => {
                self.syncHistoryWidgets();
                const list_ctx = ctx.withConstraints(.{ .width = inner_w, .height = inner_h }, .{ .width = inner_w, .height = inner_h });

                self.history_scroll_bars.scroll_view.draw_cursor = false;
                defer self.history_scroll_bars.scroll_view.draw_cursor = true;

                var list_surface = try self.history_scroll_bars.widget().draw(list_ctx);
                const sv = &self.history_scroll_bars.scroll_view;
                if (sv.cursor >= sv.scroll.top) {
                    const vis_row = sv.cursor - sv.scroll.top;
                    const crow: i17 = @intCast(vis_row);
                    if (crow < list_surface.size.height) {
                        const cbuf = try ctx.arena.alloc(vaxis.Cell, 1);
                        cbuf[0] = .{
                            .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
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

                const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                children[0] = .{ .origin = .{ .row = 2, .col = 1 }, .surface = list_surface };
                surface.children = children;
            },
        }

        return surface;
    }

    // Right pane: always-visible prompt content with border.
    // Border highlight indicates focus state.
    fn drawDetailContent(self: *Dashboard, ctx: vxfw.DrawContext, p: *const data.PromptEntry) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        w.fillSurface(&surface, theme.PANEL);
        const border_color = if (self.detail_focus_content) theme.ACCENT else theme.BORDER;
        w.drawBorder(&surface, border_color, theme.PANEL);
        w.writeText(&surface, ctx, 2, 0, p.canonical_name, theme.boldOn(theme.PANEL, theme.TEXT));

        self.syncContentWidget();
        const inner_w = ctx.max.width.? -| 4;
        const inner_h = ctx.max.height.? -| 2;
        const child_ctx = ctx.withConstraints(
            .{ .width = inner_w, .height = inner_h },
            .{ .width = inner_w, .height = inner_h },
        );
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 1, .col = 2 }, .surface = try self.content_scroll_bars.widget().draw(child_ctx) };
        surface.children = children;
        return surface;
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

    // Workspace: top workspace bar + bottom master-detail (list | content).
    // Tab cycles focus: workspace bar -> list -> content -> bar.
    fn drawWorkspaceStatus(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        const ws_idx = @min(self.ws_sel, data.WORKSPACES.len - 1);
        const ws = &data.WORKSPACES[ws_idx];

        // Top: workspace bar with grid layout (each card = 2 rows: name + status)
        // Fixed height: border(1) + 2 content rows per grid row + border(1)
        const inner_w = size.width -| 2;
        const cols: u16 = if (inner_w >= 120) 4 else if (inner_w >= 80) 3 else 2;
        self.ws_grid_cols = cols;
        const card_w: u16 = inner_w / cols;
        const ws_count: u16 = @intCast(data.WORKSPACES.len);
        const grid_rows: u16 = (ws_count + cols - 1) / cols;
        const bar_h: u16 = 1 + grid_rows + 1; // border + rows + border

        const bar_border = if (self.ws_focus == .bar) theme.ACCENT else theme.BORDER;
        var bar = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = size.width, .height = bar_h });
        w.fillSurface(&bar, theme.PANEL);
        w.drawBorder(&bar, bar_border, theme.PANEL);
        w.writeText(&bar, ctx, 2, 0, "Workspaces", theme.boldOn(theme.PANEL, theme.TEXT));

        for (data.WORKSPACES, 0..) |wsi, i| {
            const is_sel = i == ws_idx;
            const grid_col: u16 = @intCast(i % cols);
            const grid_row: u16 = @intCast(i / cols);
            const x = 1 + grid_col * card_w;
            const y = 1 + grid_row;

            // Cursor indicator (same style as Library)
            if (is_sel) {
                bar.writeCell(x, y, .{
                    .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                    .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                });
            }

            const name_x = x + 2;
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

        // Bottom: master-detail (list | content)
        const body_h = size.height - bar_h;
        const list_w: u16 = size.width / 3;
        const detail_w: u16 = size.width - list_w - 1;

        const list_ctx = ctx.withConstraints(.{ .width = list_w, .height = body_h }, .{ .width = list_w, .height = body_h });
        const detail_ctx = ctx.withConstraints(.{ .width = detail_w, .height = body_h }, .{ .width = detail_w, .height = body_h });

        const list_surface = try self.drawWsList(list_ctx);
        const detail_surface = try self.drawWsDetail(detail_ctx, ws);

        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = bar };
        children[1] = .{ .origin = .{ .row = bar_h, .col = 0 }, .surface = list_surface };
        children[2] = .{ .origin = .{ .row = bar_h, .col = list_w + 1 }, .surface = detail_surface };
        root.children = children;
        return root;
    }

    fn drawWsList(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        // Context/Prompts/Overrides item list with inner tabs
        const list_border = if (self.ws_focus == .list) theme.ACCENT else theme.BORDER;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        w.fillSurface(&surface, theme.PANEL);
        w.drawBorder(&surface, list_border, theme.PANEL);

        // Row 0: inner tabs
        var tab_col: u16 = 2;
        for (ws_tabs) |tab| {
            tab_col = w.drawInnerTabBadge(&surface, ctx, 0, tab_col, tab.label(), tab == self.ws_tab);
            tab_col +|= 1;
        }

        const inner_h = ctx.max.height.? -| 2;

        switch (self.ws_tab) {
            .context => {
                var kv_row: u16 = 2;
                for (data.WS_CONTEXT, 0..) |f, i| {
                    const sel = i == self.ws_list_sel;
                    const name_style = if (sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
                    if (sel) {
                        surface.writeCell(1, kv_row, .{
                            .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                            .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                        });
                    }
                    // Name + (modified) inline marker
                    const label = if (f.modified)
                        try std.fmt.allocPrint(ctx.arena, "{s} (modified)", .{f.path})
                    else
                        f.path;
                    w.writeText(&surface, ctx, 3, kv_row, label, name_style);
                    if (f.modified) {
                        // Color just the "(modified)" part
                        const path_w: u16 = @intCast(ctx.stringWidth(f.path));
                        w.writeText(&surface, ctx, 3 + path_w + 1, kv_row, "(modified)", theme.fg(theme.WARN));
                    }
                    // Right side: always show size
                    if (ctx.max.width) |max_w| {
                        const sw: u16 = @intCast(ctx.stringWidth(f.size));
                        if (sw + 3 < max_w) w.writeText(&surface, ctx, max_w - sw - 2, kv_row, f.size, theme.fg(theme.MUTED));
                    }
                    kv_row += 1;
                    if (kv_row >= inner_h + 2) break;
                }
            },
            .prompts => {
                var kv_row: u16 = 2;
                for (data.WS_PROMPTS, 0..) |p, i| {
                    const sel = i == self.ws_list_sel;
                    const name_style = if (sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
                    if (sel) {
                        surface.writeCell(1, kv_row, .{
                            .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                            .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                        });
                    }
                    // Name + (modified) inline marker
                    const label = if (p.has_override)
                        try std.fmt.allocPrint(ctx.arena, "{s} (modified)", .{p.name})
                    else
                        p.name;
                    w.writeText(&surface, ctx, 3, kv_row, label, name_style);
                    if (p.has_override) {
                        const name_w: u16 = @intCast(ctx.stringWidth(p.name));
                        w.writeText(&surface, ctx, 3 + name_w + 1, kv_row, "(modified)", theme.fg(theme.WARN));
                    }
                    // Right side: always show state
                    if (ctx.max.width) |max_w| {
                        const sw: u16 = @intCast(ctx.stringWidth(p.state));
                        if (sw + 3 < max_w) w.writeText(&surface, ctx, max_w - sw - 2, kv_row, p.state, theme.fg(theme.MUTED));
                    }
                    kv_row += 1;
                    if (kv_row >= inner_h + 2) break;
                }
            },
        }
        return surface;
    }

    // Workspace content pane: shows selected item's content
    fn drawWsDetail(self: *Dashboard, ctx: vxfw.DrawContext, ws: *const data.WorkspaceEntry) std.mem.Allocator.Error!vxfw.Surface {
        _ = ws;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        const content_border = if (self.ws_focus == .content) theme.ACCENT else theme.BORDER;
        w.fillSurface(&surface, theme.PANEL);
        w.drawBorder(&surface, content_border, theme.PANEL);

        const sel = self.ws_list_sel;

        // Title: selected item name
        const title: []const u8 = switch (self.ws_tab) {
            .context => if (sel < data.WS_CONTEXT.len) data.WS_CONTEXT[sel].path else "no files",
            .prompts => if (sel < data.WS_PROMPTS.len) data.WS_PROMPTS[sel].name else "no prompts",
        };
        // Title with diff marker (context branch or prompt override)
        const has_diff = switch (self.ws_tab) {
            .context => sel < data.WS_CONTEXT.len and data.WS_CONTEXT[sel].modified,
            .prompts => sel < data.WS_PROMPTS.len and data.WS_PROMPTS[sel].has_override,
        };
        if (has_diff) {
            const marker = try std.fmt.allocPrint(ctx.arena, "{s} (modified)", .{title});
            w.writeText(&surface, ctx, 2, 0, marker, theme.boldOn(theme.PANEL, theme.WARN));
        } else {
            w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
        }

        var kv_row: u16 = 2;
        const max_row = ctx.max.height.? -| 1;

        switch (self.ws_tab) {
            .context => {
                if (sel < data.WS_CONTEXT.len) {
                    const f = &data.WS_CONTEXT[sel];
                    if (f.modified and f.branch_diff.len > 0) {
                        // Show branch diff (same GitHub-style as prompts)
                        for (f.branch_diff) |line| {
                            if (kv_row >= max_row) break;
                            const line_color = if (std.mem.startsWith(u8, line, "+"))
                                theme.OK
                            else if (std.mem.startsWith(u8, line, "-"))
                                theme.DANGER
                            else
                                theme.TEXT_SOFT;
                            const line_bg = if (std.mem.startsWith(u8, line, "+"))
                                theme.rgb(0x1d2617)
                            else if (std.mem.startsWith(u8, line, "-"))
                                theme.rgb(0x2a1b18)
                            else
                                theme.PANEL;
                            w.writeText(&surface, ctx, 2, kv_row, line, .{ .fg = line_color, .bg = line_bg });
                            kv_row += 1;
                        }
                    } else {
                        // No branch changes - show file content
                        var line_iter = std.mem.splitScalar(u8, data.SAMPLE_CONTENT, '\n');
                        while (line_iter.next()) |line| {
                            if (kv_row >= max_row) break;
                            w.writeText(&surface, ctx, 2, kv_row, line, theme.fg(theme.TEXT_SOFT));
                            kv_row += 1;
                        }
                    }
                }
            },
            .prompts => {
                if (sel < data.WS_PROMPTS.len) {
                    const p = &data.WS_PROMPTS[sel];
                    if (p.has_override and p.override_diff.len > 0) {
                        // Show diff (GitHub-style colored lines)
                        for (p.override_diff) |line| {
                            if (kv_row >= max_row) break;
                            const line_color = if (std.mem.startsWith(u8, line, "+"))
                                theme.OK
                            else if (std.mem.startsWith(u8, line, "-"))
                                theme.DANGER
                            else
                                theme.TEXT_SOFT;
                            const line_bg = if (std.mem.startsWith(u8, line, "+"))
                                theme.rgb(0x1d2617)
                            else if (std.mem.startsWith(u8, line, "-"))
                                theme.rgb(0x2a1b18)
                            else
                                theme.PANEL;
                            w.writeText(&surface, ctx, 2, kv_row, line, .{ .fg = line_color, .bg = line_bg });
                            kv_row += 1;
                        }
                    } else {
                        // Show prompt body (no override)
                        var line_iter = std.mem.splitScalar(u8, data.SAMPLE_CONTENT, '\n');
                        while (line_iter.next()) |line| {
                            if (kv_row >= max_row) break;
                            w.writeText(&surface, ctx, 2, kv_row, line, theme.fg(theme.TEXT_SOFT));
                            kv_row += 1;
                        }
                    }
                }
            },
        }
        return surface;
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

    // Settings: vertical sidebar + content pane (web-style layout)
    fn drawSettings(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        // Sidebar (fixed width)
        const sidebar_w: u16 = 18;
        const sidebar_border = if (self.settings_focus == .sidebar) theme.ACCENT else theme.BORDER;
        var sidebar = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = sidebar_w, .height = size.height });
        w.fillSurface(&sidebar, theme.PANEL);
        w.drawBorder(&sidebar, sidebar_border, theme.PANEL);
        w.writeText(&sidebar, ctx, 2, 0, "Settings", theme.boldOn(theme.PANEL, theme.TEXT));

        var row: u16 = 2;
        for (settings_tabs) |tab| {
            const is_sel = tab == self.settings_tab;
            if (is_sel) {
                sidebar.writeCell(1, row, .{
                    .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                    .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                });
            }
            const style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
            w.writeText(&sidebar, ctx, 3, row, tab.label(), style);
            row += 1;
        }

        // Content pane
        const content_w = size.width -| sidebar_w -| 1;
        const content_ctx = ctx.withConstraints(
            .{ .width = content_w, .height = size.height },
            .{ .width = content_w, .height = size.height },
        );
        const content = switch (self.settings_tab) {
            .account => try self.drawSettingsAccount(content_ctx),
            .organization => try self.drawSettingsOrg(content_ctx),
            .token => try self.drawSettingsToken(content_ctx),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = sidebar };
        children[1] = .{ .origin = .{ .row = 0, .col = sidebar_w + 1 }, .surface = content };
        root.children = children;
        return root;
    }

    fn drawSettingsAccount(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const focused = self.settings_focus == .content;
        const user = data.CURRENT_USER;
        const cfg = data.CLIENT_CONFIG;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&surface, theme.PANEL);
        w.drawBorder(&surface, if (focused) theme.ACCENT else theme.BORDER, theme.PANEL);
        w.writeText(&surface, ctx, 2, 0, "Account", theme.boldOn(theme.PANEL, theme.TEXT));

        var row: u16 = 2;

        // Profile
        row = w.writeSectionHeader(&surface, ctx, 2, row, "Profile");
        row = w.writeKv(&surface, ctx, 4, row, "Username", user.username, 14);
        row = w.writeKv(&surface, ctx, 4, row, "User ID", user.user_id, 14);
        const role_color = if (std.mem.eql(u8, user.role, "maintainer")) theme.ACCENT else theme.TEXT_SOFT;
        w.writeText(&surface, ctx, 4, row, "Role", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 19, row, user.role, theme.fg(role_color));
        row += 2;

        // Connection
        row = w.writeSectionHeader(&surface, ctx, 2, row, "Connection");
        row = w.writeKv(&surface, ctx, 4, row, "Server", cfg.server_url, 14);
        row = w.writeKv(&surface, ctx, 4, row, "Sync", cfg.sync_strategy, 14);
        w.writeText(&surface, ctx, 4, row, "Token", theme.fg(theme.MUTED));
        const token_color = if (std.mem.eql(u8, cfg.token_status, "active")) theme.OK else theme.DANGER;
        const token_info = try std.fmt.allocPrint(ctx.arena, "{s}, expires {s}", .{ cfg.token_status, cfg.token_expires });
        w.writeText(&surface, ctx, 19, row, token_info, theme.fg(token_color));
        row += 2;

        // Security
        row = w.writeSectionHeader(&surface, ctx, 2, row, "Security");
        w.writeText(&surface, ctx, 4, row, "Password", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 19, row, "********", theme.fg(theme.TEXT_SOFT));
        w.writeText(&surface, ctx, 30, row, "[ Change ]", theme.fg(theme.ACCENT_SOFT));
        row += 1;
        w.writeText(&surface, ctx, 4, row, "Sessions", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 19, row, "1 active", theme.fg(theme.OK));
        row += 2;

        // My Workspaces with tree-expanded paths
        row = w.writeSectionHeader(&surface, ctx, 2, row, try std.fmt.allocPrint(ctx.arena, "My Workspaces ({d})", .{user.workspaces.len}));
        const sel = @min(self.settings_content_sel, user.workspaces.len - 1);
        for (user.workspaces, 0..) |ws_access, i| {
            if (row >= size.height -| 4) break;
            const is_sel = i == sel and focused;
            if (is_sel) {
                surface.writeCell(1, row, .{
                    .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                    .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                });
            }
            const name_style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
            w.writeText(&surface, ctx, 4, row, ws_access.name, name_style);
            const badge_fg = switch (ws_access.level) {
                .read => theme.MUTED,
                .write => theme.OK,
                .admin => theme.ACCENT,
            };
            const level_label = switch (ws_access.level) {
                .read => "read",
                .write => "write",
                .admin => "admin",
            };
            w.writeText(&surface, ctx, 24, row, level_label, theme.fg(badge_fg));
            row += 1;

            // Expand paths for selected workspace
            if (is_sel and ws_access.paths.len > 0) {
                for (ws_access.paths, 0..) |path, pi| {
                    if (row >= size.height -| 4) break;
                    const is_last = pi + 1 == ws_access.paths.len;
                    const connector = if (is_last) "\xe2\x94\x94" else "\xe2\x94\x9c"; // └ or ├
                    w.writeText(&surface, ctx, 6, row, connector, theme.fg(theme.BORDER));
                    w.writeText(&surface, ctx, 8, row, path, theme.fg(theme.MUTED));
                    row += 1;
                }
            } else if (is_sel and ws_access.paths.len == 0) {
                w.writeText(&surface, ctx, 6, row, "\xe2\x94\x94", theme.fg(theme.BORDER)); // └
                w.writeText(&surface, ctx, 8, row, "(no local paths)", theme.fg(theme.MUTED));
                row += 1;
            }
        }
        row += 1;

        // Danger zone
        if (row + 2 < size.height) {
            row = w.writeSectionHeader(&surface, ctx, 2, row, "Danger Zone");
            w.writeText(&surface, ctx, 4, row, "[ Sign Out ]", theme.fg(theme.DANGER));
            w.writeText(&surface, ctx, 19, row, "Revoke current token and exit", theme.fg(theme.MUTED));
        }
        return surface;
    }

    fn drawSettingsOrg(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const focused = self.settings_focus == .content;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&surface, theme.PANEL);
        w.drawBorder(&surface, if (focused) theme.ACCENT else theme.BORDER, theme.PANEL);
        w.writeText(&surface, ctx, 2, 0, "Organization", theme.boldOn(theme.PANEL, theme.TEXT));

        var row: u16 = 2;
        const sel = self.settings_content_sel;

        // Members section
        var maintainer_count: u16 = 0;
        for (data.MEMBERS) |m| {
            if (std.mem.eql(u8, m.role, "maintainer")) maintainer_count += 1;
        }
        const members_title = try std.fmt.allocPrint(ctx.arena, "Members ({d}  {d} maintainer, {d} member)", .{ data.MEMBERS.len, maintainer_count, data.MEMBERS.len - maintainer_count });
        row = w.writeSectionHeader(&surface, ctx, 2, row, members_title);

        w.writeText(&surface, ctx, 4, row, "USERNAME", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 18, row, "ROLE", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 30, row, "TEAMS", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 52, row, "JOINED", theme.fg(theme.MUTED));
        row += 1;

        for (data.MEMBERS, 0..) |m, i| {
            const is_sel = i == sel and focused;
            if (is_sel) {
                surface.writeCell(1, row, .{
                    .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                    .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                });
            }
            const name_style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
            w.writeText(&surface, ctx, 4, row, m.username, name_style);
            const role_color = if (std.mem.eql(u8, m.role, "maintainer")) theme.ACCENT else theme.TEXT_SOFT;
            w.writeText(&surface, ctx, 18, row, m.role, theme.fg(role_color));
            w.writeText(&surface, ctx, 30, row, m.teams, theme.fg(theme.TEXT_SOFT));
            w.writeText(&surface, ctx, 52, row, m.joined, theme.fg(theme.MUTED));
            row += 1;
            if (row >= size.height -| 10) break;
        }
        row += 1;

        // Teams section
        const teams_title = try std.fmt.allocPrint(ctx.arena, "Teams ({d})", .{data.TEAMS.len});
        row = w.writeSectionHeader(&surface, ctx, 2, row, teams_title);

        w.writeText(&surface, ctx, 4, row, "NAME", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 18, row, "MEMBERS", theme.fg(theme.MUTED));
        row += 1;

        for (data.TEAMS, 0..) |team, i| {
            const team_idx = data.MEMBERS.len + i;
            const is_sel = team_idx == sel and focused;
            if (is_sel) {
                surface.writeCell(1, row, .{
                    .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                    .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                });
            }
            const name_style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
            w.writeText(&surface, ctx, 4, row, team.name, name_style);
            var names_buf: std.ArrayList(u8) = .empty;
            for (team.member_usernames, 0..) |username, mi| {
                try names_buf.appendSlice(ctx.arena, username);
                if (mi + 1 < team.member_usernames.len) try names_buf.appendSlice(ctx.arena, ", ");
            }
            w.writeText(&surface, ctx, 18, row, try ctx.arena.dupe(u8, names_buf.items), theme.fg(theme.MUTED));
            row += 1;
        }
        row += 1;

        return surface;
    }

    fn drawSettingsToken(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const focused = self.settings_focus == .content;
        const t = data.CURRENT_TOKEN;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&surface, theme.PANEL);
        w.drawBorder(&surface, if (focused) theme.ACCENT else theme.BORDER, theme.PANEL);
        w.writeText(&surface, ctx, 2, 0, "Token", theme.boldOn(theme.PANEL, theme.TEXT));

        var row: u16 = 2;
        // Token info
        var active_count: u16 = 0;
        for (data.ALL_SCOPES) |scope_def| {
            for (t.scopes) |active| {
                if (std.mem.eql(u8, scope_def.name, active)) {
                    active_count += 1;
                    break;
                }
            }
        }
        row = w.writeKv(&surface, ctx, 2, row, "Expires", t.expires, 14);
        const scope_summary = try std.fmt.allocPrint(ctx.arena, "{d} / {d} scopes active", .{ active_count, data.ALL_SCOPES.len });
        row = w.writeKv(&surface, ctx, 2, row, "Permissions", scope_summary, 14);
        row += 1;

        // Scope permission matrix
        row = w.writeSectionHeader(&surface, ctx, 2, row, "Scope Permissions");
        const sel = @min(self.settings_content_sel, data.ALL_SCOPES.len - 1);
        for (data.ALL_SCOPES, 0..) |scope_def, i| {
            if (row >= size.height -| 5) break;
            const is_sel = i == sel and focused;
            if (is_sel) {
                surface.writeCell(1, row, .{
                    .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                    .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                });
            }
            // Check if this scope is active
            var is_active = false;
            for (t.scopes) |active| {
                if (std.mem.eql(u8, scope_def.name, active)) {
                    is_active = true;
                    break;
                }
            }
            const check = if (is_active) "\xe2\x9c\x93" else "\xe2\x94\x80";
            const check_color = if (is_active) theme.OK else theme.MUTED;
            w.writeText(&surface, ctx, 4, row, check, theme.fg(check_color));
            const name_style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else if (is_active) theme.fg(theme.TEXT) else theme.fg(theme.TEXT_SOFT);
            w.writeText(&surface, ctx, 6, row, scope_def.name, name_style);
            w.writeText(&surface, ctx, 24, row, scope_def.description, theme.fg(if (is_active) theme.TEXT_SOFT else theme.MUTED));
            row += 1;
        }
        row += 1;

        // Info note
        if (row + 1 < size.height) {
            w.writeText(&surface, ctx, 2, row, "Effective permissions = min(org role, token scopes)", theme.fg(theme.MUTED));
        }
        return surface;
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

            // Insert prompt row (name + stats)
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

        // Ensure cursor is on a prompt row, not a group header or summary
        var cur = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
        while (cur < row_idx and self.library_prompt_indices[cur] == null) {
            cur += 1;
        }
        self.library_scroll_bars.scroll_view.cursor = @intCast(cur);
        if (cur < row_idx) {
            if (self.library_prompt_indices[cur]) |pi| {
                self.selected_prompt = pi;
            }
        }
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

    // Workspace grid uses manual rendering, no sync function needed

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

// workspace_buf removed: workspace uses manual grid rendering
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
