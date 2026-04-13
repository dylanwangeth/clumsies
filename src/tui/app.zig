const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("theme.zig");
const w = @import("widgets.zig");
const data = @import("mock_data.zig");
const api = @import("api.zig");
const tree = @import("tree.zig");
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
    revoke_token,
    quit,
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

const MAX_LIBRARY_ROWS = 128;
const MAX_PR_ROWS = 64;
const detail_tabs = [_]DetailTab{ .content, .pull_requests };

pub const Dashboard = struct {
    api_state: *api.ApiState,
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

    // Library: tree-structured display with bundle filter
    library_bundle_filter: usize = 0,
    library_scroll_bars: vxfw.ScrollBars,
    library_row_count: usize = 0,
    library_prompt_indices: [MAX_LIBRARY_ROWS]?usize = .{null} ** MAX_LIBRARY_ROWS,
    library_row_dir_path: [MAX_LIBRARY_ROWS]?[]const u8 = .{null} ** MAX_LIBRARY_ROWS,
    library_row_depth: [MAX_LIBRARY_ROWS]u8 = .{0} ** MAX_LIBRARY_ROWS,
    library_widgets: [MAX_LIBRARY_ROWS]vxfw.Widget = undefined,
    library_text_rows: [MAX_LIBRARY_ROWS]vxfw.Text = undefined,
    library_table_rows: [MAX_LIBRARY_ROWS]TableRow = undefined,
    library_table_cols: [MAX_LIBRARY_ROWS][2]Column = undefined,
    library_row_text_bufs: [MAX_LIBRARY_ROWS][96]u8 = undefined,
    library_expanded: std.StringHashMapUnmanaged(void) = .empty,
    library_tree_initialized: bool = false,

    content_scroll_bars: vxfw.ScrollBars,
    content_widget: [1]vxfw.Widget = undefined,
    content_text: vxfw.Text = .{ .text = "" },

    // PR list within Prompt Detail
    pr_filter: PrFilter = .open,
    pr_scroll_bars: vxfw.ScrollBars,
    pr_widgets: [MAX_PR_ROWS * 2]vxfw.Widget = undefined,
    pr_table_rows: [MAX_PR_ROWS]TableRow = undefined,
    pr_table_cols: [MAX_PR_ROWS][4]Column = undefined,
    pr_text_rows: [MAX_PR_ROWS]vxfw.Text = undefined,
    pr_indices: [MAX_PR_ROWS * 2]?usize = .{null} ** (MAX_PR_ROWS * 2),
    pr_desc_bufs: [MAX_PR_ROWS][160]u8 = undefined,
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

    pub fn init(api_state: *api.ApiState) Dashboard {
        return .{
            .api_state = api_state,
            .library_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .content_scroll_bars = w.initPlainScrollBars(theme.PANEL, 3),
            .pr_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .pr_diff_scroll_bars = w.initPlainScrollBars(theme.PANEL, 2),
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
                            .revoke_token => {
                                const alloc = self.api_state.arena.allocator();
                                _ = api.postAction(self.api_state, alloc, .DELETE, "/api/auth/token", null) catch {
                                    self.status_line = "Token revoke failed";
                                    self.show_confirm = false;
                                    self.confirm_action = .none;
                                    ctx.consumeAndRedraw();
                                    return;
                                };
                                self.status_line = "Token revoked. Please re-login.";
                            },
                            .quit => {
                                ctx.consumeEvent();
                                ctx.quit = true;
                                return;
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
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('?', .{})) {
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
                        if (self.comment_input_len > 0) {
                            self.submitComment();
                        } else {
                            self.status_line = "Empty comment discarded.";
                        }
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
                if (key.matches('q', .{})) {
                    self.confirm_message = "";
                    self.confirm_action = .quit;
                    self.show_confirm = true;
                    ctx.consumeAndRedraw();
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
                    if (key.matches(vaxis.Key.escape, .{})) {
                        self.show_settings = false;
                        self.settings_focus = .sidebar;
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (key.matches(vaxis.Key.tab, .{})) {
                        self.settings_focus = if (self.settings_focus == .sidebar) .content else .sidebar;
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (self.settings_focus == .sidebar) {
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
                        if (key.matches(vaxis.Key.enter, .{})) {
                            self.settings_focus = .content;
                            self.settings_content_sel = 0;
                            ctx.consumeAndRedraw();
                            return;
                        }
                    } else {
                        // Content focus
                        if (key.matches(vaxis.Key.escape, .{})) {
                            self.settings_focus = .sidebar;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        const max_items: usize = switch (self.settings_tab) {
                            .account => self.accountWorkspaceCount(),
                            .organization => self.orgMemberCount(),
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
                                const ws_count = self.accountWorkspaceCount();
                                if (ws_count == 0) return;
                                const sel = @min(self.settings_content_sel, ws_count - 1);
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
                            if (key.matches('r', .{})) {
                                self.status_line = "Role change (requires input dialog)";
                                ctx.consumeAndRedraw();
                                return;
                            }
                            if (key.matches('x', .{})) {
                                self.confirm_message = "selected member";
                                self.confirm_action = .remove_member;
                                self.show_confirm = true;
                                ctx.consumeAndRedraw();
                                return;
                            }
                            if (key.matches('a', .{})) {
                                self.status_line = "Invite member (requires input dialog)";
                                ctx.consumeAndRedraw();
                                return;
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
                                self.confirm_action = .revoke_token;
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
                    if (key.matches(vaxis.Key.escape, .{})) {
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
                                // Trigger PR detail fetch for diff/comments
                                const all_p = self.getPrompts();
                                const si = @min(self.selected_prompt, if (all_p.len > 0) all_p.len - 1 else 0);
                                if (all_p.len > 0) {
                                    const prs_for = self.getPrsForPrompt(all_p[si].path);
                                    const pri = @min(self.selected_pr_idx, if (prs_for.len > 0) prs_for.len - 1 else 0);
                                    if (prs_for.len > 0) api.fetchPrDetailAsync(self.api_state, prs_for[pri].id);
                                }
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
                            const bundle_count = blk: {
                                self.api_state.mutex.lock();
                                defer self.api_state.mutex.unlock();
                                if (self.api_state.bundles) |lb| break :blk lb.len;
                                break :blk 0;
                            };
                            self.library_bundle_filter = (self.library_bundle_filter + 1) % (bundle_count + 1);
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
                        // Enter from list: toggle directory expansion, or focus detail for leaves.
                        if (!self.detail_focus_content and key.matches(vaxis.Key.enter, .{})) {
                            self.syncLibraryWidgets();
                            const pos = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
                            if (pos < self.library_row_count) {
                                if (self.library_row_dir_path[pos]) |dir| {
                                    self.toggleLibraryDir(dir);
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                            }
                            self.detail_focus_content = true;
                            ctx.consumeAndRedraw();
                            return;
                        }
                        // List pane: l/right expands the dir under cursor.
                        if (!self.detail_focus_content and (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{}))) {
                            self.syncLibraryWidgets();
                            const pos = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
                            if (pos < self.library_row_count) {
                                if (self.library_row_dir_path[pos]) |dir| {
                                    const alloc = self.api_state.arena.allocator();
                                    if (!self.library_expanded.contains(dir)) {
                                        _ = self.library_expanded.put(alloc, dir, {}) catch {};
                                        ctx.consumeAndRedraw();
                                        return;
                                    }
                                }
                            }
                        }
                        // List pane: h/left collapses current dir, or jumps to parent.
                        if (!self.detail_focus_content and (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{}))) {
                            self.syncLibraryWidgets();
                            const pos = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
                            if (pos < self.library_row_count) {
                                if (self.library_row_dir_path[pos]) |dir| {
                                    if (self.library_expanded.contains(dir)) {
                                        _ = self.library_expanded.remove(dir);
                                        ctx.consumeAndRedraw();
                                        return;
                                    }
                                }
                                // Jump to parent: scan upward for a row at a shallower depth.
                                const cur_depth = self.library_row_depth[pos];
                                if (cur_depth > 0 and pos > 0) {
                                    var p: usize = pos;
                                    while (p > 0) {
                                        p -= 1;
                                        if (self.library_row_depth[p] < cur_depth) {
                                            self.library_scroll_bars.scroll_view.cursor = @intCast(p);
                                            ctx.consumeAndRedraw();
                                            return;
                                        }
                                    }
                                }
                            }
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
                        // List pane: j/k moves through rows. Cursor can land on
                        // dir nodes (which allows Enter to toggle them) as well
                        // as leaf prompts.
                        try self.library_scroll_bars.scroll_view.handleEvent(ctx, event);
                        if (self.library_row_count == 0) return;

                        var pos = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
                        if (pos >= self.library_row_count) pos = self.library_row_count - 1;
                        self.library_scroll_bars.scroll_view.cursor = @intCast(pos);

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
                                    // Trigger workspace detail fetch
                                    self.api_state.mutex.lock();
                                    const ws_list = if (self.api_state.current_user) |u| u.workspaces else &.{};
                                    if (self.ws_sel < ws_list.len) {
                                        const ws_id = ws_list[self.ws_sel].ws_id;
                                        self.api_state.mutex.unlock();
                                        api.fetchWorkspaceAsync(self.api_state, ws_id);
                                    } else {
                                        self.api_state.mutex.unlock();
                                    }
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
                                        .context => self.wsContextCount(),
                                        .prompts => self.wsPromptsCount(),
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
                        const ins_counts = self.getInsightsCounts();
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
                                    if (ins_counts.prompt_count > 0 and self.insights_prompt_cursor < ins_counts.prompt_count - 1)
                                        self.insights_prompt_cursor += 1;
                                    ctx.consumeAndRedraw();
                                },
                                .team => {
                                    if (ins_counts.member_count > 0 and self.insights_member_cursor < ins_counts.member_count - 1)
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

        // Row 0: Accent band with org/user context
        w.paintBand(&surface, 0, theme.ACCENT, theme.PANEL);
        const HeaderInfo = struct { username: []const u8, role: []const u8 };
        const header_info: HeaderInfo = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.current_user) |u|
                break :blk .{ .username = u.username, .role = u.role };
            break :blk .{ .username = "\xe2\x80\x94", .role = "\xe2\x80\x94" };
        };
        const header_left = try std.fmt.allocPrint(ctx.arena, "{s} \xe2\x94\x80 {s} ({s})", .{ "acme", header_info.username, header_info.role });
        w.writeText(&surface, ctx, 1, 0, header_left, .{
            .fg = theme.PANEL,
            .bg = theme.ACCENT,
            .bold = true,
        });
        const sync_label: []const u8 = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            break :blk switch (self.api_state.status) {
                .connected => "\xe2\x9c\x93 Synced",
                .connecting => "\xe2\x86\xbb Connecting...",
                .disconnected => "Not connected",
                .error_auth, .error_network => "\xe2\x9c\x97 Connection failed",
            };
        };
        w.writeRightText(&surface, ctx, 0, sync_label, .{
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
            "j/k section  Enter open  Tab focus  Esc close"
        else if (self.show_settings and self.settings_tab == .account)
            "j/k move  c change password  Enter go to workspace  x sign out  Esc back"
        else if (self.show_settings and self.settings_tab == .organization)
            "j/k move  a invite  r role  x remove  Esc back"
        else if (self.show_settings and self.settings_tab == .token)
            "j/k move  r refresh  x revoke  Esc back"
        else if (self.show_settings)
            "j/k move  Esc back"
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
                const wss = self.getWorkspaces();
                if (wss.len == 0) break :blk "No workspaces";
                const ws_idx = @min(self.ws_sel, wss.len - 1);
                const wsi = &wss[ws_idx];
                break :blk if (wsi.local_rev != wsi.remote_rev) "New version available, press r to sync" else "Up to date";
            } else blk: {
                break :blk "Up to date";
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
        const prompts = self.getPrompts();
        const sel_idx = @min(self.selected_prompt, if (prompts.len > 0) prompts.len - 1 else 0);

        const list_ctx = ctx.withConstraints(.{ .width = list_w, .height = size.height }, .{ .width = list_w, .height = size.height });
        const detail_ctx = ctx.withConstraints(.{ .width = detail_w, .height = size.height }, .{ .width = detail_w, .height = size.height });

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawPromptTable(list_ctx) };
        if (prompts.len > 0) {
            children[1] = .{ .origin = .{ .row = 0, .col = list_w + 1 }, .surface = try self.drawLibraryDetail(detail_ctx, &prompts[sel_idx]) };
        } else {
            children[1] = .{ .origin = .{ .row = 0, .col = list_w + 1 }, .surface = try self.drawEmptyDetail(detail_ctx) };
        }
        root.children = children;
        return root;
    }

    fn drawPromptTable(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        // Suppress draw_cursor during rendering to avoid libvaxis #256 clipping.
        // Restored by defer so event handling still gets cursor movement.
        self.library_scroll_bars.scroll_view.draw_cursor = false;
        defer self.library_scroll_bars.scroll_view.draw_cursor = true;

        const bundles_list: []const data.BundleEntry = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.bundles) |lb| {
                const a = self.api_state.arena.allocator();
                break :blk api.toBundleEntries(a, lb);
            }
            break :blk &.{};
        };
        const bundle_label: []const u8 = if (self.library_bundle_filter == 0)
            "All"
        else if (self.library_bundle_filter - 1 < bundles_list.len)
            bundles_list[self.library_bundle_filter - 1].name
        else
            "All";
        const prompt_count: usize = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.prompts) |p| break :blk p.len;
            break :blk 0;
        };
        const subtitle = try std.fmt.allocPrint(ctx.arena, "{d} prompts  bundle: {s}  / search  b filter", .{ prompt_count, bundle_label });
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
            w.writeRightText(&surface, ctx, 0, p.path, theme.textOn(theme.PANEL, theme.MUTED));
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
                const prs = self.getPrsForPrompt(p.path);
                if (prs.len == 0) {
                    w.writeText(&surface, ctx, 2, 2, "No pull requests for this prompt.", theme.fg(theme.MUTED));
                } else if (self.show_pr_diff) {
                    // Diff drill-down view
                    const pr_idx = @min(self.selected_pr_idx, prs.len - 1);
                    const pr = &prs[pr_idx];
                    const title = try std.fmt.allocPrint(ctx.arena, "{s} \xe2\x94\x80 {s} \xe2\x94\x80 {s} \xe2\x94\x80 {s} \xe2\x94\x80 refer:{d}", .{ pr.id, pr.prompt_name, pr.author, pr.status, pr.trace_refers });
                    w.writeText(&surface, ctx, 2, 2, title, theme.boldOn(theme.PANEL, theme.TEXT));

                    // Row 3: operation header (only once detail has been fetched).
                    if (pr.operation_count > 0) {
                        const op_line = try opHeaderLine(ctx.arena, pr);
                        w.writeText(&surface, ctx, 2, 3, op_line, theme.fg(theme.TEXT_SOFT));
                    }

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
        const prompts = self.getPrompts();
        const sel_idx = @min(self.selected_prompt, if (prompts.len > 0) prompts.len - 1 else 0);

        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        if (prompts.len == 0) {
            w.writeText(&root, ctx, 2, 1, "No prompts loaded.", theme.fg(theme.MUTED));
            return root;
        }
        const p = &prompts[sel_idx];

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
                const prs = self.getPrsForPrompt(p.path);
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
        w.writeText(&surface, ctx, 2, 0, p.path, theme.boldOn(theme.PANEL, theme.TEXT));

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

        const wss = self.getWorkspaces();
        const ws_count_raw = wss.len;

        // Top: workspace bar with grid layout (each card = 2 rows: name + status)
        // Fixed height: border(1) + 2 content rows per grid row + border(1)
        const inner_w = size.width -| 2;
        const cols: u16 = if (inner_w >= 120) 4 else if (inner_w >= 80) 3 else 2;
        self.ws_grid_cols = cols;
        const card_w: u16 = inner_w / cols;
        const ws_count: u16 = @intCast(if (ws_count_raw > 0) ws_count_raw else 1);
        const grid_rows: u16 = (ws_count + cols - 1) / cols;
        const bar_h: u16 = 1 + grid_rows + 1; // border + rows + border

        const bar_border = if (self.ws_focus == .bar) theme.ACCENT else theme.BORDER;
        var bar = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = size.width, .height = bar_h });
        w.fillSurface(&bar, theme.PANEL);
        w.drawBorder(&bar, bar_border, theme.PANEL);
        w.writeText(&bar, ctx, 2, 0, "Workspaces", theme.boldOn(theme.PANEL, theme.TEXT));

        if (wss.len == 0) {
            w.writeText(&bar, ctx, 2, 1, "No workspaces loaded.", theme.fg(theme.MUTED));
        }

        const ws_idx = if (wss.len > 0) @min(self.ws_sel, wss.len - 1) else 0;
        for (wss, 0..) |wsi, i| {
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
        const ws_ptr: ?*const data.WorkspaceEntry = if (wss.len > 0) &wss[ws_idx] else null;
        const detail_surface = try self.drawWsDetail(detail_ctx, ws_ptr);

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

        // Check for live workspace detail
        self.api_state.mutex.lock();
        const live_ws = self.api_state.ws_detail;
        self.api_state.mutex.unlock();

        switch (self.ws_tab) {
            .context => {
                var kv_row: u16 = 2;
                if (live_ws) |ws_d| {
                    if (ws_d.context_files.len == 0) {
                        w.writeText(&surface, ctx, 2, kv_row, "No context files.", theme.fg(theme.MUTED));
                    } else {
                        const MAX_ROWS = 128;
                        var paths_buf: [MAX_ROWS][]const u8 = undefined;
                        var orig_idx: [MAX_ROWS]usize = undefined;
                        const n = @min(ws_d.context_files.len, MAX_ROWS);
                        for (0..n) |i| {
                            paths_buf[i] = ws_d.context_files[i].path;
                            orig_idx[i] = i;
                        }
                        const SortCtx = struct {
                            paths: [*]const []const u8,
                            fn lt(cx: @This(), a: usize, b: usize) bool {
                                return std.mem.lessThan(u8, cx.paths[a], cx.paths[b]);
                            }
                        };
                        std.mem.sort(usize, orig_idx[0..n], SortCtx{ .paths = &paths_buf }, SortCtx.lt);
                        var sorted_paths: [MAX_ROWS][]const u8 = undefined;
                        for (0..n) |i| sorted_paths[i] = paths_buf[orig_idx[i]];

                        var rows_buf: [MAX_ROWS]tree.Row = undefined;
                        const row_count = tree.flatten(sorted_paths[0..n], null, &rows_buf);

                        var text_buf: [96]u8 = undefined;
                        var r: usize = 0;
                        while (r < row_count and kv_row < inner_h + 2) : (r += 1) {
                            const tr = rows_buf[r];
                            var len = tree.renderPrefix(&text_buf, tr.depth, tr.is_last, null);
                            len = tree.appendText(&text_buf, len, tr.label);
                            if (tr.kind == .dir and len < text_buf.len) {
                                text_buf[len] = '/';
                                len += 1;
                                w.writeText(&surface, ctx, 2, kv_row, text_buf[0..len], theme.boldOn(theme.PANEL, theme.ACCENT));
                            } else {
                                const file_i = orig_idx[tr.leaf_idx];
                                const sel = file_i == self.ws_list_sel;
                                if (sel) {
                                    surface.writeCell(1, kv_row, .{
                                        .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                                        .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                                    });
                                }
                                const name_style = if (sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
                                w.writeText(&surface, ctx, 2, kv_row, text_buf[0..len], name_style);
                            }
                            kv_row += 1;
                        }
                    }
                } else {
                    w.writeText(&surface, ctx, 2, kv_row, "No context files.", theme.fg(theme.MUTED));
                }
            },
            .prompts => {
                var kv_row: u16 = 2;
                if (live_ws) |ws_d| {
                    if (ws_d.ws_prompts.len == 0) {
                        w.writeText(&surface, ctx, 2, kv_row, "No workspace prompts.", theme.fg(theme.MUTED));
                    } else {
                        const MAX_ROWS = 128;
                        const lib_prompts = self.getPrompts();
                        var paths_buf: [MAX_ROWS][]const u8 = undefined;
                        var orig_idx: [MAX_ROWS]usize = undefined;
                        const n = @min(ws_d.ws_prompts.len, MAX_ROWS);
                        for (0..n) |i| {
                            const wp = ws_d.ws_prompts[i];
                            paths_buf[i] = for (lib_prompts) |lp| {
                                if (std.mem.eql(u8, lp.content_hash, wp.content_hash)) break lp.path;
                            } else wp.prompt_id;
                            orig_idx[i] = i;
                        }
                        const SortCtx = struct {
                            paths: [*]const []const u8,
                            fn lt(cx: @This(), a: usize, b: usize) bool {
                                return std.mem.lessThan(u8, cx.paths[a], cx.paths[b]);
                            }
                        };
                        std.mem.sort(usize, orig_idx[0..n], SortCtx{ .paths = &paths_buf }, SortCtx.lt);
                        var sorted_paths: [MAX_ROWS][]const u8 = undefined;
                        for (0..n) |i| sorted_paths[i] = paths_buf[orig_idx[i]];

                        var rows_buf: [MAX_ROWS]tree.Row = undefined;
                        const row_count = tree.flatten(sorted_paths[0..n], null, &rows_buf);

                        var text_buf: [96]u8 = undefined;
                        var r: usize = 0;
                        while (r < row_count and kv_row < inner_h + 2) : (r += 1) {
                            const tr = rows_buf[r];
                            var len = tree.renderPrefix(&text_buf, tr.depth, tr.is_last, null);
                            len = tree.appendText(&text_buf, len, tr.label);
                            if (tr.kind == .dir and len < text_buf.len) {
                                text_buf[len] = '/';
                                len += 1;
                                w.writeText(&surface, ctx, 2, kv_row, text_buf[0..len], theme.boldOn(theme.PANEL, theme.ACCENT));
                            } else {
                                const wp_i = orig_idx[tr.leaf_idx];
                                const sel = wp_i == self.ws_list_sel;
                                if (sel) {
                                    surface.writeCell(1, kv_row, .{
                                        .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
                                        .style = .{ .fg = theme.ACCENT_SOFT, .bg = theme.PANEL },
                                    });
                                }
                                const name_style = if (sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
                                w.writeText(&surface, ctx, 2, kv_row, text_buf[0..len], name_style);
                                // Draft marker: the full prompt path lives in sorted_paths[r]; hasDraftFor matches on path.
                                if (self.hasDraftFor(sorted_paths[tr.leaf_idx])) {
                                    const nw: u16 = @intCast(ctx.stringWidth(text_buf[0..len]));
                                    w.writeText(&surface, ctx, 2 + nw + 1, kv_row, "*", theme.fg(theme.WARN));
                                }
                            }
                            kv_row += 1;
                        }
                    }
                } else {
                    w.writeText(&surface, ctx, 2, kv_row, "No workspace prompts.", theme.fg(theme.MUTED));
                }
            },
        }
        return surface;
    }

    // Workspace content pane: shows selected item's content
    fn drawWsDetail(self: *Dashboard, ctx: vxfw.DrawContext, ws: ?*const data.WorkspaceEntry) std.mem.Allocator.Error!vxfw.Surface {
        _ = ws;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        const content_border = if (self.ws_focus == .content) theme.ACCENT else theme.BORDER;
        w.fillSurface(&surface, theme.PANEL);
        w.drawBorder(&surface, content_border, theme.PANEL);

        // Check for live workspace detail data
        self.api_state.mutex.lock();
        const live_ws = self.api_state.ws_detail;
        self.api_state.mutex.unlock();

        if (live_ws == null) {
            w.writeText(&surface, ctx, 2, 0, "Content", theme.boldOn(theme.PANEL, theme.TEXT));
            w.writeText(&surface, ctx, 2, 2, "No workspace data loaded.", theme.fg(theme.MUTED));
            return surface;
        }
        const ws_d = live_ws.?;
        const sel = self.ws_list_sel;

        // Title: selected item name
        const title: []const u8 = switch (self.ws_tab) {
            .context => if (sel < ws_d.context_files.len) ws_d.context_files[sel].path else "no files",
            .prompts => if (sel < ws_d.ws_prompts.len) ws_d.ws_prompts[sel].prompt_id else "no prompts",
        };
        // Title with diff marker
        const has_diff: bool = false; // Live data does not yet track diff state
        w.writeText(&surface, ctx, 2, 0, title, theme.boldOn(theme.PANEL, if (has_diff) theme.WARN else theme.TEXT));
        if (self.ws_show_diff) {
            const tw: u16 = @intCast(ctx.stringWidth(title));
            w.writeText(&surface, ctx, 2 + tw + 2, 0, "diff", theme.boldOn(theme.PANEL, theme.ACCENT));
        }

        var kv_row: u16 = 2;
        const max_row = ctx.max.height.? -| 1;

        switch (self.ws_tab) {
            .context => {
                if (sel < ws_d.context_files.len) {
                    const f = &ws_d.context_files[sel];
                    if (self.ws_show_diff) {
                        w.writeText(&surface, ctx, 2, kv_row, "No diff available", theme.fg(theme.MUTED));
                    } else {
                        w.writeText(&surface, ctx, 2, kv_row, f.path, theme.fg(theme.TEXT_SOFT));
                        kv_row += 1;
                        if (kv_row < max_row) {
                            const size_label = try std.fmt.allocPrint(ctx.arena, "hash: {s}", .{f.hash});
                            w.writeText(&surface, ctx, 2, kv_row, size_label, theme.fg(theme.MUTED));
                        }
                    }
                } else {
                    w.writeText(&surface, ctx, 2, kv_row, "No context files.", theme.fg(theme.MUTED));
                }
            },
            .prompts => {
                if (sel < ws_d.ws_prompts.len) {
                    const p = &ws_d.ws_prompts[sel];
                    if (self.ws_show_diff) {
                        w.writeText(&surface, ctx, 2, kv_row, "No diff available", theme.fg(theme.MUTED));
                    } else {
                        w.writeText(&surface, ctx, 2, kv_row, p.prompt_id, theme.fg(theme.TEXT_SOFT));
                        kv_row += 1;
                        if (kv_row < max_row) {
                            const hash_label = try std.fmt.allocPrint(ctx.arena, "hash: {s}", .{p.content_hash});
                            w.writeText(&surface, ctx, 2, kv_row, hash_label, theme.fg(theme.MUTED));
                        }
                    }
                } else {
                    w.writeText(&surface, ctx, 2, kv_row, "No workspace prompts.", theme.fg(theme.MUTED));
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

        // Use live stats if available, otherwise zero-initialized defaults
        var live_insights: ?data.InsightsData = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.org_stats) |stats|
                break :blk api.insightsFromStats(ctx.arena, stats, self.api_state.prompts, self.api_state.ws_stats_members, self.api_state.ws_stats_models, self.api_state.local_stats);
            // No server stats, but local trace available — show personal data
            if (self.api_state.local_stats) |local| break :blk data.InsightsData{
                .constraint_count = local.constraint_count,
                .active_constraint_count = local.active_constraint_count,
                .idle_constraint_count = if (local.constraint_count > local.active_constraint_count) local.constraint_count - local.active_constraint_count else 0,
                .signal_ratio = local.signal_ratio,
                .refer_trend = local.refer_trend,
                .prompts = local.prompts,
            };
            break :blk null;
        };
        var empty_insights: data.InsightsData = .{
            .constraint_count = 0,
            .active_constraint_count = 0,
            .idle_constraint_count = 0,
            .signal_ratio = 0,
            .refers_per_hour = 0,
            .today_delta_pct = 0,
            .last_event_minutes_ago = 0,
            .refer_trend = .{0} ** 30,
            .prompts = &.{},
            .members = &.{},
            .models = &.{},
            .alerts = &.{},
        };
        const ins: *const data.InsightsData = if (live_insights) |*li| li else &empty_insights;

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
        const bar_start: u16 = name_w + 1;
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
                w.writeText(&s, ctx, 2, row, p.name, name_style);
                w.writeText(&s, ctx, col_rate, row, "0/d", theme.fg(theme.MUTED));
                w.writeText(&s, ctx, col_delta, row, " 0%", theme.fg(theme.MUTED));
                const sig_txt = try std.fmt.allocPrint(ctx.arena, "0/{d}", .{p.constraint_count});
                w.writeText(&s, ctx, col_sig, row, sig_txt, theme.fg(theme.MUTED));
            } else {
                const name_style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
                w.writeText(&s, ctx, 2, row, p.name, name_style);

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
        if (ins.members.len == 0) {
            var s = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
            w.fillSurface(&s, theme.PANEL);
            w.drawBorder(&s, theme.BORDER, theme.PANEL);
            w.writeText(&s, ctx, 2, 2, "No member data available.", theme.fg(theme.MUTED));
            return s;
        }
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
            w.writeText(&sidebar, ctx, 2, row, tab.label(), style);
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
        const UserView = struct { user_id: []const u8, username: []const u8, role: []const u8, workspaces: []const data.WsAccess };
        const user: UserView = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.current_user) |u|
                break :blk .{ .user_id = u.user_id, .username = u.username, .role = u.role, .workspaces = &.{} };
            break :blk .{ .user_id = "\xe2\x80\x94", .username = "\xe2\x80\x94", .role = "\xe2\x80\x94", .workspaces = &.{} };
        };
        const cfg: data.ClientConfig = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            const url = if (self.api_state.hub_url) |u| u else "\xe2\x80\x94";
            if (self.api_state.current_user) |_|
                break :blk .{ .server_url = url, .sync_strategy = "session", .token_status = "active", .token_expires = "\xe2\x80\x94" };
            break :blk .{ .server_url = url, .sync_strategy = "\xe2\x80\x94", .token_status = "\xe2\x80\x94", .token_expires = "\xe2\x80\x94" };
        };
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
        if (user.workspaces.len == 0) {
            w.writeText(&surface, ctx, 4, row, "No workspaces", theme.fg(theme.MUTED));
            return surface;
        }
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
            const badge_fg = switch (ws_access.role) {
                .member => theme.OK,
                .admin => theme.ACCENT,
            };
            const level_label = switch (ws_access.role) {
                .member => "member",
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

        // Use live directory or mock members
        self.api_state.mutex.lock();
        const live_dir = self.api_state.directory;
        self.api_state.mutex.unlock();

        const MemberView = struct { username: []const u8, role: []const u8, joined: []const u8 };
        var member_views: std.ArrayList(MemberView) = .empty;

        if (live_dir) |dir| {
            for (dir.members) |m| {
                try member_views.append(ctx.arena, .{ .username = m.username, .role = m.role, .joined = m.joined_at });
            }
        }
        // No fallback: empty list when not connected

        var maintainer_count: u16 = 0;
        for (member_views.items) |m| {
            if (std.mem.eql(u8, m.role, "maintainer")) maintainer_count += 1;
        }
        const members_title = try std.fmt.allocPrint(ctx.arena, "Members ({d}  {d} maintainer, {d} member)", .{ member_views.items.len, maintainer_count, member_views.items.len - maintainer_count });
        row = w.writeSectionHeader(&surface, ctx, 2, row, members_title);

        w.writeText(&surface, ctx, 4, row, "USERNAME", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 18, row, "ROLE", theme.fg(theme.MUTED));
        w.writeText(&surface, ctx, 30, row, "JOINED", theme.fg(theme.MUTED));
        row += 1;

        for (member_views.items, 0..) |m, i| {
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
            w.writeText(&surface, ctx, 30, row, m.joined, theme.fg(theme.MUTED));
            row += 1;
            if (row >= size.height -| 4) break;
        }

        return surface;
    }

    fn drawSettingsToken(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const focused = self.settings_focus == .content;
        // Use live scopes (comma-separated string from /api/auth/me) or mock
        const live_scopes: ?[]const u8 = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.current_user) |u| break :blk u.scopes;
            break :blk null;
        };
        const t: data.TokenInfo = .{ .scopes = &.{}, .expires = "\xe2\x80\x94" };
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&surface, theme.PANEL);
        w.drawBorder(&surface, if (focused) theme.ACCENT else theme.BORDER, theme.PANEL);
        w.writeText(&surface, ctx, 2, 0, "Token", theme.boldOn(theme.PANEL, theme.TEXT));

        var row: u16 = 2;
        // Token info
        var active_count: u16 = 0;
        for (data.ALL_SCOPES) |scope_def| {
            if (live_scopes) |scopes_csv| {
                if (std.mem.indexOf(u8, scopes_csv, scope_def.name) != null) active_count += 1;
            } else {
                for (t.scopes) |active| {
                    if (std.mem.eql(u8, scope_def.name, active)) {
                        active_count += 1;
                        break;
                    }
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
            const is_active = if (live_scopes) |scopes_csv|
                std.mem.indexOf(u8, scopes_csv, scope_def.name) != null
            else blk: {
                for (t.scopes) |active| {
                    if (std.mem.eql(u8, scope_def.name, active)) break :blk true;
                }
                break :blk false;
            };
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

    // Count active drafts (status != "merged") across all categories.
    fn draftCount(self: *Dashboard) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const drafts = self.api_state.drafts orelse return 0;
        var count: usize = 0;
        for (drafts) |d| {
            if (!std.mem.eql(u8, d.status, "merged")) count += 1;
        }
        return count;
    }

    // Returns true if any active draft targets the given prompt path.
    fn hasDraftFor(self: *Dashboard, prompt_path: []const u8) bool {
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

    fn getPrsForPrompt(self: *Dashboard, prompt_path: []const u8) []const data.PullRequestEntry {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const live_prs = self.api_state.prompt_prs;
        if (live_prs) |prs| {
            // Only trust the cached PR list when it was fetched for this path.
            if (self.api_state.prompt_prs_for_path) |cached| {
                if (!std.mem.eql(u8, cached, prompt_path)) return &.{};
            } else {
                return &.{};
            }
            const alloc = self.api_state.arena.allocator();
            return api.toPrEntries(alloc, prs, prompt_path, self.api_state);
        }
        return &.{};
    }

    fn getPrompts(self: *Dashboard) []const data.PromptEntry {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.prompts) |lp| {
            const alloc = self.api_state.arena.allocator();
            return api.toPromptEntries(alloc, lp);
        }
        return &.{};
    }

    fn submitComment(self: *Dashboard) void {
        const all_p = self.getPrompts();
        const si = @min(self.selected_prompt, if (all_p.len > 0) all_p.len - 1 else 0);
        if (all_p.len == 0) return;
        const prs_for = self.getPrsForPrompt(all_p[si].path);
        const pri = @min(self.selected_pr_idx, if (prs_for.len > 0) prs_for.len - 1 else 0);
        if (prs_for.len == 0) return;

        const alloc = self.api_state.arena.allocator();
        const path = std.fmt.allocPrint(alloc, "/api/org/prompt-prs/{s}/comments", .{prs_for[pri].id}) catch {
            self.status_line = "Failed to submit comment";
            return;
        };
        const comment_text = self.comment_input_buf[0..self.comment_input_len];
        const body = std.fmt.allocPrint(alloc, "{{\"body\":\"{s}\"}}", .{comment_text}) catch {
            self.status_line = "Failed to submit comment";
            return;
        };
        _ = api.postAction(self.api_state, alloc, .POST, path, body) catch {
            self.status_line = "Comment submission failed";
            return;
        };
        self.status_line = "Comment submitted.";
    }

    fn doPrAction(self: *Dashboard, action: []const u8) void {
        const all_p = self.getPrompts();
        const si = @min(self.selected_prompt, if (all_p.len > 0) all_p.len - 1 else 0);
        if (all_p.len == 0) return;
        const prs_for = self.getPrsForPrompt(all_p[si].path);
        const pri = @min(self.selected_pr_idx, if (prs_for.len > 0) prs_for.len - 1 else 0);
        if (prs_for.len == 0) return;
        const pr_id = prs_for[pri].id;

        const alloc = self.api_state.arena.allocator();
        const path = std.fmt.allocPrint(alloc, "/api/org/prompt-prs/{s}", .{pr_id}) catch {
            self.status_line = "Failed to build request";
            return;
        };
        const body = std.fmt.allocPrint(alloc, "{{\"action\":\"{s}\"}}", .{action}) catch {
            self.status_line = "Failed to build request";
            return;
        };
        _ = api.postAction(self.api_state, alloc, .PUT, path, body) catch {
            self.status_line = if (std.mem.eql(u8, action, "accept")) "Accept failed" else "Reject failed";
            return;
        };
        self.status_line = if (std.mem.eql(u8, action, "accept")) "PR accepted" else "PR rejected";
        self.show_pr_diff = false;
    }

    fn orgMemberCount(self: *Dashboard) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.directory) |dir| return dir.members.len;
        return 0;
    }

    fn accountWorkspaceCount(self: *Dashboard) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.current_user) |u| return u.workspaces.len;
        return 0;
    }

    fn wsCount(self: *Dashboard) usize {
        return self.getWorkspaces().len;
    }

    fn getWorkspaces(self: *Dashboard) []const data.WorkspaceEntry {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.current_user) |u| {
            const alloc = self.api_state.arena.allocator();
            var list: std.ArrayList(data.WorkspaceEntry) = .empty;
            for (u.workspaces) |ws| {
                const al: data.AccessLevel = if (std.mem.eql(u8, ws.role, "admin")) .admin else .member;
                list.append(alloc, .{
                    .name = ws.name,
                    .prompts = 0,
                    .contexts = 0,
                    .overrides = 0,
                    .local_rev = 0,
                    .remote_rev = 0,
                    .paths = 0,
                    .open_prs = 0,
                    .last_sync = "\xe2\x80\x94",
                    .access_level = al,
                }) catch continue;
            }
            return list.toOwnedSlice(alloc) catch &.{};
        }
        return &.{};
    }

    fn wsContextCount(self: *Dashboard) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.ws_detail) |ws_d| return ws_d.context_files.len;
        return 0;
    }

    fn wsPromptsCount(self: *Dashboard) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.ws_detail) |ws_d| return ws_d.ws_prompts.len;
        return 0;
    }

    const InsightsCounts = struct { prompt_count: usize, member_count: usize };

    fn getInsightsCounts(self: *Dashboard) InsightsCounts {
        // Returns counts of prompts and members for bounds checking in event handler.
        // Uses live org_stats prompt/member counts if available, else 0.
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.org_stats) |stats| {
            return .{
                .prompt_count = stats.prompts.len,
                .member_count = if (self.api_state.ws_stats_members) |m| m.len else 0,
            };
        }
        return .{ .prompt_count = 0, .member_count = 0 };
    }

    fn drawEmptyDetail(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        const border_color = if (self.detail_focus_content) theme.ACCENT else theme.BORDER;
        w.fillSurface(&surface, theme.PANEL);
        w.drawBorder(&surface, border_color, theme.PANEL);
        w.writeText(&surface, ctx, 2, 0, "Detail", theme.boldOn(theme.PANEL, theme.TEXT));
        w.writeText(&surface, ctx, 2, 2, "No prompts loaded.", theme.fg(theme.MUTED));
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
            .revoke_token => "Revoke token?",
            .quit => "Quit clumsies?",
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
        const all_prompts = self.getPrompts();
        const sel_idx = @min(self.selected_prompt, if (all_prompts.len > 0) all_prompts.len - 1 else 0);
        const title = if (all_prompts.len > 0) blk: {
            const p = &all_prompts[sel_idx];
            const prs = self.getPrsForPrompt(p.path);
            break :blk if (prs.len > 0 and self.selected_pr_idx < prs.len)
                try std.fmt.allocPrint(ctx.arena, " Comment on {s} ", .{prs[self.selected_pr_idx].id})
            else
                @as([]const u8, " New Comment ");
        } else @as([]const u8, " New Comment ");
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

    // Library: directory tree flattened by current expansion state.
    // Each row is either a directory node (library_row_dir_path[r] != null)
    // or a leaf prompt (library_prompt_indices[r] != null). Cursor can land
    // on either; Enter toggles dir expansion or focuses detail for leaves.
    fn syncLibraryWidgets(self: *Dashboard) void {
        const prompts = self.getPrompts();

        const bundles: []const data.BundleEntry = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.bundles) |lb| {
                const alloc = self.api_state.arena.allocator();
                break :blk api.toBundleEntries(alloc, lb);
            }
            break :blk &.{};
        };

        const filter_name: ?[]const u8 = if (self.library_bundle_filter == 0)
            null
        else if (self.library_bundle_filter - 1 < bundles.len)
            bundles[self.library_bundle_filter - 1].name
        else
            null;

        // Default-expand every depth-0 prefix the first time we see prompts.
        if (!self.library_tree_initialized and prompts.len > 0) {
            const alloc = self.api_state.arena.allocator();
            for (prompts) |p| {
                if (std.mem.indexOfScalar(u8, p.path, '/')) |i| {
                    const top = p.path[0 .. i + 1];
                    if (!self.library_expanded.contains(top)) {
                        _ = self.library_expanded.put(alloc, top, {}) catch {};
                    }
                }
            }
            self.library_tree_initialized = true;
        }

        // Filter prompts by bundle, collect paths into a parallel array
        // plus an index map back to the original prompts slice.
        var filtered_paths: [MAX_LIBRARY_ROWS][]const u8 = undefined;
        var filtered_orig: [MAX_LIBRARY_ROWS]usize = undefined;
        var filtered_len: usize = 0;
        for (prompts, 0..) |p, pidx| {
            if (filter_name) |fname| {
                if (std.mem.indexOf(u8, p.bundle_names, fname) == null) continue;
            }
            if (filtered_len >= MAX_LIBRARY_ROWS) break;
            filtered_paths[filtered_len] = p.path;
            filtered_orig[filtered_len] = pidx;
            filtered_len += 1;
        }

        // Sort filtered paths lexicographically so siblings are adjacent;
        // keep the index map in sync via a paired sort.
        var sort_idx: [MAX_LIBRARY_ROWS]usize = undefined;
        for (0..filtered_len) |si| sort_idx[si] = si;
        const SortCtx = struct {
            paths: [*]const []const u8,
            fn lt(ctx: @This(), a: usize, b: usize) bool {
                return std.mem.lessThan(u8, ctx.paths[a], ctx.paths[b]);
            }
        };
        std.mem.sort(usize, sort_idx[0..filtered_len], SortCtx{ .paths = &filtered_paths }, SortCtx.lt);

        var sorted_paths: [MAX_LIBRARY_ROWS][]const u8 = undefined;
        var sorted_orig: [MAX_LIBRARY_ROWS]usize = undefined;
        for (0..filtered_len) |si| {
            sorted_paths[si] = filtered_paths[sort_idx[si]];
            sorted_orig[si] = filtered_orig[sort_idx[si]];
        }

        var rows_buf: [MAX_LIBRARY_ROWS]tree.Row = undefined;
        const row_count = tree.flatten(sorted_paths[0..filtered_len], &self.library_expanded, &rows_buf);

        var i: usize = 0;
        while (i < row_count) : (i += 1) {
            const tr = rows_buf[i];
            const buf = &self.library_row_text_bufs[i];
            self.library_row_depth[i] = tr.depth;

            const chevron: ?tree.Chevron = if (tr.kind == .dir)
                (if (self.library_expanded.contains(tr.dir_prefix)) .expanded else .collapsed)
            else
                null;
            var len = tree.renderPrefix(buf, tr.depth, tr.is_last, chevron);
            len = tree.appendText(buf, len, tr.label);
            if (tr.kind == .dir and len < buf.len) {
                buf[len] = '/';
                len += 1;
            }

            if (tr.kind == .dir) {
                self.library_text_rows[i] = .{
                    .text = buf[0..len],
                    .style = theme.boldOn(theme.PANEL, theme.ACCENT),
                };
                self.library_widgets[i] = self.library_text_rows[i].widget();
                self.library_prompt_indices[i] = null;
                self.library_row_dir_path[i] = tr.dir_prefix;
            } else {
                const orig_pidx = sorted_orig[tr.leaf_idx];
                const p = prompts[orig_pidx];
                const pr_label: []const u8 = switch (p.open_pr_count) {
                    0 => "",
                    1 => "\xe2\x80\xa21",
                    2 => "\xe2\x80\xa22",
                    3 => "\xe2\x80\xa23",
                    else => "\xe2\x80\xa2+",
                };
                const sel = orig_pidx == self.selected_prompt;
                self.library_table_cols[i] = .{
                    .{ .text = buf[0..len], .flex = 1 },
                    .{ .text = pr_label, .flex = 0, .min_width = 2, .alignment = .right },
                };
                self.library_table_rows[i] = .{
                    .columns = &self.library_table_cols[i],
                    .style = theme.textOn(theme.PANEL, if (sel) theme.TEXT else theme.TEXT_SOFT),
                    .gap = 2,
                };
                self.library_widgets[i] = self.library_table_rows[i].widget();
                self.library_prompt_indices[i] = orig_pidx;
                self.library_row_dir_path[i] = null;
            }
        }
        // Clear trailing entries so stale dir/leaf markers don't linger.
        var c: usize = row_count;
        while (c < MAX_LIBRARY_ROWS) : (c += 1) {
            self.library_prompt_indices[c] = null;
            self.library_row_dir_path[c] = null;
        }

        self.library_row_count = row_count;
        self.library_scroll_bars.scroll_view.children = .{ .slice = self.library_widgets[0..row_count] };
        self.library_scroll_bars.estimated_content_height = @intCast(row_count);

        var cur = @as(usize, @intCast(self.library_scroll_bars.scroll_view.cursor));
        if (cur >= row_count) cur = if (row_count > 0) row_count - 1 else 0;
        self.library_scroll_bars.scroll_view.cursor = @intCast(cur);
        if (cur < row_count) {
            if (self.library_prompt_indices[cur]) |pi| {
                self.selected_prompt = pi;
            }
        }
    }

    fn toggleLibraryDir(self: *Dashboard, prefix: []const u8) void {
        const alloc = self.api_state.arena.allocator();
        if (self.library_expanded.fetchRemove(prefix)) |_| {
            return;
        }
        _ = self.library_expanded.put(alloc, prefix, {}) catch {};
    }

    fn syncContentWidget(self: *Dashboard) void {
        // Use live prompt content if available, else empty
        const content: []const u8 = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.prompt_content) |c| break :blk c;
            break :blk "";
        };
        self.content_text = .{
            .text = content,
            .style = theme.textOn(theme.PANEL, theme.TEXT_SOFT),
        };
        self.content_widget[0] = self.content_text.widget();
        self.content_scroll_bars.scroll_view.children = .{ .slice = self.content_widget[0..1] };
        self.content_scroll_bars.estimated_content_height = @intCast(@max(w.countLines(content), 24));

        // Trigger fetch for the selected prompt content and its PR list
        const prompts = self.getPrompts();
        if (self.selected_prompt < prompts.len) {
            const sel_path = prompts[self.selected_prompt].path;
            api.fetchPromptContentAsync(self.api_state, sel_path);
            api.fetchPromptPrsAsync(self.api_state, sel_path);
        }
    }

    fn syncPrWidgets(self: *Dashboard) void {
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

    fn syncPrDiffAndComments(self: *Dashboard, allocator: std.mem.Allocator) void {
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

    // Format the one-line operation header shown above the PR diff pane.
    // Falls back gracefully when op detail has not yet been fetched.
    fn opHeaderLine(arena: std.mem.Allocator, pr: *const data.PullRequestEntry) ![]const u8 {
        const position = if (pr.operation_count > 1)
            try std.fmt.allocPrint(arena, "op {d}/{d}", .{ pr.op_index + 1, pr.operation_count })
        else
            "op";
        if (pr.op_type.len == 0) return position;
        if (std.mem.eql(u8, pr.op_type, "rename")) {
            return std.fmt.allocPrint(arena, "{s}: rename {s} \xe2\x86\x92 {s}", .{ position, pr.op_current_path, pr.op_new_path });
        }
        const target = if (pr.op_current_path.len > 0) pr.op_current_path else pr.op_new_path;
        return std.fmt.allocPrint(arena, "{s}: {s} {s}", .{ position, pr.op_type, target });
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
        const max_prompt = blk: {
            const p = self.getPrompts();
            break :blk if (p.len > 0) p.len - 1 else 0;
        };
        self.selected_prompt = @min(prompt_idx, max_prompt);
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
