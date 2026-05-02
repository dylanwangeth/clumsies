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
const library_panel = features.library;
const rule_detail_panel = features.review;
const settings_panel = features.settings;
const workspace_panel = features.workspace;
const drafts_mod = @import("../drafts.zig");
const workspace_rule = @import("../rule.zig");
const workspace_config = @import("../workspace_config.zig");
const local_content = @import("../local_content.zig");
const runtime = @import("runtime.zig");
const util_hash = @import("clumsies_lib").util.hash;
const tui_prefs = @import("prefs.zig");
const manifest_protocol = @import("clumsies_lib").protocol.manifest;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;

const editor_host = runtime.editor_host;
const attestation_reader = runtime.attestation_reader;
const Modal = w.Modal;

const WORKSPACE_DRAWER_WIDTH: u16 = 44;
const HELP_DRAWER_WIDTH: u16 = WORKSPACE_DRAWER_WIDTH;
const DRAWER_SIDE_MARGIN: u16 = 6;

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

const top_tabs = [_]TopModule{ .dashboard, .workspace, .library, .analysis };

const WORKSPACE_METADATA_REFRESH_TICKS = 600;
const GLOBAL_METADATA_REFRESH_TICKS = 3000;
const PathTreeState = workspace_panel.PathTreeState;

const DraftTarget = features.drafts.DraftTarget;

pub const Shell = struct {
    api_state: *api.state.ApiState,
    selected_module: TopModule = .dashboard,
    library: library_panel.State,
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
    confirm_action: ConfirmAction = .none,
    last_safe_layout_size: vxfw.Size = .{},
    system_notices: w.SystemNoticeQueue = .{},
    view_arena: std.heap.ArenaAllocator,
    last_workspace_id: ?[]const u8 = null,
    workspace_pref_applied: bool = false,
    tick_count: u64 = 0,

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
        return .{
            .api_state = api_state,
            .library = library_panel.State.init(),
            .review = rule_detail_panel.State.init(),
            .workspace = workspace_panel.State.init(api_state.backing_allocator),
            .dashboard = dashboard_panel.State.init(),
            .drafts = features.drafts.State.init(api_state.backing_allocator),
            .view_arena = std.heap.ArenaAllocator.init(api_state.backing_allocator),
            .last_workspace_id = last_workspace_id,
            .app = app,
            .env_map = env_map,
        };
    }

    pub fn deinit(self: *Shell) void {
        self.releaseComposerTarget();
        self.releasePendingDiscardTarget();
        const alloc = self.api_state.allocator();
        self.workspace.deinit(alloc);
        self.library.deinit(alloc);
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
            .error_auth, .error_network => .{ .key = .connection, .kind = .failure, .persistence = .transient, .text = "\xe2\x9c\x97 Connection failed", .created_tick = now },
        };
    }

    fn handleEvent(self: *Shell, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = self.view_arena.reset(.retain_capacity);
        switch (event) {
            .key_press => |key| {
                // Confirm overlay absorbs all keys
                if (self.show_confirm) {
                    if (key.matches('y', .{})) {
                        switch (self.confirm_action) {
                            .remove_member => {
                                self.notifyOp(.info, "Member removed (not yet implemented)");
                            },
                            .delete_bundle => {
                                self.notifyOp(.info, "Bundle deleted (not yet implemented)");
                            },
                            .delete_workspace => {
                                self.notifyOp(.info, "Workspace deleted (not yet implemented)");
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
                        self.notifyOp(.warning, "Cancelled.");
                        ctx.consumeAndRedraw();
                    }
                    return;
                }

                // Help drawer absorbs all keys
                if (self.show_help) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('?', .{})) {
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
                        self.review.show_comment_editor = false;
                        self.review.comment_input_len = 0;
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        if (self.review.comment_input_len > 0) {
                            self.submitComment();
                        } else {
                            self.notifyOp(.warning, "Empty comment discarded.");
                        }
                        self.review.show_comment_editor = false;
                        self.review.comment_input_len = 0;
                        ctx.consumeAndRedraw();
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        if (self.review.comment_input_len > 0) {
                            self.review.comment_input_len -= 1;
                            ctx.consumeAndRedraw();
                        }
                    } else if (key.text) |text| {
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
                    settings_panel.handleEvent(self, ctx, key);
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
                self.tick_count +%= 1;
                self.analysis.breathing_phase = (self.analysis.breathing_phase + 1) % 21;
                self.system_notices.tick();
                self.reconcileWorkspaceSelection();
                if ((self.selected_module == .dashboard or self.selected_module == .analysis) and (self.analysis.breathing_phase == 0 or self.analysis.breathing_phase == 10)) {
                    api.state.refreshLocalState(self.api_state);
                }
                // First tick after current_user lands (the /me fetch
                // completes asynchronously, so activeWsId() was null
                // at .init). Seed the drafts map now so row markers
                // and the footer counter come up populated.
                if (!self.drafts.cache_seeded and self.activeWsId() != null) {
                    self.refreshDraftsCache();
                    self.ensureActiveWorkspaceDetailRequested();
                } else if (self.selected_module == .workspace) {
                    self.refreshDraftsCacheIfChanged();
                    self.ensureActiveWorkspaceDetailRequested();
                }
                _ = workspace_panel.consumeCreateResult(self);
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
                self.consumeAttestationUploadResult();
                self.maybeRefreshMetadata();
                ctx.redraw = true;
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

        const show_workspace_drawer = self.workspace.show_drawer and self.selected_module == .workspace and
            !self.show_settings and !self.show_help and !self.show_confirm and !self.review.show_comment_editor and
            !self.workspace.show_create and !self.drafts.show_pr_composer and !self.drafts.show_new_draft_form;
        const modal_active = self.show_help or self.show_confirm or self.review.show_comment_editor or
            self.workspace.show_create or self.drafts.show_pr_composer or
            self.drafts.show_new_draft_form or show_workspace_drawer;
        const show_notice_overlay = !modal_active and self.system_notices.hasVisible();
        var child_count: usize = 3;
        if (modal_active) child_count += 1;
        if (show_notice_overlay) child_count += 1;

        const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawHeader(header_ctx) };
        children[1] = .{ .origin = .{ .row = header_h, .col = 0 }, .surface = try self.drawBody(body_ctx) };
        children[2] = .{ .origin = .{ .row = header_h + body_h, .col = 0 }, .surface = try self.drawFooter(footer_ctx) };
        var child_idx: usize = 3;

        if (self.show_help) {
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
        if (self.show_confirm) {
            const confirm_ctx = ctx.withConstraints(
                .{ .width = size.width, .height = size.height },
                .{ .width = size.width, .height = size.height },
            );
            children[child_idx] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.drawConfirmOverlay(confirm_ctx) };
            child_idx += 1;
        }
        if (self.review.show_comment_editor) {
            const box_w: u16 = 42;
            const box_h: u16 = 8;
            const box_col = size.width -| (box_w + 2);
            const box_row = size.height -| (box_h + 2);
            const comment_ctx = ctx.withConstraints(
                .{ .width = box_w, .height = box_h },
                .{ .width = box_w, .height = box_h },
            );
            children[child_idx] = .{ .origin = .{ .row = box_row, .col = box_col }, .surface = try self.drawCommentEditorOverlay(comment_ctx) };
            child_idx += 1;
        }
        if (self.workspace.show_create) {
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
        if (self.drafts.show_pr_composer) {
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
        if (self.drafts.show_new_draft_form) {
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
        if (show_workspace_drawer) {
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
            .library => self.drawLibrary(ctx),
            .workspace => self.drawWorkspaceStatus(ctx),
            .analysis => self.drawAnalysis(ctx),
        };
    }

    fn drawFooter(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
        w.fillSurface(&surface, theme.PANEL);

        var shortcuts_max_col = surface.size.width;

        if (self.drafts.total > 0) {
            const counter = std.fmt.allocPrint(
                ctx.arena,
                "drafts: {d} ({d} ready)",
                .{ self.drafts.total, self.drafts.ready },
            ) catch "";
            const counter_w: u16 = @intCast(ctx.stringWidth(counter));
            if (counter.len > 0 and counter_w + 2 < shortcuts_max_col) {
                const counter_col = shortcuts_max_col - counter_w - 1;
                shortcuts_max_col = counter_col -| 2;
                w.writeText(&surface, ctx, counter_col, 0, counter, theme.fg(theme.ACCENT));
            }
        }

        _ = w.drawShortcutBar(&surface, ctx, try self.footerShortcuts(ctx.arena), .{
            .row = 0,
            .col = 1,
            .max_col = shortcuts_max_col,
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

        return switch (self.selected_module) {
            .dashboard => dashboard_panel.shortcuts(self),
            .library => library_panel.shortcuts(self),
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

    // Library: master-detail. Left panel carries a Files / Pull Requests
    // inner tab strip; right panel is a single detail surface that
    // follows whichever item the left panel has selected.
    fn drawLibrary(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        self.ensureDraftsCacheForActiveWorkspace();
        self.refreshDraftsCacheIfChanged();
        try library_panel.syncLibraryWidgets(self, ctx);

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
            if (self.library.selected_rule < rules.len) break :blk &rules[self.library.selected_rule];
            const k = self.library.selected_rule - rules.len;
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

    fn drawListPanel(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const bundles_list = self.getBundles();
        const bundle_label: []const u8 = if (self.library.bundle_filter == 0)
            "All"
        else if (self.library.bundle_filter - 1 < bundles_list.len)
            bundles_list[self.library.bundle_filter - 1].name
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

    // Workspace: master-detail content with a command drawer for switching
    // workspaces. Tab cycles focus between list and content.
    fn drawWorkspaceStatus(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        self.ensureDraftsCacheForActiveWorkspace();
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

        const context_files = arena.alloc(api.model.ContextFileData, manifest.context.count()) catch {
            self.workspace.local_load_failed = true;
            return;
        };
        var context_i: usize = 0;
        var context_it = manifest.context.iterator();
        while (context_it.next()) |entry| {
            context_files[context_i] = .{
                .context_id = arena.dupe(u8, entry.key_ptr.*) catch "",
                .path = arena.dupe(u8, entry.value_ptr.path) catch "",
                .hash = arena.dupe(u8, entry.value_ptr.hash) catch "",
                .size = 0,
                .author = "local",
                .updated_at = "",
            };
            context_i += 1;
        }

        const ws_rules = arena.alloc(api.model.WsRuleData, manifest.rules.count()) catch {
            self.workspace.local_load_failed = true;
            return;
        };
        var rule_i: usize = 0;
        var rule_it = manifest.rules.iterator();
        while (rule_it.next()) |entry| {
            ws_rules[rule_i] = .{
                .rule_id = arena.dupe(u8, entry.key_ptr.*) catch "",
                .content_hash = arena.dupe(u8, entry.value_ptr.hash) catch "",
                .path = arena.dupe(u8, entry.value_ptr.path) catch "",
            };
            rule_i += 1;
        }

        self.workspace.local_detail = .{
            .ws_id = ws_id_copy,
            .context_files = context_files[0..context_i],
            .ws_rules = ws_rules[0..rule_i],
        };
    }

    pub fn workspaceDetailForView(self: *Shell, ws_id: []const u8) ?api.model.WsDetail {
        self.ensureLocalWorkspaceDetail(ws_id);
        const local = self.workspace.local_detail;
        const remote_context = self.api_state.ws_context_files_cache.lookup(.{ .value = ws_id });
        const remote_rules = self.api_state.ws_manifest_cache.lookup(.{ .value = ws_id });
        const local_context = if (local) |l| l.context_files else null;
        const local_rules = if (local) |l| l.ws_rules else null;
        const context_files = self.mergeContextFilesForView(local_context, remote_context) orelse &.{};
        const ws_rules = self.mergeWorkspaceRulesForView(local_rules, remote_rules) orelse &.{};

        if (context_files.len == 0 and ws_rules.len == 0 and local == null and remote_context == null and remote_rules == null) return null;
        return .{
            .ws_id = ws_id,
            .context_files = context_files,
            .ws_rules = ws_rules,
        };
    }

    fn mergeContextFilesForView(
        self: *Shell,
        local: ?[]const api.model.ContextFileData,
        remote: ?[]const api.model.ContextFileData,
    ) ?[]const api.model.ContextFileData {
        const local_items = local orelse &.{};
        const remote_items = remote orelse &.{};
        if (local_items.len == 0) return if (remote != null) remote_items else null;
        if (remote_items.len == 0) return local_items;

        const arena = self.viewAllocator();
        var merged = arena.alloc(api.model.ContextFileData, remote_items.len + local_items.len) catch return local_items;
        var len: usize = 0;
        for (remote_items) |item| {
            merged[len] = item;
            len += 1;
        }
        for (local_items) |item| {
            if (contextPathIn(remote_items, item.path)) continue;
            merged[len] = item;
            len += 1;
        }
        return merged[0..len];
    }

    fn mergeWorkspaceRulesForView(
        self: *Shell,
        local: ?[]const api.model.WsRuleData,
        remote: ?[]const api.model.WsRuleData,
    ) ?[]const api.model.WsRuleData {
        const local_items = local orelse &.{};
        const remote_items = remote orelse &.{};
        if (local_items.len == 0) return if (remote != null) remote_items else null;
        if (remote_items.len == 0) return local_items;

        const arena = self.viewAllocator();
        var merged = arena.alloc(api.model.WsRuleData, remote_items.len + local_items.len) catch return local_items;
        var len: usize = 0;
        for (remote_items) |item| {
            merged[len] = item;
            len += 1;
        }
        for (local_items) |item| {
            if (self.rulePathIn(remote_items, item.path)) continue;
            merged[len] = item;
            len += 1;
        }
        return merged[0..len];
    }

    fn contextPathIn(items: []const api.model.ContextFileData, path: []const u8) bool {
        for (items) |item| {
            if (std.mem.eql(u8, item.path, path)) return true;
        }
        return false;
    }

    fn rulePathIn(self: *Shell, items: []const api.model.WsRuleData, path: []const u8) bool {
        for (items) |item| {
            if (std.mem.eql(u8, self.pathForWorkspaceRule(item), path)) return true;
        }
        return false;
    }

    fn hasLocalWorkspaceDetail(self: *Shell, ws_id: []const u8) bool {
        self.ensureLocalWorkspaceDetail(ws_id);
        const local = self.workspace.local_detail orelse return false;
        return local.context_files.len > 0 or local.ws_rules.len > 0;
    }

    pub fn ensureActiveWorkspaceDetailRequested(self: *Shell) void {
        const ws_id = self.activeWsId() orelse return;
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
        self.workspace.show_diff = false;
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
            workspace_panel.requestWorkspaceDetail(self, ws_id);
        }
    }

    fn maybeRefreshMetadata(self: *Shell) void {
        if (self.tick_count > 0 and self.tick_count % GLOBAL_METADATA_REFRESH_TICKS == 0) {
            api.fetch.refetchAllAsync(self.api_state);
        }
        if (self.tick_count > 0 and self.tick_count % WORKSPACE_METADATA_REFRESH_TICKS == 0) {
            const ws_id = self.activeWsId() orelse return;
            self.api_state.ws_context_files_cache.invalidate();
            self.api_state.ws_manifest_cache.invalidate();
            workspace_panel.requestWorkspaceDetail(self, ws_id);
        }
    }

    pub fn resetWorkspaceTrees(self: *Shell) void {
        self.workspace.context_tree.reset();
        self.workspace.rules_tree.reset();
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

    pub fn cachedWorkspaceContextBody(self: *Shell, ws_id: []const u8, path: []const u8) ?[]const u8 {
        if (self.api_state.ws_context_content_cache.lookup(.{ .ws_id = ws_id, .path = path })) |body| {
            return body;
        }
        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return null;
        return workspace_rule.readContextCacheFile(arena, ws_dir, path) catch null;
    }

    pub fn workspaceFileAtRow(
        self: *Shell,
        row: usize,
        live_ws: ?api.model.WsDetail,
    ) ?WorkspaceFileSelection {
        const ws_tree = self.currentWsTree();
        if (ws_tree.dirPathAt(row) != null) return null;
        const leaf = ws_tree.leafIndexAt(row) orelse return null;
        switch (self.workspace.tab) {
            .context => {
                const context_count = if (live_ws) |ws_d| ws_d.context_files.len else 0;
                if (live_ws) |ws_d| if (leaf < ws_d.context_files.len) {
                    const file = ws_d.context_files[leaf];
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
                return .{ .context = .{
                    .path = self.drafts.create_context_paths[k],
                    .is_create_draft = true,
                } };
            },
            .rules => {
                const rule_count = if (live_ws) |ws_d| ws_d.ws_rules.len else 0;
                if (live_ws) |ws_d| if (leaf < ws_d.ws_rules.len) {
                    const wp = ws_d.ws_rules[leaf];
                    const path = self.pathForWorkspaceRule(wp);
                    return .{ .rule = .{
                        .path = path,
                        .rule_id = wp.rule_id,
                        .idx = leaf,
                        .hash = wp.content_hash,
                        .category = self.libraryCategoryForPath(path),
                    } };
                };
                if (leaf < rule_count) return null;
                const k = leaf - rule_count;
                if (k >= self.drafts.create_rule_paths.len) return null;
                const path = self.drafts.create_rule_paths[k];
                return .{ .rule = .{
                    .path = path,
                    .category = self.libraryCategoryForPath(path),
                    .is_create_draft = true,
                } };
            },
        }
    }

    pub fn currentWorkspaceFileSelection(
        self: *Shell,
        live_ws: ?api.model.WsDetail,
    ) ?WorkspaceFileSelection {
        return self.workspaceFileAtRow(self.workspace.list_sel, live_ws);
    }

    pub fn pathForWorkspaceRule(self: *Shell, wp: api.model.WsRuleData) []const u8 {
        if (wp.path.len > 0) return wp.path;
        for (self.getRules()) |lp| {
            if (std.mem.eql(u8, lp.content_hash, wp.content_hash)) return lp.path;
        }
        return wp.rule_id;
    }

    pub fn cachedRuleBody(self: *Shell, path: []const u8) ?[]const u8 {
        if (self.api_state.rule_content_cache.lookup(.{ .value = path })) |resp| {
            return resp.body;
        }
        const ws_id = self.activeWsId() orelse return null;
        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return null;
        return workspace_rule.readRuleCacheFile(arena, ws_dir, path) catch null;
    }

    pub fn cachedLibraryRuleBody(
        self: *Shell,
        category: drafts_mod.DraftCategory,
        path: []const u8,
    ) ?[]const u8 {
        return switch (category) {
            .rule => self.cachedRuleBody(path),
            .context => null,
            .meta_prompt => self.cachedMetaPromptBody(),
        };
    }

    pub fn cachedMetaPromptBody(self: *Shell) ?[]const u8 {
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
                const context = switch (selection orelse {
                    self.notifyOp(.warning, "Select a context file to pull.");
                    return;
                }) {
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
                const body = self.api_state.ws_context_content_cache.lookup(.{ .ws_id = ws_d.ws_id, .path = context.path }) orelse {
                    self.requestWorkspaceSelectionContent(&ws_d);
                    self.notifyOp(.loading, "Fetching selected content; pull again after it loads.");
                    return;
                };
                local_content.write(arena, ws_dir, .context, context.path, body) catch {
                    self.notifyOp(.failure, "Pull failed: could not write local context.");
                    return;
                };
            },
            .rules => {
                const rule = switch (selection orelse {
                    self.notifyOp(.warning, "Select a rule to pull.");
                    return;
                }) {
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
                const resp = self.api_state.rule_content_cache.lookup(.{ .value = rule.path }) orelse {
                    self.requestWorkspaceSelectionContent(&ws_d);
                    self.notifyOp(.loading, "Fetching selected content; pull again after it loads.");
                    return;
                };
                local_content.write(arena, ws_dir, rule.category, rule.path, resp.body) catch {
                    self.notifyOp(.failure, "Pull failed: could not write local rule.");
                    return;
                };
            },
        }

        self.writeRemoteManifestSnapshot(ws_dir, ws_d) catch {
            self.notifyOp(.warning, "Pulled content; manifest update failed.");
            self.resetLocalWorkspaceDetail();
            return;
        };
        self.resetLocalWorkspaceDetail();
        self.notifyOp(.success, "Pulled selected content.");
    }

    pub fn pullSelectedLibraryContent(self: *Shell) void {
        const ws_id = self.activeWsId() orelse {
            self.notifyOp(.warning, "No workspace selected.");
            return;
        };
        const rules = self.getRules();
        if (self.library.selected_rule >= rules.len) {
            self.notifyOp(.warning, "Select a synced rule to pull.");
            return;
        }

        const rule = rules[self.library.selected_rule];
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
        const category = self.libraryCategoryForPath(rule.path);
        local_content.write(arena, ws_dir, category, rule.path, resp.body) catch {
            self.notifyOp(.failure, "Pull failed: could not write local rule.");
            return;
        };
        self.writeLocalManifestRule(ws_dir, rule_id, rule.path, rule.content_hash) catch {
            self.notifyOp(.warning, "Pulled content; manifest update failed.");
            self.resetLocalWorkspaceDetail();
            return;
        };
        self.resetLocalWorkspaceDetail();
        self.notifyOp(.success, "Pulled selected content.");
    }

    fn writeRemoteManifestSnapshot(
        self: *Shell,
        ws_dir: []const u8,
        ws_d: api.model.WsDetail,
    ) !void {
        const arena = self.viewAllocator();
        const rule_items = try arena.alloc(manifest_protocol.ManifestItem, ws_d.ws_rules.len);
        for (ws_d.ws_rules, 0..) |rule, i| {
            rule_items[i] = .{
                .key = rule.rule_id,
                .value = .{
                    .path = rule.path,
                    .hash = rule.content_hash,
                },
            };
        }

        const context_items = try arena.alloc(manifest_protocol.ManifestItem, ws_d.context_files.len);
        for (ws_d.context_files, 0..) |file, i| {
            context_items[i] = .{
                .key = file.context_id,
                .value = .{
                    .path = file.path,
                    .hash = file.hash,
                },
            };
        }

        const body = try std.json.Stringify.valueAlloc(arena, workspace_api.WorkspaceManifestResponse{
            .ws_id = ws_d.ws_id,
            .name = self.activeWorkspaceName(),
            .revision = 0,
            .rules = .{ .items = rule_items },
            .context = .{ .items = context_items },
        }, .{ .whitespace = .indent_2 });

        const manifest_path = try std.fs.path.join(arena, &.{ ws_dir, "manifest.json" });
        const file = try std.fs.createFileAbsolute(manifest_path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        var write_buf: [8192]u8 = undefined;
        var writer = std.fs.File.Writer.init(file, &write_buf);
        try writer.interface.writeAll(body);
        try writer.interface.flush();
    }

    fn writeLocalManifestRule(
        self: *Shell,
        ws_dir: []const u8,
        rule_id: []const u8,
        path: []const u8,
        hash: []const u8,
    ) !void {
        const arena = self.viewAllocator();
        var manifest = try workspace_rule.loadManifest(arena, ws_dir);
        defer manifest.deinit(arena);

        const extra_rule: usize = if (manifest.rules.contains(rule_id)) 0 else 1;
        const rule_items = try arena.alloc(manifest_protocol.ManifestItem, manifest.rules.count() + extra_rule);
        var rule_i: usize = 0;
        var rule_it = manifest.rules.iterator();
        while (rule_it.next()) |entry| {
            const is_selected = std.mem.eql(u8, entry.key_ptr.*, rule_id);
            rule_items[rule_i] = .{
                .key = if (is_selected) rule_id else entry.key_ptr.*,
                .value = .{
                    .path = if (is_selected) path else entry.value_ptr.path,
                    .hash = if (is_selected) hash else entry.value_ptr.hash,
                },
            };
            rule_i += 1;
        }
        if (extra_rule == 1) {
            rule_items[rule_i] = .{
                .key = rule_id,
                .value = .{
                    .path = path,
                    .hash = hash,
                },
            };
            rule_i += 1;
        }

        const context_items = try arena.alloc(manifest_protocol.ManifestItem, manifest.context.count());
        var context_i: usize = 0;
        var context_it = manifest.context.iterator();
        while (context_it.next()) |entry| {
            context_items[context_i] = .{
                .key = entry.key_ptr.*,
                .value = .{
                    .path = entry.value_ptr.path,
                    .hash = entry.value_ptr.hash,
                },
            };
            context_i += 1;
        }

        const body = try std.json.Stringify.valueAlloc(arena, workspace_api.WorkspaceManifestResponse{
            .ws_id = self.activeWsId() orelse "",
            .name = self.activeWorkspaceName(),
            .revision = 0,
            .rules = .{ .items = rule_items[0..rule_i] },
            .context = .{ .items = context_items[0..context_i] },
        }, .{ .whitespace = .indent_2 });

        const manifest_path = try std.fs.path.join(arena, &.{ ws_dir, "manifest.json" });
        const file = try std.fs.createFileAbsolute(manifest_path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        var write_buf: [8192]u8 = undefined;
        var writer = std.fs.File.Writer.init(file, &write_buf);
        try writer.interface.writeAll(body);
        try writer.interface.flush();
    }

    pub fn libraryCategoryForPath(
        self: *const Shell,
        path: []const u8,
    ) drafts_mod.DraftCategory {
        _ = self;
        return if (std.mem.eql(u8, path, "META_PROMPT.md")) .meta_prompt else .rule;
    }

    pub fn invalidateRemoteDetailRequests(self: *Shell) void {
        self.api_state.rule_content_cache.invalidate();
        self.api_state.rule_prs_cache.invalidate();
        self.api_state.ws_context_content_cache.invalidate();
    }

    pub fn requestSelectedRuleDetail(self: *Shell) void {
        const rules = self.getRules();
        if (self.library.selected_rule >= rules.len) return;

        const sel_path = rules[self.library.selected_rule].path;
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

    /// Path of the currently selected library rule, or null when no
    /// rule is in focus. Used by failure-caching in the on-demand
    /// consumers, which do not have a request-scoped key to attribute
    /// the failure to and fall back to the current UI selection.
    fn selectedRulePath(self: *Shell) ?[]const u8 {
        const rules = self.getRules();
        if (rules.len == 0) return null;
        const idx = @min(self.library.selected_rule, rules.len - 1);
        return rules[idx].path;
    }

    fn requestWorkspaceSelectionContent(self: *Shell, ws_d: *const api.model.WsDetail) void {
        const selection = self.currentWorkspaceFileSelection(ws_d.*) orelse return;
        switch (self.workspace.tab) {
            .context => {
                const context = switch (selection) {
                    .context => |c| c,
                    .rule => return,
                };
                if (context.is_create_draft) return;
                const key = api.state.WsPathKey{ .ws_id = ws_d.ws_id, .path = context.path };
                if (!self.api_state.ws_context_content_cache.shouldDispatch(key)) return;

                api.specs.dispatchFromState(
                    api.specs.WsContextContentParams,
                    api.specs.WsContextContentPayload,
                    api.specs.workspace_context_content,
                    &self.api_state.ws_context_content_pending,
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
                const key = api.cache.StringKey{ .value = rule.path };
                if (!self.api_state.rule_content_cache.shouldDispatch(key)) return;

                api.specs.dispatchFromState(
                    api.specs.PathParams,
                    @import("clumsies_lib").protocol.library_api.RuleContentResponse,
                    api.specs.library_rule_content,
                    &self.api_state.rule_content_pending,
                    self.api_state,
                    .{ .path = rule.path },
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
        if (live_ws) |ws_d| {
            self.requestWorkspaceSelectionContent(&ws_d);
        }
        const dir_sel = self.currentWsDirSelection();
        const file_sel = self.currentWorkspaceFileSelection(live_ws);
        var context_sel: ?usize = null;
        var context_sel_id: ?[]const u8 = null;
        var context_sel_path: ?[]const u8 = null;
        var rule_sel_idx: ?usize = null;
        var rule_sel_id: ?[]const u8 = null;
        var rule_sel_path: ?[]const u8 = null;
        if (file_sel) |selection| switch (selection) {
            .context => |c| {
                context_sel = c.idx;
                context_sel_id = c.context_id;
                context_sel_path = c.path;
            },
            .rule => |r| {
                rule_sel_idx = r.idx;
                rule_sel_id = r.rule_id;
                rule_sel_path = r.path;
            },
        };
        return workspace_panel.drawDetail(self, ctx, .{
            .live_ws = live_ws,
            .dir_sel = dir_sel,
            .context_sel = context_sel,
            .context_sel_id = context_sel_id,
            .context_sel_path = context_sel_path,
            .rule_sel_idx = rule_sel_idx,
            .rule_sel_id = rule_sel_id,
            .rule_sel_path = rule_sel_path,
        });
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

        const arena_h: u16 = dashboard_panel.ARENA_HEIGHT;
        const body_h: u16 = size.height -| arena_h;
        const preferred_rounds_w: u16 = @intCast(@divTrunc(@as(u32, size.width) * 38, 100));
        const rounds_w: u16 = @min(size.width, @max(@as(u16, 64), @min(@as(u16, 96), preferred_rounds_w)));
        const trace_w: u16 = size.width -| rounds_w;
        const usable_round_rows: u16 = body_h -| 2;
        self.dashboard.input_capacity = @max(@as(usize, 1), @as(usize, @intCast(usable_round_rows / 2)));
        if (self.analysis.input_cursor >= rounds.len and rounds.len > 0) {
            self.analysis.input_cursor = rounds.len - 1;
        }
        const max_round_cursor = std.math.maxInt(u32) / dashboard_panel.ROUND_ROW_COUNT;
        self.dashboard.round_scroll_bars.scroll_view.cursor = @intCast(@min(self.analysis.input_cursor, max_round_cursor) * dashboard_panel.ROUND_ROW_COUNT);
        self.dashboard.round_scroll_bars.scroll_view.ensureScroll();
        const selected_round = if (rounds.len > 0)
            rounds[@min(self.analysis.input_cursor, rounds.len - 1)]
        else
            null;
        const summary = dashboardSummary(ctx.arena, rounds);
        const arena_surface = try dashboard_panel.drawArena(
            self,
            ctx,
            size.width,
            arena_h,
            summary,
            rounds,
            self.analysis.input_cursor,
        );
        const rounds_surface = try dashboard_panel.drawRounds(
            self,
            ctx,
            rounds_w,
            body_h,
            rounds,
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

    // Count active drafts (status != "merged") across all categories.
    fn draftCount(self: *Shell) usize {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        const drafts = self.api_state.drafts orelse return 0;
        var count: usize = 0;
        for (drafts) |d| {
            if (!std.mem.eql(u8, d.status, "merged")) count += 1;
        }
        return count;
    }

    pub fn getPrsForRule(self: *Shell, rule_path: []const u8) []const data.PullRequestEntry {
        const prs = self.api_state.rule_prs_cache.lookup(.{ .value = rule_path }) orelse return &.{};
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        return api.view_model.toPrEntries(self.viewAllocator(), prs, rule_path, self.api_state);
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

    /// Pump the library rule content pending slot: on .ok, stash the
    /// response in the cache keyed by path so subsequent draws can
    /// retrieve it synchronously. On any error outcome, record the
    /// failure against the selected path so widget sync does not
    /// re-dispatch on every tick; the next `invalidateOnDemandCaches`
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

    /// Pump the library rule PR list pending slot. Routes the cache
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

    /// Pump the workspace context files pending slot. Stores under the
    /// ws_id the request was issued for; `state.wsDetail` combines it
    /// with the manifest half to form the view.
    fn consumeWsContextFilesResult(self: *Shell) void {
        const result = self.api_state.ws_context_files_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.ws_context_files_cache.store(.{ .value = payload.ws_id }, payload.files);
                self.system_notices.clear(.workspace_context_files);
            },
            else => {
                if (self.activeWsId()) |ws_id| {
                    self.api_state.ws_context_files_cache.markFailed(.{ .value = ws_id });
                    const text: []const u8 = if (self.hasLocalWorkspaceDetail(ws_id))
                        "Workspace context failed; showing local cache."
                    else
                        "Workspace context failed.";
                    self.system_notices.push(.workspace_context_files, .failure, .persistent, text);
                }
            },
        }
    }

    fn consumeWsManifestResult(self: *Shell) void {
        const result = self.api_state.ws_manifest_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.ws_manifest_cache.store(.{ .value = payload.ws_id }, payload.rules);
                self.system_notices.clear(.workspace_manifest);
            },
            else => {
                if (self.activeWsId()) |ws_id| {
                    self.api_state.ws_manifest_cache.markFailed(.{ .value = ws_id });
                    const text: []const u8 = if (self.hasLocalWorkspaceDetail(ws_id))
                        "Workspace manifest failed; showing local cache."
                    else
                        "Workspace manifest failed.";
                    self.system_notices.push(.workspace_manifest, .failure, .persistent, text);
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
        const rules = self.getRules();
        const rule_idx = @min(self.library.selected_rule, if (rules.len > 0) rules.len - 1 else 0);
        if (rules.len == 0) return null;
        const prs = self.getPrsForRule(rules[rule_idx].path);
        if (prs.len == 0) return null;
        const pr_idx = @min(self.review.selected_pr_idx, prs.len - 1);
        return prs[pr_idx].id;
    }

    /// Recompute the 8 derived pr_detail_* fields from the just-fetched
    /// response. Picking the active operation requires the currently
    /// cached library PR list so the op matching the selected rule
    /// is surfaced first.
    fn refreshPrDetailDerivedFields(
        self: *Shell,
        pr_id: []const u8,
        resp: @import("clumsies_lib").protocol.collab_api.RulePrDetailResponse,
    ) void {
        const alloc = self.api_state.allocator();

        const rules = self.getRules();
        const rule_idx = @min(self.library.selected_rule, if (rules.len > 0) rules.len - 1 else 0);
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
            diff_lines = w.computeDiffLines(alloc, base, proposed);
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
    /// outcome as an operation toast; body payloads are void so the
    /// Result carries only ok / api_error / network_error /
    /// invalid_response.
    fn consumeSignOutResult(self: *Shell) void {
        const result = self.api_state.sign_out_pending.consume() orelse return;
        switch (result) {
            .ok => self.notifyOp(.success, "Token revoked. Please re-login."),
            .api_error => |e| self.notifyOp(.failure, writeErrorStatus(self, "Token revoke failed", e)),
            .network_error => self.notifyOp(.failure, "Token revoke failed: network error."),
            .invalid_response => self.notifyOp(.failure, "Token revoke failed: malformed response."),
        }
    }

    fn consumeSubmitCommentResult(self: *Shell) void {
        const result = self.api_state.submit_comment_pending.consume() orelse return;
        switch (result) {
            .ok => self.notifyOp(.success, "Comment submitted."),
            .api_error => |e| self.notifyOp(.failure, writeErrorStatus(self, "Comment submission failed", e)),
            .network_error => self.notifyOp(.failure, "Comment submission failed: network error."),
            .invalid_response => self.notifyOp(.failure, "Comment submission failed: malformed response."),
        }
    }

    fn consumePrActionResult(self: *Shell) void {
        const result = self.api_state.pr_action_pending.consume() orelse return;
        switch (result) {
            .ok => self.notifyOp(.success, "PR action applied."),
            .api_error => |e| self.notifyOp(.failure, writeErrorStatus(self, "PR action failed", e)),
            .network_error => self.notifyOp(.failure, "PR action failed: network error."),
            .invalid_response => self.notifyOp(.failure, "PR action failed: malformed response."),
        }
    }

    fn consumeAttestationUploadResult(self: *Shell) void {
        const result = self.api_state.attestation_upload_pending.consume() orelse return;
        switch (result) {
            .ok => |summary| {
                self.system_notices.clear(.attestation_upload);
                if (summary.events_sent == 0) return;
                const message = std.fmt.allocPrint(
                    self.api_state.allocator(),
                    "Uploaded attestation logs: {d} events from {d} workspaces.",
                    .{ summary.events_sent, summary.workspace_count },
                ) catch "Uploaded attestation logs.";
                self.system_notices.push(.attestation_upload, .success, .transient, message);
                api.fetch.refetchAllAsync(self.api_state);
            },
            .not_authenticated => {
                self.system_notices.clear(.attestation_upload);
            },
            .failed => |name| {
                const message = std.fmt.allocPrint(
                    self.api_state.allocator(),
                    "Attestation upload failed: {s}; restart TUI after fixing Hub or auth.",
                    .{name},
                ) catch "Attestation upload failed; restart TUI after fixing Hub or auth.";
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
        const result = self.api_state.ws_context_content_pending.consume() orelse return;
        switch (result) {
            .ok => |payload| {
                self.api_state.ws_context_content_cache.store(
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
                self.api_state.ws_context_content_cache.markFailed(
                    .{ .ws_id = ws_d.ws_id, .path = context.path },
                );
                self.system_notices.push(.workspace_context_content, .failure, .persistent, "Workspace context content failed; showing local cache when available.");
            },
        }
    }

    fn submitComment(self: *Shell) void {
        const all_p = self.getRules();
        const si = @min(self.library.selected_rule, if (all_p.len > 0) all_p.len - 1 else 0);
        if (all_p.len == 0) return;
        const prs_for = self.getPrsForRule(all_p[si].path);
        const pri = @min(self.review.selected_pr_idx, if (prs_for.len > 0) prs_for.len - 1 else 0);
        if (prs_for.len == 0) return;

        const comment_text = self.review.comment_input_buf[0..self.review.comment_input_len];
        api.specs.dispatchFromState(
            api.specs.SubmitCommentParams,
            void,
            api.specs.submit_comment,
            &self.api_state.submit_comment_pending,
            self.api_state,
            .{ .pr_id = prs_for[pri].id, .body = comment_text },
        );
        self.notifyOp(.loading, "Submitting comment...");
    }

    pub fn doPrAction(self: *Shell, action: []const u8) void {
        const all_p = self.getRules();
        const si = @min(self.library.selected_rule, if (all_p.len > 0) all_p.len - 1 else 0);
        if (all_p.len == 0) return;
        const prs_for = self.getPrsForRule(all_p[si].path);
        const pri = @min(self.review.selected_pr_idx, if (prs_for.len > 0) prs_for.len - 1 else 0);
        if (prs_for.len == 0) return;

        api.specs.dispatchFromState(
            api.specs.PrActionParams,
            void,
            api.specs.pr_action,
            &self.api_state.pr_action_pending,
            self.api_state,
            .{ .pr_id = prs_for[pri].id, .action = action },
        );
        self.notifyOp(.loading, if (std.mem.eql(u8, action, "accept")) "Accepting PR..." else "Rejecting PR...");
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
        if (self.api_state.ws_detail) |ws_d| return ws_d.context_files.len;
        return 0;
    }

    fn wsRulesCount(self: *Shell) usize {
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
            .{ .key = "\xe2\x86\x91/\xe2\x86\x93", .label = "same as j/k in lists and tables" },
            .{ .key = "h/l", .label = "switch inner tabs when a panel has them" },
            .{ .key = "Tab", .label = "switch focus between panels or regions" },
            .{ .key = "Enter", .label = "open, toggle, or confirm the selected item" },
            .{ .key = "Esc", .label = "go back, close a drawer, or leave detail focus" },
        });
        if (row < body_h) row += 1;
        row = self.drawHelpSection(&body, ctx, row, "Application", &.{
            .{ .key = "1-4", .label = "switch the top-level module" },
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

    fn drawConfirmOverlay(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
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

    fn drawCommentEditorOverlay(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();

        // Title: show reply context or "New Comment"
        const all_rules = self.getRules();
        const sel_idx = @min(self.library.selected_rule, if (all_rules.len > 0) all_rules.len - 1 else 0);
        const title = if (all_rules.len > 0) blk: {
            const p = &all_rules[sel_idx];
            const prs = self.getPrsForRule(p.path);
            break :blk if (prs.len > 0 and self.review.selected_pr_idx < prs.len)
                try std.fmt.allocPrint(ctx.arena, "Comment on {s}", .{prs[self.review.selected_pr_idx].id})
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
        const input_text = self.review.comment_input_buf[0..self.review.comment_input_len];
        const max_visible: usize = @as(usize, box_w -| 4);
        const visible_start = if (input_text.len > max_visible) input_text.len - max_visible else 0;
        const visible = input_text[visible_start..];
        const display = try std.fmt.allocPrint(ctx.arena, "{s}_", .{visible});
        w.writeText(&surface, ctx, result.content_col, result.content_row, display, theme.textOn(theme.PANEL_ALT, theme.TEXT));

        return surface;
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
            .library => "Bundle facet, rule list, and passive preview.",
            .workspace => "Workspace list and sync status detail.",
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
        self.drafts.ready = 0;
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
                .merged, .rejected => continue,
                else => {},
            }
            self.drafts.total += 1;
            if (entry.status == .ready) self.drafts.ready += 1;

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
        library_panel.syncLibraryTree(self);
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

    /// Read the current draft bytes for a file, allocated in
    /// view_arena so the caller can use the slice for the remainder of
    /// the current frame. Returns null when no draft is tracked or
    /// the file is missing / unreadable. Both Library and Workspace
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
        const arena = self.viewAllocator();
        const ws_dir = workspace_config.getWsDir(arena, ws_id) catch return null;
        return drafts_mod.readDraftFile(arena, ws_dir, category, path) catch null;
    }

    /// Derive the draft target from the currently focused module and
    /// its selection. Returns null when the active module doesn't have
    /// an editable selection (e.g. no workspace bound or a directory
    /// row is highlighted). Workspace context create-draft rows remain
    /// editable even before hub detail has loaded.
    pub fn selectedDraftTarget(self: *Shell) ?DraftTarget {
        const ws_id = self.activeWsId() orelse return null;
        switch (self.selected_module) {
            .library => {
                const rules = self.getRules();
                if (self.library.selected_rule < rules.len) {
                    const rule = &rules[self.library.selected_rule];
                    return .{
                        .ws_id = ws_id,
                        .category = self.libraryCategoryForPath(rule.path),
                        .path = rule.path,
                        .rule_id = self.lookupRuleId(rule.path),
                    };
                }
                // Virtual row: a local create-op draft that has no
                // server-side rule yet. The index is offset by
                // `rules.len` so we can recover the create-draft
                // path from drafts_create_rule_paths.
                const k = self.library.selected_rule - rules.len;
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
            .library => {
                const rules = self.getRules();
                if (self.library.selected_rule >= rules.len) return null;
                return self.lookupRuleId(rules[self.library.selected_rule].path);
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
                    self.notifyOp(.failure, @errorName(err));
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
            self.notifyOp(.failure, @errorName(err));
            return;
        };
        switch (result) {
            .completed => self.notifyOp(.success, "Draft saved."),
            .failed => self.notifyOp(.failure, "Editor exited non-zero."),
            .editor_not_found => self.notifyOp(.failure, "No $EDITOR resolved."),
            .spawn_failed => self.notifyOp(.failure, "Editor spawn failed."),
        }
        self.refreshDraftsCache();
    }

    /// Pull the authoritative bytes for a file so a new modify-draft
    /// can seed its copy. Rules pull from the library cache; context
    /// files from the workspace context content cache.
    fn seedContentForTarget(self: *Shell, target: DraftTarget) ?[]const u8 {
        return switch (target.category) {
            .rule => self.cachedRuleBody(target.path),
            .context => self.cachedWorkspaceContextBody(target.ws_id, target.path),
            .meta_prompt => self.cachedMetaPromptBody(),
        };
    }

    /// Handler for the `m` key. Flips between `editing` and `ready`.
    /// Submitted / merged / rejected / conflicted drafts are not
    /// toggled — they represent terminal or pending-review state.
    pub fn toggleSelectedDraftReady(self: *Shell) void {
        self.refreshDraftsCache();
        const target = self.selectedDraftTarget() orelse return;
        const current = self.draftStatusFor(target.category, target.path) orelse {
            self.notifyOp(.warning, "No draft to mark ready.");
            return;
        };
        const next_status: drafts_mod.DraftStatus = switch (current) {
            .editing => .ready,
            .ready => .editing,
            else => {
                self.notifyOp(.warning, "Draft status is locked.");
                return;
            },
        };

        const alloc = self.api_state.allocator();
        const ws_dir = workspace_config.getWsDir(alloc, target.ws_id) catch return;
        defer alloc.free(ws_dir);
        drafts_mod.setDraftStatus(alloc, ws_dir, target.category, target.path, next_status) catch |err| {
            self.notifyOp(.failure, @errorName(err));
            return;
        };
        self.notifyOp(.success, if (next_status == .ready) "Draft marked ready." else "Draft marked editing.");
        self.refreshDraftsCache();
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
        const path_copy = self.api_state.allocator().dupe(u8, target.path) catch {
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
            self.workspace.show_diff = false;
        }
    }

    /// Handler for the `p` key. Opens the PR Composer when the
    /// selected file has a ready draft. The composer is intentionally
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
        if (status != .ready) {
            self.notifyOp(.warning, "Draft must be marked ready (m) before submit.");
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
        self.drafts.pr_composer_desc_len = 0;
        self.drafts.pr_composer_submitting = false;
        self.drafts.show_pr_composer = true;
    }

    fn lookupDraftOperation(self: *Shell, target: DraftTarget) ?drafts_mod.DraftOperation {
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
        self.drafts.pr_composer_desc_len = 0;
        self.releaseComposerTarget();
    }

    pub fn submitPrComposer(self: *Shell) void {
        if (self.drafts.pr_composer_submitting) return;
        if (self.drafts.pr_composer_desc_len == 0) {
            self.notifyOp(.warning, "Description is required.");
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

        const content = drafts_mod.readDraftFile(alloc, ws_dir, target.category, target.path) catch |err| {
            self.notifyOp(.failure, @errorName(err));
            return null;
        };
        errdefer alloc.free(content);

        var index = drafts_mod.loadIndex(alloc, ws_dir) catch |err| {
            self.notifyOp(.failure, @errorName(err));
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

    fn submitRulePr(self: *Shell, target: DraftTarget) void {
        const alloc = self.api_state.allocator();
        const read = self.readDraftForSubmit(alloc, target) orelse return;
        defer alloc.free(read.ws_dir);
        defer alloc.free(read.content);
        defer if (read.entry) |e| {
            if (e.base_hash) |h| alloc.free(h);
        };

        const entry = read.entry orelse {
            self.notifyOp(.warning, "Draft entry missing; try again.");
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

        const desc_copy = alloc.dupe(u8, self.drafts.pr_composer_desc_buf[0..self.drafts.pr_composer_desc_len]) catch return;
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
                self.notifyOp(.warning, "Unknown rule id for this draft.");
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
                .description = desc_copy,
                .operation_type = operation_type,
                .rule_id = rule_id_copy_opt,
                .path = path_copy_opt,
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

        const desc_copy = alloc.dupe(u8, self.drafts.pr_composer_desc_buf[0..self.drafts.pr_composer_desc_len]) catch return;
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
                .description = desc_copy,
                .operation_type = operation_type,
                .context_id = context_id_copy_opt,
                .path = path_copy_opt,
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
        if (key.matches(vaxis.Key.enter, .{})) {
            self.submitPrComposer();
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.drafts.pr_composer_desc_len > 0) {
                self.drafts.pr_composer_desc_len -= 1;
                ctx.consumeAndRedraw();
            }
            return;
        }
        if (key.text) |text| {
            const remaining = self.drafts.pr_composer_desc_buf.len - self.drafts.pr_composer_desc_len;
            if (text.len > 0 and text.len <= remaining) {
                @memcpy(self.drafts.pr_composer_desc_buf[self.drafts.pr_composer_desc_len..][0..text.len], text);
                self.drafts.pr_composer_desc_len += text.len;
                ctx.consumeAndRedraw();
            }
        } else if (key.codepoint >= 0x20 and key.codepoint < 0x7f) {
            if (self.drafts.pr_composer_desc_len < self.drafts.pr_composer_desc_buf.len) {
                self.drafts.pr_composer_desc_buf[self.drafts.pr_composer_desc_len] = @intCast(key.codepoint);
                self.drafts.pr_composer_desc_len += 1;
                ctx.consumeAndRedraw();
            }
        }
    }

    fn drawPrComposerOverlay(self: *Shell, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const box_w = @min(size.width -| 4, 60);
        const box_h: u16 = 9;
        const target = self.drafts.pr_composer_target orelse DraftTarget{
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
            .footer = if (self.drafts.pr_composer_submitting) "Submitting... Esc cancel wait" else "Enter submit  Esc cancel",
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        const row = result.content_row;

        w.writeText(&surface, ctx, col, row, path_label, theme.textOn(theme.PANEL_ALT, theme.MUTED));
        w.writeText(&surface, ctx, col + 8, row, target.path, theme.boldOn(theme.PANEL_ALT, theme.TEXT));
        w.writeText(&surface, ctx, col, row + 1, "op:", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        const op_label: []const u8 = switch (self.drafts.pr_composer_operation) {
            .create => "create",
            .modify => "modify",
            .rename => "rename",
            .delete => "delete",
        };
        w.writeText(&surface, ctx, col + 8, row + 1, op_label, theme.textOn(theme.PANEL_ALT, theme.TEXT));

        w.writeText(&surface, ctx, col, row + 3, "description:", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        const desc_text = self.drafts.pr_composer_desc_buf[0..self.drafts.pr_composer_desc_len];
        const max_visible: usize = @as(usize, box_w -| 4);
        const visible_start = if (desc_text.len > max_visible) desc_text.len - max_visible else 0;
        const visible = desc_text[visible_start..];
        const display = try std.fmt.allocPrint(ctx.arena, "{s}_", .{visible});
        w.writeText(&surface, ctx, col, row + 4, display, theme.textOn(theme.PANEL_ALT, theme.TEXT));

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
        const box_h: u16 = 7;
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
            .footer = "Enter create & edit  Esc cancel",
        };
        const result = try modal.draw(ctx, self.widget());
        var surface = result.surface;
        const col = result.content_col;
        const row = result.content_row;

        w.writeText(&surface, ctx, col, row, "path:", theme.textOn(theme.PANEL_ALT, theme.MUTED));
        const path_text = self.drafts.new_draft_path_buf[0..self.drafts.new_draft_path_len];
        const max_visible: usize = @as(usize, box_w -| 4);
        const visible_start = if (path_text.len > max_visible) path_text.len - max_visible else 0;
        const visible = path_text[visible_start..];
        const display = try std.fmt.allocPrint(ctx.arena, "{s}_", .{visible});
        w.writeText(&surface, ctx, col, row + 1, display, theme.textOn(theme.PANEL_ALT, theme.TEXT));
        w.writeText(&surface, ctx, col, row + 3, hint, theme.fg(theme.MUTED));

        return surface;
    }

    fn consumeCreateRulePrResult(self: *Shell) void {
        const result = self.api_state.create_rule_pr_pending.consume() orelse return;
        self.drafts.pr_composer_submitting = false;
        switch (result) {
            .ok => |resp| {
                self.markComposerSubmitted(resp.pr_id, resp.status);
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
                self.markComposerSubmitted(resp.pr_id, resp.status);
            },
            .api_error => |e| self.notifyOp(.failure, writeErrorStatus(self, "PR submit failed", e)),
            .network_error => self.notifyOp(.failure, "PR submit failed: network error."),
            .invalid_response => self.notifyOp(.failure, "PR submit failed: malformed response."),
        }
    }

    /// Shared post-submit path for both rule and context PRs. Marks
    /// the draft as submitted against disk, refreshes the in-memory
    /// cache, closes the composer, and posts a user-facing confirmation.
    fn markComposerSubmitted(self: *Shell, pr_id: []const u8, status: []const u8) void {
        const target = self.drafts.pr_composer_target orelse return;
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
        self.drafts.show_pr_composer = false;
        self.drafts.pr_composer_desc_len = 0;
        self.releaseComposerTarget();
        const message = std.fmt.allocPrint(
            self.api_state.allocator(),
            "PR {s} submitted ({s}).",
            .{ pr_id, status },
        ) catch "PR submitted.";
        self.notifyOp(.success, message);
    }

    fn selectTab(self: *Shell, ctx: *vxfw.EventContext, tab: TopModule) void {
        self.selected_module = tab;
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
            else => {},
        }
        ctx.consumeAndRedraw();
    }

    pub fn shiftDetailTab(self: *Shell, delta: i8) void {
        const current: i8 = @intCast(@intFromEnum(self.review.detail_tab));
        const count: i8 = @intCast(rule_detail_panel.detail_tabs.len);
        const next = @mod(current + delta + count, count);
        self.review.detail_tab = @enumFromInt(@as(u8, @intCast(next)));
        self.review.show_comment_editor = false;
        self.review.pr_filter = .open;
        self.review.selected_pr_idx = 0;
        self.review.show_diff = false;
        self.review.pr_scroll_bars.scroll_view.cursor = 0;
    }

    pub fn shiftWsTab(self: *Shell, delta: i8) void {
        const current: i8 = @intCast(@intFromEnum(self.workspace.tab));
        const count: i8 = @intCast(workspace_panel.tabs.len);
        const next = @mod(current + delta + count, count);
        self.workspace.tab = @enumFromInt(@as(u8, @intCast(next)));
    }
};
