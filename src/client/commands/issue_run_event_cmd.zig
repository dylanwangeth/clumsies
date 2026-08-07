//! Private fail-open bridge from Coding Agent lifecycle hooks to the daemon.
//! The raw host JSON is parsed in memory and reduced to a bounded allowlist;
//! prompts, transcripts, tool payloads, and assistant messages never cross the
//! daemon IPC boundary.
const std = @import("std");
const daemon_ipc = @import("../daemon/ipc.zig");
const util_hash = @import("clumsies_lib").util.hash;

const MAX_HOOK_INPUT_BYTES = 1024 * 1024;
const MAX_HOST_ID_BYTES = 256;
const MAX_HOST_RUN_KEY_BYTES = 256;
const MAX_DISPLAY_LABEL_BYTES = 160;

const Host = enum {
    codex,
    claude_code,

    fn wireName(self: Host) []const u8 {
        return switch (self) {
            .codex => "codex",
            .claude_code => "claude-code",
        };
    }
};

const NormalizedHookEvent = struct {
    event_id: []const u8,
    hook_event_name: []const u8,
    host: []const u8,
    host_run_key: ?[]const u8,
    event_type: []const u8,
    host_session_id: []const u8,
    parent_host_run_key: ?[]const u8,
    kind: ?[]const u8,
    issue_key: ?[]const u8,
    outcome: ?[]const u8,
    display_label: ?[]const u8,
    workspace_path: ?[]const u8,
    stop_hook_active: bool,
};

/// `clumsies _agent issue-run-event --host codex|claude-code`
///
/// This command emits host hook context only after a successful start event.
/// Every parse, binding, IPC, daemon, and output failure remains a no-op so
/// lifecycle observation never blocks the host agent.
pub fn run(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    const host = parseHost(args) orelse return;

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.Options.debug_io, &stdin_buffer);
    const raw = stdin_reader.interface.allocRemaining(
        allocator,
        std.Io.Limit.limited(MAX_HOOK_INPUT_BYTES),
    ) catch return;
    defer allocator.free(raw);
    if (raw.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, scratch, raw, .{
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const event = normalizeHookEvent(scratch, host, object) catch return;

    // Claude Code's first Stop is a decision point, not an ended run. Block it
    // once so the Agent can make the semantic Issue decision; the follow-up
    // Stop carries stop_hook_active=true and is the lifecycle event we record.
    if (host == .claude_code and
        std.mem.eql(u8, event.hook_event_name, "Stop") and
        !event.stop_hook_active)
    {
        const output = claudeStopDecisionJsonAlloc(allocator) catch return;
        defer allocator.free(output);
        stdout.print("{s}\n", .{output}) catch return;
        return;
    }

    const fallback_cwd = if (event.workspace_path == null)
        std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", scratch) catch return
    else
        null;
    const workspace_path = event.workspace_path orelse fallback_cwd.?;

    var binding = daemon_ipc.resolveProjectBinding(allocator, workspace_path) catch return;
    defer binding.deinit(allocator);

    var operation = daemon_ipc.recordAgentRunEventOperation(allocator, .{
        .event_id = event.event_id,
        .project_id = binding.project_id,
        .host = event.host,
        .host_run_key = event.host_run_key,
        .event_type = event.event_type,
        .source = "hook",
        .host_session_id = event.host_session_id,
        .parent_host_run_key = event.parent_host_run_key,
        .kind = event.kind,
        .issue_key = event.issue_key,
        .outcome = event.outcome,
        .display_label = event.display_label,
    }) catch return;
    defer operation.deinit(allocator);
    if (operation.isError()) return;

    const hook_output = hookContextJsonAlloc(
        allocator,
        host,
        event.hook_event_name,
        event.event_type,
        operation.structured_json,
    ) catch return;
    if (hook_output) |output| {
        defer allocator.free(output);
        stdout.print("{s}\n", .{output}) catch return;
    }
}

fn parseHost(args: []const []const u8) ?Host {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "--host")) return null;
    if (std.mem.eql(u8, args[1], "codex")) return .codex;
    if (std.mem.eql(u8, args[1], "claude-code")) return .claude_code;
    return null;
}

fn normalizeHookEvent(
    allocator: std.mem.Allocator,
    host: Host,
    object: std.json.ObjectMap,
) !NormalizedHookEvent {
    const hook_event_name = stringField(object, "hook_event_name") orelse return error.InvalidHookPayload;
    const session_raw = stringField(object, "session_id") orelse return error.InvalidHookPayload;
    if (session_raw.len == 0) return error.InvalidHookPayload;
    const session_id = try boundedIdentifierAlloc(allocator, session_raw);
    const workspace_path = boundedWorkspacePath(stringField(object, "cwd"));

    var host_run_key: ?[]const u8 = null;
    var event_type: []const u8 = undefined;
    var kind: ?[]const u8 = null;
    const issue_key: ?[]const u8 = null;
    var outcome: ?[]const u8 = null;
    var display_label: ?[]const u8 = null;
    var parent_host_run_key: ?[]const u8 = null;

    if (std.mem.eql(u8, hook_event_name, "UserPromptSubmit")) {
        event_type = "started";
        kind = "root";
        host_run_key = try rootRunKeyAlloc(allocator, host, object);
    } else if (std.mem.eql(u8, hook_event_name, "Stop")) {
        event_type = "ended";
        kind = "root";
        host_run_key = try rootRunKeyAlloc(allocator, host, object);
    } else if (std.mem.eql(u8, hook_event_name, "StopFailure") and host == .claude_code) {
        event_type = "ended";
        kind = "root";
        outcome = "failed";
        host_run_key = try rootRunKeyAlloc(allocator, host, object);
    } else if (std.mem.eql(u8, hook_event_name, "SubagentStart")) {
        event_type = "started";
        kind = "subagent";
        host_run_key = try subagentRunKeyAlloc(allocator, object, session_id);
        parent_host_run_key = try explicitRootRunKeyAlloc(allocator, host, object);
        display_label = boundedDisplayLabel(stringField(object, "agent_type"));
    } else if (std.mem.eql(u8, hook_event_name, "SubagentStop")) {
        event_type = "ended";
        kind = "subagent";
        host_run_key = try subagentRunKeyAlloc(allocator, object, session_id);
        parent_host_run_key = try explicitRootRunKeyAlloc(allocator, host, object);
        display_label = boundedDisplayLabel(stringField(object, "agent_type"));
    } else if (std.mem.eql(u8, hook_event_name, "SessionEnd")) {
        event_type = "session_ended";
        outcome = "unknown";
    } else {
        return error.UnsupportedHookEvent;
    }

    const event_id = try eventIdAlloc(
        allocator,
        host.wireName(),
        session_id,
        hook_event_name,
        host_run_key,
    );
    return .{
        .event_id = event_id,
        .hook_event_name = hook_event_name,
        .host = host.wireName(),
        .host_run_key = host_run_key,
        .event_type = event_type,
        .host_session_id = session_id,
        .parent_host_run_key = parent_host_run_key,
        .kind = kind,
        .issue_key = issue_key,
        .outcome = outcome,
        .display_label = display_label,
        .workspace_path = workspace_path,
        .stop_hook_active = boolField(object, "stop_hook_active") orelse false,
    };
}

fn hookContextJsonAlloc(
    allocator: std.mem.Allocator,
    host: Host,
    hook_event_name: []const u8,
    event_type: []const u8,
    response_json: []const u8,
) !?[]u8 {
    if (host == .codex and
        std.mem.eql(u8, hook_event_name, "Stop") and
        std.mem.eql(u8, event_type, "ended"))
    {
        return try additionalContextJsonAlloc(
            allocator,
            hook_event_name,
            "Before ending, make an explicit semantic Issue decision. If the current root task is linked to an In Progress Issue and its acceptance criteria are satisfied, call issue.request_closure with the current run_id and revision. Otherwise leave it In Progress. Stop itself never completes or advances an Issue.",
        );
    }

    if (!std.mem.eql(u8, event_type, "started")) return null;
    if (!std.mem.eql(u8, hook_event_name, "UserPromptSubmit") and
        !std.mem.eql(u8, hook_event_name, "SubagentStart")) return null;

    const StartResponse = struct {
        run: ?struct {
            run_id: []const u8,
            revision: i64,
        },
    };
    const parsed = try std.json.parseFromSlice(StartResponse, allocator, response_json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const current_run = parsed.value.run orelse return null;
    if (!isSafeRunId(current_run.run_id) or current_run.revision < 1) return null;

    const context = if (std.mem.eql(u8, hook_event_name, "UserPromptSubmit"))
        try std.fmt.allocPrint(
            allocator,
            "Clumsies current root AgentRun: run_id={s}, revision={d}. Decide semantically whether this prompt continues an existing native Issue, creates a new durable Issue, or should not become an Issue; never infer that from text matching. Use issue.list to inspect existing Issues and issue.create to capture a new one. Call issue.start with this run_id and revision only when the Issue is the active line of work. Capture unrelated follow-up work with issue.create but do not call issue.start, so it remains Todo. Before finishing, call issue.request_closure only when the linked Issue's acceptance criteria are satisfied; otherwise leave it In Progress. AgentRun Stop never advances, approves, or closes an Issue.",
            .{ current_run.run_id, current_run.revision },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "Clumsies current subagent AgentRun: run_id={s}, revision={d}. Call issue.start only when this subagent is explicitly working an existing native Issue. Subagents must not request Issue closure; report findings to the root Agent. AgentRun Stop never advances or closes an Issue.",
            .{ current_run.run_id, current_run.revision },
        );
    defer allocator.free(context);

    return try additionalContextJsonAlloc(allocator, hook_event_name, context);
}

fn additionalContextJsonAlloc(
    allocator: std.mem.Allocator,
    hook_event_name: []const u8,
    context: []const u8,
) ![]u8 {
    const HookOutput = struct {
        hookSpecificOutput: struct {
            hookEventName: []const u8,
            additionalContext: []const u8,
        },
    };
    return try std.json.Stringify.valueAlloc(allocator, HookOutput{
        .hookSpecificOutput = .{
            .hookEventName = hook_event_name,
            .additionalContext = context,
        },
    }, .{});
}

fn claudeStopDecisionJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    const StopOutput = struct {
        decision: []const u8,
        reason: []const u8,
    };
    return try std.json.Stringify.valueAlloc(allocator, StopOutput{
        .decision = "block",
        .reason = "Before stopping, make the explicit semantic Issue decision now. If the current root task is linked to an In Progress Issue and its acceptance criteria are satisfied, call issue.request_closure with the current run_id and revision. If it is not satisfied, leave it In Progress. If you already made the appropriate decision, stop again without another mutation. Stop itself never completes or advances an Issue.",
    }, .{});
}

fn isSafeRunId(value: []const u8) bool {
    const prefix = "arun_";
    if (!std.mem.startsWith(u8, value, prefix)) return false;
    const suffix = value[prefix.len..];
    if (suffix.len != 32) return false;
    for (suffix) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn rootRunKeyAlloc(
    allocator: std.mem.Allocator,
    host: Host,
    object: std.json.ObjectMap,
) ![]const u8 {
    const host_id = switch (host) {
        .codex => stringField(object, "turn_id"),
        .claude_code => stringField(object, "prompt_id"),
    } orelse return error.InvalidHookPayload;
    if (host_id.len == 0) return error.InvalidHookPayload;
    const bounded_id = try boundedIdentifierAlloc(allocator, host_id);
    return boundedRunKeyAlloc(allocator, "root", &.{bounded_id});
}

fn explicitRootRunKeyAlloc(
    allocator: std.mem.Allocator,
    host: Host,
    object: std.json.ObjectMap,
) !?[]const u8 {
    const host_id = switch (host) {
        .codex => stringField(object, "turn_id"),
        .claude_code => stringField(object, "prompt_id"),
    } orelse return null;
    if (host_id.len == 0) return null;
    const bounded_id = try boundedIdentifierAlloc(allocator, host_id);
    return try boundedRunKeyAlloc(allocator, "root", &.{bounded_id});
}

fn subagentRunKeyAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    session_id: []const u8,
) ![]const u8 {
    const agent_id_raw = stringField(object, "agent_id") orelse return error.InvalidHookPayload;
    if (agent_id_raw.len == 0) return error.InvalidHookPayload;
    const agent_id = try boundedIdentifierAlloc(allocator, agent_id_raw);
    return boundedRunKeyAlloc(allocator, "subagent", &.{ session_id, agent_id });
}

fn boundedIdentifierAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len <= MAX_HOST_ID_BYTES) return try allocator.dupe(u8, raw);
    const digest = try util_hash.sha256HexAlloc(allocator, raw);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{digest});
}

fn boundedRunKeyAlloc(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    parts: []const []const u8,
) ![]const u8 {
    var material: std.ArrayList(u8) = .empty;
    defer material.deinit(allocator);
    try material.appendSlice(allocator, prefix);
    for (parts) |part| {
        try material.append(allocator, ':');
        try material.appendSlice(allocator, part);
    }
    if (material.items.len <= MAX_HOST_RUN_KEY_BYTES) {
        return try allocator.dupe(u8, material.items);
    }
    const digest = try util_hash.sha256HexAlloc(allocator, material.items);
    return std.fmt.allocPrint(allocator, "{s}:sha256:{s}", .{ prefix, digest });
}

fn eventIdAlloc(
    allocator: std.mem.Allocator,
    host: []const u8,
    session_id: []const u8,
    event_name: []const u8,
    host_run_key: ?[]const u8,
) ![]const u8 {
    const material = try std.mem.concat(allocator, u8, &.{
        host,
        "\x1f",
        session_id,
        "\x1f",
        event_name,
        "\x1f",
        host_run_key orelse "session",
    });
    const digest = try util_hash.sha256HexAlloc(allocator, material);
    return std.fmt.allocPrint(allocator, "hook_{s}", .{digest});
}

fn boundedWorkspacePath(value: ?[]const u8) ?[]const u8 {
    const path = value orelse return null;
    if (path.len == 0 or path.len > std.fs.max_path_bytes) return null;
    return path;
}

fn boundedDisplayLabel(value: ?[]const u8) ?[]const u8 {
    const label = value orelse return null;
    if (label.len == 0 or !std.unicode.utf8ValidateSlice(label)) return null;
    var end = @min(label.len, MAX_DISPLAY_LABEL_BYTES);
    while (end > 0 and !std.unicode.utf8ValidateSlice(label[0..end])) : (end -= 1) {}
    if (end == 0) return null;
    return label[0..end];
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn normalizeForTest(
    allocator: std.mem.Allocator,
    host: Host,
    raw: []const u8,
) !NormalizedHookEvent {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
    });
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidHookPayload,
    };
    return normalizeHookEvent(allocator, host, object);
}

test "normalizes Codex root and child lifecycle without inferring Issue state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const started = try normalizeForTest(allocator, .codex,
        \\{"session_id":"thr_1","turn_id":"turn_7","cwd":"/tmp/workspace","hook_event_name":"UserPromptSubmit","prompt":"Please implement issues/open/003_issue_board.md","transcript_path":"/private/transcript","model":"gpt-5.6"}
    );
    try std.testing.expectEqualStrings("codex", started.host);
    try std.testing.expectEqualStrings("root:turn_7", started.host_run_key.?);
    try std.testing.expectEqualStrings("started", started.event_type);
    try std.testing.expect(started.issue_key == null);
    try std.testing.expect(started.display_label == null);

    const child = try normalizeForTest(allocator, .codex,
        \\{"session_id":"thr_1","turn_id":"turn_7","cwd":"/tmp/workspace","hook_event_name":"SubagentStop","agent_id":"agent_4","agent_type":"reviewer","last_assistant_message":"sensitive final text"}
    );
    try std.testing.expectEqualStrings("subagent:thr_1:agent_4", child.host_run_key.?);
    try std.testing.expectEqualStrings("root:turn_7", child.parent_host_run_key.?);
    try std.testing.expectEqualStrings("subagent", child.kind.?);
    try std.testing.expect(child.outcome == null);
    try std.testing.expectEqualStrings("reviewer", child.display_label.?);
}

test "normalizes Claude prompt ids failures and session cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stopped = try normalizeForTest(allocator, .claude_code,
        \\{"session_id":"session_1","prompt_id":"prompt_9","cwd":"/tmp/workspace","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"do not store"}
    );
    try std.testing.expectEqualStrings("claude-code", stopped.host);
    try std.testing.expectEqualStrings("root:prompt_9", stopped.host_run_key.?);
    try std.testing.expect(stopped.outcome == null);
    try std.testing.expect(!stopped.stop_hook_active);

    const failed = try normalizeForTest(allocator, .claude_code,
        \\{"session_id":"session_1","prompt_id":"prompt_10","hook_event_name":"StopFailure","error":"rate_limit","error_details":"do not store"}
    );
    try std.testing.expectEqualStrings("failed", failed.outcome.?);
    try std.testing.expect(failed.display_label == null);

    const ended = try normalizeForTest(allocator, .claude_code,
        \\{"session_id":"session_1","hook_event_name":"SessionEnd","reason":"other"}
    );
    try std.testing.expectEqualStrings("session_ended", ended.event_type);
    try std.testing.expect(ended.host_run_key == null);
    try std.testing.expect(ended.kind == null);
    try std.testing.expect(ended.parent_host_run_key == null);
    try std.testing.expectEqualStrings("unknown", ended.outcome.?);

    try std.testing.expectError(
        error.InvalidHookPayload,
        normalizeForTest(allocator, .claude_code,
            \\{"session_id":"session_1","hook_event_name":"UserPromptSubmit","prompt":"ISSUE-003"}
        ),
    );
}

test "start hook context exposes only the current run identity and revision" {
    const response =
        \\{"run":{"run_id":"arun_0123456789abcdef0123456789abcdef","revision":7,"project_id":"secret-project","host_run_key":"secret-turn","summary":"secret-summary"},"affected_runs":[],"duplicate":false}
    ;
    const output = (try hookContextJsonAlloc(
        std.testing.allocator,
        .codex,
        "UserPromptSubmit",
        "started",
        response,
    )).?;
    defer std.testing.allocator.free(output);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    const specific = parsed.value.object.get("hookSpecificOutput").?.object;
    try std.testing.expectEqualStrings(
        "UserPromptSubmit",
        specific.get("hookEventName").?.string,
    );
    const context = specific.get("additionalContext").?.string;
    try std.testing.expect(std.mem.indexOf(u8, context, "arun_0123456789abcdef0123456789abcdef") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "revision=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "issue.start") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "issue.request_closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "Decide semantically") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "secret-project") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "secret-turn") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "secret-summary") == null);
}

test "subagent start receives run context and Codex Stop receives semantic reminder" {
    const response =
        \\{"run":{"run_id":"arun_fedcba9876543210fedcba9876543210","revision":2},"affected_runs":[],"duplicate":false}
    ;
    const output = (try hookContextJsonAlloc(
        std.testing.allocator,
        .codex,
        "SubagentStart",
        "started",
        response,
    )).?;
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"hookEventName\":\"SubagentStart\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "revision=2") != null);

    const stop_output = (try hookContextJsonAlloc(
        std.testing.allocator,
        .codex,
        "Stop",
        "ended",
        response,
    )).?;
    defer std.testing.allocator.free(stop_output);
    try std.testing.expect(std.mem.indexOf(u8, stop_output, "issue.request_closure") != null);
    try std.testing.expect((try hookContextJsonAlloc(std.testing.allocator, .codex, "UserPromptSubmit", "started",
        \\{"run":{"run_id":"not-a-daemon-run","revision":1}}
    )) == null);
}

test "Claude Stop decision blocks once and explains semantic closure" {
    const output = try claudeStopDecisionJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(output);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("block", parsed.value.object.get("decision").?.string);
    const reason = parsed.value.object.get("reason").?.string;
    try std.testing.expect(std.mem.indexOf(u8, reason, "issue.request_closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason, "Stop itself never") != null);
}

test "private command accepts only the two documented host flags" {
    try std.testing.expectEqual(Host.codex, parseHost(&.{ "--host", "codex" }).?);
    try std.testing.expectEqual(Host.claude_code, parseHost(&.{ "--host", "claude-code" }).?);
    try std.testing.expect(parseHost(&.{ "--host", "claude_code" }) == null);
    try std.testing.expect(parseHost(&.{"codex"}) == null);
}
