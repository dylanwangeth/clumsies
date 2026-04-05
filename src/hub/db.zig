const std = @import("std");
const pg = @import("pg");
const Config = @import("config.zig");

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
    \\    password_hash TEXT NOT NULL,
    \\    role TEXT NOT NULL CHECK (role IN ('member', 'maintainer')),
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    UNIQUE(org_id, username)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS tokens (
    \\    token_hash TEXT PRIMARY KEY,
    \\    user_id TEXT NOT NULL REFERENCES users(user_id),
    \\    kind TEXT NOT NULL CHECK (kind IN ('access', 'refresh')),
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
    \\    ws_id TEXT NOT NULL REFERENCES workspaces(ws_id),
    \\    user_id TEXT NOT NULL REFERENCES users(user_id),
    \\    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    PRIMARY KEY (ws_id, user_id)
    \\);
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
    \\CREATE TABLE IF NOT EXISTS workspace_files (
    \\    ws_id TEXT NOT NULL REFERENCES workspaces(ws_id),
    \\    path TEXT NOT NULL,
    \\    content BYTEA NOT NULL DEFAULT '',
    \\    content_hash TEXT NOT NULL DEFAULT '',
    \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    PRIMARY KEY (ws_id, path)
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
    \\CREATE TABLE IF NOT EXISTS proposals (
    \\    proposal_id TEXT PRIMARY KEY,
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
    \\CREATE TABLE IF NOT EXISTS proposal_comments (
    \\    comment_id TEXT PRIMARY KEY,
    \\    proposal_id TEXT NOT NULL REFERENCES proposals(proposal_id),
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
    \\    merged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    proposal_id TEXT,
    \\    PRIMARY KEY (prompt_id, content_hash)
    \\);
;
