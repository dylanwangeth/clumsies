const std = @import("std");
const httpz = @import("httpz");
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("../protocol/api_error.zig").send;

const CreateTeamRequest = struct {
    name: []const u8,
};

// POST /api/org/teams
pub fn handleCreateTeam(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const body = req.json(CreateTeamRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (body.name.len == 0) {
        return apiError(res, 400, "BAD_REQUEST", "name is required");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var rand_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var id_buf: [35]u8 = undefined;
    @memcpy(id_buf[0..3], "tm-");
    const hex = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        id_buf[3 + i * 2] = hex[byte >> 4];
        id_buf[3 + i * 2 + 1] = hex[byte & 0x0f];
    }

    _ = conn.exec(
        "INSERT INTO teams (team_id, org_id, name) VALUES ($1, $2::uuid, $3)",
        .{ &id_buf, user.org_id, body.name },
    ) catch {
        if (conn.err) |pg_err| {
            if (std.mem.indexOf(u8, pg_err.message, "unique") != null or
                std.mem.indexOf(u8, pg_err.message, "duplicate") != null)
            {
                return apiError(res, 409, "CONFLICT", "team with this name already exists");
            }
        }
        return apiError(res, 500, "INTERNAL_ERROR", "failed to create team");
    };

    res.status = 201;
    try res.json(.{ .team_id = &id_buf, .name = body.name }, .{});
}

// GET /api/org/teams
pub fn handleListTeams(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    const TeamInfo = struct {
        team_id: []const u8,
        name: []const u8,
        member_count: i64,
    };

    var result = conn.query(
        \\SELECT t.team_id, t.name,
        \\    (SELECT count(*) FROM team_members tm WHERE tm.team_id = t.team_id)
        \\FROM teams t WHERE t.org_id = $1::uuid ORDER BY t.name
    ,
        .{user.org_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(TeamInfo) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .team_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .name = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .member_count = try row.get(i64, 2),
        });
    }

    try res.json(.{ .teams = list.items }, .{});
}

// GET /api/org/teams/:team_id
pub fn handleGetTeam(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const team_id = req.param("team_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "team_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var team_row = conn.row(
        "SELECT team_id, name FROM teams WHERE team_id = $1 AND org_id = $2::uuid",
        .{ team_id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "team not found");
    };

    const tid = try req.arena.dupe(u8, try team_row.get([]const u8, 0));
    const name = try req.arena.dupe(u8, try team_row.get([]const u8, 1));
    team_row.deinit() catch {};

    const MemberInfo = struct {
        user_id: []const u8,
        username: []const u8,
    };

    var member_result = conn.query(
        "SELECT tm.user_id, u.username FROM team_members tm JOIN users u ON u.user_id = tm.user_id WHERE tm.team_id = $1 ORDER BY u.username",
        .{team_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer member_result.deinit();

    var members: std.ArrayList(MemberInfo) = .empty;
    while (try member_result.next()) |row| {
        try members.append(req.arena, .{
            .user_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .username = try req.arena.dupe(u8, try row.get([]const u8, 1)),
        });
    }

    try res.json(.{
        .team_id = tid,
        .name = name,
        .members = members.items,
    }, .{});
}

// DELETE /api/org/teams/:team_id
pub fn handleDeleteTeam(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const team_id = req.param("team_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "team_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    _ = conn.exec("DELETE FROM workspace_team_access WHERE team_id = $1", .{team_id}) catch {};
    _ = conn.exec("DELETE FROM team_members WHERE team_id = $1", .{team_id}) catch {};

    const deleted = conn.exec(
        "DELETE FROM teams WHERE team_id = $1 AND org_id = $2::uuid",
        .{ team_id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database delete failed");
    };

    if (deleted == null or deleted.? == 0) {
        return apiError(res, 404, "NOT_FOUND", "team not found");
    }

    res.status = 204;
}

const AddTeamMemberRequest = struct {
    user_id: []const u8,
};

// POST /api/org/teams/:team_id/members
pub fn handleAddTeamMember(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const team_id = req.param("team_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "team_id is required");
    };

    const body = req.json(AddTeamMemberRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Verify team exists in this org
    var team_check = conn.row(
        "SELECT 1 FROM teams WHERE team_id = $1 AND org_id = $2::uuid",
        .{ team_id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "team not found");
    };
    team_check.deinit() catch {};

    // Verify user exists in org
    var user_check = conn.row(
        "SELECT 1 FROM users WHERE user_id = $1 AND org_id = $2::uuid",
        .{ body.user_id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "user not found in org");
    };
    user_check.deinit() catch {};

    _ = conn.exec(
        "INSERT INTO team_members (team_id, user_id) VALUES ($1, $2)",
        .{ team_id, body.user_id },
    ) catch {
        if (conn.err) |pg_err| {
            if (std.mem.indexOf(u8, pg_err.message, "unique") != null or
                std.mem.indexOf(u8, pg_err.message, "duplicate") != null)
            {
                return apiError(res, 409, "CONFLICT", "user is already in this team");
            }
        }
        return apiError(res, 500, "INTERNAL_ERROR", "failed to add team member");
    };

    res.status = 201;
    try res.json(.{ .team_id = team_id, .user_id = body.user_id }, .{});
}

// DELETE /api/org/teams/:team_id/members/:user_id
pub fn handleRemoveTeamMember(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const team_id = req.param("team_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "team_id is required");
    };
    const target_id = req.param("user_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "user_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    _ = conn.exec(
        "DELETE FROM team_members WHERE team_id = $1 AND user_id = $2",
        .{ team_id, target_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database delete failed");
    };

    res.status = 204;
}
