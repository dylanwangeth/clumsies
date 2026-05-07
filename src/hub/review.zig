//! Organization-level review endpoints. Aggregates PR lifecycles across
//! target types without changing the underlying rule/context ownership.

const std = @import("std");
const httpz = @import("httpz");
const collab_api = @import("clumsies_lib").protocol.collab_api;
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("api_error.zig").send;

const ReviewPrListItem = collab_api.ReviewPrListItem;
const ReviewPrListResponse = collab_api.ReviewPrListResponse;

pub fn handleListPrs(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "pr:read", res)) return;

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const target_filter = qs.get("target");
    const status_filter = qs.get("status") orelse "open";
    if (!isValidTarget(target_filter)) {
        return apiError(res, 400, "BAD_REQUEST", "target must be context, rule, bundle, or mpf");
    }
    if (!isValidStatusFilter(status_filter)) {
        return apiError(res, 400, "BAD_REQUEST", "status must be open, closed, or all");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var list: std.ArrayList(ReviewPrListItem) = .empty;
    if (targetMatches(target_filter, "rule") or targetMatches(target_filter, "mpf")) {
        appendRulePrs(conn, req.arena, user.org_id, status_filter, target_filter, &list) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
    }
    if (targetMatches(target_filter, "context")) {
        appendContextPrs(conn, req.arena, user.user_id, status_filter, &list) catch {
            return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
        };
    }
    std.mem.sort(ReviewPrListItem, list.items, {}, newerFirst);

    try res.json(ReviewPrListResponse{ .prs = list.items }, .{});
}

fn isValidTarget(target: ?[]const u8) bool {
    const t = target orelse return true;
    if (t.len == 0) return true;
    return std.mem.eql(u8, t, "context") or
        std.mem.eql(u8, t, "rule") or
        std.mem.eql(u8, t, "bundle") or
        std.mem.eql(u8, t, "mpf");
}

fn isValidStatusFilter(status: []const u8) bool {
    return std.mem.eql(u8, status, "open") or
        std.mem.eql(u8, status, "closed") or
        std.mem.eql(u8, status, "all");
}

fn targetMatches(target: ?[]const u8, kind: []const u8) bool {
    const t = target orelse return true;
    if (t.len == 0) return true;
    if (std.mem.eql(u8, t, "bundle")) return false;
    return std.mem.eql(u8, t, kind);
}

fn statusMatches(filter: []const u8, status: []const u8) bool {
    if (std.mem.eql(u8, filter, "all")) return true;
    if (std.mem.eql(u8, filter, "open")) return std.mem.eql(u8, status, "open");
    return !std.mem.eql(u8, status, "open");
}

fn newerFirst(_: void, a: ReviewPrListItem, b: ReviewPrListItem) bool {
    return std.mem.order(u8, a.created_at, b.created_at) == .gt;
}

fn appendRulePrs(
    conn: anytype,
    arena: std.mem.Allocator,
    org_id: []const u8,
    status_filter: []const u8,
    target_filter: ?[]const u8,
    list: *std.ArrayList(ReviewPrListItem),
) !void {
    var result = conn.query(
        \\SELECT pp.pr_id, pp.status, pp.title, pp.body, pp.created_at::text, u.username,
        \\  (SELECT count(*) FROM rule_pr_operations op WHERE op.pr_id = pp.pr_id) as op_count,
        \\  COALESCE((
        \\    SELECT op.type
        \\    FROM rule_pr_operations op
        \\    WHERE op.pr_id = pp.pr_id
        \\    ORDER BY op.op_index
        \\    LIMIT 1
        \\  ), '') as op_type,
        \\  (SELECT count(*) FROM rule_pr_comments c WHERE c.pr_id = pp.pr_id) as comment_count,
        \\  COALESCE((
        \\    SELECT COALESCE(r.path, op.path, '')
        \\    FROM rule_pr_operations op
        \\    LEFT JOIN rules r ON r.rule_id = op.rule_id
        \\    WHERE op.pr_id = pp.pr_id
        \\    ORDER BY op.op_index
        \\    LIMIT 1
        \\  ), '') as target_path
        \\FROM rule_prs pp
        \\JOIN users u ON u.user_id = pp.author_id
        \\WHERE pp.org_id = $1::uuid
        \\ORDER BY pp.created_at DESC
    , .{org_id}) catch return error.DatabaseQueryFailed;
    defer result.deinit();

    while (try result.next()) |row| {
        const status = try arena.dupe(u8, try row.get([]const u8, 1));
        if (!statusMatches(status_filter, status)) continue;
        const target_path = try arena.dupe(u8, try row.get([]const u8, 9));
        const target_kind = if (std.mem.eql(u8, target_path, "META_PROMPT.md")) "mpf" else "rule";
        if (target_filter) |tf| {
            if (tf.len > 0 and !std.mem.eql(u8, tf, target_kind)) continue;
        }
        try list.append(arena, .{
            .pr_id = try arena.dupe(u8, try row.get([]const u8, 0)),
            .target_kind = target_kind,
            .target_path = target_path,
            .status = status,
            .title = try arena.dupe(u8, try row.get([]const u8, 2)),
            .body = try arena.dupe(u8, try row.get([]const u8, 3)),
            .created_at = try arena.dupe(u8, try row.get([]const u8, 4)),
            .author = try arena.dupe(u8, try row.get([]const u8, 5)),
            .operation_count = try row.get(i64, 6),
            .op_type = try arena.dupe(u8, try row.get([]const u8, 7)),
            .comment_count = try row.get(i64, 8),
        });
    }
}

fn appendContextPrs(
    conn: anytype,
    arena: std.mem.Allocator,
    user_id: []const u8,
    status_filter: []const u8,
    list: *std.ArrayList(ReviewPrListItem),
) !void {
    var result = conn.query(
        \\SELECT cp.pr_id, cp.ws_id, cp.author, cp.status, cp.title, cp.body, cp.created_at::text,
        \\  (SELECT count(*) FROM context_pr_operations op WHERE op.pr_id = cp.pr_id) as op_count,
        \\  COALESCE((
        \\    SELECT op.type
        \\    FROM context_pr_operations op
        \\    WHERE op.pr_id = cp.pr_id
        \\    ORDER BY op.op_index
        \\    LIMIT 1
        \\  ), '') as op_type,
        \\  (SELECT count(*) FROM context_pr_comments c WHERE c.pr_id = cp.pr_id) as comment_count,
        \\  COALESCE((
        \\    SELECT COALESCE(op.path, cf.path, '')
        \\    FROM context_pr_operations op
        \\    LEFT JOIN workspace_context cf ON cf.context_id = op.context_id AND cf.ws_id = cp.ws_id
        \\    WHERE op.pr_id = cp.pr_id
        \\    ORDER BY op.op_index
        \\    LIMIT 1
        \\  ), '') as target_path
        \\FROM context_prs cp
        \\JOIN workspace_members wm ON wm.ws_id = cp.ws_id AND wm.user_id = $1
        \\ORDER BY cp.created_at DESC
    , .{user_id}) catch return error.DatabaseQueryFailed;
    defer result.deinit();

    while (try result.next()) |row| {
        const status = try arena.dupe(u8, try row.get([]const u8, 3));
        if (!statusMatches(status_filter, status)) continue;
        try list.append(arena, .{
            .pr_id = try arena.dupe(u8, try row.get([]const u8, 0)),
            .target_kind = "context",
            .target_path = try arena.dupe(u8, try row.get([]const u8, 10)),
            .ws_id = try arena.dupe(u8, try row.get([]const u8, 1)),
            .status = status,
            .title = try arena.dupe(u8, try row.get([]const u8, 4)),
            .body = try arena.dupe(u8, try row.get([]const u8, 5)),
            .created_at = try arena.dupe(u8, try row.get([]const u8, 6)),
            .author = try arena.dupe(u8, try row.get([]const u8, 2)),
            .operation_count = try row.get(i64, 7),
            .op_type = try arena.dupe(u8, try row.get([]const u8, 8)),
            .comment_count = try row.get(i64, 9),
        });
    }
}

test "statusMatches groups closed rule and context terminal states" {
    try std.testing.expect(statusMatches("closed", "accepted"));
    try std.testing.expect(statusMatches("closed", "merged"));
    try std.testing.expect(statusMatches("closed", "rejected"));
    try std.testing.expect(!statusMatches("closed", "open"));
}
