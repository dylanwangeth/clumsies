// Mock data matching the real clumsies data model (spec s1-0 through s2-3).
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
};

pub const BundleEntry = struct {
    name: []const u8,
    count: u16,
};

pub const HistoryEntry = struct {
    date: []const u8,
    hash: []const u8,
    label: []const u8,
};

pub const ProposalEntry = struct {
    id: []const u8,
    prompt_name: []const u8,
    status: []const u8,
    author: []const u8,
    created: []const u8,
    base_hash: []const u8,
    diff: []const []const u8,
    trace_refers: u16,
    trace_sessions: u8,
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
    .{ .canonical_name = "cmd/GEN_COMMIT_MSG", .kind = "wf", .refer_count = "1.1k", .constraint_count = 5, .bundle_count = 1, .bundle_names = "default", .updated = "2026-03-31", .age = "5d", .summary = "Review git changes and suggest a commit message", .trend = .{ 2, 3, 4, 4, 5, 5, 4, 3 }, .content_hash = "sha256:e4f5g6h7" },
    .{ .canonical_name = "coding/STYLE", .kind = "rule", .refer_count = "3.2k", .constraint_count = 8, .bundle_count = 2, .bundle_names = "frontend, default", .updated = "2026-04-04", .age = "2d", .summary = "Naming, imports, formatting, and code organization rules", .trend = .{ 1, 2, 3, 5, 6, 8, 6, 5 }, .content_hash = "sha256:a1b2c3d4" },
    .{ .canonical_name = "coding/API_REVIEW", .kind = "rule", .refer_count = "842", .constraint_count = 12, .bundle_count = 1, .bundle_names = "backend", .updated = "2026-04-05", .age = "1d", .summary = "API design review checklist for consistency and safety", .trend = .{ 3, 4, 5, 6, 7, 8, 7, 6 }, .content_hash = "sha256:i8j9k0l1" },
    .{ .canonical_name = "coding/COMPATIBILITY", .kind = "rule", .refer_count = "520", .constraint_count = 8, .bundle_count = 1, .bundle_names = "default", .updated = "2026-04-03", .age = "3d", .summary = "Breaking changes happen freely, no compatibility layers", .trend = .{ 2, 2, 3, 3, 4, 4, 3, 3 }, .content_hash = "sha256:q6r7s8t9" },
    .{ .canonical_name = "coding/CODE_COMMENTS", .kind = "rule", .refer_count = "488", .constraint_count = 9, .bundle_count = 2, .bundle_names = "frontend, backend", .updated = "2026-04-02", .age = "4d", .summary = "Comments must be final-form text, no thinking process", .trend = .{ 1, 2, 2, 3, 3, 4, 3, 3 }, .content_hash = "sha256:u0v1w2x3" },
    .{ .canonical_name = "style/UIUX_DESIGN", .kind = "rule", .refer_count = "178", .constraint_count = 7, .bundle_count = 1, .bundle_names = "frontend", .updated = "2026-03-31", .age = "5d", .summary = "UI/UX design method with pressure-testing and smoke checks", .trend = .{ 0, 1, 1, 2, 2, 3, 2, 2 }, .content_hash = "sha256:k6l7m8n9" },
    .{ .canonical_name = "wf/RELEASE_CHECKLIST", .kind = "wf", .refer_count = "611", .constraint_count = 4, .bundle_count = 2, .bundle_names = "release, ops", .updated = "2026-03-28", .age = "8d", .summary = "Pre-release verification steps for branch and CI", .trend = .{ 1, 1, 2, 2, 3, 3, 2, 2 }, .content_hash = "sha256:m2n3o4p5" },
    .{ .canonical_name = "wf/GEN_GITIGNORE", .kind = "wf", .refer_count = "145", .constraint_count = 3, .bundle_count = 1, .bundle_names = "ops", .updated = "2026-03-23", .age = "14d", .summary = "Generate .gitignore based on project type and toolchain", .trend = .{ 1, 1, 1, 1, 2, 1, 1, 1 }, .content_hash = "sha256:o0p1q2r3" },
    .{ .canonical_name = "wf/GEN_PR", .kind = "wf", .refer_count = "102", .constraint_count = 4, .bundle_count = 1, .bundle_names = "default", .updated = "2026-03-28", .age = "8d", .summary = "Create pull request with summary and test plan", .trend = .{ 0, 1, 1, 1, 2, 2, 1, 1 }, .content_hash = "sha256:s4t5u6v7" },
    .{ .canonical_name = "zig/ZIG_STYLE", .kind = "rule", .refer_count = "412", .constraint_count = 11, .bundle_count = 1, .bundle_names = "default", .updated = "2026-04-04", .age = "2d", .summary = "Zig naming conventions, error handling, and memory management", .trend = .{ 3, 3, 4, 5, 5, 6, 5, 4 }, .content_hash = "sha256:y4z5a6b7" },
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

const std = @import("std");

pub const HISTORY = [_]HistoryEntry{
    .{ .date = "2026-04-04", .hash = "sha256:a1b2c3d4", .label = "current" },
    .{ .date = "2026-03-28", .hash = "sha256:x9y8z7w6", .label = "prop-0042" },
    .{ .date = "2026-03-10", .hash = "sha256:l3m4n5o6", .label = "prop-0038" },
    .{ .date = "2026-02-14", .hash = "sha256:q1r2s3t4", .label = "seed" },
};

pub const PROPOSALS = [_]ProposalEntry{
    .{ .id = "prop-0051", .prompt_name = "coding/STYLE", .status = "open", .author = "alice", .created = "2026-04-05 10:00", .base_hash = "sha256:a1b2c3d4", .diff = &.{
        "@@ -1,3 +1,5 @@",
        " # STYLE",
        "-1. Prefer short names.",
        "+1. Prefer explicit names over abbreviations.",
        "+2. Group imports by scope.",
        " 3. Sort file sections in dependency order.",
    }, .trace_refers = 42, .trace_sessions = 12 },
    .{ .id = "prop-0050", .prompt_name = "cmd/GEN_COMMIT_MSG", .status = "open", .author = "bob", .created = "2026-04-05 09:12", .base_hash = "sha256:e4f5g6h7", .diff = &.{
        "@@ -1,2 +1,3 @@",
        " # GEN_COMMIT_MSG",
        "+Use conventional commit prefixes.",
        " Keep message under 72 chars.",
    }, .trace_refers = 18, .trace_sessions = 5 },
    .{ .id = "prop-0049", .prompt_name = "wf/RELEASE_CHECKLIST", .status = "accepted", .author = "carol", .created = "2026-04-04 16:30", .base_hash = "sha256:m2n3o4p5", .diff = &.{
        "@@ -4,1 +4,2 @@",
        " 4. Tag release branch.",
        "+5. Verify CI green before merge.",
    }, .trace_refers = 31, .trace_sessions = 8 },
};

pub const WORKSPACES = [_]WorkspaceEntry{
    .{ .name = "payments-api", .prompts = 18, .contexts = 9, .overrides = 3, .local_rev = 41, .remote_rev = 43, .paths = 2, .open_prs = 2, .last_sync = "1h ago" },
    .{ .name = "merchant-portal", .prompts = 14, .contexts = 5, .overrides = 1, .local_rev = 37, .remote_rev = 37, .paths = 1, .open_prs = 0, .last_sync = "2 min ago" },
    .{ .name = "infra-tools", .prompts = 8, .contexts = 3, .overrides = 0, .local_rev = 22, .remote_rev = 22, .paths = 1, .open_prs = 1, .last_sync = "5 min ago" },
    .{ .name = "release-bot", .prompts = 5, .contexts = 2, .overrides = 0, .local_rev = 15, .remote_rev = 15, .paths = 1, .open_prs = 0, .last_sync = "3 min ago" },
    .{ .name = "docs-site", .prompts = 6, .contexts = 4, .overrides = 0, .local_rev = 10, .remote_rev = 10, .paths = 1, .open_prs = 0, .last_sync = "10 min ago" },
    .{ .name = "mobile-app", .prompts = 12, .contexts = 7, .overrides = 2, .local_rev = 28, .remote_rev = 30, .paths = 2, .open_prs = 1, .last_sync = "30 min ago" },
    .{ .name = "data-pipeline", .prompts = 9, .contexts = 6, .overrides = 0, .local_rev = 19, .remote_rev = 19, .paths = 1, .open_prs = 0, .last_sync = "8 min ago" },
    .{ .name = "admin-dashboard", .prompts = 11, .contexts = 4, .overrides = 1, .local_rev = 25, .remote_rev = 25, .paths = 1, .open_prs = 2, .last_sync = "15 min ago" },
};

pub const ContextBranch = struct {
    name: []const u8,
    file_count: u8,
    ahead: u8,
    behind: u8,
};

pub const ContextPR = struct {
    id: []const u8,
    author: []const u8,
    status: []const u8,
    description: []const u8,
    files_changed: u8,
};

pub const CONTEXT_BRANCHES = [_]ContextBranch{
    .{ .name = "main", .file_count = 9, .ahead = 0, .behind = 0 },
    .{ .name = "alice", .file_count = 3, .ahead = 3, .behind = 0 },
    .{ .name = "bob", .file_count = 1, .ahead = 1, .behind = 1 },
    .{ .name = "carol", .file_count = 2, .ahead = 2, .behind = 0 },
};

pub const CONTEXT_PRS = [_]ContextPR{
    .{ .id = "cpr-001", .author = "alice", .status = "open", .description = "Add API design spec for payments module", .files_changed = 2 },
    .{ .id = "cpr-002", .author = "carol", .status = "open", .description = "Add observability research notes", .files_changed = 1 },
};

pub const OverrideEntry = struct {
    prompt_name: []const u8,
    base_hash: []const u8,
    current_hash: []const u8,
    status: []const u8,
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

pub const InsightsWs = struct {
    name: []const u8,
    coverage: u8,
    refer_count: []const u8,
    trend: [8]u8,
};

pub const HotspotEntry = struct {
    name: []const u8,
    refer_count: []const u8,
    prompt_idx: usize,
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
    .{ .name = "coding/STYLE", .kind = "rule", .has_override = true, .hash = "a1b2", .state = "stale", .override_diff = &style_diff },
    .{ .name = "cmd/GEN_COMMIT_MSG", .kind = "wf", .has_override = false, .hash = "e4f5", .state = "fresh", .override_diff = &empty_diff },
    .{ .name = "coding/API_REVIEW", .kind = "rule", .has_override = true, .hash = "bcdd", .state = "local", .override_diff = &api_diff },
    .{ .name = "wf/RELEASE_CHECKLIST", .kind = "wf", .has_override = false, .hash = "91ab", .state = "fresh", .override_diff = &empty_diff },
    .{ .name = "coding/COMPATIBILITY", .kind = "rule", .has_override = false, .hash = "q6r7", .state = "fresh", .override_diff = &empty_diff },
    .{ .name = "coding/CODE_COMMENTS", .kind = "rule", .has_override = false, .hash = "u0v1", .state = "fresh", .override_diff = &empty_diff },
    .{ .name = "zig/ZIG_STYLE", .kind = "rule", .has_override = false, .hash = "y4z5", .state = "fresh", .override_diff = &empty_diff },
    .{ .name = "zig/DEPRECATED_API", .kind = "rule", .has_override = true, .hash = "c8d9", .state = "stale", .override_diff = &zig_diff },
};

pub const WS_CONTEXT = [_]ContextFile{
    .{ .path = "spec/API_DESIGN.md", .size = "2.0k", .hash = "x1y2", .state = "fresh", .modified = true, .branch_diff = &ctx_api_diff },
    .{ .path = "research/competitor.md", .size = "1.0k", .hash = "m7n8", .state = "fresh", .modified = false, .branch_diff = &ctx_empty_diff },
    .{ .path = "journal/05_AUDIT.md", .size = "3.2k", .hash = "p9q0", .state = "local", .modified = true, .branch_diff = &ctx_audit_diff },
    .{ .path = "thesis/T0-observability.md", .size = "4.1k", .hash = "r3s4", .state = "fresh", .modified = false, .branch_diff = &ctx_empty_diff },
};

pub const WS_OVERRIDES = [_]OverrideEntry{
    .{ .prompt_name = "coding/STYLE", .base_hash = "a1b2", .current_hash = "c3d4", .status = "conflict" },
    .{ .prompt_name = "coding/API_REVIEW", .base_hash = "f1e2", .current_hash = "f1e2", .status = "clean" },
    .{ .prompt_name = "zig/DEPRECATED_API", .base_hash = "c8d9", .current_hash = "c8d9", .status = "clean" },
};

pub const INSIGHTS_WS = [_]InsightsWs{
    .{ .name = "payments-api", .coverage = 82, .refer_count = "4.2k", .trend = .{ 2, 3, 4, 5, 6, 7, 6, 5 } },
    .{ .name = "merchant-portal", .coverage = 76, .refer_count = "3.1k", .trend = .{ 1, 2, 3, 4, 5, 5, 4, 3 } },
    .{ .name = "infra-tools", .coverage = 74, .refer_count = "2.8k", .trend = .{ 2, 2, 3, 3, 4, 4, 3, 3 } },
    .{ .name = "release-bot", .coverage = 63, .refer_count = "1.1k", .trend = .{ 1, 1, 2, 2, 3, 3, 2, 2 } },
    .{ .name = "docs-site", .coverage = 61, .refer_count = "0.9k", .trend = .{ 0, 1, 1, 2, 2, 3, 2, 2 } },
};

pub const HOTSPOTS = [_]HotspotEntry{
    .{ .name = "coding/STYLE", .refer_count = "3210", .prompt_idx = 0 },
    .{ .name = "coding/API_REVIEW", .refer_count = "990", .prompt_idx = 2 },
    .{ .name = "wf/RELEASE_CHECKLIST", .refer_count = "611", .prompt_idx = 3 },
    .{ .name = "coding/CODE_COMMENTS", .refer_count = "488", .prompt_idx = 5 },
    .{ .name = "zig/ZIG_STYLE", .refer_count = "412", .prompt_idx = 6 },
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

pub const TokenInfo = struct {
    scope: []const u8,
    expires: []const u8,
};

pub const CURRENT_TOKEN = TokenInfo{
    .scope = "library:read workspace:read trace:write stats:read proposal:read proposal:write",
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
