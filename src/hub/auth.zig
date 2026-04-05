const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");
const Server = @import("server.zig");
const apiError = @import("../protocol/api_error.zig").send;

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

pub fn handleLogin(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
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
    defer row.deinit() catch {};

    const stored_hash = try row.get([]const u8, 4);
    if (!verifyPassword(login.credential, stored_hash)) {
        return apiError(res, 401, "UNAUTHORIZED", "invalid credentials");
    }

    const user_id = try row.get([]const u8, 0);

    const access_token = generateToken(conn, user_id, "access", ctx.config.token_ttl_seconds) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };
    const refresh_token = generateToken(conn, user_id, "refresh", ctx.config.token_ttl_seconds * 24) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "token generation failed");
    };

    try res.json(.{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = ctx.config.token_ttl_seconds,
    }, .{});
}

pub fn handleRefresh(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
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
    , .{&token_hash}) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or expired refresh token");
    };
    defer row.deinit() catch {};

    const user_id = try row.get([]const u8, 0);

    _ = conn.exec("UPDATE tokens SET revoked = true WHERE token_hash = $1", .{&token_hash}) catch {};

    const access_token = generateToken(conn, user_id, "access", ctx.config.token_ttl_seconds) catch {
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
            .ws_id = try ws_row.get([]const u8, 0),
            .name = try ws_row.get([]const u8, 1),
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
    , .{&token_hash}) catch return error.Unauthorized;

    if (row) |*r| {
        defer r.deinit() catch {};
        return .{
            .user_id = try r.get([]const u8, 0),
            .org_id = try r.get([]const u8, 1),
            .username = try r.get([]const u8, 2),
            .role = try r.get([]const u8, 3),
        };
    }
    return error.Unauthorized;
}

fn verifyPassword(input: []const u8, stored_hash: []const u8) bool {
    // TODO: Implement bcrypt/argon2 for production
    return std.mem.eql(u8, input, stored_hash);
}

fn generateToken(conn: anytype, user_id: []const u8, kind: []const u8, ttl_seconds: u32) ![]const u8 {
    var rand_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);

    var token_buf: [64]u8 = undefined;
    hexEncode(&rand_bytes, &token_buf);

    const token_hash = hashToken(&token_buf);

    _ = conn.exec(
        "INSERT INTO tokens (token_hash, user_id, kind, expires_at) VALUES ($1, $2, $3, now() + make_interval(secs => $4))",
        .{ &token_hash, user_id, kind, @as(i32, @intCast(ttl_seconds)) },
    ) catch return error.TokenInsertFailed;

    return &token_buf;
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
