const std = @import("std");
const httpz = @import("httpz");
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("../protocol/api_error.zig").send;
const ManifestMap = @import("../protocol/manifest.zig").ManifestMap;
const ManifestItem = @import("../protocol/manifest.zig").ManifestItem;

pub fn handleGetManifest(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "library:read", res)) return;

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
            .prompts = ManifestMap{ .items = &.{} },
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
        "SELECT prompt_id, path, content_hash FROM prompts WHERE org_id = $1::uuid",
        .{user.org_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var items: std.ArrayList(ManifestItem) = .empty;
    while (try result.next()) |row| {
        try items.append(req.arena, .{
            .key = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .value = .{
                .path = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                .hash = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            },
        });
    }

    var etag_buf: [32]u8 = undefined;
    const etag_slice = std.fmt.bufPrint(&etag_buf, "\"rev-{d}\"", .{revision}) catch "";
    res.header("ETag", try req.arena.dupe(u8, etag_slice));

    try res.json(.{
        .revision = revision,
        .prompts = ManifestMap{ .items = items.items },
    }, .{});
}

const PromptMeta = struct {
    prompt_id: []const u8,
    path: []const u8,
    content_hash: []const u8,
    updated_at: []const u8,
    source: []const u8,
};

pub fn handleListPrompts(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "library:read", res)) return;

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const path_prefix = qs.get("path_prefix");

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var result = if (path_prefix) |prefix| blk: {
        const like_arg = try std.fmt.allocPrint(req.arena, "{s}%", .{prefix});
        break :blk conn.query(
            "SELECT p.prompt_id, p.path, p.content_hash, p.updated_at::text, o.name as source FROM prompts p JOIN orgs o ON o.org_id = p.org_id WHERE p.org_id = $1::uuid AND p.path LIKE $2 ORDER BY p.path",
            .{ user.org_id, like_arg },
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
    } else conn.query(
        "SELECT p.prompt_id, p.path, p.content_hash, p.updated_at::text, o.name as source FROM prompts p JOIN orgs o ON o.org_id = p.org_id WHERE p.org_id = $1::uuid ORDER BY p.path",
        .{user.org_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(PromptMeta) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .prompt_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .path = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .content_hash = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .updated_at = try req.arena.dupe(u8, try row.get([]const u8, 3)),
            .source = try req.arena.dupe(u8, try row.get([]const u8, 4)),
        });
    }

    try res.json(.{ .prompts = list.items }, .{});
}

const HistoryEntry = struct {
    content_hash: []const u8,
    path: []const u8,
    merged_at: []const u8,
    pr_id: ?[]const u8,
};

pub fn handleGetPrompt(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "library:read", res)) return;

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const prompt_id_q = qs.get("prompt_id");
    const path_q = qs.get("path");
    if (prompt_id_q == null and path_q == null) {
        return apiError(res, 400, "BAD_REQUEST", "prompt_id or path query parameter is required");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = (if (prompt_id_q) |pid| conn.row(
        "SELECT p.prompt_id, p.path, p.content_hash, p.updated_at::text, o.name as source FROM prompts p JOIN orgs o ON o.org_id = p.org_id WHERE p.org_id = $1::uuid AND p.prompt_id = $2",
        .{ user.org_id, pid },
    ) else conn.row(
        "SELECT p.prompt_id, p.path, p.content_hash, p.updated_at::text, o.name as source FROM prompts p JOIN orgs o ON o.org_id = p.org_id WHERE p.org_id = $1::uuid AND p.path = $2",
        .{ user.org_id, path_q.? },
    )) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "prompt not found");
    };

    const prompt_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const path = try req.arena.dupe(u8, try row.get([]const u8, 1));
    const content_hash = try req.arena.dupe(u8, try row.get([]const u8, 2));
    const updated_at = try req.arena.dupe(u8, try row.get([]const u8, 3));
    const source = try req.arena.dupe(u8, try row.get([]const u8, 4));
    row.deinit() catch {};

    var history_result = conn.query(
        "SELECT content_hash, path, merged_at::text, pr_id FROM prompt_history WHERE prompt_id = $1 ORDER BY merged_at DESC",
        .{prompt_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer history_result.deinit();

    var history: std.ArrayList(HistoryEntry) = .empty;
    while (try history_result.next()) |hrow| {
        const h_hash = try req.arena.dupe(u8, try hrow.get([]const u8, 0));
        const h_path = try req.arena.dupe(u8, try hrow.get([]const u8, 1));
        const h_merged = try req.arena.dupe(u8, try hrow.get([]const u8, 2));
        const h_pr_id: ?[]const u8 = if (hrow.get([]const u8, 3)) |v|
            try req.arena.dupe(u8, v)
        else |_|
            null;
        try history.append(req.arena, .{
            .content_hash = h_hash,
            .path = h_path,
            .merged_at = h_merged,
            .pr_id = h_pr_id,
        });
    }

    try res.json(.{
        .prompt_id = prompt_id,
        .path = path,
        .content_hash = content_hash,
        .updated_at = updated_at,
        .source = source,
        .history = history.items,
    }, .{});
}

pub fn handleGetPromptContent(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "library:read", res)) return;

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const prompt_id_q = qs.get("prompt_id");
    const path_q = qs.get("path");
    if (prompt_id_q == null and path_q == null) {
        return apiError(res, 400, "BAD_REQUEST", "prompt_id or path query parameter is required");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = (if (prompt_id_q) |pid| conn.row(
        "SELECT prompt_id, content_hash, content, path FROM prompts WHERE org_id = $1::uuid AND prompt_id = $2",
        .{ user.org_id, pid },
    ) else conn.row(
        "SELECT prompt_id, content_hash, content, path FROM prompts WHERE org_id = $1::uuid AND path = $2",
        .{ user.org_id, path_q.? },
    )) catch {
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
    const path = try req.arena.dupe(u8, try row.get([]const u8, 3));
    row.deinit() catch {};

    res.header("ETag", content_hash);
    try res.json(.{
        .prompt_id = prompt_id,
        .path = path,
        .content_hash = content_hash,
        .body = body,
    }, .{});
}

pub fn handleListBundles(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "library:read", res)) return;

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
    if (!auth.requireScope(user, "library:read", res)) return;

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

const CreateBundleRequest = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    prompt_ids: []const []const u8,
};

pub fn handleCreateBundle(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "bundle:write", res)) return;
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const body = req.json(CreateBundleRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Validate all prompt_ids exist
    for (body.prompt_ids) |pid| {
        var exists = conn.row(
            "SELECT 1 FROM prompts WHERE org_id = $1::uuid AND prompt_id = $2",
            .{ user.org_id, pid },
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        if (exists) |*r| {
            r.deinit() catch {};
        } else {
            return apiError(res, 400, "BAD_REQUEST", "prompt_id not found in Library");
        }
    }

    // Generate bundle_id
    var rand_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var bid_buf: [36]u8 = undefined;
    @memcpy(bid_buf[0..4], "bnd-");
    const hex = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        bid_buf[4 + i * 2] = hex[byte >> 4];
        bid_buf[4 + i * 2 + 1] = hex[byte & 0x0f];
    }
    const bundle_id: []const u8 = &bid_buf;

    const desc = body.description orelse "";
    _ = conn.exec(
        "INSERT INTO bundles (bundle_id, org_id, name, description) VALUES ($1, $2::uuid, $3, $4)",
        .{ bundle_id, user.org_id, body.name, desc },
    ) catch {
        if (conn.err) |pg_err| {
            if (std.mem.indexOf(u8, pg_err.message, "unique") != null or
                std.mem.indexOf(u8, pg_err.message, "duplicate") != null)
            {
                return apiError(res, 409, "CONFLICT", "bundle with this name already exists");
            }
        }
        return apiError(res, 500, "INTERNAL_ERROR", "database insert failed");
    };

    for (body.prompt_ids) |pid| {
        _ = conn.exec(
            "INSERT INTO bundle_prompts (bundle_id, prompt_id) VALUES ($1, $2)",
            .{ bundle_id, pid },
        ) catch {};
    }

    res.status = 201;
    try res.json(.{
        .name = body.name,
        .description = desc,
        .prompt_ids = body.prompt_ids,
    }, .{});
}

const UpdateBundleRequest = struct {
    description: ?[]const u8 = null,
    prompt_ids: ?[]const []const u8 = null,
};

pub fn handleUpdateBundle(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "bundle:write", res)) return;
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const name = req.param("name") orelse {
        return apiError(res, 400, "BAD_REQUEST", "name is required");
    };

    const body = req.json(UpdateBundleRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Find bundle
    var row = conn.row(
        "SELECT bundle_id FROM bundles WHERE org_id = $1::uuid AND name = $2",
        .{ user.org_id, name },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "bundle not found");
    };
    const bundle_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    row.deinit() catch {};

    // Update description if provided
    if (body.description) |desc| {
        _ = conn.exec(
            "UPDATE bundles SET description = $1, updated_at = now() WHERE bundle_id = $2",
            .{ desc, bundle_id },
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database update failed");
        };
    }

    // Replace prompt_ids if provided
    if (body.prompt_ids) |pids| {
        for (pids) |pid| {
            var exists2 = conn.row(
                "SELECT 1 FROM prompts WHERE org_id = $1::uuid AND prompt_id = $2",
                .{ user.org_id, pid },
            ) catch {
                return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            };
            if (exists2) |*r| {
                r.deinit() catch {};
            } else {
                return apiError(res, 400, "BAD_REQUEST", "prompt_id not found in Library");
            }
        }

        _ = conn.exec("DELETE FROM bundle_prompts WHERE bundle_id = $1", .{bundle_id}) catch {};
        for (pids) |pid| {
            _ = conn.exec(
                "INSERT INTO bundle_prompts (bundle_id, prompt_id) VALUES ($1, $2)",
                .{ bundle_id, pid },
            ) catch {};
        }
        _ = conn.exec(
            "UPDATE bundles SET updated_at = now() WHERE bundle_id = $1",
            .{bundle_id},
        ) catch {};
    }

    try res.json(.{ .name = name, .updated = true }, .{});
}

pub fn handleDeleteBundle(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "bundle:write", res)) return;
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const name = req.param("name") orelse {
        return apiError(res, 400, "BAD_REQUEST", "name is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT bundle_id FROM bundles WHERE org_id = $1::uuid AND name = $2",
        .{ user.org_id, name },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "bundle not found");
    };
    const bundle_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    row.deinit() catch {};

    _ = conn.exec("DELETE FROM bundle_prompts WHERE bundle_id = $1", .{bundle_id}) catch {};
    _ = conn.exec("DELETE FROM bundles WHERE bundle_id = $1", .{bundle_id}) catch {};

    res.status = 204;
}
