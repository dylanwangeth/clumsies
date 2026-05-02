//! Long-lived API data shapes held in `ApiState`. These structs are the
//! TUI-owned representation of parsed Hub responses before they are
//! transformed into display-oriented view models.

pub const UserData = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    scopes: []const u8,
    workspaces: []const WsData,
};

pub const WsData = struct {
    ws_id: []const u8,
    name: []const u8,
    role: []const u8 = "",
};

pub const DirectoryMember = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    joined_at: []const u8,
};

pub const DirectoryData = struct {
    members: []const DirectoryMember,
};

pub const LibraryRule = struct {
    rule_id: []const u8,
    path: []const u8,
    content_hash: []const u8,
    updated_at: []const u8,
    refer_count: i64 = 0,
    active_constraint_count: i64 = 0,
    workspace_count: i64 = 0,
    bundle_count: i64 = 0,
    open_pr_count: i64 = 0,
};

pub const BundleData = struct {
    name: []const u8,
    description: []const u8,
    rule_count: usize,
};

pub const RulePr = struct {
    pr_id: []const u8,
    target_kind: []const u8 = "rule",
    target_path: []const u8 = "",
    ws_id: ?[]const u8 = null,
    status: []const u8,
    description: []const u8,
    created_at: []const u8,
    author: []const u8,
    operation_count: i32 = 0,
};

pub const RuleStats = struct {
    rule_id: []const u8,
    refer_count: i64,
    active_constraint_count: i64,
    workspace_count: i64,
    bundle_count: i64,
    open_pr_count: i64,
    last_referred_at: ?i64 = null,
    trend: []const i64 = &.{},
};

pub const UserRuleStats = struct {
    rule_id: []const u8,
    refer_count: i64,
};

pub const UserStats = struct {
    user_id: []const u8,
    username: []const u8,
    refer_count: i64,
    active_days: i64,
    last_referred_at: ?i64 = null,
    trend: []const i64 = &.{},
    top_rules: []const UserRuleStats = &.{},
};

pub const OrgStats = struct {
    total_refer_count: i64,
    workspace_count: i64,
    rule_count: i64,
    constraint_count: i64 = 0,
    active_constraint_count: i64 = 0,
    idle_constraint_count: i64 = 0,
    signal_ratio: f64 = 0,
    last_event_at: ?i64 = null,
    trend: []const TrendPoint,
    rules: []const RuleStats = &.{},
    users: []const UserStats = &.{},
};

pub const TrendPoint = struct {
    date: []const u8,
    refer_count: i64,
};

pub const WsDetail = struct {
    ws_id: []const u8,
    context_files: []const ContextFileData,
    ws_rules: []const WsRuleData,
};

pub const ContextFileData = struct {
    context_id: []const u8,
    path: []const u8,
    hash: []const u8,
    size: i64,
    author: []const u8 = "",
    updated_at: []const u8 = "",
};

pub const WsRuleData = struct {
    rule_id: []const u8,
    content_hash: []const u8,
    path: []const u8 = "",
};
