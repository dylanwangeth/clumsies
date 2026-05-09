//! Hub collaboration endpoints. Implements the Pull Request lifecycle: create PR from workspace
//! local edit, list/get PR details, add review comments, accept/reject, and track PR operations
//! (add/modify/delete rules). PRs are the only path for changes to enter the Artifact.
const std = @import("std");
const httpz = @import("httpz");
const collab_api = @import("clumsies_lib").protocol.collab_api;
const util_hash = @import("clumsies_lib").util.hash;
const Server = @import("server.zig");
const auth = @import("auth.zig");
const db_mod = @import("db.zig");
const apiError = @import("api_error.zig").send;
const RulePrComment = collab_api.RulePrComment;
const RulePrCommentsResponse = collab_api.RulePrCommentsResponse;
const RulePrDetailResponse = collab_api.RulePrDetailResponse;
const RulePrListItem = collab_api.RulePrListItem;
const RulePrListResponse = collab_api.RulePrListResponse;
const RulePrChange = collab_api.RulePrChange;
const RulePrUsageSummary = collab_api.RulePrUsageSummary;

const Operation = struct {
    type: []const u8,
    rule_id: ?[]const u8 = null,
    base_hash: ?[]const u8 = null,
    content: ?[]const u8 = null,
    path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
};

const CreatePrRequest = struct {
    title: []const u8,
    body: []const u8,
    operations: []const Operation,
};

pub fn handleCreatePr(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "pr:write", res)) return;

    const req_body = req.json(CreatePrRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (req_body.title.len == 0) {
        return apiError(res, 400, "BAD_REQUEST", "title is required");
    }

    if (req_body.operations.len == 0) {
        return apiError(res, 400, "BAD_REQUEST", "operations array must not be empty");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    for (req_body.operations, 0..) |op, idx| {
        if (!isValidType(op.type)) {
            return apiError(res, 400, "BAD_REQUEST", "operation type is not supported");
        }
        if (!try validateOperation(conn, user.org_id, op, req_body.operations, idx, res)) return;
    }

    if (!try validateNoIntraPrPathConflict(req.arena, req_body.operations, res)) return;

    const derived_base_contents = try req.arena.alloc(?[]const u8, req_body.operations.len);
    for (req_body.operations, 0..) |op, idx| {
        derived_base_contents[idx] = try deriveRuleBaseContent(conn, req.arena, user.org_id, op, res);
    }

    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var id_buf: [20]u8 = undefined;
    @memcpy(id_buf[0..4], "ppr-");
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        id_buf[4 + i * 2] = hex_chars[byte >> 4];
        id_buf[4 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    const pr_id: []const u8 = &id_buf;

    _ = conn.exec(
        \\INSERT INTO rule_prs (pr_id, org_id, author_id, title, body)
        \\VALUES ($1, $2::uuid, $3, $4, $5)
    , .{ pr_id, user.org_id, user.user_id, req_body.title, req_body.body }) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to create rule PR");
    };

    for (req_body.operations, 0..) |op, idx| {
        const target_path: ?[]const u8 = if (std.mem.eql(u8, op.type, "rename"))
            op.new_path
        else if (std.mem.eql(u8, op.type, "create"))
            op.path
        else if (std.mem.eql(u8, op.type, "bundle_create") or
            std.mem.eql(u8, op.type, "bundle_add") or
            std.mem.eql(u8, op.type, "bundle_remove"))
            op.path
        else
            null;

        _ = conn.exec(
            \\INSERT INTO rule_pr_operations (pr_id, op_index, type, rule_id, base_hash, base_content, content, path)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        , .{
            pr_id,
            @as(i32, @intCast(idx)),
            op.type,
            op.rule_id,
            op.base_hash,
            derived_base_contents[idx],
            op.content,
            target_path,
        }) catch {
            _ = conn.exec("DELETE FROM rule_prs WHERE pr_id = $1", .{pr_id}) catch {};
            return apiError(res, 500, "INTERNAL_ERROR", "failed to store operation");
        };
    }

    res.status = 201;
    try res.json(.{
        .pr_id = pr_id,
        .status = "open",
    }, .{});
}

fn isValidType(t: []const u8) bool {
    return std.mem.eql(u8, t, "modify") or
        std.mem.eql(u8, t, "rename") or
        std.mem.eql(u8, t, "create") or
        std.mem.eql(u8, t, "delete") or
        std.mem.eql(u8, t, "bundle_create") or
        std.mem.eql(u8, t, "bundle_add") or
        std.mem.eql(u8, t, "bundle_remove");
}

fn validateOperation(conn: anytype, org_id: []const u8, op: Operation, ops: []const Operation, op_index: usize, res: *httpz.Response) !bool {
    if (std.mem.eql(u8, op.type, "modify")) {
        const pid = op.rule_id orelse {
            try apiError(res, 400, "BAD_REQUEST", "modify requires rule_id");
            return false;
        };
        const base_hash = op.base_hash orelse {
            try apiError(res, 400, "BAD_REQUEST", "modify requires base_hash");
            return false;
        };
        const content = op.content orelse {
            try apiError(res, 400, "BAD_REQUEST", "modify requires content");
            return false;
        };
        db_mod.validateContentFormat(content) catch {
            try apiError(res, 422, "INVALID_FORMAT", "content must have a heading, description paragraph, and at least one section");
            return false;
        };
        return try verifyPromptBaseHash(conn, org_id, pid, base_hash, res);
    } else if (std.mem.eql(u8, op.type, "rename")) {
        const pid = op.rule_id orelse {
            try apiError(res, 400, "BAD_REQUEST", "rename requires rule_id");
            return false;
        };
        const base_hash = op.base_hash orelse {
            try apiError(res, 400, "BAD_REQUEST", "rename requires base_hash");
            return false;
        };
        const new_path = op.new_path orelse {
            try apiError(res, 400, "BAD_REQUEST", "rename requires new_path");
            return false;
        };
        if (op.content) |content| {
            db_mod.validateContentFormat(content) catch {
                try apiError(res, 422, "INVALID_FORMAT", "content must have a heading, description paragraph, and at least one section");
                return false;
            };
        }
        if (!try verifyPromptBaseHash(conn, org_id, pid, base_hash, res)) return false;
        return try verifyPathAvailable(conn, org_id, new_path, pid, res);
    } else if (std.mem.eql(u8, op.type, "create")) {
        const path = op.path orelse {
            try apiError(res, 400, "BAD_REQUEST", "create requires path");
            return false;
        };
        const content = op.content orelse {
            try apiError(res, 400, "BAD_REQUEST", "create requires content");
            return false;
        };
        db_mod.validateContentFormat(content) catch {
            try apiError(res, 422, "INVALID_FORMAT", "content must have a heading, description paragraph, and at least one section");
            return false;
        };
        return try verifyPathAvailable(conn, org_id, path, null, res);
    } else if (std.mem.eql(u8, op.type, "delete")) {
        const pid = op.rule_id orelse {
            try apiError(res, 400, "BAD_REQUEST", "delete requires rule_id");
            return false;
        };
        var row = conn.row(
            "SELECT 1 FROM rules WHERE org_id = $1::uuid AND rule_id = $2",
            .{ org_id, pid },
        ) catch {
            try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            return false;
        };
        if (row) |*r| {
            r.deinit() catch {};
            return true;
        }
        try apiError(res, 404, "NOT_FOUND", "rule not found");
        return false;
    } else if (std.mem.eql(u8, op.type, "bundle_create")) {
        const bundle_name = op.path orelse {
            try apiError(res, 400, "BAD_REQUEST", "bundle_create requires bundle name");
            return false;
        };
        return try verifyBundleAvailable(conn, org_id, bundle_name, res);
    } else if (std.mem.eql(u8, op.type, "bundle_add") or std.mem.eql(u8, op.type, "bundle_remove")) {
        const pid = op.rule_id orelse {
            try apiError(res, 400, "BAD_REQUEST", "bundle operation requires rule_id");
            return false;
        };
        const bundle_name = op.path orelse {
            try apiError(res, 400, "BAD_REQUEST", "bundle operation requires bundle name");
            return false;
        };
        if (!try verifyRuleExists(conn, org_id, pid, res)) return false;
        if (std.mem.eql(u8, op.type, "bundle_add") and createsBundleEarlierInPr(ops, op_index, bundle_name)) return true;
        if (!try verifyBundleExists(conn, org_id, bundle_name, res)) return false;
        return true;
    }
    return false;
}

fn createsBundleEarlierInPr(ops: []const Operation, current_index: usize, bundle_name: []const u8) bool {
    for (ops[0..current_index]) |op| {
        if (!std.mem.eql(u8, op.type, "bundle_create")) continue;
        if (op.path) |path| {
            if (std.mem.eql(u8, path, bundle_name)) return true;
        }
    }
    return false;
}

fn verifyRuleExists(conn: anytype, org_id: []const u8, rule_id: []const u8, res: *httpz.Response) !bool {
    var row = conn.row(
        "SELECT 1 FROM rules WHERE org_id = $1::uuid AND rule_id = $2",
        .{ org_id, rule_id },
    ) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return false;
    };
    if (row) |*r| {
        r.deinit() catch {};
        return true;
    }
    try apiError(res, 404, "NOT_FOUND", "rule not found");
    return false;
}

fn verifyBundleExists(conn: anytype, org_id: []const u8, bundle_name: []const u8, res: *httpz.Response) !bool {
    var row = conn.row(
        "SELECT 1 FROM bundles WHERE org_id = $1::uuid AND name = $2",
        .{ org_id, bundle_name },
    ) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return false;
    };
    if (row) |*r| {
        r.deinit() catch {};
        return true;
    }
    try apiError(res, 404, "NOT_FOUND", "bundle not found");
    return false;
}

fn verifyBundleAvailable(conn: anytype, org_id: []const u8, bundle_name: []const u8, res: *httpz.Response) !bool {
    var row = conn.row(
        "SELECT 1 FROM bundles WHERE org_id = $1::uuid AND name = $2",
        .{ org_id, bundle_name },
    ) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return false;
    };
    if (row) |*r| {
        r.deinit() catch {};
        try apiError(res, 409, "CONFLICT", "bundle already exists");
        return false;
    }
    return true;
}

fn verifyPromptBaseHash(conn: anytype, org_id: []const u8, rule_id: []const u8, base_hash: []const u8, res: *httpz.Response) !bool {
    var row = conn.row(
        "SELECT content_hash FROM rules WHERE org_id = $1::uuid AND rule_id = $2",
        .{ org_id, rule_id },
    ) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return false;
    } orelse {
        try apiError(res, 404, "NOT_FOUND", "rule not found");
        return false;
    };
    const current_hash_raw = row.get([]const u8, 0) catch {
        row.deinit() catch {};
        try apiError(res, 500, "INTERNAL_ERROR", "failed to read rule hash");
        return false;
    };
    var buf: [96]u8 = undefined;
    const len = @min(current_hash_raw.len, buf.len);
    @memcpy(buf[0..len], current_hash_raw[0..len]);
    row.deinit() catch {};
    if (!std.mem.eql(u8, buf[0..len], base_hash)) {
        try apiError(res, 409, "CONFLICT", "base_hash does not match current Artifact version");
        return false;
    }
    return true;
}

fn deriveRuleBaseContent(conn: anytype, allocator: std.mem.Allocator, org_id: []const u8, op: Operation, res: *httpz.Response) !?[]const u8 {
    if (std.mem.eql(u8, op.type, "create")) return null;
    if (std.mem.eql(u8, op.type, "bundle_create") or
        std.mem.eql(u8, op.type, "bundle_add") or
        std.mem.eql(u8, op.type, "bundle_remove")) return null;
    const rule_id = op.rule_id orelse return null;

    var row = conn.row(
        "SELECT content_hash, content FROM rules WHERE org_id = $1::uuid AND rule_id = $2",
        .{ org_id, rule_id },
    ) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return error.ResponseWritten;
    } orelse {
        try apiError(res, 404, "NOT_FOUND", "rule not found");
        return error.ResponseWritten;
    };
    defer row.deinit() catch {};

    const current_hash = row.get([]const u8, 0) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "failed to read rule hash");
        return error.ResponseWritten;
    };
    if (op.base_hash) |base_hash| {
        if (!std.mem.eql(u8, current_hash, base_hash)) {
            try apiError(res, 409, "CONFLICT", "base_hash does not match current Artifact version");
            return error.ResponseWritten;
        }
    }

    const content = row.get([]const u8, 1) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "failed to read rule content");
        return error.ResponseWritten;
    };
    return try allocator.dupe(u8, content);
}

fn verifyPathAvailable(conn: anytype, org_id: []const u8, path: []const u8, allow_rule_id: ?[]const u8, res: *httpz.Response) !bool {
    var row = conn.row(
        "SELECT rule_id FROM rules WHERE org_id = $1::uuid AND path = $2",
        .{ org_id, path },
    ) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return false;
    };
    if (row) |*r| {
        defer r.deinit() catch {};
        const existing_pid = r.get([]const u8, 0) catch "";
        if (allow_rule_id) |allowed| {
            if (std.mem.eql(u8, existing_pid, allowed)) return true;
        }
        try apiError(res, 409, "CONFLICT", "target path already exists in Artifact");
        return false;
    }
    return true;
}

fn validateNoIntraPrPathConflict(arena: std.mem.Allocator, ops: []const Operation, res: *httpz.Response) !bool {
    var seen: std.ArrayList([]const u8) = .empty;
    for (ops) |op| {
        const p: ?[]const u8 = if (std.mem.eql(u8, op.type, "create"))
            op.path
        else if (std.mem.eql(u8, op.type, "rename"))
            op.new_path
        else
            null;
        const path = p orelse continue;
        for (seen.items) |prev| {
            if (std.mem.eql(u8, prev, path)) {
                try apiError(res, 400, "BAD_REQUEST", "two operations target the same path in one PR");
                return false;
            }
        }
        try seen.append(arena, path);
    }
    return true;
}

pub fn handleListPrs(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "pr:read", res)) return;

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query");
    };
    const status_filter = qs.get("status");
    const rule_filter = qs.get("rule_id");

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var list: std.ArrayList(RulePrListItem) = .empty;

    const base_sql =
        \\SELECT pp.pr_id, pp.status, pp.title, pp.body, pp.created_at::text, u.username,
        \\  (SELECT count(*) FROM rule_pr_operations op WHERE op.pr_id = pp.pr_id) as op_count,
        \\  COALESCE((
        \\    SELECT op.type
        \\    FROM rule_pr_operations op
        \\    WHERE op.pr_id = pp.pr_id
        \\    ORDER BY op.op_index
        \\    LIMIT 1
        \\  ), '') as op_type,
        \\  (SELECT count(*) FROM rule_pr_comments c WHERE c.pr_id = pp.pr_id) as comment_count
        \\FROM rule_prs pp JOIN users u ON u.user_id = pp.author_id
    ;

    if (status_filter != null and rule_filter != null) {
        var result = conn.query(base_sql ++
            \\ WHERE pp.org_id = $1::uuid AND pp.status = $2
            \\ AND pp.pr_id IN (SELECT pr_id FROM rule_pr_operations WHERE rule_id = $3)
            \\ ORDER BY pp.created_at DESC
        , .{ user.org_id, status_filter.?, rule_filter.? }) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        defer result.deinit();
        while (try result.next()) |row| {
            try list.append(req.arena, .{
                .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                .status = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                .title = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                .body = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
                .author = try req.arena.dupe(u8, try row.get([]const u8, 5)),
                .operation_count = try row.get(i64, 6),
                .op_type = try req.arena.dupe(u8, try row.get([]const u8, 7)),
                .comment_count = try row.get(i64, 8),
            });
        }
    } else if (status_filter) |sf| {
        var result = conn.query(base_sql ++
            \\ WHERE pp.org_id = $1::uuid AND pp.status = $2
            \\ ORDER BY pp.created_at DESC
        , .{ user.org_id, sf }) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        defer result.deinit();
        while (try result.next()) |row| {
            try list.append(req.arena, .{
                .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                .status = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                .title = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                .body = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
                .author = try req.arena.dupe(u8, try row.get([]const u8, 5)),
                .operation_count = try row.get(i64, 6),
                .op_type = try req.arena.dupe(u8, try row.get([]const u8, 7)),
                .comment_count = try row.get(i64, 8),
            });
        }
    } else if (rule_filter) |pf| {
        var result = conn.query(base_sql ++
            \\ WHERE pp.org_id = $1::uuid
            \\ AND pp.pr_id IN (SELECT pr_id FROM rule_pr_operations WHERE rule_id = $2)
            \\ ORDER BY pp.created_at DESC
        , .{ user.org_id, pf }) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        defer result.deinit();
        while (try result.next()) |row| {
            try list.append(req.arena, .{
                .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                .status = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                .title = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                .body = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
                .author = try req.arena.dupe(u8, try row.get([]const u8, 5)),
                .operation_count = try row.get(i64, 6),
                .op_type = try req.arena.dupe(u8, try row.get([]const u8, 7)),
                .comment_count = try row.get(i64, 8),
            });
        }
    } else {
        var result = conn.query(base_sql ++
            \\ WHERE pp.org_id = $1::uuid
            \\ ORDER BY pp.created_at DESC
        , .{user.org_id}) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        defer result.deinit();
        while (try result.next()) |row| {
            try list.append(req.arena, .{
                .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                .status = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                .title = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                .body = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
                .author = try req.arena.dupe(u8, try row.get([]const u8, 5)),
                .operation_count = try row.get(i64, 6),
                .op_type = try req.arena.dupe(u8, try row.get([]const u8, 7)),
                .comment_count = try row.get(i64, 8),
            });
        }
    }

    try res.json(RulePrListResponse{ .prs = list.items }, .{});
}

pub fn handleGetPr(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "pr:read", res)) return;

    const id = req.param("id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT pr_id, status, title, body, created_at::text FROM rule_prs WHERE pr_id = $1 AND org_id = $2::uuid",
        .{ id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "rule PR not found");
    };

    const pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const status = try req.arena.dupe(u8, try row.get([]const u8, 1));
    const pr_title = try req.arena.dupe(u8, try row.get([]const u8, 2));
    const pr_body = try req.arena.dupe(u8, try row.get([]const u8, 3));
    const created_at = try req.arena.dupe(u8, try row.get([]const u8, 4));
    row.deinit() catch {};

    var ops: std.ArrayList(RulePrChange) = .empty;
    var op_result = conn.query(
        "SELECT op_index, type, rule_id, base_hash, base_content, content, path FROM rule_pr_operations WHERE pr_id = $1 ORDER BY op_index",
        .{pr_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer op_result.deinit();

    while (try op_result.next()) |orow| {
        const op_index = try orow.get(i32, 0);
        const op_type = try req.arena.dupe(u8, try orow.get([]const u8, 1));
        const op_rule_id: ?[]const u8 = if (orow.get([]const u8, 2)) |v|
            try req.arena.dupe(u8, v)
        else |_|
            null;
        const op_base_hash: ?[]const u8 = if (orow.get([]const u8, 3)) |v|
            try req.arena.dupe(u8, v)
        else |_|
            null;
        const op_base_content: ?[]const u8 = if (orow.get([]const u8, 4)) |v|
            try req.arena.dupe(u8, v)
        else |_|
            null;
        const op_content: ?[]const u8 = if (orow.get([]const u8, 5)) |v|
            try req.arena.dupe(u8, v)
        else |_|
            null;
        const op_path: ?[]const u8 = if (orow.get([]const u8, 6)) |v|
            try req.arena.dupe(u8, v)
        else |_|
            null;

        try ops.append(req.arena, .{
            .op_index = op_index,
            .type = op_type,
            .rule_id = op_rule_id,
            .base_hash = op_base_hash,
            .content = op_content,
            .path = op_path,
            .base_content = op_base_content,
        });
    }

    var attestation_summary = RulePrUsageSummary{};

    var attestation_row = conn.row(
        \\SELECT count(*), count(DISTINCT session_id), max(to_timestamp(timestamp/1000))::text
        \\FROM attestation_events
        \\WHERE rule_id IN (SELECT rule_id FROM rule_pr_operations WHERE pr_id = $1 AND rule_id IS NOT NULL)
        \\  AND type = 'refer'
    , .{pr_id}) catch null;
    if (attestation_row) |*tr| {
        attestation_summary.refer_count = tr.get(i64, 0) catch 0;
        attestation_summary.sessions_used = tr.get(i64, 1) catch 0;
        if (tr.get(?[]const u8, 2) catch null) |last_ref| {
            attestation_summary.last_referred = req.arena.dupe(u8, last_ref) catch null;
        }
        tr.deinit() catch {};
    }

    try res.json(RulePrDetailResponse{
        .pr_id = pr_id,
        .status = status,
        .title = pr_title,
        .body = pr_body,
        .created_at = created_at,
        .operations = ops.items,
        .attestation_summary = attestation_summary,
    }, .{});
}

const ActionRequest = struct {
    action: []const u8,
    reason: ?[]const u8 = null,
};

pub fn handleUpdatePr(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "pr:merge", res)) return;

    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "only maintainers can accept or reject rule PRs");
    }

    const id = req.param("id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "id is required");
    };

    const body = req.json(ActionRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (!std.mem.eql(u8, body.action, "accept") and !std.mem.eql(u8, body.action, "reject")) {
        return apiError(res, 400, "BAD_REQUEST", "action must be 'accept' or 'reject'");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var header = conn.row(
        "SELECT status FROM rule_prs WHERE pr_id = $1 AND org_id = $2::uuid",
        .{ id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "rule PR not found");
    };
    const status_raw = header.get([]const u8, 0) catch "";
    var status_buf: [32]u8 = undefined;
    const status_len = @min(status_raw.len, status_buf.len);
    @memcpy(status_buf[0..status_len], status_raw[0..status_len]);
    header.deinit() catch {};
    if (!std.mem.eql(u8, status_buf[0..status_len], "open")) {
        return apiError(res, 400, "BAD_REQUEST", "rule PR is not open");
    }

    const is_accept = std.mem.eql(u8, body.action, "accept");

    if (is_accept) {
        if (!try applyPr(conn, req.arena, user.org_id, id, res)) return;
    } else {
        _ = conn.exec(
            "UPDATE rule_prs SET status = 'rejected', updated_at = now() WHERE pr_id = $1",
            .{id},
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "failed to update rule PR");
        };
    }

    try res.json(.{
        .pr_id = id,
        .status = if (is_accept) @as([]const u8, "accepted") else @as([]const u8, "rejected"),
    }, .{});
}

const LoadedOp = struct {
    op_index: i32,
    type: []const u8,
    rule_id: ?[]const u8,
    base_hash: ?[]const u8,
    content: ?[]const u8,
    path: ?[]const u8,
};

fn applyPr(conn: anytype, arena: std.mem.Allocator, org_id: []const u8, pr_id: []const u8, res: *httpz.Response) !bool {
    var ops: std.ArrayList(LoadedOp) = .empty;
    {
        var op_result = conn.query(
            "SELECT op_index, type, rule_id, base_hash, content, path FROM rule_pr_operations WHERE pr_id = $1 ORDER BY op_index",
            .{pr_id},
        ) catch {
            try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            return false;
        };
        defer op_result.deinit();
        while (try op_result.next()) |r| {
            const op_index = r.get(i32, 0) catch continue;
            const t = arena.dupe(u8, r.get([]const u8, 1) catch "") catch continue;
            const pid: ?[]const u8 = if (r.get([]const u8, 2)) |v|
                arena.dupe(u8, v) catch null
            else |_|
                null;
            const bh: ?[]const u8 = if (r.get([]const u8, 3)) |v|
                arena.dupe(u8, v) catch null
            else |_|
                null;
            const c: ?[]const u8 = if (r.get([]const u8, 4)) |v|
                arena.dupe(u8, v) catch null
            else |_|
                null;
            const p: ?[]const u8 = if (r.get([]const u8, 5)) |v|
                arena.dupe(u8, v) catch null
            else |_|
                null;
            try ops.append(arena, .{
                .op_index = op_index,
                .type = t,
                .rule_id = pid,
                .base_hash = bh,
                .content = c,
                .path = p,
            });
        }
    }

    conn.begin() catch {
        try apiError(res, 500, "INTERNAL_ERROR", "failed to begin transaction");
        return false;
    };

    for (ops.items) |op| {
        if (std.mem.eql(u8, op.type, "modify")) {
            const pid = op.rule_id.?;
            const bh = op.base_hash.?;
            const new_content = op.content.?;
            db_mod.validateContentFormat(new_content) catch {
                conn.rollback() catch {};
                try apiError(res, 422, "INVALID_FORMAT", "content must have an H1 heading, a description paragraph, and at least one H2 section");
                return false;
            };
            var row = conn.row(
                "SELECT content_hash, path FROM rules WHERE rule_id = $1",
                .{pid},
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
                return false;
            } orelse {
                conn.rollback() catch {};
                try apiError(res, 404, "NOT_FOUND", "target rule no longer exists");
                return false;
            };
            const current_hash = row.get([]const u8, 0) catch {
                row.deinit() catch {};
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "failed to read rule hash");
                return false;
            };
            const matches = std.mem.eql(u8, current_hash, bh);
            const current_path_raw = row.get([]const u8, 1) catch "";
            var path_buf: [512]u8 = undefined;
            const plen = @min(current_path_raw.len, path_buf.len);
            @memcpy(path_buf[0..plen], current_path_raw[0..plen]);
            row.deinit() catch {};
            if (!matches) {
                conn.rollback() catch {};
                try apiError(res, 409, "CONFLICT", "Artifact has changed since PR was created");
                return false;
            }
            const new_hash = util_hash.contentHash(new_content);
            const hash_slice: []const u8 = arena.dupe(u8, &new_hash) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "alloc failed");
                return false;
            };
            _ = conn.exec(
                "UPDATE rules SET content = $1, content_hash = $2, description = $3, updated_at = now() WHERE rule_id = $4",
                .{ new_content, hash_slice, db_mod.extractDescription(new_content), pid },
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "failed to update rule");
                return false;
            };
            _ = conn.exec(
                "INSERT INTO rule_history (rule_id, content_hash, path, content, pr_id) VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING",
                .{ pid, hash_slice, path_buf[0..plen], new_content, pr_id },
            ) catch {};
            bumpWorkspaceRevisions(conn, pid);
        } else if (std.mem.eql(u8, op.type, "rename")) {
            const pid = op.rule_id.?;
            const bh = op.base_hash.?;
            const new_path = op.path.?;
            var row = conn.row(
                "SELECT content_hash FROM rules WHERE rule_id = $1",
                .{pid},
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
                return false;
            } orelse {
                conn.rollback() catch {};
                try apiError(res, 404, "NOT_FOUND", "target rule no longer exists");
                return false;
            };
            const current_hash = row.get([]const u8, 0) catch "";
            const matches = std.mem.eql(u8, current_hash, bh);
            row.deinit() catch {};
            if (!matches) {
                conn.rollback() catch {};
                try apiError(res, 409, "CONFLICT", "Artifact has changed since PR was created");
                return false;
            }
            if (op.content) |new_content| {
                db_mod.validateContentFormat(new_content) catch {
                    conn.rollback() catch {};
                    try apiError(res, 422, "INVALID_FORMAT", "content must have an H1 heading, a description paragraph, and at least one H2 section");
                    return false;
                };
                const new_hash = util_hash.contentHash(new_content);
                const hash_slice: []const u8 = arena.dupe(u8, &new_hash) catch {
                    conn.rollback() catch {};
                    try apiError(res, 500, "INTERNAL_ERROR", "alloc failed");
                    return false;
                };
                _ = conn.exec(
                    "UPDATE rules SET path = $1, content = $2, content_hash = $3, description = $4, updated_at = now() WHERE rule_id = $5",
                    .{ new_path, new_content, hash_slice, db_mod.extractDescription(new_content), pid },
                ) catch {
                    conn.rollback() catch {};
                    try apiError(res, 500, "INTERNAL_ERROR", "failed to update rule");
                    return false;
                };
                _ = conn.exec(
                    "INSERT INTO rule_history (rule_id, content_hash, path, content, pr_id) VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING",
                    .{ pid, hash_slice, new_path, new_content, pr_id },
                ) catch {};
            } else {
                _ = conn.exec(
                    "UPDATE rules SET path = $1, updated_at = now() WHERE rule_id = $2",
                    .{ new_path, pid },
                ) catch {
                    conn.rollback() catch {};
                    try apiError(res, 500, "INTERNAL_ERROR", "failed to update rule");
                    return false;
                };
            }
            bumpWorkspaceRevisions(conn, pid);
        } else if (std.mem.eql(u8, op.type, "create")) {
            const path = op.path.?;
            const new_content = op.content.?;
            db_mod.validateContentFormat(new_content) catch {
                conn.rollback() catch {};
                try apiError(res, 422, "INVALID_FORMAT", "content must have an H1 heading, a description paragraph, and at least one H2 section");
                return false;
            };
            var rand_bytes: [16]u8 = undefined;
            std.crypto.random.bytes(&rand_bytes);
            var new_pid_buf: [36]u8 = undefined;
            @memcpy(new_pid_buf[0..2], "p-");
            const hex = "0123456789abcdef";
            for (rand_bytes, 0..) |byte, i| {
                new_pid_buf[2 + i * 2] = hex[byte >> 4];
                new_pid_buf[2 + i * 2 + 1] = hex[byte & 0x0f];
            }
            const new_pid: []const u8 = arena.dupe(u8, new_pid_buf[0..34]) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "alloc failed");
                return false;
            };
            const new_hash = util_hash.contentHash(new_content);
            const hash_slice: []const u8 = arena.dupe(u8, &new_hash) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "alloc failed");
                return false;
            };
            _ = conn.exec(
                "INSERT INTO rules (rule_id, org_id, path, content, content_hash, description) VALUES ($1, $2::uuid, $3, $4, $5, $6)",
                .{ new_pid, org_id, path, new_content, hash_slice, db_mod.extractDescription(new_content) },
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 409, "CONFLICT", "target path conflict on create");
                return false;
            };
            _ = conn.exec(
                "INSERT INTO rule_history (rule_id, content_hash, path, content, pr_id) VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING",
                .{ new_pid, hash_slice, path, new_content, pr_id },
            ) catch {};
        } else if (std.mem.eql(u8, op.type, "delete")) {
            const pid = op.rule_id.?;
            _ = conn.exec("DELETE FROM workspace_rules WHERE rule_id = $1", .{pid}) catch {};
            _ = conn.exec("DELETE FROM bundle_rules WHERE rule_id = $1", .{pid}) catch {};
            _ = conn.exec("DELETE FROM rules WHERE rule_id = $1", .{pid}) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "failed to delete rule");
                return false;
            };
        } else if (std.mem.eql(u8, op.type, "bundle_create")) {
            const bundle_name = op.path.?;
            const bundle_id = try generateBundleId(arena);
            _ = conn.exec(
                "INSERT INTO bundles (bundle_id, org_id, name, description) VALUES ($1, $2::uuid, $3, '')",
                .{ bundle_id, org_id, bundle_name },
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 409, "CONFLICT", "failed to create bundle");
                return false;
            };
        } else if (std.mem.eql(u8, op.type, "bundle_add")) {
            const pid = op.rule_id.?;
            const bundle_name = op.path.?;
            const bundle_id = try loadBundleId(conn, arena, org_id, bundle_name, res) orelse {
                conn.rollback() catch {};
                return false;
            };
            _ = conn.exec(
                "INSERT INTO bundle_rules (bundle_id, rule_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                .{ bundle_id, pid },
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "failed to add rule to bundle");
                return false;
            };
        } else if (std.mem.eql(u8, op.type, "bundle_remove")) {
            const pid = op.rule_id.?;
            const bundle_name = op.path.?;
            const bundle_id = try loadBundleId(conn, arena, org_id, bundle_name, res) orelse {
                conn.rollback() catch {};
                return false;
            };
            _ = conn.exec(
                "DELETE FROM bundle_rules WHERE bundle_id = $1 AND rule_id = $2",
                .{ bundle_id, pid },
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "failed to remove rule from bundle");
                return false;
            };
        }
    }

    _ = conn.exec(
        "UPDATE artifact_manifest SET revision = revision + 1 WHERE org_id = $1::uuid",
        .{org_id},
    ) catch {};

    const updated = conn.exec(
        "UPDATE rule_prs SET status = 'accepted', updated_at = now() WHERE pr_id = $1 AND status = 'open'",
        .{pr_id},
    ) catch {
        conn.rollback() catch {};
        try apiError(res, 500, "INTERNAL_ERROR", "failed to update rule PR");
        return false;
    };
    if (updated == null or updated.? == 0) {
        conn.rollback() catch {};
        try apiError(res, 400, "BAD_REQUEST", "rule PR is not open");
        return false;
    }

    conn.commit() catch {
        conn.rollback() catch {};
        try apiError(res, 500, "INTERNAL_ERROR", "failed to commit transaction");
        return false;
    };

    return true;
}

fn generateBundleId(arena: std.mem.Allocator) ![]const u8 {
    var rand_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var buf: [36]u8 = undefined;
    @memcpy(buf[0..4], "bnd-");
    const hex = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        buf[4 + i * 2] = hex[byte >> 4];
        buf[4 + i * 2 + 1] = hex[byte & 0x0f];
    }
    return try arena.dupe(u8, buf[0..36]);
}

fn loadBundleId(
    conn: anytype,
    arena: std.mem.Allocator,
    org_id: []const u8,
    bundle_name: []const u8,
    res: *httpz.Response,
) !?[]const u8 {
    var row = conn.row(
        "SELECT bundle_id FROM bundles WHERE org_id = $1::uuid AND name = $2",
        .{ org_id, bundle_name },
    ) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return null;
    } orelse {
        try apiError(res, 404, "NOT_FOUND", "bundle not found");
        return null;
    };
    defer row.deinit() catch {};
    return try arena.dupe(u8, try row.get([]const u8, 0));
}

fn bumpWorkspaceRevisions(conn: anytype, rule_id: []const u8) void {
    _ = conn.exec(
        "UPDATE workspaces SET revision = revision + 1 WHERE ws_id IN (SELECT ws_id FROM workspace_rules WHERE rule_id = $1)",
        .{rule_id},
    ) catch {};
}

const CommentRequest = struct {
    body: []const u8,
};

pub fn handleAddComment(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "pr:write", res)) return;

    const id = req.param("id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "id is required");
    };

    const comment = req.json(CommentRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var pr_row = conn.row("SELECT pr_id FROM rule_prs WHERE pr_id = $1 AND org_id = $2::uuid", .{ id, user.org_id }) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "rule PR not found");
    };
    pr_row.deinit() catch {};

    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var cmt_id_buf: [20]u8 = undefined;
    @memcpy(cmt_id_buf[0..4], "cmt-");
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        cmt_id_buf[4 + i * 2] = hex_chars[byte >> 4];
        cmt_id_buf[4 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    _ = conn.exec(
        "INSERT INTO rule_pr_comments (comment_id, pr_id, author_id, body) VALUES ($1, $2, $3, $4)",
        .{ &cmt_id_buf, id, user.user_id, comment.body },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to add comment");
    };

    res.status = 201;
    try res.json(.{
        .comment_id = &cmt_id_buf,
        .pr_id = id,
        .author = user.username,
        .body = comment.body,
    }, .{});
}

pub fn handleListComments(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "pr:read", res)) return;

    const id = req.param("id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var pr_check = conn.row("SELECT pr_id FROM rule_prs WHERE pr_id = $1 AND org_id = $2::uuid", .{ id, user.org_id }) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "rule PR not found");
    };
    pr_check.deinit() catch {};

    var result = conn.query(
        \\SELECT c.comment_id, c.author_id, u.username, c.body, c.created_at::text
        \\FROM rule_pr_comments c
        \\JOIN users u ON u.user_id = c.author_id
        \\WHERE c.pr_id = $1
        \\ORDER BY c.created_at
    ,
        .{id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(RulePrComment) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .comment_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .author_id = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .author = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .body = try req.arena.dupe(u8, try row.get([]const u8, 3)),
            .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
        });
    }

    try res.json(RulePrCommentsResponse{ .comments = list.items }, .{});
}
