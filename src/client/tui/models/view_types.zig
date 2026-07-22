//! View model types for TUI display, transformed from Server API responses.
const std = @import("std");

pub const RuleEntry = struct {
    rule_id: []const u8 = "",
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

pub const PrChangeEntry = struct {
    target_kind: PrTargetKind = .rule,
    path: []const u8 = "",
    bundle_name: []const u8 = "",
    rule_path: []const u8 = "",
    op_type: []const u8 = "",
    base_hash: []const u8 = "",
    base_content: []const u8 = "",
    proposed_content: []const u8 = "",
    conflict: bool = false,
};

pub const PrTargetKind = enum {
    context,
    rule,
    bundle,

    pub fn label(self: PrTargetKind) []const u8 {
        return switch (self) {
            .context => "context",
            .rule => "rule",
            .bundle => "bundle",
        };
    }
};

pub const PullRequestEntry = struct {
    id: []const u8,
    target_kind: PrTargetKind = .rule,
    target_path: []const u8 = "",
    workspace_id: ?[]const u8 = null,
    rule_name: []const u8,
    status: []const u8,
    author: []const u8,
    created: []const u8,
    title: []const u8,
    body: []const u8,
    base_hash: []const u8,
    base_content: []const u8 = "",
    proposed_content: []const u8 = "",
    comments: []const CommentEntry = &.{},
    changes: []const PrChangeEntry = &.{},
    comment_count: u16 = 0,
    attestation_refers: u16,
    attestation_sessions: u8,
    operation_count: u16 = 0,
    op_type: []const u8 = "",
    op_current_path: []const u8 = "",
    op_new_path: []const u8 = "",
    op_index: u16 = 0,
    has_conflict: bool = false,
};

pub const AccessLevel = enum {
    member,
    admin,
};

pub const WorkspaceEntry = struct {
    name: []const u8,
    rules: u8,
    contexts: u8,
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

pub const MemberRuleStat = struct {
    name: []const u8,
    refer_count: u32,
};

pub const AnalysisRule = struct {
    name: []const u8,
    constraint_count: u8,
    active_constraint_count: u8,
    idle_constraint_count: u8,
    signal_ratio: u8,
    refer_count: u32,
    trend: [30]u16,
    constraints: []const ConstraintStat,
};

pub const MemberStats = struct {
    username: []const u8,
    refer_count: u32,
    active_days: u8,
    trend: [30]u16,
    top_rules: []const MemberRuleStat,
    models: []const ModelStats,
};

pub const ModelStats = struct {
    model_id: []const u8,
    refer_count: u32,
    pct: u8,
};

pub const AlertLevel = enum {
    prune,
    declining,
    healthy,
};

pub const AnalysisAlert = struct {
    rule_name: []const u8,
    level: AlertLevel,
    message: []const u8,
};

pub const AnalysisData = struct {
    constraint_count: u32 = 0,
    active_constraint_count: u32 = 0,
    idle_constraint_count: u32 = 0,
    signal_ratio: u8 = 0,
    refers_per_hour: u16 = 0,
    today_delta_pct: i8 = 0,
    last_event_minutes_ago: u16 = 0,
    refer_trend: [30]u16 = .{0} ** 30,
    rules: []const AnalysisRule = &.{},
    members: []const MemberStats = &.{},
    models: []const ModelStats = &.{},
    alerts: []const AnalysisAlert = &.{},
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

pub const WorkspaceRuleEntry = struct {
    name: []const u8,
    kind: []const u8,
    hash: []const u8,
    state: []const u8,
};

pub const MemberEntry = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    joined: []const u8,
};

pub const WorkspaceAccess = struct {
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
    workspaces: []const WorkspaceAccess,
};

pub const TokenInfo = struct {
    scopes: []const []const u8,
    expires: []const u8,
};

// Token scope definitions
pub const ALL_SCOPES = [_]struct { name: []const u8, description: []const u8 }{
    .{ .name = "artifact:read", .description = "Read rules and bundles" },
    .{ .name = "artifact:write", .description = "Create pull requests" },
    .{ .name = "bundle:write", .description = "Bundle CRUD" },
    .{ .name = "workspace:read", .description = "Read workspace manifest/files" },
    .{ .name = "workspace:write", .description = "Write context, create local edits" },
    .{ .name = "attestation:write", .description = "Upload attestation events" },
    .{ .name = "stats:read", .description = "Read statistics" },
    .{ .name = "members:read", .description = "List org/workspace members" },
    .{ .name = "members:write", .description = "Manage org/workspace members" },
    .{ .name = "pr:read", .description = "Read pull requests and comments" },
    .{ .name = "pr:write", .description = "Create/comment on pull requests" },
    .{ .name = "pr:merge", .description = "Accept/reject pull requests" },
};

// Derives kind short label from path prefix. Rule is the default kind;
// workflow/ is the only explicit prefix. PIN.md produces an empty label since
// it is not a searchable rule.
pub fn kindFromPath(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "PIN.md")) return "";
    if (std.mem.startsWith(u8, path, "workflow/")) return "wf";
    return "rule";
}
