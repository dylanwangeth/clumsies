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
const rule_detail_panel = @import("app/rule_detail.zig");
const settings_panel = @import("app/settings.zig");
const workspace_panel = @import("app/workspace.zig");
const drafts_mod = @import("../drafts.zig");
const workspace_config = @import("../workspace_config.zig");
const editor_host = @import("editor_host.zig");
const surface_size = @import("surface_size.zig");
const util_hash = @import("clumsies_lib").util.hash;

const tree = @import("tree.zig");
const attestation_reader = @import("attestation_reader.zig");
const Modal = w.Modal;
const TextInput = w.TextInput;
const TableRow = @import("table_row.zig").TableRow;
const Column = @import("table_row.zig").Column;

const WsTab = enum(u8) {
    context,
    rules,

    fn label(self: WsTab) []const u8 {
        return switch (self) {
            .context => "Context",
            .rules => "Rules",
        };
    }
};

const ws_tabs = [_]WsTab{ .context, .rules };

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
    discard_draft,
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
const MAX_DASHBOARD_ROUND_ROWS = 2048;
const MAX_DASHBOARD_CHAIN_ROWS = 1024;
const DASHBOARD_ROUND_ROW_COUNT = 5;
const detail_tabs = [_]DetailTab{ .content, .pull_requests };
const PathTreeState = tree.State(MAX_TREE_ROWS, 96);

/// Identifies the draft the user's editing action should affect.
/// Derived from the currently-focused module and list selection; all
/// draft handlers (`edit`, `toggleReady`, `discard`, `openComposer`)
/// accept a DraftTarget so the same implementation serves both the
/// Library side and the Workspace side.
pub const DraftTarget = struct {
    ws_id: []const u8,
    category: drafts_mod.DraftCategory,
    path: []const u8,
    rule_id: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
};

pub const Dashboard = struct {
    api_state: *api.state.ApiState,
    selected_module: TopModule = .dashboard,
    selected_rule: usize = 0,
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

    content_view: w.ContentView,

    // PR list within Rule Detail
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
    ws_list_scroll_bars: vxfw.ScrollBars,
    ws_context_tree: PathTreeState = .{},
    ws_rules_tree: PathTreeState = .{},
    ws_list_widgets: [MAX_TREE_ROWS]vxfw.Widget = undefined,
    ws_list_rows: [MAX_TREE_ROWS]vxfw.Text = undefined,
    last_safe_layout_size: vxfw.Size = .{},

    // Dashboard / Analysis shared state
    analysis_scope_idx: usize = 0,
    breathing_phase: u8 = 0, // 0-20 for breathing animation cycle
    analysis_focus: enum { chart, rules, members, inputs } = .inputs,
    analysis_rule_cursor: usize = 0,
    analysis_member_cursor: usize = 0,
    analysis_input_cursor: usize = 0,
    analysis_expanded_rule: ?usize = null,
    analysis_show_member_detail: bool = false,
    analysis_show_input_detail: bool = false,
    dashboard_input_capacity: usize = 1,
    dashboard_round_scroll_bars: vxfw.ScrollBars,
    dashboard_round_widgets: [MAX_DASHBOARD_ROUND_ROWS]vxfw.Widget = undefined,
    dashboard_round_rows: [MAX_DASHBOARD_ROUND_ROWS]vxfw.Text = undefined,
    dashboard_chain_scroll_bars: vxfw.ScrollBars,
    dashboard_chain_widgets: [MAX_DASHBOARD_CHAIN_ROWS]vxfw.Widget = undefined,
    dashboard_chain_rows: [MAX_DASHBOARD_CHAIN_ROWS]vxfw.Text = undefined,
    dashboard_chain_cursor: usize = 0,
    dashboard_chain_expanded: ?usize = null,
    view_arena: std.heap.ArenaAllocator,

    // Editor shell-out plumbing. `app` and `env_map` stay borrowed from
    // main.zig for the lifetime of the Dashboard. Active workspace is
    // resolved dynamically from `ws_sel` against the hub-provided
    // workspace list (see `activeWsId()`), not from a cwd binding.
    app: *vxfw.App,
    env_map: *const std.process.EnvMap,

    // Drafts cache. Refreshed on startup and after every edit op so
    // list rows and the footer counter stay in sync with disk. Prompt
    // and context drafts live in separate maps because their path
    // namespaces are distinct (library rules are org-wide, context
    // files are workspace-local).
    drafts_arena: std.heap.ArenaAllocator,
    drafts_by_rule_path: std.StringHashMapUnmanaged(drafts_mod.DraftStatus) = .{},
    drafts_by_context_path: std.StringHashMapUnmanaged(drafts_mod.DraftStatus) = .{},
    drafts_by_meta_prompt_path: std.StringHashMapUnmanaged(drafts_mod.DraftStatus) = .{},
    /// Paths of local `operation=create` drafts per category. These do
    /// not exist on the hub yet, so the server-side rules /
    /// context_files lists never carry them — the list renderers
    /// append these as virtual rows so the user can see (and edit)
    /// newly-created drafts before they are submitted.
    drafts_create_rule_paths: []const []const u8 = &.{},
    drafts_create_context_paths: []const []const u8 = &.{},
    drafts_total: usize = 0,
    drafts_ready: usize = 0,
    /// Tracks whether refreshDraftsCache has ever run against a
    /// resolved workspace. The cache is seeded once current_user
    /// appears on the tick loop so `*` markers and the footer
    /// counter populate without a user-triggered draft op.
    drafts_cache_seeded: bool = false,
    pending_discard_target: ?DraftTarget = null,
    /// Dup'd path owned by this struct for the pending discard so
    /// confirm-overlay render and commit do not depend on
    /// drafts_arena, which refreshDraftsCache resets.
    pending_discard_path_owned: ?[]const u8 = null,

    // PR Composer overlay state. MVP submits a single-draft PR; multi-
    // draft selection and DiffViewer preview are follow-ups. The target
    // captures category + path + ids at open time so the submit path
    // doesn't need to re-derive them against a selection that may have
    // moved.
    show_pr_composer: bool = false,
    pr_composer_desc_buf: [256]u8 = .{0} ** 256,
    pr_composer_desc_len: usize = 0,
    pr_composer_target: ?DraftTarget = null,
    /// Operation type of the currently-open composer draft, captured
    /// from the draft index at open time. Used by the overlay to
    /// render an accurate `op:` line instead of hard-coding "modify".
    pr_composer_operation: drafts_mod.DraftOperation = .modify,
    /// Dup'd path owned by the composer so overlay render and submit
    /// do not point into drafts_arena. Freed when the composer
    /// closes (cancel, submit success, or re-open).
    pr_composer_path_owned: ?[]const u8 = null,
    pr_composer_submitting: bool = false,

    // New-draft form. Opened from Library Files tab or Workspace
    // Context tab via `n`. Category is set by the caller to route the
    // draft into the right scope.
    show_new_draft_form: bool = false,
    new_draft_path_buf: [128]u8 = .{0} ** 128,
    new_draft_path_len: usize = 0,
    new_draft_category: drafts_mod.DraftCategory = .rule,

    pub fn init(
        api_state: *api.state.ApiState,
        app: *vxfw.App,
        env_map: *const std.process.EnvMap,
    ) Dashboard {
        return .{
            .api_state = api_state,
            .library_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .content_view = w.ContentView.init(),
            .pr_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .pr_diff_scroll_bars = w.initPlainScrollBars(theme.PANEL, 2),
            .ws_list_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .dashboard_round_scroll_bars = w.initCursorScrollBars(theme.PANEL),
            .dashboard_chain_scroll_bars = w.initPlainScrollBars(theme.PANEL, 3),
            .view_arena = std.heap.ArenaAllocator.init(api_state.backing_allocator),
            .app = app,
            .env_map = env_map,
            .drafts_arena = std.heap.ArenaAllocator.init(api_state.backing_allocator),
        };
    }

    pub fn deinit(self: *Dashboard) void {
        self.releaseComposerTarget();
        self.releasePendingDiscardTarget();
        self.view_arena.deinit();
        self.drafts_arena.deinit();
        const alloc = self.api_state.allocator();
        self.library_tree.deinit(alloc);
        self.ws_context_tree.deinit(alloc);
        self.ws_rules_tree.deinit(alloc);
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
            .rules => &self.ws_rules_tree,
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
                            .discard_draft => self.commitDiscardDraft(),
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
                        // Releasing here keeps the pending-discard
                        // path owned slice from leaking when the
                        // user declines the confirm overlay.
                        self.releasePendingDiscardTarget();
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

                // PR Composer overlay absorbs all keys while open.
                if (self.show_pr_composer) {
                    self.handlePrComposerKey(ctx, key);
                    return;
                }

                // New-draft form absorbs all keys while open.
                if (self.show_new_draft_form) {
                    self.handleNewDraftFormKey(ctx, key);
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
                        try analysis_panel.handleModuleEvent(self, ctx, key, counts.rule_count, counts.member_count);
                    },
                }
                return;
            },
            .init => {
                self.refreshDraftsCache();
                // Start breathing animation
                try ctx.tick(100, self.widget());
            },
            .tick => {
                // Advance breathing cycle: 0→20→0 (2 seconds at 100ms intervals)
                self.breathing_phase = (self.breathing_phase + 1) % 21;
                if ((self.selected_module == .dashboard or self.selected_module == .analysis) and (self.breathing_phase == 0 or self.breathing_phase == 10)) {
                    api.state.refreshLocalState(self.api_state);
                }
                // First tick after current_user lands (the /me fetch
                // completes asynchronously, so activeWsId() was null
                // at .init). Seed the drafts map now so row markers
                // and the footer counter come up populated.
                if (!self.drafts_cache_seeded and self.activeWsId() != null) {
                    self.refreshDraftsCache();
                }
                _ = self.consumeCreateWsResult();
                self.consumeRuleContentResult();
                self.consumeRulePrsResult();
                self.consumeWsContextContentResult();
                self.consumeWsContextFilesResult();
                self.consumeWsManifestResult();
                self.consumePrDetailResult();
                self.consumePrCommentsResult();
                self.consumeSignOutResult();
                self.consumeSubmitCommentResult();
                self.consumePrActionResult();
                self.consumeCreateRulePrResult();
                self.consumeCreateContextPrResult();
                ctx.redraw = true;
                try ctx.tick(100, self.widget());
            },
            else => {},
        }
    }

    fn draw(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        _ = self.view_arena.reset(.retain_capacity);
        const size = self.sanitizeLayoutSize(ctx.max.size());
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
            self.show_create_workspace or self.show_pr_composer or
            self.show_new_draft_form or show_input_overlay) child_count = 4;

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
        if (self.show_pr_composer) {
            const full_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[3] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try self.drawPrComposerOverlay(full_ctx),
            };
        }
        if (self.show_new_draft_form) {
            const full_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[3] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try self.drawNewDraftFormOverlay(full_ctx),
            };
        }

        root.children = children;
        return root;
    }

    fn sanitizeLayoutSize(self: *Dashboard, raw_size: vxfw.Size) vxfw.Size {
        const size = surface_size.sanitize(raw_size);
        if (raw_size.width == 0 or raw_size.height == 0) {
            if (self.last_safe_layout_size.width > 0 and self.last_safe_layout_size.height > 0) {
                return self.last_safe_layout_size;
            }
            return .{ .width = 96, .height = 24 };
        }

        self.last_safe_layout_size = size;
        return size;
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
                .chart => "j/k event  Enter [+]  Tab rounds  w scope  Shift-F flush  ? help  q quit",
                .inputs => "j/k move  Enter detail  Tab focus  w scope  Shift-F flush  ? help  q quit",
                else => "Tab focus  w scope  Shift-F flush  ? help  q quit",
            },
            .library => if (self.detail_focus_content and self.detail_tab == .pull_requests)
                "j/k scroll  a accept  x reject  c comment  Esc list  ? help"
            else if (self.detail_focus_content)
                "y copy id  e edit  D discard  m ready  j/k scroll  Esc list"
            else if (self.detail_tab == .pull_requests)
                "j/k move  f filter  [/] tab  Tab detail  r refresh  ? help  q quit"
            else
                "j/k move  y copy id  n new  [/] tab  Enter detail  r refresh  b bundle  ? help  q quit",
            .workspace => switch (self.ws_focus) {
                .bar => if (self.ws_tab == .context)
                    "j/k select ws  [/] tab  n new file  c create ws  Tab list  r refresh  ? help  q quit"
                else
                    "j/k select ws  [/] tab  c create ws  Tab list  r refresh  ? help  q quit",
                .list => if (self.ws_tab == .context)
                    "[/] tab  j/k move  h/l tree  y copy id  Enter open  n new file  c create ws  Esc bar  ? help"
                else
                    "[/] tab  j/k move  h/l tree  y copy id  Enter open  c create ws  Esc bar  ? help",
                .content => "y copy id  j/k scroll  d toggle diff  e edit  D discard  m ready  p submit  Esc list  ? help",
            },
            .analysis => switch (self.analysis_focus) {
                .rules => "j/k move  Enter expand  Tab focus  ? help  q quit",
                .members => "j/k move  Enter detail  Tab focus  ? help  q quit",
                else => "Tab focus  ? help  q quit",
            },
        };
        w.writeText(&surface, ctx, 1, 0, keys, theme.fg(theme.MUTED));

        if (self.drafts_total > 0) {
            const counter = std.fmt.allocPrint(
                ctx.arena,
                "drafts: {d} ({d} ready)",
                .{ self.drafts_total, self.drafts_ready },
            ) catch "";
            if (counter.len > 0) {
                const keys_w: u16 = @intCast(ctx.stringWidth(keys));
                w.writeText(&surface, ctx, 2 + keys_w + 2, 0, counter, theme.fg(theme.ACCENT));
            }
        }

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
        const rules = self.getRules();
        const create_paths = self.drafts_create_rule_paths;

        const list_ctx = ctx.withConstraints(.{ .width = list_w, .height = size.height }, .{ .width = list_w, .height = size.height });
        const detail_w: u16 = size.width - list_w - 1;
        const detail_ctx = ctx.withConstraints(.{ .width = detail_w, .height = size.height }, .{ .width = detail_w, .height = size.height });
        const list_surface = try self.drawListPanel(list_ctx);

        // selected_rule >= rules.len means a virtual (create-op
        // draft) row. Clamping into `rules` would render the last
        // server rule's header over a draft's body, which is what
        // led to a mismatched title + stale rev/pr/c badge. Instead
        // build a minimal RuleEntry stub for the virtual row so
        // the header stays in sync with the content.
        var virtual_entry: data.RuleEntry = undefined;
        const selected_entry: ?*const data.RuleEntry = blk: {
            if (self.selected_rule < rules.len) break :blk &rules[self.selected_rule];
            const k = self.selected_rule - rules.len;
            if (k >= create_paths.len) break :blk null;
            virtual_entry = .{
                .path = create_paths[k],
                .kind = "",
                .refer_count = "",
                .constraint_count = 0,
                .bundle_count = 0,
                .bundle_names = "",
                .updated = "",
                .age = "",
                .summary = "",
                .trend = .{0} ** 8,
                .content_hash = "",
                .open_pr_count = 0,
                .workspace_count = 0,
                .workspace_names = "",
                .revision = 0,
            };
            break :blk &virtual_entry;
        };

        const detail_surface = if (selected_entry) |entry|
            try rule_detail_panel.drawEmbedded(self, detail_ctx, entry)
        else
            try rule_detail_panel.drawEmbeddedEmpty(self, detail_ctx);
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
        const rule_count: usize = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.rules) |p| break :blk p.len;
            break :blk 0;
        };
        return library_panel.drawListPanel(self, ctx, bundle_label, rule_count);
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
        const lib_rules: []const data.RuleEntry = if (self.ws_tab == .rules) self.getRules() else &.{};
        return workspace_panel.drawList(self, ctx, self.currentWsTree(), live_ws, lib_rules);
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
        self.ws_rules_tree.reset();
        self.ws_list_sel = 0;
    }

    fn currentWsDirSelection(self: *Dashboard) ?[]const u8 {
        return self.currentWsTree().dirPathAt(self.ws_list_sel);
    }

    fn resolveWsContextSelection(self: *Dashboard, ws_d: *const api.model.WsDetail) ?usize {
        const leaf = self.currentWsTree().leafIndexAt(self.ws_list_sel) orelse return null;
        // Virtual rows (local create-op drafts) sit at indices past
        // the server-side context_files range. The detail-pane and
        // cache-fetch call sites index into ws_d.context_files
        // directly, so returning the virtual index would crash; the
        // content panel's unified-renderer commit handles virtual
        // rows properly, here we just refuse them.
        if (leaf >= ws_d.context_files.len) return null;
        return leaf;
    }

    const ResolvedWsRule = struct {
        idx: usize,
        path: []const u8,
    };

    pub fn cachedWorkspaceContextBody(self: *Dashboard, ws_id: []const u8, path: []const u8) ?[]const u8 {
        return self.api_state.ws_context_content_cache.lookup(.{ .ws_id = ws_id, .path = path });
    }

    pub fn cachedRuleBody(self: *Dashboard, path: []const u8) ?[]const u8 {
        const resp = self.api_state.rule_content_cache.lookup(.{ .value = path }) orelse return null;
        return resp.body;
    }

    pub fn invalidateRemoteDetailRequests(self: *Dashboard) void {
        self.api_state.rule_content_cache.invalidate();
        self.api_state.rule_prs_cache.invalidate();
        self.api_state.ws_context_content_cache.invalidate();
    }

    pub fn requestSelectedRuleDetail(self: *Dashboard) void {
        const rules = self.getRules();
        if (self.selected_rule >= rules.len) return;

        const sel_path = rules[self.selected_rule].path;
        const key = api.cache.StringKey{ .value = sel_path };

        if (self.api_state.rule_content_cache.shouldDispatch(key)) {
            api.specs.dispatchFromState(
                api.specs.PathParams,
                @import("clumsies_lib").protocol.library_api.RuleContentResponse,
                api.specs.library_rule_content,
                &self.api_state.rule_content_pending,
                self.api_state,
                .{ .path = sel_path },
            );
        }

        if (self.api_state.rule_prs_cache.shouldDispatch(key)) {
            const rule_id = self.lookupRuleId(sel_path) orelse return;
            api.specs.dispatchFromState(
                api.specs.RulePrsParams,
                api.specs.RulePrsPayload,
                api.specs.library_rule_prs,
                &self.api_state.rule_prs_pending,
                self.api_state,
                .{ .rule_id = rule_id },
            );
        }
    }

    /// Look up the rule_id that corresponds to `path` in the cached
    /// library rule list. Returns null if the library has not loaded
    /// yet or the path is unknown.
    pub fn lookupRuleId(self: *Dashboard, path: []const u8) ?[]const u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const lib = self.api_state.rules orelse return null;
        for (lib) |lp| {
            if (std.mem.eql(u8, lp.path, path)) return lp.rule_id;
        }
        return null;
    }

    pub fn lookupRuleViewByPath(self: *Dashboard, path: []const u8) ?*const data.RuleEntry {
        const rules = self.getRules();
        for (rules) |*rule| {
            if (std.mem.eql(u8, rule.path, path)) return rule;
        }
        return null;
    }

    /// Inverse of `lookupRuleId`: given a rule_id, return the path
    /// that the rule_prs cache is keyed by. Used by the rule-prs
    /// consumer so it can route a completed response against its
    /// request id rather than against the UI's current selection.
    fn lookupRulePath(self: *Dashboard, rule_id: []const u8) ?[]const u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const lib = self.api_state.rules orelse return null;
        for (lib) |lp| {
            if (std.mem.eql(u8, lp.rule_id, rule_id)) return lp.path;
        }
        return null;
    }

    /// Path of the currently selected library rule, or null when no
    /// rule is in focus. Used by failure-caching in the on-demand
    /// consumers, which do not have a request-scoped key to attribute
    /// the failure to and fall back to the current UI selection.
    fn selectedRulePath(self: *Dashboard) ?[]const u8 {
        const rules = self.getRules();
        if (rules.len == 0) return null;
        const idx = @min(self.selected_rule, rules.len - 1);
        return rules[idx].path;
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
            .rules => {
                if (dir_sel != null) return;
                const rule_sel = self.resolveWsRuleSelection(ws_d) orelse return;
                const key = api.cache.StringKey{ .value = rule_sel.path };
                if (!self.api_state.rule_content_cache.shouldDispatch(key)) return;

                api.specs.dispatchFromState(
                    api.specs.PathParams,
                    @import("clumsies_lib").protocol.library_api.RuleContentResponse,
                    api.specs.library_rule_content,
                    &self.api_state.rule_content_pending,
                    self.api_state,
                    .{ .path = rule_sel.path },
                );
            },
        }
    }

    fn resolveWsRuleSelection(self: *Dashboard, ws_d: *const api.model.WsDetail) ?ResolvedWsRule {
        const idx = self.currentWsTree().leafIndexAt(self.ws_list_sel) orelse return null;
        if (idx >= ws_d.ws_rules.len) return null;
        const lib_rules = self.getRules();
        const wp = ws_d.ws_rules[idx];
        const path = if (wp.path.len > 0)
            wp.path
        else for (lib_rules) |lp| {
            if (std.mem.eql(u8, lp.content_hash, wp.content_hash)) break lp.path;
        } else wp.rule_id;
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
        const rule_sel = if (live_ws) |ws_d|
            self.resolveWsRuleSelection(&ws_d)
        else
            null;
        // context_sel_path is the unified identity for the context
        // selection: server-side files contribute their path via
        // context_sel, virtual rows contribute theirs via the local
        // drafts_create_context_paths side-table.
        const context_sel_path: ?[]const u8 = if (live_ws) |ws_d| blk: {
            if (dir_sel != null) break :blk null;
            if (context_sel) |idx| break :blk ws_d.context_files[idx].path;
            const leaf = self.currentWsTree().leafIndexAt(self.ws_list_sel) orelse break :blk null;
            if (leaf < ws_d.context_files.len) break :blk ws_d.context_files[leaf].path;
            const k = leaf - ws_d.context_files.len;
            if (k >= self.drafts_create_context_paths.len) break :blk null;
            break :blk self.drafts_create_context_paths[k];
        } else null;
        return workspace_panel.drawDetail(self, ctx, .{
            .live_ws = live_ws,
            .dir_sel = dir_sel,
            .context_sel = context_sel,
            .context_sel_id = if (live_ws) |ws_d|
                if (context_sel) |idx| ws_d.context_files[idx].context_id else null
            else
                null,
            .context_sel_path = context_sel_path,
            .rule_sel_idx = if (rule_sel) |sel| sel.idx else null,
            .rule_sel_id = if (live_ws) |ws_d|
                if (rule_sel) |sel| ws_d.ws_rules[sel.idx].rule_id else null
            else
                null,
            .rule_sel_path = if (rule_sel) |sel| sel.path else null,
        });
    }

    fn loadAnalysisData(self: *Dashboard, arena: std.mem.Allocator) ?data.AnalysisData {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.org_stats) |stats| {
            return api.view_model.analysisFromStats(arena, stats, self.api_state.rules, null);
        }
        return null;
    }

    // Dashboard: live interaction rounds and attestation closure state.
    fn drawDashboard(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const scope = self.currentAnalysisScope();
        const scoped_attestation = self.scopedAttestationData();
        const rounds: []const attestation_reader.RoundEvent = if (scoped_attestation) |st| st.rounds else &.{};

        const arena_h: u16 = 4;
        const body_h: u16 = size.height -| arena_h;
        const preferred_rounds_w: u16 = @intCast(@divTrunc(@as(u32, size.width) * 38, 100));
        const rounds_w: u16 = @min(size.width, @max(@as(u16, 64), @min(@as(u16, 96), preferred_rounds_w)));
        const trace_w: u16 = size.width -| rounds_w;
        const usable_round_rows: u16 = body_h -| 2;
        self.dashboard_input_capacity = @max(@as(usize, 1), @as(usize, @intCast(usable_round_rows / 2)));
        if (self.analysis_input_cursor >= rounds.len and rounds.len > 0) {
            self.analysis_input_cursor = rounds.len - 1;
        }
        const max_round_cursor = std.math.maxInt(u32) / DASHBOARD_ROUND_ROW_COUNT;
        self.dashboard_round_scroll_bars.scroll_view.cursor = @intCast(@min(self.analysis_input_cursor, max_round_cursor) * DASHBOARD_ROUND_ROW_COUNT);
        self.dashboard_round_scroll_bars.scroll_view.ensureScroll();
        const selected_round = if (rounds.len > 0)
            rounds[@min(self.analysis_input_cursor, rounds.len - 1)]
        else
            null;
        const active_count = self.activeSessionCount(scope.ws_id);
        const summary = dashboardSummary(rounds, active_count);
        const arena_surface = try dashboard_panel.drawArena(
            self,
            ctx,
            size.width,
            arena_h,
            scope.label,
            summary,
        );
        const rounds_surface = try dashboard_panel.drawRounds(
            self,
            ctx,
            rounds_w,
            body_h,
            rounds,
            scope.label,
        );
        const trace_surface = try dashboard_panel.drawProtocolTrace(self, ctx, trace_w, body_h, selected_round);
        return dashboard_panel.drawRoot(self, ctx, arena_surface, rounds_surface, trace_surface);
    }

    // Analysis: aggregate rule/member views and drill-downs.
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
            .rules = &.{},
            .members = &.{},
            .models = &.{},
            .alerts = &.{},
        };
        const ins: *const data.AnalysisData = if (live_analysis) |*li| li else &empty_analysis;
        return analysis_panel.drawRoot(self, ctx, ins, analysis_available);
    }

    // Settings: vertical sidebar + content pane (web-style layout)
    fn drawSettings(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        return settings_panel.drawSettings(self, ctx);
    }

    // Spawn `clumsies flush` synchronously and report the result in
    // the status line. Synchronous is fine here: the upload worker is a
    // short-lived CLI that flushes buffered attestation events and exits.
    pub fn flushAttestation(self: *Dashboard) void {
        self.status_line = "Flushing attestation...";
        const alloc = self.api_state.allocator();
        var child = std.process.Child.init(&.{ "clumsies", "flush" }, alloc);
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

    pub fn getPrsForRule(self: *Dashboard, rule_path: []const u8) []const data.PullRequestEntry {
        const prs = self.api_state.rule_prs_cache.lookup(.{ .value = rule_path }) orelse return &.{};
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        return api.view_model.toPrEntries(self.viewAllocator(), prs, rule_path, self.api_state);
    }

    pub fn getRules(self: *Dashboard) []const data.RuleEntry {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.rules) |lp| {
            return api.view_model.toRuleEntries(self.viewAllocator(), lp);
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

    /// Pump the library rule content pending slot: on .ok, stash the
    /// response in the cache keyed by path so subsequent draws can
    /// retrieve it synchronously. On any error outcome, record the
    /// failure against the selected path so widget sync does not
    /// re-dispatch on every tick; the next `invalidateOnDemandCaches`
    /// or a navigation to a different rule clears the marker.
    fn consumeRuleContentResult(self: *Dashboard) void {
        const result = self.api_state.rule_content_pending.consume() orelse return;
        switch (result) {
            .ok => |resp| {
                self.api_state.rule_content_cache.store(.{ .value = resp.path }, resp);
            },
            else => {
                if (self.selectedRulePath()) |path| {
                    self.api_state.rule_content_cache.markFailed(.{ .value = path });
                }
            },
        }
    }

    /// Pump the library rule PR list pending slot. Routes the cache
    /// write against `payload.rule_id` — the id the request was
    /// issued for — rather than the current UI selection, so a rule
    /// switch mid-flight cannot store the list under the wrong path.
    /// On error, mark the currently selected rule as failed so the
    /// widget loop does not re-dispatch on every tick.
    fn consumeRulePrsResult(self: *Dashboard) void {
        const result = self.api_state.rule_prs_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                const path = self.lookupRulePath(payload.rule_id) orelse return;
                self.api_state.rule_prs_cache.store(.{ .value = path }, payload.prs);
            },
            else => {
                if (self.selectedRulePath()) |path| {
                    self.api_state.rule_prs_cache.markFailed(.{ .value = path });
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
                self.api_state.ws_manifest_cache.store(.{ .value = payload.ws_id }, payload.rules);
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
    /// operation, diff lines, attestation refers) against the response's
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

    /// pr_id of the currently-selected PR in the rule-detail drill-
    /// down, or null when nothing is selected.
    fn activePrId(self: *Dashboard) ?[]const u8 {
        const rules = self.getRules();
        const rule_idx = @min(self.selected_rule, if (rules.len > 0) rules.len - 1 else 0);
        if (rules.len == 0) return null;
        const prs = self.getPrsForRule(rules[rule_idx].path);
        if (prs.len == 0) return null;
        const pr_idx = @min(self.selected_pr_idx, prs.len - 1);
        return prs[pr_idx].id;
    }

    /// Recompute the 8 derived pr_detail_* fields from the just-fetched
    /// response. Picking the active operation requires the currently
    /// cached library PR list so the op matching the selected rule
    /// is surfaced first.
    fn refreshPrDetailDerivedFields(
        self: *Dashboard,
        pr_id: []const u8,
        resp: @import("clumsies_lib").protocol.collab_api.RulePrDetailResponse,
    ) void {
        const alloc = self.api_state.allocator();

        const rules = self.getRules();
        const rule_idx = @min(self.selected_rule, if (rules.len > 0) rules.len - 1 else 0);
        const target_rule_id: ?[]const u8 = if (rules.len > 0)
            self.lookupRuleId(rules[rule_idx].path)
        else
            null;

        var pick_idx: ?usize = null;
        if (target_rule_id) |tid| {
            for (resp.operations, 0..) |op, i| {
                if (op.rule_id) |pid| {
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
        var op_base_hash: ?[]const u8 = null;
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
            if (op.base_hash) |bh| op_base_hash = alloc.dupe(u8, bh) catch null;
            op_index = @intCast(@min(i, std.math.maxInt(u16)));
        }
        const attestation_refers: u16 = @intCast(@min(resp.attestation_summary.refer_count, std.math.maxInt(u16)));
        const stored_pr_id = alloc.dupe(u8, pr_id) catch null;

        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        self.api_state.pr_detail_id = stored_pr_id;
        self.api_state.pr_detail_diff = diff_lines;
        self.api_state.pr_detail_attestation_refers = attestation_refers;
        self.api_state.pr_detail_op_type = op_type;
        self.api_state.pr_detail_op_current_path = op_current_path;
        self.api_state.pr_detail_op_new_path = op_new_path;
        self.api_state.pr_detail_op_base_hash = op_base_hash;
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
        const all_p = self.getRules();
        const si = @min(self.selected_rule, if (all_p.len > 0) all_p.len - 1 else 0);
        if (all_p.len == 0) return;
        const prs_for = self.getPrsForRule(all_p[si].path);
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
        const all_p = self.getRules();
        const si = @min(self.selected_rule, if (all_p.len > 0) all_p.len - 1 else 0);
        if (all_p.len == 0) return;
        const prs_for = self.getPrsForRule(all_p[si].path);
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
                    .rules = 0,
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

    fn wsRulesCount(self: *Dashboard) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.ws_detail) |ws_d| return ws_d.ws_rules.len;
        return 0;
    }

    const AnalysisCounts = struct { rule_count: usize, member_count: usize, input_count: usize };

    const AnalysisScopeInfo = struct {
        label: []const u8,
        ws_id: ?[]const u8,
    };

    const ScopedAttestationData = struct {
        rounds: []const attestation_reader.RoundEvent,
    };

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

    fn scopedAttestationData(self: *const Dashboard) ?ScopedAttestationData {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();

        const local = self.api_state.local_stats orelse return null;
        const scope = self.currentAnalysisScopeLocked();
        if (scope.ws_id) |ws_id| {
            if (local.workspace(ws_id)) |ws| {
                return .{
                    .rounds = ws.rounds,
                };
            }
            return .{
                .rounds = &.{},
            };
        }
        return .{
            .rounds = local.rounds,
        };
    }

    fn dashboardSummary(rounds: []const attestation_reader.RoundEvent, active_session_count: usize) dashboard_panel.DashboardSummary {
        var summary: dashboard_panel.DashboardSummary = .{
            .round_count = rounds.len,
            .active_session_count = active_session_count,
        };
        for (rounds) |round| {
            if (round.submit_count > 0) summary.submitted_count += 1;
            if (round.refer_count > 0) summary.referred_count += 1;
            if (round.reject_count > 0) summary.rejected_count += 1;
            if (round.submit_count == 0 and round.reject_count == 0) summary.open_count += 1;
        }
        return summary;
    }

    fn getAnalysisCounts(self: *Dashboard) AnalysisCounts {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();

        const scope = self.currentAnalysisScopeLocked();
        const input_count: usize = if (self.api_state.local_stats) |local| blk: {
            const rounds = if (scope.ws_id) |ws_id|
                (if (local.workspace(ws_id)) |ws| ws.rounds else &.{})
            else
                local.rounds;
            break :blk rounds.len;
        } else 0;

        const rule_count: usize = if (self.api_state.org_stats) |stats|
            stats.rules.len
        else
            0;

        return .{
            .rule_count = rule_count,
            .member_count = if (self.api_state.org_stats) |stats| stats.users.len else 0,
            .input_count = input_count,
        };
    }

    fn shiftSettingsTab(self: *Dashboard, delta: i8) void {
        settings_panel.shiftSettingsTab(self, delta);
    }

    // Modal overlay showing the full user input for the selected round.
    fn drawInputDetailOverlay(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const content_and_ts: struct { content: []const u8, ts: i64 } = blk: {
            const scoped = self.scopedAttestationData() orelse break :blk .{ .content = "", .ts = 0 };
            if (scoped.rounds.len == 0) break :blk .{ .content = "", .ts = 0 };
            const idx = @min(self.analysis_input_cursor, scoped.rounds.len - 1);
            break :blk .{ .content = scoped.rounds[idx].content, .ts = scoped.rounds[idx].timestamp };
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
            .discard_draft => "Discard draft:",
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
        const all_rules = self.getRules();
        const sel_idx = @min(self.selected_rule, if (all_rules.len > 0) all_rules.len - 1 else 0);
        const title = if (all_rules.len > 0) blk: {
            const p = &all_rules[sel_idx];
            const prs = self.getPrsForRule(p.path);
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
            .dashboard => "Live interaction rounds and attestation closure.",
            .library => "Bundle facet, rule list, and passive preview.",
            .workspace => "Workspace list and sync status detail.",
            .analysis => "Rule and member aggregates.",
        };
    }

    /// Reload `drafts/index.json` into the per-category lookup maps
    /// and recompute totals. Called once at init and again after every
    /// edit op (`e`, `D`, `m`). No-op when no workspace is active —
    /// draft features just stay silent rather than surface an error.
    pub fn refreshDraftsCache(self: *Dashboard) void {
        self.drafts_by_rule_path = .{};
        self.drafts_by_context_path = .{};
        self.drafts_by_meta_prompt_path = .{};
        // drafts_create_*_paths are handed to the file tree, which
        // stores them in its `expanded` StringHashMap and `dir_paths`
        // array without duping. Both the hashmap key and the dir
        // path slice survive across subsequent refreshes (the tree
        // only rebuilds rows on sync, not keys). So these strings
        // must live in a long-lived allocator, NOT drafts_arena
        // (which is reset on every refresh). Allocate via the
        // api_state allocator, which is backed by a session-lifetime
        // arena. Individual `free` calls are no-ops there, so the
        // old slices leak within the arena until session end — that
        // is acceptable for the few bytes per refresh this costs.
        self.drafts_create_rule_paths = &.{};
        self.drafts_create_context_paths = &.{};
        self.drafts_total = 0;
        self.drafts_ready = 0;
        const ws_id = self.activeWsId() orelse return;
        self.drafts_cache_seeded = true;
        _ = self.drafts_arena.reset(.retain_capacity);
        const arena = self.drafts_arena.allocator();
        const api_alloc = self.api_state.allocator();

        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return;
        var index = drafts_mod.loadIndex(arena, ws_dir) catch return;
        defer index.deinit(arena);

        var create_rules: std.ArrayListUnmanaged([]const u8) = .empty;
        var create_contexts: std.ArrayListUnmanaged([]const u8) = .empty;

        for (index.entries.items) |entry| {
            switch (entry.status) {
                .merged, .rejected => continue,
                else => {},
            }
            self.drafts_total += 1;
            if (entry.status == .ready) self.drafts_ready += 1;

            // Lookup map keys can live in drafts_arena: the maps are
            // rebuilt from scratch on every refresh, so no key is
            // ever observed after its arena reset.
            const key_src = entry.current_path orelse entry.draft_path;
            const key = arena.dupe(u8, key_src) catch continue;
            const target_map = switch (entry.category) {
                .rule => &self.drafts_by_rule_path,
                .context => &self.drafts_by_context_path,
                .meta_prompt => &self.drafts_by_meta_prompt_path,
            };
            target_map.put(arena, key, entry.status) catch {};

            if (entry.operation == .create and entry.category != .meta_prompt) {
                // Long-lived dup — see the note at the top of this
                // function. The tree borrows these slices beyond a
                // single refresh so drafts_arena is unsafe.
                const path_copy = api_alloc.dupe(u8, entry.draft_path) catch continue;
                const dest = switch (entry.category) {
                    .rule => &create_rules,
                    .context => &create_contexts,
                    .meta_prompt => unreachable,
                };
                dest.append(api_alloc, path_copy) catch {};
            }
        }

        self.drafts_create_rule_paths = create_rules.toOwnedSlice(api_alloc) catch &.{};
        self.drafts_create_context_paths = create_contexts.toOwnedSlice(api_alloc) catch &.{};
    }

    pub fn draftStatusFor(
        self: *const Dashboard,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?drafts_mod.DraftStatus {
        return switch (category) {
            .rule => self.drafts_by_rule_path.get(path),
            .context => self.drafts_by_context_path.get(path),
            .meta_prompt => self.drafts_by_meta_prompt_path.get(path),
        };
    }

    /// Read the current draft bytes for a file, allocated in
    /// view_arena so the caller can use the slice for the remainder of
    /// the current frame. Returns null when no draft is tracked or
    /// the file is missing / unreadable. Both Library and Workspace
    /// content panels call this to overlay the working copy on top of
    /// the authoritative cache.
    pub fn draftContentForView(
        self: *Dashboard,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?[]const u8 {
        const ws_id = self.activeWsId() orelse return null;
        const has_draft = switch (category) {
            .rule => self.drafts_by_rule_path.contains(path),
            .context => self.drafts_by_context_path.contains(path),
            .meta_prompt => self.drafts_by_meta_prompt_path.contains(path),
        };
        if (!has_draft) return null;
        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return null;
        return drafts_mod.readDraftFile(arena, ws_dir, category, path) catch null;
    }

    /// Derive the draft target from the currently focused module and
    /// its selection. Returns null when the active module doesn't have
    /// an editable selection (e.g. no workspace bound, a directory row
    /// is highlighted, or the workspace detail hasn't loaded).
    pub fn selectedDraftTarget(self: *Dashboard) ?DraftTarget {
        const ws_id = self.activeWsId() orelse return null;
        switch (self.selected_module) {
            .library => {
                const rules = self.getRules();
                if (self.selected_rule < rules.len) {
                    const rule = &rules[self.selected_rule];
                    return .{
                        .ws_id = ws_id,
                        .category = .rule,
                        .path = rule.path,
                        .rule_id = self.lookupRuleId(rule.path),
                    };
                }
                // Virtual row: a local create-op draft that has no
                // server-side rule yet. The index is offset by
                // `rules.len` so we can recover the create-draft
                // path from drafts_create_rule_paths.
                const k = self.selected_rule - rules.len;
                if (k >= self.drafts_create_rule_paths.len) return null;
                return .{
                    .ws_id = ws_id,
                    .category = .rule,
                    .path = self.drafts_create_rule_paths[k],
                };
            },
            .workspace => {
                const live = api.state.wsDetail(self.api_state, ws_id) orelse return null;
                const ws_tree = self.currentWsTree();
                if (ws_tree.dirPathAt(self.ws_list_sel) != null) return null;
                const leaf = ws_tree.leafIndexAt(self.ws_list_sel) orelse return null;
                switch (self.ws_tab) {
                    .context => {
                        if (leaf < live.context_files.len) {
                            const f = live.context_files[leaf];
                            return .{
                                .ws_id = ws_id,
                                .category = .context,
                                .path = f.path,
                                .context_id = f.context_id,
                            };
                        }
                        // Virtual row: create-op context draft.
                        const k = leaf - live.context_files.len;
                        if (k >= self.drafts_create_context_paths.len) return null;
                        return .{
                            .ws_id = ws_id,
                            .category = .context,
                            .path = self.drafts_create_context_paths[k],
                        };
                    },
                    .rules => {
                        if (leaf >= live.ws_rules.len) return null;
                        const wp = live.ws_rules[leaf];
                        const path = if (wp.path.len > 0) wp.path else blk: {
                            for (self.getRules()) |lp| {
                                if (std.mem.eql(u8, lp.content_hash, wp.content_hash)) break :blk lp.path;
                            }
                            return null;
                        };
                        return .{
                            .ws_id = ws_id,
                            .category = .rule,
                            .path = path,
                            .rule_id = self.lookupRuleId(path),
                        };
                    },
                }
            },
            else => return null,
        }
    }

    pub fn selectedContentId(self: *Dashboard) ?[]const u8 {
        switch (self.selected_module) {
            .library => {
                const rules = self.getRules();
                if (self.selected_rule >= rules.len) return null;
                return self.lookupRuleId(rules[self.selected_rule].path);
            },
            .workspace => {
                const ws_id = self.activeWsId() orelse return null;
                const live = api.state.wsDetail(self.api_state, ws_id) orelse return null;
                const ws_tree = self.currentWsTree();
                if (ws_tree.dirPathAt(self.ws_list_sel) != null) return null;
                const leaf = ws_tree.leafIndexAt(self.ws_list_sel) orelse return null;
                return switch (self.ws_tab) {
                    .context => if (leaf < live.context_files.len) live.context_files[leaf].context_id else null,
                    .rules => if (leaf < live.ws_rules.len) live.ws_rules[leaf].rule_id else null,
                };
            },
            else => return null,
        }
    }

    pub fn copySelectedContentId(self: *Dashboard) bool {
        const id = self.selectedContentId() orelse return false;
        workspace_panel.copyTextToClipboard(self.api_state.backing_allocator, id);
        self.status_line = "Copied id to clipboard.";
        return true;
    }

    /// Entry point for the `e` key. Finds or creates a modify-draft for
    /// the currently selected file, shells out to $EDITOR, then
    /// refreshes caches so the right panel picks up the new draft
    /// bytes on the next render.
    pub fn editSelectedDraft(self: *Dashboard) void {
        // Refresh must run BEFORE target capture. refreshDraftsCache
        // resets drafts_arena, which backs the virtual-row path
        // slices in drafts_create_*_paths. A target captured before
        // refresh for a create-op draft would point into freed arena
        // memory on the next access. Same reasoning applies to every
        // draft handler below.
        self.refreshDraftsCache();
        const target = self.selectedDraftTarget() orelse {
            self.status_line = "No editable selection.";
            return;
        };
        self.editDraft(target);
    }

    fn editDraft(self: *Dashboard, target: DraftTarget) void {
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch {
            self.status_line = "Could not resolve workspace directory.";
            return;
        };
        defer alloc.free(ws_dir);

        if (self.draftStatusFor(target.category, target.path) == null) {
            const seed = self.seedContentForTarget(target) orelse "";
            const seed_hash = util_hash.contentHash(seed);
            drafts_mod.createDraft(alloc, ws_dir, .{
                .category = target.category,
                .operation = .modify,
                .draft_path = target.path,
                .current_path = target.path,
                .rule_id = target.rule_id,
                .context_id = target.context_id,
                .base_hash = seed_hash[0..],
            }, seed) catch |err| switch (err) {
                // Index and in-memory map raced (e.g., the user ran a
                // previous session that left entries, then restarted
                // before current_user had a chance to re-seed the
                // map). The draft genuinely exists on disk — just
                // open it instead of aborting.
                error.DraftAlreadyExists => {},
                else => {
                    self.status_line = @errorName(err);
                    return;
                },
            };
        }

        const draft_abs = std.fs.path.join(
            alloc,
            &.{ ws_dir, "drafts", @tagName(target.category), target.path },
        ) catch return;
        defer alloc.free(draft_abs);

        const result = editor_host.editFile(
            alloc,
            &self.app.vx,
            &self.app.tty,
            self.env_map,
            draft_abs,
        ) catch |err| {
            self.status_line = @errorName(err);
            return;
        };
        self.status_line = switch (result) {
            .completed => "Draft saved.",
            .failed => "Editor exited non-zero.",
            .editor_not_found => "No $EDITOR resolved.",
            .spawn_failed => "Editor spawn failed.",
        };
        self.refreshDraftsCache();
    }

    /// Pull the authoritative bytes for a file so a new modify-draft
    /// can seed its copy. Rules pull from the library cache; context
    /// files from the workspace context content cache.
    fn seedContentForTarget(self: *Dashboard, target: DraftTarget) ?[]const u8 {
        return switch (target.category) {
            .rule => self.cachedRuleBody(target.path),
            .context => self.cachedWorkspaceContextBody(target.ws_id, target.path),
            .meta_prompt => null,
        };
    }

    /// Handler for the `m` key. Flips between `editing` and `ready`.
    /// Submitted / merged / rejected / conflicted drafts are not
    /// toggled — they represent terminal or pending-review state.
    pub fn toggleSelectedDraftReady(self: *Dashboard) void {
        self.refreshDraftsCache();
        const target = self.selectedDraftTarget() orelse return;
        const current = self.draftStatusFor(target.category, target.path) orelse {
            self.status_line = "No draft to mark ready.";
            return;
        };
        const next_status: drafts_mod.DraftStatus = switch (current) {
            .editing => .ready,
            .ready => .editing,
            else => {
                self.status_line = "Draft status is locked.";
                return;
            },
        };

        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch return;
        defer alloc.free(ws_dir);
        drafts_mod.setDraftStatus(alloc, ws_dir, target.category, target.path, next_status) catch |err| {
            self.status_line = @errorName(err);
            return;
        };
        self.status_line = if (next_status == .ready) "Draft marked ready." else "Draft marked editing.";
        self.refreshDraftsCache();
    }

    /// Arms the confirm overlay for a discard. The actual discard runs
    /// from the confirm `y` branch so it matches the rest of the
    /// destructive-operation UX.
    pub fn requestDiscardSelectedDraft(self: *Dashboard) void {
        self.refreshDraftsCache();
        const target = self.selectedDraftTarget() orelse return;
        if (self.draftStatusFor(target.category, target.path) == null) {
            self.status_line = "No draft to discard.";
            return;
        }
        // Target may have been captured from drafts_arena (virtual
        // rows) — dup its path into the api_state allocator so the
        // confirm overlay can outlive any subsequent refresh call
        // without reading freed memory.
        self.releasePendingDiscardTarget();
        const path_copy = self.api_state.allocator().dupe(u8, target.path) catch {
            self.status_line = "Out of memory capturing draft target.";
            return;
        };
        self.pending_discard_target = .{
            .ws_id = target.ws_id,
            .category = target.category,
            .path = path_copy,
            .rule_id = target.rule_id,
            .context_id = target.context_id,
        };
        self.pending_discard_path_owned = path_copy;
        self.confirm_message = path_copy;
        self.confirm_action = .discard_draft;
        self.show_confirm = true;
    }

    /// Free the duped strings backing pending_discard_target, if any.
    /// Safe to call with no pending discard.
    fn releasePendingDiscardTarget(self: *Dashboard) void {
        if (self.pending_discard_path_owned) |p| {
            self.api_state.allocator().free(p);
            self.pending_discard_path_owned = null;
        }
        self.pending_discard_target = null;
    }

    fn commitDiscardDraft(self: *Dashboard) void {
        const target = self.pending_discard_target orelse return;
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch return;
        defer alloc.free(ws_dir);
        drafts_mod.discardDraft(alloc, ws_dir, target.category, target.path) catch |err| {
            self.status_line = @errorName(err);
            return;
        };
        self.status_line = "Draft discarded.";
        self.releasePendingDiscardTarget();
        self.refreshDraftsCache();
    }

    /// Handler for the `p` key. Opens the PR Composer when the
    /// selected file has a ready draft. The composer is intentionally
    /// single-op for the initial cut — multi-draft select is deferred
    /// to a follow-up.
    pub fn openPrComposer(self: *Dashboard) void {
        self.refreshDraftsCache();
        const target = self.selectedDraftTarget() orelse {
            self.status_line = "No editable selection.";
            return;
        };
        const status = self.draftStatusFor(target.category, target.path) orelse {
            self.status_line = "No draft for this selection.";
            return;
        };
        if (status != .ready) {
            self.status_line = "Draft must be marked ready (m) before submit.";
            return;
        }
        // Composer state persists across frames while the overlay is
        // open; between open and submit the user might never trigger
        // another refresh, but a future code path (tick, background
        // consumer) could. Dup path into the stable allocator so the
        // overlay draw and submit paths cannot read freed bytes.
        self.releaseComposerTarget();
        const path_copy = self.api_state.allocator().dupe(u8, target.path) catch {
            self.status_line = "Out of memory opening composer.";
            return;
        };
        self.pr_composer_target = .{
            .ws_id = target.ws_id,
            .category = target.category,
            .path = path_copy,
            .rule_id = target.rule_id,
            .context_id = target.context_id,
        };
        self.pr_composer_path_owned = path_copy;
        // Capture the draft's operation so the overlay can label
        // `op:` correctly (create / modify / rename / delete). Falls
        // back to .modify when the index lookup fails, which is the
        // historical default and keeps the overlay usable if the
        // draft file was tampered with out of band.
        self.pr_composer_operation = self.lookupDraftOperation(target) orelse .modify;
        self.pr_composer_desc_len = 0;
        self.pr_composer_submitting = false;
        self.show_pr_composer = true;
    }

    fn lookupDraftOperation(self: *Dashboard, target: DraftTarget) ?drafts_mod.DraftOperation {
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch return null;
        defer alloc.free(ws_dir);
        var index = drafts_mod.loadIndex(alloc, ws_dir) catch return null;
        defer index.deinit(alloc);
        for (index.entries.items) |entry| {
            if (entry.category != target.category) continue;
            if (!std.mem.eql(u8, entry.draft_path, target.path)) continue;
            return entry.operation;
        }
        return null;
    }

    /// Free the duped strings backing pr_composer_target, if any.
    /// Safe to call when no composer is open.
    fn releaseComposerTarget(self: *Dashboard) void {
        if (self.pr_composer_path_owned) |p| {
            self.api_state.allocator().free(p);
            self.pr_composer_path_owned = null;
        }
        self.pr_composer_target = null;
    }

    pub fn cancelPrComposer(self: *Dashboard) void {
        self.show_pr_composer = false;
        self.pr_composer_submitting = false;
        self.pr_composer_desc_len = 0;
        self.releaseComposerTarget();
    }

    pub fn submitPrComposer(self: *Dashboard) void {
        if (self.pr_composer_submitting) return;
        if (self.pr_composer_desc_len == 0) {
            self.status_line = "Description is required.";
            return;
        }
        const target = self.pr_composer_target orelse {
            self.status_line = "No composer target set.";
            return;
        };
        switch (target.category) {
            .rule => self.submitRulePr(target),
            .context => self.submitContextPr(target),
            .meta_prompt => {},
        }
    }

    fn readDraftForSubmit(
        self: *Dashboard,
        alloc: std.mem.Allocator,
        target: DraftTarget,
    ) ?struct {
        ws_dir: []const u8,
        content: []const u8,
        entry: ?DraftSubmitEntry,
    } {
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch {
            self.status_line = "Could not resolve workspace directory.";
            return null;
        };
        errdefer alloc.free(ws_dir);

        const content = drafts_mod.readDraftFile(alloc, ws_dir, target.category, target.path) catch |err| {
            self.status_line = @errorName(err);
            return null;
        };
        errdefer alloc.free(content);

        var index = drafts_mod.loadIndex(alloc, ws_dir) catch |err| {
            self.status_line = @errorName(err);
            return null;
        };
        defer index.deinit(alloc);

        var entry_out: ?DraftSubmitEntry = null;
        for (index.entries.items) |e| {
            if (e.category != target.category) continue;
            if (!std.mem.eql(u8, e.draft_path, target.path)) continue;
            entry_out = .{
                .operation = e.operation,
                .base_hash = if (e.base_hash) |h| (alloc.dupe(u8, h) catch null) else null,
            };
            break;
        }

        return .{ .ws_dir = ws_dir, .content = content, .entry = entry_out };
    }

    const DraftSubmitEntry = struct {
        operation: drafts_mod.DraftOperation,
        base_hash: ?[]const u8,
    };

    fn submitRulePr(self: *Dashboard, target: DraftTarget) void {
        const alloc = self.api_state.allocator();
        const read = self.readDraftForSubmit(alloc, target) orelse return;
        defer alloc.free(read.ws_dir);
        defer alloc.free(read.content);
        defer if (read.entry) |e| {
            if (e.base_hash) |h| alloc.free(h);
        };

        const entry = read.entry orelse {
            self.status_line = "Draft entry missing; try again.";
            return;
        };
        // Spec s1-5 §2.2: modify/rename/delete must carry rule_id +
        // base_hash; create must carry path + content. The hub
        // rejects any operation that is missing a required field.
        const operation_type: []const u8 = switch (entry.operation) {
            .create => "create",
            .modify => "modify",
            .rename => "rename",
            .delete => "delete",
        };

        const desc_copy = alloc.dupe(u8, self.pr_composer_desc_buf[0..self.pr_composer_desc_len]) catch return;
        defer alloc.free(desc_copy);
        const content_copy: ?[]const u8 = if (entry.operation == .delete)
            null
        else
            (alloc.dupe(u8, read.content) catch return);
        defer if (content_copy) |c| alloc.free(c);

        // Modify/rename/delete need rule_id; resolve from the draft
        // target first (authoritative) then fall back to a library
        // lookup by path. Create drafts have neither — that's the
        // expected missing rule_id, not an error.
        const rule_id_copy_opt: ?[]const u8 = if (entry.operation == .create)
            null
        else blk: {
            const pid = target.rule_id orelse self.lookupRuleId(target.path) orelse {
                self.status_line = "Unknown rule id for this draft.";
                return;
            };
            break :blk (alloc.dupe(u8, pid) catch return);
        };
        defer if (rule_id_copy_opt) |pid| alloc.free(pid);

        const path_copy_opt: ?[]const u8 = if (entry.operation == .create)
            (alloc.dupe(u8, target.path) catch return)
        else
            null;
        defer if (path_copy_opt) |p| alloc.free(p);

        const base_hash_copy_opt: ?[]const u8 = if (entry.base_hash) |h|
            (alloc.dupe(u8, h) catch return)
        else
            null;
        defer if (base_hash_copy_opt) |h| alloc.free(h);

        if (entry.operation == .modify or entry.operation == .rename) {
            if (base_hash_copy_opt == null) {
                self.status_line = "Missing base_hash for modify/rename draft.";
                return;
            }
        }

        api.specs.dispatchFromState(
            api.specs.CreateRulePrParams,
            api.specs.CreateRulePrResponse,
            api.specs.create_rule_pr,
            &self.api_state.create_rule_pr_pending,
            self.api_state,
            .{
                .description = desc_copy,
                .operation_type = operation_type,
                .rule_id = rule_id_copy_opt,
                .path = path_copy_opt,
                .content = content_copy,
                .base_hash = base_hash_copy_opt,
            },
        );
        self.pr_composer_submitting = true;
        self.status_line = "Submitting PR...";
    }

    fn submitContextPr(self: *Dashboard, target: DraftTarget) void {
        const alloc = self.api_state.allocator();
        const read = self.readDraftForSubmit(alloc, target) orelse return;
        defer alloc.free(read.ws_dir);
        defer alloc.free(read.content);
        defer if (read.entry) |e| {
            if (e.base_hash) |h| alloc.free(h);
        };

        const entry = read.entry orelse {
            self.status_line = "Draft entry missing; try again.";
            return;
        };
        const operation_type: []const u8 = switch (entry.operation) {
            .create => "create",
            .modify => "modify",
            .rename => "rename",
            .delete => "delete",
        };

        const desc_copy = alloc.dupe(u8, self.pr_composer_desc_buf[0..self.pr_composer_desc_len]) catch return;
        defer alloc.free(desc_copy);
        const content_copy = alloc.dupe(u8, read.content) catch return;
        defer alloc.free(content_copy);
        const ws_id_copy = alloc.dupe(u8, target.ws_id) catch return;
        defer alloc.free(ws_id_copy);
        const path_copy_opt: ?[]const u8 = if (entry.operation == .create)
            (alloc.dupe(u8, target.path) catch return)
        else
            null;
        defer if (path_copy_opt) |p| alloc.free(p);
        const context_id_copy_opt: ?[]const u8 = if (entry.operation != .create)
            if (target.context_id) |cid| (alloc.dupe(u8, cid) catch return) else null
        else
            null;
        defer if (context_id_copy_opt) |cid| alloc.free(cid);
        const base_hash_copy_opt: ?[]const u8 = if (entry.base_hash) |h|
            (alloc.dupe(u8, h) catch return)
        else
            null;
        defer if (base_hash_copy_opt) |h| alloc.free(h);

        if (entry.operation != .create and context_id_copy_opt == null) {
            self.status_line = "Missing context_id for modify/rename/delete.";
            return;
        }

        api.specs.dispatchFromState(
            api.specs.CreateContextPrParams,
            api.specs.CreateContextPrResponse,
            api.specs.create_context_pr,
            &self.api_state.create_context_pr_pending,
            self.api_state,
            .{
                .ws_id = ws_id_copy,
                .description = desc_copy,
                .operation_type = operation_type,
                .context_id = context_id_copy_opt,
                .path = path_copy_opt,
                .content = content_copy,
                .base_hash = base_hash_copy_opt,
            },
        );
        self.pr_composer_submitting = true;
        self.status_line = "Submitting PR...";
    }

    fn handlePrComposerKey(self: *Dashboard, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (self.pr_composer_submitting) {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.pr_composer_submitting = false;
                ctx.consumeAndRedraw();
            }
            return;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            self.cancelPrComposer();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.submitPrComposer();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.pr_composer_desc_len > 0) {
                self.pr_composer_desc_len -= 1;
                ctx.consumeAndRedraw();
            }
            return;
        }
        if (key.text) |text| {
            const remaining = self.pr_composer_desc_buf.len - self.pr_composer_desc_len;
            if (text.len > 0 and text.len <= remaining) {
                @memcpy(self.pr_composer_desc_buf[self.pr_composer_desc_len..][0..text.len], text);
                self.pr_composer_desc_len += text.len;
                ctx.consumeAndRedraw();
            }
        } else if (key.codepoint >= 0x20 and key.codepoint < 0x7f) {
            if (self.pr_composer_desc_len < self.pr_composer_desc_buf.len) {
                self.pr_composer_desc_buf[self.pr_composer_desc_len] = @intCast(key.codepoint);
                self.pr_composer_desc_len += 1;
                ctx.consumeAndRedraw();
            }
        }
    }

    fn drawPrComposerOverlay(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const box_w = @min(size.width -| 4, 60);
        const box_h: u16 = 9;
        const target = self.pr_composer_target orelse DraftTarget{
            .ws_id = "",
            .category = .rule,
            .path = "",
        };
        const title = switch (target.category) {
            .rule => "New Rule PR",
            .context => "New Context PR",
            .meta_prompt => "New Meta-Prompt PR",
        };
        const path_label = switch (target.category) {
            .rule => "rule:",
            .context => "file:",
            .meta_prompt => "file:",
        };
        const modal = Modal{
            .title = title,
            .box_width = box_w,
            .box_height = box_h,
            .anchor = .center,
            .footer = if (self.pr_composer_submitting) "Submitting... Esc cancel wait" else "Enter submit  Esc cancel",
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        const row = result.content_row;

        w.writeText(&surface, ctx, col, row, path_label, theme.textOn(theme.PANEL_ALT, theme.MUTED));
        w.writeText(&surface, ctx, col + 8, row, target.path, theme.boldOn(theme.PANEL_ALT, theme.TEXT));
        w.writeText(&surface, ctx, col, row + 1, "op:", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        const op_label: []const u8 = switch (self.pr_composer_operation) {
            .create => "create",
            .modify => "modify",
            .rename => "rename",
            .delete => "delete",
        };
        w.writeText(&surface, ctx, col + 8, row + 1, op_label, theme.textOn(theme.PANEL_ALT, theme.TEXT));

        w.writeText(&surface, ctx, col, row + 3, "description:", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        const desc_text = self.pr_composer_desc_buf[0..self.pr_composer_desc_len];
        const max_visible: usize = @as(usize, box_w -| 4);
        const visible_start = if (desc_text.len > max_visible) desc_text.len - max_visible else 0;
        const visible = desc_text[visible_start..];
        const display = try std.fmt.allocPrint(ctx.arena, "{s}_", .{visible});
        w.writeText(&surface, ctx, col, row + 4, display, theme.textOn(theme.PANEL_ALT, theme.TEXT));

        return surface;
    }

    pub fn openNewDraftForm(self: *Dashboard, category: drafts_mod.DraftCategory) void {
        if (self.activeWsId() == null) {
            self.status_line = "No workspace loaded yet; wait for bootstrap.";
            return;
        }
        self.new_draft_path_len = 0;
        self.new_draft_category = category;
        self.show_new_draft_form = true;
    }

    pub fn cancelNewDraftForm(self: *Dashboard) void {
        self.show_new_draft_form = false;
        self.new_draft_path_len = 0;
    }

    pub fn submitNewDraftForm(self: *Dashboard) void {
        if (self.new_draft_path_len == 0) {
            self.status_line = "Path is required.";
            return;
        }
        const ws_id = self.activeWsId() orelse return;
        const path = self.new_draft_path_buf[0..self.new_draft_path_len];
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, ws_id) catch {
            self.status_line = "Could not resolve workspace directory.";
            return;
        };
        defer alloc.free(ws_dir);

        const path_copy = alloc.dupe(u8, path) catch return;
        defer alloc.free(path_copy);

        const category = self.new_draft_category;
        drafts_mod.createDraft(alloc, ws_dir, .{
            .category = category,
            .operation = .create,
            .draft_path = path_copy,
        }, "") catch |err| {
            self.status_line = @errorName(err);
            return;
        };

        self.show_new_draft_form = false;
        self.new_draft_path_len = 0;
        self.refreshDraftsCache();

        const draft_abs = std.fs.path.join(alloc, &.{ ws_dir, "drafts", @tagName(category), path_copy }) catch return;
        defer alloc.free(draft_abs);

        const result = editor_host.editFile(
            alloc,
            &self.app.vx,
            &self.app.tty,
            self.env_map,
            draft_abs,
        ) catch |err| {
            self.status_line = @errorName(err);
            return;
        };
        self.status_line = switch (result) {
            .completed => "New draft saved.",
            .failed => "Editor exited non-zero.",
            .editor_not_found => "No $EDITOR resolved.",
            .spawn_failed => "Editor spawn failed.",
        };
        self.refreshDraftsCache();
    }

    fn handleNewDraftFormKey(self: *Dashboard, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.cancelNewDraftForm();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.submitNewDraftForm();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.new_draft_path_len > 0) {
                self.new_draft_path_len -= 1;
                ctx.consumeAndRedraw();
            }
            return;
        }
        if (key.text) |text| {
            const remaining = self.new_draft_path_buf.len - self.new_draft_path_len;
            if (text.len > 0 and text.len <= remaining) {
                @memcpy(self.new_draft_path_buf[self.new_draft_path_len..][0..text.len], text);
                self.new_draft_path_len += text.len;
                ctx.consumeAndRedraw();
            }
        } else if (key.codepoint >= 0x20 and key.codepoint < 0x7f) {
            if (self.new_draft_path_len < self.new_draft_path_buf.len) {
                self.new_draft_path_buf[self.new_draft_path_len] = @intCast(key.codepoint);
                self.new_draft_path_len += 1;
                ctx.consumeAndRedraw();
            }
        }
    }

    fn drawNewDraftFormOverlay(self: *Dashboard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const box_w = @min(size.width -| 4, 54);
        const box_h: u16 = 7;
        const title = switch (self.new_draft_category) {
            .rule => "New Rule Draft",
            .context => "New Context Draft",
            .meta_prompt => "New Meta-Prompt Draft",
        };
        const hint = switch (self.new_draft_category) {
            .rule => "e.g. rule/00_MY_RULE.md",
            .context => "e.g. spec/NEW_SPEC.md",
            .meta_prompt => "META_PROMPT.md",
        };
        const modal = Modal{
            .title = title,
            .box_width = box_w,
            .box_height = box_h,
            .anchor = .center,
            .footer = "Enter create & edit  Esc cancel",
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        const row = result.content_row;

        w.writeText(&surface, ctx, col, row, "path:", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        const path_text = self.new_draft_path_buf[0..self.new_draft_path_len];
        const max_visible: usize = @as(usize, box_w -| 4);
        const visible_start = if (path_text.len > max_visible) path_text.len - max_visible else 0;
        const visible = path_text[visible_start..];
        const display = try std.fmt.allocPrint(ctx.arena, "{s}_", .{visible});
        w.writeText(&surface, ctx, col, row + 1, display, theme.textOn(theme.PANEL_ALT, theme.TEXT));
        w.writeText(&surface, ctx, col, row + 3, hint, theme.fg(theme.MUTED));

        return surface;
    }

    fn consumeCreateRulePrResult(self: *Dashboard) void {
        const result = self.api_state.create_rule_pr_pending.consume() orelse return;
        self.pr_composer_submitting = false;
        switch (result) {
            .ok => |resp| {
                self.markComposerSubmitted(resp.pr_id, resp.status);
            },
            .api_error => |e| self.status_line = writeErrorStatus(self, "PR submit failed", e),
            .network_error => self.status_line = "PR submit failed: network error.",
            .invalid_response => self.status_line = "PR submit failed: malformed response.",
        }
    }

    fn consumeCreateContextPrResult(self: *Dashboard) void {
        const result = self.api_state.create_context_pr_pending.consume() orelse return;
        self.pr_composer_submitting = false;
        switch (result) {
            .ok => |resp| {
                self.markComposerSubmitted(resp.pr_id, resp.status);
            },
            .api_error => |e| self.status_line = writeErrorStatus(self, "PR submit failed", e),
            .network_error => self.status_line = "PR submit failed: network error.",
            .invalid_response => self.status_line = "PR submit failed: malformed response.",
        }
    }

    /// Shared post-submit path for both rule and context PRs. Marks
    /// the draft as submitted against disk, refreshes the in-memory
    /// cache, closes the composer, and posts a user-facing confirmation.
    fn markComposerSubmitted(self: *Dashboard, pr_id: []const u8, status: []const u8) void {
        const target = self.pr_composer_target orelse return;
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch return;
        defer alloc.free(ws_dir);
        drafts_mod.setDraftStatus(alloc, ws_dir, target.category, target.path, .submitted) catch {};
        self.refreshDraftsCache();
        // A new PR exists on the hub, but rule_prs_cache still
        // holds the pre-submit snapshot — the Pull Requests tab
        // would render stale rows until a manual `r` refresh. Drop
        // the cached details so the next render re-fetches.
        self.invalidateRemoteDetailRequests();
        self.show_pr_composer = false;
        self.pr_composer_desc_len = 0;
        self.releaseComposerTarget();
        self.status_line = std.fmt.allocPrint(
            self.api_state.allocator(),
            "PR {s} submitted ({s}).",
            .{ pr_id, status },
        ) catch "PR submitted.";
    }

    fn selectTab(self: *Dashboard, ctx: *vxfw.EventContext, tab: TopModule) void {
        self.selected_module = tab;
        self.analysis_show_input_detail = false;
        self.analysis_show_member_detail = false;
        self.analysis_expanded_rule = null;
        switch (tab) {
            .dashboard => {
                if (self.analysis_focus != .chart and self.analysis_focus != .inputs) {
                    self.analysis_focus = .inputs;
                }
            },
            .analysis => {
                if (self.analysis_focus != .rules and self.analysis_focus != .members) {
                    self.analysis_focus = .rules;
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
