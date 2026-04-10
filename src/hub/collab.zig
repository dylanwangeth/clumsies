const std = @import("std");
const httpz = @import("httpz");
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("../protocol/api_error.zig").send;

const CreatePrRequest = struct {
    prompt_id: []const u8,
    base_hash: []const u8,
    content: []const u8,
    description: []const u8,
};

pub fn handleCreatePr(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "pr:write", res)) return;

    const body = req.json(CreatePrRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Verify prompt exists and base_hash matches
    var prompt_row = conn.row(
        "SELECT content_hash FROM prompts WHERE prompt_id = $1 AND org_id = $2::uuid",
        .{ body.prompt_id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "prompt not found");
    };

    const current_hash = try req.arena.dupe(u8, try prompt_row.get([]const u8, 0));
    prompt_row.deinit() catch {};

    if (!std.mem.eql(u8, current_hash, body.base_hash)) {
        return apiError(res, 409, "CONFLICT", "base_hash does not match current Library version");
    }

    // Generate pr_id
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var id_buf: [20]u8 = undefined;
    @memcpy(id_buf[0..4], "ppr-");
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |byte, i| {
        id_buf[4 + i * 2] = hex_chars[byte >> 4];
        id_buf[4 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    _ = conn.exec(
        \\INSERT INTO prompt_prs (pr_id, org_id, prompt_id, author_id, base_hash, content, description)
        \\VALUES ($1, $2::uuid, $3, $4, $5, $6, $7)
    , .{ &id_buf, user.org_id, body.prompt_id, user.user_id, body.base_hash, body.content, body.description }) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to create prompt PR");
    };

    res.status = 201;
    try res.json(.{
        .pr_id = &id_buf,
        .status = "open",
    }, .{});
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
    const prompt_filter = qs.get("prompt_id");

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    const PrMeta = struct {
        pr_id: []const u8,
        prompt_id: []const u8,
        status: []const u8,
        description: []const u8,
        created_at: []const u8,
    };

    var list: std.ArrayList(PrMeta) = .empty;

    // Use separate query calls for each filter combination
    if (status_filter) |sf| {
        if (prompt_filter) |pf| {
            var result = conn.query(
                "SELECT pr_id, prompt_id, status, description, created_at::text FROM prompt_prs WHERE org_id = $1::uuid AND status = $2 AND prompt_id = $3 ORDER BY created_at DESC",
                .{ user.org_id, sf, pf },
            ) catch {
                return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            };
            defer result.deinit();
            while (try result.next()) |row| {
                try list.append(req.arena, .{
                    .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                    .prompt_id = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                    .status = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                    .description = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                    .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
                });
            }
        } else {
            var result = conn.query(
                "SELECT pr_id, prompt_id, status, description, created_at::text FROM prompt_prs WHERE org_id = $1::uuid AND status = $2 ORDER BY created_at DESC",
                .{ user.org_id, sf },
            ) catch {
                return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            };
            defer result.deinit();
            while (try result.next()) |row| {
                try list.append(req.arena, .{
                    .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                    .prompt_id = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                    .status = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                    .description = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                    .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
                });
            }
        }
    } else {
        if (prompt_filter) |pf| {
            var result = conn.query(
                "SELECT pr_id, prompt_id, status, description, created_at::text FROM prompt_prs WHERE org_id = $1::uuid AND prompt_id = $2 ORDER BY created_at DESC",
                .{ user.org_id, pf },
            ) catch {
                return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            };
            defer result.deinit();
            while (try result.next()) |row| {
                try list.append(req.arena, .{
                    .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                    .prompt_id = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                    .status = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                    .description = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                    .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
                });
            }
        } else {
            var result = conn.query(
                "SELECT pr_id, prompt_id, status, description, created_at::text FROM prompt_prs WHERE org_id = $1::uuid ORDER BY created_at DESC",
                .{user.org_id},
            ) catch {
                return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            };
            defer result.deinit();
            while (try result.next()) |row| {
                try list.append(req.arena, .{
                    .pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
                    .prompt_id = try req.arena.dupe(u8, try row.get([]const u8, 1)),
                    .status = try req.arena.dupe(u8, try row.get([]const u8, 2)),
                    .description = try req.arena.dupe(u8, try row.get([]const u8, 3)),
                    .created_at = try req.arena.dupe(u8, try row.get([]const u8, 4)),
                });
            }
        }
    }

    try res.json(.{ .prs = list.items }, .{});
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
        "SELECT pr_id, prompt_id, base_hash, status, content, description, created_at::text FROM prompt_prs WHERE pr_id = $1 AND org_id = $2::uuid",
        .{ id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "prompt PR not found");
    };

    const pr_id = try req.arena.dupe(u8, try row.get([]const u8, 0));
    const prompt_id = try req.arena.dupe(u8, try row.get([]const u8, 1));
    const base_hash = try req.arena.dupe(u8, try row.get([]const u8, 2));
    const status = try req.arena.dupe(u8, try row.get([]const u8, 3));
    const pr_content = try req.arena.dupe(u8, try row.get([]const u8, 4));
    const description = try req.arena.dupe(u8, try row.get([]const u8, 5));
    const created_at = try req.arena.dupe(u8, try row.get([]const u8, 6));
    row.deinit() catch {};

    // Compute trace_summary from trace_events
    const TraceSummary = struct {
        refer_count: i64 = 0,
        sessions_used: i64 = 0,
        last_referred: ?[]const u8 = null,
    };
    var trace_summary = TraceSummary{};

    var trace_row = conn.row(
        "SELECT count(*), count(DISTINCT session_id), max(to_timestamp(timestamp/1000))::text FROM trace_events WHERE prompt_id = $1 AND type = 'refer'",
        .{prompt_id},
    ) catch null;
    if (trace_row) |*tr| {
        trace_summary.refer_count = tr.get(i64, 0) catch 0;
        trace_summary.sessions_used = tr.get(i64, 1) catch 0;
        if (tr.get(?[]const u8, 2) catch null) |last_ref| {
            trace_summary.last_referred = req.arena.dupe(u8, last_ref) catch null;
        }
        tr.deinit() catch {};
    }

    // Fetch base content for diff: try current prompt content first, fall back to prompt_history
    var base_content: ?[]const u8 = null;
    var base_row = conn.row(
        "SELECT content, content_hash FROM prompts WHERE prompt_id = $1",
        .{prompt_id},
    ) catch null;
    if (base_row) |*br| {
        const current_hash = br.get([]const u8, 1) catch "";
        if (std.mem.eql(u8, current_hash, base_hash)) {
            base_content = req.arena.dupe(u8, br.get([]const u8, 0) catch "") catch null;
        }
        br.deinit() catch {};
    }

    // If hash doesn't match current, try prompt_history
    if (base_content == null) {
        var hist_row = conn.row(
            "SELECT content FROM prompt_history WHERE prompt_id = $1 AND content_hash = $2",
            .{ prompt_id, base_hash },
        ) catch null;
        if (hist_row) |*hr| {
            base_content = req.arena.dupe(u8, hr.get([]const u8, 0) catch "") catch null;
            hr.deinit() catch {};
        }
    }

    try res.json(.{
        .pr_id = pr_id,
        .prompt_id = prompt_id,
        .base_hash = base_hash,
        .status = status,
        .content = pr_content,
        .description = description,
        .created_at = created_at,
        .trace_summary = trace_summary,
        .diff = .{
            .base = base_content,
            .proposed = pr_content,
            .summary = computeDiffSummary(req.arena, base_content orelse "", pr_content),
        },
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
        return apiError(res, 403, "FORBIDDEN", "only maintainers can accept or reject prompt PRs");
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

    var prop_row = conn.row(
        "SELECT prompt_id, base_hash, content, status FROM prompt_prs WHERE pr_id = $1 AND org_id = $2::uuid",
        .{ id, user.org_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "prompt PR not found");
    };

    const prompt_id = try req.arena.dupe(u8, try prop_row.get([]const u8, 0));
    const base_hash = try req.arena.dupe(u8, try prop_row.get([]const u8, 1));
    const new_content = try req.arena.dupe(u8, try prop_row.get([]const u8, 2));
    const status = try req.arena.dupe(u8, try prop_row.get([]const u8, 3));
    prop_row.deinit() catch {};

    if (!std.mem.eql(u8, status, "open")) {
        return apiError(res, 400, "BAD_REQUEST", "prompt PR is not open");
    }

    if (std.mem.eql(u8, body.action, "accept")) {
        // Verify base_hash still matches Library
        var check_row = conn.row(
            "SELECT content_hash FROM prompts WHERE prompt_id = $1",
            .{prompt_id},
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        } orelse {
            return apiError(res, 404, "NOT_FOUND", "target prompt no longer exists");
        };

        const current_hash = try req.arena.dupe(u8, try check_row.get([]const u8, 0));
        check_row.deinit() catch {};

        if (!std.mem.eql(u8, current_hash, base_hash)) {
            return apiError(res, 409, "CONFLICT", "Library has changed since prompt PR was created");
        }

        // Compute new hash and update prompt
        const new_hash = @import("../protocol/hash.zig").ContentHash.compute(new_content);
        const hash_slice: []const u8 = try req.arena.dupe(u8, &new_hash);

        _ = conn.exec(
            "UPDATE prompts SET content = $1, content_hash = $2, updated_at = now() WHERE prompt_id = $3",
            .{ new_content, hash_slice, prompt_id },
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "failed to update prompt");
        };

        // Bump revision for all workspaces containing this prompt
        _ = conn.exec(
            "UPDATE workspaces SET revision = revision + 1 WHERE ws_id IN (SELECT ws_id FROM workspace_prompts WHERE prompt_id = $1)",
            .{prompt_id},
        ) catch {};

        // Record in prompt history
        _ = conn.exec(
            "INSERT INTO prompt_history (prompt_id, content_hash, content, pr_id) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
            .{ prompt_id, hash_slice, new_content, id },
        ) catch {};

        // Bump library manifest revision
        _ = conn.exec(
            "UPDATE library_manifest SET revision = revision + 1 WHERE org_id = $1::uuid",
            .{user.org_id},
        ) catch {};
    }

    // Update prompt PR status
    _ = conn.exec(
        "UPDATE prompt_prs SET status = $1, updated_at = now() WHERE pr_id = $2",
        .{ if (std.mem.eql(u8, body.action, "accept")) @as([]const u8, "accepted") else @as([]const u8, "rejected"), id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to update prompt PR");
    };

    try res.json(.{
        .pr_id = id,
        .status = if (std.mem.eql(u8, body.action, "accept")) @as([]const u8, "accepted") else @as([]const u8, "rejected"),
    }, .{});
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

    // Verify prompt PR exists
    var pr_row = conn.row("SELECT pr_id FROM prompt_prs WHERE pr_id = $1", .{id}) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "prompt PR not found");
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
        "INSERT INTO prompt_pr_comments (comment_id, pr_id, author_id, body) VALUES ($1, $2, $3, $4)",
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

    const CommentMeta = struct {
        comment_id: []const u8,
        author_id: []const u8,
        body: []const u8,
        created_at: []const u8,
    };

    var result = conn.query(
        "SELECT comment_id, author_id, body, created_at::text FROM prompt_pr_comments WHERE pr_id = $1 ORDER BY created_at",
        .{id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(CommentMeta) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .comment_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .author_id = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .body = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .created_at = try req.arena.dupe(u8, try row.get([]const u8, 3)),
        });
    }

    try res.json(.{ .comments = list.items }, .{});
}

fn computeDiffSummary(arena: std.mem.Allocator, base: []const u8, proposed: []const u8) []const u8 {
    var added: usize = 0;
    var removed: usize = 0;

    var base_lines: usize = 0;
    var proposed_lines: usize = 0;

    for (base) |c| {
        if (c == '\n') base_lines += 1;
    }
    if (base.len > 0 and base[base.len - 1] != '\n') base_lines += 1;

    for (proposed) |c| {
        if (c == '\n') proposed_lines += 1;
    }
    if (proposed.len > 0 and proposed[proposed.len - 1] != '\n') proposed_lines += 1;

    if (proposed_lines > base_lines) {
        added = proposed_lines - base_lines;
    } else {
        removed = base_lines - proposed_lines;
    }

    return std.fmt.allocPrint(arena, "+{d} -{d} lines", .{ added, removed }) catch "diff unavailable";
}
