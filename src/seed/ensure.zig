//! Ensures seed prerequisites exist: database tables, workspace directories, and initial state
//! required before the pump can generate synthetic attestation events.
const std = @import("std");
const pg = @import("pg");
const bcrypt = std.crypto.pwhash.bcrypt;
const data = @import("data.zig");
const workspace_setup = @import("workspace_setup.zig");
const reset = @import("reset.zig");

const log = std.log.scoped(.seed);

pub fn run(pool: *pg.Pool) !void {
    const conn = try pool.acquire();
    defer conn.release();

    log.info("checking seed fixtures...", .{});

    if (!try fixturesHealthy(conn)) {
        log.warn("seed fixtures missing or stale; rebuilding seed-owned state", .{});
        try reset.rebuild(conn);
        return;
    }

    try ensureLocalWorkspaceState();
    log.info("seed fixtures ready", .{});
}

fn fixturesHealthy(conn: *pg.Conn) !bool {
    if (!try stringColumnMatches(
        conn,
        "SELECT name FROM orgs WHERE org_id = $1::uuid",
        .{data.ORG_ID},
        data.ORG_NAME,
    )) return false;

    if (!try intColumnMatches(
        conn,
        "SELECT revision FROM library_manifest WHERE org_id = $1::uuid",
        .{data.ORG_ID},
        data.FIXTURE_VERSION,
    )) return false;

    for (data.USERS) |user| {
        if (!try userHealthy(conn, user)) return false;
    }

    for (data.PROMPTS) |rule| {
        if (!try stringColumnMatches(
            conn,
            "SELECT path FROM rules WHERE rule_id = $1",
            .{rule.id},
            rule.path,
        )) return false;
    }

    for (data.WORKSPACES) |workspace| {
        if (!try stringColumnMatches(
            conn,
            "SELECT name FROM workspaces WHERE ws_id = $1",
            .{workspace.id},
            workspace.name,
        )) return false;
    }

    for (data.WORKSPACE_MEMBERS) |membership| {
        if (!try exists(
            conn,
            "SELECT 1 FROM workspace_members WHERE ws_id = $1 AND user_id = $2 AND role = $3",
            .{ membership.ws_id, membership.user_id, membership.role },
        )) return false;
    }

    for (data.WORKSPACE_PROMPTS) |binding| {
        if (!try exists(
            conn,
            "SELECT 1 FROM workspace_rules WHERE ws_id = $1 AND rule_id = $2",
            .{ binding.ws_id, binding.rule_id },
        )) return false;
    }

    for (data.CONTEXTS) |context| {
        if (!try stringColumnMatches(
            conn,
            "SELECT path FROM context_files WHERE context_id = $1",
            .{context.id},
            context.path,
        )) return false;
    }

    return true;
}

fn userHealthy(conn: *pg.Conn, user: data.UserFixture) !bool {
    var row = try conn.row(
        "SELECT username, role, status, password_hash FROM users WHERE user_id = $1",
        .{user.id},
    ) orelse return false;
    defer row.deinit() catch {};

    const username = row.get([]const u8, 0) catch return false;
    const role = row.get([]const u8, 1) catch return false;
    const status = row.get([]const u8, 2) catch return false;
    const password_hash = row.get([]const u8, 3) catch return false;

    if (!std.mem.eql(u8, username, user.username)) return false;
    if (!std.mem.eql(u8, role, user.role)) return false;
    if (!std.mem.eql(u8, status, user.status)) return false;

    bcrypt.strVerify(password_hash, data.SEED_PASSWORD, .{
        .silently_truncate_password = false,
    }) catch return false;

    return true;
}

fn ensureLocalWorkspaceState() !void {
    for (data.WORKSPACES) |workspace| {
        try workspace_setup.ensureWorkspaceFiles(workspace.id);
    }
}

fn exists(conn: *pg.Conn, query: []const u8, args: anytype) !bool {
    var row = try conn.row(query, args);
    if (row) |*r| {
        r.deinit() catch {};
        return true;
    }
    return false;
}

fn stringColumnMatches(conn: *pg.Conn, query: []const u8, args: anytype, expected: []const u8) !bool {
    var row = try conn.row(query, args) orelse return false;
    defer row.deinit() catch {};
    const actual = row.get([]const u8, 0) catch return false;
    return std.mem.eql(u8, actual, expected);
}

fn intColumnMatches(conn: *pg.Conn, query: []const u8, args: anytype, expected: i32) !bool {
    var row = try conn.row(query, args) orelse return false;
    defer row.deinit() catch {};
    const actual = row.get(i32, 0) catch return false;
    return actual == expected;
}
