const std = @import("std");
const pg = @import("pg");
const data = @import("data.zig");
const seed_hash = @import("hash.zig");
const password = @import("password.zig");

const log = std.log.scoped(.seed);

pub fn run(pool: *pg.Pool) !void {
    const conn = try pool.acquire();
    defer conn.release();

    log.info("ensuring base data for pump...", .{});

    var hash_buf: [128]u8 = undefined;
    const password_hash = try password.hashPassword(data.SEED_PASSWORD, &hash_buf);
    const prompt_hash = seed_hash.contentHash(data.BASE_PROMPT_CONTENT);
    var maintainer_id_buf: [64]u8 = undefined;
    var member_id_buf: [64]u8 = undefined;

    _ = conn.exec(
        "INSERT INTO orgs (org_id, name) VALUES ($1::uuid, $2) ON CONFLICT (org_id) DO NOTHING",
        .{ data.ORG_ID, data.ORG_NAME },
    ) catch |err| {
        logPgError(conn, "ensure org failed", err);
        return err;
    };

    _ = conn.exec(
        "INSERT INTO library_manifest (org_id, revision) VALUES ($1::uuid, 0) ON CONFLICT DO NOTHING",
        .{data.ORG_ID},
    ) catch |err| {
        logPgError(conn, "ensure library manifest failed", err);
        return err;
    };

    const maintainer_id = try ensureUser(
        conn,
        &maintainer_id_buf,
        data.BASE_MAINTAINER_ID,
        data.BASE_MAINTAINER_USERNAME,
        "maintainer",
        password_hash,
    );
    const member_id = try ensureUser(
        conn,
        &member_id_buf,
        data.BASE_MEMBER_ID,
        data.BASE_MEMBER_USERNAME,
        "member",
        password_hash,
    );

    _ = conn.exec(
        \\INSERT INTO prompts (prompt_id, org_id, path, content, content_hash)
        \\VALUES ($1, $2::uuid, $3, $4, $5)
        \\ON CONFLICT (prompt_id) DO NOTHING
    , .{
        data.BASE_PROMPT_ID,
        data.ORG_ID,
        data.BASE_PROMPT_PATH,
        data.BASE_PROMPT_CONTENT,
        prompt_hash[0..],
    }) catch |err| {
        logPgError(conn, "ensure prompt failed", err);
        return err;
    };

    _ = conn.exec(
        \\INSERT INTO workspaces (ws_id, org_id, name, revision)
        \\VALUES ($1, $2::uuid, $3, 1)
        \\ON CONFLICT (ws_id) DO NOTHING
    , .{
        data.BASE_WORKSPACE_ID,
        data.ORG_ID,
        data.BASE_WORKSPACE_NAME,
    }) catch |err| {
        logPgError(conn, "ensure workspace failed", err);
        return err;
    };

    _ = conn.exec(
        \\INSERT INTO workspace_members (ws_id, user_id, role)
        \\VALUES ($1, $2, 'admin')
        \\ON CONFLICT DO NOTHING
    , .{
        data.BASE_WORKSPACE_ID,
        maintainer_id,
    }) catch |err| {
        logPgError(conn, "ensure maintainer workspace membership failed", err);
        return err;
    };

    _ = conn.exec(
        \\INSERT INTO workspace_members (ws_id, user_id, role)
        \\VALUES ($1, $2, 'member')
        \\ON CONFLICT DO NOTHING
    , .{
        data.BASE_WORKSPACE_ID,
        member_id,
    }) catch |err| {
        logPgError(conn, "ensure member workspace membership failed", err);
        return err;
    };

    _ = conn.exec(
        \\INSERT INTO workspace_prompts (ws_id, prompt_id)
        \\VALUES ($1, $2)
        \\ON CONFLICT DO NOTHING
    , .{
        data.BASE_WORKSPACE_ID,
        data.BASE_PROMPT_ID,
    }) catch |err| {
        logPgError(conn, "ensure workspace prompt binding failed", err);
        return err;
    };
}

fn ensureUser(conn: *pg.Conn, id_buf: *[64]u8, preferred_id: []const u8, username: []const u8, role: []const u8, password_hash: []const u8) ![]const u8 {
    var row = conn.row("SELECT user_id FROM users WHERE username = $1", .{username}) catch |err| {
        logPgError(conn, "ensure user lookup failed", err);
        return err;
    };

    if (row) |*r| {
        const existing_id = r.get([]const u8, 0) catch |err| {
            r.deinit() catch {};
            return err;
        };
        const stable_id = copySlice(id_buf, existing_id);
        r.deinit() catch {};

        _ = conn.exec(
            \\UPDATE users
            \\SET org_id = $1::uuid,
            \\    username = $2,
            \\    password_hash = $3,
            \\    role = $4,
            \\    status = 'active'
            \\WHERE user_id = $5
        , .{ data.ORG_ID, username, password_hash, role, stable_id }) catch |err| {
            logPgError(conn, "ensure user update failed", err);
            return err;
        };
        return stable_id;
    }

    _ = conn.exec(
        \\INSERT INTO users (user_id, org_id, username, password_hash, role, status)
        \\VALUES ($1, $2::uuid, $3, $4, $5, 'active')
        \\ON CONFLICT (user_id) DO UPDATE
        \\SET org_id = EXCLUDED.org_id,
        \\    username = EXCLUDED.username,
        \\    password_hash = EXCLUDED.password_hash,
        \\    role = EXCLUDED.role,
        \\    status = EXCLUDED.status
    , .{ preferred_id, data.ORG_ID, username, password_hash, role }) catch |err| {
        logPgError(conn, "ensure user insert failed", err);
        return err;
    };

    return copySlice(id_buf, preferred_id);
}

fn copySlice(dest: *[64]u8, src: []const u8) []const u8 {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return dest[0..len];
}

fn logPgError(conn: *pg.Conn, msg: []const u8, err: anytype) void {
    log.err("{s}: {}", .{ msg, err });
    if (conn.err) |pg_err| {
        log.err("pg detail: {s}", .{pg_err.message});
    }
}
