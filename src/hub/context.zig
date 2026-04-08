const std = @import("std");
const httpz = @import("httpz");
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("../protocol/api_error.zig").send;
const ContentHash = @import("../protocol/hash.zig").ContentHash;

// GET /api/workspaces/:ws_id/context/branches
pub fn handleListBranches(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
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

    const BranchInfo = struct {
        name: []const u8,
        revision: i32,
        file_count: i64,
        ahead: ?i64 = null,
        behind: ?i64 = null,
    };

    var result = conn.query(
        \\SELECT cb.branch_name, cb.revision,
        \\    (SELECT count(*) FROM context_files cf WHERE cf.ws_id = cb.ws_id AND cf.branch_name = cb.branch_name),
        \\    CASE WHEN cb.branch_name != 'main' THEN
        \\        (SELECT count(*) FROM context_files cf WHERE cf.ws_id = cb.ws_id AND cf.branch_name = cb.branch_name
        \\         AND (cf.path NOT IN (SELECT mf.path FROM context_files mf WHERE mf.ws_id = cb.ws_id AND mf.branch_name = 'main')
        \\              OR cf.content_hash != (SELECT mf.content_hash FROM context_files mf WHERE mf.ws_id = cb.ws_id AND mf.branch_name = 'main' AND mf.path = cf.path)))
        \\    END,
        \\    CASE WHEN cb.branch_name != 'main' THEN
        \\        (SELECT count(*) FROM context_files mf WHERE mf.ws_id = cb.ws_id AND mf.branch_name = 'main'
        \\         AND mf.updated_at > (SELECT COALESCE(MAX(cf2.updated_at), '1970-01-01') FROM context_files cf2 WHERE cf2.ws_id = cb.ws_id AND cf2.branch_name = cb.branch_name AND cf2.path = mf.path)
        \\         AND mf.path IN (SELECT cf3.path FROM context_files cf3 WHERE cf3.ws_id = cb.ws_id AND cf3.branch_name = cb.branch_name))
        \\    END
        \\FROM context_branches cb WHERE cb.ws_id = $1 ORDER BY cb.branch_name
    ,
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(BranchInfo) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .name = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .revision = try row.get(i32, 1),
            .file_count = try row.get(i64, 2),
            .ahead = row.get(i64, 3) catch null,
            .behind = row.get(i64, 4) catch null,
        });
    }

    try res.json(.{ .branches = list.items }, .{});
}

// GET /api/workspaces/:ws_id/context/files
pub fn handleListFiles(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
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

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const branch = qs.get("branch") orelse "main";

    const FileMeta = struct {
        path: []const u8,
        hash: []const u8,
        size: i64,
        author: []const u8,
        updated_at: []const u8,
    };

    var result = conn.query(
        "SELECT path, content_hash, length(content)::bigint, author, updated_at::text FROM context_files WHERE ws_id = $1 AND branch_name = $2 ORDER BY path",
        .{ ws_id, branch },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(FileMeta) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .path = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .hash = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .size = try row.get(i64, 2),
            .author = try req.arena.dupe(u8, try row.get([]const u8, 3)),
            .updated_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
        });
    }

    try res.json(.{ .branch = branch, .files = list.items }, .{});
}

// GET /api/workspaces/:ws_id/context/file/content?path=...&branch=...
pub fn handleGetFileContent(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
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
    const branch = qs.get("branch") orelse "main";

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    var row = conn.row(
        "SELECT content FROM context_files WHERE ws_id = $1 AND branch_name = $2 AND path = $3",
        .{ ws_id, branch, path },
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

// PUT /api/workspaces/:ws_id/context/file?path=...
pub fn handlePutFile(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
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

    const max_file_size = 10 * 1024 * 1024;
    if (body.len > max_file_size) {
        return apiError(res, 413, "PAYLOAD_TOO_LARGE", "file exceeds 10MB limit");
    }

    const hash = ContentHash.compute(body);
    const hash_slice: []const u8 = &hash;

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    const branch = user.username;

    // Ensure member branch exists (create from main HEAD if not)
    ensureMemberBranch(conn, ws_id, branch);

    // Write file to member branch
    _ = conn.exec(
        \\INSERT INTO context_files (ws_id, branch_name, path, content, content_hash, author, updated_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, now())
        \\ON CONFLICT (ws_id, branch_name, path) DO UPDATE SET content = $4, content_hash = $5, author = $6, updated_at = now()
    ,
        .{ ws_id, branch, path, body, hash_slice, user.username },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to write file");
    };

    // Increment branch revision
    _ = conn.exec(
        "UPDATE context_branches SET revision = revision + 1 WHERE ws_id = $1 AND branch_name = $2",
        .{ ws_id, branch },
    ) catch {};

    var rev_row = conn.row(
        "SELECT revision FROM context_branches WHERE ws_id = $1 AND branch_name = $2",
        .{ ws_id, branch },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 500, "INTERNAL_ERROR", "branch not found after write");
    };
    const branch_rev = try rev_row.get(i32, 0);
    rev_row.deinit() catch {};

    res.status = 200;
    try res.json(.{
        .branch = branch,
        .path = path,
        .hash = hash_slice,
        .branch_revision = branch_rev,
    }, .{});
}

// DELETE /api/workspaces/:ws_id/context/file?path=...
pub fn handleDeleteFile(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
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

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    const branch = user.username;

    const deleted = conn.exec(
        "DELETE FROM context_files WHERE ws_id = $1 AND branch_name = $2 AND path = $3",
        .{ ws_id, branch, path },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };

    if (deleted == null or deleted.? == 0) {
        return apiError(res, 404, "NOT_FOUND", "file not found");
    }

    try res.json(.{ .status = "deleted" }, .{});
}

const CreatePrRequest = struct {
    description: ?[]const u8 = null,
    file_paths: ?[]const []const u8 = null,
};

// POST /api/workspaces/:ws_id/context/prs
pub fn handleCreatePr(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const body = req.json(CreatePrRequest) catch {
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

    const branch = user.username;

    // Check branch exists
    var branch_row = conn.row(
        "SELECT 1 FROM context_branches WHERE ws_id = $1 AND branch_name = $2",
        .{ ws_id, branch },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "no branch found, make changes first");
    };
    branch_row.deinit() catch {};

    // Conflict detection: check if any of the PR files were modified on main since branch fork
    if (body.file_paths) |paths| {
        for (paths) |p| {
            var conflict_row = conn.row(
                "SELECT 1 FROM context_files WHERE ws_id = $1 AND branch_name = 'main' AND path = $2 AND updated_at > (SELECT created_at FROM context_branches WHERE ws_id = $1 AND branch_name = $3)",
                .{ ws_id, p, branch },
            ) catch continue;
            if (conflict_row) |*r| {
                r.deinit() catch {};
                return apiError(res, 409, "CONFLICT", "files conflict with main, rebase first");
            }
        }
    }

    // Determine which files to include in the PR
    // If file_paths specified, use those; otherwise use all branch files
    var file_count: i64 = 0;
    if (body.file_paths) |paths| {
        file_count = @intCast(paths.len);
        if (file_count == 0) {
            return apiError(res, 400, "BAD_REQUEST", "no changes to submit");
        }
        // Verify all specified paths exist on the branch
        for (paths) |p| {
            var exists = conn.row(
                "SELECT 1 FROM context_files WHERE ws_id = $1 AND branch_name = $2 AND path = $3",
                .{ ws_id, branch, p },
            ) catch {
                return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            };
            if (exists) |*r| {
                r.deinit() catch {};
            } else {
                return apiError(res, 400, "BAD_REQUEST", "file_path not found on branch");
            }
        }
    } else {
        var count_row = conn.row(
            "SELECT count(*) FROM context_files WHERE ws_id = $1 AND branch_name = $2",
            .{ ws_id, branch },
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        } orelse {
            return apiError(res, 400, "BAD_REQUEST", "no changes to submit");
        };
        file_count = try count_row.get(i64, 0);
        count_row.deinit() catch {};

        if (file_count == 0) {
            return apiError(res, 400, "BAD_REQUEST", "no changes to submit");
        }
    }

    // Generate PR ID
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var pr_id_buf: [20]u8 = undefined;
    @memcpy(pr_id_buf[0..4], "cpr-");
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        pr_id_buf[4 + i * 2] = hex_chars[byte >> 4];
        pr_id_buf[4 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    const description = body.description orelse "";

    _ = conn.exec(
        "INSERT INTO context_prs (pr_id, ws_id, author, branch_name, description) VALUES ($1, $2, $3, $4, $5)",
        .{ &pr_id_buf, ws_id, user.username, branch, description },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to create PR");
    };

    // Record which files are included in this PR
    if (body.file_paths) |paths| {
        for (paths) |p| {
            _ = conn.exec(
                "INSERT INTO context_pr_files (pr_id, path) VALUES ($1, $2)",
                .{ &pr_id_buf, p },
            ) catch {};
        }
    } else {
        // All branch files
        _ = conn.exec(
            "INSERT INTO context_pr_files (pr_id, path) SELECT $1, path FROM context_files WHERE ws_id = $2 AND branch_name = $3",
            .{ &pr_id_buf, ws_id, branch },
        ) catch {};
    }

    res.status = 201;
    try res.json(.{
        .pr_id = &pr_id_buf,
        .status = "open",
        .author = user.username,
        .files_changed = file_count,
    }, .{});
}

// GET /api/workspaces/:ws_id/context/prs
pub fn handleListPrs(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
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

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const status_filter = qs.get("status");

    const PrInfo = struct {
        pr_id: []const u8,
        author: []const u8,
        status: []const u8,
        description: []const u8,
        created_at: []const u8,
    };

    var list: std.ArrayList(PrInfo) = .empty;

    if (status_filter) |sf| {
        var result = conn.query(
            "SELECT pr_id, author, status, description, created_at::text FROM context_prs WHERE ws_id = $1 AND status = $2 ORDER BY created_at DESC",
            .{ ws_id, sf },
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        defer result.deinit();

        while (try result.next()) |row| {
            try list.append(req.arena, .{
                .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                .author = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                .status = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                .description = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
            });
        }
    } else {
        var result = conn.query(
            "SELECT pr_id, author, status, description, created_at::text FROM context_prs WHERE ws_id = $1 ORDER BY created_at DESC",
            .{ws_id},
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        defer result.deinit();

        while (try result.next()) |row| {
            try list.append(req.arena, .{
                .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                .author = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                .status = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                .description = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
            });
        }
    }

    try res.json(.{ .prs = list.items }, .{});
}

// GET /api/workspaces/:ws_id/context/prs/:pr_id
pub fn handleGetPr(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

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
        "SELECT pr_id, author, status, branch_name, description, created_at::text FROM context_prs WHERE pr_id = $1 AND ws_id = $2",
        .{ pr_id, ws_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "PR not found");
    };

    const pr_id_val = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const author = try req.arena.dupe(u8, try row.get([]const u8, 1));
    const status = try req.arena.dupe(u8, try row.get([]const u8, 2));
    const branch_name = try req.arena.dupe(u8, try row.get([]const u8, 3));
    const description = try req.arena.dupe(u8, try row.get([]const u8, 4));
    const created_at = try req.arena.dupe(u8, try row.get([]const u8, 5));
    row.deinit() catch {};

    // Get files on the branch
    const FileInfo = struct {
        path: []const u8,
        content_hash: []const u8,
    };

    var file_result = conn.query(
        "SELECT path, content_hash FROM context_files WHERE ws_id = $1 AND branch_name = $2 ORDER BY path",
        .{ ws_id, branch_name },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer file_result.deinit();

    var files: std.ArrayList(FileInfo) = .empty;
    while (try file_result.next()) |frow| {
        try files.append(req.arena, .{
            .path = try req.arena.dupe(u8, try frow.get([]const u8, 0)),
            .content_hash = try req.arena.dupe(u8, try frow.get([]const u8, 1)),
        });
    }

    try res.json(.{
        .pr_id = pr_id_val,
        .author = author,
        .status = status,
        .description = description,
        .files = files.items,
        .created_at = created_at,
    }, .{});
}

const PrActionRequest = struct {
    action: []const u8,
};

// PUT /api/workspaces/:ws_id/context/prs/:pr_id
pub fn handleUpdatePr(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

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

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    // Get PR info
    var pr_row = conn.row(
        "SELECT branch_name, status FROM context_prs WHERE pr_id = $1 AND ws_id = $2",
        .{ pr_id, ws_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "PR not found");
    };

    const branch_name = try req.arena.dupe(u8, try pr_row.get([]const u8, 0));
    const current_status = try req.arena.dupe(u8, try pr_row.get([]const u8, 1));
    pr_row.deinit() catch {};

    if (!std.mem.eql(u8, current_status, "open")) {
        return apiError(res, 400, "BAD_REQUEST", "PR is not open");
    }

    if (std.mem.eql(u8, body.action, "merge")) {
        // Only maintainer or ws:admin can merge
        if (!std.mem.eql(u8, user.role, "maintainer") and !auth.checkWorkspaceAdmin(conn, ws_id, user.user_id)) {
            return apiError(res, 403, "FORBIDDEN", "only maintainers or ws admins can merge");
        }

        // Ensure main branch exists
        _ = conn.exec(
            "INSERT INTO context_branches (ws_id, branch_name, base_revision, revision) VALUES ($1, 'main', 0, 0) ON CONFLICT DO NOTHING",
            .{ws_id},
        ) catch {};

        // File-level conflict detection (spec 3.9)
        var branch_info = conn.row(
            "SELECT base_revision FROM context_branches WHERE ws_id = $1 AND branch_name = $2",
            .{ ws_id, branch_name },
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        } orelse {
            return apiError(res, 500, "INTERNAL_ERROR", "branch not found");
        };
        const base_revision = try branch_info.get(i32, 0);
        branch_info.deinit() catch {};

        var main_rev_row = conn.row(
            "SELECT revision FROM context_branches WHERE ws_id = $1 AND branch_name = 'main'",
            .{ws_id},
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        const main_revision = if (main_rev_row) |*r| blk: {
            const v = try r.get(i32, 0);
            r.deinit() catch {};
            break :blk v;
        } else 0;

        if (main_revision > base_revision) {
            // Check for overlapping file paths
            var conflict_check = conn.row(
                \\SELECT count(*) FROM context_files bf
                \\JOIN context_files mf ON mf.ws_id = bf.ws_id AND mf.path = bf.path AND mf.branch_name = 'main'
                \\WHERE bf.ws_id = $1 AND bf.branch_name = $2
                \\AND mf.updated_at > bf.updated_at
            ,
                .{ ws_id, branch_name },
            ) catch {
                return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            };
            if (conflict_check) |*cc| {
                const cnt = try cc.get(i64, 0);
                cc.deinit() catch {};
                if (cnt > 0) {
                    _ = conn.exec(
                        "UPDATE context_prs SET status = 'conflict' WHERE pr_id = $1",
                        .{pr_id},
                    ) catch {};
                    return apiError(res, 409, "CONFLICT", "files conflict with main, rebase first");
                }
            }
        }

        // Copy only PR-specified files from branch to main (upsert)
        _ = conn.exec(
            \\INSERT INTO context_files (ws_id, branch_name, path, content, content_hash, author, updated_at)
            \\SELECT ws_id, 'main', path, content, content_hash, author, now()
            \\FROM context_files WHERE ws_id = $1 AND branch_name = $2
            \\AND path IN (SELECT path FROM context_pr_files WHERE pr_id = $3)
            \\ON CONFLICT (ws_id, branch_name, path) DO UPDATE SET content = EXCLUDED.content, content_hash = EXCLUDED.content_hash, author = EXCLUDED.author, updated_at = now()
        ,
            .{ ws_id, branch_name, pr_id },
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "failed to merge files to main");
        };

        // Increment main branch revision and workspace revision
        _ = conn.exec(
            "UPDATE context_branches SET revision = revision + 1 WHERE ws_id = $1 AND branch_name = 'main'",
            .{ws_id},
        ) catch {};
        _ = conn.exec(
            "UPDATE workspaces SET revision = revision + 1 WHERE ws_id = $1",
            .{ws_id},
        ) catch {};

        // Update member branch base_revision to main's new revision
        _ = conn.exec(
            "UPDATE context_branches SET base_revision = (SELECT revision FROM context_branches WHERE ws_id = $1 AND branch_name = 'main') WHERE ws_id = $1 AND branch_name = $2",
            .{ ws_id, branch_name },
        ) catch {};

        // Mark PR as merged
        _ = conn.exec(
            "UPDATE context_prs SET status = 'merged' WHERE pr_id = $1",
            .{pr_id},
        ) catch {};

        try res.json(.{ .merged = true }, .{});
    } else if (std.mem.eql(u8, body.action, "close")) {
        _ = conn.exec(
            "UPDATE context_prs SET status = 'closed' WHERE pr_id = $1",
            .{pr_id},
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "failed to close PR");
        };

        try res.json(.{ .closed = true }, .{});
    } else {
        return apiError(res, 400, "BAD_REQUEST", "action must be 'merge' or 'close'");
    }
}

const CommentRequest = struct {
    body: []const u8,
};

// POST /api/workspaces/:ws_id/context/prs/:pr_id/comments
pub fn handleAddPrComment(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

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

    // Verify PR exists in this workspace
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

// POST /api/workspaces/:ws_id/context/branches/:branch/rebase
pub fn handleRebase(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const branch = req.param("branch") orelse {
        return apiError(res, 400, "BAD_REQUEST", "branch is required");
    };

    if (std.mem.eql(u8, branch, "main")) {
        return apiError(res, 400, "BAD_REQUEST", "cannot rebase main");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    // Get branch base_revision
    var branch_row = conn.row(
        "SELECT base_revision FROM context_branches WHERE ws_id = $1 AND branch_name = $2",
        .{ ws_id, branch },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "branch not found");
    };
    _ = try branch_row.get(i32, 0);
    branch_row.deinit() catch {};

    // Get main revision
    var main_row = conn.row(
        "SELECT revision FROM context_branches WHERE ws_id = $1 AND branch_name = 'main'",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        // No main branch, nothing to rebase from
        try res.json(.{ .branch = branch, .status = "rebased", .new_base_revision = @as(i32, 0) }, .{});
        return;
    };
    const main_rev = try main_row.get(i32, 0);
    main_row.deinit() catch {};

    // Check for conflicts: files changed on both branch and main
    var conflict_result = conn.query(
        \\SELECT bf.path FROM context_files bf
        \\JOIN context_files mf ON mf.ws_id = bf.ws_id AND mf.path = bf.path AND mf.branch_name = 'main'
        \\WHERE bf.ws_id = $1 AND bf.branch_name = $2
        \\AND bf.content_hash != mf.content_hash
        \\AND mf.updated_at > bf.updated_at
    ,
        .{ ws_id, branch },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer conflict_result.deinit();

    const ConflictPath = struct { path: []const u8 };
    var conflicts: std.ArrayList(ConflictPath) = .empty;
    while (try conflict_result.next()) |crow| {
        try conflicts.append(req.arena, .{
            .path = try req.arena.dupe(u8, try crow.get([]const u8, 0)),
        });
    }

    if (conflicts.items.len > 0) {
        // Extract just the path strings for JSON
        var paths: std.ArrayList([]const u8) = .empty;
        for (conflicts.items) |c| {
            try paths.append(req.arena, c.path);
        }
        res.status = 409;
        try res.json(.{
            .branch = branch,
            .status = "conflict",
            .conflicting_files = paths.items,
        }, .{});
        return;
    }

    // No conflicts: apply main changes to branch
    // 1. Add files that exist on main but not on branch
    _ = conn.exec(
        \\INSERT INTO context_files (ws_id, branch_name, path, content, content_hash, author, updated_at)
        \\SELECT ws_id, $2, path, content, content_hash, author, updated_at
        \\FROM context_files WHERE ws_id = $1 AND branch_name = 'main'
        \\AND path NOT IN (SELECT path FROM context_files WHERE ws_id = $1 AND branch_name = $2)
    ,
        .{ ws_id, branch },
    ) catch {};

    // 2. Update branch files where only main changed (branch file unchanged since fork)
    _ = conn.exec(
        \\UPDATE context_files bf SET
        \\    content = mf.content, content_hash = mf.content_hash,
        \\    author = mf.author, updated_at = mf.updated_at
        \\FROM context_files mf
        \\WHERE mf.ws_id = bf.ws_id AND mf.branch_name = 'main' AND mf.path = bf.path
        \\AND bf.ws_id = $1 AND bf.branch_name = $2
        \\AND mf.content_hash != bf.content_hash
        \\AND mf.updated_at > bf.updated_at
    ,
        .{ ws_id, branch },
    ) catch {};

    // Update base_revision
    _ = conn.exec(
        "UPDATE context_branches SET base_revision = $1 WHERE ws_id = $2 AND branch_name = $3",
        .{ main_rev, ws_id, branch },
    ) catch {};

    try res.json(.{
        .branch = branch,
        .status = "rebased",
        .new_base_revision = main_rev,
    }, .{});
}

fn ensureMemberBranch(conn: anytype, ws_id: []const u8, branch: []const u8) void {
    // Get current main revision as base
    var main_row = conn.row(
        "SELECT revision FROM context_branches WHERE ws_id = $1 AND branch_name = 'main'",
        .{ws_id},
    ) catch null;

    var main_rev: i32 = 0;
    if (main_row) |*r| {
        main_rev = r.get(i32, 0) catch 0;
        r.deinit() catch {};
    }

    _ = conn.exec(
        "INSERT INTO context_branches (ws_id, branch_name, base_revision, revision) VALUES ($1, $2, $3, 0) ON CONFLICT DO NOTHING",
        .{ ws_id, branch, main_rev },
    ) catch {};
}
