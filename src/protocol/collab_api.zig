//! Collaboration API response shapes. Pull requests carry workspace local edits back to the
//! Library for review. Each PR contains PromptPrChanges (add/modify/delete) and a
//! PromptPrUsageSummary showing how much the changed prompt has been referred.
pub const PromptPrListItem = struct {
    pr_id: []const u8,
    status: []const u8,
    description: []const u8,
    created_at: []const u8,
    author: []const u8 = "",
    operation_count: i64 = 0,
};

pub const PromptPrListResponse = struct {
    prs: []const PromptPrListItem = &.{},
};

pub const PromptPrChange = struct {
    op_index: i32 = 0,
    type: []const u8 = "",
    prompt_id: ?[]const u8 = null,
    base_hash: ?[]const u8 = null,
    content: ?[]const u8 = null,
    path: ?[]const u8 = null,
    base_content: ?[]const u8 = null,
    current_path: ?[]const u8 = null,
};

pub const PromptPrUsageSummary = struct {
    refer_count: i64 = 0,
    sessions_used: i64 = 0,
    last_referred: ?[]const u8 = null,
};

pub const PromptPrDetailResponse = struct {
    pr_id: []const u8,
    status: []const u8,
    description: []const u8,
    created_at: []const u8,
    operations: []const PromptPrChange = &.{},
    trace_summary: PromptPrUsageSummary = .{},
};

pub const PromptPrComment = struct {
    comment_id: []const u8 = "",
    author_id: []const u8 = "",
    author: []const u8 = "",
    body: []const u8 = "",
    created_at: []const u8 = "",
};

pub const PromptPrCommentsResponse = struct {
    comments: []const PromptPrComment = &.{},
};
