//! Settings feature container. Renders account, workspace, organization,
//! and token panes and handles settings-mode navigation.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../../theme.zig");
const w = @import("../../widgets.zig");
const data = @import("../../models/view_types.zig");
const api = @import("../../api.zig");
const workspace_config = @import("../../../workspace_config.zig");

pub const Tab = enum(u8) {
    account,
    preferences,
    workspaces,
    organization,
    token,

    pub fn label(self: Tab) []const u8 {
        return switch (self) {
            .account => "Account",
            .preferences => "Preferences",
            .workspaces => "Workspaces",
            .organization => "Organization",
            .token => "Token",
        };
    }
};

pub const Focus = enum { sidebar, content };
pub const WorkspaceFocus = enum { list, members };

pub const State = struct {
    tab: Tab = .account,
    focus: Focus = .sidebar,
    content_sel: usize = 0,
    workspace_focus: WorkspaceFocus = .list,
    workspace_member_sel: usize = 0,
};

pub fn drawSettings(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const SettingsTab = @TypeOf(self.settings.tab);
    const settings_tabs = [_]SettingsTab{ .account, .preferences, .workspaces, .organization, .token };

    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.PANEL);

    const sidebar_w: u16 = 18;
    const sidebar_border = theme.focusBorder(self.settings.focus == .sidebar);
    var sidebar = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = sidebar_w, .height = size.height });
    w.fillSurface(&sidebar, theme.PANEL);
    w.drawBorder(&sidebar, sidebar_border, theme.PANEL);
    w.writeText(&sidebar, ctx, 2, 0, "Settings", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 1;
    for (settings_tabs) |tab| {
        const is_sel = tab == self.settings.tab;
        if (is_sel) {
            w.writeCursorMarker(&sidebar, 1, row);
        }
        const style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
        w.writeText(&sidebar, ctx, 2, row, settingsTabLabel(tab), style);
        row += 1;
    }

    const content_w = size.width -| sidebar_w -| 1;
    const content_ctx = ctx.withConstraints(
        .{ .width = content_w, .height = size.height },
        .{ .width = content_w, .height = size.height },
    );
    const content = switch (self.settings.tab) {
        .account => try drawSettingsAccount(self, content_ctx),
        .preferences => try drawSettingsPreferences(self, content_ctx),
        .workspaces => try drawSettingsWorkspaces(self, content_ctx),
        .organization => try drawSettingsOrg(self, content_ctx),
        .token => try drawSettingsToken(self, content_ctx),
    };

    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = sidebar };
    children[1] = .{ .origin = .{ .row = 0, .col = sidebar_w + 1 }, .surface = content };
    root.children = children;
    return root;
}

pub fn handleEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches(vaxis.Key.escape, .{})) {
        if (self.settings.tab == .workspaces and self.settings.focus == .content and self.settings.workspace_focus == .members) {
            self.settings.workspace_focus = .list;
            ctx.consumeAndRedraw();
            return;
        }
        self.show_settings = false;
        self.settings.focus = .sidebar;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
        shiftSettingsFocus(self, -1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.tab, .{})) {
        shiftSettingsFocus(self, 1);
        ctx.consumeAndRedraw();
        return;
    }
    if (handlePageAction(self, ctx, key)) return;
    if (self.settings.focus == .sidebar) {
        handleSidebarEvent(self, ctx, key);
    } else {
        handleContentEvent(self, ctx, key);
    }
}

fn shiftSettingsFocus(self: anytype, delta: i8) void {
    if (self.settings.tab != .workspaces) {
        self.settings.focus = if (self.settings.focus == .sidebar) .content else .sidebar;
        self.settings.workspace_focus = .list;
        return;
    }

    const current: i8 = if (self.settings.focus == .sidebar)
        0
    else switch (self.settings.workspace_focus) {
        .list => 1,
        .members => 2,
    };
    const next = @mod(current + delta + 3, 3);
    switch (next) {
        0 => {
            self.settings.focus = .sidebar;
            self.settings.workspace_focus = .list;
        },
        1 => {
            self.settings.focus = .content;
            self.settings.workspace_focus = .list;
        },
        2 => {
            self.settings.focus = .content;
            self.settings.workspace_focus = .members;
            self.settings.workspace_member_sel = 0;
        },
        else => unreachable,
    }
}

pub fn shortcuts(self: anytype) []const w.Shortcut {
    return switch (self.settings.tab) {
        .account => &.{
            .{ .key = "Tab", .label = "switch focus" },
            .{ .key = "u", .label = "change username" },
            .{ .key = "c", .label = "change password" },
            .{ .key = "x", .label = "sign out" },
            .{ .key = "Esc", .label = "back" },
        },
        .preferences => &.{
            .{ .key = "e", .label = "edit viewer" },
            .{ .key = "x", .label = "clear viewer" },
            .{ .key = "t", .label = "test viewer" },
            .{ .key = "Tab", .label = "switch focus" },
            .{ .key = "Esc", .label = "back" },
        },
        .workspaces => if (self.settings.workspace_focus == .members) &.{
            .{ .key = "j/k", .label = "move" },
            .{ .key = "a", .label = "add member" },
            .{ .key = "r", .label = "change role" },
            .{ .key = "x", .label = "remove" },
            .{ .key = "Tab", .label = "next panel" },
            .{ .key = "Esc", .label = "workspaces" },
        } else &.{
            .{ .key = "j/k", .label = "move" },
            .{ .key = "Enter", .label = "open" },
            .{ .key = "Tab", .label = "next panel" },
            .{ .key = "n", .label = "create" },
            .{ .key = "r", .label = "rename" },
            .{ .key = "p", .label = "bind cwd" },
            .{ .key = "x", .label = "delete" },
            .{ .key = "Esc", .label = "back" },
        },
        .organization => if (self.canManageMembers()) &.{
            .{ .key = "j/k", .label = "move" },
            .{ .key = "Enter", .label = "open" },
            .{ .key = "Tab", .label = "switch focus" },
            .{ .key = "a", .label = "invite" },
            .{ .key = "r", .label = "change role" },
            .{ .key = "x", .label = "remove" },
            .{ .key = "Esc", .label = "back" },
        } else &.{
            .{ .key = "j/k", .label = "move" },
            .{ .key = "Enter", .label = "open" },
            .{ .key = "Tab", .label = "switch focus" },
            .{ .key = "Esc", .label = "back" },
        },
        .token => &.{
            .{ .key = "j/k", .label = "move" },
            .{ .key = "Enter", .label = "open" },
            .{ .key = "Tab", .label = "switch focus" },
            .{ .key = "r", .label = "rotate token" },
            .{ .key = "x", .label = "revoke" },
            .{ .key = "Esc", .label = "back" },
        },
    };
}

fn handlePageAction(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) bool {
    switch (self.settings.tab) {
        .account => {
            if (key.matches('x', .{})) {
                self.confirm_message = "sign out";
                self.confirm_action = .revoke_token;
                self.show_confirm = true;
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('c', .{})) {
                self.openPasswordDialog();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('u', .{})) {
                self.openUsernameDialog();
                ctx.consumeAndRedraw();
                return true;
            }
        },
        .preferences => {
            if (key.matches('e', .{})) {
                self.openMarkdownViewerDialog();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('x', .{})) {
                self.clearMarkdownViewerPreference();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('t', .{})) {
                self.testMarkdownViewerPreference();
                ctx.consumeAndRedraw();
                return true;
            }
        },
        .workspaces => {
            if (key.matches('n', .{})) {
                self.settings.workspace_focus = .list;
                self.openCreateWorkspace();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('r', .{}) and self.settings.workspace_focus == .list) {
                self.openRenameWorkspace();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('r', .{}) and self.settings.workspace_focus == .members) {
                self.openChangeWorkspaceMemberRoleDialog();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('x', .{}) and self.settings.workspace_focus == .list) {
                self.openWorkspaceDeleteConfirm();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('x', .{}) and self.settings.workspace_focus == .members) {
                self.openRemoveWorkspaceMemberConfirm();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('p', .{}) and self.settings.workspace_focus == .list) {
                self.bindCurrentDirectoryToSelectedWorkspace();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('a', .{})) {
                self.openAddWorkspaceMemberDialog();
                ctx.consumeAndRedraw();
                return true;
            }
        },
        .organization => {
            if (key.matches('r', .{})) {
                if (!self.ensureMemberManagementAllowed()) {
                    ctx.consumeAndRedraw();
                    return true;
                }
                self.openChangeMemberRoleDialog();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('x', .{})) {
                if (!self.ensureMemberManagementAllowed()) {
                    ctx.consumeAndRedraw();
                    return true;
                }
                self.openRemoveMemberConfirm();
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('a', .{})) {
                if (!self.ensureMemberManagementAllowed()) {
                    ctx.consumeAndRedraw();
                    return true;
                }
                self.openInviteMemberDialog();
                ctx.consumeAndRedraw();
                return true;
            }
        },
        .token => {
            if (key.matches('r', .{})) {
                self.notifyOp(.info, "Token rotation (not yet implemented)");
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('x', .{})) {
                self.confirm_message = "current token";
                self.confirm_action = .revoke_token;
                self.show_confirm = true;
                ctx.consumeAndRedraw();
                return true;
            }
        },
    }
    return false;
}

fn shiftSettingsTab(self: anytype, delta: i8) void {
    const SettingsTab = @TypeOf(self.settings.tab);
    const settings_tabs = [_]SettingsTab{ .account, .preferences, .workspaces, .organization, .token };

    const previous_tab = self.settings.tab;
    const current: i8 = @intCast(@intFromEnum(self.settings.tab));
    const count: i8 = @intCast(settings_tabs.len);
    const next = @mod(current + delta + count, count);
    self.settings.tab = @enumFromInt(@as(u8, @intCast(next)));
    self.settings.workspace_focus = .list;
    self.settings.workspace_member_sel = 0;
    if (previous_tab != self.settings.tab and self.settings.tab == .workspaces) {
        self.refreshSettingsWorkspaces();
    }
}

fn orgMemberCount(self: anytype) usize {
    self.api_state.mutex.lockUncancelable(std.Options.debug_io);
    defer self.api_state.mutex.unlock(std.Options.debug_io);
    if (self.api_state.members) |dir| return dir.members.len;
    return 0;
}

fn accountWorkspaceCount(self: anytype) usize {
    self.api_state.mutex.lockUncancelable(std.Options.debug_io);
    defer self.api_state.mutex.unlock(std.Options.debug_io);
    if (self.api_state.current_user) |u| return u.workspaces.len;
    return 0;
}

fn selectedWorkspaceMemberCount(self: anytype) usize {
    self.api_state.mutex.lockUncancelable(std.Options.debug_io);
    defer self.api_state.mutex.unlock(std.Options.debug_io);
    const user = self.api_state.current_user orelse return 0;
    if (user.workspaces.len == 0) return 0;
    const idx = @min(self.settings.content_sel, user.workspaces.len - 1);
    const ws_id = user.workspaces[idx].ws_id;
    if (self.api_state.workspace_members_cache.lookup(.{ .value = ws_id })) |members| return members.len;
    return 0;
}

fn handleSidebarEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        shiftSettingsTab(self, 1);
        self.settings.content_sel = 0;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        shiftSettingsTab(self, -1);
        self.settings.content_sel = 0;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        self.settings.focus = .content;
        self.settings.content_sel = 0;
        ctx.consumeAndRedraw();
        return;
    }
}

fn handleContentEvent(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches(vaxis.Key.escape, .{})) {
        if (self.settings.tab == .workspaces and self.settings.workspace_focus == .members) {
            self.settings.workspace_focus = .list;
            ctx.consumeAndRedraw();
            return;
        }
        self.settings.focus = .sidebar;
        ctx.consumeAndRedraw();
        return;
    }
    const max_items: usize = switch (self.settings.tab) {
        .account => 0,
        .preferences => 0,
        .workspaces => if (self.settings.workspace_focus == .members) selectedWorkspaceMemberCount(self) else accountWorkspaceCount(self),
        .organization => orgMemberCount(self),
        .token => data.ALL_SCOPES.len,
    };
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (self.settings.tab == .workspaces and self.settings.workspace_focus == .members) {
            if (self.settings.workspace_member_sel + 1 < max_items)
                self.settings.workspace_member_sel += 1;
        } else {
            if (self.settings.content_sel + 1 < max_items)
                self.settings.content_sel += 1;
        }
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.settings.tab == .workspaces and self.settings.workspace_focus == .members) {
            if (self.settings.workspace_member_sel > 0)
                self.settings.workspace_member_sel -= 1;
        } else {
            if (self.settings.content_sel > 0)
                self.settings.content_sel -= 1;
        }
        ctx.consumeAndRedraw();
        return;
    }

    switch (self.settings.tab) {
        .account => handleAccountAction(self, ctx, key),
        .preferences => handlePreferencesAction(self, ctx, key),
        .workspaces => handleWorkspacesAction(self, ctx, key),
        .organization => handleOrganizationAction(self, ctx, key),
        .token => handleTokenAction(self, ctx, key),
    }
}

fn handleAccountAction(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches('x', .{})) {
        self.confirm_message = "sign out";
        self.confirm_action = .revoke_token;
        self.show_confirm = true;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('c', .{})) {
        self.openPasswordDialog();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('u', .{})) {
        self.openUsernameDialog();
        ctx.consumeAndRedraw();
    }
}

fn handlePreferencesAction(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches('e', .{})) {
        self.openMarkdownViewerDialog();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('x', .{})) {
        self.clearMarkdownViewerPreference();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('t', .{})) {
        self.testMarkdownViewerPreference();
        ctx.consumeAndRedraw();
    }
}

fn handleWorkspacesAction(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches(vaxis.Key.enter, .{})) {
        if (self.settings.workspace_focus == .members) return;
        const ws_count = accountWorkspaceCount(self);
        if (ws_count == 0) return;
        const sel = @min(self.settings.content_sel, ws_count - 1);
        self.selectWorkspaceIndex(sel);
        self.show_settings = false;
        self.settings.focus = .sidebar;
        self.selected_module = .workspace;
        self.workspace.focus = .list;
        self.workspace.show_drawer = false;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('n', .{})) {
        self.settings.workspace_focus = .list;
        self.openCreateWorkspace();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('r', .{}) and self.settings.workspace_focus == .list) {
        self.openRenameWorkspace();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('r', .{}) and self.settings.workspace_focus == .members) {
        self.openChangeWorkspaceMemberRoleDialog();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('x', .{}) and self.settings.workspace_focus == .list) {
        self.openWorkspaceDeleteConfirm();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('x', .{}) and self.settings.workspace_focus == .members) {
        self.openRemoveWorkspaceMemberConfirm();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('p', .{}) and self.settings.workspace_focus == .list) {
        self.bindCurrentDirectoryToSelectedWorkspace();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('a', .{})) {
        self.openAddWorkspaceMemberDialog();
        ctx.consumeAndRedraw();
        return;
    }
}

fn handleOrganizationAction(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches('r', .{})) {
        if (!self.ensureMemberManagementAllowed()) {
            ctx.consumeAndRedraw();
            return;
        }
        self.openChangeMemberRoleDialog();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('x', .{})) {
        if (!self.ensureMemberManagementAllowed()) {
            ctx.consumeAndRedraw();
            return;
        }
        self.openRemoveMemberConfirm();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('a', .{})) {
        if (!self.ensureMemberManagementAllowed()) {
            ctx.consumeAndRedraw();
            return;
        }
        self.openInviteMemberDialog();
        ctx.consumeAndRedraw();
    }
}

fn handleTokenAction(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches('r', .{})) {
        self.notifyOp(.info, "Token rotation (not yet implemented)");
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('x', .{})) {
        self.confirm_message = "current token";
        self.confirm_action = .revoke_token;
        self.show_confirm = true;
        ctx.consumeAndRedraw();
    }
}

fn settingsTabLabel(tab: anytype) []const u8 {
    return switch (tab) {
        .account => "Account",
        .preferences => "Preferences",
        .workspaces => "Workspaces",
        .organization => "Organization",
        .token => "Token",
    };
}

fn drawSettingsAccount(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const focused = self.settings.focus == .content;
    const UserView = struct {
        user_id: []const u8,
        username: []const u8,
        role: []const u8,
    };

    const user: UserView = blk: {
        self.api_state.mutex.lockUncancelable(std.Options.debug_io);
        defer self.api_state.mutex.unlock(std.Options.debug_io);
        if (self.api_state.current_user) |u|
            break :blk .{ .user_id = u.user_id, .username = u.username, .role = u.role };
        break :blk .{ .user_id = "\xe2\x80\x94", .username = "\xe2\x80\x94", .role = "\xe2\x80\x94" };
    };
    const cfg: data.ClientConfig = blk: {
        self.api_state.mutex.lockUncancelable(std.Options.debug_io);
        defer self.api_state.mutex.unlock(std.Options.debug_io);
        const url = if (self.api_state.server_url) |u| u else "\xe2\x80\x94";
        if (self.api_state.current_user) |_|
            break :blk .{ .server_url = url, .sync_strategy = "session", .token_status = "active", .token_expires = "\xe2\x80\x94" };
        break :blk .{ .server_url = url, .sync_strategy = "\xe2\x80\x94", .token_status = "\xe2\x80\x94", .token_expires = "\xe2\x80\x94" };
    };

    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(focused), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Account", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 1;

    row = w.writeSectionHeader(&surface, ctx, 2, row, "Profile");
    row = w.writeKv(&surface, ctx, 4, row, "Username", user.username, 14);
    w.writeText(&surface, ctx, 30, row - 1, "[ Change ]", theme.fg(theme.ACCENT_SOFT));
    row = w.writeKv(&surface, ctx, 4, row, "User ID", user.user_id, 14);
    const role_color = if (std.mem.eql(u8, user.role, "maintainer")) theme.ACCENT else theme.TEXT_SOFT;
    w.writeText(&surface, ctx, 4, row, "Role", theme.fg(theme.MUTED));
    w.writeText(&surface, ctx, 19, row, user.role, theme.fg(role_color));
    row += 2;

    row = w.writeSectionHeader(&surface, ctx, 2, row, "Connection");
    row = w.writeKv(&surface, ctx, 4, row, "Server", cfg.server_url, 14);
    row = w.writeKv(&surface, ctx, 4, row, "Sync", cfg.sync_strategy, 14);
    w.writeText(&surface, ctx, 4, row, "Token", theme.fg(theme.MUTED));
    const token_color = if (std.mem.eql(u8, cfg.token_status, "active")) theme.OK else theme.DANGER;
    const token_info = try std.fmt.allocPrint(ctx.arena, "{s}, expires {s}", .{ cfg.token_status, cfg.token_expires });
    w.writeText(&surface, ctx, 19, row, token_info, theme.fg(token_color));
    row += 1;

    w.writeText(&surface, ctx, 4, row, "MCP", theme.fg(theme.MUTED));
    w.writeText(&surface, ctx, 19, row, "bound by retrieve", theme.fg(theme.TEXT_SOFT));
    row += 1;
    row += 1;

    row = w.writeSectionHeader(&surface, ctx, 2, row, "Security");
    w.writeText(&surface, ctx, 4, row, "Password", theme.fg(theme.MUTED));
    w.writeText(&surface, ctx, 19, row, "********", theme.fg(theme.TEXT_SOFT));
    w.writeText(&surface, ctx, 30, row, "[ Change ]", theme.fg(theme.ACCENT_SOFT));
    row += 1;
    w.writeText(&surface, ctx, 4, row, "Sessions", theme.fg(theme.MUTED));
    w.writeText(&surface, ctx, 19, row, "1 active", theme.fg(theme.OK));
    row += 2;

    if (row + 2 < size.height) {
        row = w.writeSectionHeader(&surface, ctx, 2, row, "Danger Zone");
        w.writeText(&surface, ctx, 4, row, "[ Sign Out ]", theme.fg(theme.DANGER));
        w.writeText(&surface, ctx, 19, row, "Revoke current token and exit", theme.fg(theme.MUTED));
    }
    return surface;
}

fn drawSettingsPreferences(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const focused = self.settings.focus == .content;
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(focused), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Preferences", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 1;
    row = w.writeSectionHeader(&surface, ctx, 2, row, "Local Viewer");
    w.writeText(&surface, ctx, 4, row, "Markdown", theme.fg(theme.MUTED));
    const command = self.markdownViewerCommandForView();
    const configured = self.markdownViewerIsConfigured();
    const command_style = theme.fg(if (configured) theme.TEXT_SOFT else theme.MUTED);
    w.writeTextMax(&surface, ctx, 18, row, size.width -| 21, command, command_style);
    row += 2;

    w.writeText(&surface, ctx, 4, row, "[ Edit ]", theme.fg(theme.ACCENT_SOFT));
    w.writeText(&surface, ctx, 15, row, "[ Clear ]", theme.fg(if (configured) theme.TEXT_SOFT else theme.MUTED));
    w.writeText(&surface, ctx, 27, row, "[ Test ]", theme.fg(theme.TEXT_SOFT));
    row += 2;

    if (row < size.height -| 1) {
        _ = w.writeWrappedTextMax(
            &surface,
            ctx,
            4,
            row,
            size.width -| 7,
            3,
            "Used by the v shortcut. Configure a command prefix such as `open -a Typora`; Clumsies appends the preview file path.",
            theme.fg(theme.MUTED),
        );
    }
    return surface;
}

fn drawSettingsWorkspaces(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const focused = self.settings.focus == .content;
    const list_focused = focused and self.settings.workspace_focus == .list;
    const members_focused = focused and self.settings.workspace_focus == .members;
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.PANEL);

    const WorkspaceView = struct {
        ws_id: []const u8,
        name: []const u8,
        description: []const u8,
        owner: []const u8,
        active: bool,
    };
    const workspaces: []const WorkspaceView = blk: {
        var list: std.ArrayList(WorkspaceView) = .empty;
        self.api_state.mutex.lockUncancelable(std.Options.debug_io);
        defer self.api_state.mutex.unlock(std.Options.debug_io);
        if (self.api_state.current_user) |u| {
            const active_idx = if (u.workspaces.len > 0) @min(self.workspace.sel, u.workspaces.len - 1) else 0;
            for (u.workspaces, 0..) |ws, i| {
                try list.append(ctx.arena, .{
                    .ws_id = try ctx.arena.dupe(u8, ws.ws_id),
                    .name = try ctx.arena.dupe(u8, ws.name),
                    .description = try ctx.arena.dupe(u8, ws.description),
                    .owner = try ctx.arena.dupe(u8, ws.owner),
                    .active = i == active_idx,
                });
            }
        }
        break :blk try list.toOwnedSlice(ctx.arena);
    };

    const gap: u16 = if (size.width > 70) 1 else 0;
    const desired_list_w: u16 = if (size.width >= 90)
        @min(@as(u16, 42), @max(@as(u16, 30), size.width / 3))
    else
        @max(@as(u16, 24), size.width / 2);
    const panes_w = size.width -| gap;
    const min_detail_w: u16 = if (panes_w > 1) 1 else 0;
    const max_list_w: u16 = panes_w -| min_detail_w;
    const list_w: u16 = if (max_list_w == 0) 0 else @max(@as(u16, 1), @min(desired_list_w, max_list_w));
    const detail_w: u16 = size.width -| list_w -| gap;

    var list = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = list_w, .height = size.height });
    w.fillSurface(&list, theme.PANEL);
    w.drawBorder(&list, theme.focusBorder(list_focused), theme.PANEL);
    w.writeText(&list, ctx, 2, 0, "Workspaces", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 1;
    if (workspaces.len == 0) {
        w.writeText(&list, ctx, 2, row, "No workspaces", theme.fg(theme.MUTED));
    } else {
        const sel = @min(self.settings.content_sel, workspaces.len - 1);
        for (workspaces, 0..) |workspace, i| {
            if (row >= size.height -| 2) break;
            const is_sel = i == sel and list_focused;
            if (is_sel) {
                w.writeCursorMarker(&list, 1, row);
            }
            const name_style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
            w.writeTextMax(&list, ctx, 2, row, list_w -| 5, workspace.name, name_style);
            if (workspace.active) {
                const dot_col: u16 = @min(list_w -| 3, @as(u16, @intCast(2 + ctx.stringWidth(workspace.name) + 1)));
                w.writeText(&list, ctx, dot_col, row, "\xe2\x80\xa2", theme.fg(theme.ACCENT));
            }
            row += 1;
        }
    }

    if (detail_w == 0) {
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = list };
        root.children = children;
        return root;
    }

    var detail = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = detail_w, .height = size.height });
    w.fillSurface(&detail, theme.PANEL);
    w.drawBorder(&detail, theme.focusBorder(members_focused), theme.PANEL);
    w.writeText(&detail, ctx, 2, 0, "Details", theme.boldOn(theme.PANEL, theme.TEXT));

    var detail_row: u16 = 1;
    if (workspaces.len == 0) {
        w.writeTextMax(&detail, ctx, 2, detail_row, detail_w -| 5, "Create a workspace to start managing shared rules.", theme.fg(theme.MUTED));
    } else {
        const sel = @min(self.settings.content_sel, workspaces.len - 1);
        const workspace = workspaces[sel];
        requestWorkspaceMembers(self, workspace.ws_id);
        const members = self.api_state.workspace_members_cache.lookup(.{ .value = workspace.ws_id });
        w.writeText(&detail, ctx, 2, detail_row, "Description", theme.fg(theme.MUTED));
        detail_row += 1;
        if (workspace.description.len > 0) {
            _ = w.writeWrappedTextMax(&detail, ctx, 2, detail_row, detail_w -| 5, 2, workspace.description, theme.fg(theme.TEXT_SOFT));
        } else {
            w.writeText(&detail, ctx, 2, detail_row, "No description", theme.fg(theme.MUTED));
        }
        detail_row += 3;

        const local_paths = cachedWorkspacePaths(self, workspace.ws_id);
        w.writeText(&detail, ctx, 2, detail_row, "Bound paths", theme.fg(theme.MUTED));
        detail_row += 1;
        if (local_paths.len == 0) {
            w.writeText(&detail, ctx, 2, detail_row, "No bound paths", theme.fg(theme.MUTED));
            detail_row += 1;
        } else {
            const max_paths = @min(local_paths.len, @as(usize, 3));
            for (local_paths[0..max_paths]) |path| {
                w.writeText(&detail, ctx, 2, detail_row, "-", theme.fg(theme.MUTED));
                detail_row = w.writeWrappedTextMax(&detail, ctx, 4, detail_row, detail_w -| 7, 2, path, theme.fg(theme.TEXT_SOFT));
            }
            if (local_paths.len > max_paths) {
                const more = try std.fmt.allocPrint(ctx.arena, "{d} more", .{local_paths.len - max_paths});
                w.writeText(&detail, ctx, 2, detail_row, "-", theme.fg(theme.MUTED));
                w.writeText(&detail, ctx, 4, detail_row, more, theme.fg(theme.MUTED));
                detail_row += 1;
            }
        }
        detail_row += 1;

        w.writeText(&detail, ctx, 2, detail_row, "Status", theme.fg(theme.MUTED));
        w.writeText(&detail, ctx, 14, detail_row, if (workspace.active) "active" else "available", theme.fg(if (workspace.active) theme.ACCENT_SOFT else theme.TEXT_SOFT));
        detail_row += 1;
        if (workspace.owner.len > 0) {
            w.writeText(&detail, ctx, 2, detail_row, "Owner", theme.fg(theme.MUTED));
            w.writeTextMax(&detail, ctx, 14, detail_row, detail_w -| 17, workspace.owner, theme.fg(theme.TEXT_SOFT));
            detail_row += 1;
        }
        detail_row += 1;

        w.writeText(&detail, ctx, 2, detail_row, "Members", theme.fgBold(theme.ACCENT));
        detail_row += 1;
        if (members) |list_members| {
            if (list_members.len == 0) {
                w.writeText(&detail, ctx, 2, detail_row, "No members", theme.fg(theme.MUTED));
            } else {
                const member_sel = @min(self.settings.workspace_member_sel, list_members.len - 1);
                const max_members = @min(list_members.len, @as(usize, @intCast(size.height -| detail_row -| 2)));
                for (list_members[0..max_members], 0..) |member, member_idx| {
                    const is_member_sel = members_focused and member_idx == member_sel;
                    if (is_member_sel) {
                        w.writeCursorMarker(&detail, 1, detail_row);
                    }
                    const name_col: u16 = 2;
                    const name_w: u16 = if (detail_w > 36) 18 else @max(@as(u16, 10), detail_w / 2);
                    const role_col: u16 = @min(detail_w -| 8, name_col + name_w + 2);
                    const name_style = if (is_member_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
                    const role_style = if (std.mem.eql(u8, member.role, "admin")) theme.fg(theme.ACCENT_SOFT) else theme.fg(theme.MUTED);
                    w.writeTextMax(&detail, ctx, name_col, detail_row, name_w, member.username, name_style);
                    w.writeTextMax(&detail, ctx, role_col, detail_row, detail_w -| role_col -| 2, member.role, role_style);
                    detail_row += 1;
                }
            }
        } else if (self.api_state.workspace_members_cache.isFailed(.{ .value = workspace.ws_id })) {
            w.writeText(&detail, ctx, 2, detail_row, "Members failed to load", theme.fg(theme.DANGER));
        } else {
            w.writeText(&detail, ctx, 2, detail_row, "Loading members...", theme.fg(theme.MUTED));
        }
    }

    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = list };
    children[1] = .{ .origin = .{ .row = 0, .col = list_w + gap }, .surface = detail };
    root.children = children;
    return root;
}

fn requestWorkspaceMembers(self: anytype, ws_id: []const u8) void {
    const key: api.cache.StringKey = .{ .value = ws_id };
    if (self.api_state.workspace_members_pending.isInflight()) return;
    if (!self.api_state.workspace_members_cache.beginRefresh(key, self.tick_count, api.cache.DEFAULT_SNAPSHOT_REFRESH_TICKS)) return;
    api.specs.dispatchFromState(
        api.specs.WorkspaceIdParams,
        api.specs.WorkspaceMembersPayload,
        api.specs.workspace_members,
        &self.api_state.workspace_members_pending,
        self.api_state,
        .{ .ws_id = ws_id },
    );
}

fn cachedWorkspacePaths(self: anytype, ws_id: []const u8) []const []const u8 {
    const key: api.cache.StringKey = .{ .value = ws_id };
    if (self.api_state.workspace_paths_cache.lookup(key)) |paths| return paths;
    if (!self.api_state.workspace_paths_cache.shouldDispatch(key)) return &.{};

    const alloc = self.api_state.allocator();
    const key_copy = alloc.dupe(u8, ws_id) catch {
        self.api_state.workspace_paths_cache.markFailed(key);
        return &.{};
    };
    const paths = workspace_config.listWorkspacePaths(alloc, ws_id) catch {
        self.api_state.workspace_paths_cache.markFailed(.{ .value = key_copy });
        return &.{};
    };
    self.api_state.workspace_paths_cache.store(.{ .value = key_copy }, paths.paths);
    return paths.paths;
}

fn drawSettingsOrg(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const focused = self.settings.focus == .content;
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(focused), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Organization", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 1;
    const sel = self.settings.content_sel;

    self.api_state.mutex.lockUncancelable(std.Options.debug_io);
    const live_dir = self.api_state.members;
    self.api_state.mutex.unlock(std.Options.debug_io);

    const MemberView = struct { username: []const u8, role: []const u8, status: []const u8, joined: []const u8 };
    var member_views: std.ArrayList(MemberView) = .empty;
    if (live_dir) |dir| {
        for (dir.members) |m| {
            try member_views.append(ctx.arena, .{ .username = m.username, .role = m.role, .status = m.status, .joined = m.joined_at });
        }
    }

    var maintainer_count: u16 = 0;
    for (member_views.items) |m| {
        if (std.mem.eql(u8, m.role, "maintainer")) maintainer_count += 1;
    }
    const members_title = try std.fmt.allocPrint(
        ctx.arena,
        "Members ({d}  {d} maintainer, {d} member)",
        .{ member_views.items.len, maintainer_count, member_views.items.len - maintainer_count },
    );
    row = w.writeSectionHeader(&surface, ctx, 2, row, members_title);

    w.writeText(&surface, ctx, 4, row, "USERNAME", theme.fg(theme.MUTED));
    w.writeText(&surface, ctx, 18, row, "ROLE", theme.fg(theme.MUTED));
    w.writeText(&surface, ctx, 30, row, "STATUS", theme.fg(theme.MUTED));
    w.writeText(&surface, ctx, 42, row, "JOINED", theme.fg(theme.MUTED));
    row += 1;

    for (member_views.items, 0..) |m, i| {
        const is_sel = i == sel and focused;
        if (is_sel) {
            w.writeCursorMarker(&surface, 1, row);
        }
        const name_style = if (is_sel) theme.boldOn(theme.PANEL, theme.TEXT) else theme.fg(theme.TEXT_SOFT);
        w.writeText(&surface, ctx, 4, row, m.username, name_style);
        const role_color = if (std.mem.eql(u8, m.role, "maintainer")) theme.ACCENT else theme.TEXT_SOFT;
        w.writeText(&surface, ctx, 18, row, m.role, theme.fg(role_color));
        const status_color = if (std.mem.eql(u8, m.status, "active")) theme.OK else theme.WARN;
        w.writeText(&surface, ctx, 30, row, m.status, theme.fg(status_color));
        w.writeText(&surface, ctx, 42, row, m.joined, theme.fg(theme.MUTED));
        row += 1;
        if (row >= size.height -| 4) break;
    }

    return surface;
}

fn drawSettingsToken(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const focused = self.settings.focus == .content;
    const live_scopes: ?[]const u8 = blk: {
        self.api_state.mutex.lockUncancelable(std.Options.debug_io);
        defer self.api_state.mutex.unlock(std.Options.debug_io);
        if (self.api_state.current_user) |u| break :blk u.scopes;
        break :blk null;
    };

    const t: data.TokenInfo = .{ .scopes = &.{}, .expires = "\xe2\x80\x94" };
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(focused), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Token", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 1;
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

    row = w.writeSectionHeader(&surface, ctx, 2, row, "Scope Permissions");
    const sel = @min(self.settings.content_sel, data.ALL_SCOPES.len - 1);
    for (data.ALL_SCOPES, 0..) |scope_def, i| {
        if (row >= size.height -| 5) break;
        const is_sel = i == sel and focused;
        if (is_sel) {
            w.writeCursorMarker(&surface, 1, row);
        }
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
        const name_style = if (is_sel)
            theme.boldOn(theme.PANEL, theme.TEXT)
        else if (is_active)
            theme.fg(theme.TEXT)
        else
            theme.fg(theme.TEXT_SOFT);
        w.writeText(&surface, ctx, 6, row, scope_def.name, name_style);
        w.writeText(
            &surface,
            ctx,
            24,
            row,
            scope_def.description,
            theme.fg(if (is_active) theme.TEXT_SOFT else theme.MUTED),
        );
        row += 1;
    }
    row += 1;

    if (row + 1 < size.height) {
        w.writeText(&surface, ctx, 2, row, "Effective permissions = min(org role, token scopes)", theme.fg(theme.MUTED));
    }
    return surface;
}
