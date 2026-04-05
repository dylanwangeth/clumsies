const std = @import("std");
const httpz = @import("httpz");
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("../protocol/api_error.zig").send;

pub fn handleGetManifest(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var rev_row = conn.row(
        "SELECT revision FROM library_manifest WHERE org_id = $1::uuid",
        .{user.org_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        const w = res.writer();
        try w.writeAll("{\"revision\":0,\"prompts\":{}}");
        return;
    };
    defer rev_row.deinit() catch {};

    const revision = try rev_row.get(i32, 0);

    if (req.header("if-none-match")) |etag| {
        var etag_buf: [32]u8 = undefined;
        const expected = std.fmt.bufPrint(&etag_buf, "\"rev-{d}\"", .{revision}) catch "";
        if (std.mem.eql(u8, etag, expected)) {
            res.status = 304;
            return;
        }
    }

    var result = conn.query(
        "SELECT prompt_id, content_hash FROM prompts WHERE org_id = $1::uuid",
        .{user.org_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    const w = res.writer();
    try w.print("{{\"revision\":{d},\"prompts\":{{", .{revision});

    var first = true;
    while (try result.next()) |row| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("\"");
        try w.writeAll(try row.get([]const u8, 0));
        try w.writeAll("\":\"");
        try w.writeAll(try row.get([]const u8, 1));
        try w.writeAll("\"");
    }

    try w.writeAll("}}");

    var etag_buf: [32]u8 = undefined;
    const etag = std.fmt.bufPrint(&etag_buf, "\"rev-{d}\"", .{revision}) catch "";
    res.header("ETag", etag);
}

const PromptMeta = struct {
    prompt_id: []const u8,
    kind: []const u8,
    canonical_name: []const u8,
    content_hash: []const u8,
    updated_at: []const u8,
};

pub fn handleListPrompts(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var result = conn.query(
        "SELECT prompt_id, kind, canonical_name, content_hash, updated_at::text FROM prompts WHERE org_id = $1::uuid ORDER BY canonical_name",
        .{user.org_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(PromptMeta) = .empty;
    defer list.deinit(req.arena);

    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .prompt_id = try row.get([]const u8, 0),
            .kind = try row.get([]const u8, 1),
            .canonical_name = try row.get([]const u8, 2),
            .content_hash = try row.get([]const u8, 3),
            .updated_at = try row.get([]const u8, 4),
        });
    }

    try res.json(.{
        .prompts = list.items,
    }, .{});
}
