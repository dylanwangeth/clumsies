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
    insights,
    workspace,
    library,

    fn label(self: TopModule) []const u8 {
        return switch (self) {
            .insights => "Insights",
            .workspace => "Workspace",
            .library => "Library",
        };
    }
};

const PrFilter = enum {
    open,
    all,
    closed,

    fn label(self: PrFilter) []const u8 {
        return switch (self) {
            .open => "open",
            .all => "all",
            .closed => "closed",
        };
    }

    fn next(self: PrFilter) PrFilter {
        return switch (self) {
            .open => .all,
            .all => .closed,
            .closed => .open,
        };
    }
};

const DetailTab = enum(u8) {
    content,
    pull_requests,

    fn label(self: DetailTab) []const u8 {
        return switch (self) {
            .content => "Content",
            .pull_requests => "Pull Requests",
        };
    }
};

const top_tabs = [_]TopModule{ .insights, .workspace, .library };

// 12 prompts + up to 12 group headers = 24 max rows
const MAX_LIBRARY_ROWS = data.PROMPTS.len + 12;
const detail_tabs = [_]DetailTab{ .content, .pull_requests };

pub const Dashboard = struct {
    selected_module: TopModule = .insights,
    selected_prompt: usize = 0,
    show_help: bool = false,
    show_detail: bool = false,
    show_settings: bool = false,
    show_confirm: bool = false,
    confirm_message: []const u8 = "",
    confirm_action: ConfirmAction = .none,
    detail_origin: TopModule = .library,
    detail_tab: DetailTab = .content,
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
    library_table_cols: [MAX_LIBRARY_ROWS][2]Column = undefined,

    content_scroll_bars: vxfw.ScrollBars,
    content_widget: [1]vxfw.Widget = undefined,
    content_text: vxfw.Text = .{ .text = "" },

    // PR list within Prompt Detail
    pr_filter: PrFilter = .open,
    pr_scroll_bars: vxfw.ScrollBars,
    pr_widgets: [data.PULL_REQUESTS.len * 2]vxfw.Widget = undefined,
    pr_table_rows: [data.PULL_REQUESTS.len]TableRow = undefined,
    pr_table_cols: [data.PULL_REQUESTS.len][4]Column = undefined,
    pr_text_rows: [data.PULL_REQUESTS.len]vxfw.Text = undefined,
    pr_indices: [data.PULL_REQUESTS.len * 2]?usize = .{null} ** (data.PULL_REQUESTS.len * 2),
    pr_row_count: usize = 0,
    // PR drill-down state
    show_pr_diff: bool = false,
    selected_pr_idx: usize = 0,
    pr_diff_scroll_bars: vxfw.ScrollBars,
    pr_diff_widgets: [32]vxfw.Widget = undefined,
    pr_diff_rows: [32]vxfw.Text = undefined,
    pr_diff_count: usize = 0,
    // Comment editor state
    show_comment_editor: bool = false,
    comment_input_buf: [256]u8 = .{0} ** 256,
    comment_input_len: usize = 0,

    // Workspace Status
    ws_tab: WsTab = .context,
    ws_focus: WsFocus = .bar,
    ws_sel: usize = 0,
    ws_list_sel: usize = 0,
    ws_grid_cols: u16 = 3,
    ws_show_diff: bool = false,
    // Workspace uses manual grid + list rendering, no ScrollBars

    // Insights
    insights_period: Period = .daily,
    breathing_phase: u8 = 0, // 0-20 for breathing animation cycle
    insights_focus: enum { chart, prompts, team } = .chart,
    insights_prompt_cursor: usize = 0,
    insights_member_cursor: usize = 0,
    insights_expanded_prompt: ?usize = null,
    insights_show_member_detail: bool = false,
    chart_offset: u16 = 0,

    pub fn init() Dashboard {
        return .{
            .library_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .content_scroll_bars = w.initPlainScrollBars(theme.PANEL, 3),
            .pr_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .pr_diff_scroll_bars = w.initPlainScrollBars(theme.PANEL, 2),
            // workspace uses manual grid, no ScrollBars
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

                // Comment editor absorbs all keys
                if (self.show_comment_editor) {
                    if (key.matches(vaxis.Key.escape, .{})) {
                        self.show_comment_editor = false;
                        self.comment_input_len = 0;
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        self.status_line = if (self.comment_input_len > 0) "Comment submitted." else "Empty comment discarded.";
                        self.show_comment_editor = false;
                        self.comment_input_len = 0;
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (self.comment_input_len > 0) {
                            self.comment_input_len -= 1;
                            ctx.consumeAndRedraw();
                        }
                    } else if (key.text) |text| {
                        const remaining = self.comment_input_buf.len - self.comment_input_len;
                        if (text.len > 0 and text.len <= remaining) {
                            @memcpy(self.comment_input_buf[self.comment_input_len .. self.comment_input_len + text.len], text);
                            self.comment_input_len += text.len;
                            ctx.consumeAndRedraw();
                        }
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
                        self.status_line = "Create PR (not yet implemented)";
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (self.detail_focus_content) {
                        // Content pane has focus: j/k scrolls content
                        try self.content_scroll_bars.scroll_view.handleEvent(ctx, event);
                    } else {
                        // Info pane has focus: h/l switches tabs, j/k for PRs
                        if (self.detail_tab == .pull_requests and self.show_pr_diff) {
                            // PR diff drill-down: Esc goes back, j/k scrolls diff
                            if (key.matches(vaxis.Key.escape, .{})) {
                                self.show_pr_diff = false;
                                self.show_comment_editor = false;
                                ctx.consumeAndRedraw();
                                return;
                            }
                            if (key.matches('a', .{})) {
                                self.status_line = "Accept PR (not yet implemented)";
                                ctx.consumeAndRedraw();
                                return;
                            }
                            if (key.matches('x', .{})) {
                                self.status_line = "Reject PR (not yet implemented)";
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
                        if (self.detail_tab == .pull_requests) {
                            if (key.matches('f', .{})) {
                                self.pr_filter = self.pr_filter.next();
                                self.pr_scroll_bars.scroll_view.cursor = 0;
                                self.selected_pr_idx = 0;
                                ctx.consumeAndRedraw();
                                return;
                            }
                            if (key.matches(vaxis.Key.enter, .{})) {
                                self.show_pr_diff = true;
                                ctx.consumeAndRedraw();
                                return;
                            }
                            self.syncPrWidgets();
                            if (self.pr_row_count == 0) return;

                            const prev = self.pr_scroll_bars.scroll_view.cursor;
                            try self.pr_scroll_bars.scroll_view.handleEvent(ctx, event);

                            var pos = @as(usize, @intCast(self.pr_scroll_bars.scroll_view.cursor));
                            if (pos >= self.pr_row_count) pos = if (self.pr_row_count > 0) self.pr_row_count - 1 else 0;

                            // Skip description rows (null index). Try next row, if still null revert.
                            if (pos < self.pr_row_count and self.pr_indices[pos] == null) {
                                const moving_down = self.pr_scroll_bars.scroll_view.cursor > prev;
                                if (moving_down and pos + 1 < self.pr_row_count and self.pr_indices[pos + 1] != null) {
                                    pos += 1;
                                } else {
                                    // Can't skip forward, revert to prev
                                    pos = @intCast(prev);
                                }
                            }
                            self.pr_scroll_bars.scroll_view.cursor = @intCast(pos);
                            if (pos < self.pr_row_count) {
                                if (self.pr_indices[pos]) |pi| {
                                    self.selected_pr_idx = pi;
                                }
                            }
                        }
                    }
                    return;
                }

                // Top-level tab switching
                if (key.matches('1', .{})) return self.selectTab(ctx, .insights);
                if (key.matches('2', .{})) return self.selectTab(ctx, .workspace);
                if (key.matches('3', .{})) return self.selectTab(ctx, .library);

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
                            if (self.detail_tab == .pull_requests and self.show_pr_diff) {
                                if (key.matches(vaxis.Key.escape, .{})) {
                                    self.show_pr_diff = false;
                                    self.show_comment_editor = false;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches('a', .{})) {
                                    self.status_line = "Accept PR (not yet implemented)";
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches('x', .{})) {
                                    self.status_line = "Reject PR (not yet implemented)";
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
                                return;
                            }
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
                            if (self.detail_tab == .pull_requests) {
                                if (key.matches('f', .{})) {
                                    self.pr_filter = self.pr_filter.next();
                                    self.pr_scroll_bars.scroll_view.cursor = 0;
                                    self.selected_pr_idx = 0;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                if (key.matches(vaxis.Key.enter, .{})) {
                                    self.show_pr_diff = true;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                                self.syncPrWidgets();
                                if (self.pr_row_count == 0) return;

                                const prev = self.pr_scroll_bars.scroll_view.cursor;
                                try self.pr_scroll_bars.scroll_view.handleEvent(ctx, event);

                                var pos = @as(usize, @intCast(self.pr_scroll_bars.scroll_view.cursor));
                                if (pos >= self.pr_row_count) pos = if (self.pr_row_count > 0) self.pr_row_count - 1 else 0;

                                // Skip description rows (null index). Try next row, if still null revert.
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
                                    if (self.pr_indices[pos]) |pi| {
                                        self.selected_pr_idx = pi;
                                    }
                                }
                                if (self.pr_indices[pos]) |pi| {
                                    self.selected_pr_idx = pi;
                                }
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
                            if (self.selected_prompt != pi) {
                                self.selected_prompt = pi;
                                self.show_pr_diff = false;
                                self.show_comment_editor = false;
                                self.selected_pr_idx = 0;
                                self.pr_scroll_bars.scroll_view.cursor = 0;
                                self.pr_filter = .open;
                            }
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
                                if (key.matches('d', .{})) {
                                    self.ws_show_diff = !self.ws_show_diff;
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
                        const ins = &data.INSIGHTS;
                        if (key.matches('t', .{})) {
                            self.insights_period = self.insights_period.next();
                            self.status_line = switch (self.insights_period) {
                                .daily => "Period: daily (30d).",
                                .weekly => "Period: weekly (8w).",
                                .monthly => "Period: monthly (12m).",
                            };
                            ctx.consumeAndRedraw();
                        }
                        if (key.matches(vaxis.Key.tab, .{})) {
                            self.insights_focus = switch (self.insights_focus) {
                                .chart => .prompts,
                                .prompts => .team,
                                .team => .chart,
                            };
                            self.insights_expanded_prompt = null;
                            self.insights_show_member_detail = false;
                            ctx.consumeAndRedraw();
                        }
                        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                            switch (self.insights_focus) {
                                .prompts => {
                                    if (self.insights_prompt_cursor < ins.prompts.len - 1)
                                        self.insights_prompt_cursor += 1;
                                    ctx.consumeAndRedraw();
                                },
                                .team => {
                                    if (self.insights_member_cursor < ins.members.len - 1)
                                        self.insights_member_cursor += 1;
                                    ctx.consumeAndRedraw();
                                },
                                else => {},
                            }
                        }
                        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                            switch (self.insights_focus) {
                                .prompts => {
                                    self.insights_prompt_cursor -|= 1;
                                    ctx.consumeAndRedraw();
                                },
                                .team => {
                                    self.insights_member_cursor -|= 1;
                                    ctx.consumeAndRedraw();
                                },
                                else => {},
                            }
                        }
                        if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
                            if (self.insights_focus == .chart) {
                                self.status_line = "Chart scroll requires Hub API (mock: fixed 30d window).";
                                ctx.consumeAndRedraw();
                            }
                        }
                        if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
                            if (self.insights_focus == .chart) {
                                self.status_line = "Chart scroll requires Hub API (mock: fixed 30d window).";
                                ctx.consumeAndRedraw();
                            }
                        }
                        if (key.matches(vaxis.Key.enter, .{})) {
                            switch (self.insights_focus) {
                                .prompts => {
                                    // Toggle per-constraint detail expansion
                                    if (self.insights_expanded_prompt == self.insights_prompt_cursor) {
                                        self.insights_expanded_prompt = null;
                                    } else {
                                        self.insights_expanded_prompt = self.insights_prompt_cursor;
                                    }
                                    ctx.consumeAndRedraw();
                                },
                                .team => {
                                    self.insights_show_member_detail = !self.insights_show_member_detail;
                                    ctx.consumeAndRedraw();
                                },
                                else => {},
                            }
                        }
                        if (key.matches(vaxis.Key.escape, .{})) {
                            if (self.insights_expanded_prompt != null) {
                                self.insights_expanded_prompt = null;
                                ctx.consumeAndRedraw();
                            } else if (self.insights_show_member_detail) {
                                self.insights_show_member_detail = false;
                                ctx.consumeAndRedraw();
                            } else {
                                self.insights_focus = .prompts;
                                ctx.consumeAndRedraw();
                            }
                        }
                    },
                }
            },
            .init => {
                // Start breathing animation
                try ctx.tick(100, self.widget());
            },
            .tick => {
                // Advance breathing cycle: 0→20→0 (2 seconds at 100ms intervals)
                self.breathing_phase = (self.breathing_phase + 1) % 21;
                ctx.redraw = true;
                try ctx.tick(100, self.widget());
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
        if (self.show_help or self.show_confirm or self.show_comment_editor) child_count = 4;

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
        if (self.show_comment_editor) {
            const box_w: u16 = 42;
            const box_h: u16 = 8;
            const box_col = size.width -| (box_w + 2);
            const box_row = size.height -| (box_h + 2);
            const comment_ctx = ctx.withConstraints(
                .{ .width = box_w, .height = box_h },
                .{ .width = box_w, .height = box_h },
            );
            children[3] = .{ .origin = .{ .row = box_row, .col = box_col }, .surface = try self.drawCommentEditorOverlay(comment_ctx) };
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
        else if (self.show_comment_editor)
            "Enter send  Esc cancel"
        else if (self.show_detail and self.detail_tab == .pull_requests and self.show_pr_diff)
            "j/k scroll  a accept  x reject  c comment  Esc back"
        else if (self.show_detail and self.detail_tab == .pull_requests)
            "j/k move  Enter view diff  h/l tab  Esc back  ? help"
        else if (self.show_detail and self.detail_focus_content)
            "j/k scroll  g/G jump  Tab info pane  Esc back  ? help"
        else if (self.show_detail)
            "h/l tab  j/k move  Tab content pane  p create PR  Esc back  ? help"
        else switch (self.selected_module) {
            .library => if (self.detail_focus_content and self.detail_tab == .pull_requests and self.show_pr_diff)
                "j/k scroll  a accept  x reject  c comment  Esc back"
            else if (self.detail_focus_content and self.detail_tab == .pull_requests)
                "j/k move  Enter view diff  Esc back  ? help"
            else if (self.detail_focus_content)
                "h/l tab  j/k scroll  Esc list  ? help"
            else
                "j/k move  Enter detail  b bundle  S settings  ? help  q quit",
            .workspace => switch (self.ws_focus) {
                .bar => "j/k select workspace  Tab list  r sync  ? help  q quit",
                .list => "h/l tab  j/k move  Enter content  Esc bar  ? help",
                .content => "j/k scroll  d toggle diff  Esc list  ? help",
            },
            .insights => switch (self.insights_focus) {
                .chart => "h/l scroll  Tab focus  t period  ? help  q quit",
                .prompts => "j/k move  Enter expand  Tab focus  t period  ? help  q quit",
                .team => "j/k move  Enter detail  Tab focus  t period  ? help  q quit",
            },
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

        // Right-aligned contextual hint for workspace items
        if (!self.show_help and !self.show_confirm and !self.show_settings and
            !self.show_comment_editor and !self.show_detail and
            self.selected_module == .workspace)
        {
            const hint: []const u8 = if (self.ws_focus == .content)
                (if (self.ws_show_diff) "d content" else "d diff")
            else if (self.ws_focus == .bar) blk: {
                const ws_idx = @min(self.ws_sel, data.WORKSPACES.len - 1);
                const wsi = &data.WORKSPACES[ws_idx];
                break :blk if (wsi.local_rev != wsi.remote_rev) "New version available, press r to sync" else "Up to date";
            } else blk: {
                const ws_sel = self.ws_list_sel;
                const is_modified = switch (self.ws_tab) {
                    .context => ws_sel < data.WS_CONTEXT.len and data.WS_CONTEXT[ws_sel].modified,
                    .prompts => ws_sel < data.WS_PROMPTS.len and data.WS_PROMPTS[ws_sel].has_override,
                };
                break :blk if (is_modified) "New version available, press r to sync" else "Up to date";
            };
            w.writeRightText(&surface, ctx, 0, hint, theme.fg(theme.TEXT_SOFT));
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

    // Library right pane: detail for selected prompt with Overview/Content/Pull Requests tabs.
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
        if (self.detail_tab == .pull_requests) {
            w.writeRightText(&surface, ctx, 0, "f filter", theme.textOn(theme.PANEL, theme.MUTED));
        } else {
            w.writeRightText(&surface, ctx, 0, p.canonical_name, theme.textOn(theme.PANEL, theme.MUTED));
        }

        const inner_h = ctx.max.height.? -| 2;
        const inner_w = ctx.max.width.? -| 4;

        switch (self.detail_tab) {
            .content => {
                // Meta header row
                var header_rows: u16 = 1;
                const meta_line = try std.fmt.allocPrint(ctx.arena, "rev.{d}  \xc2\xb7{d} PR  {d} constraints  {s}", .{ p.revision, p.open_pr_count, p.constraint_count, p.updated });
                w.writeText(&surface, ctx, 2, 2, meta_line, theme.fg(theme.MUTED));

                // Workspace names (if present)
                if (p.workspace_names.len > 0) {
                    header_rows += 1;
                    w.writeText(&surface, ctx, 2, 3, p.workspace_names, theme.fg(theme.TEXT_SOFT));
                }

                // Spacing row
                header_rows += 1;
                const content_origin_row: u16 = 2 + header_rows;
                const content_h = inner_h -| header_rows;

                self.syncContentWidget();
                const child_ctx = ctx.withConstraints(.{ .width = inner_w, .height = content_h }, .{ .width = inner_w, .height = content_h });
                const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                children[0] = .{ .origin = .{ .row = content_origin_row, .col = 2 }, .surface = try self.content_scroll_bars.widget().draw(child_ctx) };
                surface.children = children;
            },
            .pull_requests => {
                const prs = data.prsForPrompt(p.canonical_name);
                if (prs.len == 0) {
                    w.writeText(&surface, ctx, 2, 2, "No pull requests for this prompt.", theme.fg(theme.MUTED));
                } else if (self.show_pr_diff) {
                    // Diff drill-down view
                    const pr_idx = @min(self.selected_pr_idx, prs.len - 1);
                    const pr = &prs[pr_idx];
                    const title = try std.fmt.allocPrint(ctx.arena, "{s} \xe2\x94\x80 {s} \xe2\x94\x80 {s} \xe2\x94\x80 {s} \xe2\x94\x80 refer:{d}", .{ pr.id, pr.prompt_name, pr.author, pr.status, pr.trace_refers });
                    w.writeText(&surface, ctx, 2, 2, title, theme.boldOn(theme.PANEL, theme.TEXT));

                    self.syncPrDiffAndComments(ctx.arena);
                    const diff_h = inner_h -| 2;
                    const diff_ctx = ctx.withConstraints(.{ .width = inner_w, .height = diff_h }, .{ .width = inner_w, .height = diff_h });
                    const diff_children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                    diff_children[0] = .{ .origin = .{ .row = 4, .col = 2 }, .surface = try self.pr_diff_scroll_bars.widget().draw(diff_ctx) };
                    surface.children = diff_children;
                } else {
                    // PR list view
                    self.syncPrWidgets();
                    const list_ctx = ctx.withConstraints(.{ .width = inner_w, .height = inner_h }, .{ .width = inner_w, .height = inner_h });
                    self.pr_scroll_bars.scroll_view.draw_cursor = false;
                    defer self.pr_scroll_bars.scroll_view.draw_cursor = true;

                    var list_surface = try self.pr_scroll_bars.widget().draw(list_ctx);
                    const sv = &self.pr_scroll_bars.scroll_view;
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
                    const pr_children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                    pr_children[0] = .{ .origin = .{ .row = 2, .col = 1 }, .surface = list_surface };
                    surface.children = pr_children;
                }
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

        // Row 0: inner tabs + right hint
        var col: u16 = 2;
        for (detail_tabs) |tab| {
            col = w.drawInnerTabBadge(&surface, ctx, 0, col, tab.label(), tab == self.detail_tab);
            col +|= 1;
        }
        if (self.detail_tab == .pull_requests) {
            w.writeRightText(&surface, ctx, 0, "f filter", theme.textOn(theme.PANEL, theme.MUTED));
        }

        const inner_h = ctx.max.height.? -| 3;
        const inner_w = ctx.max.width.? -| 2;

        switch (self.detail_tab) {
            .content => {
                // Meta header row
                var header_rows2: u16 = 1;
                const meta_line2 = try std.fmt.allocPrint(ctx.arena, "rev.{d}  \xc2\xb7{d} PR  {d} constraints  {s}", .{ p.revision, p.open_pr_count, p.constraint_count, p.updated });
                w.writeText(&surface, ctx, 2, 2, meta_line2, theme.fg(theme.MUTED));

                // Workspace names (if present)
                if (p.workspace_names.len > 0) {
                    header_rows2 += 1;
                    w.writeText(&surface, ctx, 2, 3, p.workspace_names, theme.fg(theme.TEXT_SOFT));
                }

                // Spacing row
                header_rows2 += 1;
                const content_origin_row2: u16 = 2 + header_rows2;
                const content_h2 = inner_h -| header_rows2;

                self.syncContentWidget();
                const child_ctx = ctx.withConstraints(.{ .width = inner_w, .height = content_h2 }, .{ .width = inner_w, .height = content_h2 });
                const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                children[0] = .{ .origin = .{ .row = content_origin_row2, .col = 2 }, .surface = try self.content_scroll_bars.widget().draw(child_ctx) };
                surface.children = children;
            },
            .pull_requests => {
                const prs = data.prsForPrompt(p.canonical_name);
                if (prs.len == 0) {
                    w.writeText(&surface, ctx, 2, 2, "No pull requests for this prompt.", theme.fg(theme.MUTED));
                } else if (self.show_pr_diff) {
                    const pr_idx = @min(self.selected_pr_idx, prs.len - 1);
                    const pr = &prs[pr_idx];
                    const title = try std.fmt.allocPrint(ctx.arena, "{s} \xe2\x94\x80 {s} \xe2\x94\x80 {s} \xe2\x94\x80 {s} \xe2\x94\x80 refer:{d}", .{ pr.id, pr.prompt_name, pr.author, pr.status, pr.trace_refers });
                    w.writeText(&surface, ctx, 2, 2, title, theme.boldOn(theme.PANEL, theme.TEXT));

                    self.syncPrDiffAndComments(ctx.arena);
                    const diff_h = inner_h -| 2;
                    const diff_ctx = ctx.withConstraints(.{ .width = inner_w, .height = diff_h }, .{ .width = inner_w, .height = diff_h });
                    const diff_children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                    diff_children[0] = .{ .origin = .{ .row = 4, .col = 2 }, .surface = try self.pr_diff_scroll_bars.widget().draw(diff_ctx) };
                    surface.children = diff_children;
                } else {
                    self.syncPrWidgets();
                    const list_ctx = ctx.withConstraints(.{ .width = inner_w, .height = inner_h }, .{ .width = inner_w, .height = inner_h });
                    self.pr_scroll_bars.scroll_view.draw_cursor = false;
                    defer self.pr_scroll_bars.scroll_view.draw_cursor = true;

                    var list_surface = try self.pr_scroll_bars.widget().draw(list_ctx);
                    const sv = &self.pr_scroll_bars.scroll_view;
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
                            const new_ch = try ctx.arena.alloc(vxfw.SubSurface, old.len + 1);
                            @memcpy(new_ch[0..old.len], old);
                            new_ch[old.len] = .{
                                .origin = .{ .col = 0, .row = crow },
                                .surface = csurface,
                                .z_index = 1,
                            };
                            list_surface.children = new_ch;
                        }
                    }
                    const pr_children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                    pr_children[0] = .{ .origin = .{ .row = 2, .col = 1 }, .surface = list_surface };
                    surface.children = pr_children;
                }
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
        // Context/Prompts/Local Edits item list with inner tabs
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
                var last_prefix: []const u8 = "";
                for (data.WS_CONTEXT, 0..) |f, i| {
                    if (kv_row >= inner_h + 2) break;
                    const prefix = data.pathPrefix(f.path);
                    if (!std.mem.eql(u8, prefix, last_prefix)) {
                        w.writeText(&surface, ctx, 2, kv_row, prefix, theme.boldOn(theme.PANEL, theme.ACCENT));
                        kv_row += 1;
                        last_prefix = prefix;
                        if (kv_row >= inner_h + 2) break;
                    }
                    const sel = i == self.ws_list_sel;
                    const name_style = if (sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
                    if (sel) {
                        surface.writeCell(1, kv_row, .{
                            .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                            .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                        });
                    }
                    const fname = data.promptName(f.path);
                    w.writeText(&surface, ctx, 2, kv_row, fname, name_style);
                    if (f.modified) {
                        const nw: u16 = @intCast(ctx.stringWidth(fname));
                        w.writeText(&surface, ctx, 2 + nw + 1, kv_row, "*", theme.fg(theme.WARN));
                    }
                    kv_row += 1;
                }
            },
            .prompts => {
                var kv_row: u16 = 2;
                var last_prefix: []const u8 = "";
                for (data.WS_PROMPTS, 0..) |p, i| {
                    if (kv_row >= inner_h + 2) break;
                    const prefix = data.pathPrefix(p.name);
                    if (!std.mem.eql(u8, prefix, last_prefix)) {
                        w.writeText(&surface, ctx, 2, kv_row, prefix, theme.boldOn(theme.PANEL, theme.ACCENT));
                        kv_row += 1;
                        last_prefix = prefix;
                        if (kv_row >= inner_h + 2) break;
                    }
                    const sel = i == self.ws_list_sel;
                    const name_style = if (sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
                    if (sel) {
                        surface.writeCell(1, kv_row, .{
                            .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                            .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                        });
                    }
                    const fname = data.promptName(p.name);
                    w.writeText(&surface, ctx, 2, kv_row, fname, name_style);
                    if (p.has_override) {
                        const nw: u16 = @intCast(ctx.stringWidth(fname));
                        w.writeText(&surface, ctx, 2 + nw + 1, kv_row, "*", theme.fg(theme.WARN));
                    }
                    kv_row += 1;
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
        // Title with diff marker (context branch or prompt local edit)
        const has_diff = switch (self.ws_tab) {
            .context => sel < data.WS_CONTEXT.len and data.WS_CONTEXT[sel].modified,
            .prompts => sel < data.WS_PROMPTS.len and data.WS_PROMPTS[sel].has_override,
        };
        w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, if (has_diff) theme.WARN else theme.TEXT));
        {
            var marker_col: u16 = 2 + @as(u16, @intCast(ctx.stringWidth(title)));
            if (has_diff) {
                marker_col += 1;
                w.writeText(&surface, ctx, marker_col, 0, "*", theme.boldOn(theme.PANEL, theme.WARN));
                marker_col += 1;
            }
            if (self.ws_show_diff) {
                marker_col += 1;
                w.writeText(&surface, ctx, marker_col, 0, "diff", theme.boldOn(theme.PANEL, theme.ACCENT));
            }
        }

        var kv_row: u16 = 2;
        const max_row = ctx.max.height.? -| 1;

        switch (self.ws_tab) {
            .context => {
                if (sel < data.WS_CONTEXT.len) {
                    const f = &data.WS_CONTEXT[sel];
                    if (self.ws_show_diff) {
                        if (f.branch_diff.len > 0) {
                            // Show branch diff (GitHub-style colored lines)
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
                            w.writeText(&surface, ctx, 2, kv_row, "No diff available", theme.fg(theme.MUTED));
                        }
                    } else {
                        // Show file content
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
                    if (self.ws_show_diff) {
                        if (p.override_diff.len > 0) {
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
                            w.writeText(&surface, ctx, 2, kv_row, "No diff available", theme.fg(theme.MUTED));
                        }
                    } else {
                        // Show prompt body
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

    // Insights: multi-panel signal-ratio dashboard
    fn drawInsights(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.CANVAS);

        const ins = &data.INSIGHTS;

        // Layout: chart(top, full width) + prompts|team (bottom, side by side)
        const chart_h: u16 = if (size.height > 40) 10 else 8;
        const body_h: u16 = size.height -| chart_h;
        const team_w: u16 = 18; // narrow sidebar: border(2) + padding(2) + grid(5×2) + gaps
        const prompts_w: u16 = size.width -| team_w;

        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);

        // Panel 1: Signal Trend chart (hero, full width)
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawInsightsChart(ctx, size.width, chart_h, ins) };
        // Panel 2: Prompts Rank (or Member Detail if active)
        const main_surface = if (self.insights_show_member_detail)
            try self.drawMemberDetail(ctx, prompts_w, body_h, ins)
        else
            try self.drawInsightsPrompts(ctx, prompts_w, body_h, ins);
        children[1] = .{ .origin = .{ .row = chart_h, .col = 0 }, .surface = main_surface };
        // Panel 3: Team Activity sidebar (narrow, right side)
        children[2] = .{ .origin = .{ .row = chart_h, .col = prompts_w }, .surface = try self.drawInsightsTeam(ctx, team_w, body_h, ins) };

        root.children = children;
        return root;
    }

    fn drawInsightsChart(self: *Dashboard, ctx: vxfw.DrawContext, width: u16, height: u16, ins: *const data.InsightsData) std.mem.Allocator.Error!vxfw.Surface {
        const border_color = if (self.insights_focus == .chart) theme.ACCENT else theme.BORDER;
        var s = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        w.fillSurface(&s, theme.PANEL);
        w.drawBorder(&s, border_color, theme.PANEL);

        // Title bar: ● Signal Trend ── key metrics
        // Breathing ● : phase 0-10 = dim→bright, 10-20 = bright→dim
        const breath_t: f32 = blk: {
            const p = self.breathing_phase;
            const half: f32 = if (p <= 10) @as(f32, @floatFromInt(p)) / 10.0 else @as(f32, @floatFromInt(20 - p)) / 10.0;
            break :blk 0.3 + half * 0.7; // range 0.3 to 1.0
        };
        const dark_green = theme.rgb(0x2d4a1f);
        const dot_color = theme.lerpColor(dark_green, theme.OK, breath_t);
        w.writeText(&s, ctx, 2, 0, "\u{25cf}", .{ .fg = dot_color, .bg = theme.PANEL });
        w.writeText(&s, ctx, 4, 0, "Signal Trend", theme.boldOn(theme.PANEL, theme.TEXT));
        const metrics_txt = try std.fmt.allocPrint(ctx.arena, "signal {d}%", .{ins.signal_ratio});
        w.writeText(&s, ctx, 18, 0, metrics_txt, theme.fg(theme.ACCENT_SOFT));
        w.writeRightText(&s, ctx, 0, "t period", theme.fg(theme.MUTED));

        const chart_x: u16 = 1;
        const chart_w: u16 = width -| 2;
        const chart_rows: u16 = height -| 3;
        w.drawBrailleAreaChart(&s, ctx.arena, &ins.refer_trend, chart_x, 1, chart_w, chart_rows);

        // X-axis: minimal endpoints
        w.writeText(&s, ctx, chart_x, height -| 2, "30d ago", theme.fg(theme.DIM));
        w.writeRightText(&s, ctx, height -| 2, "today", theme.fg(theme.DIM));

        return s;
    }

    fn drawInsightsPrompts(self: *Dashboard, ctx: vxfw.DrawContext, width: u16, height: u16, ins: *const data.InsightsData) std.mem.Allocator.Error!vxfw.Surface {
        const border_color = if (self.insights_focus == .prompts) theme.ACCENT else theme.BORDER;
        var s = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        w.fillSurface(&s, theme.PANEL);
        w.drawBorder(&s, border_color, theme.PANEL);

        w.writeText(&s, ctx, 3, 0, "Prompts Rank", theme.boldOn(theme.PANEL, theme.TEXT));
        // Right-aligned column headers (with right padding)
        const col_rate: u16 = width -| 24;
        const col_delta: u16 = width -| 16;
        const col_sig: u16 = width -| 9;
        w.writeText(&s, ctx, col_rate, 0, "rate", theme.fg(theme.MUTED));
        w.writeText(&s, ctx, col_delta, 0, "\u{0394}7d", theme.fg(theme.MUTED));
        w.writeText(&s, ctx, col_sig, 0, "signal", theme.fg(theme.MUTED));

        // Find max refer count for bar scaling
        var max_refer: u32 = 1;
        for (ins.prompts) |p| {
            if (p.refer_count > max_refer) max_refer = p.refer_count;
        }

        const name_w: u16 = 21;
        const bar_start: u16 = name_w + 2;
        const bar_end: u16 = col_rate -| 2;
        const bar_max_w: u16 = bar_end -| bar_start;

        const focused = self.insights_focus == .prompts;
        var row: u16 = 1;
        for (ins.prompts, 0..) |p, pi| {
            if (row >= height -| 1) break;
            const is_idle = p.refer_count == 0;
            const is_sel = pi == self.insights_prompt_cursor and focused;

            // Cursor indicator
            if (is_sel) {
                s.writeCell(1, row, .{
                    .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                    .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                });
            }

            if (is_idle) {
                // Same layout as active prompts, just name in red
                const name_style: vaxis.Style = if (is_sel) theme.boldOn(theme.PANEL, theme.DANGER) else .{ .fg = theme.DANGER, .bg = theme.PANEL };
                w.writeText(&s, ctx, 3, row, p.name, name_style);
                w.writeText(&s, ctx, col_rate, row, "0/d", theme.fg(theme.MUTED));
                w.writeText(&s, ctx, col_delta, row, " 0%", theme.fg(theme.MUTED));
                const sig_txt = try std.fmt.allocPrint(ctx.arena, "0/{d}", .{p.constraint_count});
                w.writeText(&s, ctx, col_sig, row, sig_txt, theme.fg(theme.MUTED));
            } else {
                const name_style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
                w.writeText(&s, ctx, 3, row, p.name, name_style);

                const bar_w: u16 = @intCast(@as(u32, bar_max_w) * p.refer_count / max_refer);
                for (0..bar_w) |offset| {
                    const bc: u16 = bar_start + @as(u16, @intCast(offset));
                    if (bc >= bar_end) break;
                    const t: f32 = if (bar_w > 1) @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(bar_w - 1)) else 0.5;
                    s.writeCell(bc, row, .{
                        .char = .{ .grapheme = "\xe2\x96\x88", .width = 1 },
                        .style = .{ .fg = theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, t), .bg = theme.PANEL },
                    });
                }
                const ref_text = try std.fmt.allocPrint(ctx.arena, " {d}", .{p.refer_count});
                const ref_col: u16 = bar_start + bar_w;
                if (ref_col + @as(u16, @intCast(ctx.stringWidth(ref_text))) < col_rate) {
                    w.writeText(&s, ctx, ref_col, row, ref_text, theme.fg(theme.TEXT));
                }
                const rate = try std.fmt.allocPrint(ctx.arena, "{d}/d", .{p.rate_per_day});
                w.writeText(&s, ctx, col_rate, row, rate, theme.fg(theme.MUTED));
                w.writeDelta(&s, ctx, col_delta, row, p.delta_pct);
                const sig_txt = try std.fmt.allocPrint(ctx.arena, "{d}/{d}", .{ p.active_constraint_count, p.constraint_count });
                w.writeText(&s, ctx, col_sig, row, sig_txt, theme.fg(theme.MUTED));
            }
            row += 1;

            // Expanded per-constraint detail
            if (self.insights_expanded_prompt == pi) {
                var c_max: u32 = 1;
                for (p.constraints) |c| {
                    if (c.refer_count > c_max) c_max = c.refer_count;
                }
                for (p.constraints, 0..) |c, ci| {
                    if (row >= height -| 1) break;
                    const is_c_idle = c.refer_count == 0;
                    const is_last = ci + 1 == p.constraints.len;
                    const tree_char: []const u8 = if (is_last) "\xe2\x94\x94" else "\xe2\x94\x9c"; // └ or ├
                    w.writeText(&s, ctx, 5, row, tree_char, theme.fg(theme.DIM));
                    w.writeText(&s, ctx, 7, row, c.id, theme.fg(theme.MUTED));
                    w.writeText(&s, ctx, 12, row, c.label, if (is_c_idle) theme.fg(theme.DANGER) else theme.fg(theme.TEXT_SOFT));
                    if (!is_c_idle) {
                        const c_bar_w: u16 = @intCast(@min(@as(u32, bar_max_w / 2) * c.refer_count / c_max, bar_max_w / 2));
                        for (0..c_bar_w) |offset| {
                            const bc: u16 = 32 + @as(u16, @intCast(offset));
                            if (bc >= col_rate -| 2) break;
                            const t: f32 = if (c_bar_w > 1) @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(c_bar_w - 1)) else 0.5;
                            s.writeCell(bc, row, .{
                                .char = .{ .grapheme = "\xe2\x96\x88", .width = 1 },
                                .style = .{ .fg = theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, t), .bg = theme.PANEL },
                            });
                        }
                        const c_ref = try std.fmt.allocPrint(ctx.arena, " {d}", .{c.refer_count});
                        w.writeText(&s, ctx, col_rate, row, c_ref, theme.fg(theme.MUTED));
                    } else {
                        const idle_txt = if (c.idle_days) |d|
                            try std.fmt.allocPrint(ctx.arena, "idle {d}d \xe2\x9a\xa0", .{d})
                        else
                            "idle \xe2\x9a\xa0";
                        w.writeText(&s, ctx, col_rate, row, idle_txt, .{ .fg = theme.DANGER, .bg = theme.PANEL });
                    }
                    row += 1;
                }
            }
        }

        return s;
    }

    fn drawInsightsTeam(self: *Dashboard, ctx: vxfw.DrawContext, width: u16, height: u16, ins: *const data.InsightsData) std.mem.Allocator.Error!vxfw.Surface {
        const border_color = if (self.insights_focus == .team) theme.ACCENT else theme.BORDER;
        var s = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        w.fillSurface(&s, theme.PANEL);
        w.drawBorder(&s, border_color, theme.PANEL);

        w.writeText(&s, ctx, 2, 0, "Team Activity", theme.boldOn(theme.PANEL, theme.TEXT));

        // Find team max for color scaling
        var team_max: u16 = 1;
        for (ins.members) |member| {
            for (member.trend) |v| {
                if (v > team_max) team_max = v;
            }
        }

        var row: u16 = 1;
        const num_weeks: u16 = (30 + 6) / 7; // 5 weeks
        const grid_col: u16 = 2;

        for (ins.members, 0..) |member, mi| {
            if (row + 8 >= height) break;
            // Member name with cursor indicator
            const is_sel = mi == self.insights_member_cursor and self.insights_focus == .team;
            if (is_sel) {
                s.writeCell(1, row, .{
                    .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                    .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                });
            }
            const name_style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
            w.writeText(&s, ctx, 2, row, member.username, name_style);
            row += 1;

            // 5×7 grid: 5 rows (weeks) × 7 cols (days of week)
            var week: u16 = 0;
            while (week < num_weeks) : (week += 1) {
                if (row >= height -| 1) break;
                var day: u16 = 0;
                while (day < 7) : (day += 1) {
                    const data_idx = week * 7 + day;
                    if (data_idx >= 30) break;
                    const val = member.trend[data_idx];
                    const max_f: f32 = @floatFromInt(@max(team_max, 1));
                    const fg = if (val == 0)
                        theme.rgb(0xffe8b8) // pale cream, lighter than ACCENT_SOFT
                    else
                        theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, @as(f32, @floatFromInt(val)) / max_f);
                    const col = grid_col + day * 2; // 1 char cell + 1 gap
                    if (col < width -| 1) {
                        s.writeCell(col, row, .{
                            .char = .{ .grapheme = "\xe2\x96\xa0", .width = 1 }, // ■
                            .style = .{ .fg = fg, .bg = theme.PANEL },
                        });
                    }
                }
                row += 1;
            }
            row += 1; // gap between members
        }

        return s;
    }

    fn drawMemberDetail(self: *Dashboard, ctx: vxfw.DrawContext, width: u16, height: u16, ins: *const data.InsightsData) std.mem.Allocator.Error!vxfw.Surface {
        const member_idx = @min(self.insights_member_cursor, ins.members.len - 1);
        const member = &ins.members[member_idx];
        var s = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        w.fillSurface(&s, theme.PANEL);
        w.drawBorder(&s, theme.ACCENT, theme.PANEL);

        const title = try std.fmt.allocPrint(ctx.arena, "{s}'s Activity", .{member.username});
        w.writeText(&s, ctx, 3, 0, title, theme.boldOn(theme.PANEL, theme.TEXT));
        w.writeRightText(&s, ctx, 0, "Esc back", theme.fg(theme.MUTED));

        var row: u16 = 2;
        // Summary
        const summary = try std.fmt.allocPrint(ctx.arena, "{d} refs  {d}d active", .{ member.refer_count, member.active_days });
        w.writeText(&s, ctx, 3, row, summary, theme.fg(theme.TEXT));
        row += 2;

        // Top prompts with bars
        w.writeText(&s, ctx, 3, row, "Top Prompts", theme.fgBold(theme.TEXT));
        row += 1;
        var max_ref: u32 = 1;
        for (member.top_prompts) |tp| {
            if (tp.refer_count > max_ref) max_ref = tp.refer_count;
        }
        const bar_start: u16 = 24;
        const bar_end: u16 = width -| 12;
        const bar_max_w: u16 = bar_end -| bar_start;
        for (member.top_prompts) |tp| {
            if (row >= height -| 5) break;
            w.writeText(&s, ctx, 5, row, tp.name, theme.fg(theme.TEXT_SOFT));
            const bar_w: u16 = @intCast(@as(u32, bar_max_w) * tp.refer_count / max_ref);
            for (0..bar_w) |offset| {
                const bc: u16 = bar_start + @as(u16, @intCast(offset));
                if (bc >= bar_end) break;
                const t: f32 = if (bar_w > 1) @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(bar_w - 1)) else 0.5;
                s.writeCell(bc, row, .{
                    .char = .{ .grapheme = "\xe2\x96\x88", .width = 1 },
                    .style = .{ .fg = theme.lerpColor(theme.ACCENT_SOFT, theme.ACCENT, t), .bg = theme.PANEL },
                });
            }
            const ref_txt = try std.fmt.allocPrint(ctx.arena, " {d}", .{tp.refer_count});
            w.writeText(&s, ctx, bar_start + bar_w, row, ref_txt, theme.fg(theme.MUTED));
            row += 1;
        }

        // Models
        row += 1;
        w.writeText(&s, ctx, 3, row, "Models", theme.fgBold(theme.TEXT));
        row += 1;
        for (member.models) |model| {
            if (row >= height -| 1) break;
            const mtxt = try std.fmt.allocPrint(ctx.arena, "{s}  \u{00d7}{d} ({d}%)", .{ model.model_id, model.refer_count, model.pct });
            w.writeText(&s, ctx, 5, row, mtxt, theme.fg(theme.TEXT_SOFT));
            row += 1;
        }

        return s;
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
            "1-3            Switch top-level module",
            "j / \xe2\x86\x93           Move down / next row",
            "k / \xe2\x86\x91           Move up / previous row",
            "h / \xe2\x86\x90           Previous tab / region",
            "l / \xe2\x86\x92           Next tab / region",
            "Enter          Open selected / confirm",
            "Esc            Back / close overlay",
            "g              Jump to first row",
            "G              Jump to last row",
            "r              Refresh / sync",
            "w              Workspace switcher (future)",
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

    fn drawCommentEditorOverlay(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        const bg = theme.PANEL_ALT;
        w.fillSurface(&surface, bg);
        w.drawBorder(&surface, theme.ACCENT, bg);

        // Title: show reply context or "New Comment"
        const p = &data.PROMPTS[self.selected_prompt];
        const prs = data.prsForPrompt(p.canonical_name);
        const title = if (prs.len > 0 and self.selected_pr_idx < prs.len)
            try std.fmt.allocPrint(ctx.arena, " Comment on {s} ", .{prs[self.selected_pr_idx].id})
        else
            " New Comment ";
        w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(bg, theme.ACCENT));

        // Input text with cursor
        const input_text = self.comment_input_buf[0..self.comment_input_len];
        const max_visible: usize = @as(usize, size.width -| 4);
        const visible_start = if (input_text.len > max_visible) input_text.len - max_visible else 0;
        const visible = input_text[visible_start..];
        const display = try std.fmt.allocPrint(ctx.arena, "{s}_", .{visible});
        w.writeText(&surface, ctx, 2, 2, display, theme.textOn(bg, theme.TEXT));

        // Hint
        w.writeText(&surface, ctx, 2, size.height -| 2, "Enter send  Esc cancel", theme.textOn(bg, theme.TEXT_SOFT));

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
                const pr_label: []const u8 = switch (p.open_pr_count) {
                    0 => "",
                    1 => "\xe2\x80\xa21",
                    2 => "\xe2\x80\xa22",
                    3 => "\xe2\x80\xa23",
                    else => "\xe2\x80\xa2+",
                };
                self.library_table_cols[row_idx] = .{
                    .{ .text = name, .flex = 1 },
                    .{ .text = pr_label, .flex = 0, .min_width = 2, .alignment = .right },
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

    fn syncPrWidgets(self: *Dashboard) void {
        const p = &data.PROMPTS[self.selected_prompt];
        const prs = data.prsForPrompt(p.canonical_name);
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
            // Row 2: description (muted)
            self.pr_text_rows[pi] = .{
                .text = pr.description,
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

    fn syncPrDiffAndComments(self: *Dashboard, allocator: std.mem.Allocator) void {
        const p = &data.PROMPTS[self.selected_prompt];
        const prs = data.prsForPrompt(p.canonical_name);
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

    fn contextHint(self: *const Dashboard) []const u8 {
        if (self.show_help) return "Keyboard reference overlay.";
        if (self.show_detail) return switch (self.detail_tab) {
            .content => "Full prompt body. j/k to scroll.",
            .pull_requests => if (self.show_pr_diff) "PR diff view. j/k scroll, a/x/c actions." else "j/k move  f filter  Enter view  c comment  Esc back",
        };
        return switch (self.selected_module) {
            .library => "Bundle facet, prompt list, and passive preview.",
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
        self.pr_filter = .open;
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
        // Reset PR drill-down state when leaving PR tab
        self.show_pr_diff = false;
        self.show_comment_editor = false;
        self.pr_filter = .open;
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

