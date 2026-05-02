//! Seed fixture data: users, workspaces, rules, bundles, and constraints for development.
//! These fixtures populate the database with realistic data so the TUI and CLI can be developed
//! against a working Hub instance.
const std = @import("std");

pub const FIXTURE_VERSION: i32 = 3;

pub const ORG_ID = "a0000000-0000-0000-0000-000000000001";
pub const ORG_NAME = "clumsies-seed-lab";
pub const SEED_PASSWORD = "admin";
pub const CLEANUP_INTERVAL: u64 = 100;
pub const CAP_ATTESTATION_EVENTS: i64 = 5000;
pub const SEED_WORKSPACE_PREFIX = "ws-seed-";

pub const UserFixture = struct {
    id: []const u8,
    username: []const u8,
    role: []const u8,
    status: []const u8 = "active",
};

pub const RuleFixture = struct {
    id: []const u8,
    path: []const u8,
    content: []const u8,
};

pub const WorkspaceFixture = struct {
    id: []const u8,
    name: []const u8,
};

pub const WorkspaceMemberFixture = struct {
    ws_id: []const u8,
    user_id: []const u8,
    role: []const u8,
};

pub const WorkspaceRuleFixture = struct {
    ws_id: []const u8,
    rule_id: []const u8,
};

pub const ContextFixture = struct {
    id: []const u8,
    ws_id: []const u8,
    path: []const u8,
    author: []const u8,
    content: []const u8,
};

pub const RuleRefer = struct {
    rule_id: []const u8,
    constraint_id: []const u8,
    reason: []const u8,
};

pub const PumpScenario = struct {
    user_id: []const u8,
    ws_id: []const u8,
    input: []const u8,
    refers: []const RuleRefer,
};

pub const PumpProfile = struct {
    name: []const u8,
    session_rates: []const u8,
};

pub const META_PROMPT_CONTENT =
    \\# clumsies
    \\
    \\This workspace uses [clumsies](https://github.com/lilhammerfun/clumsies/blob/main/README.md)
    \\to manage rules and context for AI agents. These coexist with your own memory,
    \\but take priority when they conflict.
    \\
    \\## Protocol
    \\
    \\Follow this loop every turn:
    \\
    \\1. **Discover.** Call `memory.discover()` to list all available rules,
    \\   workflows, and context. Read their descriptions to decide what is relevant.
    \\2. **Load.** Call `memory.load()` with the ids you need and a `knownHashes`
    \\   entry for every id. Use a remembered hash when available, otherwise pass an
    \\   empty string. Loaded content includes parsed rule ids.
    \\3. **Apply.** Follow loaded rules in your work. Rules override your defaults.
    \\4. **Refer.** Call `memory.refer()` for each rule you applied. This is
    \\   not optional — it is how the system measures rule effectiveness.
    \\5. **Refine.** When the user asks you to create, update, rename,
    \\   delete, or discard draft changes for rules, context, or MPF.
    \\   Use the `draft` tool with a `resource` value and exactly one
    \\   tagged `op` object.
    \\6. **Submit.** Call `memory.submit()` with a short summary of your work before
    \\   finishing every response. The stop hook will block if you forget.
    \\
    \\## Resource types
    \\
    \\- **rule** (`<category>/<name>.md`) — rules to follow in your work.
    \\- **workflow** (`workflow/<name>.md`) — ordered procedures, exposed as
    \\  slash commands by the adapter.
    \\- **context** — workspace-scoped reference material (design docs, research,
    \\  specs).
    \\
    \\Categories are organizational only (e.g. `coding/`, `zig/`, `writing/`).
    \\
    \\Filter with `memory.discover({kind: "rule"})` or `memory.discover({group: "zig"})`.
    \\
    \\## Accountability
    \\
    \\If you fail to follow loaded rules, the user may call `/ntmd` to reject the turn.
    \\This records a `memory.reject()` event. When this happens, review which rules you
    \\missed and correct your approach.
    \\
    \\## Priority
    \\
    \\Loaded rules > this meta-rule > your defaults.
    \\
    \\When a rule conflicts with your training, follow the rule.
;

pub const CODING_WORKFLOW_CONTENT =
    \\# Coding
    \\
    \\Standard workflow for making code changes. Assumes main is protected and all changes go through PRs.
    \\
    \\## Steps
    \\
    \\1. **Load relevant rules.** Before writing any code, search and load all applicable coding rules via `memory.discover` + `memory.load`. This includes language-specific rules, general coding rules, and any domain-specific rules relevant to the task.
    \\2. **Assess complexity.** For non-trivial tasks, design the approach before writing code.
    \\3. Ensure you are on `main` and up to date.
    \\4. Create a feature branch.
    \\5. Make changes, committing logically.
    \\6. Run `zig build` and `zig build test` before pushing.
    \\7. Push and open a PR when ready.
    \\
    \\## Rule loading
    \\
    \\Every coding task must begin with loading applicable rules. At minimum: language rules, coding rules, and domain rules.
    \\
    \\## Safety
    \\
    \\- Run tests before every push.
    \\- Never force-push to shared branches without warning collaborators.
    \\- Keep commits buildable and split by concern.
;

pub const TRACE_DISCIPLINE_CONTENT =
    \\# Attestation Discipline
    \\
    \\Keep attestation behavior strict and observable:
    \\
    \\1. Treat the hub-issued `rule_id` as the only rule identity in attestation events.
    \\2. Write local attestation log lines in the same JSON shape accepted by `POST /api/attestations`.
    \\3. Emit `user_prompt` before `refer` so Recent Inputs and Insights stay meaningful.
    \\4. Keep the seed pump focused on observability traffic. Do not mutate workspace structure during activity generation.
;

pub const HUB_SINGLE_SOURCE_CONTENT =
    \\# Hub Is The Single Source Of Truth
    \\
    \\- The hub server owns business logic for auth, library, workspace, context, collaboration, and attestation stats.
    \\- CLI, MCP, and TUI are clients. They should talk to the hub over REST instead of duplicating policy.
    \\- Library rules are organization-wide. Workspace context stays local to a workspace.
    \\- Attestation data is a signal for refinement. It should not trigger automatic edits on its own.
;

pub const ZIG_TOOLCHAIN_CONTENT =
    \\# Zig Toolchain
    \\
    \\- This repo targets Zig 0.15.x.
    \\- Do not assume Zig 0.16-dev APIs; `std.io` and `std.fs` changed in breaking ways there.
    \\- Before shipping non-trivial changes, run `zig build` and `zig build test`.
;

pub const BUILD_ENV_CONTEXT =
    \\# Build Environment Snapshot
    \\
    \\This seed context is derived from `.rules/context/00_BUILD_ENV.md`.
    \\
    \\- The repository is built against Zig 0.15.x.
    \\- Developers should verify the active Zig toolchain before building.
    \\- Zig 0.16-dev is intentionally excluded because the standard library APIs used by this project are not compatible.
    \\- The baseline verification loop is `zig build` followed by `zig build test`.
;

pub const ARCHITECTURE_CONTEXT =
    \\# Architecture Snapshot
    \\
    \\This seed context is derived from `.rules/context/01_ARCHITECTURE.md`.
    \\
    \\- The hub server is the only layer that owns business logic.
    \\- CLI, MCP, and TUI are clients that integrate over HTTP APIs.
    \\- Library rules are shared at the organization level, while context is workspace-scoped.
    \\- Attestation data exists to support observability and rule refinement decisions.
;

pub const TRACE_ALIGNMENT_CONTEXT =
    \\# MCP Attestation Alignment Snapshot
    \\
    \\This seed context is derived from `.rules/plan/MCP_TRACE_ALIGNMENT.md`.
    \\
    \\- Local attestation logs should match the server `POST /api/attestations` payload shape.
    \\- `ws_id` must be the hub workspace id, not a local hash.
    \\- `user_prompt` events are required if the TUI should render a Recent Inputs feed.
    \\- `rule_id` must always be the hub-issued identifier.
;

pub const RECENT_INPUTS_CONTEXT =
    \\# Recent Inputs Snapshot
    \\
    \\- The TUI Recent Inputs panel reads local attestation logs from `~/.clumsies/workspaces/{ws_id}/logs/attestation/*.jsonl`.
    \\- `user_prompt` drives the feed; `refer` enriches the rule-level stats.
    \\- If the pump only mutates server tables and skips local attestation writes, Recent Inputs will look empty.
;

pub const PLUGIN_SETUP_CONTEXT =
    \\# Agent Adapter Snapshot
    \\
    \\- Agent adapters should bridge `setup -> search -> load -> refer` without adding business logic.
    \\- Cache-backed lookup is preferable to scanning arbitrary project files.
    \\- Local attestation should stay readable when the hub is offline so the dashboard can still explain recent work.
;

pub const USERS = [_]UserFixture{
    .{ .id = "usr-seed-admin", .username = "admin", .role = "maintainer" },
    .{ .id = "usr-seed-dylan", .username = "Dylan", .role = "member" },
    .{ .id = "usr-seed-lilhammer", .username = "lilhammer", .role = "member" },
    .{ .id = "usr-seed-joji", .username = "Joji", .role = "member" },
    .{ .id = "usr-seed-amimibear", .username = "amimibear", .role = "member" },
};

pub const RULES = [_]RuleFixture{
    .{ .id = "p-seed-meta", .path = "META_PROMPT.md", .content = META_PROMPT_CONTENT },
    .{ .id = "p-seed-coding", .path = "workflow/00_CODING.md", .content = CODING_WORKFLOW_CONTENT },
    .{ .id = "p-seed-trace", .path = "rule/trace/TRACE_DISCIPLINE.md", .content = TRACE_DISCIPLINE_CONTENT },
    .{ .id = "p-seed-hub", .path = "rule/architecture/HUB_SINGLE_SOURCE.md", .content = HUB_SINGLE_SOURCE_CONTENT },
    .{ .id = "p-seed-build", .path = "rule/build/ZIG_TOOLCHAIN.md", .content = ZIG_TOOLCHAIN_CONTENT },
};

pub const WORKSPACES = [_]WorkspaceFixture{
    .{ .id = "ws-seed-sandbox", .name = "seed-sandbox" },
    .{ .id = "ws-seed-hub", .name = "hub-bootstrap" },
    .{ .id = "ws-seed-tui", .name = "tui-insights" },
    .{ .id = "ws-seed-plugin", .name = "plugin-lab" },
};

pub const WORKSPACE_MEMBERS = [_]WorkspaceMemberFixture{
    .{ .ws_id = "ws-seed-sandbox", .user_id = "usr-seed-admin", .role = "admin" },
    .{ .ws_id = "ws-seed-hub", .user_id = "usr-seed-admin", .role = "admin" },
    .{ .ws_id = "ws-seed-tui", .user_id = "usr-seed-admin", .role = "admin" },
    .{ .ws_id = "ws-seed-plugin", .user_id = "usr-seed-admin", .role = "admin" },
    .{ .ws_id = "ws-seed-sandbox", .user_id = "usr-seed-dylan", .role = "admin" },
    .{ .ws_id = "ws-seed-tui", .user_id = "usr-seed-dylan", .role = "admin" },
    .{ .ws_id = "ws-seed-hub", .user_id = "usr-seed-lilhammer", .role = "admin" },
    .{ .ws_id = "ws-seed-plugin", .user_id = "usr-seed-joji", .role = "member" },
    .{ .ws_id = "ws-seed-sandbox", .user_id = "usr-seed-amimibear", .role = "member" },
    .{ .ws_id = "ws-seed-plugin", .user_id = "usr-seed-amimibear", .role = "member" },
};

pub const WORKSPACE_RULES = [_]WorkspaceRuleFixture{
    .{ .ws_id = "ws-seed-sandbox", .rule_id = "p-seed-meta" },
    .{ .ws_id = "ws-seed-sandbox", .rule_id = "p-seed-coding" },
    .{ .ws_id = "ws-seed-sandbox", .rule_id = "p-seed-trace" },
    .{ .ws_id = "ws-seed-sandbox", .rule_id = "p-seed-build" },
    .{ .ws_id = "ws-seed-hub", .rule_id = "p-seed-meta" },
    .{ .ws_id = "ws-seed-hub", .rule_id = "p-seed-coding" },
    .{ .ws_id = "ws-seed-hub", .rule_id = "p-seed-trace" },
    .{ .ws_id = "ws-seed-hub", .rule_id = "p-seed-hub" },
    .{ .ws_id = "ws-seed-tui", .rule_id = "p-seed-meta" },
    .{ .ws_id = "ws-seed-tui", .rule_id = "p-seed-coding" },
    .{ .ws_id = "ws-seed-tui", .rule_id = "p-seed-trace" },
    .{ .ws_id = "ws-seed-tui", .rule_id = "p-seed-hub" },
    .{ .ws_id = "ws-seed-plugin", .rule_id = "p-seed-meta" },
    .{ .ws_id = "ws-seed-plugin", .rule_id = "p-seed-coding" },
    .{ .ws_id = "ws-seed-plugin", .rule_id = "p-seed-trace" },
};

pub const CONTEXTS = [_]ContextFixture{
    .{ .id = "ctx-seed-sandbox-build", .ws_id = "ws-seed-sandbox", .path = "spec/BUILD_ENV.md", .author = "Dylan", .content = BUILD_ENV_CONTEXT },
    .{ .id = "ctx-seed-sandbox-inputs", .ws_id = "ws-seed-sandbox", .path = "notes/RECENT_INPUTS.md", .author = "amimibear", .content = RECENT_INPUTS_CONTEXT },
    .{ .id = "ctx-seed-hub-arch", .ws_id = "ws-seed-hub", .path = "spec/ARCHITECTURE.md", .author = "lilhammer", .content = ARCHITECTURE_CONTEXT },
    .{ .id = "ctx-seed-hub-build", .ws_id = "ws-seed-hub", .path = "spec/BUILD_ENV.md", .author = "admin", .content = BUILD_ENV_CONTEXT },
    .{ .id = "ctx-seed-tui-trace", .ws_id = "ws-seed-tui", .path = "research/MCP_TRACE_ALIGNMENT.md", .author = "Dylan", .content = TRACE_ALIGNMENT_CONTEXT },
    .{ .id = "ctx-seed-tui-inputs", .ws_id = "ws-seed-tui", .path = "notes/RECENT_INPUTS.md", .author = "Joji", .content = RECENT_INPUTS_CONTEXT },
    .{ .id = "ctx-seed-plugin-trace", .ws_id = "ws-seed-plugin", .path = "research/MCP_TRACE_ALIGNMENT.md", .author = "amimibear", .content = TRACE_ALIGNMENT_CONTEXT },
    .{ .id = "ctx-seed-plugin-adapter", .ws_id = "ws-seed-plugin", .path = "notes/PLUGIN_SETUP.md", .author = "Joji", .content = PLUGIN_SETUP_CONTEXT },
};

const SANDBOX_REFERS = [_]RuleRefer{
    .{ .rule_id = "p-seed-coding", .constraint_id = "coding.load-rules-first", .reason = "loaded coding workflow before making changes" },
    .{ .rule_id = "p-seed-trace", .constraint_id = "trace.session-input-before-refer", .reason = "kept recent inputs visible in local trace" },
};

const HUB_REFERS = [_]RuleRefer{
    .{ .rule_id = "p-seed-meta", .constraint_id = "meta.search-load-refer", .reason = "used the setup-search-load-refer loop explicitly" },
    .{ .rule_id = "p-seed-hub", .constraint_id = "architecture.hub-owns-business-logic", .reason = "kept bootstrap policy inside the hub layer" },
};

const TUI_REFERS = [_]RuleRefer{
    .{ .rule_id = "p-seed-trace", .constraint_id = "trace.local-and-server-shape-match", .reason = "matched local trace shape to the server payload" },
    .{ .rule_id = "p-seed-coding", .constraint_id = "coding.run-build-and-test", .reason = "verified behavior after changing the pump path" },
};

const PLUGIN_REFERS = [_]RuleRefer{
    .{ .rule_id = "p-seed-meta", .constraint_id = "meta.protocol-responsibility", .reason = "kept the adapter focused on protocol execution" },
    .{ .rule_id = "p-seed-trace", .constraint_id = "trace.rule-id-must-be-hub-issued", .reason = "avoided file-derived ids in refer events" },
};

const RESET_REFERS = [_]RuleRefer{
    .{ .rule_id = "p-seed-hub", .constraint_id = "architecture.rebuild-only-seed-owned-state", .reason = "reset logic should only target seed-owned fixtures" },
    .{ .rule_id = "p-seed-trace", .constraint_id = "trace.keep-pump-structurally-pure", .reason = "pump stayed focused on activity data instead of schema churn" },
};

const PROFILE_RAMP_UP = [_]u8{ 1, 1, 2, 2, 3, 3, 4, 4, 5, 6, 7, 8 };
const PROFILE_COOLDOWN = [_]u8{ 8, 7, 6, 5, 4, 3, 2, 2, 1, 1, 1, 0 };
const PROFILE_WAVE = [_]u8{ 2, 3, 5, 6, 5, 3, 2, 3, 5, 6, 4, 2 };
const PROFILE_SPIKE = [_]u8{ 0, 0, 1, 1, 2, 8, 10, 3, 1, 1, 0, 0 };
const PROFILE_LOW_AMBIENT = [_]u8{ 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0 };

pub const PUMP_PROFILES = [_]PumpProfile{
    .{ .name = "ramp-up", .session_rates = &PROFILE_RAMP_UP },
    .{ .name = "cooldown", .session_rates = &PROFILE_COOLDOWN },
    .{ .name = "wave", .session_rates = &PROFILE_WAVE },
    .{ .name = "spike", .session_rates = &PROFILE_SPIKE },
    .{ .name = "low-ambient", .session_rates = &PROFILE_LOW_AMBIENT },
};

pub const PUMP_SCENARIOS = [_]PumpScenario{
    .{
        .user_id = "usr-seed-dylan",
        .ws_id = "ws-seed-sandbox",
        .input = "Investigate why the Recent Inputs panel is empty in the TUI dashboard.",
        .refers = &SANDBOX_REFERS,
    },
    .{
        .user_id = "usr-seed-lilhammer",
        .ws_id = "ws-seed-hub",
        .input = "Verify first maintainer bootstrap when HUB_BOOTSTRAP_USERNAME is missing.",
        .refers = &HUB_REFERS,
    },
    .{
        .user_id = "usr-seed-admin",
        .ws_id = "ws-seed-tui",
        .input = "Confirm that insights are sourced from local attestation logs instead of only server stats.",
        .refers = &TUI_REFERS,
    },
    .{
        .user_id = "usr-seed-joji",
        .ws_id = "ws-seed-plugin",
        .input = "Sketch a Codex adapter that can honor setup search load refer over the current hub.",
        .refers = &PLUGIN_REFERS,
    },
    .{
        .user_id = "usr-seed-amimibear",
        .ws_id = "ws-seed-sandbox",
        .input = "Keep clumsies-seed focused on fixture repair plus trace pump instead of random structural writes.",
        .refers = &RESET_REFERS,
    },
};

pub fn ruleById(rule_id: []const u8) ?*const RuleFixture {
    for (&RULES) |*rule| {
        if (std.mem.eql(u8, rule.id, rule_id)) return rule;
    }
    return null;
}

pub fn userById(user_id: []const u8) ?*const UserFixture {
    for (&USERS) |*user| {
        if (std.mem.eql(u8, user.id, user_id)) return user;
    }
    return null;
}

pub fn workspaceById(ws_id: []const u8) ?*const WorkspaceFixture {
    for (&WORKSPACES) |*workspace| {
        if (std.mem.eql(u8, workspace.id, ws_id)) return workspace;
    }
    return null;
}

pub fn isSeedWorkspaceId(ws_id: []const u8) bool {
    return std.mem.startsWith(u8, ws_id, SEED_WORKSPACE_PREFIX);
}

test "ruleById returns known rule fixtures" {
    try std.testing.expect(ruleById("p-seed-meta") != null);
    try std.testing.expect(ruleById("missing") == null);
}

test "seed lookup helpers resolve user and workspace fixtures" {
    try std.testing.expect(userById("usr-seed-admin") != null);
    try std.testing.expect(userById("missing") == null);
    try std.testing.expect(workspaceById("ws-seed-tui") != null);
    try std.testing.expect(workspaceById("missing") == null);
}

test "isSeedWorkspaceId matches fixed seed prefix" {
    try std.testing.expect(isSeedWorkspaceId("ws-seed-sandbox"));
    try std.testing.expect(!isSeedWorkspaceId("ws-prod-real"));
}
