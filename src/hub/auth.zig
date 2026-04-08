const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");
const Server = @import("server.zig");
const apiError = @import("../protocol/api_error.zig").send;

const bcrypt = std.crypto.pwhash.bcrypt;

pub const AuthUser = struct {
    user_id: []const u8,
    org_id: []const u8,
    username: []const u8,
    role: []const u8,
    scopes: []const u8,
};

const MEMBER_SCOPES = "library:read,workspace:read,workspace:write,trace:write,stats:read,members:read,proposal:read,proposal:write,team:read";
const MAINTAINER_SCOPES = "library:read,library:write,bundle:write,workspace:read,workspace:write,trace:write,stats:read,members:read,members:write,proposal:read,proposal:write,proposal:merge,team:read,team:write";

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
        "SELECT user_id, org_id, username, role, password_hash FROM users WHERE username = $1",
        .{login.username},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 401, "UNAUTHORIZED", "invalid credentials");
    };

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
    const scopes = login.scopes orelse default_scopes;

    const access_token = generateToken(req.arena, conn, user_id, "access", scopes, ctx.config.token_ttl_seconds) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };
    const refresh_token = generateToken(req.arena, conn, user_id, "refresh", scopes, ctx.config.token_ttl_seconds * 24) catch {
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

    const access_token = generateToken(req.arena, conn, user_id, "access", scopes, ctx.config.token_ttl_seconds) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };

    try res.json(.{
        .access_token = access_token,
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

    var ws_list: std.ArrayList(WorkspaceInfo) = .empty;
    defer ws_list.deinit(req.arena);

    var result = conn.query(
        \\SELECT DISTINCT w.ws_id, w.name FROM workspaces w
        \\WHERE w.ws_id IN (
        \\    SELECT ws_id FROM workspace_user_access WHERE user_id = $1
        \\    UNION
        \\    SELECT wta.ws_id FROM workspace_team_access wta
        \\        JOIN team_members tm ON tm.team_id = wta.team_id
        \\        WHERE tm.user_id = $1
        \\)
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
        });
    }

    try res.json(.{
        .user_id = user.user_id,
        .username = user.username,
        .role = user.role,
        .scopes = user.scopes,
        .workspaces = ws_list.items,
    }, .{});
}

const WorkspaceInfo = struct {
    ws_id: []const u8,
    name: []const u8,
};

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
        \\SELECT 1 FROM workspace_user_access WHERE ws_id = $1 AND user_id = $2
        \\UNION ALL
        \\SELECT 1 FROM workspace_team_access wta
        \\    JOIN team_members tm ON tm.team_id = wta.team_id
        \\    WHERE wta.ws_id = $1 AND tm.user_id = $2
        \\LIMIT 1
    ,
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
        \\SELECT 1 FROM workspace_user_access WHERE ws_id = $1 AND user_id = $2 AND level = 'admin'
        \\UNION ALL
        \\SELECT 1 FROM workspace_team_access wta
        \\    JOIN team_members tm ON tm.team_id = wta.team_id
        \\    WHERE wta.ws_id = $1 AND tm.user_id = $2 AND wta.level = 'admin'
        \\LIMIT 1
    ,
        .{ ws_id, user_id },
    ) catch return false;
    if (row) |*r| {
        r.deinit() catch {};
        return true;
    }
    return false;
}

fn verifyPassword(input: []const u8, stored_hash: []const u8) bool {
    // Support both bcrypt PHC format and plain text (for dev/migration)
    if (std.mem.startsWith(u8, stored_hash, "$2") or std.mem.startsWith(u8, stored_hash, "$bcrypt")) {
        bcrypt.strVerify(stored_hash, input, .{ .silently_truncate_password = false }) catch return false;
        return true;
    }
    return std.mem.eql(u8, input, stored_hash);
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
        std.log.err("token insert failed: {}", .{err});
        if (conn.err) |pg_err| {
            std.log.err("pg detail: {s}", .{pg_err.message});
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
    joined_at: []const u8,
};

pub fn handleListMembers(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var result = conn.query(
        "SELECT user_id, username, role, created_at::text FROM users WHERE org_id = $1::uuid ORDER BY username",
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
            .joined_at = try req.arena.dupe(u8, try row.get([]const u8, 3)),
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

    _ = conn.exec(
        "INSERT INTO users (user_id, org_id, username, role, password_hash) VALUES ($1, $2::uuid, $3, $4, '')",
        .{ @as([]const u8, &uid_buf), user.org_id, body.username, body.role },
    ) catch {
        if (conn.err) |pg_err| {
            if (std.mem.indexOf(u8, pg_err.message, "unique") != null or
                std.mem.indexOf(u8, pg_err.message, "duplicate") != null)
            {
                return apiError(res, 409, "CONFLICT", "user already exists in this org");
            }
        }
        return apiError(res, 500, "INTERNAL_ERROR", "database insert failed");
    };

    res.status = 201;
    try res.json(.{
        .user_id = @as([]const u8, &uid_buf),
        .username = body.username,
        .role = body.role,
    }, .{});
}

const ChangeRoleRequest = struct {
    role: []const u8,
};

pub fn handleChangeRole(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
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

    // Cascade: remove from all workspaces and teams
    _ = conn.exec("DELETE FROM workspace_user_access WHERE user_id = $1", .{target_id}) catch {};
    _ = conn.exec("DELETE FROM team_members WHERE user_id = $1", .{target_id}) catch {};
    // Revoke tokens
    _ = conn.exec("UPDATE tokens SET revoked = true WHERE user_id = $1", .{target_id}) catch {};
    // Remove user
    _ = conn.exec("DELETE FROM users WHERE user_id = $1 AND org_id = $2::uuid", .{ target_id, user.org_id }) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database delete failed");
    };

    res.status = 204;
}
