//! Hub context endpoints. Context is project-specific knowledge (specs, research, ADRs) owned
//! by each workspace independently. These endpoints list, serve, and track context files.
const std = @import("std");
const httpz = @import("httpz");
const util_hash = @import("clumsies_lib").util.hash;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;
const Server = @import("server.zig");
const auth = @import("auth.zig");
const db_mod = @import("db.zig");
const apiError = @import("api_error.zig").send;
const ContextFile = workspace_api.ContextFile;
const ContextFilesResponse = workspace_api.ContextFilesResponse;
const BatchContextContentRequest = workspace_api.BatchContextContentRequest;
const BatchContextContentResponse = workspace_api.BatchContextContentResponse;
const BatchContextItem = workspace_api.BatchContextItem;

const BATCH_MAX_PATHS: usize = 1024;

pub fn handleListFiles(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "workspace:read", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    var result = conn.query(
        "SELECT context_id, path, content_hash, length(content)::bigint, author, updated_at::text FROM workspace_context WHERE ws_id = $1 ORDER BY path",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(ContextFile) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .context_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .path = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .content_hash = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .size = try row.get(i64, 3),
            .author = try req.arena.dupe(u8, try row.get([]const u8, 4)),
            .updated_at = try req.arena.dupe(u8, try row.get([]const u8, 5)),
        });
    }

    try res.json(ContextFilesResponse{ .files = list.items }, .{});
}

/// Batch context content fetch. Paths are scoped to the caller's
/// workspace membership; same-per-item error model as the artifact
/// batch endpoint. TUI and sync both use this endpoint for single and
/// bulk context file loads.
pub fn handleBatchFileContent(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "workspace:read", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const body = req.json(BatchContextContentRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (body.paths.len > BATCH_MAX_PATHS) {
        return apiError(res, 400, "BAD_REQUEST", "too many paths");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    var items: std.ArrayList(BatchContextItem) = .empty;
    for (body.paths) |path| {
        // Same split as the artifact batch handler: a real DB error
        // reports INTERNAL_ERROR, a missing row reports NOT_FOUND.
        // Collapsing both into NOT_FOUND masked transient outages as
        // "every file is missing".
        const row_result = conn.row(
            "SELECT content_hash, content FROM workspace_context WHERE ws_id = $1 AND path = $2",
            .{ ws_id, path },
        ) catch {
            try items.append(req.arena, .{
                .path = try req.arena.dupe(u8, path),
                .@"error" = "INTERNAL_ERROR",
            });
            continue;
        };
        var row = row_result orelse {
            try items.append(req.arena, .{
                .path = try req.arena.dupe(u8, path),
                .@"error" = "NOT_FOUND",
            });
            continue;
        };
        defer row.deinit() catch {};

        const content_hash = try req.arena.dupe(u8, try row.get([]const u8, 0));
        const content = try req.arena.dupe(u8, try row.get([]const u8, 1));
        try items.append(req.arena, .{
            .path = try req.arena.dupe(u8, path),
            .content_hash = content_hash,
            .body = content,
        });
    }

    try res.json(BatchContextContentResponse{ .items = items.items }, .{});
}

const Operation = struct {
    type: []const u8,
    context_id: ?[]const u8 = null,
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
    if (!auth.requireScope(user, "workspace:write", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

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

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    for (req_body.operations) |op| {
        if (!isValidType(op.type)) {
            return apiError(res, 400, "BAD_REQUEST", "operation type must be update, rename, create, or delete");
        }
        if (!try validateOperation(conn, ws_id, op, res)) return;
    }
    if (!try validateNoIntraPrPathConflict(req.arena, req_body.operations, res)) return;

    const derived_base_contents = try req.arena.alloc(?[]const u8, req_body.operations.len);
    for (req_body.operations, 0..) |op, idx| {
        derived_base_contents[idx] = try deriveContextBaseContent(conn, req.arena, ws_id, op, res);
    }

    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var pr_id_buf: [20]u8 = undefined;
    @memcpy(pr_id_buf[0..4], "cpr-");
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        pr_id_buf[4 + i * 2] = hex_chars[byte >> 4];
        pr_id_buf[4 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    const pr_id: []const u8 = &pr_id_buf;

    _ = conn.exec(
        "INSERT INTO context_prs (pr_id, ws_id, author, title, body) VALUES ($1, $2, $3, $4, $5)",
        .{ pr_id, ws_id, user.username, req_body.title, req_body.body },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to create PR");
    };

    for (req_body.operations, 0..) |op, idx| {
        const target_path: ?[]const u8 = if (std.mem.eql(u8, op.type, "rename"))
            op.new_path
        else if (std.mem.eql(u8, op.type, "create"))
            op.path
        else
            null;

        _ = conn.exec(
            \\INSERT INTO context_pr_operations (pr_id, op_index, type, context_id, base_hash, base_content, content, path)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        , .{ pr_id, @as(i32, @intCast(idx)), op.type, op.context_id, op.base_hash, derived_base_contents[idx], op.content, target_path }) catch {
            _ = conn.exec("DELETE FROM context_prs WHERE pr_id = $1", .{pr_id}) catch {};
            return apiError(res, 500, "INTERNAL_ERROR", "failed to store operation");
        };
    }

    res.status = 201;
    try res.json(.{
        .pr_id = pr_id,
        .status = "open",
        .author = user.username,
        .operation_count = @as(i64, @intCast(req_body.operations.len)),
    }, .{});
}

fn isValidType(t: []const u8) bool {
    return std.mem.eql(u8, t, "update") or
        std.mem.eql(u8, t, "rename") or
        std.mem.eql(u8, t, "create") or
        std.mem.eql(u8, t, "delete");
}

fn validateOperation(conn: anytype, ws_id: []const u8, op: Operation, res: *httpz.Response) !bool {
    if (std.mem.eql(u8, op.type, "update")) {
        const cid = op.context_id orelse {
            try apiError(res, 400, "BAD_REQUEST", "update requires context_id");
            return false;
        };
        const base_hash = op.base_hash orelse {
            try apiError(res, 400, "BAD_REQUEST", "update requires base_hash");
            return false;
        };
        const content = op.content orelse {
            try apiError(res, 400, "BAD_REQUEST", "update requires content");
            return false;
        };
        db_mod.validateContentFormat(content) catch {
            try apiError(res, 422, "INVALID_FORMAT", "content must have a heading, description paragraph, and at least one section");
            return false;
        };
        return try verifyContextBaseHash(conn, ws_id, cid, base_hash, res);
    } else if (std.mem.eql(u8, op.type, "rename")) {
        const cid = op.context_id orelse {
            try apiError(res, 400, "BAD_REQUEST", "rename requires context_id");
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
        if (!try verifyContextBaseHash(conn, ws_id, cid, base_hash, res)) return false;
        return try verifyPathAvailable(conn, ws_id, new_path, cid, res);
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
        return try verifyPathAvailable(conn, ws_id, path, null, res);
    } else if (std.mem.eql(u8, op.type, "delete")) {
        const cid = op.context_id orelse {
            try apiError(res, 400, "BAD_REQUEST", "delete requires context_id");
            return false;
        };
        var row = conn.row(
            "SELECT 1 FROM workspace_context WHERE ws_id = $1 AND context_id = $2",
            .{ ws_id, cid },
        ) catch {
            try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            return false;
        };
        if (row) |*r| {
            r.deinit() catch {};
            return true;
        }
        try apiError(res, 404, "NOT_FOUND", "context file not found");
        return false;
    }
    return false;
}

fn verifyContextBaseHash(conn: anytype, ws_id: []const u8, context_id: []const u8, base_hash: []const u8, res: *httpz.Response) !bool {
    var row = conn.row(
        "SELECT content_hash FROM workspace_context WHERE ws_id = $1 AND context_id = $2",
        .{ ws_id, context_id },
    ) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return false;
    } orelse {
        try apiError(res, 404, "NOT_FOUND", "context file not found");
        return false;
    };
    const current_raw = row.get([]const u8, 0) catch {
        row.deinit() catch {};
        try apiError(res, 500, "INTERNAL_ERROR", "failed to read hash");
        return false;
    };
    var buf: [96]u8 = undefined;
    const len = @min(current_raw.len, buf.len);
    @memcpy(buf[0..len], current_raw[0..len]);
    row.deinit() catch {};
    if (!std.mem.eql(u8, buf[0..len], base_hash)) {
        try apiError(res, 409, "CONFLICT", "base_hash does not match current file version");
        return false;
    }
    return true;
}

fn deriveContextBaseContent(conn: anytype, allocator: std.mem.Allocator, ws_id: []const u8, op: Operation, res: *httpz.Response) !?[]const u8 {
    if (std.mem.eql(u8, op.type, "create")) return null;
    const context_id = op.context_id orelse return null;

    var row = conn.row(
        "SELECT content_hash, content FROM workspace_context WHERE ws_id = $1 AND context_id = $2",
        .{ ws_id, context_id },
    ) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return error.ResponseWritten;
    } orelse {
        try apiError(res, 404, "NOT_FOUND", "context file not found");
        return error.ResponseWritten;
    };
    defer row.deinit() catch {};

    const current_hash = row.get([]const u8, 0) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "failed to read hash");
        return error.ResponseWritten;
    };
    if (op.base_hash) |base_hash| {
        if (!std.mem.eql(u8, current_hash, base_hash)) {
            try apiError(res, 409, "CONFLICT", "base_hash does not match current file version");
            return error.ResponseWritten;
        }
    }

    const content = row.get([]const u8, 1) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "failed to read content");
        return error.ResponseWritten;
    };
    return try allocator.dupe(u8, content);
}

fn verifyPathAvailable(conn: anytype, ws_id: []const u8, path: []const u8, allow_context_id: ?[]const u8, res: *httpz.Response) !bool {
    var row = conn.row(
        "SELECT context_id FROM workspace_context WHERE ws_id = $1 AND path = $2",
        .{ ws_id, path },
    ) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return false;
    };
    if (row) |*r| {
        defer r.deinit() catch {};
        const existing = r.get([]const u8, 0) catch "";
        if (allow_context_id) |allowed| {
            if (std.mem.eql(u8, existing, allowed)) return true;
        }
        try apiError(res, 409, "CONFLICT", "target path already exists");
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
    if (!auth.requireScope(user, "workspace:read", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const status_filter = qs.get("status");

    const PrInfo = struct {
        pr_id: []const u8,
        author: []const u8,
        status: []const u8,
        title: []const u8,
        body: []const u8,
        created_at: []const u8,
        operation_count: i64,
    };

    const base_sql =
        \\SELECT pr_id, author, status, title, body, created_at::text,
        \\  (SELECT count(*) FROM context_pr_operations op WHERE op.pr_id = context_prs.pr_id)
        \\FROM context_prs
    ;

    var list: std.ArrayList(PrInfo) = .empty;

    if (status_filter) |sf| {
        var result = conn.query(base_sql ++
            \\ WHERE ws_id = $1 AND status = $2 ORDER BY created_at DESC
        , .{ ws_id, sf }) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        defer result.deinit();
        while (try result.next()) |row| {
            try list.append(req.arena, .{
                .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                .author = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                .status = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                .title = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                .body = try req.arena.dupe(u8, try row.get([]const u8, 4)),
                .created_at = try req.arena.dupe(u8, try row.get([]const u8, 5)),
                .operation_count = try row.get(i64, 6),
            });
        }
    } else {
        var result = conn.query(base_sql ++
            \\ WHERE ws_id = $1 ORDER BY created_at DESC
        , .{ws_id}) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        defer result.deinit();
        while (try result.next()) |row| {
            try list.append(req.arena, .{
                .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                .author = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                .status = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                .title = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                .body = try req.arena.dupe(u8, try row.get([]const u8, 4)),
                .created_at = try req.arena.dupe(u8, try row.get([]const u8, 5)),
                .operation_count = try row.get(i64, 6),
            });
        }
    }

    try res.json(.{ .prs = list.items }, .{});
}

const OperationView = struct {
    op_index: i32,
    type: []const u8,
    context_id: ?[]const u8,
    base_hash: ?[]const u8,
    content: ?[]const u8,
    path: ?[]const u8,
    base_content: ?[]const u8,
};

pub fn handleGetPr(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "workspace:read", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const pr_id = req.param("pr_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "pr_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    var row = conn.row(
        "SELECT pr_id, author, status, title, body, created_at::text FROM context_prs WHERE pr_id = $1 AND ws_id = $2",
        .{ pr_id, ws_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "PR not found");
    };

    const pr_id_val = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const author = try req.arena.dupe(u8, try row.get([]const u8, 1));
    const status = try req.arena.dupe(u8, try row.get([]const u8, 2));
    const pr_title = try req.arena.dupe(u8, try row.get([]const u8, 3));
    const pr_body = try req.arena.dupe(u8, try row.get([]const u8, 4));
    const created_at = try req.arena.dupe(u8, try row.get([]const u8, 5));
    row.deinit() catch {};

    var ops: std.ArrayList(OperationView) = .empty;
    var op_result = conn.query(
        "SELECT op_index, type, context_id, base_hash, base_content, content, path FROM context_pr_operations WHERE pr_id = $1 ORDER BY op_index",
        .{pr_id_val},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer op_result.deinit();

    while (try op_result.next()) |orow| {
        const op_index = try orow.get(i32, 0);
        const op_type = try req.arena.dupe(u8, try orow.get([]const u8, 1));
        const op_context_id: ?[]const u8 = if (orow.get([]const u8, 2)) |v|
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
            .context_id = op_context_id,
            .base_hash = op_base_hash,
            .content = op_content,
            .path = op_path,
            .base_content = op_base_content,
        });
    }

    try res.json(.{
        .pr_id = pr_id_val,
        .author = author,
        .status = status,
        .title = pr_title,
        .body = pr_body,
        .operations = ops.items,
        .created_at = created_at,
    }, .{});
}

const PrActionRequest = struct {
    action: []const u8,
    reason: ?[]const u8 = null,
};

pub fn handleUpdatePr(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "workspace:write", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const pr_id = req.param("pr_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "pr_id is required");
    };

    const body = req.json(PrActionRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (!std.mem.eql(u8, body.action, "merge") and !std.mem.eql(u8, body.action, "reject")) {
        return apiError(res, 400, "BAD_REQUEST", "action must be 'merge' or 'reject'");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    var pr_row = conn.row(
        "SELECT status FROM context_prs WHERE pr_id = $1 AND ws_id = $2",
        .{ pr_id, ws_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "PR not found");
    };
    const current_status_raw = pr_row.get([]const u8, 0) catch "";
    var status_buf: [32]u8 = undefined;
    const status_len = @min(current_status_raw.len, status_buf.len);
    @memcpy(status_buf[0..status_len], current_status_raw[0..status_len]);
    pr_row.deinit() catch {};

    if (!std.mem.eql(u8, status_buf[0..status_len], "open")) {
        return apiError(res, 400, "BAD_REQUEST", "PR is not open");
    }

    if (std.mem.eql(u8, body.action, "merge")) {
        if (!std.mem.eql(u8, user.role, "maintainer") and !auth.checkWorkspaceAdmin(conn, ws_id, user.user_id)) {
            return apiError(res, 403, "FORBIDDEN", "only maintainers or ws admins can merge");
        }
        if (!try applyPr(conn, req.arena, ws_id, pr_id, user.username, res)) return;

        try res.json(.{ .pr_id = pr_id, .status = "merged" }, .{});
    } else {
        _ = conn.exec(
            "UPDATE context_prs SET status = 'rejected' WHERE pr_id = $1",
            .{pr_id},
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "failed to reject PR");
        };
        try res.json(.{ .pr_id = pr_id, .status = "rejected" }, .{});
    }
}

const LoadedOp = struct {
    op_index: i32,
    type: []const u8,
    context_id: ?[]const u8,
    base_hash: ?[]const u8,
    content: ?[]const u8,
    path: ?[]const u8,
};

fn applyPr(conn: anytype, arena: std.mem.Allocator, ws_id: []const u8, pr_id: []const u8, author: []const u8, res: *httpz.Response) !bool {
    var ops: std.ArrayList(LoadedOp) = .empty;
    {
        var op_result = conn.query(
            "SELECT op_index, type, context_id, base_hash, content, path FROM context_pr_operations WHERE pr_id = $1 ORDER BY op_index",
            .{pr_id},
        ) catch {
            try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            return false;
        };
        defer op_result.deinit();
        while (try op_result.next()) |r| {
            const op_index = r.get(i32, 0) catch continue;
            const t = arena.dupe(u8, r.get([]const u8, 1) catch "") catch continue;
            const cid: ?[]const u8 = if (r.get([]const u8, 2)) |v|
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
                .context_id = cid,
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
        if (std.mem.eql(u8, op.type, "update")) {
            const cid = op.context_id.?;
            const bh = op.base_hash.?;
            const new_content = op.content.?;
            db_mod.validateContentFormat(new_content) catch {
                conn.rollback() catch {};
                try apiError(res, 422, "INVALID_FORMAT", "content must have an H1 heading, a description paragraph, and at least one H2 section");
                return false;
            };
            var row = conn.row(
                "SELECT content_hash FROM workspace_context WHERE ws_id = $1 AND context_id = $2",
                .{ ws_id, cid },
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
                return false;
            } orelse {
                conn.rollback() catch {};
                try apiError(res, 404, "NOT_FOUND", "target file no longer exists");
                return false;
            };
            const current_hash = row.get([]const u8, 0) catch "";
            const matches = std.mem.eql(u8, current_hash, bh);
            row.deinit() catch {};
            if (!matches) {
                conn.rollback() catch {};
                try apiError(res, 409, "CONFLICT", "file has changed since PR was created");
                return false;
            }
            const new_hash = util_hash.contentHash(new_content);
            const hash_slice: []const u8 = arena.dupe(u8, &new_hash) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "alloc failed");
                return false;
            };
            _ = conn.exec(
                "UPDATE workspace_context SET content = $1, content_hash = $2, description = $3, author = $4, updated_at = now() WHERE ws_id = $5 AND context_id = $6",
                .{ new_content, hash_slice, db_mod.extractDescription(new_content), author, ws_id, cid },
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "failed to update file");
                return false;
            };
        } else if (std.mem.eql(u8, op.type, "rename")) {
            const cid = op.context_id.?;
            const bh = op.base_hash.?;
            const new_path = op.path.?;
            var row = conn.row(
                "SELECT content_hash FROM workspace_context WHERE ws_id = $1 AND context_id = $2",
                .{ ws_id, cid },
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
                return false;
            } orelse {
                conn.rollback() catch {};
                try apiError(res, 404, "NOT_FOUND", "target file no longer exists");
                return false;
            };
            const current_hash = row.get([]const u8, 0) catch "";
            const matches = std.mem.eql(u8, current_hash, bh);
            row.deinit() catch {};
            if (!matches) {
                conn.rollback() catch {};
                try apiError(res, 409, "CONFLICT", "file has changed since PR was created");
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
                    "UPDATE workspace_context SET path = $1, content = $2, content_hash = $3, description = $4, author = $5, updated_at = now() WHERE ws_id = $6 AND context_id = $7",
                    .{ new_path, new_content, hash_slice, db_mod.extractDescription(new_content), author, ws_id, cid },
                ) catch {
                    conn.rollback() catch {};
                    try apiError(res, 500, "INTERNAL_ERROR", "failed to update file");
                    return false;
                };
            } else {
                _ = conn.exec(
                    "UPDATE workspace_context SET path = $1, author = $2, updated_at = now() WHERE ws_id = $3 AND context_id = $4",
                    .{ new_path, author, ws_id, cid },
                ) catch {
                    conn.rollback() catch {};
                    try apiError(res, 500, "INTERNAL_ERROR", "failed to update file");
                    return false;
                };
            }
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
            var cid_buf: [36]u8 = undefined;
            @memcpy(cid_buf[0..4], "ctx-");
            const hex = "0123456789abcdef";
            for (rand_bytes, 0..) |byte, i| {
                cid_buf[4 + i * 2] = hex[byte >> 4];
                cid_buf[4 + i * 2 + 1] = hex[byte & 0x0f];
            }
            const new_cid: []const u8 = arena.dupe(u8, cid_buf[0..36]) catch {
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
                "INSERT INTO workspace_context (context_id, ws_id, path, content, content_hash, author, description) VALUES ($1, $2, $3, $4, $5, $6, $7)",
                .{ new_cid, ws_id, path, new_content, hash_slice, author, db_mod.extractDescription(new_content) },
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 409, "CONFLICT", "target path conflict on create");
                return false;
            };
        } else if (std.mem.eql(u8, op.type, "delete")) {
            const cid = op.context_id.?;
            _ = conn.exec(
                "DELETE FROM workspace_context WHERE ws_id = $1 AND context_id = $2",
                .{ ws_id, cid },
            ) catch {
                conn.rollback() catch {};
                try apiError(res, 500, "INTERNAL_ERROR", "failed to delete file");
                return false;
            };
        }
    }

    const updated = conn.exec(
        "UPDATE context_prs SET status = 'merged' WHERE pr_id = $1 AND status = 'open'",
        .{pr_id},
    ) catch {
        conn.rollback() catch {};
        try apiError(res, 500, "INTERNAL_ERROR", "failed to update PR");
        return false;
    };
    if (updated == null or updated.? == 0) {
        conn.rollback() catch {};
        try apiError(res, 400, "BAD_REQUEST", "PR is not open");
        return false;
    }

    _ = conn.exec(
        "UPDATE workspaces SET revision = revision + 1 WHERE ws_id = $1",
        .{ws_id},
    ) catch {
        conn.rollback() catch {};
        try apiError(res, 500, "INTERNAL_ERROR", "failed to update workspace revision");
        return false;
    };

    conn.commit() catch {
        conn.rollback() catch {};
        try apiError(res, 500, "INTERNAL_ERROR", "failed to commit transaction");
        return false;
    };
    return true;
}

const CommentRequest = struct {
    body: []const u8,
};

pub fn handleAddPrComment(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "workspace:write", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const pr_id = req.param("pr_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "pr_id is required");
    };

    const body = req.json(CommentRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    var pr_check = conn.row(
        "SELECT 1 FROM context_prs WHERE pr_id = $1 AND ws_id = $2",
        .{ pr_id, ws_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "PR not found");
    };
    pr_check.deinit() catch {};

    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var comment_id_buf: [20]u8 = undefined;
    @memcpy(comment_id_buf[0..4], "cmt-");
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        comment_id_buf[4 + i * 2] = hex_chars[byte >> 4];
        comment_id_buf[4 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    _ = conn.exec(
        "INSERT INTO context_pr_comments (comment_id, pr_id, author, body) VALUES ($1, $2, $3, $4)",
        .{ &comment_id_buf, pr_id, user.username, body.body },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to add comment");
    };

    res.status = 201;
    try res.json(.{
        .comment_id = &comment_id_buf,
        .author = user.username,
    }, .{});
}

pub fn handleListPrComments(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "workspace:read", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const pr_id = req.param("pr_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "pr_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    var pr_check = conn.row(
        "SELECT 1 FROM context_prs WHERE pr_id = $1 AND ws_id = $2",
        .{ pr_id, ws_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "PR not found");
    };
    pr_check.deinit() catch {};

    const Comment = struct {
        comment_id: []const u8 = "",
        author_id: []const u8 = "",
        author: []const u8 = "",
        body: []const u8 = "",
        created_at: []const u8 = "",
    };
    var result = conn.query(
        \\SELECT comment_id, author, body, created_at::text
        \\FROM context_pr_comments
        \\WHERE pr_id = $1
        \\ORDER BY created_at
    , .{pr_id}) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(Comment) = .empty;
    while (try result.next()) |row| {
        const author = try req.arena.dupe(u8, try row.get([]const u8, 1));
        try list.append(req.arena, .{
            .comment_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .author_id = author,
            .author = author,
            .body = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .created_at = try req.arena.dupe(u8, try row.get([]const u8, 3)),
        });
    }

    try res.json(.{ .comments = list.items }, .{});
}
