const std = @import("std");
const pg = @import("pg");
const Config = @import("config.zig");
const bcrypt = std.crypto.pwhash.bcrypt;

pub const Pool = pg.Pool;

pub fn initPool(allocator: std.mem.Allocator, config: Config) !*Pool {
    return Pool.init(allocator, .{
        .size = 5,
        .connect = .{
            .host = config.db_host,
            .port = config.db_port,
        },
        .auth = .{
            .username = config.db_user,
            .database = config.db_name,
            .password = config.db_password,
            .timeout = 10_000,
        },
    });
}

pub fn migrate(pool: *Pool) !void {
    const conn = try pool.acquire();
    defer conn.release();

    _ = conn.exec(migration_sql, .{}) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.Writer.init(std.fs.File.stderr(), &buf);
        defer w.interface.flush() catch {};
        try w.interface.print("migration error: {}\n", .{err});
        if (conn.err) |pg_err| {
            try w.interface.print("pg: {s}\n", .{pg_err.message});
        }
        return err;
    };
}

pub fn bootstrap(pool: *Pool) !void {
    const alloc = std.heap.page_allocator;
    const username = std.process.getEnvVarOwned(alloc, "HUB_BOOTSTRAP_USERNAME") catch return;
    const password = std.process.getEnvVarOwned(alloc, "HUB_BOOTSTRAP_PASSWORD") catch return;
    const org_name = std.process.getEnvVarOwned(alloc, "HUB_BOOTSTRAP_ORG") catch "default";

    const conn = try pool.acquire();
    defer conn.release();

    // Only bootstrap if no users exist
    var count_row = conn.row("SELECT count(*) FROM users", .{}) catch return;
    if (count_row) |*cr| {
        const count = cr.get(i64, 0) catch 0;
        cr.deinit() catch {};
        if (count > 0) return;
    }

    const log = std.log.scoped(.bootstrap);

    // Create org
    _ = conn.exec(
        "INSERT INTO orgs (name) VALUES ($1) ON CONFLICT DO NOTHING",
        .{org_name},
    ) catch |err| {
        log.err("bootstrap org failed: {}", .{err});
        return;
    };

    // Get org_id — copy into stable buffer before row deinit
    var org_row = conn.row("SELECT org_id::text FROM orgs WHERE name = $1", .{org_name}) catch return;
    var org_id_buf: [64]u8 = undefined;
    const org_id: []const u8 = if (org_row) |*or_| blk: {
        const val = or_.get([]const u8, 0) catch {
            or_.deinit() catch {};
            return;
        };
        const len = @min(val.len, org_id_buf.len);
        @memcpy(org_id_buf[0..len], val[0..len]);
        or_.deinit() catch {};
        break :blk org_id_buf[0..len];
    } else return;

    // Hash password
    var hash_buf: [128]u8 = undefined;
    const password_hash = bcrypt.strHash(password, .{
        .params = .{ .rounds_log = 10, .silently_truncate_password = false },
        .encoding = .phc,
    }, &hash_buf) catch {
        log.err("bootstrap password hash failed", .{});
        return;
    };

    // Generate user_id
    var rand_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var uid_buf: [36]u8 = undefined;
    @memcpy(uid_buf[0..4], "usr-");
    const hex = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        uid_buf[4 + i * 2] = hex[byte >> 4];
        uid_buf[4 + i * 2 + 1] = hex[byte & 0x0f];
    }

    _ = conn.exec(
        \\INSERT INTO users (user_id, org_id, username, password_hash, role, status)
        \\VALUES ($1, $2::uuid, $3, $4, 'maintainer', 'active')
    , .{ @as([]const u8, &uid_buf), org_id, username, password_hash }) catch |err| {
        log.err("bootstrap user failed: {}", .{err});
        return;
    };

    // Create library manifest
    _ = conn.exec(
        "INSERT INTO library_manifest (org_id, revision) VALUES ($1::uuid, 0) ON CONFLICT DO NOTHING",
        .{org_id},
    ) catch {};

    log.info("bootstrapped org '{s}' with maintainer '{s}'", .{ org_name, username });
}

const migration_sql =
    \\CREATE TABLE IF NOT EXISTS orgs (
    \\    org_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    \\    name TEXT NOT NULL UNIQUE,
    \\    settings JSONB NOT NULL DEFAULT '{}',
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS users (
    \\    user_id TEXT PRIMARY KEY,
    \\    org_id UUID NOT NULL REFERENCES orgs(org_id),
    \\    username TEXT NOT NULL,
    \\    password_hash TEXT NOT NULL DEFAULT '',
    \\    role TEXT NOT NULL CHECK (role IN ('member', 'maintainer')),
    \\    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('invited', 'active')),
    \\    invite_token_hash TEXT,
    \\    invite_expires_at TIMESTAMPTZ,
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    UNIQUE(org_id, username),
    \\    UNIQUE(username)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS tokens (
    \\    token_hash TEXT PRIMARY KEY,
    \\    user_id TEXT NOT NULL REFERENCES users(user_id),
    \\    kind TEXT NOT NULL CHECK (kind IN ('access', 'refresh')),
    \\    scopes TEXT NOT NULL DEFAULT '',
    \\    expires_at TIMESTAMPTZ NOT NULL,
    \\    revoked BOOLEAN NOT NULL DEFAULT false,
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS workspaces (
    \\    ws_id TEXT PRIMARY KEY,
    \\    org_id UUID NOT NULL REFERENCES orgs(org_id),
    \\    name TEXT NOT NULL,
    \\    revision INTEGER NOT NULL DEFAULT 0,
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    UNIQUE(org_id, name)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS workspace_members (
    \\    ws_id TEXT NOT NULL REFERENCES workspaces(ws_id) ON DELETE CASCADE,
    \\    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    \\    role TEXT NOT NULL CHECK (role IN ('member', 'admin')),
    \\    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    PRIMARY KEY (ws_id, user_id)
    \\);
    \\CREATE INDEX IF NOT EXISTS workspace_members_user_id_idx
    \\    ON workspace_members(user_id);
    \\
    \\CREATE TABLE IF NOT EXISTS prompts (
    \\    prompt_id TEXT PRIMARY KEY,
    \\    org_id UUID NOT NULL REFERENCES orgs(org_id),
    \\    canonical_name TEXT NOT NULL,
    \\    kind TEXT NOT NULL CHECK (kind IN ('rule', 'workflow')),
    \\    content TEXT NOT NULL DEFAULT '',
    \\    content_hash TEXT NOT NULL DEFAULT '',
    \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    UNIQUE(org_id, canonical_name)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS workspace_prompts (
    \\    ws_id TEXT NOT NULL REFERENCES workspaces(ws_id),
    \\    prompt_id TEXT NOT NULL REFERENCES prompts(prompt_id),
    \\    PRIMARY KEY (ws_id, prompt_id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS context_branches (
    \\    ws_id TEXT NOT NULL REFERENCES workspaces(ws_id) ON DELETE CASCADE,
    \\    branch_name TEXT NOT NULL,
    \\    base_revision INTEGER NOT NULL DEFAULT 0,
    \\    revision INTEGER NOT NULL DEFAULT 0,
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    PRIMARY KEY (ws_id, branch_name)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS context_files (
    \\    ws_id TEXT NOT NULL,
    \\    branch_name TEXT NOT NULL,
    \\    path TEXT NOT NULL,
    \\    content TEXT NOT NULL,
    \\    content_hash TEXT NOT NULL,
    \\    author TEXT NOT NULL,
    \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    PRIMARY KEY (ws_id, branch_name, path),
    \\    FOREIGN KEY (ws_id, branch_name) REFERENCES context_branches(ws_id, branch_name) ON DELETE CASCADE
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS context_prs (
    \\    pr_id TEXT PRIMARY KEY,
    \\    ws_id TEXT NOT NULL REFERENCES workspaces(ws_id) ON DELETE CASCADE,
    \\    author TEXT NOT NULL,
    \\    branch_name TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    status TEXT NOT NULL DEFAULT 'open'
    \\        CHECK (status IN ('open', 'merged', 'closed', 'conflict')),
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS context_pr_files (
    \\    pr_id TEXT NOT NULL REFERENCES context_prs(pr_id) ON DELETE CASCADE,
    \\    path TEXT NOT NULL,
    \\    PRIMARY KEY (pr_id, path)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS context_pr_comments (
    \\    comment_id TEXT PRIMARY KEY,
    \\    pr_id TEXT NOT NULL REFERENCES context_prs(pr_id) ON DELETE CASCADE,
    \\    author TEXT NOT NULL,
    \\    body TEXT NOT NULL,
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS bundles (
    \\    bundle_id TEXT PRIMARY KEY,
    \\    org_id UUID NOT NULL REFERENCES orgs(org_id),
    \\    name TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    UNIQUE(org_id, name)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS bundle_prompts (
    \\    bundle_id TEXT NOT NULL REFERENCES bundles(bundle_id),
    \\    prompt_id TEXT NOT NULL REFERENCES prompts(prompt_id),
    \\    PRIMARY KEY (bundle_id, prompt_id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS prompt_prs (
    \\    pr_id TEXT PRIMARY KEY,
    \\    org_id UUID NOT NULL REFERENCES orgs(org_id),
    \\    prompt_id TEXT NOT NULL REFERENCES prompts(prompt_id),
    \\    author_id TEXT NOT NULL REFERENCES users(user_id),
    \\    base_hash TEXT NOT NULL,
    \\    content TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'accepted', 'rejected')),
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS prompt_pr_comments (
    \\    comment_id TEXT PRIMARY KEY,
    \\    pr_id TEXT NOT NULL REFERENCES prompt_prs(pr_id),
    \\    author_id TEXT NOT NULL REFERENCES users(user_id),
    \\    body TEXT NOT NULL,
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS trace_events (
    \\    ws_id TEXT NOT NULL,
    \\    session_id TEXT NOT NULL,
    \\    event_id BIGINT NOT NULL,
    \\    type TEXT NOT NULL,
    \\    timestamp BIGINT NOT NULL,
    \\    prompt_id TEXT,
    \\    prompt_hash TEXT,
    \\    constraint_id TEXT,
    \\    override_base_hash TEXT,
    \\    reason TEXT,
    \\    content TEXT,
    \\    content_hash TEXT,
    \\    PRIMARY KEY (ws_id, session_id, event_id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS library_manifest (
    \\    org_id UUID PRIMARY KEY REFERENCES orgs(org_id),
    \\    revision INTEGER NOT NULL DEFAULT 0
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS prompt_history (
    \\    prompt_id TEXT NOT NULL REFERENCES prompts(prompt_id),
    \\    content_hash TEXT NOT NULL,
    \\    content TEXT NOT NULL DEFAULT '',
    \\    merged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    pr_id TEXT,
    \\    PRIMARY KEY (prompt_id, content_hash)
    \\);
;
