// Data types for TUI display, matching the Hub Server API model.
const std = @import("std");

pub const PromptEntry = struct {
    path: []const u8,
    kind: []const u8,
    refer_count: []const u8,
    constraint_count: u8,
    bundle_count: u8,
    bundle_names: []const u8,
    updated: []const u8,
    age: []const u8,
    summary: []const u8,
    trend: [8]u8,
    content_hash: []const u8,
    open_pr_count: u8 = 0,
    workspace_count: u8 = 0,
    workspace_names: []const u8 = "",
    revision: u16 = 1,
};

pub const BundleEntry = struct {
    name: []const u8,
    count: u16,
};

pub const CommentEntry = struct {
    id: []const u8,
    author: []const u8,
    body: []const u8,
    created: []const u8,
};

pub const ActiveSessionView = struct {
    ws_id: []const u8,
    session_id: []const u8,
    age: []const u8,
};

pub const PullRequestEntry = struct {
    id: []const u8,
    prompt_name: []const u8,
    status: []const u8,
    author: []const u8,
    created: []const u8,
    description: []const u8,
    base_hash: []const u8,
    diff: []const []const u8,
    comments: []const CommentEntry = &.{},
    trace_refers: u16,
    trace_sessions: u8,
    operation_count: u16 = 0,
    op_type: []const u8 = "",
    op_current_path: []const u8 = "",
    op_new_path: []const u8 = "",
    op_index: u16 = 0,
};

pub const AccessLevel = enum {
    member,
    admin,

    pub fn badge(self: AccessLevel) []const u8 {
        return switch (self) {
            .member => "m",
            .admin => "a",
        };
    }
};

pub const WorkspaceEntry = struct {
    name: []const u8,
    prompts: u8,
    contexts: u8,
    overrides: u8,
    local_rev: u16,
    remote_rev: u16,
    paths: u8,
    open_prs: u8,
    last_sync: []const u8,
    access_level: AccessLevel,
};

pub const ConstraintStat = struct {
    id: []const u8,
    label: []const u8,
    refer_count: u32,
    idle_days: ?u16,
};

pub const MemberPromptStat = struct {
    name: []const u8,
    refer_count: u32,
};

pub const InsightsPrompt = struct {
    name: []const u8,
    constraint_count: u8,
    active_constraint_count: u8,
    idle_constraint_count: u8,
    signal_ratio: u8,
    refer_count: u32,
    rate_per_day: u16,
    delta_pct: i8,
    last_referred_days_ago: ?u16,
    trend: [30]u16,
    constraints: []const ConstraintStat,
};

pub const InsightsMember = struct {
    username: []const u8,
    refer_count: u32,
    active_days: u8,
    trend: [30]u16,
    top_prompts: []const MemberPromptStat,
    models: []const InsightsModel,
};

pub const InsightsModel = struct {
    model_id: []const u8,
    refer_count: u32,
    pct: u8,
};

pub const AlertLevel = enum {
    prune,
    declining,
    healthy,

    pub fn icon(self: AlertLevel) []const u8 {
        return switch (self) {
            .prune => "\xe2\x9a\xa0",
            .declining => "\xe2\x86\x93",
            .healthy => "\xe2\x9c\x93",
        };
    }
};

pub const InsightsAlert = struct {
    prompt_name: []const u8,
    level: AlertLevel,
    message: []const u8,
};

pub const InsightsData = struct {
    constraint_count: u32 = 0,
    active_constraint_count: u32 = 0,
    idle_constraint_count: u32 = 0,
    signal_ratio: u8 = 0,
    refers_per_hour: u16 = 0,
    today_delta_pct: i8 = 0,
    last_event_minutes_ago: u16 = 0,
    refer_trend: [30]u16 = .{0} ** 30,
    prompts: []const InsightsPrompt = &.{},
    members: []const InsightsMember = &.{},
    models: []const InsightsModel = &.{},
    alerts: []const InsightsAlert = &.{},
    inputs: []const InputItem = &.{},
};

pub const InputItem = struct {
    timestamp: i64,
    content: []const u8,
};

pub const ContextFile = struct {
    path: []const u8,
    size: []const u8,
    hash: []const u8,
    state: []const u8,
    modified: bool,
    branch_diff: []const []const u8,
};

pub const WsPromptEntry = struct {
    name: []const u8,
    kind: []const u8,
    has_override: bool,
    hash: []const u8,
    state: []const u8,
    override_diff: []const []const u8,
};

pub const MemberEntry = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    joined: []const u8,
};

pub const WsAccess = struct {
    name: []const u8,
    role: AccessLevel,
    paths: []const []const u8,
};

pub const ClientConfig = struct {
    server_url: []const u8,
    sync_strategy: []const u8,
    token_status: []const u8,
    token_expires: []const u8,
};

pub const CurrentUser = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    scopes: []const []const u8,
    workspaces: []const WsAccess,
};

pub const TokenInfo = struct {
    scopes: []const []const u8,
    expires: []const u8,
};

// Token scope definitions
pub const ALL_SCOPES = [_]struct { name: []const u8, description: []const u8 }{
    .{ .name = "library:read", .description = "Read prompts and bundles" },
    .{ .name = "library:write", .description = "Create pull requests" },
    .{ .name = "bundle:write", .description = "Bundle CRUD" },
    .{ .name = "workspace:read", .description = "Read workspace manifest/files" },
    .{ .name = "workspace:write", .description = "Write context, create local edits" },
    .{ .name = "trace:write", .description = "Upload trace events" },
    .{ .name = "stats:read", .description = "Read statistics" },
    .{ .name = "members:read", .description = "List org/workspace members" },
    .{ .name = "members:write", .description = "Manage org/workspace members" },
    .{ .name = "pr:read", .description = "Read pull requests and comments" },
    .{ .name = "pr:write", .description = "Create/comment on pull requests" },
    .{ .name = "pr:merge", .description = "Accept/reject pull requests" },
};

// Helper functions
// Returns the group segment after the kind prefix.
// e.g. "rule/coding/STYLE.md" -> "coding"
pub fn pathPrefix(path: []const u8) []const u8 {
    var p = path;
    if (std.mem.indexOfScalar(u8, p, '/')) |first_slash| {
        p = p[first_slash + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, p, '/')) |idx| {
        return p[0..idx];
    }
    return p;
}

// Returns the last segment without .md extension.
// e.g. "rule/coding/STYLE.md" -> "STYLE"
pub fn promptName(path: []const u8) []const u8 {
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return stripMd(path);
    return stripMd(path[last_slash + 1 ..]);
}

fn stripMd(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".md")) return name[0 .. name.len - 3];
    return name;
}

// Derives kind short label from path prefix.
// e.g. "rule/..." -> "rule", "workflow/..." -> "wf"
pub fn kindFromPath(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/')) |idx| {
        const category = path[0..idx];
        if (std.mem.eql(u8, category, "rule")) return "rule";
        if (std.mem.eql(u8, category, "workflow")) return "wf";
    }
    return "";
}

pub fn syncStateLabel(ws: *const WorkspaceEntry) []const u8 {
    if (ws.local_rev == ws.remote_rev) return "up to date";
    return "behind";
}

pub fn syncStateColor(ws: *const WorkspaceEntry) @import("theme.zig").Color {
    const t = @import("theme.zig");
    if (ws.local_rev == ws.remote_rev) return t.OK;
    return t.WARN;
}
