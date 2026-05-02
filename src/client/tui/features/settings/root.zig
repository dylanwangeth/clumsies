//! Settings feature container. Renders account, organization, and token
//! panes and handles settings-mode navigation.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../../theme.zig");
const w = @import("../../widgets.zig");
const data = @import("../../models/view_types.zig");

pub const Tab = enum(u8) {
    account,
    organization,
    token,

    pub fn label(self: Tab) []const u8 {
        return switch (self) {
            .account => "Account",
            .organization => "Organization",
            .token => "Token",
        };
    }
};

pub const Focus = enum { sidebar, content };

pub const State = struct {
    tab: Tab = .account,
    focus: Focus = .sidebar,
    content_sel: usize = 0,
};

pub fn drawSettings(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const SettingsTab = @TypeOf(self.settings.tab);
    const settings_tabs = [_]SettingsTab{ .account, .organization, .token };

    const size = ctx.max.size();
    var root = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&root, theme.PANEL);

    const sidebar_w: u16 = 18;
    const sidebar_border = theme.focusBorder(self.settings.focus == .sidebar);
    var sidebar = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = sidebar_w, .height = size.height });
    w.fillSurface(&sidebar, theme.PANEL);
    w.drawBorder(&sidebar, sidebar_border, theme.PANEL);
    w.writeText(&sidebar, ctx, 2, 0, "Settings", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 2;
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
        self.show_settings = false;
        self.settings.focus = .sidebar;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.tab, .{})) {
        self.settings.focus = if (self.settings.focus == .sidebar) .content else .sidebar;
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

pub fn shortcuts(self: anytype) []const w.Shortcut {
    return switch (self.settings.tab) {
        .account => &.{
            .{ .key = "j/k", .label = "move" },
            .{ .key = "Enter", .label = "open/switch" },
            .{ .key = "Tab", .label = "switch focus" },
            .{ .key = "c", .label = "change password" },
            .{ .key = "x", .label = "sign out" },
            .{ .key = "Esc", .label = "back" },
        },
        .organization => &.{
            .{ .key = "j/k", .label = "move" },
            .{ .key = "Enter", .label = "open" },
            .{ .key = "Tab", .label = "switch focus" },
            .{ .key = "a", .label = "invite" },
            .{ .key = "r", .label = "change role" },
            .{ .key = "x", .label = "remove" },
            .{ .key = "Esc", .label = "back" },
        },
        .token => &.{
            .{ .key = "j/k", .label = "move" },
            .{ .key = "Enter", .label = "open" },
            .{ .key = "Tab", .label = "switch focus" },
            .{ .key = "r", .label = "refresh" },
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
                self.confirm_action = .remove_member;
                self.show_confirm = true;
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('c', .{})) {
                self.status_line = "Password change (requires input dialog)";
                ctx.consumeAndRedraw();
                return true;
            }
        },
        .organization => {
            if (key.matches('r', .{})) {
                self.status_line = "Role change (requires input dialog)";
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('x', .{})) {
                self.confirm_message = "selected member";
                self.confirm_action = .remove_member;
                self.show_confirm = true;
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches('a', .{})) {
                self.status_line = "Invite member (requires input dialog)";
                ctx.consumeAndRedraw();
                return true;
            }
        },
        .token => {
            if (key.matches('r', .{})) {
                self.status_line = "Token refresh (not yet implemented)";
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
    const settings_tabs = [_]SettingsTab{ .account, .organization, .token };

    const current: i8 = @intCast(@intFromEnum(self.settings.tab));
    const count: i8 = @intCast(settings_tabs.len);
    const next = @mod(current + delta + count, count);
    self.settings.tab = @enumFromInt(@as(u8, @intCast(next)));
}

fn orgMemberCount(self: anytype) usize {
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    if (self.api_state.directory) |dir| return dir.members.len;
    return 0;
}

fn accountWorkspaceCount(self: anytype) usize {
    self.api_state.mutex.lock();
    defer self.api_state.mutex.unlock();
    if (self.api_state.current_user) |u| return u.workspaces.len;
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
        self.settings.focus = .sidebar;
        ctx.consumeAndRedraw();
        return;
    }
    const max_items: usize = switch (self.settings.tab) {
        .account => accountWorkspaceCount(self),
        .organization => orgMemberCount(self),
        .token => data.ALL_SCOPES.len,
    };
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (self.settings.content_sel + 1 < max_items)
            self.settings.content_sel += 1;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.settings.content_sel > 0)
            self.settings.content_sel -= 1;
        ctx.consumeAndRedraw();
        return;
    }

    switch (self.settings.tab) {
        .account => handleAccountAction(self, ctx, key),
        .organization => handleOrganizationAction(self, ctx, key),
        .token => handleTokenAction(self, ctx, key),
    }
}

fn handleAccountAction(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
    if (key.matches(vaxis.Key.enter, .{})) {
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
    if (key.matches('x', .{})) {
        self.confirm_message = "sign out";
        self.confirm_action = .remove_member;
        self.show_confirm = true;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('c', .{})) {
        self.status_line = "Password change (requires input dialog)";
        ctx.consumeAndRedraw();
    }
}

fn handleOrganizationAction(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
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
    }
}

fn handleTokenAction(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) void {
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
    }
}

fn settingsTabLabel(tab: anytype) []const u8 {
    return switch (tab) {
        .account => "Account",
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
        workspaces: []const data.WsAccess,
    };

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
    w.drawBorder(&surface, theme.focusBorder(focused), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Account", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 2;

    row = w.writeSectionHeader(&surface, ctx, 2, row, "Profile");
    row = w.writeKv(&surface, ctx, 4, row, "Username", user.username, 14);
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
    w.writeText(&surface, ctx, 19, row, "bound by memory.setup", theme.fg(theme.TEXT_SOFT));
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

    row = w.writeSectionHeader(&surface, ctx, 2, row, try std.fmt.allocPrint(ctx.arena, "My Workspaces ({d})", .{user.workspaces.len}));
    if (user.workspaces.len == 0) {
        w.writeText(&surface, ctx, 4, row, "No workspaces", theme.fg(theme.MUTED));
        return surface;
    }

    const sel = @min(self.settings.content_sel, user.workspaces.len - 1);
    for (user.workspaces, 0..) |ws_access, i| {
        if (row >= size.height -| 4) break;
        const is_sel = i == sel and focused;
        if (is_sel) {
            w.writeCursorMarker(&surface, 1, row);
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

        if (is_sel and ws_access.paths.len > 0) {
            for (ws_access.paths, 0..) |path, pi| {
                if (row >= size.height -| 4) break;
                const is_last = pi + 1 == ws_access.paths.len;
                const connector = if (is_last) "\xe2\x94\x94" else "\xe2\x94\x9c";
                w.writeText(&surface, ctx, 6, row, connector, theme.fg(theme.BORDER));
                w.writeText(&surface, ctx, 8, row, path, theme.fg(theme.MUTED));
                row += 1;
            }
        } else if (is_sel and ws_access.paths.len == 0) {
            w.writeText(&surface, ctx, 6, row, "\xe2\x94\x94", theme.fg(theme.BORDER));
            w.writeText(&surface, ctx, 8, row, "(no local paths)", theme.fg(theme.MUTED));
            row += 1;
        }
    }
    row += 1;

    if (row + 2 < size.height) {
        row = w.writeSectionHeader(&surface, ctx, 2, row, "Danger Zone");
        w.writeText(&surface, ctx, 4, row, "[ Sign Out ]", theme.fg(theme.DANGER));
        w.writeText(&surface, ctx, 19, row, "Revoke current token and exit", theme.fg(theme.MUTED));
    }
    return surface;
}

fn drawSettingsOrg(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const focused = self.settings.focus == .content;
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(focused), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Organization", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 2;
    const sel = self.settings.content_sel;

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
    w.writeText(&surface, ctx, 30, row, "JOINED", theme.fg(theme.MUTED));
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
        w.writeText(&surface, ctx, 30, row, m.joined, theme.fg(theme.MUTED));
        row += 1;
        if (row >= size.height -| 4) break;
    }

    return surface;
}

fn drawSettingsToken(self: anytype, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const focused = self.settings.focus == .content;
    const live_scopes: ?[]const u8 = blk: {
        self.api_state.mutex.lock();
        defer self.api_state.mutex.unlock();
        if (self.api_state.current_user) |u| break :blk u.scopes;
        break :blk null;
    };

    const t: data.TokenInfo = .{ .scopes = &.{}, .expires = "\xe2\x80\x94" };
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    w.fillSurface(&surface, theme.PANEL);
    w.drawBorder(&surface, theme.focusBorder(focused), theme.PANEL);
    w.writeText(&surface, ctx, 2, 0, "Token", theme.boldOn(theme.PANEL, theme.TEXT));

    var row: u16 = 2;
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
