//! Hub request authentication. Validates Bearer tokens, resolves the user and org membership,
//! and enforces token scope restrictions. Every API handler calls this to get verified user
//! context before processing the request.
const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");
const auth_api = @import("clumsies_lib").protocol.auth_api;
const Server = @import("server.zig");
const apiError = @import("api_error.zig").send;

const bcrypt = std.crypto.pwhash.bcrypt;
const MeResponse = auth_api.MeResponse;
const MeWorkspace = auth_api.MeWorkspace;
const log = std.log.scoped(.hub_auth);

pub const AuthUser = struct {
    user_id: []const u8,
    org_id: []const u8,
    username: []const u8,
    role: []const u8,
    scopes: []const u8,
};

const MEMBER_SCOPES = "artifact:read,workspace:read,workspace:write,attestation:write,stats:read,members:read,pr:read,pr:write";
const MAINTAINER_SCOPES = "artifact:read,artifact:write,bundle:write,workspace:read,workspace:write,attestation:write,stats:read,members:read,members:write,pr:read,pr:write,pr:merge";

pub fn requireScope(user: AuthUser, scope: []const u8, res: anytype) bool {
    if (std.mem.indexOf(u8, user.scopes, scope) != null) return true;
    apiError(res, 403, "FORBIDDEN", "token missing required scope") catch {};
    return false;
}

const LoginRequest = struct {
    username: []const u8,
    credential: []const u8,
    scopes: ?[]const u8 = null,
};

const RefreshRequest = struct {
    refresh_token: []const u8,
};

pub fn handleRevokeToken(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    // Revoke all tokens for this user
    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();
    _ = conn.exec("UPDATE tokens SET revoked = true WHERE user_id = $1", .{user.user_id}) catch {};
    try res.json(.{ .revoked = true }, .{});
}

pub fn handleLogin(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const client_ip = req.header("x-forwarded-for") orelse "unknown";
    if (!ctx.auth_rate_limiter.check(client_ip)) {
        res.status = 429;
        return apiError(res, 429, "TOO_MANY_REQUESTS", "rate limit exceeded");
    }

    const login = req.json(LoginRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT user_id, org_id, username, role, password_hash, status FROM users WHERE username = $1",
        .{login.username},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 401, "UNAUTHORIZED", "invalid credentials");
    };

    // Reject invited users with the same 401 to avoid username enumeration
    const status = try row.get([]const u8, 5);
    if (std.mem.eql(u8, status, "invited")) {
        row.deinit() catch {};
        return apiError(res, 401, "UNAUTHORIZED", "invalid credentials");
    }

    const stored_hash = try row.get([]const u8, 4);
    if (!verifyPassword(login.credential, stored_hash)) {
        row.deinit() catch {};
        return apiError(res, 401, "UNAUTHORIZED", "invalid credentials");
    }

    const user_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const role = try req.arena.dupe(u8, try row.get([]const u8, 3));
    row.deinit() catch {};

    // Determine scopes: use requested scopes if provided, otherwise default for role
    const default_scopes = if (std.mem.eql(u8, role, "maintainer")) MAINTAINER_SCOPES else MEMBER_SCOPES;
    const scopes = if (login.scopes) |requested| blk: {
        // Validate each requested scope is in the role's allowed set
        var it = std.mem.splitScalar(u8, requested, ',');
        while (it.next()) |s| {
            if (std.mem.indexOf(u8, default_scopes, s) == null) {
                return apiError(res, 400, "BAD_REQUEST", "requested scope not allowed for this role");
            }
        }
        break :blk requested;
    } else default_scopes;

    const access_token = generateToken(req.arena, conn, user_id, "access", scopes, ctx.config.token_ttl_seconds) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };
    const refresh_token = generateToken(req.arena, conn, user_id, "refresh", scopes, ctx.config.refresh_token_ttl_seconds) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };

    try res.json(.{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = ctx.config.token_ttl_seconds,
    }, .{});
}

pub fn handleRefresh(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const client_ip = req.header("x-forwarded-for") orelse "unknown";
    if (!ctx.auth_rate_limiter.check(client_ip)) {
        res.status = 429;
        return apiError(res, 429, "TOO_MANY_REQUESTS", "rate limit exceeded");
    }

    const body = req.json(RefreshRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    const token_hash = hashToken(body.refresh_token);

    var row = conn.row(
        \\SELECT t.user_id, t.scopes FROM tokens t
        \\WHERE t.token_hash = $1
        \\  AND t.kind = 'refresh'
        \\  AND t.revoked = false
        \\  AND t.expires_at > now()
    , .{@as([]const u8, &token_hash)}) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or expired refresh token");
    };

    const user_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const scopes = try req.arena.dupe(u8, try row.get([]const u8, 1));
    row.deinit() catch {};

    _ = conn.exec("UPDATE tokens SET revoked = true WHERE token_hash = $1", .{@as([]const u8, &token_hash)}) catch {};

    // Rotate both tokens: a refresh that only minted a new access
    // token left the client with a revoked refresh token and no way
    // to refresh again, forcing re-login after one hop. Issue a new
    // refresh token alongside the access token so clients can keep
    // rolling forward as long as they stay within the refresh TTL.
    const access_token = generateToken(req.arena, conn, user_id, "access", scopes, ctx.config.token_ttl_seconds) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };
    const new_refresh_token = generateToken(req.arena, conn, user_id, "refresh", scopes, ctx.config.refresh_token_ttl_seconds) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };

    try res.json(.{
        .access_token = access_token,
        .refresh_token = new_refresh_token,
        .expires_in = ctx.config.token_ttl_seconds,
    }, .{});
}

pub fn handleMe(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var ws_list: std.ArrayList(MeWorkspace) = .empty;
    defer ws_list.deinit(req.arena);

    var result = conn.query(
        \\SELECT wm.ws_id, w.name, wm.role FROM workspace_members wm
        \\JOIN workspaces w ON w.ws_id = wm.ws_id
        \\WHERE wm.user_id = $1 ORDER BY w.name
    ,
        .{user.user_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    while (try result.next()) |ws_row| {
        try ws_list.append(req.arena, .{
            .ws_id = try req.arena.dupe(u8, try ws_row.get([]const u8, 0)),
            .name = try req.arena.dupe(u8, try ws_row.get([]const u8, 1)),
            .role = try req.arena.dupe(u8, try ws_row.get([]const u8, 2)),
        });
    }

    try res.json(MeResponse{
        .user_id = user.user_id,
        .username = user.username,
        .role = user.role,
        .scopes = user.scopes,
        .workspaces = ws_list.items,
    }, .{});
}

pub fn authenticate(ctx: *Server.Context, req: *httpz.Request) !AuthUser {
    const auth_header = req.header("authorization") orelse return error.Unauthorized;

    if (auth_header.len < 8) return error.Unauthorized;
    if (!std.ascii.eqlIgnoreCase(auth_header[0..7], "bearer ")) return error.Unauthorized;
    const raw_token = auth_header[7..];

    const token_hash = hashToken(raw_token);

    const conn = ctx.pool.acquire() catch return error.Unauthorized;
    defer conn.release();

    var row = conn.row(
        \\SELECT u.user_id, u.org_id::text, u.username, u.role, t.scopes
        \\FROM tokens t JOIN users u ON u.user_id = t.user_id
        \\WHERE t.token_hash = $1
        \\  AND t.kind = 'access'
        \\  AND t.revoked = false
        \\  AND t.expires_at > now()
    , .{@as([]const u8, &token_hash)}) catch return error.Unauthorized;

    if (row) |*r| {
        const user = AuthUser{
            .user_id = req.arena.dupe(u8, try r.get([]const u8, 0)) catch return error.Unauthorized,
            .org_id = req.arena.dupe(u8, try r.get([]const u8, 1)) catch return error.Unauthorized,
            .username = req.arena.dupe(u8, try r.get([]const u8, 2)) catch return error.Unauthorized,
            .role = req.arena.dupe(u8, try r.get([]const u8, 3)) catch return error.Unauthorized,
            .scopes = req.arena.dupe(u8, try r.get([]const u8, 4)) catch return error.Unauthorized,
        };
        r.deinit() catch {};
        return user;
    }
    return error.Unauthorized;
}

pub fn checkWorkspaceMember(conn: anytype, ws_id: []const u8, user_id: []const u8) bool {
    var row = conn.row(
        "SELECT 1 FROM workspace_members WHERE ws_id = $1 AND user_id = $2",
        .{ ws_id, user_id },
    ) catch return false;
    if (row) |*r| {
        r.deinit() catch {};
        return true;
    }
    return false;
}

pub fn checkWorkspaceAdmin(conn: anytype, ws_id: []const u8, user_id: []const u8) bool {
    var row = conn.row(
        "SELECT 1 FROM workspace_members WHERE ws_id = $1 AND user_id = $2 AND role = 'admin'",
        .{ ws_id, user_id },
    ) catch return false;
    if (row) |*r| {
        r.deinit() catch {};
        return true;
    }
    return false;
}

fn verifyPassword(input: []const u8, stored_hash: []const u8) bool {
    // Reject placeholder hashes (invited users who haven't set a password)
    if (std.mem.startsWith(u8, stored_hash, "!")) return false;
    // Support both bcrypt PHC format and plain text (for dev/migration)
    if (std.mem.startsWith(u8, stored_hash, "$2") or std.mem.startsWith(u8, stored_hash, "$bcrypt")) {
        bcrypt.strVerify(stored_hash, input, .{ .silently_truncate_password = false }) catch return false;
        return true;
    }
    return std.mem.eql(u8, input, stored_hash);
}

fn generateInviteToken(buf: *[68]u8) []const u8 {
    var rand_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    @memcpy(buf[0..4], "inv_");
    hexEncode(&rand_bytes, buf[4..68]);
    return buf;
}

fn hashInviteToken(token: []const u8) [64]u8 {
    return hashToken(token);
}

pub fn hashPassword(password: []const u8, out: []u8) ![]const u8 {
    return bcrypt.strHash(password, .{
        .params = .{ .rounds_log = 10, .silently_truncate_password = false },
        .encoding = .phc,
    }, out);
}

fn generateToken(allocator: std.mem.Allocator, conn: *pg.Conn, user_id: []const u8, kind: []const u8, scopes: []const u8, ttl_seconds: u32) ![]const u8 {
    var rand_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);

    var token_buf: [64]u8 = undefined;
    hexEncode(&rand_bytes, &token_buf);

    const token_hash = hashToken(&token_buf);
    const hash_slice: []const u8 = &token_hash;

    const epoch_now: f64 = @floatFromInt(std.time.timestamp());
    const expires_epoch: f64 = epoch_now + @as(f64, @floatFromInt(ttl_seconds));
    _ = conn.exec(
        "INSERT INTO tokens (token_hash, user_id, kind, scopes, expires_at) VALUES ($1, $2, $3, $4, to_timestamp($5))",
        .{ hash_slice, user_id, kind, scopes, expires_epoch },
    ) catch |err| {
        log.err("token insert failed: {}", .{err});
        if (conn.err) |pg_err| {
            log.err("pg detail: {s}", .{pg_err.message});
        }
        return error.TokenInsertFailed;
    };

    return allocator.dupe(u8, &token_buf) catch return error.TokenInsertFailed;
}

fn hashToken(raw: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    var out: [64]u8 = undefined;
    hexEncode(&digest, &out);
    return out;
}

fn hexEncode(input: []const u8, output: []u8) void {
    const hex = "0123456789abcdef";
    for (input, 0..) |byte, i| {
        output[i * 2] = hex[byte >> 4];
        output[i * 2 + 1] = hex[byte & 0x0f];
    }
}

// Org Member management

const MemberInfo = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    status: []const u8,
    joined_at: []const u8,
};

pub fn handleListMembers(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!requireScope(user, "members:read", res)) return;
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var result = conn.query(
        "SELECT user_id, username, role, status, created_at::text FROM users WHERE org_id = $1::uuid ORDER BY username",
        .{user.org_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(MemberInfo) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .user_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .username = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .role = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .status = try req.arena.dupe(u8, try row.get([]const u8, 3)),
            .joined_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
        });
    }

    try res.json(.{ .members = list.items }, .{});
}

const InviteRequest = struct {
    username: []const u8,
    role: []const u8,
};

pub fn handleInviteMember(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!requireScope(user, "members:write", res)) return;
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const body = req.json(InviteRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (!std.mem.eql(u8, body.role, "member") and !std.mem.eql(u8, body.role, "maintainer")) {
        return apiError(res, 400, "BAD_REQUEST", "role must be member or maintainer");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

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

    // Generate invite token
    var invite_buf: [68]u8 = undefined;
    const invite_token = generateInviteToken(&invite_buf);
    const invite_hash = hashInviteToken(invite_token);
    const invite_hash_slice: []const u8 = &invite_hash;

    _ = conn.exec(
        \\INSERT INTO users (user_id, org_id, username, role, status, invite_token_hash, invite_expires_at)
        \\VALUES ($1, $2::uuid, $3, $4, 'invited', $5, now() + interval '7 days')
    , .{ @as([]const u8, &uid_buf), user.org_id, body.username, body.role, invite_hash_slice }) catch {
        if (conn.err) |pg_err| {
            if (std.mem.indexOf(u8, pg_err.message, "unique") != null or
                std.mem.indexOf(u8, pg_err.message, "duplicate") != null)
            {
                return apiError(res, 409, "CONFLICT", "user already exists in this org");
            }
        }
        return apiError(res, 500, "INTERNAL_ERROR", "database insert failed");
    };

    // Read back invite_expires_at for response
    var exp_row = conn.row(
        "SELECT invite_expires_at::text FROM users WHERE user_id = $1",
        .{@as([]const u8, &uid_buf)},
    ) catch null;
    const expires_at = if (exp_row) |*er| blk: {
        const val = req.arena.dupe(u8, er.get([]const u8, 0) catch "") catch "";
        er.deinit() catch {};
        break :blk val;
    } else "";

    res.status = 201;
    try res.json(.{
        .user_id = @as([]const u8, &uid_buf),
        .username = body.username,
        .role = body.role,
        .status = "invited",
        .invite_token = invite_token,
        .invite_expires_at = expires_at,
    }, .{});
}

const ChangeRoleRequest = struct {
    role: []const u8,
};

pub fn handleChangeRole(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!requireScope(user, "members:write", res)) return;
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const target_id = req.param("user_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "user_id is required");
    };

    const body = req.json(ChangeRoleRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (!std.mem.eql(u8, body.role, "member") and !std.mem.eql(u8, body.role, "maintainer")) {
        return apiError(res, 400, "BAD_REQUEST", "role must be member or maintainer");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Protect last maintainer from demotion
    if (std.mem.eql(u8, body.role, "member")) {
        var count_row = conn.row(
            "SELECT count(*) FROM users WHERE org_id = $1::uuid AND role = 'maintainer'",
            .{user.org_id},
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        } orelse {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        const count = try count_row.get(i64, 0);
        count_row.deinit() catch {};
        if (count <= 1) {
            return apiError(res, 400, "BAD_REQUEST", "cannot demote the last maintainer");
        }
    }

    _ = conn.exec(
        "UPDATE users SET role = $1 WHERE user_id = $2 AND org_id = $3::uuid",
        .{ body.role, target_id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database update failed");
    };

    try res.json(.{ .user_id = target_id, .role = body.role }, .{});
}

pub fn handleRemoveMember(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!requireScope(user, "members:write", res)) return;
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const target_id = req.param("user_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "user_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Check target exists and protect last maintainer
    var target_row = conn.row(
        "SELECT role FROM users WHERE user_id = $1 AND org_id = $2::uuid",
        .{ target_id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "user not found");
    };
    const target_role = try req.arena.dupe(u8, try target_row.get([]const u8, 0));
    target_row.deinit() catch {};

    if (std.mem.eql(u8, target_role, "maintainer")) {
        var count_row = conn.row(
            "SELECT count(*) FROM users WHERE org_id = $1::uuid AND role = 'maintainer'",
            .{user.org_id},
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        } orelse {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        const count = try count_row.get(i64, 0);
        count_row.deinit() catch {};
        if (count <= 1) {
            return apiError(res, 400, "BAD_REQUEST", "cannot remove the last maintainer");
        }
    }

    // Cascade: remove from all workspaces
    _ = conn.exec("DELETE FROM workspace_members WHERE user_id = $1", .{target_id}) catch {};
    // Delete tokens (FK on users has no CASCADE, must remove before user)
    _ = conn.exec("DELETE FROM tokens WHERE user_id = $1", .{target_id}) catch {};
    // Remove user
    _ = conn.exec("DELETE FROM users WHERE user_id = $1 AND org_id = $2::uuid", .{ target_id, user.org_id }) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database delete failed");
    };

    res.status = 204;
}

// Invite activation

const ActivateRequest = struct {
    username: []const u8,
    invite_token: []const u8,
    credential: []const u8,
};

pub fn handleActivate(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const client_ip = req.header("x-forwarded-for") orelse "unknown";
    if (!ctx.auth_rate_limiter.check(client_ip)) {
        return apiError(res, 429, "TOO_MANY_REQUESTS", "rate limit exceeded");
    }

    const body = req.json(ActivateRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (body.credential.len == 0) {
        return apiError(res, 400, "BAD_REQUEST", "credential is required");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT user_id, org_id, role, status, invite_token_hash, invite_expires_at > now() as not_expired FROM users WHERE username = $1",
        .{body.username},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 401, "UNAUTHORIZED", "invalid activation credentials");
    };

    const status = row.get([]const u8, 3) catch {
        row.deinit() catch {};
        return apiError(res, 401, "UNAUTHORIZED", "invalid activation credentials");
    };
    if (!std.mem.eql(u8, status, "invited")) {
        row.deinit() catch {};
        return apiError(res, 401, "UNAUTHORIZED", "invalid activation credentials");
    }

    const stored_hash = row.get([]const u8, 4) catch {
        row.deinit() catch {};
        return apiError(res, 401, "UNAUTHORIZED", "invalid activation credentials");
    };
    const not_expired = row.get(bool, 5) catch false;
    if (!not_expired) {
        row.deinit() catch {};
        return apiError(res, 401, "UNAUTHORIZED", "invitation has expired");
    }

    // Verify invite token (constant-time comparison to prevent timing side-channel)
    const input_hash = hashInviteToken(body.invite_token);
    const match = if (stored_hash.len == input_hash.len) blk: {
        var diff: u8 = 0;
        for (&input_hash, stored_hash[0..input_hash.len]) |a, b| {
            diff |= a ^ b;
        }
        break :blk diff == 0;
    } else false;
    if (!match) {
        row.deinit() catch {};
        return apiError(res, 401, "UNAUTHORIZED", "invalid activation credentials");
    }

    const user_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const org_id = try req.arena.dupe(u8, try row.get([]const u8, 1));
    const role = try req.arena.dupe(u8, try row.get([]const u8, 2));
    row.deinit() catch {};

    // Hash the new password and activate
    var hash_buf: [128]u8 = undefined;
    const password_hash = hashPassword(body.credential, &hash_buf) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "password hashing failed");
    };

    _ = conn.exec(
        \\UPDATE users SET password_hash = $2, status = 'active',
        \\  invite_token_hash = NULL, invite_expires_at = NULL
        \\WHERE user_id = $1
    , .{ user_id, password_hash }) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database update failed");
    };

    // Issue token pair (same as login)
    const default_scopes = if (std.mem.eql(u8, role, "maintainer")) MAINTAINER_SCOPES else MEMBER_SCOPES;
    const ttl = ctx.config.token_ttl_seconds;

    const access_token = generateToken(req.arena, conn, user_id, "access", default_scopes, ttl) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };
    const refresh_token = generateToken(req.arena, conn, user_id, "refresh", default_scopes, ctx.config.refresh_token_ttl_seconds) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };

    _ = org_id; // Used for token scope validation in future

    try res.json(.{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = ttl,
    }, .{});
}

pub fn handleReissueInvite(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!requireScope(user, "members:write", res)) return;
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const target_id = req.param("user_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "user_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT status FROM users WHERE user_id = $1 AND org_id = $2::uuid",
        .{ target_id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "user not found");
    };

    const status = try req.arena.dupe(u8, try row.get([]const u8, 0));
    row.deinit() catch {};

    if (!std.mem.eql(u8, status, "invited")) {
        return apiError(res, 400, "BAD_REQUEST", "user is already active");
    }

    // Generate new invite token (old one is overwritten)
    var invite_buf: [68]u8 = undefined;
    const invite_token = generateInviteToken(&invite_buf);
    const invite_hash = hashInviteToken(invite_token);
    const invite_hash_slice: []const u8 = &invite_hash;

    _ = conn.exec(
        "UPDATE users SET invite_token_hash = $2, invite_expires_at = now() + interval '7 days' WHERE user_id = $1",
        .{ target_id, invite_hash_slice },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database update failed");
    };

    var exp_row = conn.row(
        "SELECT invite_expires_at::text FROM users WHERE user_id = $1",
        .{target_id},
    ) catch null;
    const expires_at = if (exp_row) |*er| blk: {
        const val = req.arena.dupe(u8, er.get([]const u8, 0) catch "") catch "";
        er.deinit() catch {};
        break :blk val;
    } else "";

    try res.json(.{
        .user_id = target_id,
        .status = "invited",
        .invite_token = invite_token,
        .invite_expires_at = expires_at,
    }, .{});
}

// GET /api/org/directory
pub fn handleDirectory(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!requireScope(user, "members:read", res)) return;
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var members: std.ArrayList(auth_api.DirectoryMember) = .empty;
    var result = conn.query(
        "SELECT user_id, username, role, status, created_at::text FROM users WHERE org_id = $1::uuid ORDER BY username",
        .{user.org_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    while (try result.next()) |row| {
        try members.append(req.arena, .{
            .user_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .username = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .role = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .status = try req.arena.dupe(u8, try row.get([]const u8, 3)),
            .joined_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
        });
    }

    try res.json(auth_api.DirectoryResponse{ .members = members.items }, .{});
}
