const std = @import("std");
const pg = @import("pg");
const data = @import("data.zig");
const seed_hash = @import("hash.zig");
const password = @import("password.zig");
const local_state = @import("local_state.zig");

const log = std.log.scoped(.seed);

pub fn run(pool: *pg.Pool) !void {
    const conn = try pool.acquire();
    defer conn.release();
    try rebuild(conn);
}

pub fn rebuild(conn: *pg.Conn) !void {
    log.info("rebuilding seed fixtures...", .{});

    clearSeedLocalState();

    _ = conn.exec(
        \\TRUNCATE orgs, users, tokens, workspaces, workspace_members, prompts, workspace_prompts,
        \\  context_files, context_prs, context_pr_operations, context_pr_comments,
        \\  bundles, bundle_prompts, prompt_prs, prompt_pr_operations, prompt_pr_comments,
        \\  trace_events, library_manifest, prompt_history
        \\CASCADE
    , .{}) catch |err| {
        log.err("truncate failed: {}", .{err});
        return err;
    };

    try seedOrg(conn);
    try seedUsers(conn);
    try seedPrompts(conn);
    try seedWorkspaces(conn);
    try seedWorkspaceMembers(conn);
    try seedWorkspacePrompts(conn);
    try seedContexts(conn);
    try seedHistoricalTrace(conn);
    try ensureLocalWorkspaceState();

    log.info("seed fixtures rebuilt", .{});
}

fn clearSeedLocalState() void {
    for (data.WORKSPACES) |workspace| {
        local_state.deleteWorkspaceFiles(workspace.id);
    }
}

fn ensureLocalWorkspaceState() !void {
    for (data.WORKSPACES) |workspace| {
        try local_state.ensureWorkspaceFiles(workspace.id);
    }
}

fn seedOrg(conn: *pg.Conn) !void {
    _ = try conn.exec(
        "INSERT INTO orgs (org_id, name) VALUES ($1::uuid, $2)",
        .{ data.ORG_ID, data.ORG_NAME },
    );

    _ = try conn.exec(
        "INSERT INTO library_manifest (org_id, revision) VALUES ($1::uuid, $2)",
        .{ data.ORG_ID, data.FIXTURE_VERSION },
    );
}

fn seedUsers(conn: *pg.Conn) !void {
    var hash_buf: [128]u8 = undefined;
    const password_hash = try password.hashPassword(data.SEED_PASSWORD, &hash_buf);

    for (data.USERS) |user| {
        _ = try conn.exec(
            \\INSERT INTO users (user_id, org_id, username, password_hash, role, status)
            \\VALUES ($1, $2::uuid, $3, $4, $5, $6)
        , .{ user.id, data.ORG_ID, user.username, password_hash, user.role, user.status });
    }
}

fn seedPrompts(conn: *pg.Conn) !void {
    for (data.PROMPTS) |prompt| {
        const content_hash = seed_hash.contentHash(prompt.content);
        _ = try conn.exec(
            \\INSERT INTO prompts (prompt_id, org_id, path, content, content_hash)
            \\VALUES ($1, $2::uuid, $3, $4, $5)
        , .{ prompt.id, data.ORG_ID, prompt.path, prompt.content, content_hash[0..] });
    }
}

fn seedWorkspaces(conn: *pg.Conn) !void {
    for (data.WORKSPACES) |workspace| {
        _ = try conn.exec(
            \\INSERT INTO workspaces (ws_id, org_id, name, revision)
            \\VALUES ($1, $2::uuid, $3, $4)
        , .{ workspace.id, data.ORG_ID, workspace.name, data.FIXTURE_VERSION });
    }
}

fn seedWorkspaceMembers(conn: *pg.Conn) !void {
    for (data.WORKSPACE_MEMBERS) |membership| {
        _ = try conn.exec(
            \\INSERT INTO workspace_members (ws_id, user_id, role)
            \\VALUES ($1, $2, $3)
        , .{ membership.ws_id, membership.user_id, membership.role });
    }
}

fn seedWorkspacePrompts(conn: *pg.Conn) !void {
    for (data.WORKSPACE_PROMPTS) |binding| {
        _ = try conn.exec(
            \\INSERT INTO workspace_prompts (ws_id, prompt_id)
            \\VALUES ($1, $2)
        , .{ binding.ws_id, binding.prompt_id });
    }
}

fn seedContexts(conn: *pg.Conn) !void {
    for (data.CONTEXTS) |context| {
        const content_hash = seed_hash.contentHash(context.content);
        _ = try conn.exec(
            \\INSERT INTO context_files (context_id, ws_id, path, content, content_hash, author)
            \\VALUES ($1, $2, $3, $4, $5, $6)
        , .{ context.id, context.ws_id, context.path, context.content, content_hash[0..], context.author });
    }
}

fn seedHistoricalTrace(conn: *pg.Conn) !void {
    const day_ms = std.time.ms_per_day;
    const hour_ms = std.time.ms_per_hour;
    const now_ms = std.time.milliTimestamp();

    for (0..14) |age_days| {
        for (data.PUMP_SCENARIOS, 0..) |scenario, scenario_idx| {
            const repeats = historicalRepeats(age_days, scenario_idx);
            for (0..repeats) |repeat_idx| {
                const base_ts = now_ms -
                    (@as(i64, @intCast(age_days + 1)) * day_ms) +
                    (@as(i64, @intCast(repeat_idx)) * hour_ms);
                var session_buf: [96]u8 = undefined;
                const session_id = std.fmt.bufPrint(
                    &session_buf,
                    "ses-seed-history-{d}-{d}-{d}",
                    .{ age_days, scenario_idx, repeat_idx },
                ) catch continue;

                for (scenario.refers, 0..) |refer, refer_idx| {
                    const prompt = data.promptById(refer.prompt_id) orelse continue;
                    const prompt_hash = seed_hash.contentHash(prompt.content);
                    try insertHistoricalTraceEvent(conn, scenario.user_id, .{
                        .ws_id = scenario.ws_id,
                        .session_id = session_id,
                        .event_id = @as(i64, @intCast(refer_idx)),
                        .type = "refer",
                        .timestamp = base_ts + @as(i64, @intCast(refer_idx)),
                        .prompt_id = prompt.id,
                        .prompt_hash = prompt_hash[0..],
                        .constraint_id = refer.constraint_id,
                        .reason = refer.reason,
                    });
                }
            }
        }
    }
}

fn historicalRepeats(age_days: usize, scenario_idx: usize) usize {
    return switch (scenario_idx) {
        0 => if (age_days < 7) 3 else 1, // trending up
        1 => if (age_days < 7) 1 else 3, // trending down
        2 => 2, // flat
        3 => if (age_days < 7) 2 else 0, // newly active
        4 => if (age_days < 7) 0 else 2, // recently cooled off
        else => 1,
    };
}

const HistoricalTraceEvent = struct {
    ws_id: []const u8,
    session_id: []const u8,
    event_id: i64,
    type: []const u8,
    timestamp: i64,
    prompt_id: ?[]const u8 = null,
    prompt_hash: ?[]const u8 = null,
    constraint_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

fn insertHistoricalTraceEvent(conn: *pg.Conn, user_id: []const u8, event: HistoricalTraceEvent) !void {
    _ = try conn.exec(
        \\INSERT INTO trace_events (user_id, ws_id, session_id, event_id, type, timestamp,
        \\  prompt_id, prompt_hash, constraint_id, override_base_hash, reason, content, content_hash)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NULL, $10, NULL, NULL)
        \\ON CONFLICT (ws_id, session_id, event_id) DO NOTHING
    , .{
        user_id,
        event.ws_id,
        event.session_id,
        event.event_id,
        event.type,
        event.timestamp,
        event.prompt_id,
        event.prompt_hash,
        event.constraint_id,
        event.reason,
    });
}
