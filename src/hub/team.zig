const std = @import("std");
const httpz = @import("httpz");
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("../protocol/api_error.zig").send;

// GET /api/org/directory
pub fn handleDirectory(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "members:read", res)) return;
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    const DirectoryMember = struct {
        user_id: []const u8,
        username: []const u8,
        role: []const u8,
        joined_at: []const u8,
    };

    var members: std.ArrayList(DirectoryMember) = .empty;
    var result = conn.query(
        "SELECT user_id, username, role, created_at::text FROM users WHERE org_id = $1::uuid ORDER BY username",
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
            .joined_at = try req.arena.dupe(u8, try row.get([]const u8, 3)),
        });
    }

    try res.json(.{ .members = members.items }, .{});
}
