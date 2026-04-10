const std = @import("std");

const Self = @This();

rng: std.Random.DefaultPrng,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Self {
    var seed: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&seed));
    return .{
        .rng = std.Random.DefaultPrng.init(seed),
        .allocator = allocator,
    };
}

pub fn initWithSeed(allocator: std.mem.Allocator, seed: u64) Self {
    return .{
        .rng = std.Random.DefaultPrng.init(seed),
        .allocator = allocator,
    };
}

pub fn random(self: *Self) std.Random {
    return self.rng.random();
}

// Pick a random element from a slice
pub fn pick(self: *Self, comptime T: type, items: []const T) T {
    return items[self.random().intRangeLessThan(usize, 0, items.len)];
}

// Generate a random hex ID with a prefix: "ppr-a1b2c3d4e5f6..."
// Fills the entire buffer: prefix + hex chars to fill remaining space.
pub fn hexId(self: *Self, buf: *[24]u8, prefix: []const u8) []const u8 {
    const hex = "0123456789abcdef";
    @memcpy(buf[0..prefix.len], prefix);
    // Fill remaining bytes with hex
    const remaining = buf.len - prefix.len;
    const rand_byte_count = (remaining + 1) / 2;
    var rand_bytes: [12]u8 = undefined;
    self.random().bytes(rand_bytes[0..rand_byte_count]);
    for (0..remaining) |i| {
        const byte = rand_bytes[i / 2];
        buf[prefix.len + i] = if (i % 2 == 0) hex[byte >> 4] else hex[byte & 0x0f];
    }
    return buf;
}

// Generate a random integer in range [min, max)
pub fn intRange(self: *Self, comptime T: type, min: T, max: T) T {
    return self.random().intRangeLessThan(T, min, max);
}

// Generate a past timestamp as milliseconds offset from now
// Returns a negative offset in ms (e.g., -86400000 for 1 day ago)
pub fn pastDaysMs(self: *Self, max_days: u32) i64 {
    const days = self.intRange(u32, 1, max_days + 1);
    const hours = self.intRange(u32, 0, 24);
    const mins = self.intRange(u32, 0, 60);
    return -@as(i64, @intCast(days)) * 86400000 -
        @as(i64, @intCast(hours)) * 3600000 -
        @as(i64, @intCast(mins)) * 60000;
}

// Return a SQL interval string like "14 days 3 hours 22 minutes"
pub fn pastInterval(self: *Self, buf: *[64]u8, max_days: u32) []const u8 {
    const days = self.intRange(u32, 1, max_days + 1);
    const hours = self.intRange(u32, 0, 24);
    const mins = self.intRange(u32, 0, 60);
    return std.fmt.bufPrint(buf, "{d} days {d} hours {d} minutes", .{ days, hours, mins }) catch "1 days";
}

pub fn boolean(self: *Self) bool {
    return self.random().boolean();
}

// Weighted boolean: returns true with probability weight/100
pub fn chance(self: *Self, weight: u8) bool {
    return self.intRange(u8, 0, 100) < weight;
}

// Names

const FIRST_NAMES = [_][]const u8{
    "alice", "bob",   "carol",  "dave",  "eve",    "frank",
    "grace", "henry", "iris",   "jack",  "kate",   "liam",
    "maya",  "noah",  "olivia", "peter", "quinn",  "rose",
    "sam",   "tara",  "victor", "wendy", "xander", "yuki",
    "zara",
};

const TEAM_NAMES = [_][]const u8{
    "frontend", "backend",  "infra",  "platform", "mobile",
    "data",     "security", "devops", "design",   "qa",
};

pub fn firstName(self: *Self) []const u8 {
    return self.pick([]const u8, &FIRST_NAMES);
}

pub fn teamName(self: *Self) []const u8 {
    return self.pick([]const u8, &TEAM_NAMES);
}

// Prompt domain

const RULE_GROUPS = [_][]const u8{
    "coding", "zig", "style", "security", "testing", "api", "db", "perf",
};

const RULE_NAMES = [_][]const u8{
    "STYLE",            "COMMENTS",      "COMPATIBILITY",  "DEPENDENCIES", "NAMING",
    "ERROR_HANDLING",   "MEMORY_SAFETY", "CONCURRENCY",    "LOGGING",      "AUTH",
    "INPUT_VALIDATION", "RATE_LIMITING", "E2E",            "UNIT_TEST",    "BENCHMARKS",
    "UIUX",             "ACCESSIBILITY", "DEPRECATED_API",
};

const WORKFLOW_NAMES = [_][]const u8{
    "CODING",      "RELEASE", "GEN_COMMIT_MSG", "GEN_PR",            "JOURNAL",
    "CODE_REVIEW", "DEPLOY",  "ROLLBACK",       "INCIDENT_RESPONSE",
};

pub fn promptCanonicalName(self: *Self, buf: *[80]u8) []const u8 {
    if (self.chance(70)) {
        const group = self.pick([]const u8, &RULE_GROUPS);
        const name = self.pick([]const u8, &RULE_NAMES);
        return std.fmt.bufPrint(buf, "rule/{s}/{s}", .{ group, name }) catch "rule/coding/STYLE";
    } else {
        const name = self.pick([]const u8, &WORKFLOW_NAMES);
        return std.fmt.bufPrint(buf, "workflow/{s}", .{name}) catch "workflow/CODING";
    }
}

pub fn promptKind(self: *Self) []const u8 {
    return if (self.chance(70)) "rule" else "workflow";
}

const RULE_CONTENT_TEMPLATES = [_][]const u8{
    "# {name}\n\nThis rule defines conventions for {topic} in the codebase.\n\n## Requirements\n\n- Follow consistent patterns across all modules\n- Document exceptions explicitly\n- Run automated checks before committing",
    "# {name}\n\n## Scope\n\nApplies to all {topic} code in the project.\n\n## Conventions\n\n1. Prefer explicit over implicit behavior\n2. Handle errors at the appropriate level\n3. Keep functions focused on a single responsibility",
    "# {name}\n\nStandard {topic} practices for the team.\n\n## Prohibited\n\n- Skipping validation on external input\n- Swallowing errors silently\n- Using deprecated APIs\n\n## Preferred\n\n- Explicit error propagation\n- Structured logging\n- Defensive programming at boundaries",
};

const WORKFLOW_CONTENT_TEMPLATES = [_][]const u8{
    "# {name}\n\n## Steps\n\n1. Review current state and gather context\n2. Plan the approach and identify risks\n3. Execute changes incrementally\n4. Verify each step before proceeding\n5. Document decisions and outcomes",
    "# {name}\n\nStandard procedure for {topic}.\n\n## Prerequisites\n\n- Clean working tree\n- All tests passing\n- Peer review completed\n\n## Execution\n\n1. Create tracking issue\n2. Prepare changes\n3. Run validation suite\n4. Submit for approval",
};

const TOPICS = [_][]const u8{
    "error handling",            "memory management",     "API design",     "testing",
    "code organization",         "dependency management", "security",       "performance optimization",
    "logging and observability", "database operations",   "authentication", "input validation",
};

pub fn promptContent(self: *Self, buf: *[512]u8, kind: []const u8, name: []const u8) []const u8 {
    const topic = self.pick([]const u8, &TOPICS);
    const template = if (std.mem.eql(u8, kind, "rule"))
        self.pick([]const u8, &RULE_CONTENT_TEMPLATES)
    else
        self.pick([]const u8, &WORKFLOW_CONTENT_TEMPLATES);

    // Simple template substitution
    var result: []const u8 = template;
    var tmp1: [512]u8 = undefined;
    if (std.mem.indexOf(u8, result, "{name}")) |idx| {
        const before = result[0..idx];
        const after = result[idx + 6 ..];
        const len = before.len + name.len + after.len;
        if (len <= tmp1.len) {
            @memcpy(tmp1[0..before.len], before);
            @memcpy(tmp1[before.len..][0..name.len], name);
            @memcpy(tmp1[before.len + name.len ..][0..after.len], after);
            result = tmp1[0..len];
        }
    }
    var tmp2: [512]u8 = undefined;
    if (std.mem.indexOf(u8, result, "{topic}")) |idx| {
        const before = result[0..idx];
        const after = result[idx + 7 ..];
        const len = before.len + topic.len + after.len;
        if (len <= tmp2.len) {
            @memcpy(tmp2[0..before.len], before);
            @memcpy(tmp2[before.len..][0..topic.len], topic);
            @memcpy(tmp2[before.len + topic.len ..][0..after.len], after);
            result = tmp2[0..len];
        }
    }

    const out_len = @min(result.len, buf.len);
    @memcpy(buf[0..out_len], result[0..out_len]);
    return buf[0..out_len];
}

// Review comments

const REVIEW_COMMENTS = [_][]const u8{
    "LGTM, clean implementation. Ship it.",
    "Can you add a test case for the empty input scenario?",
    "The naming here doesn't match our style guide. Should be camelCase for functions.",
    "I think we should split this into two separate changes — the refactor and the feature.",
    "Approved. Nice cleanup of the error handling paths.",
    "This conflicts with the changes carol is working on in the other PR. Can you coordinate?",
    "Could you explain the rationale behind using a hash map here instead of a sorted array?",
    "Nit: trailing whitespace on line 42.",
    "The error message should be more descriptive — 'failed' doesn't help debugging.",
    "Good catch on the edge case. I missed this in the original review.",
    "This needs a migration step for existing databases. See ADR-008.",
    "Performance concern: this allocates on every request. Consider using an arena.",
    "The API contract changed — we need to update the spec document.",
    "Looks good overall. One minor suggestion: extract the validation logic into a helper.",
    "Blocking: this introduces a cross-org data leak. The query needs an org_id filter.",
    "Nice use of comptime here. Much cleaner than the runtime dispatch we had before.",
};

pub fn reviewComment(self: *Self) []const u8 {
    return self.pick([]const u8, &REVIEW_COMMENTS);
}

// PR descriptions

const PR_DESCRIPTIONS = [_][]const u8{
    "Refactor error handling to use explicit propagation instead of catch {}",
    "Add input validation for all external API endpoints",
    "Update naming conventions to match the latest style guide",
    "Fix cross-org data access vulnerability in comment endpoints",
    "Add comptime type reflection for automatic struct serialization",
    "Improve test coverage for edge cases in the sync protocol",
    "Clean up deprecated API usage after Zig 0.15 migration",
    "Add rate limiting to prevent abuse of the auth endpoints",
    "Restructure context file storage to support branch-level isolation",
    "Update prompt content to reflect current team practices",
};

pub fn prDescription(self: *Self) []const u8 {
    return self.pick([]const u8, &PR_DESCRIPTIONS);
}

// Context file paths

const CONTEXT_DIRS = [_][]const u8{
    "research", "spec", "design", "config", "docs", "adr",
};

const CONTEXT_FILES = [_][]const u8{
    "overview.md",         "implementation.md", "api-design.md",     "data-model.md",
    "deploy.toml",         "monitoring.toml",   "auth-flow.md",      "sync-protocol.md",
    "dashboard-layout.md", "library-view.md",   "error-handling.md", "performance-audit.md",
    "security-review.md",  "migration-plan.md",
};

pub fn contextPath(self: *Self, buf: *[80]u8) []const u8 {
    const dir = self.pick([]const u8, &CONTEXT_DIRS);
    const file = self.pick([]const u8, &CONTEXT_FILES);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, file }) catch "docs/overview.md";
}

pub fn contextContent(self: *Self, buf: *[256]u8) []const u8 {
    const topic = self.pick([]const u8, &TOPICS);
    return std.fmt.bufPrint(buf, "# {s}\n\nDocumentation for {s}.\n\nLast updated by the team.", .{ topic, topic }) catch "# Content";
}

// Workspace names

const WS_PREFIXES = [_][]const u8{
    "clumsies", "acme", "platform", "infra", "tools",
};

const WS_SUFFIXES = [_][]const u8{
    "main", "staging", "dev", "tui", "api", "docs", "mobile", "data",
};

pub fn workspaceName(self: *Self, buf: *[40]u8) []const u8 {
    const prefix = self.pick([]const u8, &WS_PREFIXES);
    const suffix = self.pick([]const u8, &WS_SUFFIXES);
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ prefix, suffix }) catch "workspace";
}

// Bundle names

const BUNDLE_NAMES = [_][]const u8{
    "zig-coding",  "full-stack",     "workflows",  "security-hardening",
    "api-design",  "testing-suite",  "onboarding", "code-review",
    "performance", "infrastructure",
};

const BUNDLE_DESCS = [_][]const u8{
    "Coding conventions and style rules for Zig development",
    "Complete rule set for full-stack development workflow",
    "Standard workflow prompts for common development tasks",
    "Security-focused rules and validation patterns",
    "API design patterns and REST conventions",
    "Testing strategies and coverage requirements",
    "Onboarding materials for new team members",
    "Code review guidelines and checklists",
    "Performance optimization rules and benchmarking practices",
    "Infrastructure and deployment configuration standards",
};

pub fn bundleName(self: *Self) []const u8 {
    return self.pick([]const u8, &BUNDLE_NAMES);
}

pub fn bundleDescription(self: *Self) []const u8 {
    return self.pick([]const u8, &BUNDLE_DESCS);
}

// Branch names

const BRANCH_PREFIXES = [_][]const u8{
    "feat", "fix", "refactor", "docs", "test", "chore",
};

const BRANCH_TOPICS = [_][]const u8{
    "api-docs",      "error-handling", "auth-flow", "layout-fix",
    "sync-protocol", "rate-limiting",  "readme",    "test-coverage",
    "perf-tuning",   "schema-update",  "logging",   "monitoring",
};

pub fn branchName(self: *Self, buf: *[40]u8) []const u8 {
    const prefix = self.pick([]const u8, &BRANCH_PREFIXES);
    const topic = self.pick([]const u8, &BRANCH_TOPICS);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ prefix, topic }) catch "feat/update";
}
