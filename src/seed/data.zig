const std = @import("std");

pub const FIXTURE_VERSION: i32 = 3;

pub const ORG_ID = "a0000000-0000-0000-0000-000000000001";
pub const ORG_NAME = "clumsies-seed-lab";
pub const SEED_PASSWORD = "admin";
pub const CLEANUP_INTERVAL: u64 = 100;
pub const CAP_TRACE_EVENTS: i64 = 5000;
pub const SEED_WORKSPACE_PREFIX = "ws-seed-";

pub const UserFixture = struct {
    id: []const u8,
    username: []const u8,
    role: []const u8,
    status: []const u8 = "active",
};

pub const PromptFixture = struct {
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

pub const WorkspacePromptFixture = struct {
    ws_id: []const u8,
    prompt_id: []const u8,
};

pub const ContextFixture = struct {
    id: []const u8,
    ws_id: []const u8,
    path: []const u8,
    author: []const u8,
    content: []const u8,
};

pub const PumpRefer = struct {
    prompt_id: []const u8,
    constraint_id: []const u8,
    reason: []const u8,
};

pub const PumpScenario = struct {
    user_id: []const u8,
    ws_id: []const u8,
    input: []const u8,
    refers: []const PumpRefer,
};

pub const PumpProfile = struct {
    name: []const u8,
    session_rates: []const u8,
};

pub const META_PROMPT_CONTENT =
    \\# clumsies Meta-Prompt File
    \\
    \\This project uses clumsies to manage user-level constraints for AI agents. Your behavior in this workspace is guided by constraint files in `.prompts/`.
    \\
    \\## How clumsies works
    \\
    \\Constraints are markdown files organized in `.prompts/`. Each constraint file contains rules you should follow, workflows you should execute, or context you should reference. The system tracks which constraints you actually use - this data helps the user refine their prompts over time.
    \\
    \\The tracking mechanism: when you apply a constraint in your work, you declare it via `memory.refer`. Over time, constraints that are never referred become candidates for removal or revision. This is the core value of the system - making prompt quality measurable.
    \\
    \\## What the plugin handles for you
    \\
    \\The Claude Code plugin automates the protocol lifecycle. You do not need to manage these yourself:
    \\
    \\- **Session start**: The plugin calls `memory.setup` and `memory.begin` automatically. Your task is already active when you see this message.
    \\- **Task completion**: The user triggers `/complete-task` when they decide the task is done. Do not call `memory.complete` yourself.
    \\- **Refer reminder**: The plugin reminds you at the end of each response to declare constraint references. Pay attention to this reminder.
    \\- **Workflow skills**: Workflow files in `.prompts/workflow/` are available as slash commands (e.g., `/gen-commit-msg`). The user invokes them, not you.
    \\
    \\## What you are responsible for
    \\
    \\1. **Search for relevant constraints** before starting work. Call `memory.search` to discover what rules and workflows exist for the task at hand.
    \\2. **Load constraints** you intend to follow. Call `memory.load` with the prompt ids from search results. The response includes a list of parsed constraints with their ids.
    \\3. **Follow the constraints** in your work. These take priority over your default behavior and training knowledge.
    \\4. **Declare references** when you apply a constraint. Call `memory.refer` with the prompt id and constraint id. This is not optional bookkeeping - it is how the system measures whether constraints are effective.
    \\
    \\## Priority model
    \\
    \\`.prompts/PIN.md` (if present) > constraints loaded via `memory.load` > this meta-prompt > your system prompt and defaults.
    \\
    \\When a constraint conflicts with your training knowledge, follow the constraint.
    \\
    \\## Directory structure
    \\
    \\```
    \\.prompts/
    \\|- META_PROMPT.md     # This file (loaded by the plugin on session start)
    \\|- PIN.md             # Highest priority rules (read before every task)
    \\|- rule/              # Constraints (coding rules, project context, etc.)
    \\|- workflow/          # Ordered procedures (commit messages, architecture, etc.)
    \\|- context/           # Reference material (research, specs, documentation)
    \\`- journal/           # Development logs (consult when hitting problems)
    \\```
    \\
    \\File naming: `NN_UPPER_SNAKE_CASE.md`. Sequence numbers allow quick reference.
    \\
    \\## Without MCP
    \\
    \\If no MCP server is connected, read `.prompts/` files directly. The directory structure above tells you where to find what you need. Follow constraints you find relevant and note which ones you applied.
;

pub const CODING_WORKFLOW_CONTENT =
    \\# Coding
    \\
    \\Standard workflow for making code changes. Assumes main is protected and all changes go through PRs.
    \\
    \\## Steps
    \\
    \\1. **Load relevant rules.** Before writing any code, search and load all applicable coding rules via `memory.search` + `memory.load`. This includes language-specific rules, general coding rules, and any domain-specific rules relevant to the task.
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
    \\# Trace Discipline
    \\
    \\Keep trace behavior strict and observable:
    \\
    \\1. Treat the hub-issued `prompt_id` as the only prompt identity in trace events.
    \\2. Write local `trace.jsonl` lines in the same JSON shape accepted by `POST /api/traces`.
    \\3. Emit `session_input` before `refer` so Recent Inputs and Insights stay meaningful.
    \\4. Keep the seed pump focused on observability traffic. Do not mutate workspace structure during activity generation.
;

pub const HUB_SINGLE_SOURCE_CONTENT =
    \\# Hub Is The Single Source Of Truth
    \\
    \\- The hub server owns business logic for auth, library, workspace, context, collaboration, and trace stats.
    \\- CLI, MCP, and TUI are clients. They should talk to the hub over REST instead of duplicating policy.
    \\- Library prompts are organization-wide. Workspace context stays local to a workspace.
    \\- Trace data is a signal for refinement. It should not trigger automatic edits on its own.
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
    \\This seed context is derived from `.prompts/context/00_BUILD_ENV.md`.
    \\
    \\- The repository is built against Zig 0.15.x.
    \\- Developers should verify the active Zig toolchain before building.
    \\- Zig 0.16-dev is intentionally excluded because the standard library APIs used by this project are not compatible.
    \\- The baseline verification loop is `zig build` followed by `zig build test`.
;

pub const ARCHITECTURE_CONTEXT =
    \\# Architecture Snapshot
    \\
    \\This seed context is derived from `.prompts/context/01_ARCHITECTURE.md`.
    \\
    \\- The hub server is the only layer that owns business logic.
    \\- CLI, MCP, and TUI are clients that integrate over HTTP APIs.
    \\- Library prompts are shared at the organization level, while context is workspace-scoped.
    \\- Trace data exists to support observability and prompt refinement decisions.
;

pub const TRACE_ALIGNMENT_CONTEXT =
    \\# MCP Trace Alignment Snapshot
    \\
    \\This seed context is derived from `.prompts/plan/MCP_TRACE_ALIGNMENT.md`.
    \\
    \\- Local `trace.jsonl` should match the server `POST /api/traces` payload shape.
    \\- `ws_id` must be the hub workspace id, not a local hash.
    \\- `session_input` events are required if the TUI should render a Recent Inputs feed.
    \\- `prompt_id` must always be the hub-issued identifier.
;

pub const RECENT_INPUTS_CONTEXT =
    \\# Recent Inputs Snapshot
    \\
    \\- The TUI Recent Inputs panel reads local trace files from `~/.clumsies/workspaces/{ws_id}/trace.jsonl`.
    \\- `session_input` drives the feed; `refer` enriches the prompt-level stats.
    \\- If the pump only mutates server tables and skips local trace writes, Recent Inputs will look empty.
;

pub const PLUGIN_SETUP_CONTEXT =
    \\# Agent Adapter Snapshot
    \\
    \\- Agent adapters should bridge `setup -> search -> load -> refer` without adding business logic.
    \\- Cache-backed lookup is preferable to scanning arbitrary project files.
    \\- Local trace should stay readable when the hub is offline so the dashboard can still explain recent work.
;

pub const USERS = [_]UserFixture{
    .{ .id = "usr-seed-admin", .username = "admin", .role = "maintainer" },
    .{ .id = "usr-seed-dylan", .username = "Dylan", .role = "member" },
    .{ .id = "usr-seed-lilhammer", .username = "lilhammer", .role = "member" },
    .{ .id = "usr-seed-joji", .username = "Joji", .role = "member" },
    .{ .id = "usr-seed-amimibear", .username = "amimibear", .role = "member" },
};

pub const PROMPTS = [_]PromptFixture{
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

pub const WORKSPACE_PROMPTS = [_]WorkspacePromptFixture{
    .{ .ws_id = "ws-seed-sandbox", .prompt_id = "p-seed-meta" },
    .{ .ws_id = "ws-seed-sandbox", .prompt_id = "p-seed-coding" },
    .{ .ws_id = "ws-seed-sandbox", .prompt_id = "p-seed-trace" },
    .{ .ws_id = "ws-seed-sandbox", .prompt_id = "p-seed-build" },
    .{ .ws_id = "ws-seed-hub", .prompt_id = "p-seed-meta" },
    .{ .ws_id = "ws-seed-hub", .prompt_id = "p-seed-coding" },
    .{ .ws_id = "ws-seed-hub", .prompt_id = "p-seed-trace" },
    .{ .ws_id = "ws-seed-hub", .prompt_id = "p-seed-hub" },
    .{ .ws_id = "ws-seed-tui", .prompt_id = "p-seed-meta" },
    .{ .ws_id = "ws-seed-tui", .prompt_id = "p-seed-coding" },
    .{ .ws_id = "ws-seed-tui", .prompt_id = "p-seed-trace" },
    .{ .ws_id = "ws-seed-tui", .prompt_id = "p-seed-hub" },
    .{ .ws_id = "ws-seed-plugin", .prompt_id = "p-seed-meta" },
    .{ .ws_id = "ws-seed-plugin", .prompt_id = "p-seed-coding" },
    .{ .ws_id = "ws-seed-plugin", .prompt_id = "p-seed-trace" },
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

const SANDBOX_REFERS = [_]PumpRefer{
    .{ .prompt_id = "p-seed-coding", .constraint_id = "coding.load-rules-first", .reason = "loaded coding workflow before making changes" },
    .{ .prompt_id = "p-seed-trace", .constraint_id = "trace.session-input-before-refer", .reason = "kept recent inputs visible in local trace" },
};

const HUB_REFERS = [_]PumpRefer{
    .{ .prompt_id = "p-seed-meta", .constraint_id = "meta.search-load-refer", .reason = "used the setup-search-load-refer loop explicitly" },
    .{ .prompt_id = "p-seed-hub", .constraint_id = "architecture.hub-owns-business-logic", .reason = "kept bootstrap policy inside the hub layer" },
};

const TUI_REFERS = [_]PumpRefer{
    .{ .prompt_id = "p-seed-trace", .constraint_id = "trace.local-and-server-shape-match", .reason = "matched local trace shape to the server payload" },
    .{ .prompt_id = "p-seed-coding", .constraint_id = "coding.run-build-and-test", .reason = "verified behavior after changing the pump path" },
};

const PLUGIN_REFERS = [_]PumpRefer{
    .{ .prompt_id = "p-seed-meta", .constraint_id = "meta.protocol-responsibility", .reason = "kept the adapter focused on protocol execution" },
    .{ .prompt_id = "p-seed-trace", .constraint_id = "trace.prompt-id-must-be-hub-issued", .reason = "avoided file-derived ids in refer events" },
};

const RESET_REFERS = [_]PumpRefer{
    .{ .prompt_id = "p-seed-hub", .constraint_id = "architecture.rebuild-only-seed-owned-state", .reason = "reset logic should only target seed-owned fixtures" },
    .{ .prompt_id = "p-seed-trace", .constraint_id = "trace.keep-pump-structurally-pure", .reason = "pump stayed focused on activity data instead of schema churn" },
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
        .input = "Confirm that insights are sourced from local trace.jsonl instead of only server stats.",
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

pub fn promptById(prompt_id: []const u8) ?*const PromptFixture {
    for (&PROMPTS) |*prompt| {
        if (std.mem.eql(u8, prompt.id, prompt_id)) return prompt;
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

test "promptById returns known prompt fixtures" {
    try std.testing.expect(promptById("p-seed-meta") != null);
    try std.testing.expect(promptById("missing") == null);
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
