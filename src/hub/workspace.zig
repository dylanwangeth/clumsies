const std = @import("std");
const httpz = @import("httpz");
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("../protocol/api_error.zig").send;
const KvMap = @import("../protocol/manifest.zig").KvMap;
const KvEntry = @import("../protocol/manifest.zig").KvEntry;

const CreateRequest = struct {
    name: []const u8,
    bundle_id: ?[]const u8 = null,
};

pub fn handleCreate(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const body = req.json(CreateRequest) catch {
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
    var ws_id_buf: [35]u8 = undefined;
    @memcpy(ws_id_buf[0..3], "ws-");
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        ws_id_buf[3 + i * 2] = hex_chars[byte >> 4];
        ws_id_buf[3 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    _ = conn.exec(
        "INSERT INTO workspaces (ws_id, org_id, name) VALUES ($1, $2::uuid, $3)",
        .{ &ws_id_buf, user.org_id, body.name },
    ) catch {
        if (conn.err) |pg_err| {
            if (std.mem.indexOf(u8, pg_err.message, "unique") != null or
                std.mem.indexOf(u8, pg_err.message, "duplicate") != null)
            {
                return apiError(res, 409, "CONFLICT", "workspace with this name already exists");
            }
        }
        return apiError(res, 500, "INTERNAL_ERROR", "failed to create workspace");
    };

    _ = conn.exec(
        "INSERT INTO workspace_members (ws_id, user_id) VALUES ($1, $2)",
        .{ &ws_id_buf, user.user_id },
    ) catch {};

    res.status = 201;
    try res.json(.{
        .ws_id = &ws_id_buf,
        .name = body.name,
        .revision = @as(i32, 0),
    }, .{});
}

pub fn handleGet(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT ws_id, name, revision FROM workspaces WHERE ws_id = $1",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "workspace not found");
    };
    defer row.deinit() catch {};

    try res.json(.{
        .ws_id = try row.get([]const u8, 0),
        .name = try row.get([]const u8, 1),
        .revision = try row.get(i32, 2),
    }, .{});
}

const UpdateRequest = struct {
    name: []const u8,
};

pub fn handleUpdate(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const body = req.json(UpdateRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "UPDATE workspaces SET name = $1, revision = revision + 1 WHERE ws_id = $2 RETURNING ws_id, name, revision",
        .{ body.name, ws_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "workspace not found");
    };
    defer row.deinit() catch {};

    try res.json(.{
        .ws_id = try row.get([]const u8, 0),
        .name = try row.get([]const u8, 1),
        .revision = try row.get(i32, 2),
    }, .{});
}

pub fn handleGetManifest(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var ws_row = conn.row(
        "SELECT ws_id, name, revision FROM workspaces WHERE ws_id = $1",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "workspace not found");
    };

    const ws_id_val = try req.arena.dupe(u8, try ws_row.get([]const u8, 0));
    const ws_name = try req.arena.dupe(u8, try ws_row.get([]const u8, 1));
    const revision = try ws_row.get(i32, 2);
    ws_row.deinit() catch {};

    if (req.header("if-none-match")) |etag| {
        var rev_buf: [32]u8 = undefined;
        const expected = std.fmt.bufPrint(&rev_buf, "\"rev-{d}\"", .{revision}) catch "";
        if (std.mem.eql(u8, etag, expected)) {
            res.status = 304;
            return;
        }
    }

    const prompts = try collectKvMap(req.arena, conn, "SELECT wp.prompt_id, p.content_hash FROM workspace_prompts wp JOIN prompts p ON p.prompt_id = wp.prompt_id WHERE wp.ws_id = $1", .{ws_id});

    const context = try collectKvMap(req.arena, conn, "SELECT path, content_hash FROM workspace_files WHERE ws_id = $1", .{ws_id});

    var etag_buf: [32]u8 = undefined;
    const etag_slice = std.fmt.bufPrint(&etag_buf, "\"rev-{d}\"", .{revision}) catch "";
    res.header("ETag", try req.arena.dupe(u8, etag_slice));

    try res.json(.{
        .ws_id = ws_id_val,
        .name = ws_name,
        .revision = revision,
        .prompts = prompts,
        .context = context,
    }, .{});
}

const AddPromptRequest = struct {
    prompt_id: []const u8,
};

pub fn handleAddPrompt(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const body = req.json(AddPromptRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var prompt_row = conn.row(
        "SELECT prompt_id FROM prompts WHERE prompt_id = $1",
        .{body.prompt_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "prompt not found");
    };
    prompt_row.deinit() catch {};

    _ = conn.exec(
        "INSERT INTO workspace_prompts (ws_id, prompt_id) VALUES ($1, $2)",
        .{ ws_id, body.prompt_id },
    ) catch {
        if (conn.err) |pg_err| {
            if (std.mem.indexOf(u8, pg_err.message, "duplicate") != null) {
                return apiError(res, 409, "CONFLICT", "prompt already in workspace");
            }
        }
        return apiError(res, 500, "INTERNAL_ERROR", "failed to add prompt");
    };

    var rev_row = conn.row(
        "UPDATE workspaces SET revision = revision + 1 WHERE ws_id = $1 RETURNING revision",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to update revision");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "workspace not found");
    };
    const new_rev = try rev_row.get(i32, 0);
    rev_row.deinit() catch {};

    try res.json(.{ .revision = new_rev }, .{});
}

pub fn handleRemovePrompt(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const prompt_id = req.param("prompt_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "prompt_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    const deleted = conn.exec(
        "DELETE FROM workspace_prompts WHERE ws_id = $1 AND prompt_id = $2",
        .{ ws_id, prompt_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };

    if (deleted == null or deleted.? == 0) {
        return apiError(res, 404, "NOT_FOUND", "prompt not in workspace");
    }

    var rev_row = conn.row(
        "UPDATE workspaces SET revision = revision + 1 WHERE ws_id = $1 RETURNING revision",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to update revision");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "workspace not found");
    };
    const new_rev = try rev_row.get(i32, 0);
    rev_row.deinit() catch {};

    try res.json(.{ .revision = new_rev }, .{});
}

pub fn handleListFiles(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    const FileMeta = struct {
        path: []const u8,
        hash: []const u8,
    };

    var result = conn.query(
        "SELECT path, content_hash FROM workspace_files WHERE ws_id = $1 ORDER BY path",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(FileMeta) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .path = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .hash = try req.arena.dupe(u8, try row.get([]const u8, 1)),
        });
    }

    try res.json(.{ .files = list.items }, .{});
}

pub fn handleGetFileContent(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const path = qs.get("path") orelse {
        return apiError(res, 400, "BAD_REQUEST", "path query parameter is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT content FROM workspace_files WHERE ws_id = $1 AND path = $2",
        .{ ws_id, path },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "file not found");
    };

    const content = try req.arena.dupe(u8, try row.get([]const u8, 0));
    row.deinit() catch {};

    res.header("Content-Type", "application/octet-stream");
    res.body = content;
}

pub fn handlePutFile(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const path = qs.get("path") orelse {
        return apiError(res, 400, "BAD_REQUEST", "path query parameter is required");
    };

    const body = req.body() orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const hash = @import("../protocol/hash.zig").ContentHash.compute(body);
    const hash_slice: []const u8 = &hash;

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    _ = conn.exec(
        \\INSERT INTO workspace_files (ws_id, path, content, content_hash, updated_at)
        \\VALUES ($1, $2, $3, $4, now())
        \\ON CONFLICT (ws_id, path) DO UPDATE SET content = $3, content_hash = $4, updated_at = now()
    ,
        .{ ws_id, path, body, hash_slice },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to write file");
    };

    var rev_row = conn.row(
        "UPDATE workspaces SET revision = revision + 1 WHERE ws_id = $1 RETURNING revision",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to update revision");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "workspace not found");
    };
    const new_rev = try rev_row.get(i32, 0);
    rev_row.deinit() catch {};

    try res.json(.{
        .revision = new_rev,
        .hash = hash_slice,
    }, .{});
}

pub fn handleDeleteFile(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const path = qs.get("path") orelse {
        return apiError(res, 400, "BAD_REQUEST", "path query parameter is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    const deleted = conn.exec(
        "DELETE FROM workspace_files WHERE ws_id = $1 AND path = $2",
        .{ ws_id, path },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };

    if (deleted == null or deleted.? == 0) {
        return apiError(res, 404, "NOT_FOUND", "file not found");
    }

    var rev_row = conn.row(
        "UPDATE workspaces SET revision = revision + 1 WHERE ws_id = $1 RETURNING revision",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to update revision");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "workspace not found");
    };
    const new_rev = try rev_row.get(i32, 0);
    rev_row.deinit() catch {};

    try res.json(.{ .revision = new_rev }, .{});
}

fn collectKvMap(arena: std.mem.Allocator, conn: anytype, sql: []const u8, params: anytype) !KvMap {
    var result = conn.query(sql, params) catch return KvMap{ .entries = &.{} };
    defer result.deinit();

    var entries: std.ArrayList(KvEntry) = .empty;
    while (try result.next()) |row| {
        try entries.append(arena, .{
            .key = try arena.dupe(u8, try row.get([]const u8, 0)),
            .value = try arena.dupe(u8, try row.get([]const u8, 1)),
        });
    }

    return KvMap{ .entries = entries.items };
}
