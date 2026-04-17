//! Statistics API response shapes. Stats aggregate trace events into constraint-level usage
//! metrics: refer counts, signal ratios, per-prompt trends, and per-user activity. These feed
//! the TUI Analysis and Dashboard panels.
pub const TrendPoint = struct {
    date: []const u8,
    refer_count: i64 = 0,
};

pub const TrendSeries = struct {
    period: []const u8 = "",
    data: []const TrendPoint = &.{},
};

pub const OrgPromptStat = struct {
    prompt_id: []const u8,
    refer_count: i64 = 0,
    active_constraint_count: i64 = 0,
    workspace_count: i64 = 0,
    bundle_count: i64 = 0,
    open_pr_count: i64 = 0,
    last_referred_at: ?i64 = null,
    trend: []const i64 = &.{},
};

pub const OrgUserTopPromptStat = struct {
    prompt_id: []const u8 = "",
    refer_count: i64 = 0,
};

pub const OrgUserStat = struct {
    user_id: []const u8 = "",
    username: []const u8 = "",
    refer_count: i64 = 0,
    active_days: i64 = 0,
    last_referred_at: ?i64 = null,
    trend: []const i64 = &.{},
    top_prompts: []const OrgUserTopPromptStat = &.{},
};

pub const OrgStatsResponse = struct {
    total_refer_count: i64 = 0,
    workspace_count: i64 = 0,
    prompt_count: i64 = 0,
    prompts: []const OrgPromptStat = &.{},
    users: []const OrgUserStat = &.{},
    trend: TrendSeries = .{},
};

pub const WorkspacePromptStat = struct {
    prompt_id: []const u8,
    refer_count: i64 = 0,
};

pub const WorkspaceStatsResponse = struct {
    ws_id: []const u8,
    total_refer_count: i64 = 0,
    constraint_coverage: f64 = 0,
    prompts: []const WorkspacePromptStat = &.{},
    trend: TrendSeries = .{},
};
