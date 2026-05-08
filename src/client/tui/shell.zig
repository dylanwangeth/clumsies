//! Top-level TUI application shell. Owns global layout, overlays, shared
//! runtime state, and routes input/draw calls into feature containers.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("theme.zig");
const w = @import("widgets.zig");
const models = @import("models.zig");
const data = models.view_types;
const api = @import("api.zig");
const features = @import("features.zig");
const analysis_panel = features.analysis;
const dashboard_panel = features.dashboard;
const artifact_panel = features.artifact;
const review_panel = features.review;
const rule_detail_panel = features.review;
const settings_panel = features.settings;
const workspace_panel = features.workspace;
const auth_mod = @import("../auth.zig");
const auth_api = @import("clumsies_lib").protocol.auth_api;
const HubClient = @import("../hub_client.zig").HubClient;
const drafts_mod = @import("../drafts.zig");
const workspace_rule = @import("../rule.zig");
const workspace_config = @import("../workspace_config.zig");
const local_content = @import("../local_content.zig");
const runtime = @import("runtime.zig");
const tasks = @import("tasks.zig");
const util_hash = @import("clumsies_lib").util.hash;
const tui_prefs = @import("prefs.zig");

const log = std.log.scoped(.tui_event);

const editor_host = runtime.editor_host;
const attestation_reader = runtime.attestation_reader;
const Modal = w.Modal;

const WORKSPACE_DRAWER_WIDTH: u16 = 44;
const HELP_DRAWER_WIDTH: u16 = WORKSPACE_DRAWER_WIDTH;
const DRAWER_SIDE_MARGIN: u16 = 6;

const ConfirmAction = enum {
    none,
    bind_current_directory,
    remove_member,
    remove_workspace_member,
    delete_bundle,
    delete_workspace,
    revoke_token,
    discard_draft,
    quit,
};

const ConfirmChoice = enum { accept, cancel };

const TopModule = enum(u8) {
    dashboard,
    workspace,
    artifact,
    review,
    analysis,

    fn label(self: TopModule) []const u8 {
        return switch (self) {
            .dashboard => "Dashboard",
            .workspace => "Workspace",
            .artifact => "Artifact",
            .review => "Review",
            .analysis => "Analysis",
        };
    }
};

fn moduleName(module: TopModule) []const u8 {
    return switch (module) {
        .dashboard => "dashboard",
        .workspace => "workspace",
        .artifact => "artifact",
        .review => "review",
        .analysis => "analysis",
    };
}

fn confirmActionName(action: ConfirmAction) []const u8 {
    return switch (action) {
        .none => "none",
        .bind_current_directory => "bind_current_directory",
        .remove_member => "remove_member",
        .remove_workspace_member => "remove_workspace_member",
        .delete_bundle => "delete_bundle",
        .delete_workspace => "delete_workspace",
        .revoke_token => "revoke_token",
        .discard_draft => "discard_draft",
        .quit => "quit",
    };
}

fn keyName(key: vaxis.Key) []const u8 {
    if (key.matches(vaxis.Key.escape, .{})) return "escape";
    if (key.matches(vaxis.Key.enter, .{})) return "enter";
    if (key.matches(vaxis.Key.backspace, .{})) return "backspace";
    if (key.matches(vaxis.Key.tab, .{})) return "tab";
    if (key.matches(vaxis.Key.up, .{})) return "up";
    if (key.matches(vaxis.Key.down, .{})) return "down";
    if (key.matches(vaxis.Key.left, .{})) return "left";
    if (key.matches(vaxis.Key.right, .{})) return "right";
    if (key.matches(vaxis.Key.page_up, .{})) return "page_up";
    if (key.matches(vaxis.Key.page_down, .{})) return "page_down";
    if (key.matches(vaxis.Key.home, .{})) return "home";
    if (key.matches(vaxis.Key.end, .{})) return "end";
    if (key.matches(vaxis.Key.f2, .{})) return "f2";
    if (key.text) |text| {
        if (text.len > 0) return "text_input";
    }
    if (key.mods.ctrl) return "ctrl_key";
    return "key";
}

fn keyTextLen(key: vaxis.Key) usize {
    if (key.text) |text| return text.len;
    return 0;
}

const top_tabs = [_]TopModule{ .dashboard, .workspace, .artifact, .review, .analysis };

const WORKSPACE_METADATA_REFRESH_TICKS = 600;
const GLOBAL_METADATA_REFRESH_TICKS = 3000;
const HEALTH_CHECK_TICKS = 300;
const ATTESTATION_UPLOAD_TICKS = 600;
const PathTreeState = workspace_panel.PathTreeState;

const DraftTarget = features.drafts.DraftTarget;
const PendingPrAction = features.drafts.PendingPrAction;
const LoginMode = enum { sign_in, activate };
const LoginFocus = enum { hub_url, username, invite_token, password, submit };
const ProfileDialogKind = enum { username, password };
const ProfileDialogFocus = enum { first, second, submit };
const InviteDialogFocus = enum { username, role, submit };
const MemberDialogScope = enum { org, workspace };
const RoleDialogKind = enum { invite, change };
const ORG_ROLE_OPTIONS = [_][]const u8{ "member", "maintainer" };
const WORKSPACE_ROLE_OPTIONS = [_][]const u8{ "member", "admin" };

pub const Shell = struct {
    api_state: *api.state.ApiState,
    selected_module: TopModule = .dashboard,
    artifact: artifact_panel.State,
    review: rule_detail_panel.State,
    workspace: workspace_panel.State,
    dashboard: dashboard_panel.State,
    analysis: analysis_panel.State = .{},
    settings: settings_panel.State = .{},
    drafts: features.drafts.State,
    show_help: bool = false,
    show_settings: bool = false,
    show_confirm: bool = false,
    confirm_message: []const u8 = "",
    confirm_error_message: []const u8 = "",
    confirm_submitting: bool = false,
    confirm_action: ConfirmAction = .none,
    confirm_choice: ConfirmChoice = .accept,
    confirm_member_user_id_buf: [80]u8 = .{0} ** 80,
    confirm_member_user_id_len: usize = 0,
    confirm_workspace_id_buf: [80]u8 = .{0} ** 80,
    confirm_workspace_id_len: usize = 0,
    last_safe_layout_size: vxfw.Size = .{},
    system_notices: w.SystemNoticeQueue = .{},
    view_arena: std.heap.ArenaAllocator,
    last_workspace_id: ?[]const u8 = null,
    workspace_pref_applied: bool = false,
    tick_count: u64 = 0,
    login_hub_url_buf: [160]u8 = .{0} ** 160,
    login_hub_url_len: usize = 0,
    login_username_buf: [80]u8 = .{0} ** 80,
    login_username_len: usize = 0,
    login_password_buf: [128]u8 = .{0} ** 128,
    login_password_len: usize = 0,
    login_invite_token_buf: [128]u8 = .{0} ** 128,
    login_invite_token_len: usize = 0,
    login_mode: LoginMode = .sign_in,
    login_focus: LoginFocus = .hub_url,
    login_message: []const u8 = "",
    show_profile_dialog: bool = false,
    profile_dialog_kind: ProfileDialogKind = .username,
    profile_dialog_focus: ProfileDialogFocus = .first,
    profile_dialog_submitting: bool = false,
    profile_first_buf: [128]u8 = .{0} ** 128,
    profile_first_len: usize = 0,
    profile_second_buf: [128]u8 = .{0} ** 128,
    profile_second_len: usize = 0,
    profile_dialog_message: []const u8 = "",
    show_invite_dialog: bool = false,
    invite_dialog_kind: RoleDialogKind = .invite,
    invite_dialog_focus: InviteDialogFocus = .username,
    invite_dialog_submitting: bool = false,
    invite_username_buf: [80]u8 = .{0} ** 80,
    invite_username_len: usize = 0,
    invite_role_idx: usize = 0,
    invite_target_user_id_buf: [80]u8 = .{0} ** 80,
    invite_target_user_id_len: usize = 0,
    invite_dialog_message: []const u8 = "",
    invite_result_token_buf: [160]u8 = .{0} ** 160,
    invite_result_token_len: usize = 0,
    invite_token_copied: bool = false,
    invite_dialog_scope: MemberDialogScope = .org,
    invite_workspace_id_buf: [80]u8 = .{0} ** 80,
    invite_workspace_id_len: usize = 0,
    sign_out_should_quit: bool = false,
    quit_after_sign_out: bool = false,

    // Editor shell-out plumbing. `app` and `env_map` stay borrowed from
    // main.zig for the lifetime of the Shell. Active workspace is
    // resolved dynamically from `ws_sel` against the hub-provided
    // workspace list (see `activeWsId()`), not from a cwd binding.
    app: *vxfw.App,
    env_map: *const std.process.EnvMap,

    pub fn init(
        api_state: *api.state.ApiState,
        app: *vxfw.App,
        env_map: *const std.process.EnvMap,
    ) Shell {
        const prefs = tui_prefs.load(api_state.backing_allocator) catch tui_prefs.Prefs{};
        defer prefs.deinit(api_state.backing_allocator);
        const last_workspace_id = if (prefs.last_workspace_id) |id|
            api_state.backing_allocator.dupe(u8, id) catch null
        else
            null;
        var shell = Shell{
            .api_state = api_state,
            .artifact = artifact_panel.State.init(),
            .review = rule_detail_panel.State.init(),
            .workspace = workspace_panel.State.init(api_state.backing_allocator),
            .dashboard = dashboard_panel.State.init(),
            .drafts = features.drafts.State.init(api_state.backing_allocator),
            .view_arena = std.heap.ArenaAllocator.init(api_state.backing_allocator),
            .last_workspace_id = last_workspace_id,
            .app = app,
            .env_map = env_map,
        };
        shell.seedLoginDefaults();
        return shell;
    }

    pub fn deinit(self: *Shell) void {
        self.releaseComposerTarget();
        self.releasePendingDiscardTarget();
        self.releasePendingPrAction();
        const alloc = self.api_state.allocator();
        self.workspace.deinit(alloc);
        self.artifact.deinit(alloc);
        self.drafts.deinit();
        if (self.last_workspace_id) |id| self.api_state.backing_allocator.free(id);
        self.view_arena.deinit();
    }

    pub fn widget(self: *Shell) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Shell = @ptrCast(@alignCast(ptr));
        try self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Shell = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn viewAllocator(self: *Shell) std.mem.Allocator {
        return self.view_arena.allocator();
    }

    pub fn currentWsTree(self: *Shell) *PathTreeState {
        return switch (self.workspace.tab) {
            .context => &self.workspace.context_tree,
            .rules => &self.workspace.rules_tree,
        };
    }

    fn connectionHeaderNotice(self: *Shell) ?w.SystemNotice {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const now = self.system_notices.now();
        return switch (self.api_state.status) {
            .connected => null,
            .connecting => .{ .key = .connection, .kind = .loading, .persistence = .transient, .text = "\xe2\x86\xbb Connecting...", .created_tick = now },
            .disconnected => .{ .key = .connection, .kind = .warning, .persistence = .transient, .text = "Not connected", .created_tick = now },
            .error_auth => .{ .key = .connection, .kind = .failure, .persistence = .transient, .text = "Auth required", .created_tick = now },
            .error_network => .{ .key = .connection, .kind = .failure, .persistence = .transient, .text = "Offline", .created_tick = now },
        };
    }

    fn handleEvent(self: *Shell, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = self.view_arena.reset(.retain_capacity);
        switch (event) {
            .key_press => |key| {
                self.logKeyEvent(self.activeInputLayer(), key);
                if (self.shouldShowLoginPanel()) {
                    if (key.matches('c', .{ .ctrl = true })) {
                        log.info("quit_direct", .{});
                        ctx.consumeEvent();
                        ctx.quit = true;
                        return;
                    }
                    self.handleLoginKey(ctx, key);
                    return;
                }

                // Confirm overlay absorbs all keys
                if (self.show_confirm) {
                    if (self.confirm_submitting) {
                        ctx.consumeEvent();
                        return;
                    }
                    if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.left, .{}) or key.matches(vaxis.Key.right, .{})) {
                        self.confirm_choice = switch (self.confirm_choice) {
                            .accept => .cancel,
                            .cancel => .accept,
                        };
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (key.matches('y', .{}) or (self.confirm_choice == .accept and (key.matches(vaxis.Key.enter, .{}) or key.matches(' ', .{})))) {
                        self.acceptConfirm(ctx);
                        return;
                    }
                    if (key.matches('n', .{}) or key.matches(vaxis.Key.escape, .{}) or (self.confirm_choice == .cancel and (key.matches(vaxis.Key.enter, .{}) or key.matches(' ', .{})))) {
                        self.cancelConfirm(ctx);
                        return;
                    }
                    return;
                }

                if (self.show_profile_dialog) {
                    self.handleProfileDialogKey(ctx, key);
                    return;
                }

                if (self.show_invite_dialog) {
                    self.handleInviteDialogKey(ctx, key);
                    return;
                }

                // Help drawer absorbs all keys
                if (self.show_help) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('?', .{})) {
                        log.info("help_close", .{});
                        self.show_help = false;
                        ctx.consumeAndRedraw();
                    }
                    return;
                }

                if (self.workspace.show_drawer) {
                    workspace_panel.handleWorkspaceDrawerKey(self, ctx, key);
                    return;
                }

                // Create Workspace overlay absorbs all keys
                if (self.workspace.show_create) {
                    workspace_panel.handleCreateKey(self, ctx, key);
                    return;
                }

                // Comment editor absorbs all keys
                if (self.review.show_comment_editor) {
                    if (key.matches(vaxis.Key.escape, .{})) {
                        log.info("comment_editor_cancel", .{});
                        self.review.show_comment_editor = false;
                        self.review.comment_input_len = 0;
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        log.info("comment_editor_submit bytes={d}", .{self.review.comment_input_len});
                        if (self.review.comment_input_len > 0) {
                            self.submitComment();
                        } else {
                            self.notifyOp(.warning, "Empty comment discarded.");
                        }
                        self.review.show_comment_editor = false;
                        self.review.comment_input_len = 0;
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        log.info("comment_editor_backspace bytes={d}", .{self.review.comment_input_len});
                        if (self.review.comment_input_len > 0) {
                            self.review.comment_input_len -= 1;
                            ctx.consumeAndRedraw();
                        }
                    } else if (key.text) |text| {
                        log.info("comment_editor_text bytes={d}", .{text.len});
                        const remaining = self.review.comment_input_buf.len - self.review.comment_input_len;
                        if (text.len > 0 and text.len <= remaining) {
                            @memcpy(self.review.comment_input_buf[self.review.comment_input_len .. self.review.comment_input_len + text.len], text);
                            self.review.comment_input_len += text.len;
                            ctx.consumeAndRedraw();
                        }
                    }
                    return;
                }

                // PR Composer overlay absorbs all keys while open.
                if (self.drafts.show_pr_composer) {
                    self.handlePrComposerKey(ctx, key);
                    return;
                }

                // New-draft form absorbs all keys while open.
                if (self.drafts.show_new_draft_form) {
                    self.handleNewDraftFormKey(ctx, key);
                    return;
                }

                // Global quit
                if (key.matches('c', .{ .ctrl = true })) {
                    log.info("quit_direct", .{});
                    ctx.consumeEvent();
                    ctx.quit = true;
                    return;
                }
                if (key.matches('q', .{})) {
                    log.info("quit_prompt", .{});
                    self.confirm_message = "";
                    self.confirm_action = .quit;
                    self.show_confirm = true;
                    ctx.consumeAndRedraw();
                    return;
                }

                // Help toggle
                if (key.matches('?', .{})) {
                    log.info("help_open", .{});
                    self.show_help = true;
                    ctx.consumeAndRedraw();
                    return;
                }

                // Settings mode
                if (self.show_settings) {
                    settings_panel.handleEvent(self, ctx, key);
                    return;
                }

                // Settings toggle (S key)
                if (key.matches('S', .{})) {
                    log.info("settings_open", .{});
                    self.show_settings = true;
                    ctx.consumeAndRedraw();
                    return;
                }

                // Top-level tab switching
                if (key.matches('1', .{})) return self.selectTab(ctx, .dashboard);
                if (key.matches('2', .{})) return self.selectTab(ctx, .workspace);
                if (key.matches('3', .{})) return self.selectTab(ctx, .artifact);
                if (key.matches('4', .{})) return self.selectTab(ctx, .review);
                if (key.matches('5', .{})) return self.selectTab(ctx, .analysis);

                // Module-specific input
                switch (self.selected_module) {
                    .artifact => try artifact_panel.handleModuleEvent(self, ctx, event, key),
                    .review => try review_panel.handleModuleEvent(self, ctx, event, key),
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
                log.info("init", .{});
                self.refreshDraftsCache();
                // Start breathing animation
                try ctx.tick(100, self.widget());
            },
            .tick => {
                const was_login_panel = self.shouldShowLoginPanel();
                const was_native_cursor_input = self.hasNativeCursorInput();

                // Advance breathing cycle: 0→20→0 (2 seconds at 100ms intervals)
                self.tick_count +%= 1;
                self.analysis.breathing_phase = (self.analysis.breathing_phase + 1) % 21;
                self.system_notices.tick();

                // Drain completed results into caches BEFORE any
                // dispatch checks so that a result landing between
                // ticks doesn't trigger a redundant re-dispatch.
                _ = workspace_panel.consumeCreateResult(self);
                self.consumeUpdateWorkspaceResult();
                self.consumeDeleteWorkspaceResult();
                self.consumeRuleContentResult();
                self.consumeRulePrsResult();
                self.consumeReviewPrsResult();
                self.consumeWsContextContentResult();
                self.consumeWorkspaceContextResult();
                self.consumeWsManifestResult();
                self.consumeWorkspaceMembersResult();
                self.consumePrDetailResult();
                self.consumePrCommentsResult();
                self.consumeSignOutResult();
                if (self.quit_after_sign_out) {
                    ctx.quit = true;
                    return;
                }
                self.consumeSubmitCommentResult();
                self.consumePrActionResult();
                self.consumeCreateRulePrResult();
                self.consumeCreateContextPrResult();
                self.consumeUpdateProfileResult();
                self.consumeInviteMemberResult();
                self.consumeChangeMemberRoleResult();
                self.consumeRemoveMemberResult();
                self.consumeAddWorkspaceMemberResult();
                self.consumeChangeWorkspaceMemberRoleResult();
                self.consumeRemoveWorkspaceMemberResult();
                self.consumeAttestationUploadResult();
                self.consumeHealthResult();

                self.reconcileWorkspaceSelection();
                if ((self.selected_module == .dashboard or self.selected_module == .analysis) and (self.analysis.breathing_phase == 0 or self.analysis.breathing_phase == 10)) {
                    api.state.refreshLocalState(self.api_state);
                }
                if (!self.drafts.cache_seeded and self.activeWsId() != null) {
                    self.refreshDraftsCache();
                } else if (self.selected_module == .workspace) {
                    self.refreshDraftsCacheIfChanged();
                    self.ensureActiveWorkspaceDetailRequested();
                }
                self.maybeRefreshMetadata();
                const is_login_panel = self.shouldShowLoginPanel();
                const is_native_cursor_input = self.hasNativeCursorInput();
                ctx.redraw = !is_native_cursor_input or was_login_panel != is_login_panel or was_native_cursor_input != is_native_cursor_input;
                try ctx.tick(100, self.widget());
            },
            else => {},
        }
    }

    fn draw(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        _ = self.view_arena.reset(.retain_capacity);
        const size = self.sanitizeLayoutSize(ctx.max.size());
        if (size.width < 96 or size.height < 24) {
            return self.drawTooSmall(ctx, size);
        }

        var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&root, theme.PANEL);

        const header_band_h: u16 = 1;
        const header_h: u16 = 4;
        const footer_shortcuts = try self.footerShortcuts(ctx.arena);
        const footer_h = w.shortcutBarRows(ctx, footer_shortcuts, .{
            .row = 0,
            .col = 1,
            .max_col = size.width,
            .max_rows = 2,
        });
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

        const show_workspace_drawer = self.workspace.show_drawer and self.selected_module == .workspace and
            !self.show_settings and !self.show_help and !self.show_confirm and !self.review.show_comment_editor and
            !self.workspace.show_create and !self.drafts.show_pr_composer and !self.drafts.show_new_draft_form and
            !self.show_profile_dialog and !self.show_invite_dialog;
        const show_login_panel = self.shouldShowLoginPanel();
        const allow_regular_overlays = !show_login_panel;
        const modal_active = show_login_panel or self.show_help or self.show_confirm or self.review.show_comment_editor or
            self.workspace.show_create or self.drafts.show_pr_composer or
            self.drafts.show_new_draft_form or self.show_profile_dialog or self.show_invite_dialog or show_workspace_drawer;
        const show_notice_overlay = !modal_active and self.system_notices.hasVisible();
        var child_count: usize = 3;
        if (show_login_panel) child_count += 1;
        if (allow_regular_overlays and self.show_help) child_count += 1;
        if (allow_regular_overlays and self.show_confirm) child_count += 1;
        if (allow_regular_overlays and self.show_profile_dialog) child_count += 1;
        if (allow_regular_overlays and self.show_invite_dialog) child_count += 1;
        if (allow_regular_overlays and self.review.show_comment_editor) child_count += 1;
        if (allow_regular_overlays and self.workspace.show_create) child_count += 1;
        if (allow_regular_overlays and self.drafts.show_pr_composer) child_count += 1;
        if (allow_regular_overlays and self.drafts.show_new_draft_form) child_count += 1;
        if (allow_regular_overlays and show_workspace_drawer) child_count += 1;
        if (show_notice_overlay) child_count += 1;

        const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawHeader(header_ctx) };
        children[1] = .{ .origin = .{ .row = header_h, .col = 0 }, .surface = try self.drawBody(body_ctx) };
        children[2] = .{ .origin = .{ .row = header_h + body_h, .col = 0 }, .surface = try self.drawFooter(footer_ctx, footer_shortcuts) };
        var child_idx: usize = 3;

        if (show_login_panel) {
            const full_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[child_idx] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try self.drawLoginPanel(full_ctx),
            };
            child_idx += 1;
        }
        if (allow_regular_overlays and self.show_help) {
            const drawer_w: u16 = @min(HELP_DRAWER_WIDTH, size.width -| DRAWER_SIDE_MARGIN);
            const drawer_top: u16 = header_band_h;
            if (drawer_w >= w.Drawer.min_child_width and size.height > drawer_top) {
                const drawer_h: u16 = size.height - drawer_top;
                const help_ctx = ctx.withConstraints(
                    .{ .width = drawer_w, .height = drawer_h },
                    .{ .width = drawer_w, .height = drawer_h },
                );
                children[child_idx] = .{
                    .origin = .{ .row = drawer_top, .col = size.width - drawer_w },
                    .surface = try self.drawHelpDrawer(help_ctx),
                };
                child_idx += 1;
            } else {
                const help_ctx = ctx.withConstraints(
                    .{ .width = size.width, .height = size.height },
                    .{ .width = size.width, .height = size.height },
                );
                children[child_idx] = .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.drawHelpDrawer(help_ctx),
                };
                child_idx += 1;
            }
        }
        if (allow_regular_overlays and self.show_confirm) {
            const confirm_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[child_idx] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawConfirmOverlay(confirm_ctx) };
            child_idx += 1;
        }
        if (allow_regular_overlays and self.show_profile_dialog) {
            const full_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[child_idx] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try self.drawProfileDialog(full_ctx),
            };
            child_idx += 1;
        }
        if (allow_regular_overlays and self.show_invite_dialog) {
            const full_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[child_idx] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try self.drawInviteDialog(full_ctx),
            };
            child_idx += 1;
        }
        if (allow_regular_overlays and self.review.show_comment_editor) {
            const box_w = @min(size.width -| 4, @as(u16, 60));
            const box_h: u16 = 8;
            const full_ctx = ctx.withConstraints(
                .{ .width = box_w, .height = box_h },
                .{ .width = box_w, .height = box_h },
            );
            children[child_idx] = .{
                .origin = .{
                    .row = size.height -| box_h -| 1,
                    .col = size.width -| box_w -| 2,
                },
                .surface = try self.drawCommentEditorOverlay(full_ctx),
            };
            child_idx += 1;
        }
        if (allow_regular_overlays and self.workspace.show_create) {
            const full_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[child_idx] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try workspace_panel.drawCreateOverlay(self, full_ctx),
            };
            child_idx += 1;
        }
        if (allow_regular_overlays and self.drafts.show_pr_composer) {
            const full_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[child_idx] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try self.drawPrComposerOverlay(full_ctx),
            };
            child_idx += 1;
        }
        if (allow_regular_overlays and self.drafts.show_new_draft_form) {
            const full_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[child_idx] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try self.drawNewDraftFormOverlay(full_ctx),
            };
            child_idx += 1;
        }
        if (allow_regular_overlays and show_workspace_drawer) {
            const drawer_w: u16 = @min(WORKSPACE_DRAWER_WIDTH, size.width -| DRAWER_SIDE_MARGIN);
            const drawer_top: u16 = 1;
            if (drawer_w > 0 and size.height > drawer_top) {
                const drawer_h: u16 = size.height - drawer_top;
                const drawer_ctx = ctx.withConstraints(
                    .{ .width = drawer_w, .height = drawer_h },
                    .{ .width = drawer_w, .height = drawer_h },
                );
                children[child_idx] = .{
                    .origin = .{ .row = drawer_top, .col = size.width - drawer_w },
                    .surface = try workspace_panel.drawWorkspaceDrawer(self, drawer_ctx),
                };
                child_idx += 1;
            }
        }
        if (show_notice_overlay) {
            const notice_max_size = vxfw.Size{
                .width = size.width,
                .height = size.height - header_band_h - footer_h,
            };
            const notice_size = self.system_notices.overlaySize(ctx, notice_max_size);
            const notice_w = notice_size.width;
            const notice_h = notice_size.height;
            if (notice_w >= 24 and notice_h >= 3) {
                const notice_ctx = ctx.withConstraints(
                    .{ .width = notice_w, .height = notice_h },
                    .{ .width = notice_w, .height = notice_h },
                );
                children[child_idx] = .{
                    .origin = .{ .row = header_band_h, .col = size.width - notice_w -| 1 },
                    .surface = try self.system_notices.drawOverlay(self.widget(), notice_ctx),
                };
                child_idx += 1;
            }
        }

        root.children = children;
        return root;
    }

    fn sanitizeLayoutSize(self: *Shell, raw_size: vxfw.Size) vxfw.Size {
        const size = w.sanitizeSurfaceSize(raw_size);
        if (raw_size.width == 0 or raw_size.height == 0) {
            if (self.last_safe_layout_size.width > 0 and self.last_safe_layout_size.height > 0) {
                return self.last_safe_layout_size;
            }
            return .{ .width = 96, .height = 24 };
        }

        self.last_safe_layout_size = size;
        return size;
    }

    fn drawHeader(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        w.fillSurface(&surface, theme.PANEL_ALT);

        // Row 0: Accent band with org/user context
        w.paintBand(&surface, 0, theme.ACCENT, theme.PANEL);
        const org_name: []const u8 = blk: {
            self.api_state.mutex.lock();
            defer self.api_state.mutex.unlock();
            if (self.api_state.current_user) |u|
                break :blk u.org_name;
            break :blk "\xe2\x80\x94";
        };
        w.writeText(&surface, ctx, 1, 0, org_name, .{
            .fg = theme.PANEL,
            .bg = theme.ACCENT,
            .bold = true,
        });
        if (self.connectionHeaderNotice()) |notice| {
            w.writeRightText(&surface, ctx, 0, notice.text, w.systemNoticeHeaderStyle(notice.kind));
        }

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

    fn drawBody(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        if (self.show_settings) return settings_panel.drawSettings(self, ctx);
        return switch (self.selected_module) {
            .dashboard => self.drawDashboard(ctx),
            .artifact => self.drawArtifact(ctx),
            .review => self.drawReview(ctx),
            .workspace => self.drawWorkspaceStatus(ctx),
            .analysis => self.drawAnalysis(ctx),
        };
    }

    fn drawFooter(self: *Shell, ctx: vxfw.DrawContext, shortcuts: []const w.Shortcut) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        w.fillSurface(&surface, theme.PANEL);

        _ = w.drawShortcutBar(&surface, ctx, shortcuts, .{
            .row = 0,
            .col = 1,
            .max_col = surface.size.width,
            .max_rows = 2,
        });

        return surface;
    }

    fn footerShortcuts(self: *Shell, arena: std.mem.Allocator) std.mem.Allocator.Error![]const w.Shortcut {
        if (self.show_confirm or self.review.show_comment_editor or self.workspace.show_drawer) {
            return w.sortedShortcuts(arena, self.contextShortcuts());
        }
        return filteredFooterShortcuts(arena, self.contextShortcuts());
    }

    fn contextShortcuts(self: *Shell) []const w.Shortcut {
        if (self.show_confirm) return &.{
            .{ .key = "y", .label = "confirm" },
            .{ .key = "n", .label = "cancel" },
            .{ .key = "Esc", .label = "cancel" },
        };
        if (self.show_settings) return settings_panel.shortcuts(self);
        if (self.review.show_comment_editor) return &.{
            .{ .key = "Enter", .label = "send" },
            .{ .key = "Esc", .label = "cancel" },
        };
        if (self.workspace.show_drawer) return &.{
            .{ .key = "j/k", .label = "move" },
            .{ .key = "Enter", .label = "switch" },
            .{ .key = "w", .label = "close" },
            .{ .key = "Esc", .label = "close" },
        };
        if (self.shouldShowLoginPanel()) return &.{
            .{ .key = "Tab", .label = "next field" },
            .{ .key = "Enter", .label = "continue" },
            .{ .key = "Esc", .label = "quit" },
            .{ .key = "Ctrl+C", .label = "quit" },
        };

        return switch (self.selected_module) {
            .dashboard => dashboard_panel.shortcuts(self),
            .artifact => artifact_panel.shortcuts(self),
            .review => review_panel.shortcuts(self),
            .workspace => workspace_panel.shortcuts(self),
            .analysis => analysis_panel.shortcuts(self),
        };
    }

    fn filteredFooterShortcuts(
        arena: std.mem.Allocator,
        shortcuts: []const w.Shortcut,
    ) std.mem.Allocator.Error![]const w.Shortcut {
        var visible_count: usize = 0;
        var has_help = false;
        for (shortcuts) |shortcut| {
            if (std.mem.eql(u8, shortcut.key, "?")) {
                has_help = true;
                visible_count += 1;
            } else if (!isCommonShortcutKey(shortcut.key)) {
                visible_count += 1;
            }
        }
        if (!has_help) visible_count += 1;

        const out = try arena.alloc(w.Shortcut, visible_count);
        var idx: usize = 0;
        for (shortcuts) |shortcut| {
            if (std.mem.eql(u8, shortcut.key, "?") or !isCommonShortcutKey(shortcut.key)) {
                out[idx] = shortcut;
                idx += 1;
            }
        }
        if (!has_help) {
            out[idx] = .{ .key = "?", .label = "help" };
        }
        return w.sortedShortcuts(arena, out);
    }

    fn isCommonShortcutKey(key: []const u8) bool {
        return std.mem.eql(u8, key, "j/k") or
            std.mem.eql(u8, key, "h/l") or
            std.mem.eql(u8, key, "Enter") or
            std.mem.eql(u8, key, "Tab") or
            std.mem.eql(u8, key, "Esc") or
            std.mem.eql(u8, key, "q");
    }

    pub fn notifyOp(self: *Shell, kind: w.SystemNoticeKind, text: []const u8) void {
        self.system_notices.push(.operation, kind, .transient, text);
    }

    // Artifact: master-detail. Left panel carries a Files / Pull Requests
    // inner tab strip; right panel is a single detail surface that
    // follows whichever item the left panel has selected.
    fn drawArtifact(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        self.ensureDraftsCacheForActiveWorkspace();
        self.refreshDraftsCacheIfChanged();
        try artifact_panel.syncArtifactWidgets(self, ctx);

        const size = ctx.max.size();
        const list_w: u16 = size.width / 3;
        const rules = self.getRules();
        const create_paths = self.drafts.create_rule_paths;

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
            if (self.artifact.selected_rule < rules.len) break :blk &rules[self.artifact.selected_rule];
            const k = self.artifact.selected_rule - rules.len;
            if (k >= create_paths.len) break :blk null;
            if (self.draftLocalIdFor(.rule, create_paths[k]) == null) break :blk null;
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
        return artifact_panel.drawRoot(self, ctx, list_surface, detail_surface);
    }

    fn seedLoginDefaults(self: *Shell) void {
        const default_url = "http://127.0.0.1:8400";
        @memcpy(self.login_hub_url_buf[0..default_url.len], default_url);
        self.login_hub_url_len = default_url.len;
        self.login_focus = .username;
    }

    fn shouldShowLoginPanel(self: *const Shell) bool {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.current_user != null) return false;
        return switch (self.api_state.status) {
            .disconnected, .error_auth, .error_network => true,
            else => false,
        };
    }

    fn hasNativeCursorInput(self: *const Shell) bool {
        if (self.shouldShowLoginPanel()) return true;
        if (self.review.show_comment_editor) return true;
        if (self.show_profile_dialog and !self.profile_dialog_submitting) return true;
        if (self.show_invite_dialog and !self.invite_dialog_submitting) return true;
        if (self.drafts.show_new_draft_form) return true;
        if (self.drafts.show_pr_composer) return self.drafts.pr_composer_focus == .title or self.drafts.pr_composer_focus == .body;
        if (self.workspace.show_create) return self.workspace.create_focus == .name or self.workspace.create_focus == .description;
        return false;
    }

    fn handleLoginKey(self: *Shell, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.escape, .{})) {
            ctx.consumeEvent();
            ctx.quit = true;
            return;
        }
        if (key.matches(vaxis.Key.f2, .{})) {
            self.login_mode = if (self.login_mode == .sign_in) .activate else .sign_in;
            if (self.login_focus == .invite_token and self.login_mode == .sign_in) self.login_focus = .username;
            self.login_message = "";
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.login_focus = self.nextLoginFocus();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.login_focus == .password or self.login_focus == .submit) {
                self.submitLoginForm();
            } else {
                self.login_focus = self.nextLoginFocus();
            }
            ctx.consumeAndRedraw();
            return;
        }
        if (self.login_focus == .submit) {
            ctx.consumeEvent();
            return;
        }

        var input = switch (self.login_focus) {
            .hub_url => w.TextInput{ .buf = &self.login_hub_url_buf, .len = &self.login_hub_url_len },
            .username => w.TextInput{ .buf = &self.login_username_buf, .len = &self.login_username_len },
            .invite_token => w.TextInput{ .buf = &self.login_invite_token_buf, .len = &self.login_invite_token_len },
            .password => w.TextInput{ .buf = &self.login_password_buf, .len = &self.login_password_len },
            .submit => unreachable,
        };
        switch (input.handleKey(key)) {
            .consumed => {
                self.login_message = "";
                ctx.consumeAndRedraw();
            },
            .cancel => {
                self.login_password_len = 0;
                self.login_message = "";
                ctx.consumeAndRedraw();
            },
            else => ctx.consumeEvent(),
        }
    }

    fn submitLoginForm(self: *Shell) void {
        const hub_url_raw = self.login_hub_url_buf[0..self.login_hub_url_len];
        const username = self.login_username_buf[0..self.login_username_len];
        const password = self.login_password_buf[0..self.login_password_len];
        const invite_token = self.login_invite_token_buf[0..self.login_invite_token_len];
        if (hub_url_raw.len == 0 or username.len == 0 or password.len == 0 or (self.login_mode == .activate and invite_token.len == 0)) {
            self.login_message = if (self.login_mode == .activate) "Hub, user, invite token, and password are required." else "Hub URL, username, and password are required.";
            return;
        }

        const alloc = self.api_state.backing_allocator;
        const hub_url = normalizeLoginHubUrl(alloc, hub_url_raw) catch {
            self.login_message = "Hub URL must use http:// or https://.";
            return;
        };
        defer alloc.free(hub_url);

        const body = switch (self.login_mode) {
            .sign_in => blk: {
                const LoginBody = struct { username: []const u8, credential: []const u8 };
                break :blk std.json.Stringify.valueAlloc(alloc, LoginBody{
                    .username = username,
                    .credential = password,
                }, .{}) catch {
                    self.login_message = "Could not build login request.";
                    return;
                };
            },
            .activate => std.json.Stringify.valueAlloc(alloc, auth_api.ActivateRequest{
                .username = username,
                .invite_token = invite_token,
                .credential = password,
            }, .{}) catch {
                self.login_message = "Could not build login request.";
                return;
            },
        };
        const path = switch (self.login_mode) {
            .sign_in => "/api/auth/login",
            .activate => "/api/auth/activate",
        };
        if (body.len == 0) {
            self.login_message = "Could not build login request.";
            return;
        }
        defer alloc.free(body);

        api.state.setConnectionStatus(self.api_state, .connecting);
        var client = HubClient.init(alloc, hub_url, null);
        defer client.deinit();
        const response = client.post(path, body) catch {
            api.state.setConnectionStatus(self.api_state, .error_network);
            self.login_message = "Hub is unreachable. Check the URL and server.";
            return;
        };
        defer response.deinit();

        if (response.status == .unauthorized) {
            api.state.setConnectionStatus(self.api_state, .error_auth);
            self.login_message = if (self.login_mode == .activate) "Invite activation failed." else "Invalid credentials. Press F2 to activate an invite.";
            return;
        }
        if (response.status != .ok) {
            api.state.setConnectionStatus(self.api_state, .error_auth);
            self.login_message = "Login failed. Check Hub logs for details.";
            return;
        }

        const parsed = std.json.parseFromSlice(auth_api.LoginResponse, alloc, response.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            api.state.setConnectionStatus(self.api_state, .error_auth);
            self.login_message = "Hub returned an invalid login response.";
            return;
        };
        defer parsed.deinit();

        _ = auth_mod.saveAuth(alloc, hub_url, username, parsed.value.access_token, parsed.value.refresh_token) catch {};
        api.fetch.startFetch(self.api_state, hub_url, username, parsed.value.access_token, parsed.value.refresh_token) catch {
            api.state.setConnectionStatus(self.api_state, .error_network);
            self.login_message = "Logged in, but startup fetch failed.";
            return;
        };
        tasks.attestation_upload.start(self.api_state) catch {};
        const completed_mode = self.login_mode;
        @memset(&self.login_password_buf, 0);
        @memset(&self.login_invite_token_buf, 0);
        self.login_password_len = 0;
        self.login_invite_token_len = 0;
        self.login_mode = .sign_in;
        self.login_message = "";
        self.notifyOp(.success, if (completed_mode == .activate) "Invite activated." else "Signed in.");
    }

    fn drawLoginPanel(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const box_w: u16 = @min(@as(u16, 58), size.width -| 6);
        const box_h: u16 = if (self.login_mode == .activate) 17 else 15;
        const modal = Modal{
            .title = "Connect to Clumsies Hub",
            .box_width = box_w,
            .box_height = box_h,
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;

        const col = result.content_col;
        const field_start = result.content_row;
        const switch_label = if (self.login_mode == .activate) "F2 sign in" else "F2 activate invite";
        const switch_w: u16 = @intCast(@min(ctx.stringWidth(switch_label), result.content_width));
        w.writeText(&surface, ctx, col + result.content_width -| switch_w, field_start -| 2, switch_label, theme.textOn(theme.PANEL_ALT, theme.MUTED));
        self.drawLoginField(&surface, ctx, col, field_start, result.content_width, "Hub", self.login_hub_url_buf[0..self.login_hub_url_len], .hub_url);
        self.drawLoginField(&surface, ctx, col, field_start + 2, result.content_width, "User", self.login_username_buf[0..self.login_username_len], .username);
        var password_row = field_start + 4;
        if (self.login_mode == .activate) {
            self.drawLoginField(&surface, ctx, col, field_start + 4, result.content_width, "Token", self.login_invite_token_buf[0..self.login_invite_token_len], .invite_token);
            password_row = field_start + 6;
        }
        const password_mask = try ctx.arena.alloc(u8, self.login_password_len);
        @memset(password_mask, '*');
        const password_label = if (self.login_mode == .activate) "New Pass" else "Pass";
        self.drawLoginField(&surface, ctx, col, password_row, result.content_width, password_label, password_mask, .password);

        self.drawLoginSubmit(&surface, ctx, col, password_row + 2);
        if (self.login_message.len > 0) {
            const message_row = password_row + 4;
            if (message_row + 1 < surface.size.height) {
                const max_rows: u16 = @min(2, surface.size.height - message_row - 1);
                _ = w.writeWrappedTextMax(&surface, ctx, col, message_row, result.content_width, max_rows, self.login_message, theme.textOn(theme.PANEL_ALT, theme.DANGER));
            }
        }
        return surface;
    }

    fn drawLoginField(
        self: *Shell,
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        col: u16,
        row: u16,
        content_width: u16,
        label: []const u8,
        value: []const u8,
        focus: LoginFocus,
    ) void {
        const active = self.login_focus == focus;
        const field_col = col + 11;
        const field_w = content_width -| 12;
        w.writeText(surface, ctx, col, row, " ", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        w.writeText(surface, ctx, col + 2, row, label, theme.textOn(theme.PANEL_ALT, if (active) theme.TEXT_SOFT else theme.MUTED));
        const value_w = field_w -| 1;
        w.drawTextInputSlot(surface, ctx, field_col, row, value_w, value, theme.TEXT, active);
    }

    fn drawLoginSubmit(self: *Shell, surface: *vxfw.Surface, ctx: vxfw.DrawContext, col: u16, row: u16) void {
        const active = self.login_focus == .submit;
        const fg = if (active) theme.TEXT else theme.TEXT_SOFT;
        w.writeText(surface, ctx, col, row, " ", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        const label = if (self.login_mode == .activate) "[ Activate ]" else "[ Sign in ]";
        w.writeText(surface, ctx, col + 11, row, label, .{ .fg = fg, .bg = theme.PANEL_ALT, .bold = active });
    }

    pub fn canManageMembers(self: *Shell) bool {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const user = self.api_state.current_user orelse return false;
        return std.mem.eql(u8, user.role, "maintainer") and std.mem.indexOf(u8, user.scopes, "members:write") != null;
    }

    pub fn ensureMemberManagementAllowed(self: *Shell) bool {
        if (self.canManageMembers()) return true;
        self.notifyOp(.warning, "Maintainer role required.");
        return false;
    }

    pub fn canManageSelectedWorkspaceMembers(self: *Shell) bool {
        const workspace = self.selectedSettingsWorkspace() orelse return false;
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const user = self.api_state.current_user orelse return false;
        if (std.mem.indexOf(u8, user.scopes, "members:write") == null) return false;
        return std.mem.eql(u8, user.role, "maintainer") or std.mem.eql(u8, workspace.role, "admin");
    }

    pub fn ensureWorkspaceMemberManagementAllowed(self: *Shell) bool {
        if (self.canManageSelectedWorkspaceMembers()) return true;
        self.notifyOp(.warning, "Workspace admin role required.");
        return false;
    }

    pub fn canRemoveSelectedWorkspaceMember(self: *Shell) bool {
        const workspace = self.selectedSettingsWorkspace() orelse return false;
        const member = self.selectedWorkspaceMember() orelse return false;
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const user = self.api_state.current_user orelse return false;
        if (std.mem.indexOf(u8, user.scopes, "members:write") == null) return false;
        if (std.mem.eql(u8, member.user_id, user.user_id)) return true;
        return std.mem.eql(u8, user.role, "maintainer") or std.mem.eql(u8, workspace.role, "admin");
    }

    pub fn ensureWorkspaceMemberRemovalAllowed(self: *Shell) bool {
        if (self.canRemoveSelectedWorkspaceMember()) return true;
        self.notifyOp(.warning, "Workspace admin role required.");
        return false;
    }

    fn nextLoginFocus(self: *const Shell) LoginFocus {
        return switch (self.login_focus) {
            .hub_url => .username,
            .username => if (self.login_mode == .activate) .invite_token else .password,
            .invite_token => .password,
            .password => .submit,
            .submit => .hub_url,
        };
    }

    fn normalizeLoginHubUrl(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidHubUrl;
        const with_scheme = if (std.mem.indexOf(u8, trimmed, "://") == null)
            try std.fmt.allocPrint(allocator, "http://{s}", .{trimmed})
        else
            try allocator.dupe(u8, trimmed);
        errdefer allocator.free(with_scheme);
        if (!std.mem.startsWith(u8, with_scheme, "http://") and !std.mem.startsWith(u8, with_scheme, "https://")) {
            return error.UnsupportedHubUrlScheme;
        }
        const normalized = std.mem.trimRight(u8, with_scheme, "/");
        if (normalized.len == with_scheme.len) return with_scheme;
        const copy = try allocator.dupe(u8, normalized);
        allocator.free(with_scheme);
        return copy;
    }

    fn drawReview(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        self.ensureReviewPrsRequested();
        return review_panel.drawRoot(self, ctx);
    }

    fn drawListPanel(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        return artifact_panel.drawListPanel(self, ctx);
    }

    // Workspace: master-detail content with a command drawer for switching
    // workspaces. Tab cycles focus between list and content.
    fn drawWorkspaceStatus(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        self.ensureActiveWorkspaceDetailRequested();
        self.ensureDraftsCacheForActiveWorkspace();
        self.refreshDraftsCacheIfChanged();
        const size = ctx.max.size();
        const list_w: u16 = size.width / 3;
        const detail_w: u16 = size.width - list_w - 1;
        const list_ctx = ctx.withConstraints(.{ .width = list_w, .height = size.height }, .{ .width = list_w, .height = size.height });
        const detail_ctx = ctx.withConstraints(.{ .width = detail_w, .height = size.height }, .{ .width = detail_w, .height = size.height });
        const list_surface = try self.drawWsList(list_ctx);
        const detail_surface = try self.drawWsDetail(detail_ctx);
        return workspace_panel.drawStatus(self, ctx, list_surface, detail_surface);
    }

    fn drawWsList(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        workspace_panel.syncWsRows(self);
        const live_ws = if (self.activeWsId()) |ws_id|
            self.workspaceDetailForView(ws_id)
        else
            null;
        return workspace_panel.drawList(self, ctx, self.currentWsTree(), live_ws);
    }

    /// ws_id of the currently-selected workspace, or null when the
    /// workspace list is empty / not loaded yet. Reads ws_id directly
    /// off the authoritative `current_user.workspaces` list because
    /// the view-layer `WorkspaceEntry` intentionally omits it.
    pub fn activeWsId(self: *Shell) ?[]const u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const user = self.api_state.current_user orelse return null;
        if (user.workspaces.len == 0) return null;
        const idx = @min(self.workspace.sel, user.workspaces.len - 1);
        return user.workspaces[idx].ws_id;
    }

    pub fn activeWorkspaceName(self: *Shell) []const u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const user = self.api_state.current_user orelse return "No workspace";
        if (user.workspaces.len == 0) return "No workspace";
        const idx = @min(self.workspace.sel, user.workspaces.len - 1);
        return user.workspaces[idx].name;
    }

    fn selectedSettingsWorkspaceId(self: *Shell) ?[]const u8 {
        if (!self.show_settings or self.settings.tab != .workspaces) return null;
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const user = self.api_state.current_user orelse return null;
        if (user.workspaces.len == 0) return null;
        const idx = @min(self.settings.content_sel, user.workspaces.len - 1);
        return user.workspaces[idx].ws_id;
    }

    fn reconcileWorkspaceSelection(self: *Shell) void {
        var next_idx: ?usize = null;
        self.api_state.mutex.lock();
        if (self.api_state.current_user) |user| {
            if (user.workspaces.len == 0) {
                self.workspace.sel = 0;
                self.workspace_pref_applied = true;
            } else if (!self.workspace_pref_applied) {
                next_idx = tui_prefs.selectWorkspaceIndex(user.workspaces, self.last_workspace_id);
            } else if (self.workspace.sel >= user.workspaces.len) {
                next_idx = 0;
            }
        }
        self.api_state.mutex.unlock();

        if (next_idx) |idx| {
            self.workspace_pref_applied = true;
            self.selectWorkspaceIndex(idx);
        }
    }

    fn rememberWorkspaceId(self: *Shell, ws_id: []const u8) void {
        if (self.last_workspace_id) |old| {
            if (std.mem.eql(u8, old, ws_id)) {
                tui_prefs.saveLastWorkspaceId(self.api_state.backing_allocator, ws_id) catch {};
                return;
            }
            self.api_state.backing_allocator.free(old);
        }
        self.last_workspace_id = self.api_state.backing_allocator.dupe(u8, ws_id) catch null;
        tui_prefs.saveLastWorkspaceId(self.api_state.backing_allocator, ws_id) catch {};
    }

    pub fn resetLocalWorkspaceDetail(self: *Shell) void {
        _ = self.workspace.local_arena.reset(.retain_capacity);
        self.workspace.local_cache_id = null;
        self.workspace.local_detail = null;
        self.workspace.local_load_failed = false;
    }

    fn ensureLocalWorkspaceDetail(self: *Shell, ws_id: []const u8) void {
        if (self.workspace.local_cache_id) |cached| {
            if (std.mem.eql(u8, cached, ws_id)) return;
        }
        self.resetLocalWorkspaceDetail();

        const arena = self.workspace.local_arena.allocator();
        const ws_id_copy = arena.dupe(u8, ws_id) catch {
            self.workspace.local_load_failed = true;
            return;
        };
        self.workspace.local_cache_id = ws_id_copy;

        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch {
            self.workspace.local_load_failed = true;
            return;
        };
        var manifest = workspace_rule.loadManifest(arena, ws_dir) catch {
            self.workspace.local_load_failed = true;
            return;
        };
        defer manifest.deinit(arena);

        const workspace_context = arena.alloc(api.model.WorkspaceContextData, manifest.context.count()) catch {
            self.workspace.local_load_failed = true;
            return;
        };
        var context_i: usize = 0;
        var context_it = manifest.context.iterator();
        while (context_it.next()) |entry| {
            workspace_context[context_i] = .{
                .context_id = arena.dupe(u8, entry.key_ptr.*) catch "",
                .path = arena.dupe(u8, entry.value_ptr.path) catch "",
                .hash = arena.dupe(u8, entry.value_ptr.hash) catch "",
                .size = 0,
                .author = "local",
                .updated_at = "",
            };
            context_i += 1;
        }

        const workspace_rules = arena.alloc(api.model.WorkspaceRuleData, manifest.rules.count()) catch {
            self.workspace.local_load_failed = true;
            return;
        };
        var rule_i: usize = 0;
        var rule_it = manifest.rules.iterator();
        while (rule_it.next()) |entry| {
            workspace_rules[rule_i] = .{
                .rule_id = arena.dupe(u8, entry.key_ptr.*) catch "",
                .content_hash = arena.dupe(u8, entry.value_ptr.hash) catch "",
                .path = arena.dupe(u8, entry.value_ptr.path) catch "",
            };
            rule_i += 1;
        }

        self.workspace.local_detail = .{
            .ws_id = ws_id_copy,
            .workspace_context = workspace_context[0..context_i],
            .workspace_rules = workspace_rules[0..rule_i],
        };
    }

    pub fn workspaceDetailForView(self: *Shell, ws_id: []const u8) ?api.model.WorkspaceDetail {
        self.ensureLocalWorkspaceDetail(ws_id);
        const local = self.workspace.local_detail;
        const remote_context = self.api_state.workspace_context_cache.lookup(.{ .value = ws_id });
        const remote_rules = self.api_state.workspace_manifest_cache.lookup(.{ .value = ws_id });
        const local_context = if (local) |l| l.workspace_context else null;
        const local_rules = if (local) |l| l.workspace_rules else null;
        const workspace_context = self.mergeWorkspaceContextForView(local_context, remote_context) orelse &.{};
        const workspace_rules = self.mergeWorkspaceRulesForView(local_rules, remote_rules) orelse &.{};

        if (workspace_context.len == 0 and workspace_rules.len == 0 and local == null and remote_context == null and remote_rules == null) return null;
        return .{
            .ws_id = ws_id,
            .workspace_context = workspace_context,
            .workspace_rules = workspace_rules,
        };
    }

    fn mergeWorkspaceContextForView(
        self: *Shell,
        local: ?[]const api.model.WorkspaceContextData,
        remote: ?[]const api.model.WorkspaceContextData,
    ) ?[]const api.model.WorkspaceContextData {
        _ = self;
        return remote orelse local;
    }

    fn mergeWorkspaceRulesForView(
        self: *Shell,
        local: ?[]const api.model.WorkspaceRuleData,
        remote: ?[]const api.model.WorkspaceRuleData,
    ) ?[]const api.model.WorkspaceRuleData {
        _ = self;
        return remote orelse local;
    }

    fn hasLocalWorkspaceDetail(self: *Shell, ws_id: []const u8) bool {
        self.ensureLocalWorkspaceDetail(ws_id);
        const local = self.workspace.local_detail orelse return false;
        return local.workspace_context.len > 0 or local.workspace_rules.len > 0;
    }

    pub fn ensureActiveWorkspaceDetailRequested(self: *Shell) void {
        const ws_id = self.activeWsId() orelse return;
        log.info("ensureActiveWorkspaceDetailRequested module={s}", .{moduleName(self.selected_module)});
        self.ensureLocalWorkspaceDetail(ws_id);
        workspace_panel.requestWorkspaceDetail(self, ws_id);
    }

    pub fn selectWorkspaceIndex(self: *Shell, idx: usize) void {
        var selected_ws_id: ?[]const u8 = null;
        self.api_state.mutex.lock();
        if (self.api_state.current_user) |user| {
            if (user.workspaces.len > 0) {
                const next = @min(idx, user.workspaces.len - 1);
                self.workspace.sel = next;
                selected_ws_id = user.workspaces[next].ws_id;
            } else {
                self.workspace.sel = 0;
            }
        } else {
            self.workspace.sel = 0;
        }
        self.api_state.mutex.unlock();

        self.workspace.list_sel = 0;
        self.workspace.hide_diff = false;
        self.resetWorkspaceTrees();
        self.workspace.list_scroll_bars.scroll_view.cursor = 0;
        self.workspace.list_scroll_bars.scroll_view.scroll.top = 0;
        self.workspace.list_scroll_bars.scroll_view.scroll.vertical_offset = 0;
        self.workspace.list_scroll_bars.scroll_view.scroll.left = 0;
        self.resetLocalWorkspaceDetail();
        self.ensureDraftsCacheForActiveWorkspace();
        if (selected_ws_id) |ws_id| {
            self.rememberWorkspaceId(ws_id);
            self.ensureLocalWorkspaceDetail(ws_id);
            if (self.selected_module == .workspace) {
                workspace_panel.requestWorkspaceDetail(self, ws_id);
            }
        }
    }

    pub fn openCreateWorkspace(self: *Shell) void {
        workspace_panel.openCreate(self);
    }

    pub fn openRenameWorkspace(self: *Shell) void {
        const workspace = self.selectedSettingsWorkspace() orelse {
            self.notifyOp(.warning, "No workspace selected.");
            return;
        };
        workspace_panel.openEdit(self, workspace.ws_id, workspace.name, workspace.description);
    }

    pub fn openWorkspaceDeleteConfirm(self: *Shell) void {
        const workspace = self.selectedSettingsWorkspace() orelse {
            self.notifyOp(.warning, "No workspace selected.");
            return;
        };
        self.confirm_message = std.fmt.allocPrint(self.viewAllocator(), "Delete {s}.", .{workspace.name}) catch "Delete selected workspace.";
        self.confirm_action = .delete_workspace;
        self.confirm_choice = .accept;
        self.show_confirm = true;
    }

    pub fn bindCurrentDirectoryToSelectedWorkspace(self: *Shell) void {
        const workspace = self.selectedSettingsWorkspace() orelse {
            self.notifyOp(.warning, "No workspace selected.");
            return;
        };
        const alloc = self.api_state.backing_allocator;
        const cwd = std.fs.cwd().realpathAlloc(alloc, ".") catch {
            self.notifyOp(.failure, "Could not resolve current directory.");
            return;
        };
        defer alloc.free(cwd);

        self.confirm_message = std.fmt.allocPrint(
            self.viewAllocator(),
            "Bind {s} to {s}.",
            .{ workspace.name, cwd },
        ) catch "Bind current directory.";
        self.confirm_error_message = "";
        self.confirm_submitting = false;
        self.confirm_action = .bind_current_directory;
        self.confirm_choice = .accept;
        self.show_confirm = true;
    }

    fn commitBindCurrentDirectoryToSelectedWorkspace(self: *Shell) bool {
        const workspace = self.selectedSettingsWorkspace() orelse {
            self.confirm_error_message = "No workspace selected.";
            return false;
        };
        const alloc = self.api_state.backing_allocator;

        const cwd = std.fs.cwd().realpathAlloc(alloc, ".") catch {
            self.confirm_error_message = "Could not resolve current directory.";
            return false;
        };
        defer alloc.free(cwd);

        var hub_url_copy: ?[]const u8 = null;
        self.api_state.mutex.lock();
        if (self.api_state.hub_url) |hub_url| {
            hub_url_copy = alloc.dupe(u8, hub_url) catch null;
        }
        self.api_state.mutex.unlock();
        const hub_url = hub_url_copy orelse {
            self.confirm_error_message = "Hub URL is not loaded.";
            return false;
        };
        defer alloc.free(hub_url);

        workspace_config.addWorkspace(alloc, hub_url, workspace.name, workspace.ws_id, cwd) catch {
            self.confirm_error_message = "Could not bind current directory.";
            return false;
        };
        self.api_state.workspace_paths_cache.invalidate();
        self.notifyOp(.success, "Current directory bound.");
        return true;
    }

    const SettingsWorkspaceSelection = struct {
        ws_id: []const u8,
        name: []const u8,
        description: []const u8,
        role: []const u8,
    };

    fn selectedSettingsWorkspace(self: *Shell) ?SettingsWorkspaceSelection {
        if (!self.show_settings or self.settings.tab != .workspaces) return null;
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const user = self.api_state.current_user orelse return null;
        if (user.workspaces.len == 0) return null;
        const idx = @min(self.settings.content_sel, user.workspaces.len - 1);
        const ws = user.workspaces[idx];
        return .{ .ws_id = ws.ws_id, .name = ws.name, .description = ws.description, .role = ws.role };
    }

    fn maybeRefreshMetadata(self: *Shell) void {
        if (self.tick_count > 0 and self.tick_count % GLOBAL_METADATA_REFRESH_TICKS == 0) {
            if (self.selected_module == .review) {
                api.state.invalidateRemoteCaches(self.api_state, .pr_lists);
            } else {
                self.invalidateRemoteDetailRequests();
            }
            api.fetch.refetchAllAsync(self.api_state);
        }
        if (self.tick_count > 0 and self.tick_count % HEALTH_CHECK_TICKS == 0) {
            api.specs.dispatchHealthCheck(self.api_state);
        }
        if (self.tick_count > 0 and self.tick_count % ATTESTATION_UPLOAD_TICKS == 0) {
            tasks.attestation_upload.start(self.api_state) catch |err| {
                log.warn("attestation_upload_start_failed error={s}", .{@errorName(err)});
            };
        }
        if (self.selected_module == .review and self.tick_count > 0 and self.tick_count % WORKSPACE_METADATA_REFRESH_TICKS == 0) {
            api.state.invalidateRemoteCaches(self.api_state, .pr_lists);
            self.ensureReviewPrsRequested();
        }
        if (self.selected_module == .workspace and self.tick_count > 0 and self.tick_count % WORKSPACE_METADATA_REFRESH_TICKS == 0) {
            const ws_id = self.activeWsId() orelse return;
            api.state.invalidateRemoteCaches(self.api_state, .workspace_detail);
            workspace_panel.refreshWorkspaceDetail(self, ws_id);
        }
    }

    pub fn resetWorkspaceTrees(self: *Shell) void {
        const allocator = self.api_state.allocator();
        self.workspace.context_tree.reset(allocator);
        self.workspace.rules_tree.reset(allocator);
        self.workspace.list_sel = 0;
    }

    fn currentWsDirSelection(self: *Shell) ?[]const u8 {
        return self.currentWsTree().dirPathAt(self.workspace.list_sel);
    }

    pub const WorkspaceFileSelection = union(enum) {
        context: struct {
            path: []const u8,
            context_id: ?[]const u8 = null,
            idx: ?usize = null,
            hash: ?[]const u8 = null,
            is_create_draft: bool = false,
        },
        rule: struct {
            path: []const u8,
            rule_id: ?[]const u8 = null,
            idx: ?usize = null,
            hash: ?[]const u8 = null,
            category: drafts_mod.DraftCategory,
            is_create_draft: bool = false,
        },

        pub fn draftCategory(self: WorkspaceFileSelection) drafts_mod.DraftCategory {
            return switch (self) {
                .context => .context,
                .rule => |r| r.category,
            };
        }

        pub fn path(self: WorkspaceFileSelection) []const u8 {
            return switch (self) {
                .context => |c| c.path,
                .rule => |r| r.path,
            };
        }
    };

    const PullDelta = union(enum) {
        none,
        upsert_context: api.model.WorkspaceContextData,
        upsert_rule: api.model.WorkspaceRuleData,
        remove_context: api.model.WorkspaceContextData,
        remove_rule: api.model.WorkspaceRuleData,
    };

    pub fn workspaceSelectionHasPullAvailable(self: *Shell, selection: WorkspaceFileSelection) bool {
        return switch (self.workspaceSelectionPullDelta(selection)) {
            .none => false,
            else => true,
        };
    }

    pub fn workspaceSelectionPullLabel(
        self: *Shell,
        arena: std.mem.Allocator,
        selection: WorkspaceFileSelection,
    ) std.mem.Allocator.Error!?[]const u8 {
        const op = switch (self.workspaceSelectionPullDelta(selection)) {
            .none => return null,
            .upsert_context => |remote| blk: {
                const local = self.localContextEntryFor(remote.path, remote.context_id) orelse break :blk "create";
                if (!std.mem.eql(u8, local.path, remote.path)) break :blk "rename";
                break :blk "update";
            },
            .upsert_rule => |remote| blk: {
                const remote_path = self.pathForWorkspaceRule(remote);
                const local = self.localRuleEntryFor(remote_path, remote.rule_id) orelse break :blk "create";
                if (!std.mem.eql(u8, local.path, remote_path)) break :blk "rename";
                break :blk "update";
            },
            .remove_context, .remove_rule => "delete",
        };
        const label = try std.fmt.allocPrint(arena, "pull available [op:{s}]", .{op});
        return label;
    }

    pub fn artifactRuleHasPullAvailable(self: *Shell, rule: *const data.RuleEntry) bool {
        if (rule.content_hash.len == 0) return false;
        const ws_id = self.activeWsId() orelse return false;
        self.ensureLocalWorkspaceDetail(ws_id);
        const rule_id = self.lookupRuleId(rule.path);
        const local = self.localRuleEntryFor(rule.path, rule_id) orelse return true;
        if (!std.mem.eql(u8, local.path, rule.path)) return true;
        return !local_content.hashesEqual(local.content_hash, rule.content_hash);
    }

    fn workspaceSelectionPullDelta(self: *Shell, selection: WorkspaceFileSelection) PullDelta {
        const ws_id = self.activeWsId() orelse return .none;
        self.ensureLocalWorkspaceDetail(ws_id);
        switch (selection) {
            .context => |context| {
                if (context.is_create_draft) return .none;
                const remote_items = self.api_state.workspace_context_cache.lookup(.{ .value = ws_id }) orelse return .none;
                const remote = findContextByPath(remote_items, context.path);
                const local = self.localContextEntryFor(context.path, context.context_id);
                if (remote) |remote_item| {
                    const local_item = local orelse return .{ .upsert_context = remote_item };
                    if (local_content.hashesEqual(local_item.hash, remote_item.hash)) return .none;
                    return .{ .upsert_context = remote_item };
                }
                if (local) |local_item| return .{ .remove_context = local_item };
                return .none;
            },
            .rule => |rule| {
                if (rule.is_create_draft) return .none;
                const remote_items = self.api_state.workspace_manifest_cache.lookup(.{ .value = ws_id }) orelse return .none;
                const remote = self.findRuleFor(remote_items, rule.path, rule.rule_id);
                const local = self.localRuleEntryFor(rule.path, rule.rule_id);
                if (remote) |remote_item| {
                    const remote_path = self.pathForWorkspaceRule(remote_item);
                    const local_item = local orelse return .{ .upsert_rule = remote_item };
                    if (std.mem.eql(u8, local_item.path, remote_path) and
                        local_content.hashesEqual(local_item.content_hash, remote_item.content_hash))
                    {
                        return .none;
                    }
                    return .{ .upsert_rule = remote_item };
                }
                if (local) |local_item| return .{ .remove_rule = local_item };
                return .none;
            },
        }
    }

    fn findContextByPath(items: []const api.model.WorkspaceContextData, path: []const u8) ?api.model.WorkspaceContextData {
        for (items) |item| {
            if (std.mem.eql(u8, item.path, path)) return item;
        }
        return null;
    }

    fn localContextEntryFor(
        self: *Shell,
        path: []const u8,
        context_id: ?[]const u8,
    ) ?api.model.WorkspaceContextData {
        const local = self.workspace.local_detail orelse return null;
        for (local.workspace_context) |item| {
            if (context_id) |id| {
                if (item.context_id.len > 0 and std.mem.eql(u8, item.context_id, id)) return item;
            }
            if (std.mem.eql(u8, item.path, path)) return item;
        }
        return null;
    }

    pub fn workspaceLocalContextPathForView(
        self: *Shell,
        path: []const u8,
        context_id: ?[]const u8,
    ) ?[]const u8 {
        const local = self.localContextEntryFor(path, context_id) orelse return null;
        return local.path;
    }

    fn findRuleFor(
        self: *Shell,
        items: []const api.model.WorkspaceRuleData,
        path: []const u8,
        rule_id: ?[]const u8,
    ) ?api.model.WorkspaceRuleData {
        for (items) |item| {
            if (rule_id) |id| {
                if (item.rule_id.len > 0 and std.mem.eql(u8, item.rule_id, id)) return item;
            }
            if (std.mem.eql(u8, self.pathForWorkspaceRule(item), path)) return item;
        }
        return null;
    }

    fn localRuleEntryFor(
        self: *Shell,
        path: []const u8,
        rule_id: ?[]const u8,
    ) ?api.model.WorkspaceRuleData {
        const local = self.workspace.local_detail orelse return null;
        return self.findRuleFor(local.workspace_rules, path, rule_id);
    }

    pub fn workspaceLocalRulePathForView(
        self: *Shell,
        path: []const u8,
        rule_id: ?[]const u8,
    ) ?[]const u8 {
        const local = self.localRuleEntryFor(path, rule_id) orelse return null;
        return local.path;
    }

    pub fn remoteWorkspaceContextBody(self: *Shell, ws_id: []const u8, path: []const u8) ?[]const u8 {
        if (self.api_state.workspace_context_content_cache.lookup(.{ .ws_id = ws_id, .path = path })) |body| {
            return body;
        }
        return null;
    }

    pub fn remoteWorkspaceContextBodyForHash(
        self: *Shell,
        ws_id: []const u8,
        path: []const u8,
        remote_hash: []const u8,
    ) ?[]const u8 {
        const body = self.remoteWorkspaceContextBody(ws_id, path) orelse return null;
        const body_hash = util_hash.contentHash(body);
        if (!local_content.hashesEqual(body_hash[0..], remote_hash)) return null;
        return body;
    }

    pub fn localWorkspaceContextBody(self: *Shell, ws_id: []const u8, path: []const u8) ?[]const u8 {
        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return null;
        return workspace_rule.readContextCacheFile(arena, ws_dir, path) catch null;
    }

    pub fn cachedWorkspaceContextBody(self: *Shell, ws_id: []const u8, path: []const u8) ?[]const u8 {
        return self.remoteWorkspaceContextBody(ws_id, path) orelse self.localWorkspaceContextBody(ws_id, path);
    }

    pub fn workspaceFileAtRow(
        self: *Shell,
        row: usize,
        live_ws: ?api.model.WorkspaceDetail,
    ) ?WorkspaceFileSelection {
        const ws_tree = self.currentWsTree();
        if (ws_tree.dirPathAt(row) != null) return null;
        const leaf = ws_tree.leafIndexAt(row) orelse return null;
        switch (self.workspace.tab) {
            .context => {
                const context_count = if (live_ws) |ws_d| ws_d.workspace_context.len else 0;
                if (live_ws) |ws_d| if (leaf < ws_d.workspace_context.len) {
                    const file = ws_d.workspace_context[leaf];
                    return .{ .context = .{
                        .path = file.path,
                        .context_id = file.context_id,
                        .idx = leaf,
                        .hash = file.hash,
                    } };
                };
                if (leaf < context_count) return null;
                const k = leaf - context_count;
                if (k >= self.drafts.create_context_paths.len) return null;
                if (self.draftLocalIdFor(.context, self.drafts.create_context_paths[k]) == null) return null;
                return .{ .context = .{
                    .path = self.drafts.create_context_paths[k],
                    .is_create_draft = true,
                } };
            },
            .rules => {
                const rule_count = if (live_ws) |ws_d| ws_d.workspace_rules.len else 0;
                if (live_ws) |ws_d| if (leaf < ws_d.workspace_rules.len) {
                    const wp = ws_d.workspace_rules[leaf];
                    const path = self.pathForWorkspaceRule(wp);
                    return .{ .rule = .{
                        .path = path,
                        .rule_id = wp.rule_id,
                        .idx = leaf,
                        .hash = wp.content_hash,
                        .category = self.artifactCategoryForPath(path),
                    } };
                };
                if (leaf < rule_count) return null;
                const k = leaf - rule_count;
                if (k >= self.drafts.create_rule_paths.len) return null;
                const path = self.drafts.create_rule_paths[k];
                if (self.draftLocalIdFor(self.artifactCategoryForPath(path), path) == null) return null;
                return .{ .rule = .{
                    .path = path,
                    .category = self.artifactCategoryForPath(path),
                    .is_create_draft = true,
                } };
            },
        }
    }

    pub fn currentWorkspaceFileSelection(
        self: *Shell,
        live_ws: ?api.model.WorkspaceDetail,
    ) ?WorkspaceFileSelection {
        return self.workspaceFileAtRow(self.workspace.list_sel, live_ws);
    }

    pub fn pathForWorkspaceRule(self: *Shell, wp: api.model.WorkspaceRuleData) []const u8 {
        if (wp.path.len > 0) return wp.path;
        for (self.getRules()) |lp| {
            if (std.mem.eql(u8, lp.content_hash, wp.content_hash)) return lp.path;
        }
        return wp.rule_id;
    }

    pub fn remoteRuleBody(self: *Shell, path: []const u8) ?[]const u8 {
        if (self.api_state.rule_content_cache.lookup(.{ .value = path })) |resp| {
            return resp.body;
        }
        return null;
    }

    pub fn localRuleBody(self: *Shell, path: []const u8) ?[]const u8 {
        const ws_id = self.activeWsId() orelse return null;
        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return null;
        return workspace_rule.readRuleCacheFile(arena, ws_dir, path) catch null;
    }

    pub fn cachedRuleBody(self: *Shell, path: []const u8) ?[]const u8 {
        return self.remoteRuleBody(path) orelse self.localRuleBody(path);
    }

    pub fn remoteArtifactRuleBody(
        self: *Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?[]const u8 {
        return switch (category) {
            .rule, .meta_prompt => self.remoteRuleBody(path),
            .context => null,
        };
    }

    pub fn remoteArtifactRuleBodyForHash(
        self: *Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
        remote_hash: []const u8,
    ) ?[]const u8 {
        const body = self.remoteArtifactRuleBody(category, path) orelse return null;
        const body_hash = util_hash.contentHash(body);
        if (!local_content.hashesEqual(body_hash[0..], remote_hash)) return null;
        return body;
    }

    pub fn localArtifactRuleBody(
        self: *Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?[]const u8 {
        return switch (category) {
            .rule => self.localRuleBody(path),
            .context => null,
            .meta_prompt => self.localMetaPromptBody(),
        };
    }

    pub fn cachedArtifactRuleBody(
        self: *Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?[]const u8 {
        return self.remoteArtifactRuleBody(category, path) orelse self.localArtifactRuleBody(category, path);
    }

    pub fn localMetaPromptBody(self: *Shell) ?[]const u8 {
        const ws_id = self.activeWsId() orelse return null;
        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return null;
        const path = std.fs.path.join(arena, &.{ ws_dir, "cache", "META_PROMPT.md" }) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();
        var read_buf: [4096]u8 = undefined;
        var fr = std.fs.File.Reader.init(file, &read_buf);
        return fr.interface.allocRemaining(arena, std.io.Limit.limited(10 * 1024 * 1024)) catch null;
    }

    pub fn isLocalContentFresh(
        self: *Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
        remote_hash: []const u8,
    ) bool {
        const ws_id = self.activeWsId() orelse return false;
        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return false;
        return local_content.freshness(arena, ws_dir, category, path, remote_hash) == .fresh;
    }

    pub fn pullSelectedWorkspaceContent(self: *Shell) void {
        const ws_id = self.activeWsId() orelse {
            self.notifyOp(.warning, "No workspace selected.");
            return;
        };
        const ws_d = self.workspaceDetailForView(ws_id) orelse {
            self.ensureActiveWorkspaceDetailRequested();
            self.notifyOp(.loading, "Workspace metadata is still loading.");
            return;
        };

        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch {
            self.notifyOp(.failure, "Pull failed: local workspace path unavailable.");
            return;
        };

        const selection = self.currentWorkspaceFileSelection(ws_d);
        switch (self.workspace.tab) {
            .context => {
                const selected = selection orelse {
                    self.notifyOp(.warning, "Select a context file to pull.");
                    return;
                };
                const context = switch (selected) {
                    .context => |c| c,
                    .rule => {
                        self.notifyOp(.warning, "Select a context file to pull.");
                        return;
                    },
                };
                if (context.is_create_draft) {
                    self.notifyOp(.warning, "Select a synced context file to pull.");
                    return;
                }
                switch (self.workspaceSelectionPullDelta(selected)) {
                    .none => {
                        self.notifyOp(.success, "Selected content is already current.");
                        return;
                    },
                    .upsert_context => |remote| {
                        const body = self.api_state.workspace_context_content_cache.lookup(.{ .ws_id = ws_d.ws_id, .path = remote.path }) orelse {
                            self.requestWorkspaceSelectionContent(&ws_d, selected);
                            self.notifyOp(.loading, "Fetching selected content; pull again after it loads.");
                            return;
                        };
                        local_content.write(arena, ws_dir, .context, remote.path, body) catch {
                            self.notifyOp(.failure, "Pull failed: could not write local context.");
                            return;
                        };
                        local_content.writeManifestContextEntry(arena, ws_dir, ws_id, self.activeWorkspaceName(), remote.context_id, remote.path, remote.hash) catch {
                            self.notifyOp(.warning, "Pulled content; manifest update failed.");
                            self.resetLocalWorkspaceDetail();
                            return;
                        };
                    },
                    .remove_context => |local| {
                        local_content.removeManifestContextEntry(arena, ws_dir, ws_id, self.activeWorkspaceName(), local.context_id, local.path) catch {
                            self.notifyOp(.warning, "Pull failed: could not remove local context.");
                            self.resetLocalWorkspaceDetail();
                            return;
                        };
                    },
                    .upsert_rule, .remove_rule => unreachable,
                }
            },
            .rules => {
                const selected = selection orelse {
                    self.notifyOp(.warning, "Select a rule to pull.");
                    return;
                };
                const rule = switch (selected) {
                    .context => {
                        self.notifyOp(.warning, "Select a rule to pull.");
                        return;
                    },
                    .rule => |r| r,
                };
                if (rule.is_create_draft) {
                    self.notifyOp(.warning, "Select a synced rule to pull.");
                    return;
                }
                switch (self.workspaceSelectionPullDelta(selected)) {
                    .none => {
                        self.notifyOp(.success, "Selected content is already current.");
                        return;
                    },
                    .upsert_rule => |remote| {
                        const remote_path = self.pathForWorkspaceRule(remote);
                        const resp = self.api_state.rule_content_cache.lookup(.{ .value = remote_path }) orelse {
                            self.requestWorkspaceSelectionContent(&ws_d, selected);
                            self.notifyOp(.loading, "Fetching selected content; pull again after it loads.");
                            return;
                        };
                        const category = self.artifactCategoryForPath(remote_path);
                        local_content.write(arena, ws_dir, category, remote_path, resp.body) catch {
                            self.notifyOp(.failure, "Pull failed: could not write local rule.");
                            return;
                        };
                        local_content.writeManifestRuleEntry(arena, ws_dir, ws_id, self.activeWorkspaceName(), remote.rule_id, remote_path, remote.content_hash) catch {
                            self.notifyOp(.warning, "Pulled content; manifest update failed.");
                            self.resetLocalWorkspaceDetail();
                            return;
                        };
                    },
                    .remove_rule => |local| {
                        local_content.removeManifestRuleEntry(arena, ws_dir, ws_id, self.activeWorkspaceName(), local.rule_id, local.path) catch {
                            self.notifyOp(.warning, "Pull failed: could not remove local rule.");
                            self.resetLocalWorkspaceDetail();
                            return;
                        };
                    },
                    .upsert_context, .remove_context => unreachable,
                }
            },
        }

        self.resetLocalWorkspaceDetail();
        self.notifyOp(.success, "Pulled selected content.");
    }

    pub fn pullSelectedArtifactContent(self: *Shell) void {
        const ws_id = self.activeWsId() orelse {
            self.notifyOp(.warning, "No workspace selected.");
            return;
        };
        const rules = self.getRules();
        if (self.artifact.selected_rule >= rules.len) {
            self.notifyOp(.warning, "Select a synced rule to pull.");
            return;
        }

        const rule = rules[self.artifact.selected_rule];
        const rule_id = self.lookupRuleId(rule.path) orelse {
            self.notifyOp(.warning, "Selected rule id is not loaded yet.");
            return;
        };
        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch {
            self.notifyOp(.failure, "Pull failed: local workspace path unavailable.");
            return;
        };

        const resp = self.api_state.rule_content_cache.lookup(.{ .value = rule.path }) orelse {
            self.requestSelectedRuleDetail();
            self.notifyOp(.loading, "Fetching selected content; pull again after it loads.");
            return;
        };
        const category = self.artifactCategoryForPath(rule.path);
        local_content.write(arena, ws_dir, category, rule.path, resp.body) catch {
            self.notifyOp(.failure, "Pull failed: could not write local rule.");
            return;
        };
        local_content.writeManifestRuleEntry(arena, ws_dir, ws_id, self.activeWorkspaceName(), rule_id, rule.path, rule.content_hash) catch {
            self.notifyOp(.warning, "Pulled content; manifest update failed.");
            self.resetLocalWorkspaceDetail();
            return;
        };
        self.resetLocalWorkspaceDetail();
        self.notifyOp(.success, "Pulled selected content.");
    }

    pub fn artifactCategoryForPath(
        self: *const Shell,
        path: []const u8,
    ) drafts_mod.DraftCategory {
        _ = self;
        return if (std.mem.eql(u8, path, "META_PROMPT.md")) .meta_prompt else .rule;
    }

    pub fn invalidateRemoteDetailRequests(self: *Shell) void {
        api.state.invalidateRemoteCaches(self.api_state, .all_on_demand);
    }

    pub fn requestSelectedRuleDetail(self: *Shell) void {
        const rules = self.getRules();
        if (self.artifact.selected_rule >= rules.len) return;

        const sel_path = rules[self.artifact.selected_rule].path;
        const key = api.cache.StringKey{ .value = sel_path };

        if (self.api_state.rule_content_cache.shouldDispatch(key)) {
            api.specs.dispatchFromState(
                api.specs.RuleContentParams,
                @import("clumsies_lib").protocol.artifact_api.RuleContentResponse,
                api.specs.artifact_rule_content,
                &self.api_state.rule_content_pending,
                self.api_state,
                .{ .path = sel_path, .rule_id = self.lookupRuleId(sel_path) },
            );
        }

        if (self.api_state.rule_prs_cache.shouldDispatch(key)) {
            const rule_id = self.lookupRuleId(sel_path) orelse return;
            api.specs.dispatchFromState(
                api.specs.RulePrsParams,
                api.specs.RulePrsPayload,
                api.specs.artifact_rule_prs,
                &self.api_state.rule_prs_pending,
                self.api_state,
                .{ .rule_id = rule_id },
            );
        }
    }

    /// Look up the rule_id that corresponds to `path` in the cached
    /// artifact rule list. Returns null if the artifact has not loaded
    /// yet or the path is unknown.
    pub fn lookupRuleId(self: *Shell, path: []const u8) ?[]const u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const lib = self.api_state.rules orelse return null;
        for (lib) |lp| {
            if (std.mem.eql(u8, lp.path, path)) return lp.rule_id;
        }
        return null;
    }

    pub fn lookupRuleViewByPath(self: *Shell, path: []const u8) ?*const data.RuleEntry {
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
    fn lookupRulePath(self: *Shell, rule_id: []const u8) ?[]const u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const lib = self.api_state.rules orelse return null;
        for (lib) |lp| {
            if (std.mem.eql(u8, lp.rule_id, rule_id)) return lp.path;
        }
        return null;
    }

    /// Path of the currently selected artifact rule, or null when no
    /// rule is in focus. Used by failure-caching in the on-demand
    /// consumers, which do not have a request-scoped key to attribute
    /// the failure to and fall back to the current UI selection.
    fn selectedRulePath(self: *Shell) ?[]const u8 {
        const rules = self.getRules();
        if (rules.len == 0) return null;
        const idx = @min(self.artifact.selected_rule, rules.len - 1);
        return rules[idx].path;
    }

    fn requestWorkspaceSelectionContent(self: *Shell, ws_d: *const api.model.WorkspaceDetail, selection: WorkspaceFileSelection) void {
        switch (self.workspace.tab) {
            .context => {
                const context = switch (selection) {
                    .context => |c| c,
                    .rule => return,
                };
                if (context.is_create_draft) return;
                const remote_items = self.api_state.workspace_context_cache.lookup(.{ .value = ws_d.ws_id }) orelse return;
                const remote = findContextByPath(remote_items, context.path) orelse return;
                const key = api.state.WorkspacePathKey{ .ws_id = ws_d.ws_id, .path = context.path };
                if (remote.hash.len > 0) {
                    if (self.remoteWorkspaceContextBody(ws_d.ws_id, context.path)) |body| {
                        const body_hash = util_hash.contentHash(body);
                        if (local_content.hashesEqual(body_hash[0..], remote.hash)) return;
                        self.api_state.workspace_context_content_cache.invalidate();
                        self.api_state.workspace_context_content_pending.cancel();
                    }
                }
                if (!self.api_state.workspace_context_content_cache.shouldDispatch(key)) return;

                api.specs.dispatchFromState(
                    api.specs.WorkspaceContextContentParams,
                    api.specs.WorkspaceContextContentPayload,
                    api.specs.workspace_context_content,
                    &self.api_state.workspace_context_content_pending,
                    self.api_state,
                    .{ .ws_id = ws_d.ws_id, .path = context.path },
                );
            },
            .rules => {
                const rule = switch (selection) {
                    .context => return,
                    .rule => |r| r,
                };
                if (rule.is_create_draft) return;
                const remote_items = self.api_state.workspace_manifest_cache.lookup(.{ .value = ws_d.ws_id }) orelse return;
                const remote = self.findRuleFor(remote_items, rule.path, rule.rule_id) orelse return;
                const remote_path = self.pathForWorkspaceRule(remote);
                const key = api.cache.StringKey{ .value = remote_path };
                if (remote.content_hash.len > 0) {
                    if (self.remoteArtifactRuleBody(self.artifactCategoryForPath(remote_path), remote_path)) |body| {
                        const body_hash = util_hash.contentHash(body);
                        if (local_content.hashesEqual(body_hash[0..], remote.content_hash)) return;
                        self.api_state.rule_content_cache.invalidate();
                        self.api_state.rule_content_pending.cancel();
                    }
                }
                if (!self.api_state.rule_content_cache.shouldDispatch(key)) return;

                api.specs.dispatchFromState(
                    api.specs.RuleContentParams,
                    @import("clumsies_lib").protocol.artifact_api.RuleContentResponse,
                    api.specs.artifact_rule_content,
                    &self.api_state.rule_content_pending,
                    self.api_state,
                    .{ .path = remote_path, .rule_id = remote.rule_id },
                );
            },
        }
    }

    // Workspace content pane: shows selected item's content
    fn drawWsDetail(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const active_ws_id = self.activeWsId();
        const live_ws = if (active_ws_id) |ws_id|
            self.workspaceDetailForView(ws_id)
        else
            null;
        workspace_panel.syncWsRows(self);
        const current_file_sel = self.currentWorkspaceFileSelection(live_ws);
        const file_sel = current_file_sel orelse self.lastWorkspaceFileSelection(live_ws);
        if (live_ws) |ws_d| {
            if (file_sel) |selection| self.requestWorkspaceSelectionContent(&ws_d, selection);
        }
        if (current_file_sel != null) {
            switch (self.workspace.tab) {
                .context => self.workspace.last_context_file_row = self.workspace.list_sel,
                .rules => self.workspace.last_rule_file_row = self.workspace.list_sel,
            }
        }
        var context_sel: ?usize = null;
        var context_sel_id: ?[]const u8 = null;
        var context_sel_path: ?[]const u8 = null;
        var context_sel_hash: ?[]const u8 = null;
        var context_local_path: ?[]const u8 = null;
        var rule_sel_idx: ?usize = null;
        var rule_sel_id: ?[]const u8 = null;
        var rule_sel_path: ?[]const u8 = null;
        var rule_sel_hash: ?[]const u8 = null;
        var rule_local_path: ?[]const u8 = null;
        if (file_sel) |selection| switch (selection) {
            .context => |c| {
                context_sel = c.idx;
                context_sel_id = c.context_id;
                context_sel_path = c.path;
                context_sel_hash = c.hash;
                context_local_path = self.workspaceLocalContextPathForView(c.path, c.context_id);
            },
            .rule => |r| {
                rule_sel_idx = r.idx;
                rule_sel_id = r.rule_id;
                rule_sel_path = r.path;
                rule_sel_hash = r.hash;
                rule_local_path = self.workspaceLocalRulePathForView(r.path, r.rule_id);
            },
        };
        return workspace_panel.drawDetail(self, ctx, .{
            .live_ws = live_ws,
            .context_sel = context_sel,
            .context_sel_id = context_sel_id,
            .context_sel_path = context_sel_path,
            .context_sel_hash = context_sel_hash,
            .context_local_path = context_local_path,
            .rule_sel_idx = rule_sel_idx,
            .rule_sel_id = rule_sel_id,
            .rule_sel_path = rule_sel_path,
            .rule_sel_hash = rule_sel_hash,
            .rule_local_path = rule_local_path,
        });
    }

    fn lastWorkspaceFileSelection(self: *Shell, live_ws: ?api.model.WorkspaceDetail) ?WorkspaceFileSelection {
        const row = switch (self.workspace.tab) {
            .context => self.workspace.last_context_file_row,
            .rules => self.workspace.last_rule_file_row,
        } orelse return null;
        return self.workspaceFileAtRow(row, live_ws);
    }

    fn loadAnalysisData(self: *Shell, arena: std.mem.Allocator) ?data.AnalysisData {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.org_stats) |stats| {
            return api.view_model.analysisFromStats(arena, stats, self.api_state.rules, null);
        }
        return null;
    }

    // Shell: live interaction rounds and attestation closure state.
    fn drawDashboard(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const scoped_attestation = self.scopedAttestationData();
        const rounds: []const attestation_reader.RoundEvent = if (scoped_attestation) |st| st.rounds else &.{};
        const visible_rounds = dashboard_panel.visibleRounds(rounds);

        const arena_h: u16 = dashboard_panel.ARENA_HEIGHT;
        const body_h: u16 = size.height -| arena_h;
        const preferred_rounds_w: u16 = @intCast(@divTrunc(@as(u32, size.width) * 38, 100));
        const rounds_w: u16 = @min(size.width, @max(@as(u16, 64), @min(@as(u16, 96), preferred_rounds_w)));
        const trace_w: u16 = size.width -| rounds_w;
        const usable_round_rows: u16 = body_h -| 2;
        self.dashboard.input_capacity = @max(@as(usize, 1), @as(usize, @intCast(usable_round_rows / 2)));
        if (self.analysis.input_cursor >= visible_rounds.len and visible_rounds.len > 0) {
            self.analysis.input_cursor = visible_rounds.len - 1;
        }
        const max_round_cursor = std.math.maxInt(u32) / dashboard_panel.ROUND_ROW_COUNT;
        self.dashboard.round_scroll_bars.scroll_view.cursor = @intCast(@min(self.analysis.input_cursor, max_round_cursor) * dashboard_panel.ROUND_ROW_COUNT);
        const selected_round = if (visible_rounds.len > 0)
            visible_rounds[@min(self.analysis.input_cursor, visible_rounds.len - 1)]
        else
            null;
        const summary = dashboardSummary(ctx.arena, rounds);
        const arena_surface = try dashboard_panel.drawArena(
            self,
            ctx,
            size.width,
            arena_h,
            summary,
            visible_rounds,
            self.analysis.input_cursor,
        );
        const rounds_surface = try dashboard_panel.drawRounds(
            self,
            ctx,
            rounds_w,
            body_h,
            visible_rounds,
        );
        const trace_surface = try dashboard_panel.drawProtocolTrace(self, ctx, trace_w, body_h, selected_round);
        return dashboard_panel.drawRoot(self, ctx, arena_surface, rounds_surface, trace_surface);
    }

    // Analysis: aggregate rule/member views and drill-downs.
    fn drawAnalysis(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
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

    // Count active drafts across all categories; terminal states are hidden.
    fn draftCount(self: *Shell) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const drafts = self.api_state.drafts orelse return 0;
        var count: usize = 0;
        for (drafts) |d| {
            if (!std.mem.eql(u8, d.status, "applied") and !std.mem.eql(u8, d.status, "declined")) count += 1;
        }
        return count;
    }

    pub fn getPrsForRule(self: *Shell, rule_path: []const u8) []const data.PullRequestEntry {
        const prs = self.api_state.rule_prs_cache.lookup(.{ .value = rule_path }) orelse return &.{};
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        return api.view_model.toPrEntries(self.viewAllocator(), prs, rule_path, self.api_state);
    }

    pub fn getReviewPrs(self: *Shell) []const data.PullRequestEntry {
        const prs = self.api_state.review_prs_cache.lookup(.{ .value = "review" }) orelse return &.{};
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        return api.view_model.toReviewPrEntries(self.viewAllocator(), prs, self.api_state);
    }

    fn ensureReviewPrsRequested(self: *Shell) void {
        if (!self.api_state.review_prs_cache.shouldDispatch(.{ .value = "review" })) return;
        api.specs.dispatchFromState(
            api.specs.ReviewPrsParams,
            []const api.model.RulePr,
            api.specs.review_prs,
            &self.api_state.review_prs_pending,
            self.api_state,
            .{
                .target_kind = null,
                .status = "all",
            },
        );
    }

    pub fn getRules(self: *Shell) []const data.RuleEntry {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.rules) |lp| {
            return api.view_model.toRuleEntries(self.viewAllocator(), lp);
        }
        return &.{};
    }

    pub fn getBundles(self: *Shell) []const data.BundleEntry {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.bundles) |lb| {
            return api.view_model.toBundleEntries(self.viewAllocator(), lb);
        }
        return &.{};
    }

    /// Pump the artifact rule content pending slot: on .ok, stash the
    /// response in the cache keyed by path so subsequent draws can
    /// retrieve it synchronously. On any error outcome, record the
    /// failure against the selected path so widget sync does not
    /// re-dispatch on every tick; the next remote cache invalidation
    /// or a navigation to a different rule clears the marker.
    fn consumeRuleContentResult(self: *Shell) void {
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

    /// Pump the artifact rule PR list pending slot. Routes the cache
    /// write against `payload.rule_id` — the id the request was
    /// issued for — rather than the current UI selection, so a rule
    /// switch mid-flight cannot store the list under the wrong path.
    /// On error, mark the currently selected rule as failed so the
    /// widget loop does not re-dispatch on every tick.
    fn consumeRulePrsResult(self: *Shell) void {
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

    fn consumeReviewPrsResult(self: *Shell) void {
        const result = self.api_state.review_prs_pending.consume() orelse return;
        switch (result) {
            .ok => |prs| {
                self.api_state.review_prs_cache.store(.{ .value = "review" }, prs);
                self.reconcileTerminalPrDrafts(prs);
            },
            else => {
                self.api_state.review_prs_cache.markFailed(.{ .value = "review" });
            },
        }
    }

    fn reconcileTerminalPrDrafts(self: *Shell, prs: []const api.model.RulePr) void {
        const active_ws_id = self.activeWsId();
        var changed = false;
        for (prs) |pr| {
            const next_status = draftStatusForTerminalPr(pr.status) orelse continue;
            const category = draftCategoryForPrTargetKind(pr.target_kind) orelse continue;
            if (pr.ws_id) |ws_id| {
                changed = self.reconcileTerminalPrDraftInWorkspace(ws_id, category, pr.target_path, next_status) or changed;
            } else if (active_ws_id) |ws_id| {
                changed = self.reconcileTerminalPrDraftInWorkspace(ws_id, category, pr.target_path, next_status) or changed;
            }
        }
        if (!changed) return;
        self.refreshDraftsCache();
        workspace_panel.syncWsRows(self);
        artifact_panel.syncArtifactTree(self);
    }

    fn reconcileTerminalPrDraftInWorkspace(
        self: *Shell,
        ws_id: []const u8,
        category: drafts_mod.DraftCategory,
        target_path: []const u8,
        next_status: drafts_mod.DraftStatus,
    ) bool {
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, ws_id) catch return false;
        defer alloc.free(ws_dir);
        return drafts_mod.transitionDraftStatus(
            alloc,
            ws_dir,
            category,
            target_path,
            .in_review,
            next_status,
        ) catch false;
    }

    fn draftStatusForTerminalPr(status: []const u8) ?drafts_mod.DraftStatus {
        if (std.mem.eql(u8, status, "accepted") or std.mem.eql(u8, status, "merged")) {
            return .applied;
        }
        if (std.mem.eql(u8, status, "rejected")) return .declined;
        return null;
    }

    fn draftCategoryForPrTargetKind(target_kind: []const u8) ?drafts_mod.DraftCategory {
        if (std.mem.eql(u8, target_kind, "context")) return .context;
        if (std.mem.eql(u8, target_kind, "rule")) return .rule;
        if (std.mem.eql(u8, target_kind, "mpf")) return .meta_prompt;
        return null;
    }

    /// Pump the workspace context files pending slot. Stores under the
    /// ws_id the request was issued for; `state.wsDetail` combines it
    /// with the manifest half to form the view.
    fn consumeWorkspaceContextResult(self: *Shell) void {
        const result = self.api_state.workspace_context_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.workspace_context_cache.store(.{ .value = payload.ws_id }, payload.files);
                self.settlePendingWorkspacePrAction(payload.ws_id);
                self.system_notices.clear(.workspace_context);
            },
            else => {
                if (self.activeWsId()) |ws_id| {
                    const has_remote_snapshot = self.api_state.workspace_context_cache.lookup(.{ .value = ws_id }) != null;
                    if (!has_remote_snapshot) self.api_state.workspace_context_cache.markFailed(.{ .value = ws_id });
                    if (!self.isHubConnected()) return;
                    const text: []const u8 = if (has_remote_snapshot)
                        "Workspace context refresh failed; showing latest remote snapshot."
                    else if (self.hasLocalWorkspaceDetail(ws_id))
                        "Workspace context failed; showing local cache."
                    else
                        "Workspace context failed.";
                    self.system_notices.push(.workspace_context, .failure, .persistent, text);
                }
            },
        }
    }

    fn consumeWsManifestResult(self: *Shell) void {
        const result = self.api_state.workspace_manifest_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.workspace_manifest_cache.store(.{ .value = payload.ws_id }, payload.rules);
                self.system_notices.clear(.workspace_manifest);
            },
            else => {
                if (self.activeWsId()) |ws_id| {
                    const has_remote_snapshot = self.api_state.workspace_manifest_cache.lookup(.{ .value = ws_id }) != null;
                    if (!has_remote_snapshot) self.api_state.workspace_manifest_cache.markFailed(.{ .value = ws_id });
                    if (!self.isHubConnected()) return;
                    const text: []const u8 = if (has_remote_snapshot)
                        "Workspace manifest refresh failed; showing latest remote snapshot."
                    else if (self.hasLocalWorkspaceDetail(ws_id))
                        "Workspace manifest failed; showing local cache."
                    else
                        "Workspace manifest failed.";
                    self.system_notices.push(.workspace_manifest, .failure, .persistent, text);
                }
            },
        }
    }

    fn consumeWorkspaceMembersResult(self: *Shell) void {
        const result = self.api_state.workspace_members_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.workspace_members_cache.store(.{ .value = payload.ws_id }, payload.members);
            },
            else => {
                if (self.selectedSettingsWorkspaceId()) |ws_id| {
                    self.api_state.workspace_members_cache.markFailed(.{ .value = ws_id });
                }
            },
        }
    }

    /// Pump the PR detail pending slot. On .ok, stash the raw response
    /// in the cache and recompute the derived view fields (picked
    /// operation, diff lines, attestation refers) against the response's
    /// own pr_id so selection changes mid-flight cannot misroute
    /// either the cache entry or the derived fields.
    fn consumePrDetailResult(self: *Shell) void {
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

    fn consumePrCommentsResult(self: *Shell) void {
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
    fn activePrId(self: *Shell) ?[]const u8 {
        if (self.selected_module == .review) {
            const prs = self.getReviewPrs();
            if (prs.len == 0) return null;
            const pr_idx = @min(self.review.selected_pr_idx, prs.len - 1);
            return prs[pr_idx].id;
        }
        const rules = self.getRules();
        const rule_idx = @min(self.artifact.selected_rule, if (rules.len > 0) rules.len - 1 else 0);
        if (rules.len == 0) return null;
        const prs = self.getPrsForRule(rules[rule_idx].path);
        if (prs.len == 0) return null;
        const pr_idx = @min(self.review.selected_pr_idx, prs.len - 1);
        return prs[pr_idx].id;
    }

    /// Recompute the 8 derived pr_detail_* fields from the just-fetched
    /// response. Picking the active operation requires the currently
    /// cached artifact PR list so the op matching the selected rule
    /// is surfaced first.
    fn refreshPrDetailDerivedFields(
        self: *Shell,
        pr_id: []const u8,
        resp: @import("clumsies_lib").protocol.collab_api.RulePrDetailResponse,
    ) void {
        const alloc = self.api_state.allocator();

        const target_rule_id: ?[]const u8 = if (self.selected_module == .review) null else blk: {
            const rules = self.getRules();
            const rule_idx = @min(self.artifact.selected_rule, if (rules.len > 0) rules.len - 1 else 0);
            break :blk if (rules.len > 0)
                self.lookupRuleId(rules[rule_idx].path)
            else
                null;
        };

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

        var op_type: ?[]const u8 = null;
        var op_current_path: ?[]const u8 = null;
        var op_new_path: ?[]const u8 = null;
        var op_base_hash: ?[]const u8 = null;
        var op_index: u16 = 0;
        const op_total: u16 = @intCast(@min(resp.operations.len, std.math.maxInt(u16)));

        var base_copy: ?[]const u8 = null;
        var proposed_copy: ?[]const u8 = null;

        if (pick_idx) |i| {
            const op = resp.operations[i];
            const base = op.base_content orelse "";
            const proposed = op.content orelse "";
            base_copy = alloc.dupe(u8, base) catch null;
            proposed_copy = alloc.dupe(u8, proposed) catch null;
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
        self.api_state.pr_detail_base = base_copy;
        self.api_state.pr_detail_proposed = proposed_copy;
        self.api_state.pr_detail_attestation_refers = attestation_refers;
        self.api_state.pr_detail_op_type = op_type;
        self.api_state.pr_detail_op_current_path = op_current_path;
        self.api_state.pr_detail_op_new_path = op_new_path;
        self.api_state.pr_detail_op_base_hash = op_base_hash;
        self.api_state.pr_detail_op_index = op_index;
        self.api_state.pr_detail_op_total = op_total;
    }

    /// Pump the three write-path pending slots. Each surfaces the
    /// outcome as an operation toast; body payloads are void so the
    /// Result carries only ok / api_error / network_error /
    /// invalid_response.
    fn consumeSignOutResult(self: *Shell) void {
        const result = self.api_state.sign_out_pending.consume() orelse return;
        switch (result) {
            .ok => {
                auth_mod.clearAuth(self.api_state.backing_allocator) catch |err| {
                    log.warn("clear_auth_failed error={s}", .{@errorName(err)});
                };
                self.api_state.clearAuthSession();
                self.show_settings = false;
                if (self.sign_out_should_quit) {
                    self.quit_after_sign_out = true;
                } else {
                    self.notifyOp(.success, "Signed out.");
                }
            },
            .api_error => |e| {
                self.sign_out_should_quit = false;
                self.notifyOp(.failure, writeErrorStatus(self, "Token revoke failed", e));
            },
            .network_error => {
                self.sign_out_should_quit = false;
                self.notifyOp(.failure, "Token revoke failed: network error.");
            },
            .invalid_response => {
                self.sign_out_should_quit = false;
                self.notifyOp(.failure, "Token revoke failed: malformed response.");
            },
        }
    }

    fn consumeUpdateProfileResult(self: *Shell) void {
        const result = self.api_state.update_profile_pending.consume() orelse return;
        self.profile_dialog_submitting = false;
        switch (result) {
            .ok => |resp| {
                self.applyUpdatedProfile(resp);
                self.closeProfileDialog();
                api.fetch.refetchAllAsync(self.api_state);
                self.notifyOp(.success, "Profile updated.");
            },
            .api_error => |e| {
                self.profile_dialog_message = writeErrorStatus(self, "Profile update failed", e);
            },
            .network_error => {
                self.profile_dialog_message = "Profile update failed: network error.";
            },
            .invalid_response => {
                self.profile_dialog_message = "Profile update failed: malformed response.";
            },
        }
    }

    fn consumeInviteMemberResult(self: *Shell) void {
        const result = self.api_state.invite_member_pending.consume() orelse return;
        self.invite_dialog_submitting = false;
        switch (result) {
            .ok => |resp| {
                self.invite_dialog_message = "Invite created.";
                const len = @min(resp.invite_token.len, self.invite_result_token_buf.len);
                @memcpy(self.invite_result_token_buf[0..len], resp.invite_token[0..len]);
                self.invite_result_token_len = len;
                api.fetch.refetchAllAsync(self.api_state);
                self.notifyOp(.success, "Invite created.");
            },
            .api_error => |e| {
                self.invite_dialog_message = writeErrorStatus(self, "Invite failed", e);
                self.invite_result_token_len = 0;
            },
            .network_error => {
                self.invite_dialog_message = "Invite failed: network error.";
                self.invite_result_token_len = 0;
            },
            .invalid_response => {
                self.invite_dialog_message = "Invite failed: malformed response.";
                self.invite_result_token_len = 0;
            },
        }
    }

    fn consumeChangeMemberRoleResult(self: *Shell) void {
        const result = self.api_state.change_member_role_pending.consume() orelse return;
        self.invite_dialog_submitting = false;
        switch (result) {
            .ok => {
                self.closeInviteMemberDialog();
                api.fetch.refetchAllAsync(self.api_state);
                self.notifyOp(.success, "Role updated.");
            },
            .api_error => |e| {
                self.invite_dialog_message = writeErrorStatus(self, "Role update failed", e);
            },
            .network_error => {
                self.invite_dialog_message = "Role update failed: network error.";
            },
            .invalid_response => {
                self.invite_dialog_message = "Role update failed: malformed response.";
            },
        }
    }

    fn consumeRemoveMemberResult(self: *Shell) void {
        const result = self.api_state.remove_member_pending.consume() orelse return;
        self.confirm_submitting = false;
        switch (result) {
            .ok => {
                self.closeConfirmOverlay();
                api.fetch.refetchAllAsync(self.api_state);
                self.notifyOp(.success, "Member removed.");
            },
            .api_error => |e| self.confirm_error_message = writeErrorStatus(self, "Remove member failed", e),
            .network_error => self.confirm_error_message = "Remove member failed: network error.",
            .invalid_response => self.confirm_error_message = "Remove member failed: malformed response.",
        }
    }

    fn consumeAddWorkspaceMemberResult(self: *Shell) void {
        const result = self.api_state.add_workspace_member_pending.consume() orelse return;
        self.invite_dialog_submitting = false;
        switch (result) {
            .ok => {
                self.closeInviteMemberDialog();
                self.invalidateSelectedWorkspaceMembers();
                self.notifyOp(.success, "Workspace member added.");
            },
            .api_error => |e| self.invite_dialog_message = writeErrorStatus(self, "Add member failed", e),
            .network_error => self.invite_dialog_message = "Add member failed: network error.",
            .invalid_response => self.invite_dialog_message = "Add member failed: malformed response.",
        }
    }

    fn consumeChangeWorkspaceMemberRoleResult(self: *Shell) void {
        const result = self.api_state.change_workspace_member_role_pending.consume() orelse return;
        self.invite_dialog_submitting = false;
        switch (result) {
            .ok => {
                self.closeInviteMemberDialog();
                self.invalidateSelectedWorkspaceMembers();
                self.notifyOp(.success, "Workspace role updated.");
            },
            .api_error => |e| self.invite_dialog_message = writeErrorStatus(self, "Role update failed", e),
            .network_error => self.invite_dialog_message = "Role update failed: network error.",
            .invalid_response => self.invite_dialog_message = "Role update failed: malformed response.",
        }
    }

    fn consumeRemoveWorkspaceMemberResult(self: *Shell) void {
        const result = self.api_state.remove_workspace_member_pending.consume() orelse return;
        self.confirm_submitting = false;
        switch (result) {
            .ok => {
                self.closeConfirmOverlay();
                self.invalidateSelectedWorkspaceMembers();
                self.settings.workspace_member_sel = 0;
                self.notifyOp(.success, "Workspace member removed.");
            },
            .api_error => |e| self.confirm_error_message = writeErrorStatus(self, "Remove member failed", e),
            .network_error => self.confirm_error_message = "Remove member failed: network error.",
            .invalid_response => self.confirm_error_message = "Remove member failed: malformed response.",
        }
    }

    fn invalidateSelectedWorkspaceMembers(self: *Shell) void {
        self.api_state.workspace_members_cache.invalidate();
    }

    fn consumeUpdateWorkspaceResult(self: *Shell) void {
        const result = self.api_state.update_ws_pending.consume() orelse return;
        switch (result) {
            .ok => {
                workspace_panel.closeCreate(self);
                api.fetch.refetchAllAsync(self.api_state);
                self.notifyOp(.success, "Workspace updated.");
            },
            else => workspace_panel.applyCreateResult(self, result),
        }
    }

    fn consumeDeleteWorkspaceResult(self: *Shell) void {
        const result = self.api_state.delete_ws_pending.consume() orelse return;
        switch (result) {
            .ok => {
                self.workspace.sel = 0;
                self.settings.content_sel = 0;
                api.fetch.refetchAllAsync(self.api_state);
                self.notifyOp(.success, "Workspace deleted.");
            },
            .api_error => |e| self.notifyOp(.failure, writeErrorStatus(self, "Delete workspace failed", e)),
            .network_error => self.notifyOp(.failure, "Delete workspace failed: network error."),
            .invalid_response => self.notifyOp(.failure, "Delete workspace failed: malformed response."),
        }
    }

    fn submitDeleteWorkspace(self: *Shell) void {
        const workspace = self.selectedSettingsWorkspace() orelse {
            self.notifyOp(.warning, "No workspace selected.");
            return;
        };
        api.specs.dispatchFromState(
            api.specs.WorkspaceIdParams,
            void,
            api.specs.delete_workspace,
            &self.api_state.delete_ws_pending,
            self.api_state,
            .{ .ws_id = workspace.ws_id },
        );
        self.notifyOp(.loading, "Deleting workspace...");
    }

    fn applyUpdatedProfile(self: *Shell, resp: auth_api.UpdateProfileResponse) void {
        const alloc = self.api_state.backing_allocator;
        const state_alloc = self.api_state.allocator();
        const org_name_copy = state_alloc.dupe(u8, resp.org_name) catch return;
        const username_copy = state_alloc.dupe(u8, resp.username) catch return;
        var hub_url_copy: ?[]const u8 = null;
        var access_copy: ?[]const u8 = null;
        var refresh_copy: ?[]const u8 = null;

        self.api_state.mutex.lock();
        self.api_state.username = username_copy;
        if (self.api_state.current_user) |*u| {
            u.org_name = org_name_copy;
            u.username = username_copy;
            u.role = resp.role;
            u.scopes = resp.scopes;
        }
        if (self.api_state.hub_url) |value| hub_url_copy = alloc.dupe(u8, value) catch null;
        if (self.api_state.access_token) |value| access_copy = alloc.dupe(u8, value) catch null;
        if (self.api_state.refresh_token) |value| refresh_copy = alloc.dupe(u8, value) catch null;
        self.api_state.mutex.unlock();

        defer if (hub_url_copy) |value| alloc.free(value);
        defer if (access_copy) |value| alloc.free(value);
        defer if (refresh_copy) |value| alloc.free(value);

        if (hub_url_copy != null and access_copy != null and refresh_copy != null) {
            _ = auth_mod.saveAuth(alloc, hub_url_copy.?, resp.username, access_copy.?, refresh_copy.?) catch |err| {
                log.warn("profile_auth_persist_failed error={s}", .{@errorName(err)});
            };
        }
    }

    fn consumeSubmitCommentResult(self: *Shell) void {
        const result = self.api_state.submit_comment_pending.consume() orelse return;
        switch (result) {
            .ok => {
                const submitted_pr = self.selectedPr();
                api.state.invalidateRemoteCaches(self.api_state, .pr_lifecycle);
                if (self.selected_module == .review) {
                    self.ensureReviewPrsRequested();
                    if (submitted_pr) |pr| self.fetchPrDetailForEntry(pr);
                }
                self.notifyOp(.success, "Comment submitted.");
            },
            .api_error => |e| self.notifyOp(.failure, writeErrorStatus(self, "Comment submission failed", e)),
            .network_error => self.notifyOp(.failure, "Comment submission failed: network error."),
            .invalid_response => self.notifyOp(.failure, "Comment submission failed: malformed response."),
        }
    }

    fn consumePrActionResult(self: *Shell) void {
        const result = self.api_state.pr_action_pending.consume() orelse return;
        switch (result) {
            .ok => {
                const wait_for_workspace = self.shouldSettlePrActionAfterWorkspaceRefresh();
                if (!wait_for_workspace) self.settlePendingPrActionDraft();
                self.invalidateRemoteDetailRequests();
                self.returnReviewDetailToListAfterPrAction();
                if (wait_for_workspace) {
                    if (self.drafts.pending_pr_action) |pending| {
                        workspace_panel.refreshWorkspaceDetail(self, pending.target.ws_id);
                    }
                }
                self.notifyOp(.success, "PR action applied.");
            },
            .api_error => |e| {
                self.releasePendingPrAction();
                self.notifyOp(.failure, writeErrorStatus(self, "PR action failed", e));
            },
            .network_error => {
                self.releasePendingPrAction();
                self.notifyOp(.failure, "PR action failed: network error.");
            },
            .invalid_response => {
                self.releasePendingPrAction();
                self.notifyOp(.failure, "PR action failed: malformed response.");
            },
        }
    }

    fn consumeAttestationUploadResult(self: *Shell) void {
        const result = self.api_state.attestation_upload_pending.consume() orelse return;
        switch (result) {
            .ok => |summary| {
                self.system_notices.clear(.attestation_upload);
                log.info("attestation_upload_ok workspaces={d} events={d} batches={d}", .{
                    summary.workspace_count,
                    summary.events_sent,
                    summary.batches_sent,
                });
                if (summary.events_sent > 0) api.fetch.refetchAllAsync(self.api_state);
            },
            .not_authenticated => {
                log.warn("attestation_upload_not_authenticated", .{});
                self.system_notices.clear(.attestation_upload);
            },
            .failed => |name| {
                log.warn("attestation_upload_failed error={s}", .{name});
                const message = std.fmt.allocPrint(
                    self.api_state.allocator(),
                    "Attestation upload failed: {s}. Check local client log.",
                    .{name},
                ) catch "Attestation upload failed. Check local client log.";
                self.system_notices.push(.attestation_upload, .failure, .persistent, message);
            },
        }
    }

    /// Format `context: <server message> (CODE)` into a Shell-owned
    /// message buffer suitable for a toast.
    fn writeErrorStatus(self: *Shell, context: []const u8, err: api.request.ApiErrorPayload) []const u8 {
        const alloc = self.api_state.allocator();
        return std.fmt.allocPrint(alloc, "{s}: {s} ({s})", .{ context, err.message, err.code }) catch context;
    }

    /// Pump the workspace context file content pending slot. The
    /// payload carries the (ws_id, path) key the request was issued
    /// for, so the cache entry is routed against the request rather
    /// than against whatever the user now has selected. On error,
    /// mark the currently selected (ws_id, path) as failed to stop the
    /// widget loop from re-dispatching on every tick.
    fn consumeWsContextContentResult(self: *Shell) void {
        const result = self.api_state.workspace_context_content_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.workspace_context_content_cache.store(
                    .{ .ws_id = payload.ws_id, .path = payload.path },
                    payload.body,
                );
                self.system_notices.clear(.workspace_context_content);
            },
            else => {
                const ws_id = self.activeWsId() orelse return;
                const ws_d = self.workspaceDetailForView(ws_id) orelse return;
                const selection = self.currentWorkspaceFileSelection(ws_d) orelse return;
                const context = switch (selection) {
                    .context => |c| c,
                    .rule => return,
                };
                if (context.is_create_draft) return;
                self.api_state.workspace_context_content_cache.markFailed(
                    .{ .ws_id = ws_d.ws_id, .path = context.path },
                );
                if (!self.isHubConnected()) return;
                self.system_notices.push(.workspace_context_content, .failure, .persistent, "Workspace context content failed; showing local cache when available.");
            },
        }
    }

    fn isHubConnected(self: *Shell) bool {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        return self.api_state.status == .connected;
    }

    fn consumeHealthResult(self: *Shell) void {
        const result = self.api_state.health_pending.consume() orelse return;
        switch (result) {
            .ok => {
                self.api_state.mutex.lock();
                const was_offline = self.api_state.status == .error_network;
                if (was_offline) self.api_state.status = .connected;
                self.api_state.mutex.unlock();
                if (was_offline) api.fetch.refetchAllAsync(self.api_state);
            },
            else => {
                self.api_state.mutex.lock();
                if (self.api_state.status != .connecting and self.api_state.status != .disconnected) {
                    self.api_state.status = .error_network;
                }
                self.api_state.mutex.unlock();
            },
        }
    }

    fn submitComment(self: *Shell) void {
        const pr = self.selectedPr() orelse return;
        if (pr.target_kind == .bundle) return;

        const comment_text = self.review.comment_input_buf[0..self.review.comment_input_len];
        api.specs.dispatchFromState(
            api.specs.SubmitCommentParams,
            void,
            api.specs.submit_comment,
            &self.api_state.submit_comment_pending,
            self.api_state,
            .{ .pr_id = pr.id, .target_kind = pr.target_kind, .ws_id = pr.workspace_id, .body = comment_text },
        );
        self.notifyOp(.loading, "Submitting comment...");
    }

    fn fetchPrDetailForEntry(self: *Shell, pr: data.PullRequestEntry) void {
        if (pr.target_kind == .bundle) return;
        api.specs.dispatchFromState(
            api.specs.PrIdParams,
            @import("clumsies_lib").protocol.collab_api.RulePrDetailResponse,
            api.specs.pr_detail,
            &self.api_state.pr_detail_pending,
            self.api_state,
            .{ .pr_id = pr.id, .target_kind = pr.target_kind, .ws_id = pr.workspace_id },
        );
        api.specs.dispatchFromState(
            api.specs.PrIdParams,
            api.specs.PrCommentsPayload,
            api.specs.pr_comments,
            &self.api_state.pr_comments_pending,
            self.api_state,
            .{ .pr_id = pr.id, .target_kind = pr.target_kind, .ws_id = pr.workspace_id },
        );
    }

    pub fn doPrAction(self: *Shell, action: []const u8) void {
        const pr = self.selectedPr() orelse return;
        if (pr.target_kind == .bundle) return;
        if (!self.capturePendingPrAction(pr, action)) return;

        api.specs.dispatchFromState(
            api.specs.PrActionParams,
            void,
            api.specs.pr_action,
            &self.api_state.pr_action_pending,
            self.api_state,
            .{ .pr_id = pr.id, .target_kind = pr.target_kind, .ws_id = pr.workspace_id, .action = action },
        );
        self.notifyOp(.loading, if (std.mem.eql(u8, action, "accept")) "Accepting PR..." else "Rejecting PR...");
    }

    fn selectedPr(self: *Shell) ?data.PullRequestEntry {
        if (self.selected_module == .review) {
            const prs = self.getReviewPrs();
            if (prs.len == 0) return null;
            return prs[@min(self.review.selected_pr_idx, prs.len - 1)];
        }
        const all_p = self.getRules();
        const si = @min(self.artifact.selected_rule, if (all_p.len > 0) all_p.len - 1 else 0);
        if (all_p.len == 0) return null;
        const prs_for = self.getPrsForRule(all_p[si].path);
        if (prs_for.len == 0) return null;
        return prs_for[@min(self.review.selected_pr_idx, prs_for.len - 1)];
    }

    pub fn wsCount(self: *Shell) usize {
        return self.getWorkspaces().len;
    }

    pub fn getWorkspaces(self: *Shell) []const data.WorkspaceEntry {
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

    fn wsContextCount(self: *Shell) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.ws_detail) |ws_d| return ws_d.workspace_context.len;
        return 0;
    }

    fn wsRulesCount(self: *Shell) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.ws_detail) |ws_d| return ws_d.workspace_rules.len;
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

    fn currentAnalysisScopeLocked(self: *const Shell) AnalysisScopeInfo {
        const workspaces = if (self.api_state.current_user) |u| u.workspaces else &.{};
        if (workspaces.len == 0 or self.analysis.scope_idx == 0) {
            return .{ .label = "All Workspaces", .ws_id = null };
        }

        const scope_idx = @min(self.analysis.scope_idx, workspaces.len);
        const ws = workspaces[scope_idx - 1];
        return .{ .label = ws.name, .ws_id = ws.ws_id };
    }

    fn currentAnalysisScope(self: *const Shell) AnalysisScopeInfo {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        return self.currentAnalysisScopeLocked();
    }

    pub fn cycleAnalysisScope(self: *Shell) AnalysisScopeInfo {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const workspaces = if (self.api_state.current_user) |u| u.workspaces else &.{};
        const scope_count = workspaces.len + 1;
        self.analysis.scope_idx = (self.analysis.scope_idx + 1) % scope_count;
        return self.currentAnalysisScopeLocked();
    }

    fn scopedAttestationData(self: *const Shell) ?ScopedAttestationData {
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

    fn dashboardSummary(arena: std.mem.Allocator, rounds: []const attestation_reader.RoundEvent) dashboard_panel.DashboardSummary {
        var summary: dashboard_panel.DashboardSummary = .{
            .round_count = rounds.len,
        };
        var sessions: std.StringHashMapUnmanaged(void) = .empty;
        for (rounds) |round| {
            if (round.submit_count > 0) summary.submitted_count += 1;
            if (round.refer_count > 0) summary.referred_count += 1;
            if (round.reject_count > 0) summary.rejected_count += 1;
            if (round.submit_count == 0 and round.reject_count == 0) summary.open_count += 1;
            summary.refer_count += round.refer_count;
            if (dashboard_panel.isExceptionRound(round)) summary.exception_count += 1;
            sessions.put(arena, round.session_id, {}) catch {};
        }
        summary.session_count = sessions.count();
        return summary;
    }

    fn getAnalysisCounts(self: *Shell) AnalysisCounts {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();

        const scope = self.currentAnalysisScopeLocked();
        const input_count: usize = if (self.api_state.local_stats) |local| blk: {
            const rounds = if (scope.ws_id) |ws_id|
                (if (local.workspace(ws_id)) |ws| ws.rounds else &.{})
            else
                local.rounds;
            break :blk dashboard_panel.visibleRoundCount(rounds.len);
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

    fn drawHelpDrawer(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        if (size.width < w.Drawer.min_child_width or size.height < w.Drawer.min_child_height) {
            var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
            w.fillSurface(&surface, theme.PANEL_SOFT);
            return surface;
        }

        const body_w = size.width - w.Drawer.child_origin_col;
        const body_h = size.height - w.Drawer.child_origin_row;
        var body = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = body_w, .height = body_h });
        w.fillSurface(&body, theme.PANEL_SOFT);

        var row: u16 = 0;
        row = self.drawHelpSection(&body, ctx, row, "Navigation", &.{
            .{ .key = "j/k", .label = "move the active cursor or selection" },
            .{ .key = "J/K", .label = "page the active panel down or up" },
            .{ .key = "Ctrl-d/u", .label = "half-page the active panel down or up" },
            .{ .key = "\xe2\x86\x91/\xe2\x86\x93", .label = "same as j/k in lists and tables" },
            .{ .key = "h/l", .label = "switch inner tabs when a panel has them" },
            .{ .key = "Tab", .label = "switch focus between panels or regions" },
            .{ .key = "Enter", .label = "open, toggle, or confirm the selected item" },
            .{ .key = "z", .label = "expand or collapse all rows in a tree list" },
            .{ .key = "Esc", .label = "go back, close a drawer, or leave detail focus" },
        });
        if (row < body_h) row += 1;
        row = self.drawHelpSection(&body, ctx, row, "Application", &.{
            .{ .key = "1-5", .label = "switch the top-level module" },
            .{ .key = "S", .label = "open settings" },
            .{ .key = "?", .label = "open or close this help drawer" },
            .{ .key = "q", .label = "open quit confirmation" },
            .{ .key = "Ctrl+C", .label = "quit immediately" },
        });

        const drawer = w.Drawer{
            .title = "Keyboard Reference",
            .border_color = theme.ACCENT_SOFT,
            .background = theme.PANEL_SOFT,
            .body = body,
        };
        return drawer.draw(ctx, self.widget());
    }

    fn drawHelpSection(
        self: *Shell,
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        start_row: u16,
        title: []const u8,
        shortcuts: []const w.Shortcut,
    ) u16 {
        _ = self;
        var row = start_row;
        if (row >= surface.size.height) return row;
        w.writeText(surface, ctx, 0, row, title, theme.boldOn(theme.PANEL_SOFT, theme.TEXT));
        row += 1;

        const sorted = w.sortedShortcuts(ctx.arena, shortcuts) catch shortcuts;
        const key_col_width = helpKeyColumnWidth(ctx, sorted);
        for (sorted) |shortcut| {
            if (row >= surface.size.height) break;
            row = drawHelpShortcut(surface, ctx, row, shortcut, key_col_width);
        }
        return row;
    }

    fn helpKeyColumnWidth(ctx: vxfw.DrawContext, shortcuts: []const w.Shortcut) u16 {
        var width: u16 = 0;
        for (shortcuts) |shortcut| {
            width = @max(width, @as(u16, @intCast(ctx.stringWidth(shortcut.key))));
        }
        return width;
    }

    fn drawHelpShortcut(
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        row: u16,
        shortcut: w.Shortcut,
        key_col_width: u16,
    ) u16 {
        if (row >= surface.size.height) return row;
        const key_style = theme.boldOn(theme.PANEL_SOFT, theme.ACCENT_SOFT);
        w.writeText(surface, ctx, 0, row, shortcut.key, key_style);

        const label_col = key_col_width + 3;
        if (label_col >= surface.size.width) return row + 1;
        return drawWrappedHelpLabel(surface, ctx, row, label_col, shortcut.label);
    }

    fn drawWrappedHelpLabel(
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        start_row: u16,
        col: u16,
        text: []const u8,
    ) u16 {
        const max_width = surface.size.width - col;
        if (max_width == 0) return start_row + 1;

        var row = start_row;
        var rest = text;
        while (rest.len > 0 and row < surface.size.height) : (row += 1) {
            const line_len = wrappedLineLen(ctx, rest, max_width);
            w.writeText(
                surface,
                ctx,
                col,
                row,
                rest[0..line_len],
                theme.textOn(theme.PANEL_SOFT, theme.TEXT_SOFT),
            );
            rest = trimLeadingSpaces(rest[line_len..]);
        }
        return @max(row, start_row + 1);
    }

    fn wrappedLineLen(ctx: vxfw.DrawContext, text: []const u8, max_width: u16) usize {
        var iter = ctx.graphemeIterator(text);
        var byte_len: usize = 0;
        var width: u16 = 0;
        var last_space: usize = 0;
        while (iter.next()) |grapheme| {
            const bytes = grapheme.bytes(text);
            const grapheme_width: u16 = @intCast(ctx.stringWidth(bytes));
            if (width + grapheme_width > max_width) {
                if (last_space > 0) return last_space;
                return byte_len;
            }
            byte_len += bytes.len;
            width += grapheme_width;
            if (bytes.len == 1 and bytes[0] == ' ') last_space = byte_len - 1;
        }
        return text.len;
    }

    fn trimLeadingSpaces(text: []const u8) []const u8 {
        var i: usize = 0;
        while (i < text.len and text[i] == ' ') : (i += 1) {}
        return text[i..];
    }

    fn acceptConfirm(self: *Shell, ctx: *vxfw.EventContext) void {
        log.info("confirm_accept action={s}", .{confirmActionName(self.confirm_action)});
        switch (self.confirm_action) {
            .remove_member => {
                self.confirm_error_message = "";
                self.confirm_submitting = true;
                self.submitRemoveMember();
                ctx.consumeAndRedraw();
                return;
            },
            .remove_workspace_member => {
                self.confirm_error_message = "";
                self.confirm_submitting = true;
                self.submitRemoveWorkspaceMember();
                ctx.consumeAndRedraw();
                return;
            },
            .bind_current_directory => {
                self.confirm_error_message = "";
                if (self.commitBindCurrentDirectoryToSelectedWorkspace()) {
                    self.closeConfirmOverlay();
                }
                ctx.consumeAndRedraw();
                return;
            },
            .delete_bundle => {
                self.notifyOp(.info, "Bundle deleted (not yet implemented)");
            },
            .delete_workspace => {
                self.submitDeleteWorkspace();
            },
            .revoke_token => {
                self.sign_out_should_quit = std.mem.eql(u8, self.confirm_message, "sign out");
                api.specs.dispatchFromState(
                    api.specs.EmptyParams,
                    void,
                    api.specs.sign_out,
                    &self.api_state.sign_out_pending,
                    self.api_state,
                    .{},
                );
                self.notifyOp(.loading, "Revoking token...");
            },
            .discard_draft => self.commitDiscardDraft(),
            .quit => {
                ctx.consumeEvent();
                ctx.quit = true;
                return;
            },
            .none => {},
        }
        self.closeConfirmOverlay();
        ctx.consumeAndRedraw();
    }

    fn closeConfirmOverlay(self: *Shell) void {
        self.show_confirm = false;
        self.confirm_action = .none;
        self.confirm_choice = .accept;
        self.confirm_error_message = "";
        self.confirm_submitting = false;
        self.confirm_member_user_id_len = 0;
        self.confirm_workspace_id_len = 0;
    }

    fn cancelConfirm(self: *Shell, ctx: *vxfw.EventContext) void {
        log.info("confirm_cancel action={s}", .{confirmActionName(self.confirm_action)});
        // Releasing here keeps the pending-discard path owned slice
        // from leaking when the user declines the confirm overlay.
        self.releasePendingDiscardTarget();
        self.closeConfirmOverlay();
        self.notifyOp(.warning, "Cancelled.");
        ctx.consumeAndRedraw();
    }

    fn drawConfirmOverlay(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const message = self.confirmBody();
        const message_w: u16 = @intCast(@min(ctx.stringWidth(message), std.math.maxInt(u16)));
        const box_w = @min(@max(@as(u16, 44), message_w +| 8), size.width -| 4);
        const message_lines: u16 = if (self.confirm_action == .bind_current_directory) 3 else 1;
        const box_h: u16 = if (self.confirm_action == .bind_current_directory)
            if (self.confirm_error_message.len > 0) 13 else 10
        else if (self.confirm_error_message.len > 0) 13 else 10;
        const modal = Modal{
            .title = self.confirmTitle(),
            .box_width = box_w,
            .box_height = box_h,
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        const row = result.content_row;

        var button_row = row;
        if (message.len > 0) {
            button_row = w.writeWrappedTextMax(&surface, ctx, col, row, result.content_width, message_lines, message, theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT));
        }

        button_row += 1;
        self.drawConfirmButton(&surface, ctx, col, button_row, self.confirmAcceptLabel(), .accept);
        self.drawConfirmButton(&surface, ctx, col + 14, button_row, "[ Cancel ]", .cancel);

        if (self.confirm_error_message.len > 0) {
            _ = w.writeWrappedTextMax(
                &surface,
                ctx,
                col,
                button_row + 2,
                result.content_width,
                3,
                self.confirm_error_message,
                theme.textOn(theme.PANEL_ALT, theme.DANGER),
            );
        }

        return surface;
    }

    fn confirmTitle(self: *const Shell) []const u8 {
        return switch (self.confirm_action) {
            .bind_current_directory => "Bind Directory",
            .remove_member => "Remove Member",
            .remove_workspace_member => "Remove Member",
            .delete_bundle => "Delete Bundle",
            .delete_workspace => "Delete Workspace",
            .revoke_token => if (std.mem.eql(u8, self.confirm_message, "sign out")) "Sign Out" else "Revoke Token",
            .discard_draft => "Discard Draft",
            .quit => "Quit Clumsies",
            .none => "Confirm",
        };
    }

    fn confirmBody(self: *const Shell) []const u8 {
        if (std.mem.eql(u8, self.confirm_message, "sign out")) return "Revoke the current session token.";
        if (self.confirm_message.len > 0) return self.confirm_message;
        return switch (self.confirm_action) {
            .quit => "Leave the current TUI session.",
            else => "",
        };
    }

    fn confirmAcceptLabel(self: *const Shell) []const u8 {
        if (self.confirm_submitting) return "[ Removing... ]";
        if (std.mem.eql(u8, self.confirm_message, "sign out")) return "[ Sign out ]";
        if (self.confirm_action == .bind_current_directory) return "[ Bind ]";
        return "[ Confirm ]";
    }

    fn drawConfirmButton(
        self: *const Shell,
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        col: u16,
        row: u16,
        label: []const u8,
        choice: ConfirmChoice,
    ) void {
        const active = self.confirm_choice == choice;
        const fg = if (choice == .accept and self.confirm_action != .none)
            theme.DANGER
        else if (active)
            theme.TEXT
        else
            theme.TEXT_SOFT;
        w.writeText(surface, ctx, col, row, label, .{ .fg = fg, .bg = theme.PANEL_ALT, .bold = active });
    }

    fn drawCommentEditorOverlay(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();

        const title = if (self.selectedPr()) |pr|
            try std.fmt.allocPrint(ctx.arena, "Comment on {s}", .{pr.id})
        else
            @as([]const u8, "New Comment");

        const box_w = size.width;
        const box_h: u16 = 8;
        const modal = Modal{
            .title = title,
            .box_width = box_w,
            .box_height = box_h,
            .anchor = .bottom_right,
            .backdrop = .none,
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;

        const input_text = self.review.comment_input_buf[0..self.review.comment_input_len];
        w.drawTextInputSlot(&surface, ctx, result.content_col, result.content_row, result.content_width -| 2, input_text, theme.TEXT, true);

        return surface;
    }

    pub fn openUsernameDialog(self: *Shell) void {
        self.profile_dialog_kind = .username;
        self.profile_dialog_focus = .first;
        self.profile_dialog_submitting = false;
        self.profile_first_len = 0;
        self.profile_second_len = 0;
        self.profile_dialog_message = "";
        self.show_profile_dialog = true;

        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.current_user) |u| {
            const len = @min(u.username.len, self.profile_first_buf.len);
            @memcpy(self.profile_first_buf[0..len], u.username[0..len]);
            self.profile_first_len = len;
        }
    }

    pub fn openPasswordDialog(self: *Shell) void {
        self.profile_dialog_kind = .password;
        self.profile_dialog_focus = .first;
        self.profile_dialog_submitting = false;
        self.profile_first_len = 0;
        self.profile_second_len = 0;
        self.profile_dialog_message = "";
        self.show_profile_dialog = true;
    }

    fn closeProfileDialog(self: *Shell) void {
        self.show_profile_dialog = false;
        self.profile_dialog_submitting = false;
        self.profile_first_len = 0;
        self.profile_second_len = 0;
        self.profile_dialog_message = "";
        @memset(&self.profile_first_buf, 0);
        @memset(&self.profile_second_buf, 0);
    }

    fn handleProfileDialogKey(self: *Shell, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (self.profile_dialog_submitting) {
            if (key.matches(vaxis.Key.escape, .{})) {
                ctx.consumeEvent();
            }
            return;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            self.closeProfileDialog();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.profile_dialog_focus = self.nextProfileFocus();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.profile_dialog_focus == .submit) {
                self.submitProfileDialog();
            } else {
                self.profile_dialog_focus = self.nextProfileFocus();
            }
            ctx.consumeAndRedraw();
            return;
        }

        var input: ?w.TextInput = switch (self.profile_dialog_focus) {
            .first => w.TextInput{ .buf = &self.profile_first_buf, .len = &self.profile_first_len },
            .second => if (self.profileDialogHasSecondField()) w.TextInput{ .buf = &self.profile_second_buf, .len = &self.profile_second_len } else null,
            .submit => null,
        };
        if (input) |*field| {
            switch (field.handleKey(key)) {
                .consumed => ctx.consumeAndRedraw(),
                .submit => {
                    self.profile_dialog_focus = self.nextProfileFocus();
                    ctx.consumeAndRedraw();
                },
                .cancel => {
                    self.closeProfileDialog();
                    ctx.consumeAndRedraw();
                },
                .ignored => {},
            }
        }
    }

    fn profileDialogHasSecondField(self: *const Shell) bool {
        return self.profile_dialog_kind == .password;
    }

    fn nextProfileFocus(self: *const Shell) ProfileDialogFocus {
        return switch (self.profile_dialog_focus) {
            .first => if (self.profileDialogHasSecondField()) .second else .submit,
            .second => .submit,
            .submit => .first,
        };
    }

    fn submitProfileDialog(self: *Shell) void {
        const first = self.profile_first_buf[0..self.profile_first_len];
        const second = self.profile_second_buf[0..self.profile_second_len];
        const req: auth_api.UpdateProfileRequest = switch (self.profile_dialog_kind) {
            .username => blk: {
                if (first.len == 0) {
                    self.profile_dialog_message = "Username is required.";
                    return;
                }
                break :blk .{ .username = first };
            },
            .password => blk: {
                if (first.len == 0 or second.len == 0) {
                    self.profile_dialog_message = "Current and new password are required.";
                    return;
                }
                break :blk .{ .current_password = first, .new_password = second };
            },
        };
        self.profile_dialog_submitting = true;
        self.profile_dialog_message = "";
        api.specs.dispatchFromState(
            auth_api.UpdateProfileRequest,
            auth_api.UpdateProfileResponse,
            api.specs.update_profile,
            &self.api_state.update_profile_pending,
            self.api_state,
            req,
        );
    }

    fn drawProfileDialog(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const title = switch (self.profile_dialog_kind) {
            .username => "Change Username",
            .password => "Change Password",
        };
        const modal = Modal{
            .title = title,
            .box_width = 54,
            .box_height = if (self.profile_dialog_kind == .password) 13 else 11,
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        var row = result.content_row;

        switch (self.profile_dialog_kind) {
            .username => {
                w.writeText(&surface, ctx, col, row, "Username", theme.textOn(theme.PANEL_ALT, theme.MUTED));
                w.drawTextInputSlot(&surface, ctx, col + 12, row, result.content_width -| 14, self.profile_first_buf[0..self.profile_first_len], theme.TEXT, self.profile_dialog_focus == .first and !self.profile_dialog_submitting);
                row += 2;
            },
            .password => {
                const current_mask = try ctx.arena.alloc(u8, self.profile_first_len);
                @memset(current_mask, '*');
                const next_mask = try ctx.arena.alloc(u8, self.profile_second_len);
                @memset(next_mask, '*');
                w.writeText(&surface, ctx, col, row, "Current", theme.textOn(theme.PANEL_ALT, theme.MUTED));
                w.drawTextInputSlot(&surface, ctx, col + 12, row, result.content_width -| 14, current_mask, theme.TEXT, self.profile_dialog_focus == .first and !self.profile_dialog_submitting);
                row += 2;
                w.writeText(&surface, ctx, col, row, "New", theme.textOn(theme.PANEL_ALT, theme.MUTED));
                w.drawTextInputSlot(&surface, ctx, col + 12, row, result.content_width -| 14, next_mask, theme.TEXT, self.profile_dialog_focus == .second and !self.profile_dialog_submitting);
                row += 2;
            },
        }

        const button_label = if (self.profile_dialog_submitting) "[ Saving... ]" else "[ Save ]";
        const button_style = if (self.profile_dialog_focus == .submit and !self.profile_dialog_submitting)
            theme.boldOn(theme.PANEL_ALT, theme.TEXT)
        else
            theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT);
        w.writeText(&surface, ctx, col, row, button_label, button_style);
        if (self.profile_dialog_message.len > 0) {
            _ = w.writeWrappedTextMax(&surface, ctx, col, row + 2, result.content_width, 2, self.profile_dialog_message, theme.textOn(theme.PANEL_ALT, theme.DANGER));
        }
        return surface;
    }

    pub fn openInviteMemberDialog(self: *Shell) void {
        if (!self.ensureMemberManagementAllowed()) return;
        self.show_invite_dialog = true;
        self.invite_dialog_scope = .org;
        self.invite_dialog_kind = .invite;
        self.invite_dialog_focus = .username;
        self.invite_dialog_submitting = false;
        self.invite_username_len = 0;
        self.invite_role_idx = 0;
        self.invite_target_user_id_len = 0;
        self.invite_workspace_id_len = 0;
        self.invite_dialog_message = "";
        self.invite_result_token_len = 0;
        self.invite_token_copied = false;
        @memset(&self.invite_username_buf, 0);
        @memset(&self.invite_target_user_id_buf, 0);
        @memset(&self.invite_workspace_id_buf, 0);
        @memset(&self.invite_result_token_buf, 0);
    }

    pub fn openAddWorkspaceMemberDialog(self: *Shell) void {
        if (!self.ensureWorkspaceMemberManagementAllowed()) return;
        const workspace = self.selectedSettingsWorkspace() orelse {
            self.notifyOp(.warning, "No workspace selected.");
            return;
        };
        self.show_invite_dialog = true;
        self.invite_dialog_scope = .workspace;
        self.invite_dialog_kind = .invite;
        self.invite_dialog_focus = .username;
        self.invite_dialog_submitting = false;
        self.invite_username_len = 0;
        self.invite_role_idx = 0;
        self.invite_target_user_id_len = 0;
        self.invite_workspace_id_len = @min(workspace.ws_id.len, self.invite_workspace_id_buf.len);
        @memcpy(self.invite_workspace_id_buf[0..self.invite_workspace_id_len], workspace.ws_id[0..self.invite_workspace_id_len]);
        self.invite_dialog_message = "";
        self.invite_result_token_len = 0;
        self.invite_token_copied = false;
        @memset(&self.invite_username_buf, 0);
        @memset(&self.invite_target_user_id_buf, 0);
        @memset(&self.invite_result_token_buf, 0);
    }

    pub fn openChangeMemberRoleDialog(self: *Shell) void {
        if (!self.ensureMemberManagementAllowed()) return;
        const member = self.selectedDirectoryMember() orelse {
            self.notifyOp(.warning, "No member selected.");
            return;
        };
        self.show_invite_dialog = true;
        self.invite_dialog_scope = .org;
        self.invite_dialog_kind = .change;
        self.invite_dialog_focus = .role;
        self.invite_dialog_submitting = false;
        self.invite_username_len = @min(member.username.len, self.invite_username_buf.len);
        @memcpy(self.invite_username_buf[0..self.invite_username_len], member.username[0..self.invite_username_len]);
        self.invite_target_user_id_len = @min(member.user_id.len, self.invite_target_user_id_buf.len);
        @memcpy(self.invite_target_user_id_buf[0..self.invite_target_user_id_len], member.user_id[0..self.invite_target_user_id_len]);
        self.invite_role_idx = roleIndexForScope(.org, member.role);
        self.invite_workspace_id_len = 0;
        self.invite_dialog_message = "";
        self.invite_result_token_len = 0;
        self.invite_token_copied = false;
        @memset(&self.invite_result_token_buf, 0);
    }

    pub fn openChangeWorkspaceMemberRoleDialog(self: *Shell) void {
        if (!self.ensureWorkspaceMemberManagementAllowed()) return;
        const workspace = self.selectedSettingsWorkspace() orelse {
            self.notifyOp(.warning, "No workspace selected.");
            return;
        };
        const member = self.selectedWorkspaceMember() orelse {
            self.notifyOp(.warning, "No workspace member selected.");
            return;
        };
        self.show_invite_dialog = true;
        self.invite_dialog_scope = .workspace;
        self.invite_dialog_kind = .change;
        self.invite_dialog_focus = .role;
        self.invite_dialog_submitting = false;
        self.invite_username_len = @min(member.username.len, self.invite_username_buf.len);
        @memcpy(self.invite_username_buf[0..self.invite_username_len], member.username[0..self.invite_username_len]);
        self.invite_target_user_id_len = @min(member.user_id.len, self.invite_target_user_id_buf.len);
        @memcpy(self.invite_target_user_id_buf[0..self.invite_target_user_id_len], member.user_id[0..self.invite_target_user_id_len]);
        self.invite_workspace_id_len = @min(workspace.ws_id.len, self.invite_workspace_id_buf.len);
        @memcpy(self.invite_workspace_id_buf[0..self.invite_workspace_id_len], workspace.ws_id[0..self.invite_workspace_id_len]);
        self.invite_role_idx = roleIndexForScope(.workspace, member.role);
        self.invite_dialog_message = "";
        self.invite_result_token_len = 0;
        self.invite_token_copied = false;
        @memset(&self.invite_result_token_buf, 0);
    }

    pub fn openRemoveMemberConfirm(self: *Shell) void {
        if (!self.ensureMemberManagementAllowed()) return;
        const member = self.selectedDirectoryMember() orelse {
            self.notifyOp(.warning, "No member selected.");
            return;
        };
        self.confirm_member_user_id_len = @min(member.user_id.len, self.confirm_member_user_id_buf.len);
        @memcpy(self.confirm_member_user_id_buf[0..self.confirm_member_user_id_len], member.user_id[0..self.confirm_member_user_id_len]);
        self.confirm_message = std.fmt.allocPrint(self.viewAllocator(), "Remove {s}.", .{member.username}) catch "Remove selected member.";
        self.confirm_error_message = "";
        self.confirm_submitting = false;
        self.confirm_action = .remove_member;
        self.confirm_choice = .accept;
        self.show_confirm = true;
    }

    pub fn openRemoveWorkspaceMemberConfirm(self: *Shell) void {
        if (!self.ensureWorkspaceMemberRemovalAllowed()) return;
        const workspace = self.selectedSettingsWorkspace() orelse {
            self.notifyOp(.warning, "No workspace selected.");
            return;
        };
        const member = self.selectedWorkspaceMember() orelse {
            self.notifyOp(.warning, "No workspace member selected.");
            return;
        };
        self.confirm_workspace_id_len = @min(workspace.ws_id.len, self.confirm_workspace_id_buf.len);
        @memcpy(self.confirm_workspace_id_buf[0..self.confirm_workspace_id_len], workspace.ws_id[0..self.confirm_workspace_id_len]);
        self.confirm_member_user_id_len = @min(member.user_id.len, self.confirm_member_user_id_buf.len);
        @memcpy(self.confirm_member_user_id_buf[0..self.confirm_member_user_id_len], member.user_id[0..self.confirm_member_user_id_len]);
        self.confirm_message = std.fmt.allocPrint(self.viewAllocator(), "Remove {s}.", .{member.username}) catch "Remove selected member.";
        self.confirm_error_message = "";
        self.confirm_submitting = false;
        self.confirm_action = .remove_workspace_member;
        self.confirm_choice = .accept;
        self.show_confirm = true;
    }

    fn closeInviteMemberDialog(self: *Shell) void {
        self.show_invite_dialog = false;
        self.invite_dialog_submitting = false;
        self.invite_username_len = 0;
        self.invite_role_idx = 0;
        self.invite_target_user_id_len = 0;
        self.invite_workspace_id_len = 0;
        self.invite_dialog_message = "";
        self.invite_result_token_len = 0;
        self.invite_token_copied = false;
        @memset(&self.invite_username_buf, 0);
        @memset(&self.invite_target_user_id_buf, 0);
        @memset(&self.invite_workspace_id_buf, 0);
        @memset(&self.invite_result_token_buf, 0);
    }

    fn handleInviteDialogKey(self: *Shell, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (self.invite_dialog_submitting) return;
        if (key.matches(vaxis.Key.escape, .{})) {
            self.closeInviteMemberDialog();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.invite_dialog_focus = self.nextInviteFocus();
            ctx.consumeAndRedraw();
            return;
        }
        if (self.invite_result_token_len > 0 and key.matches('y', .{})) {
            self.copyInviteToken();
            ctx.consumeAndRedraw();
            return;
        }
        if (self.invite_dialog_focus == .role and (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{}) or key.matches(vaxis.Key.right, .{}) or key.matches('l', .{}) or key.matches(' ', .{}))) {
            self.toggleInviteRole();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.invite_dialog_focus == .submit) {
                self.submitMemberRoleDialog();
            } else if (self.invite_dialog_focus == .role and self.invite_dialog_kind == .change) {
                self.submitMemberRoleDialog();
            } else {
                self.invite_dialog_focus = self.nextInviteFocus();
            }
            ctx.consumeAndRedraw();
            return;
        }

        var input: ?w.TextInput = switch (self.invite_dialog_focus) {
            .username => if (self.invite_dialog_kind == .invite) w.TextInput{ .buf = &self.invite_username_buf, .len = &self.invite_username_len } else null,
            .role => null,
            .submit => null,
        };
        if (input) |*field| {
            switch (field.handleKey(key)) {
                .consumed => {
                    self.invite_dialog_message = "";
                    self.invite_result_token_len = 0;
                    ctx.consumeAndRedraw();
                },
                .submit => {
                    self.invite_dialog_focus = self.nextInviteFocus();
                    ctx.consumeAndRedraw();
                },
                .cancel => {
                    self.closeInviteMemberDialog();
                    ctx.consumeAndRedraw();
                },
                .ignored => {},
            }
        }
    }

    fn nextInviteFocus(self: *const Shell) InviteDialogFocus {
        if (self.invite_dialog_kind == .change) {
            return switch (self.invite_dialog_focus) {
                .username => .role,
                .role => .submit,
                .submit => .role,
            };
        }
        return switch (self.invite_dialog_focus) {
            .username => .role,
            .role => .submit,
            .submit => .username,
        };
    }

    fn submitMemberRoleDialog(self: *Shell) void {
        const username = self.invite_username_buf[0..self.invite_username_len];
        const role = self.roleOptions()[self.invite_role_idx];
        if (username.len == 0) {
            self.invite_dialog_message = "Username is required.";
            return;
        }
        self.invite_dialog_submitting = true;
        self.invite_dialog_message = "";
        self.invite_result_token_len = 0;
        self.invite_token_copied = false;
        if (self.invite_dialog_scope == .workspace) {
            const ws_id = self.invite_workspace_id_buf[0..self.invite_workspace_id_len];
            if (ws_id.len == 0) {
                self.invite_dialog_submitting = false;
                self.invite_dialog_message = "No workspace selected.";
                return;
            }
            const user_id = if (self.invite_dialog_kind == .invite)
                self.resolveOrgUserIdByUsername(username) orelse {
                    self.invite_dialog_submitting = false;
                    self.invite_dialog_message = "User must already belong to the organization.";
                    return;
                }
            else
                self.invite_target_user_id_buf[0..self.invite_target_user_id_len];
            if (user_id.len == 0) {
                self.invite_dialog_submitting = false;
                self.invite_dialog_message = "No workspace member selected.";
                return;
            }
            api.specs.dispatchFromState(
                api.specs.WorkspaceMemberRoleParams,
                void,
                if (self.invite_dialog_kind == .invite) api.specs.add_workspace_member else api.specs.change_workspace_member_role,
                if (self.invite_dialog_kind == .invite) &self.api_state.add_workspace_member_pending else &self.api_state.change_workspace_member_role_pending,
                self.api_state,
                .{ .ws_id = ws_id, .user_id = user_id, .role = role },
            );
            return;
        }
        switch (self.invite_dialog_kind) {
            .invite => api.specs.dispatchFromState(
                auth_api.InviteMemberRequest,
                auth_api.InviteMemberResponse,
                api.specs.invite_member,
                &self.api_state.invite_member_pending,
                self.api_state,
                .{ .username = username, .role = role },
            ),
            .change => {
                const user_id = self.invite_target_user_id_buf[0..self.invite_target_user_id_len];
                if (user_id.len == 0) {
                    self.invite_dialog_submitting = false;
                    self.invite_dialog_message = "No member selected.";
                    return;
                }
                api.specs.dispatchFromState(
                    api.specs.ChangeMemberRoleParams,
                    void,
                    api.specs.change_member_role,
                    &self.api_state.change_member_role_pending,
                    self.api_state,
                    .{ .user_id = user_id, .role = role },
                );
            },
        }
    }

    fn drawInviteDialog(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const title = if (self.invite_dialog_scope == .workspace)
            if (self.invite_dialog_kind == .invite) "Add Workspace Member" else "Change Workspace Role"
        else if (self.invite_dialog_kind == .invite) "Invite Member" else "Change Role";
        const message_rows: u16 = if (self.invite_dialog_message.len > 0 and self.invite_result_token_len == 0) 3 else 0;
        const base_height: u16 = if (self.invite_result_token_len > 0) 15 else if (self.invite_dialog_kind == .change) 11 else 13;
        const modal = Modal{
            .title = title,
            .box_width = 62,
            .box_height = base_height + message_rows,
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        var row = result.content_row;

        if (self.invite_dialog_kind == .invite) {
            const label = if (self.invite_dialog_scope == .workspace) "User" else "Username";
            w.writeText(&surface, ctx, col, row, label, theme.textOn(theme.PANEL_ALT, theme.MUTED));
            w.drawTextInputSlot(&surface, ctx, col + 12, row, result.content_width -| 14, self.invite_username_buf[0..self.invite_username_len], theme.TEXT, self.invite_dialog_focus == .username and !self.invite_dialog_submitting);
            row += 2;
        } else {
            w.writeText(&surface, ctx, col, row, "Member", theme.textOn(theme.PANEL_ALT, theme.MUTED));
            w.writeTextMax(&surface, ctx, col + 12, row, result.content_width -| 14, self.invite_username_buf[0..self.invite_username_len], theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT));
            row += 2;
        }
        w.writeText(&surface, ctx, col, row, "Role", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        self.drawRoleSelector(&surface, ctx, col + 12, row, result.content_width -| 12, self.invite_dialog_focus == .role and !self.invite_dialog_submitting);
        row += 2;

        const button_label = if (self.invite_dialog_submitting)
            if (self.invite_dialog_kind == .invite) "[ Inviting... ]" else "[ Saving... ]"
        else if (self.invite_dialog_kind == .invite)
            "[ Invite ]"
        else
            "[ Save ]";
        const button_style = if (self.invite_dialog_focus == .submit and !self.invite_dialog_submitting)
            theme.boldOn(theme.PANEL_ALT, theme.TEXT)
        else
            theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT);
        w.writeText(&surface, ctx, col, row, button_label, button_style);
        row += 2;

        if (self.invite_result_token_len > 0) {
            w.writeText(&surface, ctx, col, row, "Invite token", theme.textOn(theme.PANEL_ALT, theme.MUTED));
            const copy_hint = if (self.invite_token_copied) "copied" else "y copy token";
            const copy_hint_w: u16 = @intCast(@min(ctx.stringWidth(copy_hint), result.content_width));
            const copy_hint_style = if (self.invite_token_copied)
                theme.textOn(theme.PANEL_ALT, theme.OK)
            else
                theme.textOn(theme.PANEL_ALT, theme.MUTED);
            w.writeText(&surface, ctx, col + result.content_width -| copy_hint_w, row, copy_hint, copy_hint_style);
            row += 1;
            _ = w.writeWrappedTextMax(&surface, ctx, col, row, result.content_width, 2, self.invite_result_token_buf[0..self.invite_result_token_len], theme.textOn(theme.PANEL_ALT, theme.TEXT));
            row += 3;
        }
        if (self.invite_dialog_message.len > 0 and self.invite_result_token_len == 0) {
            const max_rows: u16 = if (row + 1 < surface.size.height) @min(3, surface.size.height - row - 1) else 0;
            if (max_rows > 0) {
                _ = w.writeWrappedTextMax(&surface, ctx, col, row, result.content_width, max_rows, self.invite_dialog_message, theme.textOn(theme.PANEL_ALT, theme.DANGER));
            }
        }
        return surface;
    }

    fn copyInviteToken(self: *Shell) void {
        const token = self.invite_result_token_buf[0..self.invite_result_token_len];
        if (token.len == 0) return;
        workspace_panel.copyTextToClipboard(self.api_state.backing_allocator, token);
        self.invite_token_copied = true;
    }

    fn drawRoleSelector(
        self: *const Shell,
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        col: u16,
        row: u16,
        max_width: u16,
        active: bool,
    ) void {
        var cursor = col;
        const end_col = col + max_width;
        for (self.roleOptions(), 0..) |role, i| {
            if (i > 0) {
                if (cursor + 2 >= end_col) return;
                w.writeText(surface, ctx, cursor, row, "  ", theme.textOn(theme.PANEL_ALT, theme.MUTED));
                cursor += 2;
            }
            const selected = i == self.invite_role_idx;
            const mark = if (selected) "[*] " else "[ ] ";
            const item_w: u16 = @intCast(ctx.stringWidth(mark) + ctx.stringWidth(role));
            if (cursor + item_w > end_col) return;
            const style = if (active and selected)
                theme.boldOn(theme.PANEL_ALT, theme.TEXT)
            else if (selected)
                theme.textOn(theme.PANEL_ALT, theme.TEXT)
            else
                theme.textOn(theme.PANEL_ALT, theme.TEXT_SOFT);
            w.writeText(surface, ctx, cursor, row, mark, style);
            cursor += @intCast(ctx.stringWidth(mark));
            w.writeText(surface, ctx, cursor, row, role, style);
            cursor += @intCast(ctx.stringWidth(role));
        }
        if (active) {
            const hint = "  Space switch";
            const hint_w: u16 = @intCast(ctx.stringWidth(hint));
            if (cursor + hint_w <= end_col) {
                w.writeText(surface, ctx, cursor, row, hint, theme.textOn(theme.PANEL_ALT, theme.MUTED));
            }
        }
    }

    fn toggleInviteRole(self: *Shell) void {
        self.invite_role_idx = (self.invite_role_idx + 1) % self.roleOptions().len;
        self.invite_dialog_message = "";
    }

    fn roleOptions(self: *const Shell) []const []const u8 {
        return switch (self.invite_dialog_scope) {
            .org => &ORG_ROLE_OPTIONS,
            .workspace => &WORKSPACE_ROLE_OPTIONS,
        };
    }

    fn roleIndexForScope(scope: MemberDialogScope, role: []const u8) usize {
        const options = switch (scope) {
            .org => &ORG_ROLE_OPTIONS,
            .workspace => &WORKSPACE_ROLE_OPTIONS,
        };
        for (options, 0..) |candidate, i| {
            if (std.mem.eql(u8, role, candidate)) return i;
        }
        return 0;
    }

    fn selectedDirectoryMember(self: *Shell) ?api.model.DirectoryMember {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const dir = self.api_state.directory orelse return null;
        if (dir.members.len == 0) return null;
        const idx = @min(self.settings.content_sel, dir.members.len - 1);
        return dir.members[idx];
    }

    fn selectedWorkspaceMember(self: *Shell) ?api.model.WorkspaceMemberData {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const user = self.api_state.current_user orelse return null;
        if (user.workspaces.len == 0) return null;
        const ws_idx = @min(self.settings.content_sel, user.workspaces.len - 1);
        const ws_id = user.workspaces[ws_idx].ws_id;
        const members = self.api_state.workspace_members_cache.lookup(.{ .value = ws_id }) orelse return null;
        if (members.len == 0) return null;
        const member_idx = @min(self.settings.workspace_member_sel, members.len - 1);
        return members[member_idx];
    }

    fn resolveOrgUserIdByUsername(self: *Shell, username: []const u8) ?[]const u8 {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const dir = self.api_state.directory orelse return null;
        for (dir.members) |member| {
            if (std.mem.eql(u8, member.username, username)) return member.user_id;
        }
        return null;
    }

    fn submitRemoveMember(self: *Shell) void {
        const user_id = self.confirm_member_user_id_buf[0..self.confirm_member_user_id_len];
        if (user_id.len == 0) {
            self.notifyOp(.warning, "No member selected.");
            return;
        }
        api.specs.dispatchFromState(
            api.specs.MemberIdParams,
            void,
            api.specs.remove_member,
            &self.api_state.remove_member_pending,
            self.api_state,
            .{ .user_id = user_id },
        );
        self.notifyOp(.loading, "Removing member...");
    }

    fn submitRemoveWorkspaceMember(self: *Shell) void {
        const ws_id = self.confirm_workspace_id_buf[0..self.confirm_workspace_id_len];
        const user_id = self.confirm_member_user_id_buf[0..self.confirm_member_user_id_len];
        if (ws_id.len == 0 or user_id.len == 0) {
            self.notifyOp(.warning, "No workspace member selected.");
            return;
        }
        api.specs.dispatchFromState(
            api.specs.WorkspaceMemberIdParams,
            void,
            api.specs.remove_workspace_member,
            &self.api_state.remove_workspace_member_pending,
            self.api_state,
            .{ .ws_id = ws_id, .user_id = user_id },
        );
        self.notifyOp(.loading, "Removing workspace member...");
    }

    fn drawTooSmall(self: *Shell, ctx: vxfw.DrawContext, size: vxfw.Size) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        w.fillSurface(&surface, theme.PANEL);
        w.writeText(&surface, ctx, 1, 0, "clumsies", theme.boldOn(theme.PANEL, theme.ACCENT));
        w.writeText(&surface, ctx, 2, 2, "Terminal too small. Need at least 96x24.", theme.fgBold(theme.TEXT));
        w.writeText(&surface, ctx, 2, 4, "Resize the terminal, or press q / Ctrl-C to exit.", theme.fg(theme.TEXT_SOFT));
        return surface;
    }

    fn contextHint(self: *const Shell) []const u8 {
        if (self.show_help) return "Keyboard reference drawer.";
        return switch (self.selected_module) {
            .dashboard => "Live interaction rounds and attestation closure.",
            .artifact => "Bundle facet, rule list, and passive preview.",
            .workspace => "Workspace list and sync status detail.",
            .review => "Pull request review queue.",
            .analysis => "Rule and member aggregates.",
        };
    }

    fn ensureDraftsCacheForActiveWorkspace(self: *Shell) void {
        const ws_id = self.activeWsId() orelse return;
        if (self.drafts.cache_ws_id) |cached| {
            if (std.mem.eql(u8, cached, ws_id)) return;
        }
        self.refreshDraftsCache();
    }

    /// Reload the active workspace's `drafts/index.json` into the
    /// per-category lookup maps and recompute totals. Called when the
    /// selected workspace changes and after draft edit ops (`e`, `D`,
    /// `m`). No-op when no workspace is active — draft features just
    /// stay silent rather than surface an error.
    pub fn refreshDraftsCache(self: *Shell) void {
        self.drafts.by_rule_path = .{};
        self.drafts.by_context_path = .{};
        self.drafts.by_meta_prompt_path = .{};
        self.drafts.by_rule_draft_path = .{};
        self.drafts.by_context_draft_path = .{};
        self.drafts.by_meta_prompt_draft_path = .{};
        self.drafts.by_rule_local_id = .{};
        self.drafts.by_context_local_id = .{};
        self.drafts.by_meta_prompt_local_id = .{};
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
        self.drafts.create_rule_paths = &.{};
        self.drafts.create_context_paths = &.{};
        self.drafts.total = 0;
        self.drafts.cache_ws_id = null;
        self.drafts.index_size = 0;
        self.drafts.index_mtime = 0;
        const ws_id = self.activeWsId() orelse return;
        self.drafts.cache_seeded = true;
        _ = self.drafts.arena.reset(.retain_capacity);
        const arena = self.drafts.arena.allocator();
        const api_alloc = self.api_state.allocator();
        self.drafts.cache_ws_id = api_alloc.dupe(u8, ws_id) catch ws_id;

        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return;
        const signature = draftIndexSignature(arena, ws_dir);
        self.drafts.index_size = signature.size;
        self.drafts.index_mtime = signature.mtime;
        var index = drafts_mod.loadIndex(arena, ws_dir) catch return;
        defer index.deinit(arena);

        var create_rules: std.ArrayListUnmanaged([]const u8) = .empty;
        var create_contexts: std.ArrayListUnmanaged([]const u8) = .empty;

        for (index.entries.items) |entry| {
            switch (entry.status) {
                .applied, .declined => continue,
                else => {},
            }
            self.drafts.total += 1;

            // Lookup map keys can live in drafts_arena: the maps are
            // rebuilt from scratch on every refresh, so no key is
            // ever observed after its arena reset.
            const key_src = entry.current_path orelse entry.draft_path;
            const key = arena.dupe(u8, key_src) catch continue;
            const target_map = switch (entry.category) {
                .rule => &self.drafts.by_rule_path,
                .context => &self.drafts.by_context_path,
                .meta_prompt => &self.drafts.by_meta_prompt_path,
            };
            target_map.put(arena, key, entry.status) catch {};
            const draft_path = arena.dupe(u8, entry.draft_path) catch continue;
            const draft_path_map = switch (entry.category) {
                .rule => &self.drafts.by_rule_draft_path,
                .context => &self.drafts.by_context_draft_path,
                .meta_prompt => &self.drafts.by_meta_prompt_draft_path,
            };
            draft_path_map.put(arena, key, draft_path) catch {};
            if (entry.operation == .create and entry.category != .meta_prompt) {
                const local_id = entry.local_temp_id orelse continue;
                const local_key = arena.dupe(u8, key_src) catch continue;
                const local_value = arena.dupe(u8, local_id) catch continue;
                const local_map = switch (entry.category) {
                    .rule => &self.drafts.by_rule_local_id,
                    .context => &self.drafts.by_context_local_id,
                    .meta_prompt => unreachable,
                };
                local_map.put(arena, local_key, local_value) catch {};

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

        self.drafts.create_rule_paths = create_rules.toOwnedSlice(api_alloc) catch &.{};
        self.drafts.create_context_paths = create_contexts.toOwnedSlice(api_alloc) catch &.{};
    }

    fn refreshDraftsCacheIfChanged(self: *Shell) void {
        if (self.tick_count -% self.drafts.last_index_check_tick < 10) return;
        self.drafts.last_index_check_tick = self.tick_count;

        const ws_id = self.activeWsId() orelse return;
        const alloc = self.api_state.backing_allocator;
        const ws_dir = workspace_config.getWsDir(alloc, ws_id) catch return;
        defer alloc.free(ws_dir);
        const signature = draftIndexSignature(alloc, ws_dir);
        if (signature.size == self.drafts.index_size and
            signature.mtime == self.drafts.index_mtime)
        {
            return;
        }

        self.refreshDraftsCache();
        workspace_panel.syncWsRows(self);
        artifact_panel.syncArtifactTree(self);
    }

    const DraftIndexSignature = struct {
        size: u64 = 0,
        mtime: i128 = 0,
    };

    fn draftIndexSignature(allocator: std.mem.Allocator, ws_dir: []const u8) DraftIndexSignature {
        const index_path = std.fs.path.join(allocator, &.{ ws_dir, "drafts", "index.json" }) catch return .{};
        defer allocator.free(index_path);

        const file = std.fs.openFileAbsolute(index_path, .{}) catch return .{};
        defer file.close();

        const stat = file.stat() catch return .{};
        return .{ .size = stat.size, .mtime = stat.mtime };
    }

    pub fn draftStatusFor(
        self: *const Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?drafts_mod.DraftStatus {
        return switch (category) {
            .rule => self.drafts.by_rule_path.get(path),
            .context => self.drafts.by_context_path.get(path),
            .meta_prompt => self.drafts.by_meta_prompt_path.get(path),
        };
    }

    pub fn draftLocalIdFor(
        self: *const Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?[]const u8 {
        return switch (category) {
            .rule => self.drafts.by_rule_local_id.get(path),
            .context => self.drafts.by_context_local_id.get(path),
            .meta_prompt => self.drafts.by_meta_prompt_local_id.get(path),
        };
    }

    fn draftPathForSelection(
        self: *const Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) []const u8 {
        return switch (category) {
            .rule => self.drafts.by_rule_draft_path.get(path),
            .context => self.drafts.by_context_draft_path.get(path),
            .meta_prompt => self.drafts.by_meta_prompt_draft_path.get(path),
        } orelse path;
    }

    /// Read the current draft bytes for a file, allocated in
    /// view_arena so the caller can use the slice for the remainder of
    /// the current frame. Returns null when no draft is tracked or
    /// the file is missing / unreadable. Both Artifact and Workspace
    /// content panels call this to overlay the working copy on top of
    /// the authoritative cache.
    pub fn draftContentForView(
        self: *Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?[]const u8 {
        const ws_id = self.activeWsId() orelse return null;
        const has_draft = switch (category) {
            .rule => self.drafts.by_rule_path.contains(path),
            .context => self.drafts.by_context_path.contains(path),
            .meta_prompt => self.drafts.by_meta_prompt_path.contains(path),
        };
        if (!has_draft) return null;
        const draft_path = self.draftPathForSelection(category, path);
        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return null;
        return drafts_mod.readDraftFile(arena, ws_dir, category, draft_path) catch null;
    }

    /// Derive the draft target from the currently focused module and
    /// its selection. Returns null when the active module doesn't have
    /// an editable selection (e.g. no workspace bound or a directory
    /// row is highlighted). Workspace context create-draft rows remain
    /// editable even before hub detail has loaded.
    pub fn selectedDraftTarget(self: *Shell) ?DraftTarget {
        const ws_id = self.activeWsId() orelse return null;
        switch (self.selected_module) {
            .artifact => {
                const rules = self.getRules();
                if (self.artifact.selected_rule < rules.len) {
                    const rule = &rules[self.artifact.selected_rule];
                    return .{
                        .ws_id = ws_id,
                        .category = self.artifactCategoryForPath(rule.path),
                        .path = rule.path,
                        .rule_id = self.lookupRuleId(rule.path),
                    };
                }
                // Virtual row: a local create-op draft that has no
                // server-side rule yet. The index is offset by
                // `rules.len` so we can recover the create-draft
                // path from drafts_create_rule_paths.
                const k = self.artifact.selected_rule - rules.len;
                if (k >= self.drafts.create_rule_paths.len) return null;
                return .{
                    .ws_id = ws_id,
                    .category = .rule,
                    .path = self.drafts.create_rule_paths[k],
                };
            },
            .workspace => {
                const live = self.workspaceDetailForView(ws_id);
                const selection = self.currentWorkspaceFileSelection(live) orelse return null;
                return switch (selection) {
                    .context => |c| .{
                        .ws_id = ws_id,
                        .category = .context,
                        .path = c.path,
                        .context_id = c.context_id,
                    },
                    .rule => |r| .{
                        .ws_id = ws_id,
                        .category = r.category,
                        .path = r.path,
                        .rule_id = if (r.is_create_draft) null else self.lookupRuleId(r.path),
                    },
                };
            },
            else => return null,
        }
    }

    pub fn selectedContentId(self: *Shell) ?[]const u8 {
        switch (self.selected_module) {
            .artifact => {
                const rules = self.getRules();
                if (self.artifact.selected_rule >= rules.len) return null;
                return self.lookupRuleId(rules[self.artifact.selected_rule].path);
            },
            .workspace => {
                const ws_id = self.activeWsId() orelse return null;
                const live = self.workspaceDetailForView(ws_id);
                const selection = self.currentWorkspaceFileSelection(live) orelse return null;
                return switch (selection) {
                    .context => |c| c.context_id,
                    .rule => |r| r.rule_id,
                };
            },
            else => return null,
        }
    }

    pub fn copySelectedContentId(self: *Shell) bool {
        const id = self.selectedContentId() orelse return false;
        workspace_panel.copyTextToClipboard(self.api_state.backing_allocator, id);
        self.notifyOp(.success, "Copied id to clipboard.");
        return true;
    }

    /// Entry point for the `e` key. Finds or creates a modify-draft for
    /// the currently selected file, shells out to $EDITOR, then
    /// refreshes caches so the right panel picks up the new draft
    /// bytes on the next render.
    pub fn editSelectedDraft(self: *Shell) void {
        // Refresh must run BEFORE target capture. refreshDraftsCache
        // resets drafts_arena, which backs the virtual-row path
        // slices in drafts_create_*_paths. A target captured before
        // refresh for a create-op draft would point into freed arena
        // memory on the next access. Same reasoning applies to every
        // draft handler below.
        self.refreshDraftsCache();
        const target = self.selectedDraftTarget() orelse {
            self.notifyOp(.warning, "No editable selection.");
            return;
        };
        self.editDraft(target);
    }

    fn editDraft(self: *Shell, target: DraftTarget) void {
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch {
            self.notifyOp(.failure, "Could not resolve workspace directory.");
            return;
        };
        defer alloc.free(ws_dir);

        const base_content = self.seedContentForTarget(target) orelse "";
        if (self.draftStatusFor(target.category, target.path) == null) {
            const seed_hash = util_hash.contentHash(base_content);
            drafts_mod.createDraft(alloc, ws_dir, .{
                .category = target.category,
                .operation = .modify,
                .draft_path = target.path,
                .current_path = target.path,
                .rule_id = target.rule_id,
                .context_id = target.context_id,
                .base_hash = seed_hash[0..],
            }, base_content) catch |err| switch (err) {
                // Index and in-memory map raced (e.g., the user ran a
                // previous session that left entries, then restarted
                // before current_user had a chance to re-seed the
                // map). The draft genuinely exists on disk — just
                // open it instead of aborting.
                error.DraftAlreadyExists => {},
                else => {
                    self.notifyOp(.failure, @errorName(err));
                    return;
                },
            };
        }

        const draft_path = self.draftPathForSelection(target.category, target.path);
        const draft_abs = std.fs.path.join(
            alloc,
            &.{ ws_dir, "drafts", @tagName(target.category), draft_path },
        ) catch return;
        defer alloc.free(draft_abs);

        const result = editor_host.editFile(
            alloc,
            &self.app.vx,
            &self.app.tty,
            self.env_map,
            draft_abs,
        ) catch |err| {
            self.notifyOp(.failure, @errorName(err));
            return;
        };
        switch (result) {
            .completed => {
                const unchanged = drafts_mod.discardUnchangedModifyDraft(
                    alloc,
                    ws_dir,
                    target.category,
                    draft_path,
                    base_content,
                ) catch |err| {
                    self.notifyOp(.failure, @errorName(err));
                    self.refreshDraftsCache();
                    return;
                };
                if (unchanged) {
                    self.notifyOp(.success, "No changes.");
                } else {
                    self.notifyOp(.success, "Draft saved.");
                }
            },
            .failed => self.notifyOp(.failure, "Editor exited non-zero."),
            .editor_not_found => self.notifyOp(.failure, "No $EDITOR resolved."),
            .spawn_failed => self.notifyOp(.failure, "Editor spawn failed."),
        }
        self.refreshDraftsCache();
    }

    /// Seed a modify draft from the base bytes used by the active
    /// editing surface. Workspace edits use the materialized local
    /// cache so remote awareness does not silently rebase a draft.
    fn seedContentForTarget(self: *Shell, target: DraftTarget) ?[]const u8 {
        if (self.selected_module == .workspace) {
            return switch (target.category) {
                .rule, .meta_prompt => self.localArtifactRuleBody(target.category, target.path),
                .context => self.localWorkspaceContextBody(target.ws_id, target.path),
            };
        }
        return switch (target.category) {
            .rule => self.cachedRuleBody(target.path),
            .context => self.cachedWorkspaceContextBody(target.ws_id, target.path),
            .meta_prompt => self.cachedArtifactRuleBody(.meta_prompt, target.path),
        };
    }

    /// Arms the confirm overlay for a discard. The actual discard runs
    /// from the confirm `y` branch so it matches the rest of the
    /// destructive-operation UX.
    pub fn requestDiscardSelectedDraft(self: *Shell) void {
        self.refreshDraftsCache();
        const target = self.selectedDraftTarget() orelse {
            self.notifyOp(.warning, "No draft to discard.");
            return;
        };
        if (self.draftStatusFor(target.category, target.path) == null) {
            self.notifyOp(.warning, "No draft to discard.");
            return;
        }
        // Target may have been captured from drafts_arena (virtual
        // rows) — dup its path into the api_state allocator so the
        // confirm overlay can outlive any subsequent refresh call
        // without reading freed memory.
        self.releasePendingDiscardTarget();
        const draft_path = self.draftPathForSelection(target.category, target.path);
        const path_copy = self.api_state.allocator().dupe(u8, draft_path) catch {
            self.notifyOp(.failure, "Out of memory capturing draft target.");
            return;
        };
        self.drafts.pending_discard_target = .{
            .ws_id = target.ws_id,
            .category = target.category,
            .path = path_copy,
            .rule_id = target.rule_id,
            .context_id = target.context_id,
        };
        self.drafts.pending_discard_path_owned = path_copy;
        self.confirm_message = path_copy;
        self.confirm_action = .discard_draft;
        self.show_confirm = true;
    }

    /// Free the duped strings backing pending_discard_target, if any.
    /// Safe to call with no pending discard.
    fn releasePendingDiscardTarget(self: *Shell) void {
        if (self.drafts.pending_discard_path_owned) |p| {
            self.api_state.allocator().free(p);
            self.drafts.pending_discard_path_owned = null;
        }
        self.drafts.pending_discard_target = null;
    }

    fn releasePendingPrAction(self: *Shell) void {
        const alloc = self.api_state.allocator();
        if (self.drafts.pending_pr_action_path_owned) |p| {
            alloc.free(p);
            self.drafts.pending_pr_action_path_owned = null;
        }
        if (self.drafts.pending_pr_action_ws_id_owned) |ws_id| {
            alloc.free(ws_id);
            self.drafts.pending_pr_action_ws_id_owned = null;
        }
        self.drafts.pending_pr_action = null;
    }

    fn capturePendingPrAction(self: *Shell, pr: data.PullRequestEntry, action: []const u8) bool {
        const ws_id_src = pr.workspace_id orelse self.activeWsId() orelse {
            self.releasePendingPrAction();
            return true;
        };
        const status_on_success: drafts_mod.DraftStatus = if (std.mem.eql(u8, action, "reject"))
            .declined
        else
            .applied;
        const category: drafts_mod.DraftCategory = switch (pr.target_kind) {
            .context => .context,
            .rule => .rule,
            .mpf => .meta_prompt,
            .bundle => return false,
        };

        self.releasePendingPrAction();
        const alloc = self.api_state.allocator();
        const ws_id_copy = alloc.dupe(u8, ws_id_src) catch {
            self.notifyOp(.failure, "Out of memory capturing PR action.");
            return false;
        };
        const path_copy = alloc.dupe(u8, pr.target_path) catch {
            alloc.free(ws_id_copy);
            self.notifyOp(.failure, "Out of memory capturing PR action.");
            return false;
        };

        self.drafts.pending_pr_action_ws_id_owned = ws_id_copy;
        self.drafts.pending_pr_action_path_owned = path_copy;
        self.drafts.pending_pr_action = PendingPrAction{
            .target = .{
                .ws_id = ws_id_copy,
                .category = category,
                .path = path_copy,
            },
            .status_on_success = status_on_success,
        };
        return true;
    }

    fn shouldSettlePrActionAfterWorkspaceRefresh(self: *const Shell) bool {
        const pending = self.drafts.pending_pr_action orelse return false;
        return pending.target.category == .context and pending.status_on_success == .applied;
    }

    fn settlePendingWorkspacePrAction(self: *Shell, ws_id: []const u8) void {
        const pending = self.drafts.pending_pr_action orelse return;
        if (pending.target.category != .context) return;
        if (pending.status_on_success != .applied) return;
        if (!std.mem.eql(u8, pending.target.ws_id, ws_id)) return;
        self.settlePendingPrActionDraft();
    }

    fn returnReviewDetailToListAfterPrAction(self: *Shell) void {
        if (self.selected_module != .review) return;
        if (self.review.mode != .detail) return;
        self.review.mode = .list;
        self.review.focus = .queue;
    }

    fn settlePendingPrActionDraft(self: *Shell) void {
        const pending = self.drafts.pending_pr_action orelse return;
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, pending.target.ws_id) catch {
            self.releasePendingPrAction();
            return;
        };
        defer alloc.free(ws_dir);

        _ = drafts_mod.transitionDraftStatus(
            alloc,
            ws_dir,
            pending.target.category,
            self.draftPathForSelection(pending.target.category, pending.target.path),
            .in_review,
            pending.status_on_success,
        ) catch {};
        self.releasePendingPrAction();
        self.refreshDraftsCache();
        workspace_panel.syncWsRows(self);
        artifact_panel.syncArtifactTree(self);
    }

    fn commitDiscardDraft(self: *Shell) void {
        const target = self.drafts.pending_discard_target orelse return;
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch return;
        defer alloc.free(ws_dir);
        drafts_mod.discardDraft(alloc, ws_dir, target.category, target.path) catch |err| {
            self.notifyOp(.failure, @errorName(err));
            return;
        };
        self.notifyOp(.success, "Draft discarded.");
        self.releasePendingDiscardTarget();
        self.refreshDraftsCache();
        if (self.selected_module == .workspace) {
            self.workspace.hide_diff = false;
        }
    }

    /// Handler for the `p` key. Opens the PR Composer when the
    /// selected file has a local draft. The composer is intentionally
    /// single-op for the initial cut — multi-draft select is deferred
    /// to a follow-up.
    pub fn openPrComposer(self: *Shell) void {
        self.refreshDraftsCache();
        const target = self.selectedDraftTarget() orelse {
            self.notifyOp(.warning, "No editable selection.");
            return;
        };
        const status = self.draftStatusFor(target.category, target.path) orelse {
            self.notifyOp(.warning, "No draft for this selection.");
            return;
        };
        if (status != .draft) {
            self.notifyOp(.warning, "Draft is not editable.");
            return;
        }
        // Composer state persists across frames while the overlay is
        // open; between open and submit the user might never trigger
        // another refresh, but a future code path (tick, background
        // consumer) could. Dup path into the stable allocator so the
        // overlay draw and submit paths cannot read freed bytes.
        self.releaseComposerTarget();
        const path_copy = self.api_state.allocator().dupe(u8, target.path) catch {
            self.notifyOp(.failure, "Out of memory opening composer.");
            return;
        };
        self.drafts.pr_composer_target = .{
            .ws_id = target.ws_id,
            .category = target.category,
            .path = path_copy,
            .rule_id = target.rule_id,
            .context_id = target.context_id,
        };
        self.drafts.pr_composer_path_owned = path_copy;
        // Capture the draft's operation so the overlay can label
        // `op:` correctly (create / modify / rename / delete). Falls
        // back to .modify when the index lookup fails, which is the
        // historical default and keeps the overlay usable if the
        // draft file was tampered with out of band.
        self.drafts.pr_composer_operation = self.lookupDraftOperation(target) orelse .modify;
        self.drafts.pr_composer_title_len = 0;
        self.drafts.pr_composer_body_len = 0;
        self.drafts.pr_composer_focus = .title;
        self.drafts.pr_composer_submitting = false;
        self.drafts.show_pr_composer = true;
    }

    fn lookupDraftOperation(self: *Shell, target: DraftTarget) ?drafts_mod.DraftOperation {
        return self.draftOperationForWorkspace(target.ws_id, target.category, target.path);
    }

    pub fn draftOperationForView(
        self: *Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?drafts_mod.DraftOperation {
        const ws_id = self.activeWsId() orelse return null;
        return self.draftOperationForWorkspace(ws_id, category, path);
    }

    fn draftOperationForWorkspace(
        self: *Shell,
        ws_id: []const u8,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?drafts_mod.DraftOperation {
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, ws_id) catch return null;
        defer alloc.free(ws_dir);
        var index = drafts_mod.loadIndex(alloc, ws_dir) catch return null;
        defer index.deinit(alloc);
        const entry = index.findDraftById(category, path) orelse return null;
        return entry.operation;
    }

    /// Free the duped strings backing pr_composer_target, if any.
    /// Safe to call when no composer is open.
    fn releaseComposerTarget(self: *Shell) void {
        if (self.drafts.pr_composer_path_owned) |p| {
            self.api_state.allocator().free(p);
            self.drafts.pr_composer_path_owned = null;
        }
        self.drafts.pr_composer_target = null;
    }

    pub fn cancelPrComposer(self: *Shell) void {
        self.drafts.show_pr_composer = false;
        self.drafts.pr_composer_submitting = false;
        self.drafts.pr_composer_title_len = 0;
        self.drafts.pr_composer_body_len = 0;
        self.drafts.pr_composer_focus = .title;
        self.releaseComposerTarget();
    }

    pub fn submitPrComposer(self: *Shell) void {
        if (self.drafts.pr_composer_submitting) return;
        if (self.drafts.pr_composer_title_len == 0) {
            self.notifyOp(.warning, "Title is required.");
            return;
        }
        const target = self.drafts.pr_composer_target orelse {
            self.notifyOp(.warning, "No composer target set.");
            return;
        };
        switch (target.category) {
            .rule => self.submitRulePr(target),
            .context => self.submitContextPr(target),
            .meta_prompt => self.submitRulePr(target),
        }
    }

    fn readDraftForSubmit(
        self: *Shell,
        alloc: std.mem.Allocator,
        target: DraftTarget,
    ) ?struct {
        ws_dir: []const u8,
        content: []const u8,
        entry: ?DraftSubmitEntry,
    } {
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch {
            self.notifyOp(.failure, "Could not resolve workspace directory.");
            return null;
        };
        errdefer alloc.free(ws_dir);

        var index = drafts_mod.loadIndex(alloc, ws_dir) catch |err| {
            self.notifyOp(.failure, @errorName(err));
            return null;
        };
        defer index.deinit(alloc);

        const draft_entry = index.findDraftById(target.category, target.path) orelse {
            self.notifyOp(.warning, "Draft entry missing; try again.");
            return null;
        };
        const draft_path = alloc.dupe(u8, draft_entry.draft_path) catch return null;
        errdefer alloc.free(draft_path);
        const content = drafts_mod.readDraftFile(alloc, ws_dir, target.category, draft_path) catch |err| {
            self.notifyOp(.failure, @errorName(err));
            return null;
        };
        errdefer alloc.free(content);
        const entry_out = DraftSubmitEntry{
            .operation = draft_entry.operation,
            .draft_path = draft_path,
            .base_hash = if (draft_entry.base_hash) |h| (alloc.dupe(u8, h) catch null) else null,
        };

        return .{ .ws_dir = ws_dir, .content = content, .entry = entry_out };
    }

    const DraftSubmitEntry = struct {
        operation: drafts_mod.DraftOperation,
        draft_path: []const u8,
        base_hash: ?[]const u8,
    };

    fn submitRulePr(self: *Shell, target: DraftTarget) void {
        const alloc = self.api_state.allocator();
        const read = self.readDraftForSubmit(alloc, target) orelse return;
        defer alloc.free(read.ws_dir);
        defer alloc.free(read.content);
        defer if (read.entry) |e| {
            alloc.free(e.draft_path);
            if (e.base_hash) |h| alloc.free(h);
        };

        const entry = read.entry orelse {
            self.notifyOp(.warning, "Draft entry missing; try again.");
            return;
        };
        // Existing-rule operations need identity and base metadata;
        // create operations carry the new path and content.
        const operation_type: []const u8 = switch (entry.operation) {
            .create => "create",
            .modify => "modify",
            .rename => "rename",
            .delete => "delete",
        };

        const title_copy = alloc.dupe(u8, self.drafts.pr_composer_title_buf[0..self.drafts.pr_composer_title_len]) catch return;
        defer alloc.free(title_copy);
        const body_copy = alloc.dupe(u8, self.drafts.pr_composer_body_buf[0..self.drafts.pr_composer_body_len]) catch return;
        defer alloc.free(body_copy);
        const content_copy: ?[]const u8 = if (entry.operation == .delete)
            null
        else
            (alloc.dupe(u8, read.content) catch return);
        defer if (content_copy) |c| alloc.free(c);

        // Modify/rename/delete need rule_id; resolve from the draft
        // target first (authoritative) then fall back to an artifact
        // lookup by path. Create drafts have neither — that's the
        // expected missing rule_id, not an error.
        const rule_id_copy_opt: ?[]const u8 = if (entry.operation == .create)
            null
        else blk: {
            const pid = target.rule_id orelse self.lookupRuleId(target.path) orelse {
                self.notifyOp(.warning, "Unknown rule id for this draft.");
                return;
            };
            break :blk (alloc.dupe(u8, pid) catch return);
        };
        defer if (rule_id_copy_opt) |pid| alloc.free(pid);

        const path_copy_opt: ?[]const u8 = switch (entry.operation) {
            .create => alloc.dupe(u8, entry.draft_path) catch return,
            else => null,
        };
        defer if (path_copy_opt) |p| alloc.free(p);
        const new_path_copy_opt: ?[]const u8 = switch (entry.operation) {
            .rename => alloc.dupe(u8, entry.draft_path) catch return,
            else => null,
        };
        defer if (new_path_copy_opt) |p| alloc.free(p);

        const base_hash_copy_opt: ?[]const u8 = if (entry.base_hash) |h|
            (alloc.dupe(u8, h) catch return)
        else
            null;
        defer if (base_hash_copy_opt) |h| alloc.free(h);

        if (entry.operation == .modify or entry.operation == .rename) {
            if (base_hash_copy_opt == null) {
                self.notifyOp(.warning, "Missing base_hash for modify/rename draft.");
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
                .title = title_copy,
                .body = body_copy,
                .operation_type = operation_type,
                .rule_id = rule_id_copy_opt,
                .path = path_copy_opt,
                .new_path = new_path_copy_opt,
                .content = content_copy,
                .base_hash = base_hash_copy_opt,
            },
        );
        self.drafts.pr_composer_submitting = true;
        self.notifyOp(.loading, "Submitting PR...");
    }

    fn submitContextPr(self: *Shell, target: DraftTarget) void {
        const alloc = self.api_state.allocator();
        const read = self.readDraftForSubmit(alloc, target) orelse return;
        defer alloc.free(read.ws_dir);
        defer alloc.free(read.content);
        defer if (read.entry) |e| {
            alloc.free(e.draft_path);
            if (e.base_hash) |h| alloc.free(h);
        };

        const entry = read.entry orelse {
            self.notifyOp(.warning, "Draft entry missing; try again.");
            return;
        };
        const operation_type: []const u8 = switch (entry.operation) {
            .create => "create",
            .modify => "modify",
            .rename => "rename",
            .delete => "delete",
        };

        const title_copy = alloc.dupe(u8, self.drafts.pr_composer_title_buf[0..self.drafts.pr_composer_title_len]) catch return;
        defer alloc.free(title_copy);
        const body_copy = alloc.dupe(u8, self.drafts.pr_composer_body_buf[0..self.drafts.pr_composer_body_len]) catch return;
        defer alloc.free(body_copy);
        const content_copy = alloc.dupe(u8, read.content) catch return;
        defer alloc.free(content_copy);
        const ws_id_copy = alloc.dupe(u8, target.ws_id) catch return;
        defer alloc.free(ws_id_copy);
        const path_copy_opt: ?[]const u8 = switch (entry.operation) {
            .create => alloc.dupe(u8, entry.draft_path) catch return,
            else => null,
        };
        defer if (path_copy_opt) |p| alloc.free(p);
        const new_path_copy_opt: ?[]const u8 = switch (entry.operation) {
            .rename => alloc.dupe(u8, entry.draft_path) catch return,
            else => null,
        };
        defer if (new_path_copy_opt) |p| alloc.free(p);
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
            self.notifyOp(.warning, "Missing context_id for modify/rename/delete.");
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
                .title = title_copy,
                .body = body_copy,
                .operation_type = operation_type,
                .context_id = context_id_copy_opt,
                .path = path_copy_opt,
                .new_path = new_path_copy_opt,
                .content = content_copy,
                .base_hash = base_hash_copy_opt,
            },
        );
        self.drafts.pr_composer_submitting = true;
        self.notifyOp(.loading, "Submitting PR...");
    }

    fn handlePrComposerKey(self: *Shell, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (self.drafts.pr_composer_submitting) {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.drafts.pr_composer_submitting = false;
                ctx.consumeAndRedraw();
            }
            return;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            self.cancelPrComposer();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.drafts.pr_composer_focus = switch (self.drafts.pr_composer_focus) {
                .title => .body,
                .body => .title,
            };
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.submitPrComposer();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            switch (self.drafts.pr_composer_focus) {
                .title => if (self.drafts.pr_composer_title_len > 0) {
                    self.drafts.pr_composer_title_len -= 1;
                    ctx.consumeAndRedraw();
                },
                .body => if (self.drafts.pr_composer_body_len > 0) {
                    self.drafts.pr_composer_body_len -= 1;
                    ctx.consumeAndRedraw();
                },
            }
            return;
        }
        switch (self.drafts.pr_composer_focus) {
            .title => {
                if (key.text) |text| {
                    const remaining = self.drafts.pr_composer_title_buf.len - self.drafts.pr_composer_title_len;
                    if (text.len > 0 and text.len <= remaining) {
                        @memcpy(self.drafts.pr_composer_title_buf[self.drafts.pr_composer_title_len..][0..text.len], text);
                        self.drafts.pr_composer_title_len += text.len;
                        ctx.consumeAndRedraw();
                    }
                } else if (key.codepoint >= 0x20 and key.codepoint < 0x7f) {
                    if (self.drafts.pr_composer_title_len < self.drafts.pr_composer_title_buf.len) {
                        self.drafts.pr_composer_title_buf[self.drafts.pr_composer_title_len] = @intCast(key.codepoint);
                        self.drafts.pr_composer_title_len += 1;
                        ctx.consumeAndRedraw();
                    }
                }
            },
            .body => {
                if (key.text) |text| {
                    const remaining = self.drafts.pr_composer_body_buf.len - self.drafts.pr_composer_body_len;
                    if (text.len > 0 and text.len <= remaining) {
                        @memcpy(self.drafts.pr_composer_body_buf[self.drafts.pr_composer_body_len..][0..text.len], text);
                        self.drafts.pr_composer_body_len += text.len;
                        ctx.consumeAndRedraw();
                    }
                } else if (key.codepoint >= 0x20 and key.codepoint < 0x7f) {
                    if (self.drafts.pr_composer_body_len < self.drafts.pr_composer_body_buf.len) {
                        self.drafts.pr_composer_body_buf[self.drafts.pr_composer_body_len] = @intCast(key.codepoint);
                        self.drafts.pr_composer_body_len += 1;
                        ctx.consumeAndRedraw();
                    }
                }
            },
        }
    }

    fn drawPrComposerOverlay(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const box_w = @min(size.width -| 4, 60);
        const target = self.drafts.pr_composer_target orelse DraftTarget{
            .ws_id = "",
            .category = .rule,
            .path = "",
        };
        const modal_title = switch (target.category) {
            .rule => "New Rule PR",
            .context => "New Context PR",
            .meta_prompt => "New Meta-Prompt PR",
        };
        const box_h: u16 = if (self.drafts.pr_composer_submitting) 11 else 10;
        const modal = Modal{
            .title = modal_title,
            .box_width = box_w,
            .box_height = box_h,
            .anchor = .center,
            .footer = if (self.drafts.pr_composer_submitting) "Submitting..." else "",
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        const row = result.content_row;

        const title_style = theme.textOn(theme.PANEL_ALT, if (self.drafts.pr_composer_focus == .title) theme.TEXT else theme.TEXT_SOFT);
        const body_style = theme.textOn(theme.PANEL_ALT, if (self.drafts.pr_composer_focus == .body) theme.TEXT else theme.TEXT_SOFT);

        const title_label: []const u8 = if (self.drafts.pr_composer_focus == .title) "title:" else "title:";
        w.writeText(&surface, ctx, col, row, title_label, theme.textOn(theme.PANEL_ALT, theme.MUTED));
        const title_text = self.drafts.pr_composer_title_buf[0..self.drafts.pr_composer_title_len];
        w.drawTextInputSlot(&surface, ctx, col + 6, row, result.content_width -| 8, title_text, title_style.fg, self.drafts.pr_composer_focus == .title);

        w.writeText(&surface, ctx, col, row + 2, "body:", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        const body_text = self.drafts.pr_composer_body_buf[0..self.drafts.pr_composer_body_len];
        w.drawTextInputSlot(&surface, ctx, col + 6, row + 2, result.content_width -| 8, body_text, body_style.fg, self.drafts.pr_composer_focus == .body);

        return surface;
    }

    pub fn openNewDraftForm(self: *Shell, category: drafts_mod.DraftCategory) void {
        if (self.activeWsId() == null) {
            self.notifyOp(.warning, "No workspace loaded yet; wait for bootstrap.");
            return;
        }
        self.drafts.new_draft_path_len = 0;
        self.drafts.new_draft_category = category;
        self.drafts.show_new_draft_form = true;
    }

    pub fn cancelNewDraftForm(self: *Shell) void {
        self.drafts.show_new_draft_form = false;
        self.drafts.new_draft_path_len = 0;
    }

    pub fn submitNewDraftForm(self: *Shell) void {
        if (self.drafts.new_draft_path_len == 0) {
            self.notifyOp(.warning, "Path is required.");
            return;
        }
        const ws_id = self.activeWsId() orelse return;
        const path = self.drafts.new_draft_path_buf[0..self.drafts.new_draft_path_len];
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, ws_id) catch {
            self.notifyOp(.failure, "Could not resolve workspace directory.");
            return;
        };
        defer alloc.free(ws_dir);

        const path_copy = alloc.dupe(u8, path) catch return;
        defer alloc.free(path_copy);

        const category = self.drafts.new_draft_category;
        drafts_mod.createDraft(alloc, ws_dir, .{
            .category = category,
            .operation = .create,
            .draft_path = path_copy,
        }, "") catch |err| {
            self.notifyOp(.failure, @errorName(err));
            return;
        };

        self.drafts.show_new_draft_form = false;
        self.drafts.new_draft_path_len = 0;
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
            self.notifyOp(.failure, @errorName(err));
            return;
        };
        switch (result) {
            .completed => self.notifyOp(.success, "New draft saved."),
            .failed => self.notifyOp(.failure, "Editor exited non-zero."),
            .editor_not_found => self.notifyOp(.failure, "No $EDITOR resolved."),
            .spawn_failed => self.notifyOp(.failure, "Editor spawn failed."),
        }
        self.refreshDraftsCache();
    }

    fn handleNewDraftFormKey(self: *Shell, ctx: *vxfw.EventContext, key: vaxis.Key) void {
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
            if (self.drafts.new_draft_path_len > 0) {
                self.drafts.new_draft_path_len -= 1;
                ctx.consumeAndRedraw();
            }
            return;
        }
        if (key.text) |text| {
            const remaining = self.drafts.new_draft_path_buf.len - self.drafts.new_draft_path_len;
            if (text.len > 0 and text.len <= remaining) {
                @memcpy(self.drafts.new_draft_path_buf[self.drafts.new_draft_path_len..][0..text.len], text);
                self.drafts.new_draft_path_len += text.len;
                ctx.consumeAndRedraw();
            }
        } else if (key.codepoint >= 0x20 and key.codepoint < 0x7f) {
            if (self.drafts.new_draft_path_len < self.drafts.new_draft_path_buf.len) {
                self.drafts.new_draft_path_buf[self.drafts.new_draft_path_len] = @intCast(key.codepoint);
                self.drafts.new_draft_path_len += 1;
                ctx.consumeAndRedraw();
            }
        }
    }

    fn drawNewDraftFormOverlay(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const box_w = @min(size.width -| 4, 54);
        const box_h: u16 = 10;
        const title = switch (self.drafts.new_draft_category) {
            .rule => "New Rule Draft",
            .context => "New Context Draft",
            .meta_prompt => "New Meta-Prompt Draft",
        };
        const hint = switch (self.drafts.new_draft_category) {
            .rule => "e.g. rule/00_MY_RULE.md",
            .context => "e.g. spec/NEW_SPEC.md",
            .meta_prompt => "META_PROMPT.md",
        };
        const modal = Modal{
            .title = title,
            .box_width = box_w,
            .box_height = box_h,
            .anchor = .center,
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        const row = result.content_row;

        w.writeText(&surface, ctx, col, row, "path:", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        const path_text = self.drafts.new_draft_path_buf[0..self.drafts.new_draft_path_len];
        w.drawTextInputSlot(&surface, ctx, col, row + 1, result.content_width -| 2, path_text, theme.TEXT, true);
        w.writeText(&surface, ctx, col, row + 3, hint, theme.textOn(theme.PANEL_ALT, theme.MUTED));

        return surface;
    }

    fn consumeCreateRulePrResult(self: *Shell) void {
        const result = self.api_state.create_rule_pr_pending.consume() orelse return;
        self.drafts.pr_composer_submitting = false;
        switch (result) {
            .ok => |resp| {
                self.markComposerInReview(resp.pr_id, resp.status);
            },
            .api_error => |e| self.notifyOp(.failure, writeErrorStatus(self, "PR submit failed", e)),
            .network_error => self.notifyOp(.failure, "PR submit failed: network error."),
            .invalid_response => self.notifyOp(.failure, "PR submit failed: malformed response."),
        }
    }

    fn consumeCreateContextPrResult(self: *Shell) void {
        const result = self.api_state.create_context_pr_pending.consume() orelse return;
        self.drafts.pr_composer_submitting = false;
        switch (result) {
            .ok => |resp| {
                self.markComposerInReview(resp.pr_id, resp.status);
            },
            .api_error => |e| self.notifyOp(.failure, writeErrorStatus(self, "PR submit failed", e)),
            .network_error => self.notifyOp(.failure, "PR submit failed: network error."),
            .invalid_response => self.notifyOp(.failure, "PR submit failed: malformed response."),
        }
    }

    /// Shared post-submit path for both rule and context PRs. Marks
    /// the draft as in review against disk, refreshes the in-memory
    /// cache, closes the composer, and posts a user-facing confirmation.
    fn markComposerInReview(self: *Shell, pr_id: []const u8, status: []const u8) void {
        const target = self.drafts.pr_composer_target orelse return;
        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch return;
        defer alloc.free(ws_dir);
        drafts_mod.setDraftStatus(
            alloc,
            ws_dir,
            target.category,
            self.draftPathForSelection(target.category, target.path),
            .in_review,
        ) catch {};
        self.refreshDraftsCache();
        // A new PR exists on the hub, but rule_prs_cache still
        // holds the pre-submit snapshot — the Pull Requests tab
        // would render stale rows until a manual `r` refresh. Drop
        // the cached details so the next render re-fetches.
        self.invalidateRemoteDetailRequests();
        self.drafts.show_pr_composer = false;
        self.drafts.pr_composer_title_len = 0;
        self.drafts.pr_composer_body_len = 0;
        self.drafts.pr_composer_focus = .title;
        self.releaseComposerTarget();
        const message = std.fmt.allocPrint(
            self.api_state.allocator(),
            "PR {s} opened ({s}).",
            .{ pr_id, status },
        ) catch "PR opened.";
        self.notifyOp(.success, message);
    }

    fn selectTab(self: *Shell, ctx: *vxfw.EventContext, tab: TopModule) void {
        const previous = self.selected_module;
        self.selected_module = tab;
        log.info("tab_select from={s} to={s}", .{ moduleName(previous), moduleName(tab) });
        self.analysis.show_member_detail = false;
        self.analysis.expanded_rule = null;
        switch (tab) {
            .dashboard => {
                if (self.analysis.focus != .chart and self.analysis.focus != .inputs) {
                    self.analysis.focus = .inputs;
                }
            },
            .analysis => {
                if (self.analysis.focus != .rules and self.analysis.focus != .members) {
                    self.analysis.focus = .rules;
                }
            },
            .workspace => {
                self.ensureActiveWorkspaceDetailRequested();
            },
            .review => {
                api.state.invalidateRemoteCaches(self.api_state, .pr_lists);
                self.ensureReviewPrsRequested();
            },
            else => {},
        }
        ctx.consumeAndRedraw();
    }

    fn activeInputLayer(self: *const Shell) []const u8 {
        if (self.show_confirm) return "confirm";
        if (self.show_profile_dialog) return "profile_dialog";
        if (self.show_invite_dialog) return "invite_dialog";
        if (self.show_help) return "help";
        if (self.shouldShowLoginPanel()) return "login";
        if (self.workspace.show_drawer) return "workspace_drawer";
        if (self.workspace.show_create) return "workspace_create";
        if (self.review.show_comment_editor) return "comment_editor";
        if (self.drafts.show_pr_composer) return "pr_composer";
        if (self.drafts.show_new_draft_form) return "new_draft_form";
        if (self.show_settings) return "settings";
        return "module";
    }

    fn logKeyEvent(self: *const Shell, layer: []const u8, key: vaxis.Key) void {
        log.debug("key module={s} layer={s} key={s} text_bytes={d} ctrl={} alt={} shift={}", .{
            moduleName(self.selected_module),
            layer,
            keyName(key),
            keyTextLen(key),
            key.mods.ctrl,
            key.mods.alt,
            key.mods.shift,
        });
    }

    pub fn shiftDetailTab(self: *Shell, delta: i8) void {
        const current: i8 = @intCast(@intFromEnum(self.review.detail_tab));
        const count: i8 = @intCast(rule_detail_panel.detail_tabs.len);
        const next = @mod(current + delta + count, count);
        self.review.detail_tab = @enumFromInt(@as(u8, @intCast(next)));
        self.review.show_comment_editor = false;
        self.review.pr_filter = .open;
        self.review.selected_pr_idx = 0;
        self.review.hide_diff = false;
        self.review.pr_scroll_bars.scroll_view.cursor = 0;
    }

    pub fn shiftWsTab(self: *Shell, delta: i8) void {
        const current: i8 = @intCast(@intFromEnum(self.workspace.tab));
        const count: i8 = @intCast(workspace_panel.tabs.len);
        const next = @mod(current + delta + count, count);
        self.workspace.tab = @enumFromInt(@as(u8, @intCast(next)));
    }
};
