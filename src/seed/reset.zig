//! Database reset for development: drops and recreates all seed fixtures, providing a clean
//! slate for testing.
const std = @import("std");
const pg = @import("pg");
const data = @import("data.zig");
const util_hash = @import("clumsies_lib").util.hash;
const password = @import("password.zig");
const workspace_setup = @import("workspace_setup.zig");

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
        \\TRUNCATE orgs, users, tokens, workspaces, workspace_members, rules, workspace_rules,
        \\  workspace_context, context_prs, context_pr_operations, context_pr_comments,
        \\  bundles, bundle_rules, rule_prs, rule_pr_operations, rule_pr_comments,
        \\  attestation_events, artifact_manifest, rule_history
        \\CASCADE
    , .{}) catch |err| {
        log.err("truncate failed: {}", .{err});
        return err;
    };

    try seedOrg(conn);
    try seedUsers(conn);
    try seedRules(conn);
    try seedWorkspaces(conn);
    try seedWorkspaceMembers(conn);
    try seedWorkspaceRules(conn);
    try seedContexts(conn);
    try seedHistoricalAttestation(conn);
    try ensureLocalWorkspaceState();

    log.info("seed fixtures rebuilt", .{});
}

fn clearSeedLocalState() void {
    for (data.WORKSPACES) |workspace| {
        workspace_setup.deleteWorkspaceFiles(workspace.id, workspace.name);
    }
}

fn ensureLocalWorkspaceState() !void {
    for (data.WORKSPACES) |workspace| {
        try workspace_setup.ensureWorkspaceFiles(workspace.id, workspace.name);
    }
}

fn seedOrg(conn: *pg.Conn) !void {
    _ = try conn.exec(
        "INSERT INTO orgs (org_id, name) VALUES ($1::uuid, $2)",
        .{ data.ORG_ID, data.ORG_NAME },
    );

    _ = try conn.exec(
        "INSERT INTO artifact_manifest (org_id, revision) VALUES ($1::uuid, $2)",
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

fn seedRules(conn: *pg.Conn) !void {
    for (data.RULES) |rule| {
        const content_hash = util_hash.contentHash(rule.content);
        _ = try conn.exec(
            \\INSERT INTO rules (rule_id, org_id, path, content, content_hash)
            \\VALUES ($1, $2::uuid, $3, $4, $5)
        , .{ rule.id, data.ORG_ID, rule.path, rule.content, content_hash[0..] });
    }
}

fn seedWorkspaces(conn: *pg.Conn) !void {
    for (data.WORKSPACES) |workspace| {
        _ = try conn.exec(
            \\INSERT INTO workspaces (ws_id, org_id, name, description, revision)
            \\VALUES ($1, $2::uuid, $3, $4, $5)
        , .{ workspace.id, data.ORG_ID, workspace.name, workspace.description, data.FIXTURE_VERSION });
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

fn seedWorkspaceRules(conn: *pg.Conn) !void {
    for (data.WORKSPACE_RULES) |binding| {
        _ = try conn.exec(
            \\INSERT INTO workspace_rules (ws_id, rule_id)
            \\VALUES ($1, $2)
        , .{ binding.ws_id, binding.rule_id });
    }
}

fn seedContexts(conn: *pg.Conn) !void {
    for (data.CONTEXTS) |context| {
        const content_hash = util_hash.contentHash(context.content);
        _ = try conn.exec(
            \\INSERT INTO workspace_context (context_id, ws_id, path, content, content_hash, author)
            \\VALUES ($1, $2, $3, $4, $5, $6)
        , .{ context.id, context.ws_id, context.path, context.content, content_hash[0..], context.author });
    }
}

fn seedHistoricalAttestation(conn: *pg.Conn) !void {
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
                    const rule = data.ruleById(refer.rule_id) orelse continue;
                    const rule_hash = util_hash.contentHash(rule.content);
                    try insertHistoricalAttestationEvent(conn, scenario.user_id, .{
                        .ws_id = scenario.ws_id,
                        .session_id = session_id,
                        .event_id = @as(i64, @intCast(refer_idx)),
                        .type = "refer",
                        .timestamp = base_ts + @as(i64, @intCast(refer_idx)),
                        .rule_id = rule.id,
                        .rule_hash = rule_hash[0..],
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

const HistoricalAttestationEvent = struct {
    ws_id: []const u8,
    session_id: []const u8,
    event_id: i64,
    type: []const u8,
    timestamp: i64,
    rule_id: ?[]const u8 = null,
    rule_hash: ?[]const u8 = null,
    constraint_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

fn insertHistoricalAttestationEvent(conn: *pg.Conn, user_id: []const u8, event: HistoricalAttestationEvent) !void {
    _ = try conn.exec(
        \\INSERT INTO attestation_events (user_id, ws_id, session_id, event_id, type, timestamp,
        \\  rule_id, rule_hash, constraint_id, reason, content, content_hash)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, NULL)
        \\ON CONFLICT (ws_id, session_id, event_id) DO NOTHING
    , .{
        user_id,
        event.ws_id,
        event.session_id,
        event.event_id,
        event.type,
        event.timestamp,
        event.rule_id,
        event.rule_hash,
        event.constraint_id,
        event.reason,
    });
}
