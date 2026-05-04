//! Hub workspace endpoints. A workspace is a project's working environment: a subset of Artifact
//! rules plus its own context. These endpoints handle workspace CRUD and serve the manifest
//! that drives the client sync protocol.
const std = @import("std");
const httpz = @import("httpz");
const manifest = @import("clumsies_lib").protocol.manifest;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("api_error.zig").send;
const ManifestMap = manifest.ManifestMap;
const ManifestItem = manifest.ManifestItem;
const WorkspaceManifestResponse = workspace_api.WorkspaceManifestResponse;
const CreateWorkspaceRequest = workspace_api.CreateWorkspaceRequest;
const CreateWorkspaceResponse = workspace_api.CreateWorkspaceResponse;

pub fn handleCreate(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "workspace:write", res)) return;

    const body = req.json(CreateWorkspaceRequest) catch {
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

    // Creator becomes workspace admin
    _ = conn.exec(
        "INSERT INTO workspace_members (ws_id, user_id, role) VALUES ($1, $2, 'admin')",
        .{ &ws_id_buf, user.user_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "failed to add creator as admin");
    };

    // Initialize workspace from bundle if specified
    if (body.bundle_id) |bid| {
        initFromBundle(conn, &ws_id_buf, bid);
    }

    res.status = 201;
    try res.json(CreateWorkspaceResponse{
        .ws_id = ws_id_buf[0..],
        .name = body.name,
        .revision = 0,
    }, .{});
}

pub fn handleGet(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
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
    if (!auth.requireScope(user, "workspace:write", res)) return;

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

    const rules = try collectManifestMap(req.arena, conn, "SELECT wp.rule_id, p.path, p.content_hash, p.description FROM workspace_rules wp JOIN rules p ON p.rule_id = wp.rule_id WHERE wp.ws_id = $1", .{ws_id});

    const context = try collectManifestMap(req.arena, conn, "SELECT context_id, path, content_hash, description FROM workspace_context WHERE ws_id = $1", .{ws_id});

    var etag_buf: [32]u8 = undefined;
    const etag_slice = std.fmt.bufPrint(&etag_buf, "\"rev-{d}\"", .{revision}) catch "";
    res.header("ETag", try req.arena.dupe(u8, etag_slice));

    try res.json(WorkspaceManifestResponse{
        .ws_id = ws_id_val,
        .name = ws_name,
        .revision = revision,
        .rules = rules,
        .context = context,
    }, .{});
}

const AddRuleRequest = struct {
    rule_id: []const u8,
};

pub fn handleAddRule(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "workspace:write", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const body = req.json(AddRuleRequest) catch {
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

    var rule_row = conn.row(
        "SELECT rule_id FROM rules WHERE rule_id = $1",
        .{body.rule_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "rule not found");
    };
    rule_row.deinit() catch {};

    _ = conn.exec(
        "INSERT INTO workspace_rules (ws_id, rule_id) VALUES ($1, $2)",
        .{ ws_id, body.rule_id },
    ) catch {
        if (conn.err) |pg_err| {
            if (std.mem.indexOf(u8, pg_err.message, "duplicate") != null) {
                return apiError(res, 409, "CONFLICT", "rule already in workspace");
            }
        }
        return apiError(res, 500, "INTERNAL_ERROR", "failed to add rule");
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

pub fn handleRemoveRule(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "workspace:write", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const rule_id = req.param("rule_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "rule_id is required");
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
        "DELETE FROM workspace_rules WHERE ws_id = $1 AND rule_id = $2",
        .{ ws_id, rule_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };

    if (deleted == null or deleted.? == 0) {
        return apiError(res, 404, "NOT_FOUND", "rule not in workspace");
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
        "SELECT rule_id FROM bundle_rules WHERE bundle_id = $1",
        .{bundle_id},
    ) catch return;
    defer result.deinit();

    while (result.next() catch null) |brow| {
        const pid = brow.get([]const u8, 0) catch continue;
        _ = conn.exec(
            "INSERT INTO workspace_rules (ws_id, rule_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
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
    if (!auth.requireScope(user, "workspace:write", res)) return;
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

    // Cascade delete: comments, pr_files, prs, files, branches, members, rule refs, then workspace
    _ = conn.exec("DELETE FROM context_pr_comments WHERE pr_id IN (SELECT pr_id FROM context_prs WHERE ws_id = $1)", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM context_pr_files WHERE pr_id IN (SELECT pr_id FROM context_prs WHERE ws_id = $1)", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM context_prs WHERE ws_id = $1", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM workspace_context WHERE ws_id = $1", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM context_branches WHERE ws_id = $1", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM workspace_members WHERE ws_id = $1", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM workspace_rules WHERE ws_id = $1", .{ws_id}) catch {};
    _ = conn.exec("DELETE FROM workspaces WHERE ws_id = $1", .{ws_id}) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database delete failed");
    };

    res.status = 204;
}

// Workspace membership management

const MemberInfo = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    joined_at: []const u8,
};

pub fn handleListMembers(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "members:read", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Verify workspace exists
    var ws_check = conn.row("SELECT 1 FROM workspaces WHERE ws_id = $1", .{ws_id}) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    if (ws_check) |*wc| {
        wc.deinit() catch {};
    } else {
        return apiError(res, 404, "NOT_FOUND", "workspace not found");
    }

    if (!std.mem.eql(u8, user.role, "maintainer") and !auth.checkWorkspaceMember(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "not a member of this workspace");
    }

    var result = conn.query(
        \\SELECT wm.user_id, u.username, wm.role, wm.joined_at::text
        \\FROM workspace_members wm JOIN users u ON u.user_id = wm.user_id
        \\WHERE wm.ws_id = $1 ORDER BY u.username
    , .{ws_id}) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    defer result.deinit();

    var list: std.ArrayList(MemberInfo) = .empty;
    while (try result.next()) |row| {
        try list.append(req.arena, .{
            .user_id = try req.arena.dupe(u8, try row.get([]const u8, 0)),
            .username = try req.arena.dupe(u8, try row.get([]const u8, 1)),
            .role = try req.arena.dupe(u8, try row.get([]const u8, 2)),
            .joined_at = try req.arena.dupe(u8, try row.get([]const u8, 3)),
        });
    }

    try res.json(.{ .members = list.items }, .{});
}

const InviteRequest = struct {
    user_id: []const u8,
    role: []const u8 = "member",
};

pub fn handleInviteMember(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "members:write", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const body = req.json(InviteRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (!std.mem.eql(u8, body.role, "member") and !std.mem.eql(u8, body.role, "admin")) {
        return apiError(res, 400, "BAD_REQUEST", "role must be member or admin");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!std.mem.eql(u8, user.role, "maintainer") and !auth.checkWorkspaceAdmin(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "ws:admin or maintainer required");
    }

    var org_check = conn.row(
        "SELECT 1 FROM users u JOIN workspaces w ON w.org_id = u.org_id WHERE u.user_id = $1 AND w.ws_id = $2",
        .{ body.user_id, ws_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        return apiError(res, 404, "NOT_FOUND", "user not found in org");
    };
    org_check.deinit() catch {};

    _ = conn.exec(
        "INSERT INTO workspace_members (ws_id, user_id, role) VALUES ($1, $2, $3)",
        .{ ws_id, body.user_id, body.role },
    ) catch {
        if (conn.err) |pg_err| {
            if (std.mem.indexOf(u8, pg_err.message, "unique") != null or
                std.mem.indexOf(u8, pg_err.message, "duplicate") != null)
            {
                return apiError(res, 409, "CONFLICT", "user is already a member");
            }
        }
        return apiError(res, 500, "INTERNAL_ERROR", "failed to add member");
    };

    res.status = 201;
    try res.json(.{ .user_id = body.user_id, .role = body.role }, .{});
}

const RoleChangeRequest = struct {
    role: []const u8,
};

pub fn handleChangeMemberRole(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "members:write", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const target_id = req.param("user_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "user_id is required");
    };

    const body = req.json(RoleChangeRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (!std.mem.eql(u8, body.role, "member") and !std.mem.eql(u8, body.role, "admin")) {
        return apiError(res, 400, "BAD_REQUEST", "role must be member or admin");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    if (!std.mem.eql(u8, user.role, "maintainer") and !auth.checkWorkspaceAdmin(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "ws:admin or maintainer required");
    }

    // Prevent downgrading the last admin
    if (std.mem.eql(u8, body.role, "member")) {
        var admin_count = conn.row(
            "SELECT count(*) FROM workspace_members WHERE ws_id = $1 AND role = 'admin'",
            .{ws_id},
        ) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        } orelse {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        const count = admin_count.get(i64, 0) catch {
            admin_count.deinit() catch {};
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        admin_count.deinit() catch {};
        if (count <= 1) {
            var is_target_admin = conn.row(
                "SELECT 1 FROM workspace_members WHERE ws_id = $1 AND user_id = $2 AND role = 'admin'",
                .{ ws_id, target_id },
            ) catch {
                return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            };
            if (is_target_admin) |*r| {
                r.deinit() catch {};
                return apiError(res, 400, "BAD_REQUEST", "cannot downgrade the last admin");
            }
        }
    }

    const updated = conn.exec(
        "UPDATE workspace_members SET role = $3 WHERE ws_id = $1 AND user_id = $2",
        .{ ws_id, target_id, body.role },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database update failed");
    };

    if (updated == null or updated.? == 0) {
        return apiError(res, 404, "NOT_FOUND", "member not found");
    }

    try res.json(.{ .user_id = target_id, .role = body.role }, .{});
}

pub fn handleRemoveWsMember(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "members:write", res)) return;

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };
    const target_id = req.param("user_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "user_id is required");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    // Self-leave allowed, otherwise need admin/maintainer
    const is_self = std.mem.eql(u8, target_id, user.user_id);
    if (!is_self and !std.mem.eql(u8, user.role, "maintainer") and !auth.checkWorkspaceAdmin(conn, ws_id, user.user_id)) {
        return apiError(res, 403, "FORBIDDEN", "ws:admin or maintainer required");
    }

    // Prevent removing the last admin
    var admin_check = conn.row(
        "SELECT count(*) FROM workspace_members WHERE ws_id = $1 AND role = 'admin'",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    };
    if (admin_check) |*ac| {
        const count = ac.get(i64, 0) catch {
            ac.deinit() catch {};
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
        ac.deinit() catch {};
        if (count <= 1) {
            var is_target_admin = conn.row(
                "SELECT 1 FROM workspace_members WHERE ws_id = $1 AND user_id = $2 AND role = 'admin'",
                .{ ws_id, target_id },
            ) catch {
                return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
            };
            if (is_target_admin) |*r| {
                r.deinit() catch {};
                return apiError(res, 400, "BAD_REQUEST", "cannot remove the last admin");
            }
        }
    }

    _ = conn.exec(
        "DELETE FROM workspace_members WHERE ws_id = $1 AND user_id = $2",
        .{ ws_id, target_id },
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database delete failed");
    };

    res.status = 204;
}

fn collectManifestMap(arena: std.mem.Allocator, conn: anytype, sql: []const u8, params: anytype) !ManifestMap {
    var result = conn.query(sql, params) catch return ManifestMap{ .items = &.{} };
    defer result.deinit();

    var items: std.ArrayList(ManifestItem) = .empty;
    while (try result.next()) |row| {
        try items.append(arena, .{
            .key = try arena.dupe(u8, try row.get([]const u8, 0)),
            .value = .{
                .path = try arena.dupe(u8, try row.get([]const u8, 1)),
                .hash = try arena.dupe(u8, try row.get([]const u8, 2)),
                .description = try arena.dupe(u8, try row.get([]const u8, 3)),
            },
        });
    }

    return ManifestMap{ .items = items.items };
}
