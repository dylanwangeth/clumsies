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
};

const LoginRequest = struct {
    username: []const u8,
    credential: []const u8,
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
    row.deinit() catch {};

    const access_token = generateToken(req.arena, conn, user_id, "access", ctx.config.token_ttl_seconds) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };
    const refresh_token = generateToken(req.arena, conn, user_id, "refresh", ctx.config.token_ttl_seconds * 24) catch {
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
        \\SELECT t.user_id FROM tokens t
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
    row.deinit() catch {};

    _ = conn.exec("UPDATE tokens SET revoked = true WHERE token_hash = $1", .{@as([]const u8, &token_hash)}) catch {};

    const access_token = generateToken(req.arena, conn, user_id, "access", ctx.config.token_ttl_seconds) catch {
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
        "SELECT w.ws_id, w.name FROM workspace_members wm JOIN workspaces w ON w.ws_id = wm.ws_id WHERE wm.user_id = $1",
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
        \\SELECT u.user_id, u.org_id::text, u.username, u.role
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

fn generateToken(allocator: std.mem.Allocator, conn: *pg.Conn, user_id: []const u8, kind: []const u8, ttl_seconds: u32) ![]const u8 {
    var rand_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);

    var token_buf: [64]u8 = undefined;
    hexEncode(&rand_bytes, &token_buf);

    const token_hash = hashToken(&token_buf);
    const hash_slice: []const u8 = &token_hash;

    const epoch_now: f64 = @floatFromInt(std.time.timestamp());
    const expires_epoch: f64 = epoch_now + @as(f64, @floatFromInt(ttl_seconds));
    _ = conn.exec(
        "INSERT INTO tokens (token_hash, user_id, kind, expires_at) VALUES ($1, $2, $3, to_timestamp($4))",
        .{ hash_slice, user_id, kind, expires_epoch },
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
