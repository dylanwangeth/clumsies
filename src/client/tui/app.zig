const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("theme.zig");
const w = @import("widgets.zig");
const data = @import("view_types.zig");
const api = @import("api.zig");
const analysis_panel = @import("app/analysis.zig");
const dashboard_panel = @import("app/dashboard.zig");
const library_panel = @import("app/library.zig");
const prompt_detail_panel = @import("app/prompt_detail.zig");
const settings_panel = @import("app/settings.zig");
const workspace_panel = @import("app/workspace.zig");

const tree = @import("tree.zig");
const trace_reader = @import("trace_reader.zig");
const Modal = @import("widgets/modal.zig").Modal;
const TextInput = @import("widgets/text_input.zig").TextInput;
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

const ConfirmAction = enum {
    none,
    remove_member,
    delete_bundle,
    delete_workspace,
    revoke_token,
    quit,
};

const TopModule = enum(u8) {
    dashboard,
    workspace,
    library,
    analysis,

    fn label(self: TopModule) []const u8 {
        return switch (self) {
            .dashboard => "Dashboard",
            .workspace => "Workspace",
            .library => "Library",
            .analysis => "Analysis",
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

const top_tabs = [_]TopModule{ .dashboard, .workspace, .library, .analysis };

const MAX_TREE_ROWS = 128;
const MAX_PR_ROWS = 64;
const detail_tabs = [_]DetailTab{ .content, .pull_requests };
const PathTreeState = tree.State(MAX_TREE_ROWS, 96);

pub const Dashboard = struct {
    api_state: *api.state.ApiState,
    selected_module: TopModule = .dashboard,
    selected_prompt: usize = 0,
    show_help: bool = false,
    show_settings: bool = false,
    show_confirm: bool = false,
    confirm_message: []const u8 = "",
    confirm_action: ConfirmAction = .none,
    detail_tab: DetailTab = .content,
    detail_focus_content: bool = false,
    settings_tab: SettingsTab = .account,
    settings_focus: enum { sidebar, content } = .sidebar,
    settings_content_sel: usize = 0, // cursor within content (members/workspaces list)
    status_line: []const u8 = "Ready.",

    // Library: tree-structured display with bundle filter
    library_bundle_filter: usize = 0,
    library_scroll_bars: vxfw.ScrollBars,
    library_tree: PathTreeState = .{},
    library_widgets: [MAX_TREE_ROWS]vxfw.Widget = undefined,
    library_text_rows: [MAX_TREE_ROWS]vxfw.Text = undefined,
    library_table_rows: [MAX_TREE_ROWS]TableRow = undefined,
    library_table_cols: [MAX_TREE_ROWS][2]Column = undefined,

    content_scroll_bars: vxfw.ScrollBars,

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
    selected_pr_idx: usize = 0,
    pr_diff_scroll_bars: vxfw.ScrollBars,
    pr_diff_widgets: [32]vxfw.Widget = undefined,
    pr_diff_rows: [32]vxfw.Text = undefined,
    pr_diff_count: usize = 0,
    // Comment editor state
    show_comment_editor: bool = false,
    comment_input_buf: [256]u8 = .{0} ** 256,
    comment_input_len: usize = 0,

    // Create Workspace overlay
    show_create_workspace: bool = false,
    create_ws_phase: workspace_panel.CreateWsPhase = .form,
    create_ws_focus: workspace_panel.CreateWsFocus = .name,
    create_ws_name_buf: [64]u8 = undefined,
    create_ws_name_len: usize = 0,
    create_ws_desc_buf: [256]u8 = undefined,
    create_ws_desc_len: usize = 0,
    create_ws_selected_bundle: ?usize = null,
    create_ws_bundle_cursor: usize = 0,
    create_ws_error_kind: workspace_panel.CreateWsErrorKind = .none,
    create_ws_error_buf: [160]u8 = undefined,
    create_ws_error_len: usize = 0,
    create_ws_created_id_buf: [64]u8 = undefined,
    create_ws_created_id_len: usize = 0,
    create_ws_created_name_buf: [64]u8 = undefined,
    create_ws_created_name_len: usize = 0,

    // Workspace Status
    ws_tab: WsTab = .context,
    ws_focus: WsFocus = .bar,
    ws_sel: usize = 0,
    ws_list_sel: usize = 0,
    ws_grid_cols: u16 = 3,
    ws_show_diff: bool = false,
    ws_context_tree: PathTreeState = .{},
    ws_prompts_tree: PathTreeState = .{},
    // Workspace uses manual grid + cached visible rows, no ScrollBars

    // Dashboard / Analysis shared state
    analysis_scope_idx: usize = 0,
    breathing_phase: u8 = 0, // 0-20 for breathing animation cycle
    analysis_focus: enum { chart, prompts, members, inputs } = .chart,
    analysis_prompt_cursor: usize = 0,
    analysis_member_cursor: usize = 0,
    analysis_input_cursor: usize = 0,
    analysis_expanded_prompt: ?usize = null,
    analysis_show_member_detail: bool = false,
    analysis_show_input_detail: bool = false,
    dashboard_input_capacity: usize = 1,
    view_arena: std.heap.ArenaAllocator,

    pub fn init(api_state: *api.state.ApiState) Dashboard {
        return .{
            .api_state = api_state,
            .library_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .content_scroll_bars = w.initPlainScrollBars(theme.PANEL, 3),
            .pr_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .pr_diff_scroll_bars = w.initPlainScrollBars(theme.PANEL, 2),
            .view_arena = std.heap.ArenaAllocator.init(api_state.backing_allocator),
        };
    }

    pub fn deinit(self: *Dashboard) void {
        self.view_arena.deinit();
        const alloc = self.api_state.allocator();
        self.library_tree.deinit(alloc);
        self.ws_context_tree.deinit(alloc);
        self.ws_prompts_tree.deinit(alloc);
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

    pub fn viewAllocator(self: *Dashboard) std.mem.Allocator {
        return self.view_arena.allocator();
    }

    pub fn currentWsTree(self: *Dashboard) *PathTreeState {
        return switch (self.ws_tab) {
            .context => &self.ws_context_tree,
            .prompts => &self.ws_prompts_tree,
        };
    }

    fn handleEvent(self: *Dashboard, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = self.view_arena.reset(.retain_capacity);
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
                                api.specs.dispatchFromState(
                                    api.specs.EmptyParams,
                                    void,
                                    api.specs.sign_out,
                                    &self.api_state.sign_out_pending,
                                    self.api_state,
                                    .{},
                                );
                                self.status_line = "Revoking token...";
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

                // Create Workspace overlay absorbs all keys
                if (self.show_create_workspace) {
                    self.handleCreateWorkspaceKey(ctx, key);
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

                // Top-level tab switching
                if (key.matches('1', .{})) return self.selectTab(ctx, .dashboard);
                if (key.matches('2', .{})) return self.selectTab(ctx, .workspace);
                if (key.matches('3', .{})) return self.selectTab(ctx, .library);
                if (key.matches('4', .{})) return self.selectTab(ctx, .analysis);

                // Module-specific input
                switch (self.selected_module) {
                    .library => try library_panel.handleModuleEvent(self, ctx, event, key),
                    .workspace => try workspace_panel.handleModuleEvent(self, ctx, key),
                    .dashboard => try dashboard_panel.handleModuleEvent(self, ctx, key, self.getAnalysisCounts().input_count),
                    .analysis => {
                        const counts = self.getAnalysisCounts();
                        try analysis_panel.handleModuleEvent(self, ctx, key, counts.prompt_count, counts.member_count);
                    },
                }
                return;
            },
            .init => {
                // Start breathing animation
                try ctx.tick(100, self.widget());
            },
            .tick => {
                // Advance breathing cycle: 0→20→0 (2 seconds at 100ms intervals)
                self.breathing_phase = (self.breathing_phase + 1) % 21;
                if ((self.selected_module == .dashboard or self.selected_module == .analysis) and (self.breathing_phase == 0 or self.breathing_phase == 10)) {
                    api.state.refreshLocalState(self.api_state);
                }
                _ = self.consumeCreateWsResult();
                self.consumePromptContentResult();
                self.consumePromptPrsResult();
                self.consumeWsContextContentResult();
                self.consumeWsContextFilesResult();
                self.consumeWsManifestResult();
                self.consumePrDetailResult();
                self.consumePrCommentsResult();
                self.consumeSignOutResult();
                self.consumeSubmitCommentResult();
                self.consumePrActionResult();
                ctx.redraw = true;
                try ctx.tick(100, self.widget());
            },
            else => {},
        }
    }

    fn draw(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        _ = self.view_arena.reset(.retain_capacity);
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

        const show_input_overlay = self.analysis_show_input_detail and self.selected_module == .dashboard;
        var child_count: usize = 3;
        if (self.show_help or self.show_confirm or self.show_comment_editor or
            self.show_create_workspace or show_input_overlay) child_count = 4;

        const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawHeader(header_ctx) };
        children[1] = .{ .origin = .{ .row = header_h, .col = 0 }, .surface = try self.drawBody(body_ctx) };
        children[2] = .{ .origin = .{ .row = header_h + body_h, .col = 0 }, .surface = try self.drawFooter(footer_ctx) };

        if (show_input_overlay) {
            const input_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[3] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawInputDetailOverlay(input_ctx) };
        }
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
        if (self.show_create_workspace) {
            const full_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[3] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try workspace_panel.drawCreateOverlay(self, full_ctx),
            };
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
            const is_active = if (self.show_settings) false else (tab == self.selected_module);
            col = w.drawTabBadge(&surface, ctx, 2, col, label, is_active);
            col +|= 1;
        }

        return surface;
    }

    fn drawBody(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        if (self.show_settings) return self.drawSettings(ctx);
        return switch (self.selected_module) {
            .dashboard => self.drawDashboard(ctx),
            .library => self.drawLibrary(ctx),
            .workspace => self.drawWorkspaceStatus(ctx),
            .analysis => self.drawAnalysis(ctx),
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
            "j/k move  Enter go to workspace  x sign out  Esc back"
        else if (self.show_settings and self.settings_tab == .organization)
            "j/k move  a invite  r role  x remove  Esc back"
        else if (self.show_settings and self.settings_tab == .token)
            "j/k move  r refresh  x revoke  Esc back"
        else if (self.show_settings)
            "j/k move  Esc back"
        else if (self.show_comment_editor)
            "Enter send  Esc cancel"
        else switch (self.selected_module) {
            .dashboard => switch (self.analysis_focus) {
                .chart => "Tab focus  w scope  Shift-F flush  ? help  q quit",
                .inputs => "j/k move  Enter detail  Tab focus  w scope  Shift-F flush  ? help  q quit",
                else => "Tab focus  w scope  Shift-F flush  ? help  q quit",
            },
            .library => if (self.detail_focus_content and self.detail_tab == .pull_requests)
                "j/k scroll  a accept  x reject  c comment  Esc list  ? help"
            else if (self.detail_focus_content)
                "j/k scroll  g/G jump  Esc list  ? help"
            else if (self.detail_tab == .pull_requests)
                "j/k move  f filter  T tab  Tab detail  r refresh  ? help  q quit"
            else
                "j/k move  T tab  Enter detail  r refresh  b bundle  S settings  ? help  q quit",
            .workspace => switch (self.ws_focus) {
                .bar => "j/k select workspace  c create  Tab list  r refresh  ? help  q quit",
                .list => "h/l tab  j/k move  ←/→ tree  Enter open  c create  Esc bar  ? help",
                .content => "j/k scroll  d toggle diff  c create  Esc list  ? help",
            },
            .analysis => switch (self.analysis_focus) {
                .prompts => "j/k move  Enter expand  Tab focus  ? help  q quit",
                .members => "j/k move  Enter detail  Tab focus  ? help  q quit",
                else => "Tab focus  ? help  q quit",
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
            !self.show_comment_editor and
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

    // Library: master-detail. Left panel carries a Files / Pull Requests
    // inner tab strip; right panel is a single detail surface that
    // follows whichever item the left panel has selected.
    fn drawLibrary(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        library_panel.syncLibraryWidgets(self);

        const size = ctx.max.size();
        const list_w: u16 = size.width / 3;
        const prompts = self.getPrompts();
        const sel_idx = @min(self.selected_prompt, if (prompts.len > 0) prompts.len - 1 else 0);

        const list_ctx = ctx.withConstraints(.{ .width = list_w, .height = size.height }, .{ .width = list_w, .height = size.height });
        const detail_w: u16 = size.width - list_w - 1;
        const detail_ctx = ctx.withConstraints(.{ .width = detail_w, .height = size.height }, .{ .width = detail_w, .height = size.height });
        const list_surface = try self.drawListPanel(list_ctx);
        const detail_surface = if (prompts.len > 0)
            try prompt_detail_panel.drawEmbedded(self, detail_ctx, &prompts[sel_idx])
        else
            try prompt_detail_panel.drawEmbeddedEmpty(self, detail_ctx);
        return library_panel.drawRoot(self, ctx, list_surface, detail_surface);
    }

    fn drawListPanel(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const bundles_list = self.getBundles();
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
        return library_panel.drawListPanel(self, ctx, bundle_label, prompt_count);
    }

    // Workspace: top workspace bar + bottom master-detail (list | content).
    // Tab cycles focus: workspace bar -> list -> content -> bar.
    fn drawWorkspaceStatus(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const wss = self.getWorkspaces();
        const size = ctx.max.size();
        const inner_w = size.width -| 2;
        const cols: u16 = if (inner_w >= 120) 4 else if (inner_w >= 80) 3 else 2;
        const ws_count: u16 = @intCast(if (wss.len > 0) wss.len else 1);
        const grid_rows: u16 = (ws_count + cols - 1) / cols;
        const bar_h: u16 = 1 + grid_rows + 1;
        const body_h = size.height - bar_h;
        const list_w: u16 = size.width / 3;
        const detail_w: u16 = size.width - list_w - 1;
        const list_ctx = ctx.withConstraints(.{ .width = list_w, .height = body_h }, .{ .width = list_w, .height = body_h });
        const detail_ctx = ctx.withConstraints(.{ .width = detail_w, .height = body_h }, .{ .width = detail_w, .height = body_h });
        const list_surface = try self.drawWsList(list_ctx);
        const detail_surface = try self.drawWsDetail(detail_ctx);
        return workspace_panel.drawStatus(self, ctx, wss, list_surface, detail_surface);
    }

    fn drawWsList(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        workspace_panel.syncWsRows(self);
        const live_ws = if (self.activeWsId()) |ws_id|
            api.state.wsDetail(self.api_state, ws_id)
        else
            null;
        const lib_prompts: []const data.PromptEntry = if (self.ws_tab == .prompts) self.getPrompts() else &.{};
        return workspace_panel.drawList(self, ctx, self.currentWsTree(), live_ws, lib_prompts);
    }

    /// ws_id of the currently-selected workspace, or null when the
    /// workspace list is empty / not loaded yet. Reads ws_id directly
    /// off the authoritative `current_user.workspaces` list because
    /// the view-layer `WorkspaceEntry` intentionally omits it.
    pub fn activeWsId(self: *Dashboard) ?[]const u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const user = self.api_state.current_user orelse return null;
        if (user.workspaces.len == 0) return null;
        const idx = @min(self.ws_sel, user.workspaces.len - 1);
        return user.workspaces[idx].ws_id;
    }

    pub fn resetWorkspaceTrees(self: *Dashboard) void {
        self.ws_context_tree.reset();
        self.ws_prompts_tree.reset();
        self.ws_list_sel = 0;
    }

    fn currentWsDirSelection(self: *Dashboard) ?[]const u8 {
        return self.currentWsTree().dirPathAt(self.ws_list_sel);
    }

    fn resolveWsContextSelection(self: *Dashboard, ws_d: *const api.model.WsDetail) ?usize {
        _ = ws_d;
        return self.currentWsTree().leafIndexAt(self.ws_list_sel);
    }

    const ResolvedWsPrompt = struct {
        idx: usize,
        path: []const u8,
    };

    fn cachedWorkspaceContextBody(self: *Dashboard, ws_id: []const u8, path: []const u8) ?[]const u8 {
        return self.api_state.ws_context_content_cache.lookup(.{ .ws_id = ws_id, .path = path });
    }

    pub fn cachedPromptBody(self: *Dashboard, path: []const u8) ?[]const u8 {
        const resp = self.api_state.prompt_content_cache.lookup(.{ .value = path }) orelse return null;
        return resp.body;
    }

    pub fn invalidateRemoteDetailRequests(self: *Dashboard) void {
        self.api_state.prompt_content_cache.invalidate();
        self.api_state.prompt_prs_cache.invalidate();
        self.api_state.ws_context_content_cache.invalidate();
    }

    pub fn requestSelectedPromptDetail(self: *Dashboard) void {
        const prompts = self.getPrompts();
        if (self.selected_prompt >= prompts.len) return;

        const sel_path = prompts[self.selected_prompt].path;
        const key = api.cache.StringKey{ .value = sel_path };

        if (self.api_state.prompt_content_cache.shouldDispatch(key)) {
            api.specs.dispatchFromState(
                api.specs.PathParams,
                @import("clumsies_lib").protocol.library_api.PromptContentResponse,
                api.specs.library_prompt_content,
                &self.api_state.prompt_content_pending,
                self.api_state,
                .{ .path = sel_path },
            );
        }

        if (self.api_state.prompt_prs_cache.shouldDispatch(key)) {
            const prompt_id = self.lookupPromptId(sel_path) orelse return;
            api.specs.dispatchFromState(
                api.specs.PromptPrsParams,
                api.specs.PromptPrsPayload,
                api.specs.library_prompt_prs,
                &self.api_state.prompt_prs_pending,
                self.api_state,
                .{ .prompt_id = prompt_id },
            );
        }
    }

    /// Look up the prompt_id that corresponds to `path` in the cached
    /// library prompt list. Returns null if the library has not loaded
    /// yet or the path is unknown.
    fn lookupPromptId(self: *Dashboard, path: []const u8) ?[]const u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const lib = self.api_state.prompts orelse return null;
        for (lib) |lp| {
            if (std.mem.eql(u8, lp.path, path)) return lp.prompt_id;
        }
        return null;
    }

    /// Inverse of `lookupPromptId`: given a prompt_id, return the path
    /// that the prompt_prs cache is keyed by. Used by the prompt-prs
    /// consumer so it can route a completed response against its
    /// request id rather than against the UI's current selection.
    fn lookupPromptPath(self: *Dashboard, prompt_id: []const u8) ?[]const u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const lib = self.api_state.prompts orelse return null;
        for (lib) |lp| {
            if (std.mem.eql(u8, lp.prompt_id, prompt_id)) return lp.path;
        }
        return null;
    }

    /// Path of the currently selected library prompt, or null when no
    /// prompt is in focus. Used by failure-caching in the on-demand
    /// consumers, which do not have a request-scoped key to attribute
    /// the failure to and fall back to the current UI selection.
    fn selectedPromptPath(self: *Dashboard) ?[]const u8 {
        const prompts = self.getPrompts();
        if (prompts.len == 0) return null;
        const idx = @min(self.selected_prompt, prompts.len - 1);
        return prompts[idx].path;
    }

    fn requestWorkspaceSelectionContent(self: *Dashboard, ws_d: *const api.model.WsDetail) void {
        const dir_sel = self.currentWsDirSelection();
        switch (self.ws_tab) {
            .context => {
                if (dir_sel != null) return;
                const context_sel = self.resolveWsContextSelection(ws_d) orelse return;
                const file = &ws_d.context_files[context_sel];
                const key = api.state.WsPathKey{ .ws_id = ws_d.ws_id, .path = file.path };
                if (!self.api_state.ws_context_content_cache.shouldDispatch(key)) return;

                api.specs.dispatchFromState(
                    api.specs.WsContextContentParams,
                    api.specs.WsContextContentPayload,
                    api.specs.workspace_context_content,
                    &self.api_state.ws_context_content_pending,
                    self.api_state,
                    .{ .ws_id = ws_d.ws_id, .path = file.path },
                );
            },
            .prompts => {
                if (dir_sel != null) return;
                const prompt_sel = self.resolveWsPromptSelection(ws_d) orelse return;
                const key = api.cache.StringKey{ .value = prompt_sel.path };
                if (!self.api_state.prompt_content_cache.shouldDispatch(key)) return;

                api.specs.dispatchFromState(
                    api.specs.PathParams,
                    @import("clumsies_lib").protocol.library_api.PromptContentResponse,
                    api.specs.library_prompt_content,
                    &self.api_state.prompt_content_pending,
                    self.api_state,
                    .{ .path = prompt_sel.path },
                );
            },
        }
    }

    fn resolveWsPromptSelection(self: *Dashboard, ws_d: *const api.model.WsDetail) ?ResolvedWsPrompt {
        const idx = self.currentWsTree().leafIndexAt(self.ws_list_sel) orelse return null;
        const lib_prompts = self.getPrompts();
        const wp = ws_d.ws_prompts[idx];
        const path = if (wp.path.len > 0)
            wp.path
        else for (lib_prompts) |lp| {
            if (std.mem.eql(u8, lp.content_hash, wp.content_hash)) break lp.path;
        } else wp.prompt_id;
        return .{ .idx = idx, .path = path };
    }

    // Workspace content pane: shows selected item's content
    fn drawWsDetail(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const live_ws = if (self.activeWsId()) |ws_id|
            api.state.wsDetail(self.api_state, ws_id)
        else
            null;
        workspace_panel.syncWsRows(self);
        if (live_ws) |ws_d| {
            self.requestWorkspaceSelectionContent(&ws_d);
        }
        const dir_sel = self.currentWsDirSelection();
        const context_sel = if (live_ws) |ws_d|
            self.resolveWsContextSelection(&ws_d)
        else
            null;
        const prompt_sel = if (live_ws) |ws_d|
            self.resolveWsPromptSelection(&ws_d)
        else
            null;
        const context_body: ?[]const u8 = if (live_ws != null and dir_sel == null and self.ws_tab == .context and context_sel != null)
            self.cachedWorkspaceContextBody(live_ws.?.ws_id, live_ws.?.context_files[context_sel.?].path)
        else
            null;
        const prompt_body: ?[]const u8 = if (dir_sel == null and self.ws_tab == .prompts and prompt_sel != null)
            self.cachedPromptBody(prompt_sel.?.path)
        else
            null;
        return workspace_panel.drawDetail(self, ctx, .{
            .live_ws = live_ws,
            .dir_sel = dir_sel,
            .context_sel = context_sel,
            .prompt_sel_idx = if (prompt_sel) |sel| sel.idx else null,
            .prompt_sel_path = if (prompt_sel) |sel| sel.path else null,
            .context_body = context_body,
            .prompt_body = prompt_body,
        });
    }

    fn loadAnalysisData(self: *Dashboard, arena: std.mem.Allocator) ?data.AnalysisData {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.org_stats) |stats| {
            return api.view_model.analysisFromStats(arena, stats, self.api_state.prompts, null);
        }
        return null;
    }

    // Dashboard: live scope-aware signal and recent input feed.
    fn drawDashboard(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const scope = self.currentAnalysisScope();
        const server_signal_ratio = self.serverSignalRatio();

        const scoped_trace = self.scopedTraceData();
        const signal_value_text: []const u8 = blk: {
            if (scoped_trace) |st| {
                if (st.constraint_count > 0) {
                    break :blk std.fmt.allocPrint(ctx.arena, "{d}%", .{st.signal_ratio}) catch "n/a";
                }
            }
            if (scope.ws_id == null) {
                if (server_signal_ratio) |sig| {
                    break :blk std.fmt.allocPrint(ctx.arena, "{d}%", .{sig}) catch "n/a";
                }
            }
            break :blk "n/a";
        };
        const chart_series: ChartSeries = if (scoped_trace) |st|
            self.buildLocalChartSeries(ctx.arena, st.refers)
        else
            .{ .values = &.{}, .left_label = "60s ago", .right_label = "now" };

        const inputs: []const trace_reader.InputEvent = if (scoped_trace) |st| st.inputs else &.{};

        const chart_h: u16 = if (size.height > 40) 10 else 8;
        const inputs_h: u16 = size.height -| chart_h;
        const usable_input_rows: u16 = inputs_h -| 2;
        self.dashboard_input_capacity = @max(@as(usize, 1), @as(usize, @intCast((usable_input_rows + 1) / 3)));
        const visible_inputs = latestInputs(inputs, self.dashboard_input_capacity);
        const active_count = self.activeSessionCount(scope.ws_id);
        const chart_surface = try dashboard_panel.drawChart(
            self,
            ctx,
            size.width,
            chart_h,
            signal_value_text,
            chart_series,
            scope.label,
            active_count,
        );
        const inputs_surface = try dashboard_panel.drawInputs(
            self,
            ctx,
            size.width,
            inputs_h,
            visible_inputs,
            scope.label,
        );
        return dashboard_panel.drawRoot(self, ctx, chart_surface, inputs_surface);
    }

    // Analysis: aggregate prompt/member views and drill-downs.
    fn drawAnalysis(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var live_analysis = self.loadAnalysisData(ctx.arena);
        const analysis_available = live_analysis != null;
        var empty_analysis: data.AnalysisData = .{
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
        const ins: *const data.AnalysisData = if (live_analysis) |*li| li else &empty_analysis;
        return analysis_panel.drawRoot(self, ctx, ins, analysis_available);
    }

    fn latestInputs(inputs: anytype, limit: usize) @TypeOf(inputs) {
        return inputs[0..@min(inputs.len, limit)];
    }

    // Settings: vertical sidebar + content pane (web-style layout)
    fn drawSettings(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        return settings_panel.drawSettings(self, ctx);
    }

    // Spawn `clumsies trace flush` synchronously and report the result in
    // the status line. Synchronous is fine here: the upload worker is a
    // short-lived CLI that flushes buffered trace events and exits.
    pub fn flushTrace(self: *Dashboard) void {
        self.status_line = "Flushing trace...";
        const alloc = self.api_state.allocator();
        var child = std.process.Child.init(&.{ "clumsies", "trace", "flush" }, alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch {
            self.status_line = "Flush failed: clumsies binary not found";
            return;
        };
        var stdout: std.ArrayList(u8) = .empty;
        var stderr: std.ArrayList(u8) = .empty;
        child.collectOutput(alloc, &stdout, &stderr, 64 * 1024) catch {};
        const term = child.wait() catch {
            self.status_line = "Flush failed: child wait error";
            return;
        };
        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    api.state.refreshLocalState(self.api_state);
                    const trimmed = std.mem.trim(u8, stdout.items, " \n\r\t");
                    if (trimmed.len > 0) {
                        self.status_line = std.fmt.allocPrint(alloc, "Flush: {s}", .{trimmed}) catch "Flush: ok";
                    } else {
                        self.status_line = "Flush: ok";
                    }
                } else {
                    const trimmed = std.mem.trim(u8, stderr.items, " \n\r\t");
                    self.status_line = std.fmt.allocPrint(alloc, "Flush exit {d}: {s}", .{ code, trimmed }) catch "Flush failed";
                }
            },
            else => self.status_line = "Flush terminated abnormally",
        }
    }

    fn activeSessionCount(self: *Dashboard, scope_ws_id: ?[]const u8) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const sessions = self.api_state.active_sessions orelse return 0;
        if (scope_ws_id) |ws_id| {
            var count: usize = 0;
            for (sessions) |sess| {
                if (std.mem.eql(u8, sess.ws_id, ws_id)) count += 1;
            }
            return count;
        }
        return sessions.len;
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

    pub fn getPrsForPrompt(self: *Dashboard, prompt_path: []const u8) []const data.PullRequestEntry {
        const prs = self.api_state.prompt_prs_cache.lookup(.{ .value = prompt_path }) orelse return &.{};
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        return api.view_model.toPrEntries(self.viewAllocator(), prs, prompt_path, self.api_state);
    }

    pub fn getPrompts(self: *Dashboard) []const data.PromptEntry {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.prompts) |lp| {
            return api.view_model.toPromptEntries(self.viewAllocator(), lp);
        }
        return &.{};
    }

    pub fn getBundles(self: *Dashboard) []const data.BundleEntry {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.bundles) |lb| {
            return api.view_model.toBundleEntries(self.viewAllocator(), lb);
        }
        return &.{};
    }

    pub fn openCreateWorkspace(self: *Dashboard) void {
        workspace_panel.resetCreate(self);
        self.show_create_workspace = true;
    }

    fn closeCreateWorkspace(self: *Dashboard) void {
        self.show_create_workspace = false;
        workspace_panel.resetCreate(self);
    }

    fn createWsBundleCount(self: *Dashboard) usize {
        return workspace_panel.createBundleCount(self);
    }

    fn createWsSelectedBundleName(self: *Dashboard) ?[]const u8 {
        return workspace_panel.createSelectedBundleName(self);
    }

    fn handleCreateWorkspaceKey(self: *Dashboard, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        switch (self.create_ws_phase) {
            .form => self.handleCreateWsFormKey(ctx, key),
            .submitting => self.handleCreateWsSubmittingKey(ctx, key),
            .success => self.handleCreateWsSuccessKey(ctx, key),
        }
    }

    fn handleCreateWsFormKey(self: *Dashboard, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.closeCreateWorkspace();
            ctx.consumeAndRedraw();
            return;
        }

        const bundles_n = self.createWsBundleCount();

        if (key.matches(vaxis.Key.tab, .{})) {
            self.create_ws_focus = self.create_ws_focus.next(bundles_n);
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
            self.create_ws_focus = self.create_ws_focus.prev(bundles_n);
            ctx.consumeAndRedraw();
            return;
        }

        switch (self.create_ws_focus) {
            .name => self.routeCreateWsTextInput(
                ctx,
                key,
                &self.create_ws_name_buf,
                &self.create_ws_name_len,
            ),
            .description => self.routeCreateWsTextInput(
                ctx,
                key,
                &self.create_ws_desc_buf,
                &self.create_ws_desc_len,
            ),
            .bundle => self.handleCreateWsBundleKey(ctx, key),
            .submit => self.handleCreateWsSubmitKey(ctx, key),
        }
    }

    fn routeCreateWsTextInput(
        self: *Dashboard,
        ctx: *vxfw.EventContext,
        key: vaxis.Key,
        buf: []u8,
        len: *usize,
    ) void {
        var input = TextInput{ .buf = buf, .len = len };
        switch (input.handleKey(key)) {
            .submit => {
                const bundles_n = self.createWsBundleCount();
                self.create_ws_focus = self.create_ws_focus.next(bundles_n);
                ctx.consumeAndRedraw();
            },
            .consumed => {
                self.create_ws_error_kind = .none;
                self.create_ws_error_len = 0;
                ctx.consumeAndRedraw();
            },
            .cancel, .ignored => ctx.consumeEvent(),
        }
    }

    fn handleCreateWsBundleKey(self: *Dashboard, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        const count = self.createWsBundleCount();
        if (count == 0) {
            ctx.consumeEvent();
            return;
        }
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.create_ws_bundle_cursor + 1 < count) self.create_ws_bundle_cursor += 1;
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.create_ws_bundle_cursor > 0) self.create_ws_bundle_cursor -= 1;
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(' ', .{}) or key.matches(vaxis.Key.enter, .{})) {
            if (self.create_ws_selected_bundle) |idx| {
                if (idx == self.create_ws_bundle_cursor) {
                    self.create_ws_selected_bundle = null;
                } else {
                    self.create_ws_selected_bundle = self.create_ws_bundle_cursor;
                }
            } else {
                self.create_ws_selected_bundle = self.create_ws_bundle_cursor;
            }
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeEvent();
    }

    fn handleCreateWsSubmitKey(self: *Dashboard, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.enter, .{}) or key.matches(' ', .{})) {
            self.submitCreateWorkspace();
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeEvent();
    }

    fn submitCreateWorkspace(self: *Dashboard) void {
        const name = self.create_ws_name_buf[0..self.create_ws_name_len];
        if (name.len == 0) {
            workspace_panel.setCreateNameRequired(self);
            self.create_ws_focus = .name;
            return;
        }

        self.create_ws_phase = .submitting;
        self.create_ws_error_kind = .none;
        self.create_ws_error_len = 0;

        const workspace_api = @import("clumsies_lib").protocol.workspace_api;
        api.specs.dispatchFromState(
            workspace_api.CreateWorkspaceRequest,
            workspace_api.CreateWorkspaceResponse,
            api.specs.create_workspace,
            &self.api_state.create_ws_pending,
            self.api_state,
            .{
                .name = name,
                .bundle_id = self.createWsSelectedBundleName(),
            },
        );
    }

    fn handleCreateWsSubmittingKey(self: *Dashboard, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.escape, .{})) {
            // Abandon the in-flight result; bg thread still finishes but result will be dropped
            // in consumeCreateWsResult when phase is no longer .submitting.
            self.closeCreateWorkspace();
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeEvent();
    }

    fn handleCreateWsSuccessKey(self: *Dashboard, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.closeCreateWorkspace();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches('c', .{})) {
            workspace_panel.copyCreateInitCommand(self);
            self.status_line = "Copied clumsies init command to clipboard.";
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeEvent();
    }

    fn consumeCreateWsResult(self: *Dashboard) bool {
        const result = self.api_state.create_ws_pending.consume() orelse return false;
        if (!self.show_create_workspace or self.create_ws_phase != .submitting) {
            // Overlay was closed while request was in flight — drop the result.
            return false;
        }
        workspace_panel.applyCreateResult(self, result);
        return true;
    }

    /// Pump the library prompt content pending slot: on .ok, stash the
    /// response in the cache keyed by path so subsequent draws can
    /// retrieve it synchronously. On any error outcome, record the
    /// failure against the selected path so widget sync does not
    /// re-dispatch on every tick; the next `invalidateOnDemandCaches`
    /// or a navigation to a different prompt clears the marker.
    fn consumePromptContentResult(self: *Dashboard) void {
        const result = self.api_state.prompt_content_pending.consume() orelse return;
        switch (result) {
            .ok => |resp| {
                self.api_state.prompt_content_cache.store(.{ .value = resp.path }, resp);
            },
            else => {
                if (self.selectedPromptPath()) |path| {
                    self.api_state.prompt_content_cache.markFailed(.{ .value = path });
                }
            },
        }
    }

    /// Pump the library prompt PR list pending slot. Routes the cache
    /// write against `payload.prompt_id` — the id the request was
    /// issued for — rather than the current UI selection, so a prompt
    /// switch mid-flight cannot store the list under the wrong path.
    /// On error, mark the currently selected prompt as failed so the
    /// widget loop does not re-dispatch on every tick.
    fn consumePromptPrsResult(self: *Dashboard) void {
        const result = self.api_state.prompt_prs_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                const path = self.lookupPromptPath(payload.prompt_id) orelse return;
                self.api_state.prompt_prs_cache.store(.{ .value = path }, payload.prs);
            },
            else => {
                if (self.selectedPromptPath()) |path| {
                    self.api_state.prompt_prs_cache.markFailed(.{ .value = path });
                }
            },
        }
    }

    /// Pump the workspace context files pending slot. Stores under the
    /// ws_id the request was issued for; `state.wsDetail` combines it
    /// with the manifest half to form the view.
    fn consumeWsContextFilesResult(self: *Dashboard) void {
        const result = self.api_state.ws_context_files_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.ws_context_files_cache.store(.{ .value = payload.ws_id }, payload.files);
            },
            else => {
                if (self.activeWsId()) |ws_id| {
                    self.api_state.ws_context_files_cache.markFailed(.{ .value = ws_id });
                }
            },
        }
    }

    fn consumeWsManifestResult(self: *Dashboard) void {
        const result = self.api_state.ws_manifest_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.ws_manifest_cache.store(.{ .value = payload.ws_id }, payload.prompts);
            },
            else => {
                if (self.activeWsId()) |ws_id| {
                    self.api_state.ws_manifest_cache.markFailed(.{ .value = ws_id });
                }
            },
        }
    }

    /// Pump the PR detail pending slot. On .ok, stash the raw response
    /// in the cache and recompute the derived view fields (picked
    /// operation, diff lines, trace refers) against the response's
    /// own pr_id so selection changes mid-flight cannot misroute
    /// either the cache entry or the derived fields.
    fn consumePrDetailResult(self: *Dashboard) void {
        const result = self.api_state.pr_detail_pending.consume() orelse return;
        switch (result) {
            .ok => |resp| {
                self.api_state.pr_detail_cache.store(.{ .value = resp.pr_id }, resp);
                self.refreshPrDetailDerivedFields(resp.pr_id, resp);
            },
            else => {
                if (self.activePrId()) |pr_id| {
                    self.api_state.pr_detail_cache.markFailed(.{ .value = pr_id });
                }
            },
        }
    }

    fn consumePrCommentsResult(self: *Dashboard) void {
        const result = self.api_state.pr_comments_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.pr_comments_cache.store(.{ .value = payload.pr_id }, payload.comments);
            },
            else => {
                if (self.activePrId()) |pr_id| {
                    self.api_state.pr_comments_cache.markFailed(.{ .value = pr_id });
                }
            },
        }
    }

    /// pr_id of the currently-selected PR in the prompt-detail drill-
    /// down, or null when nothing is selected.
    fn activePrId(self: *Dashboard) ?[]const u8 {
        const prompts = self.getPrompts();
        const prompt_idx = @min(self.selected_prompt, if (prompts.len > 0) prompts.len - 1 else 0);
        if (prompts.len == 0) return null;
        const prs = self.getPrsForPrompt(prompts[prompt_idx].path);
        if (prs.len == 0) return null;
        const pr_idx = @min(self.selected_pr_idx, prs.len - 1);
        return prs[pr_idx].id;
    }

    /// Recompute the 8 derived pr_detail_* fields from the just-fetched
    /// response. Picking the active operation requires the currently
    /// cached library PR list so the op matching the selected prompt
    /// is surfaced first.
    fn refreshPrDetailDerivedFields(
        self: *Dashboard,
        pr_id: []const u8,
        resp: @import("clumsies_lib").protocol.collab_api.PromptPrDetailResponse,
    ) void {
        const alloc = self.api_state.allocator();

        const prompts = self.getPrompts();
        const prompt_idx = @min(self.selected_prompt, if (prompts.len > 0) prompts.len - 1 else 0);
        const target_prompt_id: ?[]const u8 = if (prompts.len > 0)
            self.lookupPromptId(prompts[prompt_idx].path)
        else
            null;

        var pick_idx: ?usize = null;
        if (target_prompt_id) |tid| {
            for (resp.operations, 0..) |op, i| {
                if (op.prompt_id) |pid| {
                    if (std.mem.eql(u8, pid, tid)) {
                        pick_idx = i;
                        break;
                    }
                }
            }
        }
        if (pick_idx == null and resp.operations.len > 0) pick_idx = 0;

        var diff_lines: ?[]const []const u8 = null;
        var op_type: ?[]const u8 = null;
        var op_current_path: ?[]const u8 = null;
        var op_new_path: ?[]const u8 = null;
        var op_index: u16 = 0;
        const op_total: u16 = @intCast(@min(resp.operations.len, std.math.maxInt(u16)));

        if (pick_idx) |i| {
            const op = resp.operations[i];
            const base = op.base_content orelse "";
            const proposed = op.content orelse "";
            diff_lines = api.fetch.computeDiffLines(alloc, base, proposed);
            op_type = alloc.dupe(u8, op.type) catch null;
            if (op.current_path) |cp| op_current_path = alloc.dupe(u8, cp) catch null;
            if (op.path) |np| op_new_path = alloc.dupe(u8, np) catch null;
            op_index = @intCast(@min(i, std.math.maxInt(u16)));
        }
        const trace_refers: u16 = @intCast(@min(resp.trace_summary.refer_count, std.math.maxInt(u16)));
        const stored_pr_id = alloc.dupe(u8, pr_id) catch null;

        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        self.api_state.pr_detail_id = stored_pr_id;
        self.api_state.pr_detail_diff = diff_lines;
        self.api_state.pr_detail_trace_refers = trace_refers;
        self.api_state.pr_detail_op_type = op_type;
        self.api_state.pr_detail_op_current_path = op_current_path;
        self.api_state.pr_detail_op_new_path = op_new_path;
        self.api_state.pr_detail_op_index = op_index;
        self.api_state.pr_detail_op_total = op_total;
    }

    /// Pump the three write-path pending slots. Each surfaces the
    /// outcome on status_line so the user sees the deferred result of
    /// their action; body payloads are void so the Result carries only
    /// ok / api_error / network_error / invalid_response.
    fn consumeSignOutResult(self: *Dashboard) void {
        const result = self.api_state.sign_out_pending.consume() orelse return;
        self.status_line = switch (result) {
            .ok => "Token revoked. Please re-login.",
            .api_error => |e| writeErrorStatus(self, "Token revoke failed", e),
            .network_error => "Token revoke failed: network error.",
            .invalid_response => "Token revoke failed: malformed response.",
        };
    }

    fn consumeSubmitCommentResult(self: *Dashboard) void {
        const result = self.api_state.submit_comment_pending.consume() orelse return;
        self.status_line = switch (result) {
            .ok => "Comment submitted.",
            .api_error => |e| writeErrorStatus(self, "Comment submission failed", e),
            .network_error => "Comment submission failed: network error.",
            .invalid_response => "Comment submission failed: malformed response.",
        };
    }

    fn consumePrActionResult(self: *Dashboard) void {
        const result = self.api_state.pr_action_pending.consume() orelse return;
        self.status_line = switch (result) {
            .ok => "PR action applied.",
            .api_error => |e| writeErrorStatus(self, "PR action failed", e),
            .network_error => "PR action failed: network error.",
            .invalid_response => "PR action failed: malformed response.",
        };
    }

    /// Format `context: <server message> (CODE)` into the Dashboard's
    /// owned status_line buffer-via-arena. Returns a slice valid until
    /// the next status_line update.
    fn writeErrorStatus(self: *Dashboard, context: []const u8, err: api.request.ApiErrorPayload) []const u8 {
        const alloc = self.api_state.allocator();
        return std.fmt.allocPrint(alloc, "{s}: {s} ({s})", .{ context, err.message, err.code }) catch context;
    }

    /// Pump the workspace context file content pending slot. The
    /// payload carries the (ws_id, path) key the request was issued
    /// for, so the cache entry is routed against the request rather
    /// than against whatever the user now has selected. On error,
    /// mark the currently selected (ws_id, path) as failed to stop the
    /// widget loop from re-dispatching on every tick.
    fn consumeWsContextContentResult(self: *Dashboard) void {
        const result = self.api_state.ws_context_content_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.ws_context_content_cache.store(
                    .{ .ws_id = payload.ws_id, .path = payload.path },
                    payload.body,
                );
            },
            else => {
                const ws_id = self.activeWsId() orelse return;
                const ws_d = api.state.wsDetail(self.api_state, ws_id) orelse return;
                const context_sel = self.resolveWsContextSelection(&ws_d) orelse return;
                const file = ws_d.context_files[context_sel];
                self.api_state.ws_context_content_cache.markFailed(
                    .{ .ws_id = ws_d.ws_id, .path = file.path },
                );
            },
        }
    }

    fn submitComment(self: *Dashboard) void {
        const all_p = self.getPrompts();
        const si = @min(self.selected_prompt, if (all_p.len > 0) all_p.len - 1 else 0);
        if (all_p.len == 0) return;
        const prs_for = self.getPrsForPrompt(all_p[si].path);
        const pri = @min(self.selected_pr_idx, if (prs_for.len > 0) prs_for.len - 1 else 0);
        if (prs_for.len == 0) return;

        const comment_text = self.comment_input_buf[0..self.comment_input_len];
        api.specs.dispatchFromState(
            api.specs.SubmitCommentParams,
            void,
            api.specs.submit_comment,
            &self.api_state.submit_comment_pending,
            self.api_state,
            .{ .pr_id = prs_for[pri].id, .body = comment_text },
        );
        self.status_line = "Submitting comment...";
    }

    pub fn doPrAction(self: *Dashboard, action: []const u8) void {
        const all_p = self.getPrompts();
        const si = @min(self.selected_prompt, if (all_p.len > 0) all_p.len - 1 else 0);
        if (all_p.len == 0) return;
        const prs_for = self.getPrsForPrompt(all_p[si].path);
        const pri = @min(self.selected_pr_idx, if (prs_for.len > 0) prs_for.len - 1 else 0);
        if (prs_for.len == 0) return;

        api.specs.dispatchFromState(
            api.specs.PrActionParams,
            void,
            api.specs.pr_action,
            &self.api_state.pr_action_pending,
            self.api_state,
            .{ .pr_id = prs_for[pri].id, .action = action },
        );
        self.status_line = if (std.mem.eql(u8, action, "accept")) "Accepting PR..." else "Rejecting PR...";
    }

    fn orgMemberCount(self: *Dashboard) usize {
        return settings_panel.orgMemberCount(self);
    }

    fn accountWorkspaceCount(self: *Dashboard) usize {
        return settings_panel.accountWorkspaceCount(self);
    }

    pub fn wsCount(self: *Dashboard) usize {
        return self.getWorkspaces().len;
    }

    fn getWorkspaces(self: *Dashboard) []const data.WorkspaceEntry {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.current_user) |u| {
            const alloc = self.api_state.allocator();
            var list: std.ArrayList(data.WorkspaceEntry) = .empty;
            for (u.workspaces) |ws| {
                const al: data.AccessLevel = if (std.mem.eql(u8, ws.role, "admin")) .admin else .member;
                list.append(alloc, .{
                    .name = ws.name,
                    .prompts = 0,
                    .contexts = 0,
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

    const AnalysisCounts = struct { prompt_count: usize, member_count: usize, input_count: usize };

    const AnalysisScopeInfo = struct {
        label: []const u8,
        ws_id: ?[]const u8,
    };

    const ScopedTraceData = struct {
        label: []const u8,
        signal_ratio: u8,
        constraint_count: u32,
        refers: []const trace_reader.ReferEvent,
        inputs: []const trace_reader.InputEvent,
    };

    const ChartSeries = struct {
        values: []const f32,
        left_label: []const u8,
        right_label: []const u8,
    };

    fn smoothLocalChartBuckets(arena: std.mem.Allocator, source: []const u16) []const f32 {
        if (source.len == 0) return &.{};

        const values = arena.alloc(f32, source.len) catch return &.{};
        const kernel = [_]f32{ 1, 2, 3, 2, 1 };

        // Smooth the second-level refer buckets just for display. This keeps
        // the underlying counts exact while turning isolated spikes into a
        // more legible local activity wave.
        for (source, 0..) |_, center| {
            var weighted_sum: f32 = 0;
            var weight_total: f32 = 0;

            for (kernel, 0..) |weight, kernel_idx| {
                const offset: isize = @as(isize, @intCast(kernel_idx)) - 2;
                const sample_idx_signed: isize = @as(isize, @intCast(center)) + offset;
                if (sample_idx_signed < 0 or sample_idx_signed >= @as(isize, @intCast(source.len))) continue;

                const sample_idx: usize = @intCast(sample_idx_signed);
                weighted_sum += @as(f32, @floatFromInt(source[sample_idx])) * weight;
                weight_total += weight;
            }

            values[center] = if (weight_total > 0)
                weighted_sum / weight_total
            else
                @as(f32, @floatFromInt(source[center]));
        }

        return values;
    }

    test "smoothLocalChartBuckets softens an isolated spike" {
        const source = [_]u16{ 0, 0, 0, 6, 0, 0, 0 };
        const values = smoothLocalChartBuckets(std.testing.allocator, &source);
        defer std.testing.allocator.free(values);

        try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), values[1], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 4.0 / 3.0), values[2], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 2.0), values[3], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 4.0 / 3.0), values[4], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), values[5], 0.001);
    }

    fn currentAnalysisScopeLocked(self: *const Dashboard) AnalysisScopeInfo {
        const workspaces = if (self.api_state.current_user) |u| u.workspaces else &.{};
        if (workspaces.len == 0 or self.analysis_scope_idx == 0) {
            return .{ .label = "All Workspaces", .ws_id = null };
        }

        const scope_idx = @min(self.analysis_scope_idx, workspaces.len);
        const ws = workspaces[scope_idx - 1];
        return .{ .label = ws.name, .ws_id = ws.ws_id };
    }

    fn currentAnalysisScope(self: *const Dashboard) AnalysisScopeInfo {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        return self.currentAnalysisScopeLocked();
    }

    pub fn cycleAnalysisScope(self: *Dashboard) AnalysisScopeInfo {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const workspaces = if (self.api_state.current_user) |u| u.workspaces else &.{};
        const scope_count = workspaces.len + 1;
        self.analysis_scope_idx = (self.analysis_scope_idx + 1) % scope_count;
        return self.currentAnalysisScopeLocked();
    }

    fn serverSignalRatio(self: *const Dashboard) ?u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const stats = self.api_state.org_stats orelse return null;
        return @intCast(@min(@as(u64, @intFromFloat(stats.signal_ratio * 100)), 100));
    }

    fn scopedTraceData(self: *const Dashboard) ?ScopedTraceData {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();

        const local = self.api_state.local_stats orelse return null;
        const scope = self.currentAnalysisScopeLocked();
        if (scope.ws_id) |ws_id| {
            if (local.workspace(ws_id)) |ws| {
                return .{
                    .label = scope.label,
                    .signal_ratio = ws.signal_ratio,
                    .constraint_count = ws.constraint_count,
                    .refers = ws.refers,
                    .inputs = ws.inputs,
                };
            }
            return .{
                .label = scope.label,
                .signal_ratio = 0,
                .constraint_count = 0,
                .refers = &.{},
                .inputs = &.{},
            };
        }
        return .{
            .label = scope.label,
            .signal_ratio = local.signal_ratio,
            .constraint_count = local.constraint_count,
            .refers = local.refers,
            .inputs = local.inputs,
        };
    }

    fn buildLocalChartSeries(self: *const Dashboard, arena: std.mem.Allocator, refers: []const trace_reader.ReferEvent) ChartSeries {
        _ = self;
        const bucket_ms: i64 = std.time.ms_per_s;
        const bucket_count: usize = 60;
        const span_ms: i64 = bucket_ms * bucket_count;

        var raw_values: [bucket_count]u16 = .{0} ** bucket_count;

        const now_ms = std.time.milliTimestamp();
        const current_bucket_start_ms = now_ms - @mod(now_ms, bucket_ms);
        const end_ms = current_bucket_start_ms + bucket_ms;
        const start_ms = end_ms - span_ms;
        for (refers) |rv| {
            if (rv.timestamp < start_ms or rv.timestamp >= end_ms) continue;
            const idx: usize = @intCast(@divFloor(rv.timestamp - start_ms, bucket_ms));
            if (idx >= bucket_count) continue;
            raw_values[idx] +|= 1;
        }

        return .{
            .values = smoothLocalChartBuckets(arena, raw_values[0..]),
            .left_label = "60s ago",
            .right_label = "now",
        };
    }

    fn getAnalysisCounts(self: *Dashboard) AnalysisCounts {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();

        const scope = self.currentAnalysisScopeLocked();
        const input_count: usize = if (self.api_state.local_stats) |local| blk: {
            const inputs = if (scope.ws_id) |ws_id|
                (if (local.workspace(ws_id)) |ws| ws.inputs else &.{})
            else
                local.inputs;
            break :blk latestInputs(inputs, self.dashboard_input_capacity).len;
        } else 0;

        const prompt_count: usize = if (self.api_state.org_stats) |stats|
            stats.prompts.len
        else
            0;

        return .{
            .prompt_count = prompt_count,
            .member_count = if (self.api_state.org_stats) |stats| stats.users.len else 0,
            .input_count = input_count,
        };
    }

    fn shiftSettingsTab(self: *Dashboard, delta: i8) void {
        settings_panel.shiftSettingsTab(self, delta);
    }

    // Modal overlay showing the full text of the currently-selected user
    // prompt from the Recent Inputs panel. Wraps at the box width and
    // truncates if the prompt is longer than the box can display.
    fn drawInputDetailOverlay(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const content_and_ts: struct { content: []const u8, ts: i64 } = blk: {
            const scoped = self.scopedTraceData() orelse break :blk .{ .content = "", .ts = 0 };
            const visible = latestInputs(scoped.inputs, self.dashboard_input_capacity);
            if (visible.len == 0) break :blk .{ .content = "", .ts = 0 };
            const idx = @min(self.analysis_input_cursor, visible.len - 1);
            break :blk .{ .content = visible[idx].content, .ts = visible[idx].timestamp };
        };
        return dashboard_panel.drawInputDetailOverlay(self, ctx, content_and_ts.content, content_and_ts.ts);
    }

    fn drawHelpOverlay(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const modal = Modal{ .title = "Keyboard Reference", .box_width = 52, .box_height = 19 };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        const row = result.content_row;

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
            "r              Refresh / sync",
            "w              Dashboard scope",
            "?              Toggle this help",
            "q / Ctrl+C     Quit",
        };
        for (lines, 0..) |line, i| {
            w.writeText(&surface, ctx, col, @intCast(row + i), line, theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT));
        }

        return surface;
    }

    fn drawConfirmOverlay(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const modal = Modal{
            .title = "Confirm",
            .box_width = 44,
            .box_height = 7,
            .border_color = theme.DANGER,
            .footer = "y confirm    n / Esc cancel",
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        const row = result.content_row;

        const action_label: []const u8 = switch (self.confirm_action) {
            .remove_member => "Remove member:",
            .delete_bundle => "Delete bundle:",
            .delete_workspace => "Delete workspace:",
            .revoke_token => "Revoke token?",
            .quit => "Quit clumsies?",
            .none => "Confirm:",
        };
        w.writeText(&surface, ctx, col, row, action_label, theme.textOn(theme.PANEL_ALT, theme.TEXT));
        w.writeText(&surface, ctx, col, row + 1, self.confirm_message, theme.boldOn(theme.PANEL_ALT, theme.ACCENT));

        return surface;
    }

    fn drawCommentEditorOverlay(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();

        // Title: show reply context or "New Comment"
        const all_prompts = self.getPrompts();
        const sel_idx = @min(self.selected_prompt, if (all_prompts.len > 0) all_prompts.len - 1 else 0);
        const title = if (all_prompts.len > 0) blk: {
            const p = &all_prompts[sel_idx];
            const prs = self.getPrsForPrompt(p.path);
            break :blk if (prs.len > 0 and self.selected_pr_idx < prs.len)
                try std.fmt.allocPrint(ctx.arena, "Comment on {s}", .{prs[self.selected_pr_idx].id})
            else
                @as([]const u8, "New Comment");
        } else @as([]const u8, "New Comment");

        const box_w = @min(size.width -| 4, 60);
        const box_h: u16 = 8;
        const modal = Modal{
            .title = title,
            .box_width = box_w,
            .box_height = box_h,
            .anchor = .bottom_right,
            .footer = "Enter send  Esc cancel",
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;

        // Input text with cursor
        const input_text = self.comment_input_buf[0..self.comment_input_len];
        const max_visible: usize = @as(usize, box_w -| 4);
        const visible_start = if (input_text.len > max_visible) input_text.len - max_visible else 0;
        const visible = input_text[visible_start..];
        const display = try std.fmt.allocPrint(ctx.arena, "{s}_", .{visible});
        w.writeText(&surface, ctx, result.content_col, result.content_row, display, theme.textOn(theme.PANEL_ALT, theme.TEXT));

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

    fn contextHint(self: *const Dashboard) []const u8 {
        if (self.show_help) return "Keyboard reference overlay.";
        return switch (self.selected_module) {
            .dashboard => "Live signal and recent input feed.",
            .library => "Bundle facet, prompt list, and passive preview.",
            .workspace => "Workspace list and sync status detail.",
            .analysis => "Prompt and member aggregates.",
        };
    }

    fn selectTab(self: *Dashboard, ctx: *vxfw.EventContext, tab: TopModule) void {
        self.selected_module = tab;
        self.analysis_show_input_detail = false;
        self.analysis_show_member_detail = false;
        self.analysis_expanded_prompt = null;
        switch (tab) {
            .dashboard => {
                if (self.analysis_focus != .chart and self.analysis_focus != .inputs) {
                    self.analysis_focus = .chart;
                }
            },
            .analysis => {
                if (self.analysis_focus != .prompts and self.analysis_focus != .members) {
                    self.analysis_focus = .prompts;
                }
            },
            else => {},
        }
        self.status_line = tab.label();
        ctx.consumeAndRedraw();
    }

    pub fn shiftDetailTab(self: *Dashboard, delta: i8) void {
        const current: i8 = @intCast(@intFromEnum(self.detail_tab));
        const count: i8 = @intCast(detail_tabs.len);
        const next = @mod(current + delta + count, count);
        self.detail_tab = @enumFromInt(@as(u8, @intCast(next)));
        self.show_comment_editor = false;
        self.pr_filter = .open;
        self.selected_pr_idx = 0;
        self.pr_scroll_bars.scroll_view.cursor = 0;
    }

    pub fn shiftWsTab(self: *Dashboard, delta: i8) void {
        const current: i8 = @intCast(@intFromEnum(self.ws_tab));
        const count: i8 = @intCast(ws_tabs.len);
        const next = @mod(current + delta + count, count);
        self.ws_tab = @enumFromInt(@as(u8, @intCast(next)));
    }
};
