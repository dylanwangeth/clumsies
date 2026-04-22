//! Collaboration API response shapes. Pull requests carry workspace local edits back to the
//! Library for review. Each PR contains RulePrChanges (add/modify/delete) and a
//! RulePrUsageSummary showing how much the changed rule has been referred.
pub const RulePrListItem = struct {
    pr_id: []const u8,
    status: []const u8,
    description: []const u8,
    created_at: []const u8,
    author: []const u8 = "",
    operation_count: i64 = 0,
};

pub const RulePrListResponse = struct {
    prs: []const RulePrListItem = &.{},
};

pub const RulePrChange = struct {
    op_index: i32 = 0,
    type: []const u8 = "",
    rule_id: ?[]const u8 = null,
    base_hash: ?[]const u8 = null,
    content: ?[]const u8 = null,
    path: ?[]const u8 = null,
    base_content: ?[]const u8 = null,
    current_path: ?[]const u8 = null,
};

pub const RulePrUsageSummary = struct {
    refer_count: i64 = 0,
    sessions_used: i64 = 0,
    last_referred: ?[]const u8 = null,
};

pub const RulePrDetailResponse = struct {
    pr_id: []const u8,
    status: []const u8,
    description: []const u8,
    created_at: []const u8,
    operations: []const RulePrChange = &.{},
    attestation_summary: RulePrUsageSummary = .{},
};

pub const RulePrComment = struct {
    comment_id: []const u8 = "",
    author_id: []const u8 = "",
    author: []const u8 = "",
    body: []const u8 = "",
    created_at: []const u8 = "",
};

pub const RulePrCommentsResponse = struct {
    comments: []const RulePrComment = &.{},
};
