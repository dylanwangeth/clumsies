const std = @import("std");
const httpz = @import("httpz");
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("../protocol/api_error.zig").send;

const TraceEventInput = struct {
    event_id: i64,
    session_id: []const u8,
    ws_id: []const u8,
    type: []const u8,
    timestamp: i64,
    prompt_id: ?[]const u8 = null,
    prompt_hash: ?[]const u8 = null,
    constraint_id: ?[]const u8 = null,
    override_base_hash: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    content: ?[]const u8 = null,
    content_hash: ?[]const u8 = null,
};

const BatchRequest = struct {
    events: []const TraceEventInput,
};

const ConstraintStat = struct {
    constraint_id: []const u8,
    refer_count: i64,
};

const TrendEntry = struct {
    date: []const u8,
    refer_count: i64,
};

fn parsePeriod(period: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, period, "daily")) return "day";
    if (std.mem.eql(u8, period, "weekly")) return "week";
    if (std.mem.eql(u8, period, "monthly")) return "month";
    return null;
}

fn queryTrend(
    conn: anytype,
    arena: std.mem.Allocator,
    sql_trunc: []const u8,
    where_clause: []const u8,
    bind: anytype,
) []const TrendEntry {
    const query = std.fmt.allocPrint(
        arena,
        "SELECT date_trunc('{s}', to_timestamp(timestamp/1000))::date::text as date, count(*) as refer_count" ++
            " FROM trace_events WHERE {s} AND type = 'refer'" ++
            " GROUP BY 1 ORDER BY 1",
        .{ sql_trunc, where_clause },
    ) catch return &.{};

    var result = conn.query(query, bind) catch return &.{};
    defer result.deinit();

    var list: std.ArrayList(TrendEntry) = .empty;
    while (result.next() catch return list.items) |row| {
        list.append(arena, .{
            .date = arena.dupe(u8, row.get([]const u8, 0) catch continue) catch continue,
            .refer_count = row.get(i64, 1) catch continue,
        }) catch continue;
    }
    return list.items;
}

pub fn handleUpload(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const client_ip = req.header("x-forwarded-for") orelse "unknown";
    if (!ctx.rate_limiter.check(client_ip)) {
        return apiError(res, 429, "TOO_MANY_REQUESTS", "rate limit exceeded");
    }

    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "trace:write", res)) return;

    const batch = req.json(BatchRequest) catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid JSON body");
    } orelse {
        return apiError(res, 400, "BAD_REQUEST", "missing request body");
    };

    if (batch.events.len > 1000) {
        return apiError(res, 413, "PAYLOAD_TOO_LARGE", "max 1000 events per batch");
    }

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var accepted: i32 = 0;
    var deduplicated: i32 = 0;

    for (batch.events) |event| {
        // Validate prompt_id exists if provided
        if (event.prompt_id) |pid| {
            var check = conn.row("SELECT 1 FROM prompts WHERE prompt_id = $1", .{pid}) catch {
                deduplicated += 1;
                continue;
            };
            if (check) |*c| {
                c.deinit() catch {};
            } else {
                deduplicated += 1;
                continue;
            }
        }
        _ = conn.exec(
            \\INSERT INTO trace_events (ws_id, session_id, event_id, type, timestamp,
            \\  prompt_id, prompt_hash, constraint_id, override_base_hash, reason, content, content_hash)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            \\ON CONFLICT (ws_id, session_id, event_id) DO NOTHING
        , .{
            event.ws_id,       event.session_id,          @as(i64, event.event_id),
            event.type,        @as(i64, event.timestamp), event.prompt_id,
            event.prompt_hash, event.constraint_id,       event.override_base_hash,
            event.reason,      event.content,             event.content_hash,
        }) catch {
            deduplicated += 1;
            continue;
        };
        accepted += 1;
    }

    try res.json(.{
        .accepted = accepted,
        .deduplicated = deduplicated,
    }, .{});
}

pub fn handleOrgStats(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const period = qs.get("period") orelse "daily";
    const sql_trunc = parsePeriod(period) orelse {
        return apiError(res, 400, "BAD_REQUEST", "invalid period; use daily, weekly, or monthly");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        \\SELECT
        \\  (SELECT count(*) FROM trace_events te JOIN workspaces w ON w.ws_id = te.ws_id WHERE w.org_id = $1::uuid AND te.type = 'refer') as refer_count,
        \\  (SELECT count(*) FROM workspaces WHERE org_id = $1::uuid) as ws_count,
        \\  (SELECT count(*) FROM prompts WHERE org_id = $1::uuid) as prompt_count
    , .{user.org_id}) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        try res.json(.{ .total_refer_count = @as(i64, 0), .workspace_count = @as(i64, 0), .prompt_count = @as(i64, 0), .trend = .{ .period = period, .data = @as([]const TrendEntry, &.{}) } }, .{});
        return;
    };
    defer row.deinit() catch {};

    const trend_data = queryTrend(
        conn,
        req.arena,
        sql_trunc,
        "ws_id IN (SELECT ws_id FROM workspaces WHERE org_id = $1::uuid)",
        .{user.org_id},
    );

    try res.json(.{
        .total_refer_count = try row.get(i64, 0),
        .workspace_count = try row.get(i64, 1),
        .prompt_count = try row.get(i64, 2),
        .trend = .{ .period = period, .data = trend_data },
    }, .{});
}

pub fn handleWorkspaceStats(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const ws_id = req.param("ws_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "ws_id is required");
    };

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const period = qs.get("period") orelse "daily";
    const sql_trunc = parsePeriod(period) orelse {
        return apiError(res, 400, "BAD_REQUEST", "invalid period; use daily, weekly, or monthly");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT count(*) FROM trace_events WHERE ws_id = $1 AND type = 'refer'",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        try res.json(.{ .ws_id = ws_id, .total_refer_count = @as(i64, 0), .constraint_coverage = @as(f64, 0.0), .trend = .{ .period = period, .data = @as([]const TrendEntry, &.{}) } }, .{});
        return;
    };
    defer row.deinit() catch {};

    const total_refer_count = try row.get(i64, 0);

    // Query constraint coverage: fraction of workspace prompts that have been referred
    var coverage: f64 = 0.0;
    var cov_row = conn.row(
        \\SELECT count(DISTINCT te.prompt_id)::float / GREATEST(count(DISTINCT wp.prompt_id), 1)
        \\FROM workspace_prompts wp
        \\LEFT JOIN trace_events te ON te.prompt_id = wp.prompt_id AND te.ws_id = wp.ws_id AND te.type = 'refer'
        \\WHERE wp.ws_id = $1
    , .{ws_id}) catch null;
    if (cov_row != null) {
        coverage = cov_row.?.get(f64, 0) catch 0.0;
        cov_row.?.deinit() catch {};
    }

    // Per-prompt refer counts
    const PromptRef = struct {
        prompt_id: []const u8,
        refer_count: i64,
    };
    var prompt_list: std.ArrayList(PromptRef) = .empty;

    const prompt_result = conn.query(
        "SELECT prompt_id, count(*) FROM trace_events WHERE ws_id = $1 AND type = 'refer' AND prompt_id IS NOT NULL GROUP BY prompt_id ORDER BY count(*) DESC",
        .{ws_id},
    ) catch null;
    if (prompt_result) |pr| {
        defer pr.deinit();
        while (pr.next() catch null) |prow| {
            prompt_list.append(req.arena, .{
                .prompt_id = req.arena.dupe(u8, prow.get([]const u8, 0) catch continue) catch continue,
                .refer_count = prow.get(i64, 1) catch continue,
            }) catch continue;
        }
    }

    const trend_data = queryTrend(conn, req.arena, sql_trunc, "ws_id = $1", .{ws_id});

    try res.json(.{
        .ws_id = ws_id,
        .total_refer_count = total_refer_count,
        .constraint_coverage = coverage,
        .prompts = prompt_list.items,
        .trend = .{ .period = period, .data = trend_data },
    }, .{});
}

pub fn handlePromptStats(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const prompt_id = req.param("prompt_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "prompt_id is required");
    };

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const period = qs.get("period") orelse "daily";
    const sql_trunc = parsePeriod(period) orelse {
        return apiError(res, 400, "BAD_REQUEST", "invalid period; use daily, weekly, or monthly");
    };

    const conn = ctx.pool.acquire() catch {
        return apiError(res, 503, "SERVICE_UNAVAILABLE", "database unavailable");
    };
    defer conn.release();

    var row = conn.row(
        "SELECT count(*) FROM trace_events WHERE prompt_id = $1 AND type = 'refer'",
        .{prompt_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        try res.json(.{ .prompt_id = prompt_id, .total_refer_count = @as(i64, 0), .constraints = @as([]const ConstraintStat, &.{}), .trend = .{ .period = period, .data = @as([]const TrendEntry, &.{}) } }, .{});
        return;
    };
    const total_refer_count = try row.get(i64, 0);
    row.deinit() catch {};

    // Query per-constraint breakdown
    var constraint_result = conn.query(
        "SELECT constraint_id, count(*) as cnt FROM trace_events WHERE prompt_id = $1 AND type = 'refer' AND constraint_id IS NOT NULL GROUP BY constraint_id ORDER BY cnt DESC",
        .{prompt_id},
    ) catch {
        try res.json(.{ .prompt_id = prompt_id, .total_refer_count = total_refer_count, .constraints = @as([]const ConstraintStat, &.{}), .trend = .{ .period = period, .data = @as([]const TrendEntry, &.{}) } }, .{});
        return;
    };
    defer constraint_result.deinit();

    var constraints: std.ArrayList(ConstraintStat) = .empty;
    while (constraint_result.next() catch null) |crow| {
        constraints.append(req.arena, .{
            .constraint_id = req.arena.dupe(u8, crow.get([]const u8, 0) catch continue) catch continue,
            .refer_count = crow.get(i64, 1) catch continue,
        }) catch continue;
    }

    const trend_data = queryTrend(conn, req.arena, sql_trunc, "prompt_id = $1", .{prompt_id});

    try res.json(.{
        .prompt_id = prompt_id,
        .total_refer_count = total_refer_count,
        .constraints = constraints.items,
        .trend = .{ .period = period, .data = trend_data },
    }, .{});
}
