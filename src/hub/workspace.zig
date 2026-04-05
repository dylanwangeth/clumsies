const std = @import("std");
const httpz = @import("httpz");
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("../protocol/api_error.zig").send;

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
    const hex = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        ws_id_buf[3 + i * 2] = hex[byte >> 4];
        ws_id_buf[3 + i * 2 + 1] = hex[byte & 0x0f];
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
    defer ws_row.deinit() catch {};

    const ws_id_val = try ws_row.get([]const u8, 0);
    const ws_name = try ws_row.get([]const u8, 1);
    const revision = try ws_row.get(i32, 2);

    if (req.header("if-none-match")) |etag| {
        var rev_buf: [32]u8 = undefined;
        const expected = std.fmt.bufPrint(&rev_buf, "\"rev-{d}\"", .{revision}) catch "";
        if (std.mem.eql(u8, etag, expected)) {
            res.status = 304;
            return;
        }
    }

    // Build JSON response manually for dynamic key-value maps
    const w = res.writer();
    try w.writeAll("{\"ws_id\":\"");
    try w.writeAll(ws_id_val);
    try w.writeAll("\",\"name\":\"");
    try w.writeAll(ws_name);
    try w.print("\",\"revision\":{d},\"prompts\":{{", .{revision});

    var prompts_result = conn.query(
        "SELECT wp.prompt_id, p.content_hash FROM workspace_prompts wp JOIN prompts p ON p.prompt_id = wp.prompt_id WHERE wp.ws_id = $1",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer prompts_result.deinit();

    var first = true;
    while (try prompts_result.next()) |prow| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("\"");
        try w.writeAll(try prow.get([]const u8, 0));
        try w.writeAll("\":\"");
        try w.writeAll(try prow.get([]const u8, 1));
        try w.writeAll("\"");
    }

    try w.writeAll("},\"context\":{");

    var files_result = conn.query(
        "SELECT path, content_hash FROM workspace_files WHERE ws_id = $1",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer files_result.deinit();

    first = true;
    while (try files_result.next()) |frow| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("\"");
        try w.writeAll(try frow.get([]const u8, 0));
        try w.writeAll("\":\"");
        try w.writeAll(try frow.get([]const u8, 1));
        try w.writeAll("\"");
    }

    try w.writeAll("}}");

    var etag_buf: [32]u8 = undefined;
    const etag = std.fmt.bufPrint(&etag_buf, "\"rev-{d}\"", .{revision}) catch "";
    res.header("ETag", etag);
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
    defer prompt_row.deinit() catch {};

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
    defer rev_row.deinit() catch {};

    try res.json(.{
        .revision = try rev_row.get(i32, 0),
    }, .{});
}
