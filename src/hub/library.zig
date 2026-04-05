const std = @import("std");
const httpz = @import("httpz");
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("../protocol/api_error.zig").send;
const KvMap = @import("../protocol/manifest.zig").KvMap;
const KvEntry = @import("../protocol/manifest.zig").KvEntry;

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
        try res.json(.{
            .revision = @as(i32, 0),
            .prompts = KvMap{ .entries = &.{} },
        }, .{});
        return;
    };

    const revision = try rev_row.get(i32, 0);
    rev_row.deinit() catch {};

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

    var entries: std.ArrayList(KvEntry) = .empty;
    while (try result.next()) |row| {
        try entries.append(req.arena, .{
            .key = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .value = try req.arena.dupe(u8, try row.get([]const u8, 1)),
        });
    }

    var etag_buf: [32]u8 = undefined;
    const etag_slice = std.fmt.bufPrint(&etag_buf, "\"rev-{d}\"", .{revision}) catch "";
    res.header("ETag", try req.arena.dupe(u8, etag_slice));

    try res.json(.{
        .revision = revision,
        .prompts = KvMap{ .entries = entries.items },
    }, .{});
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
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .prompt_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .kind = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .canonical_name = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .content_hash = try req.arena.dupe(u8, try row.get([]const u8, 3)),
            .updated_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
        });
    }

    try res.json(.{ .prompts = list.items }, .{});
}

pub fn handleGetPrompt(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const name = qs.get("name") orelse {
        return apiError(res, 400, "BAD_REQUEST", "name query parameter is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT prompt_id, kind, canonical_name, content_hash, updated_at::text FROM prompts WHERE org_id = $1::uuid AND canonical_name = $2",
        .{ user.org_id, name },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "prompt not found");
    };

    const prompt_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const kind = try req.arena.dupe(u8, try row.get([]const u8, 1));
    const canonical_name = try req.arena.dupe(u8, try row.get([]const u8, 2));
    const content_hash = try req.arena.dupe(u8, try row.get([]const u8, 3));
    const updated_at = try req.arena.dupe(u8, try row.get([]const u8, 4));
    row.deinit() catch {};

    try res.json(.{
        .prompt_id = prompt_id,
        .kind = kind,
        .canonical_name = canonical_name,
        .content_hash = content_hash,
        .updated_at = updated_at,
    }, .{});
}

pub fn handleGetPromptContent(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const name = qs.get("name") orelse {
        return apiError(res, 400, "BAD_REQUEST", "name query parameter is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT prompt_id, content_hash, content FROM prompts WHERE org_id = $1::uuid AND canonical_name = $2",
        .{ user.org_id, name },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "prompt not found");
    };

    const content_hash = try req.arena.dupe(u8, try row.get([]const u8, 1));

    if (req.header("if-none-match")) |etag| {
        if (std.mem.eql(u8, etag, content_hash)) {
            row.deinit() catch {};
            res.status = 304;
            return;
        }
    }

    const prompt_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const body = try req.arena.dupe(u8, try row.get([]const u8, 2));
    row.deinit() catch {};

    res.header("ETag", content_hash);
    try res.json(.{
        .prompt_id = prompt_id,
        .content_hash = content_hash,
        .body = body,
    }, .{});
}

pub fn handleListBundles(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    const BundleMeta = struct {
        name: []const u8,
        description: []const u8,
        updated_at: []const u8,
    };

    var result = conn.query(
        "SELECT name, description, updated_at::text FROM bundles WHERE org_id = $1::uuid ORDER BY name",
        .{user.org_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(BundleMeta) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .name = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .description = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .updated_at = try req.arena.dupe(u8, try row.get([]const u8, 2)),
        });
    }

    try res.json(.{ .bundles = list.items }, .{});
}

pub fn handleGetBundle(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const name = req.param("name") orelse {
        return apiError(res, 400, "BAD_REQUEST", "name is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT bundle_id, name, description, created_at::text, updated_at::text FROM bundles WHERE org_id = $1::uuid AND name = $2",
        .{ user.org_id, name },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "bundle not found");
    };

    const bundle_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const bundle_name = try req.arena.dupe(u8, try row.get([]const u8, 1));
    const description = try req.arena.dupe(u8, try row.get([]const u8, 2));
    const created_at = try req.arena.dupe(u8, try row.get([]const u8, 3));
    const updated_at = try req.arena.dupe(u8, try row.get([]const u8, 4));
    row.deinit() catch {};

    var prompt_result = conn.query(
        "SELECT prompt_id FROM bundle_prompts WHERE bundle_id = $1",
        .{bundle_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer prompt_result.deinit();

    var ids: std.ArrayList([]const u8) = .empty;
    while (try prompt_result.next()) |prow| {
        try ids.append(req.arena, try req.arena.dupe(u8, try prow.get([]const u8, 0)));
    }

    try res.json(.{
        .name = bundle_name,
        .description = description,
        .prompt_ids = ids.items,
        .created_at = created_at,
        .updated_at = updated_at,
    }, .{});
}
