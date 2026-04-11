// Mock data for the TUI dashboard, matching the Hub Server data model.
// No invented fields: only what the Hub Server API actually provides.

pub const PromptEntry = struct {
    canonical_name: []const u8,
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

pub const BUNDLES = [_]BundleEntry{
    .{ .name = "All", .count = 47 },
    .{ .name = "frontend", .count = 12 },
    .{ .name = "backend", .count = 9 },
    .{ .name = "release", .count = 5 },
    .{ .name = "default", .count = 21 },
    .{ .name = "ops", .count = 4 },
};

// Sorted by path prefix for grouped display in Library
pub const PROMPTS = [_]PromptEntry{
    .{ .canonical_name = "arch/ADR_DOCUMENT", .kind = "rule", .refer_count = "291", .constraint_count = 6, .bundle_count = 1, .bundle_names = "default", .updated = "2026-03-25", .age = "12d", .summary = "Conventions for writing architecture decision records", .trend = .{ 1, 1, 1, 2, 2, 2, 1, 1 }, .content_hash = "sha256:g2h3i4j5" },
    .{ .canonical_name = "cmd/GEN_COMMIT_MSG", .kind = "wf", .refer_count = "1.1k", .constraint_count = 5, .bundle_count = 1, .bundle_names = "default", .updated = "2026-03-31", .age = "5d", .summary = "Review git changes and suggest a commit message", .trend = .{ 2, 3, 4, 4, 5, 5, 4, 3 }, .content_hash = "sha256:e4f5g6h7", .open_pr_count = 1, .workspace_count = 8, .workspace_names = "payments-api \xc2\xb7 merchant-portal \xc2\xb7 infra-tools \xc2\xb7 release-bot \xc2\xb7 docs-site \xc2\xb7 mobile-app \xc2\xb7 data-pipeline \xc2\xb7 admin-dashboard", .revision = 15 },
    .{ .canonical_name = "coding/STYLE", .kind = "rule", .refer_count = "3.2k", .constraint_count = 8, .bundle_count = 2, .bundle_names = "frontend, default", .updated = "2026-04-04", .age = "2d", .summary = "Naming, imports, formatting, and code organization rules", .trend = .{ 1, 2, 3, 5, 6, 8, 6, 5 }, .content_hash = "sha256:a1b2c3d4", .open_pr_count = 1, .workspace_count = 6, .workspace_names = "payments-api \xc2\xb7 merchant-portal \xc2\xb7 infra-tools \xc2\xb7 release-bot \xc2\xb7 docs-site \xc2\xb7 mobile-app", .revision = 42 },
    .{ .canonical_name = "coding/API_REVIEW", .kind = "rule", .refer_count = "842", .constraint_count = 12, .bundle_count = 1, .bundle_names = "backend", .updated = "2026-04-05", .age = "1d", .summary = "API design review checklist for consistency and safety", .trend = .{ 3, 4, 5, 6, 7, 8, 7, 6 }, .content_hash = "sha256:i8j9k0l1", .open_pr_count = 1, .workspace_count = 3, .workspace_names = "payments-api \xc2\xb7 merchant-portal \xc2\xb7 infra-tools", .revision = 18 },
    .{ .canonical_name = "coding/COMPATIBILITY", .kind = "rule", .refer_count = "520", .constraint_count = 8, .bundle_count = 1, .bundle_names = "default", .updated = "2026-04-03", .age = "3d", .summary = "Breaking changes happen freely, no compatibility layers", .trend = .{ 2, 2, 3, 3, 4, 4, 3, 3 }, .content_hash = "sha256:q6r7s8t9" },
    .{ .canonical_name = "coding/CODE_COMMENTS", .kind = "rule", .refer_count = "488", .constraint_count = 9, .bundle_count = 2, .bundle_names = "frontend, backend", .updated = "2026-04-02", .age = "4d", .summary = "Comments must be final-form text, no thinking process", .trend = .{ 1, 2, 2, 3, 3, 4, 3, 3 }, .content_hash = "sha256:u0v1w2x3" },
    .{ .canonical_name = "style/UIUX_DESIGN", .kind = "rule", .refer_count = "178", .constraint_count = 7, .bundle_count = 1, .bundle_names = "frontend", .updated = "2026-03-31", .age = "5d", .summary = "UI/UX design method with pressure-testing and smoke checks", .trend = .{ 0, 1, 1, 2, 2, 3, 2, 2 }, .content_hash = "sha256:k6l7m8n9" },
    .{ .canonical_name = "wf/RELEASE_CHECKLIST", .kind = "wf", .refer_count = "611", .constraint_count = 4, .bundle_count = 2, .bundle_names = "release, ops", .updated = "2026-03-28", .age = "8d", .summary = "Pre-release verification steps for branch and CI", .trend = .{ 1, 1, 2, 2, 3, 3, 2, 2 }, .content_hash = "sha256:m2n3o4p5", .open_pr_count = 1 },
    .{ .canonical_name = "wf/GEN_GITIGNORE", .kind = "wf", .refer_count = "145", .constraint_count = 3, .bundle_count = 1, .bundle_names = "ops", .updated = "2026-03-23", .age = "14d", .summary = "Generate .gitignore based on project type and toolchain", .trend = .{ 1, 1, 1, 1, 2, 1, 1, 1 }, .content_hash = "sha256:o0p1q2r3" },
    .{ .canonical_name = "wf/GEN_PR", .kind = "wf", .refer_count = "102", .constraint_count = 4, .bundle_count = 1, .bundle_names = "default", .updated = "2026-03-28", .age = "8d", .summary = "Create pull request with summary and test plan", .trend = .{ 0, 1, 1, 1, 2, 2, 1, 1 }, .content_hash = "sha256:s4t5u6v7" },
    .{ .canonical_name = "zig/ZIG_STYLE", .kind = "rule", .refer_count = "412", .constraint_count = 11, .bundle_count = 1, .bundle_names = "default", .updated = "2026-04-04", .age = "2d", .summary = "Zig naming conventions, error handling, and memory management", .trend = .{ 3, 3, 4, 5, 5, 6, 5, 4 }, .content_hash = "sha256:y4z5a6b7", .open_pr_count = 1 },
    .{ .canonical_name = "zig/DEPRECATED_API", .kind = "rule", .refer_count = "387", .constraint_count = 59, .bundle_count = 1, .bundle_names = "default", .updated = "2026-04-05", .age = "1d", .summary = "Zig 0.15 removed and renamed APIs with replacements", .trend = .{ 2, 3, 4, 5, 6, 7, 6, 5 }, .content_hash = "sha256:c8d9e0f1" },
};

pub fn pathPrefix(canonical_name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, canonical_name, "/")) |idx| {
        return canonical_name[0..idx];
    }
    return canonical_name;
}

pub fn promptName(canonical_name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, canonical_name, "/")) |idx| {
        return canonical_name[idx + 1 ..];
    }
    return canonical_name;
}

pub fn prsForPrompt(canonical_name: []const u8) []const PullRequestEntry {
    // Return a slice of PULL_REQUESTS matching the given prompt name.
    // Since mock data is static and small, we scan the full array each time.
    var start: usize = 0;
    var end: usize = 0;
    var found_start = false;
    for (PULL_REQUESTS, 0..) |pr, i| {
        if (std.mem.eql(u8, pr.prompt_name, canonical_name)) {
            if (!found_start) {
                start = i;
                found_start = true;
            }
            end = i + 1;
        }
    }
    if (!found_start) return &.{};
    return PULL_REQUESTS[start..end];
}

const std = @import("std");

pub const PULL_REQUESTS = [_]PullRequestEntry{
    // coding/STYLE: 3 PRs (open, rejected, accepted)
    .{ .id = "pr-0051", .prompt_name = "coding/STYLE", .status = "open", .author = "alice", .created = "2026-04-05 10:00", .description = "Prefer explicit names over abbreviations, add import grouping rule", .base_hash = "sha256:a1b2c3d4", .diff = &.{
        "@@ -1,3 +1,5 @@",
        " # STYLE",
        "-1. Prefer short names.",
        "+1. Prefer explicit names over abbreviations.",
        "+2. Group imports by scope.",
        " 3. Sort file sections in dependency order.",
    }, .comments = &.{
        .{ .id = "cmt-0012", .author = "bob", .body = "Naming convention looks good, but consider keeping short names for loop variables.", .created = "2026-04-05 11:30" },
        .{ .id = "cmt-0013", .author = "carol", .body = "Agreed with the import grouping rule. Should we also sort by scope?", .created = "2026-04-05 14:00" },
        .{ .id = "cmt-0014", .author = "alice", .body = "Good point Bob. I'll add a note about loop variable exemptions.", .created = "2026-04-05 15:20" },
    }, .trace_refers = 42, .trace_sessions = 12 },
    .{ .id = "pr-0048", .prompt_name = "coding/STYLE", .status = "rejected", .author = "dave", .created = "2026-04-03 14:00", .description = "Remove all formatting rules and rely on zig fmt only", .base_hash = "sha256:a1b2c3d4", .diff = &.{
        "@@ -1,5 +1,2 @@",
        " # STYLE",
        "-1. Prefer short names.",
        "-2. Sort file sections in dependency order.",
        "-3. Keep line length under 120.",
        "+1. Use zig fmt for all formatting.",
    }, .comments = &.{
        .{ .id = "cmt-0010", .author = "carol", .body = "zig fmt doesn't cover naming conventions. We still need manual rules for those.", .created = "2026-04-03 15:00" },
        .{ .id = "cmt-0011", .author = "bob", .body = "Agreed, rejecting. Formatting is only part of style.", .created = "2026-04-03 16:30" },
    }, .trace_refers = 42, .trace_sessions = 12 },
    .{ .id = "pr-0045", .prompt_name = "coding/STYLE", .status = "accepted", .author = "bob", .created = "2026-03-28 09:00", .description = "Add line length constraint and section ordering rule", .base_hash = "sha256:x9y8z7w6", .diff = &.{
        "@@ -2,1 +2,3 @@",
        " 1. Prefer short names.",
        "+2. Sort file sections in dependency order.",
        "+3. Keep line length under 120.",
    }, .trace_refers = 38, .trace_sessions = 10 },
    // cmd/GEN_COMMIT_MSG: 2 PRs (open, accepted)
    .{ .id = "pr-0050", .prompt_name = "cmd/GEN_COMMIT_MSG", .status = "open", .author = "bob", .created = "2026-04-05 09:12", .description = "Use conventional commit prefixes for consistency", .base_hash = "sha256:e4f5g6h7", .diff = &.{
        "@@ -1,2 +1,3 @@",
        " # GEN_COMMIT_MSG",
        "+Use conventional commit prefixes.",
        " Keep message under 72 chars.",
    }, .comments = &.{
        .{ .id = "cmt-0015", .author = "alice", .body = "Which prefixes? feat/fix/chore? Please list them explicitly.", .created = "2026-04-05 10:30" },
    }, .trace_refers = 18, .trace_sessions = 5 },
    .{ .id = "pr-0044", .prompt_name = "cmd/GEN_COMMIT_MSG", .status = "accepted", .author = "carol", .created = "2026-03-25 11:00", .description = "Enforce 72-char subject line limit", .base_hash = "sha256:e4f5g6h7", .diff = &.{
        "@@ -1,1 +1,2 @@",
        " # GEN_COMMIT_MSG",
        "+Keep message under 72 chars.",
    }, .trace_refers = 15, .trace_sessions = 4 },
    // wf/RELEASE_CHECKLIST: 2 PRs (open, accepted)
    .{ .id = "pr-0052", .prompt_name = "wf/RELEASE_CHECKLIST", .status = "open", .author = "dave", .created = "2026-04-06 08:30", .description = "Add rollback procedure and hotfix branch policy", .base_hash = "sha256:m2n3o4p5", .diff = &.{
        "@@ -5,0 +5,3 @@",
        " 5. Verify CI green before merge.",
        "+6. Prepare rollback plan for critical paths.",
        "+7. Hotfix branches must be named hotfix/<issue-id>.",
        "+8. Post-release smoke test within 30 minutes.",
    }, .comments = &.{
        .{ .id = "cmt-0016", .author = "alice", .body = "30 minutes seems tight for large deployments. Can we make it configurable?", .created = "2026-04-06 09:00" },
        .{ .id = "cmt-0017", .author = "dave", .body = "Fair point. Changed to 'within the agreed SLA window'.", .created = "2026-04-06 09:45" },
    }, .trace_refers = 31, .trace_sessions = 8 },
    .{ .id = "pr-0049", .prompt_name = "wf/RELEASE_CHECKLIST", .status = "accepted", .author = "carol", .created = "2026-04-04 16:30", .description = "Add CI green verification step before merge", .base_hash = "sha256:m2n3o4p5", .diff = &.{
        "@@ -4,1 +4,2 @@",
        " 4. Tag release branch.",
        "+5. Verify CI green before merge.",
    }, .trace_refers = 31, .trace_sessions = 8 },
    // coding/API_REVIEW: 1 PR (open)
    .{ .id = "pr-0053", .prompt_name = "coding/API_REVIEW", .status = "open", .author = "carol", .created = "2026-04-06 11:00", .description = "Add rate limiting and pagination requirements to API review checklist", .base_hash = "sha256:i8j9k0l1", .diff = &.{
        "@@ -10,0 +10,4 @@",
        " 10. Validate error response schema.",
        "+11. All list endpoints must support cursor-based pagination.",
        "+12. Rate limiting headers (X-RateLimit-*) required on all public endpoints.",
        "+13. Batch endpoints must document max items per request.",
        "+14. Breaking changes require deprecation notice in previous release.",
    }, .comments = &.{
        .{ .id = "cmt-0018", .author = "bob", .body = "Should we also require idempotency keys for POST endpoints?", .created = "2026-04-06 12:00" },
        .{ .id = "cmt-0019", .author = "carol", .body = "Good idea, adding that as item 15.", .created = "2026-04-06 12:30" },
        .{ .id = "cmt-0020", .author = "alice", .body = "The deprecation notice rule should reference our versioning policy doc.", .created = "2026-04-06 14:00" },
    }, .trace_refers = 55, .trace_sessions = 9 },
    // zig/ZIG_STYLE: 1 PR (open)
    .{ .id = "pr-0054", .prompt_name = "zig/ZIG_STYLE", .status = "open", .author = "alice", .created = "2026-04-07 09:00", .description = "Clarify comptime function naming and add allocator passing conventions", .base_hash = "sha256:y4z5a6b7", .diff = &.{
        "@@ -5,2 +5,5 @@",
        " - Comptime functions that return types use PascalCase",
        "+- Functions accepting allocator must take it as first parameter",
        "+- Prefer arena allocator for request-scoped work",
        "+- Use errdefer to free on error paths, not manual cleanup",
        " ",
        " ## Formatting",
    }, .trace_refers = 28, .trace_sessions = 7 },
};

pub const WORKSPACES = [_]WorkspaceEntry{
    .{ .name = "payments-api", .prompts = 18, .contexts = 9, .overrides = 3, .local_rev = 41, .remote_rev = 43, .paths = 2, .open_prs = 2, .last_sync = "1h ago", .access_level = .admin },
    .{ .name = "merchant-portal", .prompts = 14, .contexts = 5, .overrides = 1, .local_rev = 37, .remote_rev = 37, .paths = 1, .open_prs = 0, .last_sync = "2 min ago", .access_level = .member },
    .{ .name = "infra-tools", .prompts = 8, .contexts = 3, .overrides = 0, .local_rev = 22, .remote_rev = 22, .paths = 1, .open_prs = 1, .last_sync = "5 min ago", .access_level = .member },
    .{ .name = "release-bot", .prompts = 5, .contexts = 2, .overrides = 0, .local_rev = 15, .remote_rev = 15, .paths = 1, .open_prs = 0, .last_sync = "3 min ago", .access_level = .member },
    .{ .name = "docs-site", .prompts = 6, .contexts = 4, .overrides = 0, .local_rev = 10, .remote_rev = 10, .paths = 1, .open_prs = 0, .last_sync = "10 min ago", .access_level = .member },
    .{ .name = "mobile-app", .prompts = 12, .contexts = 7, .overrides = 2, .local_rev = 28, .remote_rev = 30, .paths = 2, .open_prs = 1, .last_sync = "30 min ago", .access_level = .admin },
    .{ .name = "data-pipeline", .prompts = 9, .contexts = 6, .overrides = 0, .local_rev = 19, .remote_rev = 19, .paths = 1, .open_prs = 0, .last_sync = "8 min ago", .access_level = .member },
    .{ .name = "admin-dashboard", .prompts = 11, .contexts = 4, .overrides = 1, .local_rev = 25, .remote_rev = 25, .paths = 1, .open_prs = 2, .last_sync = "15 min ago", .access_level = .admin },
};


pub const ContextFile = struct {
    path: []const u8,
    size: []const u8,
    hash: []const u8,
    state: []const u8,
    modified: bool, // true = your branch differs from main
    branch_diff: []const []const u8, // your branch diff vs main
};

pub const WsPromptEntry = struct {
    name: []const u8,
    kind: []const u8,
    has_override: bool,
    hash: []const u8,
    state: []const u8,
    override_diff: []const []const u8,
};

// ── Insights data model (aligned with s1-4 signal_ratio spec) ──

pub const ConstraintStat = struct {
    id: []const u8,
    label: []const u8,
    refer_count: u32,
    idle_days: ?u16, // null = active
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
    signal_ratio: u8, // 0-100, displayed as percentage
    refer_count: u32,
    rate_per_day: u16,
    delta_pct: i8,
    last_referred_days_ago: ?u16, // null = never referred
    trend: [30]u16,
    constraints: []const ConstraintStat,
};

pub const InsightsMember = struct {
    username: []const u8,
    refer_count: u32,
    active_days: u8,
    trend: [30]u16, // daily refer counts (30d), used for contribution heatmap
    top_prompts: []const MemberPromptStat,
    models: []const InsightsModel,
};

pub const InsightsModel = struct {
    model_id: []const u8,
    refer_count: u32,
    pct: u8, // percentage of total
};

pub const AlertLevel = enum {
    prune, // idle constraints, needs pruning
    declining, // refer rate dropping
    healthy, // all good

    pub fn icon(self: AlertLevel) []const u8 {
        return switch (self) {
            .prune => "\xe2\x9a\xa0", // ⚠
            .declining => "\xe2\x86\x93", // ↓
            .healthy => "\xe2\x9c\x93", // ✓
        };
    }
};

pub const InsightsAlert = struct {
    prompt_name: []const u8,
    level: AlertLevel,
    message: []const u8,
};

pub const InsightsData = struct {
    // Header
    constraint_count: u32,
    active_constraint_count: u32,
    idle_constraint_count: u32,
    signal_ratio: u8, // 0-100
    refers_per_hour: u16,
    today_delta_pct: i8,
    last_event_minutes_ago: u16,
    // Chart
    refer_trend: [30]u16, // daily refer counts (30d)
    // Prompts
    prompts: []const InsightsPrompt,
    // Members
    members: []const InsightsMember,
    // Models
    models: []const InsightsModel,
    // Alerts
    alerts: []const InsightsAlert,
};

// Context branch diffs (member branch vs main)
const ctx_api_diff = [_][]const u8{
    "  # API Design Spec",
    "  ",
    "  ## Authentication",
    "- All endpoints require Bearer token.",
    "+ All endpoints require Bearer token or API key.",
    "+ API keys are scoped per-workspace.",
    "  ",
    "  ## Rate Limiting",
    "  Default: 100 req/min per token.",
    "+ Added: burst allowance of 20 req/s for batch ops.",
    "  ",
    "  ## Error Format",
    "  All errors return JSON with `code` and `message`.",
    "+ Added: `request_id` field for tracing.",
    "+ Added: `retry_after` header on 429 responses.",
};
const ctx_audit_diff = [_][]const u8{
    "  # Audit Journal 05",
    "  ",
    "- ## Findings: 3 issues identified",
    "+ ## Findings: 5 issues identified",
    "  ",
    "  1. Token rotation not enforced",
    "  2. Stale sessions not cleaned up",
    "  3. Missing rate limit on /sync endpoint",
    "+ 4. Webhook secrets stored in plaintext",
    "+ 5. No audit log for permission changes",
    "  ",
    "  ## Recommendations",
    "- Schedule fix for Q2.",
    "+ Schedule fix for Q2. Items 4-5 are P0.",
};
const ctx_empty_diff = [_][]const u8{};

const style_diff = [_][]const u8{
    "  # STYLE",
    "- 1. Prefer short names.",
    "+ 1. Prefer explicit names over abbreviations.",
    "+ 2. Group imports by scope.",
    "  3. Sort file sections in dependency order.",
};
const api_diff = [_][]const u8{
    "  # API_REVIEW",
    "+ Added: validate response schemas against OpenAPI spec.",
    "  Check error codes match documentation.",
};
const zig_diff = [_][]const u8{
    "  # DEPRECATED_API",
    "- std.heap.GeneralPurposeAllocator",
    "+ std.heap.DebugAllocator",
    "  Target version: 0.15.1",
};
const empty_diff = [_][]const u8{};

pub const WS_PROMPTS = [_]WsPromptEntry{
    .{ .name = "cmd/GEN_COMMIT_MSG", .kind = "wf", .has_override = false, .hash = "e4f5", .state = "fresh", .override_diff = &empty_diff },
    .{ .name = "coding/API_REVIEW", .kind = "rule", .has_override = true, .hash = "bcdd", .state = "local", .override_diff = &api_diff },
    .{ .name = "coding/CODE_COMMENTS", .kind = "rule", .has_override = false, .hash = "u0v1", .state = "fresh", .override_diff = &empty_diff },
    .{ .name = "coding/COMPATIBILITY", .kind = "rule", .has_override = false, .hash = "q6r7", .state = "fresh", .override_diff = &empty_diff },
    .{ .name = "coding/STYLE", .kind = "rule", .has_override = true, .hash = "a1b2", .state = "stale", .override_diff = &style_diff },
    .{ .name = "wf/RELEASE_CHECKLIST", .kind = "wf", .has_override = false, .hash = "91ab", .state = "fresh", .override_diff = &empty_diff },
    .{ .name = "zig/DEPRECATED_API", .kind = "rule", .has_override = true, .hash = "c8d9", .state = "stale", .override_diff = &zig_diff },
    .{ .name = "zig/ZIG_STYLE", .kind = "rule", .has_override = false, .hash = "y4z5", .state = "fresh", .override_diff = &empty_diff },
};

pub const WS_CONTEXT = [_]ContextFile{
    .{ .path = "spec/API_DESIGN.md", .size = "2.0k", .hash = "x1y2", .state = "fresh", .modified = true, .branch_diff = &ctx_api_diff },
    .{ .path = "research/competitor.md", .size = "1.0k", .hash = "m7n8", .state = "fresh", .modified = false, .branch_diff = &ctx_empty_diff },
    .{ .path = "journal/05_AUDIT.md", .size = "3.2k", .hash = "p9q0", .state = "local", .modified = true, .branch_diff = &ctx_audit_diff },
    .{ .path = "thesis/T0-observability.md", .size = "4.1k", .hash = "r3s4", .state = "fresh", .modified = false, .branch_diff = &ctx_empty_diff },
};


const style_constraints = [_]ConstraintStat{
    .{ .id = "c-1", .label = "naming conventions", .refer_count = 1280, .idle_days = null },
    .{ .id = "c-2", .label = "import ordering", .refer_count = 890, .idle_days = null },
    .{ .id = "c-3", .label = "formatting rules", .refer_count = 720, .idle_days = null },
    .{ .id = "c-4", .label = "code organization", .refer_count = 180, .idle_days = null },
    .{ .id = "c-5", .label = "file structure", .refer_count = 80, .idle_days = null },
    .{ .id = "c-6", .label = "error handling", .refer_count = 40, .idle_days = null },
    .{ .id = "c-7", .label = "test conventions", .refer_count = 20, .idle_days = null },
    .{ .id = "c-8", .label = "unused rule", .refer_count = 0, .idle_days = 14 },
};

const empty_constraints = [_]ConstraintStat{};

const alice_prompts = [_]MemberPromptStat{
    .{ .name = "coding/STYLE", .refer_count = 68 },
    .{ .name = "zig/ZIG_STYLE", .refer_count = 32 },
    .{ .name = "coding/API_REVIEW", .refer_count = 24 },
};
const bob_prompts = [_]MemberPromptStat{
    .{ .name = "coding/STYLE", .refer_count = 42 },
    .{ .name = "zig/DEPRECATED", .refer_count = 28 },
};
const carol_prompts = [_]MemberPromptStat{
    .{ .name = "coding/COMMENTS", .refer_count = 35 },
    .{ .name = "coding/STYLE", .refer_count = 22 },
};
const dave_prompts = [_]MemberPromptStat{
    .{ .name = "wf/RELEASE", .refer_count = 18 },
};

const alice_models = [_]InsightsModel{
    .{ .model_id = "claude-opus", .refer_count = 138, .pct = 97 },
    .{ .model_id = "gpt-4o", .refer_count = 4, .pct = 3 },
};
const bob_models = [_]InsightsModel{
    .{ .model_id = "claude-opus", .refer_count = 95, .pct = 97 },
    .{ .model_id = "gpt-4o", .refer_count = 3, .pct = 3 },
};
const single_model = [_]InsightsModel{
    .{ .model_id = "claude-opus", .refer_count = 67, .pct = 100 },
};

// @zig-fmt: off
const insights_prompts = [_]InsightsPrompt{
    .{ .name = "coding/STYLE",      .constraint_count = 8,  .active_constraint_count = 7,  .idle_constraint_count = 1, .signal_ratio = 87,  .refer_count = 3210, .rate_per_day = 42, .delta_pct = 8,   .last_referred_days_ago = 0,  .trend = .{ 85, 90, 95, 88, 102, 108, 112, 98, 105, 115, 120, 110, 118, 125, 130, 122, 128, 135, 140, 132, 138, 142, 148, 140, 145, 150, 155, 148, 152, 158 }, .constraints = &style_constraints },
    .{ .name = "coding/API_REVIEW", .constraint_count = 12, .active_constraint_count = 10, .idle_constraint_count = 2, .signal_ratio = 83,  .refer_count = 842,  .rate_per_day = 12, .delta_pct = 14,  .last_referred_days_ago = 0,  .trend = .{ 18, 20, 22, 25, 24, 28, 30, 26, 32, 35, 28, 30, 34, 38, 36, 40, 42, 38, 35, 40, 45, 42, 48, 44, 40, 46, 50, 48, 52, 55 }, .constraints = &empty_constraints },
    .{ .name = "wf/RELEASE",        .constraint_count = 4,  .active_constraint_count = 4,  .idle_constraint_count = 0, .signal_ratio = 100, .refer_count = 611,  .rate_per_day = 8,  .delta_pct = -2,  .last_referred_days_ago = 1,  .trend = .{ 25, 28, 30, 32, 28, 26, 24, 22, 25, 28, 30, 26, 24, 22, 20, 22, 24, 26, 22, 20, 18, 20, 22, 24, 20, 18, 16, 18, 20, 18 }, .constraints = &empty_constraints },
    .{ .name = "coding/COMMENTS",   .constraint_count = 9,  .active_constraint_count = 7,  .idle_constraint_count = 2, .signal_ratio = 77,  .refer_count = 488,  .rate_per_day = 6,  .delta_pct = 5,   .last_referred_days_ago = 0,  .trend = .{ 12, 14, 15, 16, 14, 18, 20, 16, 18, 20, 22, 18, 20, 22, 24, 20, 22, 24, 26, 22, 24, 26, 28, 24, 26, 28, 30, 26, 28, 30 }, .constraints = &empty_constraints },
    .{ .name = "zig/ZIG_STYLE",     .constraint_count = 11, .active_constraint_count = 8,  .idle_constraint_count = 3, .signal_ratio = 72,  .refer_count = 412,  .rate_per_day = 5,  .delta_pct = 3,   .last_referred_days_ago = 0,  .trend = .{ 10, 12, 14, 12, 15, 16, 14, 18, 16, 14, 18, 20, 16, 18, 20, 22, 18, 16, 20, 22, 18, 20, 22, 24, 20, 18, 22, 24, 20, 22 }, .constraints = &empty_constraints },
    .{ .name = "zig/DEPRECATED",    .constraint_count = 59, .active_constraint_count = 52, .idle_constraint_count = 7, .signal_ratio = 88,  .refer_count = 387,  .rate_per_day = 5,  .delta_pct = 11,  .last_referred_days_ago = 0,  .trend = .{ 5, 6, 8, 10, 8, 12, 14, 10, 12, 15, 18, 14, 16, 18, 20, 16, 18, 22, 24, 18, 20, 22, 25, 20, 22, 25, 28, 22, 25, 28 }, .constraints = &empty_constraints },
    .{ .name = "coding/COMPAT",     .constraint_count = 8,  .active_constraint_count = 8,  .idle_constraint_count = 0, .signal_ratio = 100, .refer_count = 198,  .rate_per_day = 3,  .delta_pct = 1,   .last_referred_days_ago = 1,  .trend = .{ 5, 6, 6, 7, 6, 7, 8, 6, 7, 8, 6, 7, 8, 7, 6, 7, 8, 7, 6, 7, 8, 7, 6, 7, 8, 7, 6, 7, 8, 7 }, .constraints = &empty_constraints },
    .{ .name = "wf/GEN_PR",         .constraint_count = 4,  .active_constraint_count = 4,  .idle_constraint_count = 0, .signal_ratio = 100, .refer_count = 102,  .rate_per_day = 1,  .delta_pct = -5,  .last_referred_days_ago = 2,  .trend = .{ 6, 5, 5, 4, 5, 4, 4, 3, 4, 3, 4, 3, 3, 4, 3, 3, 2, 3, 3, 2, 3, 2, 2, 3, 2, 2, 1, 2, 2, 1 }, .constraints = &empty_constraints },
    .{ .name = "arch/ADR_DOC",      .constraint_count = 6,  .active_constraint_count = 6,  .idle_constraint_count = 0, .signal_ratio = 100, .refer_count = 58,   .rate_per_day = 1,  .delta_pct = 0,   .last_referred_days_ago = 3,  .trend = .{ 2, 2, 2, 2, 1, 2, 2, 2, 1, 2, 2, 2, 2, 1, 2, 2, 2, 1, 2, 2, 2, 2, 1, 2, 2, 2, 1, 2, 2, 2 }, .constraints = &empty_constraints },
    .{ .name = "style/UIUX",        .constraint_count = 7,  .active_constraint_count = 0,  .idle_constraint_count = 7, .signal_ratio = 0,   .refer_count = 0,    .rate_per_day = 0,  .delta_pct = 0,   .last_referred_days_ago = 14, .trend = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .constraints = &empty_constraints },
    .{ .name = "wf/GITIGNORE",      .constraint_count = 3,  .active_constraint_count = 0,  .idle_constraint_count = 3, .signal_ratio = 0,   .refer_count = 0,    .rate_per_day = 0,  .delta_pct = 0,   .last_referred_days_ago = null, .trend = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .constraints = &empty_constraints },
    .{ .name = "cmd/GEN_ISSUE",     .constraint_count = 4,  .active_constraint_count = 0,  .idle_constraint_count = 4, .signal_ratio = 0,   .refer_count = 0,    .rate_per_day = 0,  .delta_pct = 0,   .last_referred_days_ago = 21, .trend = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .constraints = &empty_constraints },
};

const insights_members = [_]InsightsMember{
    .{ .username = "alice", .refer_count = 142, .active_days = 22, .trend = .{ 4, 6, 5, 8, 7, 0, 0, 5, 7, 6, 9, 8, 1, 0, 6, 8, 7, 10, 9, 2, 0, 7, 9, 8, 11, 10, 3, 1, 8, 10 }, .top_prompts = &alice_prompts, .models = &alice_models },
    .{ .username = "bob",   .refer_count = 98,  .active_days = 18, .trend = .{ 3, 4, 0, 5, 6, 0, 0, 4, 3, 0, 6, 7, 2, 0, 3, 5, 0, 7, 8, 0, 0, 4, 6, 0, 8, 7, 1, 0, 5, 7 }, .top_prompts = &bob_prompts, .models = &bob_models },
    .{ .username = "carol", .refer_count = 67,  .active_days = 15, .trend = .{ 0, 3, 4, 2, 0, 0, 0, 0, 4, 5, 3, 0, 0, 0, 0, 5, 6, 4, 0, 0, 0, 0, 6, 5, 3, 0, 0, 0, 5, 4 }, .top_prompts = &carol_prompts, .models = &single_model },
    .{ .username = "dave",  .refer_count = 31,  .active_days = 8,  .trend = .{ 2, 0, 0, 3, 2, 0, 0, 0, 0, 0, 4, 3, 0, 0, 0, 0, 0, 5, 2, 0, 0, 0, 0, 0, 4, 3, 0, 0, 0, 2 }, .top_prompts = &dave_prompts, .models = &single_model },
};
// @zig-fmt: on

const insights_models = [_]InsightsModel{
    .{ .model_id = "claude-opus", .refer_count = 3800, .pct = 90 },
    .{ .model_id = "gpt-4o", .refer_count = 400, .pct = 10 },
};

const insights_alerts = [_]InsightsAlert{
    .{ .prompt_name = "style/UIUX", .level = .prune, .message = "7 idle constraints \u{2014} consider pruning" },
    .{ .prompt_name = "wf/GITIGNORE", .level = .prune, .message = "3 idle \u{2014} never referred" },
    .{ .prompt_name = "cmd/GEN_ISSUE", .level = .prune, .message = "4 idle for 21d" },
    .{ .prompt_name = "wf/GEN_PR", .level = .declining, .message = "refer rate -5% this week" },
    .{ .prompt_name = "wf/RELEASE", .level = .declining, .message = "refer rate -2% this week" },
    .{ .prompt_name = "coding/STYLE", .level = .healthy, .message = "signal 7/8, +8% this week" },
};

pub const INSIGHTS: InsightsData = .{
    .constraint_count = 380,
    .active_constraint_count = 312,
    .idle_constraint_count = 68,
    .signal_ratio = 82,
    .refers_per_hour = 42,
    .today_delta_pct = 12,
    .last_event_minutes_ago = 2,
    .refer_trend = .{ 145, 160, 155, 172, 168, 42, 28, 158, 175, 168, 192, 188, 48, 32, 172, 190, 182, 210, 205, 55, 35, 185, 205, 195, 225, 218, 62, 38, 198, 215 },
    .prompts = &insights_prompts,
    .members = &insights_members,
    .models = &insights_models,
    .alerts = &insights_alerts,
};

pub const SAMPLE_CONTENT =
    \\# Code Comments
    \\
    \\Code comments must be final-form text. No thinking
    \\process or intermediate reasoning.
    \\
    \\## Prohibited comment types
    \\
    \\- Thinking process: `// Wait, let me recalculate...`
    \\- Personal dialogue: `// Actually...`
    \\- Vague markers: `// TODO: Fix this later`
    \\  (must state what specifically needs fixing)
    \\
    \\## Allowed comment types
    \\
    \\- Technical notes: explain complex logic, algorithms
    \\- Functional markers: `// TODO: Implement signature
    \\  verification for production`
    \\- Security warnings: `// SECURITY: Must validate
    \\  inputs before...`
    \\
    \\## No decorative separators
    \\
    \\Do not use repeated symbols to draw separators,
    \\borders, or decorations in comments.
    \\
    \\## Language
    \\
    \\All code comments must be in English.
    \\
    \\## Audience
    \\
    \\All code comments must assume the reader is another
    \\developer, not a personal memo.
;

pub const MemberEntry = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    joined: []const u8,
};

pub const MEMBERS = [_]MemberEntry{
    .{ .user_id = "usr-001", .username = "alice", .role = "maintainer", .joined = "2026-01-15" },
    .{ .user_id = "usr-002", .username = "bob", .role = "member", .joined = "2026-02-20" },
    .{ .user_id = "usr-003", .username = "carol", .role = "member", .joined = "2026-03-05" },
    .{ .user_id = "usr-004", .username = "dave", .role = "member", .joined = "2026-03-18" },
};

// Mirrors GET /api/auth/me + config.toml workspace bindings
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

const my_scopes = [_][]const u8{
    "library:read",
    "workspace:read",
    "workspace:write",
    "trace:write",
    "stats:read",
    "pr:read",
    "pr:write",
    "members:read",
};

// Token scope definitions for the Hub Server permission model
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

const payments_paths = [_][]const u8{ "~/work/payments", "~/work/payments-v2" };
const merchant_paths = [_][]const u8{ "~/work/merchant", "~/projects/merchant-staging" };
const infra_paths = [_][]const u8{"~/work/infra-tools"};
const bot_paths = [_][]const u8{"~/work/release-bot"};
const docs_paths = [_][]const u8{"~/work/docs-site"};
const mobile_paths = [_][]const u8{ "~/work/mobile", "~/projects/mobile-beta" };
const pipeline_paths = [_][]const u8{"~/work/data-pipeline"};
const empty_paths = [_][]const u8{};

const my_workspaces = [_]WsAccess{
    .{ .name = "payments-api", .role = .admin, .paths = &payments_paths },
    .{ .name = "merchant-portal", .role = .member, .paths = &merchant_paths },
    .{ .name = "infra-tools", .role = .member, .paths = &infra_paths },
    .{ .name = "release-bot", .role = .member, .paths = &bot_paths },
    .{ .name = "docs-site", .role = .member, .paths = &docs_paths },
    .{ .name = "mobile-app", .role = .admin, .paths = &mobile_paths },
    .{ .name = "data-pipeline", .role = .member, .paths = &pipeline_paths },
    .{ .name = "admin-dashboard", .role = .admin, .paths = &empty_paths },
};

pub const CLIENT_CONFIG = ClientConfig{
    .server_url = "https://hub.acme.io",
    .sync_strategy = "session",
    .token_status = "active",
    .token_expires = "2026-04-07T12:00:00Z",
};

pub const CURRENT_USER = CurrentUser{
    .user_id = "usr-0001",
    .username = "alice",
    .role = "maintainer",
    .scopes = &my_scopes,
    .workspaces = &my_workspaces,
};

pub const TokenInfo = struct {
    scopes: []const []const u8,
    expires: []const u8,
};


pub const CURRENT_TOKEN = TokenInfo{
    .scopes = &my_scopes,
    .expires = "2026-04-07T12:00:00Z",
};

pub fn syncStateLabel(ws: *const WorkspaceEntry) []const u8 {
    if (ws.local_rev == ws.remote_rev) return "up to date";
    return "behind";
}

pub fn syncStateColor(ws: *const WorkspaceEntry) @import("theme.zig").Color {
    const t = @import("theme.zig");
    if (ws.local_rev == ws.remote_rev) return t.OK;
    return t.WARN;
}

const Color = @import("vaxis").Color;
