//! Statistics API response shapes. Stats aggregate attestation events into constraint-level usage
//! metrics: refer counts, signal ratios, per-rule trends, and per-user activity. These feed
//! the TUI Analysis and Dashboard panels.
pub const TrendPoint = struct {
    date: []const u8,
    refer_count: i64 = 0,
};

pub const TrendSeries = struct {
    period: []const u8 = "",
    data: []const TrendPoint = &.{},
};

pub const OrgRuleStat = struct {
    rule_id: []const u8,
    refer_count: i64 = 0,
    active_constraint_count: i64 = 0,
    trend: []const i64 = &.{},
};

pub const OrgUserTopRuleStat = struct {
    rule_id: []const u8 = "",
    refer_count: i64 = 0,
};

pub const OrgUserStat = struct {
    user_id: []const u8 = "",
    username: []const u8 = "",
    refer_count: i64 = 0,
    active_days: i64 = 0,
    trend: []const i64 = &.{},
    top_rules: []const OrgUserTopRuleStat = &.{},
};

pub const OrgStatsResponse = struct {
    total_refer_count: i64 = 0,
    workspace_count: i64 = 0,
    rule_count: i64 = 0,
    rules: []const OrgRuleStat = &.{},
    users: []const OrgUserStat = &.{},
    trend: TrendSeries = .{},
};

pub const WorkspaceRuleStat = struct {
    rule_id: []const u8,
    refer_count: i64 = 0,
};

pub const WorkspaceStatsResponse = struct {
    ws_id: []const u8,
    total_refer_count: i64 = 0,
    constraint_coverage: f64 = 0,
    rules: []const WorkspaceRuleStat = &.{},
    trend: TrendSeries = .{},
};
