//! Hub Library endpoints. The Library is the org's rule collection and single source of truth.
//! Serves the library manifest (content index), rule metadata, rule content by hash, and
//! bundle definitions.
const std = @import("std");
const httpz = @import("httpz");
const library_api = @import("clumsies_lib").protocol.library_api;
const manifest = @import("clumsies_lib").protocol.manifest;
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("api_error.zig").send;
const BundleListResponse = library_api.BundleListResponse;
const BundleMeta = library_api.BundleMeta;
const LibraryManifestResponse = library_api.LibraryManifestResponse;
const RuleListResponse = library_api.RuleListResponse;
const RuleMeta = library_api.RuleMeta;
const RuleContentResponse = library_api.RuleContentResponse;
const BatchRuleContentRequest = library_api.BatchRuleContentRequest;
const BatchRuleContentResponse = library_api.BatchRuleContentResponse;
const BatchRuleItem = library_api.BatchRuleItem;
const ManifestMap = manifest.ManifestMap;
const ManifestItem = manifest.ManifestItem;

const BATCH_MAX_IDS: usize = 1024;

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
        try res.json(LibraryManifestResponse{
            .revision = @as(i32, 0),
            .rules = ManifestMap{ .items = &.{} },
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
        "SELECT rule_id, path, content_hash FROM rules WHERE org_id = $1::uuid",
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

    try res.json(LibraryManifestResponse{
        .revision = revision,
        .rules = ManifestMap{ .items = items.items },
    }, .{});
}

pub fn handleListRules(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
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
            "SELECT p.rule_id, p.path, p.content_hash, p.updated_at::text, o.name as source FROM rules p JOIN orgs o ON o.org_id = p.org_id WHERE p.org_id = $1::uuid AND p.path LIKE $2 ORDER BY p.path",
            .{ user.org_id, like_arg },
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
    } else conn.query(
        "SELECT p.rule_id, p.path, p.content_hash, p.updated_at::text, o.name as source FROM rules p JOIN orgs o ON o.org_id = p.org_id WHERE p.org_id = $1::uuid ORDER BY p.path",
        .{user.org_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(RuleMeta) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .rule_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .path = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .content_hash = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .updated_at = try req.arena.dupe(u8, try row.get([]const u8, 3)),
            .source = try req.arena.dupe(u8, try row.get([]const u8, 4)),
        });
    }

    try res.json(RuleListResponse{ .rules = list.items }, .{});
}

const HistoryEntry = struct {
    content_hash: []const u8,
    path: []const u8,
    merged_at: []const u8,
    pr_id: ?[]const u8,
};

pub fn handleGetRule(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "library:read", res)) return;

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const rule_id_q = qs.get("rule_id");
    const path_q = qs.get("path");
    if (rule_id_q == null and path_q == null) {
        return apiError(res, 400, "BAD_REQUEST", "rule_id or path query parameter is required");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = (if (rule_id_q) |pid| conn.row(
        "SELECT p.rule_id, p.path, p.content_hash, p.updated_at::text, o.name as source FROM rules p JOIN orgs o ON o.org_id = p.org_id WHERE p.org_id = $1::uuid AND p.rule_id = $2",
        .{ user.org_id, pid },
    ) else conn.row(
        "SELECT p.rule_id, p.path, p.content_hash, p.updated_at::text, o.name as source FROM rules p JOIN orgs o ON o.org_id = p.org_id WHERE p.org_id = $1::uuid AND p.path = $2",
        .{ user.org_id, path_q.? },
    )) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "rule not found");
    };

    const rule_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const path = try req.arena.dupe(u8, try row.get([]const u8, 1));
    const content_hash = try req.arena.dupe(u8, try row.get([]const u8, 2));
    const updated_at = try req.arena.dupe(u8, try row.get([]const u8, 3));
    const source = try req.arena.dupe(u8, try row.get([]const u8, 4));
    row.deinit() catch {};

    var history_result = conn.query(
        "SELECT content_hash, path, merged_at::text, pr_id FROM rule_history WHERE rule_id = $1 ORDER BY merged_at DESC",
        .{rule_id},
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
        .rule_id = rule_id,
        .path = path,
        .content_hash = content_hash,
        .updated_at = updated_at,
        .source = source,
        .history = history.items,
    }, .{});
}

pub fn handleGetRuleContent(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "library:read", res)) return;

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const rule_id_q = qs.get("rule_id");
    const path_q = qs.get("path");
    if (rule_id_q == null and path_q == null) {
        return apiError(res, 400, "BAD_REQUEST", "rule_id or path query parameter is required");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = (if (rule_id_q) |pid| conn.row(
        "SELECT rule_id, content_hash, content, path FROM rules WHERE org_id = $1::uuid AND rule_id = $2",
        .{ user.org_id, pid },
    ) else conn.row(
        "SELECT rule_id, content_hash, content, path FROM rules WHERE org_id = $1::uuid AND path = $2",
        .{ user.org_id, path_q.? },
    )) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "rule not found");
    };

    const content_hash = try req.arena.dupe(u8, try row.get([]const u8, 1));

    if (req.header("if-none-match")) |etag| {
        if (std.mem.eql(u8, etag, content_hash)) {
            row.deinit() catch {};
            res.status = 304;
            return;
        }
    }

    const rule_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const body = try req.arena.dupe(u8, try row.get([]const u8, 2));
    const path = try req.arena.dupe(u8, try row.get([]const u8, 3));
    row.deinit() catch {};

    res.header("ETag", content_hash);
    try res.json(RuleContentResponse{
        .rule_id = rule_id,
        .path = path,
        .content_hash = content_hash,
        .body = body,
    }, .{});
}

/// Batch rule content fetch. Clients (notably `clumsies sync`)
/// send a list of rule_ids in one POST; the response carries a
/// per-id item, each either populated or tagged with a per-item
/// error. A single fetch replaces what used to be N sequential GETs
/// and dominates sync wall time over tunneled links.
pub fn handleBatchRuleContent(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "library:read", res)) return;

    const body = req.json(BatchRuleContentRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (body.rule_ids.len > BATCH_MAX_IDS) {
        return apiError(res, 400, "BAD_REQUEST", "too many rule_ids");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var items: std.ArrayList(BatchRuleItem) = .empty;
    for (body.rule_ids) |rule_id| {
        // Distinguish query failure (INTERNAL_ERROR) from a missing
        // row (NOT_FOUND). Previously both collapsed into NOT_FOUND,
        // so a transient database outage presented to the client as
        // "every rule is missing" — misleading and impossible to
        // debug without server logs.
        const row_result = conn.row(
            "SELECT rule_id, content_hash, content, path FROM rules WHERE org_id = $1::uuid AND rule_id = $2",
            .{ user.org_id, rule_id },
        ) catch {
            try items.append(req.arena, .{
                .rule_id = try req.arena.dupe(u8, rule_id),
                .@"error" = "INTERNAL_ERROR",
            });
            continue;
        };
        var row = row_result orelse {
            try items.append(req.arena, .{
                .rule_id = try req.arena.dupe(u8, rule_id),
                .@"error" = "NOT_FOUND",
            });
            continue;
        };
        // Defer the release so a row.get / dupe failure mid-iteration
        // still returns the pg row handle to the pool.
        defer row.deinit() catch {};

        const pid = try req.arena.dupe(u8, try row.get([]const u8, 0));
        const content_hash = try req.arena.dupe(u8, try row.get([]const u8, 1));
        const content = try req.arena.dupe(u8, try row.get([]const u8, 2));
        const path = try req.arena.dupe(u8, try row.get([]const u8, 3));
        try items.append(req.arena, .{
            .rule_id = pid,
            .path = path,
            .content_hash = content_hash,
            .body = content,
        });
    }

    try res.json(BatchRuleContentResponse{ .items = items.items }, .{});
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

    var result = conn.query(
        \\SELECT b.name, b.description, b.updated_at::text, count(bp.rule_id)::bigint
        \\FROM bundles b
        \\LEFT JOIN bundle_rules bp ON bp.bundle_id = b.bundle_id
        \\WHERE b.org_id = $1::uuid
        \\GROUP BY b.bundle_id, b.name, b.description, b.updated_at
        \\ORDER BY b.name
    ,
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
            .rule_count = try row.get(i64, 3),
        });
    }

    try res.json(BundleListResponse{ .bundles = list.items }, .{});
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

    var rule_result = conn.query(
        "SELECT rule_id FROM bundle_rules WHERE bundle_id = $1",
        .{bundle_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer rule_result.deinit();

    var ids: std.ArrayList([]const u8) = .empty;
    while (try rule_result.next()) |prow| {
        try ids.append(req.arena, try req.arena.dupe(u8, try prow.get([]const u8, 0)));
    }

    try res.json(.{
        .name = bundle_name,
        .description = description,
        .rule_ids = ids.items,
        .created_at = created_at,
        .updated_at = updated_at,
    }, .{});
}

const CreateBundleRequest = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    rule_ids: []const []const u8,
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

    // Validate all rule_ids exist
    for (body.rule_ids) |pid| {
        var exists = conn.row(
            "SELECT 1 FROM rules WHERE org_id = $1::uuid AND rule_id = $2",
            .{ user.org_id, pid },
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        if (exists) |*r| {
            r.deinit() catch {};
        } else {
            return apiError(res, 400, "BAD_REQUEST", "rule_id not found in Library");
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

    for (body.rule_ids) |pid| {
        _ = conn.exec(
            "INSERT INTO bundle_rules (bundle_id, rule_id) VALUES ($1, $2)",
            .{ bundle_id, pid },
        ) catch {};
    }

    res.status = 201;
    try res.json(.{
        .name = body.name,
        .description = desc,
        .rule_ids = body.rule_ids,
    }, .{});
}

const UpdateBundleRequest = struct {
    description: ?[]const u8 = null,
    rule_ids: ?[]const []const u8 = null,
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

    // Replace rule_ids if provided
    if (body.rule_ids) |pids| {
        for (pids) |pid| {
            var exists2 = conn.row(
                "SELECT 1 FROM rules WHERE org_id = $1::uuid AND rule_id = $2",
                .{ user.org_id, pid },
            ) catch {
                return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            };
            if (exists2) |*r| {
                r.deinit() catch {};
            } else {
                return apiError(res, 400, "BAD_REQUEST", "rule_id not found in Library");
            }
        }

        _ = conn.exec("DELETE FROM bundle_rules WHERE bundle_id = $1", .{bundle_id}) catch {};
        for (pids) |pid| {
            _ = conn.exec(
                "INSERT INTO bundle_rules (bundle_id, rule_id) VALUES ($1, $2)",
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

    _ = conn.exec("DELETE FROM bundle_rules WHERE bundle_id = $1", .{bundle_id}) catch {};
    _ = conn.exec("DELETE FROM bundles WHERE bundle_id = $1", .{bundle_id}) catch {};

    res.status = 204;
}
