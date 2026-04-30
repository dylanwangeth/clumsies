//! PostgreSQL connection pool initialization for the Hub server.
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

pub const ContentFormatError = error{ MissingHeading, MissingDescription, MissingSection };

/// Validate that markdown content follows the required structure:
/// H1 title, description paragraph(s) between H1 and first H2, at least one H2 section.
pub fn validateContentFormat(content: []const u8) ContentFormatError!void {
    var lines = std.mem.splitSequence(u8, content, "\n");
    var found_heading = false;
    var found_description = false;
    var found_section = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "---")) continue;
        if (trimmed.len >= 2 and trimmed[0] == '#' and trimmed[1] == '#') {
            found_section = true;
            break;
        }
        if (!found_heading) {
            if (trimmed[0] != '#') return error.MissingHeading;
            found_heading = true;
        } else {
            found_description = true;
        }
    }
    if (!found_heading) return error.MissingHeading;
    if (!found_description) return error.MissingDescription;
    if (!found_section) return error.MissingSection;
}

/// Extract the description from markdown content: all text between the H1
/// heading and the first H2 section, trimmed of leading/trailing whitespace.
pub fn extractDescription(content: []const u8) []const u8 {
    var lines = std.mem.splitSequence(u8, content, "\n");
    var past_heading = false;
    var start: usize = 0;
    var end: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (!past_heading) {
            if (trimmed.len > 0 and trimmed[0] == '#') {
                past_heading = true;
            }
            continue;
        }

        if (trimmed.len >= 2 and trimmed[0] == '#' and trimmed[1] == '#') break;
        if (std.mem.eql(u8, trimmed, "---")) continue;
        if (trimmed.len == 0) {
            if (start > 0 and end > start) continue;
            continue;
        }

        if (start == 0) {
            start = @intFromPtr(line.ptr) - @intFromPtr(content.ptr);
        }
        end = @intFromPtr(line.ptr) + line.len - @intFromPtr(content.ptr);
    }

    if (end > start) return content[start..end];
    return "";
}

pub fn bootstrap(pool: *Pool) !void {
    const alloc = std.heap.page_allocator;
    const log = std.log.scoped(.bootstrap);

    const conn = try pool.acquire();
    defer conn.release();

    // Only bootstrap if no users exist
    var count_row = conn.row("SELECT count(*) FROM users", .{}) catch return;
    if (count_row) |*cr| {
        const count = cr.get(i64, 0) catch 0;
        cr.deinit() catch {};
        if (count > 0) return;
    }

    const username_owned = std.process.getEnvVarOwned(alloc, "HUB_BOOTSTRAP_USERNAME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            log.warn("HUB_BOOTSTRAP_USERNAME missing; defaulting to 'admin'", .{});
            break :blk null;
        },
        else => return err,
    };
    defer if (username_owned) |value| alloc.free(value);
    const username = username_owned orelse "admin";

    const password_owned = std.process.getEnvVarOwned(alloc, "HUB_BOOTSTRAP_PASSWORD") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            log.warn("HUB_BOOTSTRAP_PASSWORD missing; defaulting to 'admin'", .{});
            break :blk null;
        },
        else => return err,
    };
    defer if (password_owned) |value| alloc.free(value);
    const password = password_owned orelse "admin";

    const org_name_owned = std.process.getEnvVarOwned(alloc, "HUB_BOOTSTRAP_ORG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (org_name_owned) |value| alloc.free(value);
    const org_name = org_name_owned orelse "default";

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
    \\CREATE TABLE IF NOT EXISTS rules (
    \\    rule_id TEXT PRIMARY KEY,
    \\    org_id UUID NOT NULL REFERENCES orgs(org_id),
    \\    path TEXT NOT NULL,
    \\    content TEXT NOT NULL DEFAULT '',
    \\    content_hash TEXT NOT NULL DEFAULT '',
    \\    description TEXT NOT NULL DEFAULT '',
    \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    UNIQUE(org_id, path)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS workspace_rules (
    \\    ws_id TEXT NOT NULL REFERENCES workspaces(ws_id),
    \\    rule_id TEXT NOT NULL REFERENCES rules(rule_id),
    \\    PRIMARY KEY (ws_id, rule_id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS context_files (
    \\    context_id TEXT PRIMARY KEY,
    \\    ws_id TEXT NOT NULL REFERENCES workspaces(ws_id) ON DELETE CASCADE,
    \\    path TEXT NOT NULL,
    \\    content TEXT NOT NULL,
    \\    content_hash TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    author TEXT NOT NULL,
    \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    UNIQUE(ws_id, path)
    \\);
    \\CREATE INDEX IF NOT EXISTS context_files_ws_idx
    \\    ON context_files(ws_id);
    \\
    \\CREATE TABLE IF NOT EXISTS context_prs (
    \\    pr_id TEXT PRIMARY KEY,
    \\    ws_id TEXT NOT NULL REFERENCES workspaces(ws_id) ON DELETE CASCADE,
    \\    author TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    status TEXT NOT NULL DEFAULT 'open'
    \\        CHECK (status IN ('open', 'merged', 'rejected')),
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS context_pr_operations (
    \\    pr_id TEXT NOT NULL REFERENCES context_prs(pr_id) ON DELETE CASCADE,
    \\    op_index INTEGER NOT NULL,
    \\    type TEXT NOT NULL CHECK (type IN ('modify', 'rename', 'create', 'delete')),
    \\    context_id TEXT,
    \\    base_hash TEXT,
    \\    content TEXT,
    \\    path TEXT,
    \\    PRIMARY KEY (pr_id, op_index)
    \\);
    \\CREATE INDEX IF NOT EXISTS context_pr_operations_context_id_idx
    \\    ON context_pr_operations(context_id);
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
    \\CREATE TABLE IF NOT EXISTS bundle_rules (
    \\    bundle_id TEXT NOT NULL REFERENCES bundles(bundle_id),
    \\    rule_id TEXT NOT NULL REFERENCES rules(rule_id),
    \\    PRIMARY KEY (bundle_id, rule_id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS rule_prs (
    \\    pr_id TEXT PRIMARY KEY,
    \\    org_id UUID NOT NULL REFERENCES orgs(org_id),
    \\    author_id TEXT NOT NULL REFERENCES users(user_id),
    \\    description TEXT NOT NULL DEFAULT '',
    \\    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'accepted', 'rejected')),
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS rule_pr_operations (
    \\    pr_id TEXT NOT NULL REFERENCES rule_prs(pr_id) ON DELETE CASCADE,
    \\    op_index INTEGER NOT NULL,
    \\    type TEXT NOT NULL CHECK (type IN ('modify', 'rename', 'create', 'delete')),
    \\    rule_id TEXT,
    \\    base_hash TEXT,
    \\    content TEXT,
    \\    path TEXT,
    \\    PRIMARY KEY (pr_id, op_index)
    \\);
    \\CREATE INDEX IF NOT EXISTS rule_pr_operations_rule_id_idx
    \\    ON rule_pr_operations(rule_id);
    \\
    \\CREATE TABLE IF NOT EXISTS rule_pr_comments (
    \\    comment_id TEXT PRIMARY KEY,
    \\    pr_id TEXT NOT NULL REFERENCES rule_prs(pr_id),
    \\    author_id TEXT NOT NULL REFERENCES users(user_id),
    \\    body TEXT NOT NULL,
    \\    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS attestation_events (
    \\    user_id TEXT REFERENCES users(user_id),
    \\    ws_id TEXT NOT NULL,
    \\    session_id TEXT NOT NULL,
    \\    event_id BIGINT NOT NULL,
    \\    type TEXT NOT NULL,
    \\    timestamp BIGINT NOT NULL,
    \\    rule_id TEXT,
    \\    rule_hash TEXT,
    \\    constraint_id TEXT,
    \\    reason TEXT,
    \\    content TEXT,
    \\    content_hash TEXT,
    \\    model TEXT,
    \\    PRIMARY KEY (ws_id, session_id, event_id)
    \\);
    \\ALTER TABLE attestation_events
    \\    ADD COLUMN IF NOT EXISTS user_id TEXT REFERENCES users(user_id);
    \\ALTER TABLE attestation_events
    \\    DROP COLUMN IF EXISTS override_base_hash;
    \\ALTER TABLE attestation_events
    \\    ADD COLUMN IF NOT EXISTS model TEXT;
    \\CREATE INDEX IF NOT EXISTS attestation_events_user_id_idx
    \\    ON attestation_events(user_id);
    \\CREATE INDEX IF NOT EXISTS attestation_events_ws_ts_idx
    \\    ON attestation_events(ws_id, timestamp DESC);
    \\CREATE INDEX IF NOT EXISTS attestation_events_rule_ts_idx
    \\    ON attestation_events(rule_id, timestamp DESC);
    \\
    \\CREATE TABLE IF NOT EXISTS library_manifest (
    \\    org_id UUID PRIMARY KEY REFERENCES orgs(org_id),
    \\    revision INTEGER NOT NULL DEFAULT 0
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS rule_history (
    \\    rule_id TEXT NOT NULL REFERENCES rules(rule_id),
    \\    content_hash TEXT NOT NULL,
    \\    path TEXT NOT NULL DEFAULT '',
    \\    content TEXT NOT NULL DEFAULT '',
    \\    merged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    \\    pr_id TEXT,
    \\    PRIMARY KEY (rule_id, content_hash)
    \\);
;

test "validateContentFormat accepts valid markdown" {
    const valid = "# Title\n\nDescription text.\n\n## Section\n\n- Item";
    try validateContentFormat(valid);
}

test "validateContentFormat rejects missing heading" {
    const no_h1 = "No heading here\n\n## Section\n\n- Item";
    try std.testing.expectError(error.MissingHeading, validateContentFormat(no_h1));
}

test "validateContentFormat rejects missing description" {
    const no_desc = "# Title\n\n## Section\n\n- Item";
    try std.testing.expectError(error.MissingDescription, validateContentFormat(no_desc));
}

test "validateContentFormat rejects missing section" {
    const no_h2 = "# Title\n\nDescription.\n";
    try std.testing.expectError(error.MissingSection, validateContentFormat(no_h2));
}

test "validateContentFormat rejects H2-only file" {
    const h2_only = "## Not a title\n\n## Section\n\n- Item";
    try std.testing.expectError(error.MissingHeading, validateContentFormat(h2_only));
}

test "extractDescription returns text between H1 and H2" {
    const content = "# Title\n\nFirst paragraph.\n\nSecond line.\n\n## Section\n\n- Item";
    const desc = extractDescription(content);
    try std.testing.expectEqualStrings("First paragraph.\n\nSecond line.", desc);
}

test "extractDescription returns empty for no content between H1 and H2" {
    const content = "# Title\n\n## Section\n\n- Item";
    const desc = extractDescription(content);
    try std.testing.expectEqualStrings("", desc);
}

test "extractDescription skips front matter separators" {
    const content = "# Title\n\n---\n\nDescription here.\n\n## Section\n\n- Item";
    const desc = extractDescription(content);
    try std.testing.expectEqualStrings("Description here.", desc);
}
