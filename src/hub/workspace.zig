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

    // Initialize workspace from bundle if specified
    if (body.bundle_id) |bid| {
        initFromBundle(conn, &ws_id_buf, bid);
    }

    res.status = 201;
    try res.json(.{
        .ws_id = &ws_id_buf,
        .name = body.name,
        .revision = @as(i32, 0),
    }, .{});
}

pub fn handleGet(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

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
    const user = auth.authenticate(ctx, req) catch {
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

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    if (!try checkIfMatch(conn, req, res, ws_id)) return;

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
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

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

    const context = try collectKvMap(req.arena, conn, "SELECT path, content_hash FROM context_files WHERE ws_id = $1 AND branch_name = 'main'", .{ws_id});

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
    const user = auth.authenticate(ctx, req) catch {
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

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    if (!try checkIfMatch(conn, req, res, ws_id)) return;

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
    const user = auth.authenticate(ctx, req) catch {
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

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    if (!try checkIfMatch(conn, req, res, ws_id)) return;

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


fn initFromBundle(conn: anytype, ws_id: []const u8, bundle_id: []const u8) void {
    var result = conn.query(
        "SELECT prompt_id FROM bundle_prompts WHERE bundle_id = $1",
        .{bundle_id},
    ) catch return;
    defer result.deinit();

    while (result.next() catch null) |brow| {
        const pid = brow.get([]const u8, 0) catch continue;
        _ = conn.exec(
            "INSERT INTO workspace_prompts (ws_id, prompt_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
            .{ ws_id, pid },
        ) catch {};
    }
}

fn checkIfMatch(conn: anytype, req: anytype, res: anytype, ws_id: []const u8) !bool {
    const if_match = req.header("if-match") orelse return true;
    // Parse "rev-N" from the ETag
    const trimmed = if (if_match.len > 2 and if_match[0] == '"' and if_match[if_match.len - 1] == '"')
        if_match[1 .. if_match.len - 1]
    else
        if_match;
    if (!std.mem.startsWith(u8, trimmed, "rev-")) {
        try apiError(res, 412, "PRECONDITION_FAILED", "invalid ETag format");
        return false;
    }
    const expected_rev = std.fmt.parseInt(i32, trimmed[4..], 10) catch {
        try apiError(res, 412, "PRECONDITION_FAILED", "invalid ETag format");
        return false;
    };
    var rev_row = conn.row("SELECT revision FROM workspaces WHERE ws_id = $1", .{ws_id}) catch {
        try apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        return false;
    } orelse {
        try apiError(res, 404, "NOT_FOUND", "workspace not found");
        return false;
    };
    const current_rev = try rev_row.get(i32, 0);
    rev_row.deinit() catch {};
    if (current_rev != expected_rev) {
        try apiError(res, 412, "PRECONDITION_FAILED", "revision mismatch, re-fetch manifest");
        return false;
    }
    return true;
}

// Workspace deletion
pub fn handleDelete(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "maintainer role required");
    }

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Verify workspace exists
    var exists = conn.row(
        "SELECT 1 FROM workspaces WHERE ws_id = $1 AND org_id = $2::uuid",
        .{ ws_id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    if (exists) |*r| {
        r.deinit() catch {};
    } else {
        return apiError(res, 404, "NOT_FOUND", "workspace not found");
    }

    // Cascade delete: comments, prs, files, branches, members, prompt refs, then workspace
    _ = conn.exec("DELETE FROM context_pr_comments WHERE pr_id IN (SELECT pr_id FROM context_prs WHERE ws_id = $1)", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM context_prs WHERE ws_id = $1", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM context_files WHERE ws_id = $1", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM context_branches WHERE ws_id = $1", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM workspace_members WHERE ws_id = $1", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM workspace_prompts WHERE ws_id = $1", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM workspaces WHERE ws_id = $1", .{ws_id}) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database delete failed");
    };

    res.status = 204;
}

// Workspace member management

const WsMemberInfo = struct {
    user_id: []const u8,
    username: []const u8,
    level: []const u8,
    joined_at: []const u8,
};

pub fn handleListMembers(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Must be ws member or maintainer
    if (!std.mem.eql(u8, user.role, "maintainer") and !auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    var result = conn.query(
        "SELECT wm.user_id, u.username, wm.level, wm.joined_at::text FROM workspace_members wm JOIN users u ON u.user_id = wm.user_id WHERE wm.ws_id = $1 ORDER BY u.username",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(WsMemberInfo) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .user_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .username = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .level = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .joined_at = try req.arena.dupe(u8, try row.get([]const u8, 3)),
        });
    }

    try res.json(.{ .members = list.items }, .{});
}

const AddWsMemberRequest = struct {
    user_id: []const u8,
    level: ?[]const u8 = null,
};

pub fn handleAddMember(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const body = req.json(AddWsMemberRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Member can only add self (join), maintainer can add anyone
    const is_self = std.mem.eql(u8, body.user_id, user.user_id);
    if (!is_self and !std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "only maintainers can add other members");
    }

    const level = body.level orelse "write";
    if (!std.mem.eql(u8, level, "read") and !std.mem.eql(u8, level, "write") and !std.mem.eql(u8, level, "admin")) {
        return apiError(res, 400, "BAD_REQUEST", "level must be read, write, or admin");
    }

    // Verify target user exists in org
    var target_exists = conn.row(
        "SELECT 1 FROM users WHERE user_id = $1 AND org_id = $2::uuid",
        .{ body.user_id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    if (target_exists) |*r| {
        r.deinit() catch {};
    } else {
        return apiError(res, 404, "NOT_FOUND", "user not found in org");
    }

    _ = conn.exec(
        "INSERT INTO workspace_members (ws_id, user_id, level) VALUES ($1, $2, $3)",
        .{ ws_id, body.user_id, level },
    ) catch {
        if (conn.err) |pg_err| {
            if (std.mem.indexOf(u8, pg_err.message, "unique") != null or
                std.mem.indexOf(u8, pg_err.message, "duplicate") != null)
            {
                return apiError(res, 409, "CONFLICT", "user is already a member");
            }
        }
        return apiError(res, 500, "INTERNAL_ERROR", "database insert failed");
    };

    res.status = 201;
    try res.json(.{ .user_id = body.user_id, .level = level }, .{});
}

pub fn handleRemoveMember(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const target_id = req.param("user_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "user_id is required");
    };

    // Member can only remove self (leave), maintainer can remove anyone
    const is_self = std.mem.eql(u8, target_id, user.user_id);
    if (!is_self and !std.mem.eql(u8, user.role, "maintainer")) {
        return apiError(res, 403, "FORBIDDEN", "only maintainers can remove other members");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    _ = conn.exec(
        "DELETE FROM workspace_members WHERE ws_id = $1 AND user_id = $2",
        .{ ws_id, target_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database delete failed");
    };

    res.status = 204;
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
