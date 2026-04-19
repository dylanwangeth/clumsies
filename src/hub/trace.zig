//! Hub trace endpoints. Ingests trace events uploaded by clients (POST /api/traces), stores them
//! in PostgreSQL, and serves aggregated statistics: refer counts, signal ratios, per-prompt and
//! per-user trends for the TUI dashboard.
const std = @import("std");
const httpz = @import("httpz");
const stats_api = @import("clumsies_lib").protocol.stats_api;
const Server = @import("server.zig");
const auth = @import("auth.zig");
const apiError = @import("api_error.zig").send;
const log = std.log.scoped(.trace_stats);
const OrgPromptStats = stats_api.OrgPromptStat;
const OrgStatsResponse = stats_api.OrgStatsResponse;
const OrgUserStats = stats_api.OrgUserStat;
const TrendEntry = stats_api.TrendPoint;
const TrendSeries = stats_api.TrendSeries;
const UserTopPromptStat = stats_api.OrgUserTopPromptStat;
const WorkspacePromptStat = stats_api.WorkspacePromptStat;
const WorkspaceStatsResponse = stats_api.WorkspaceStatsResponse;

const TraceEventInput = struct {
    event_id: i64,
    session_id: []const u8,
    ws_id: []const u8,
    type: []const u8,
    timestamp: i64,
    prompt_id: ?[]const u8 = null,
    prompt_hash: ?[]const u8 = null,
    constraint_id: ?[]const u8 = null,
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

fn parsePeriod(period: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, period, "daily")) return "day";
    if (std.mem.eql(u8, period, "weekly")) return "week";
    if (std.mem.eql(u8, period, "monthly")) return "month";
    return null;
}

fn defaultDays(period: []const u8) u32 {
    if (std.mem.eql(u8, period, "daily")) return 7;
    if (std.mem.eql(u8, period, "weekly")) return 56; // 8 weeks
    if (std.mem.eql(u8, period, "monthly")) return 365; // 12 months
    return 30;
}

fn queryTrend(
    conn: anytype,
    arena: std.mem.Allocator,
    sql_trunc: []const u8,
    where_clause: []const u8,
    bind: anytype,
    max_days: u32,
) []const TrendEntry {
    const days_filter = std.fmt.allocPrint(arena, " AND timestamp >= (extract(epoch from now()) * 1000 - {d}::bigint * 86400000)", .{max_days}) catch "";

    const query = std.fmt.allocPrint(
        arena,
        "SELECT date_trunc('{s}', to_timestamp(timestamp/1000))::date::text as date, count(*) as refer_count" ++
            " FROM trace_events WHERE {s} AND type = 'refer'{s}" ++
            " GROUP BY 1 ORDER BY 1",
        .{ sql_trunc, where_clause, days_filter },
    ) catch return &.{};

    var result = conn.query(query, bind) catch |err| {
        log.err("trend query failed: {}", .{err});
        return &.{};
    };
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

fn recentCutoffMs(max_days: u32) i64 {
    return std.time.milliTimestamp() - @as(i64, max_days) * std.time.ms_per_day;
}

fn zeroTrendSeries(arena: std.mem.Allocator, max_days: u32) []i64 {
    const len: usize = @intCast(max_days);
    const buf = arena.alloc(i64, len) catch return &.{};
    @memset(buf, 0);
    return buf;
}

fn setTrendBucket(series: []i64, age_days: i64, count: i64) void {
    if (age_days < 0) return;
    const days: usize = @intCast(age_days);
    if (days >= series.len) return;
    const idx = series.len - 1 - days;
    series[idx] = count;
}

fn queryPromptTrendSeries(
    conn: anytype,
    arena: std.mem.Allocator,
    org_id: []const u8,
    max_days: u32,
) std.StringHashMap([]i64) {
    var series_by_prompt = std.StringHashMap([]i64).init(arena);
    const cutoff_ms = recentCutoffMs(max_days);

    var result = conn.query(
        \\SELECT te.prompt_id,
        \\  floor(extract(epoch from (date_trunc('day', now()) - date_trunc('day', to_timestamp(te.timestamp / 1000)))) / 86400)::bigint as age_days,
        \\  count(*) as refer_count
        \\FROM trace_events te
        \\JOIN workspaces w ON w.ws_id = te.ws_id
        \\WHERE w.org_id = $1::uuid
        \\  AND te.type = 'refer'
        \\  AND te.prompt_id IS NOT NULL
        \\  AND te.timestamp >= $2
        \\GROUP BY te.prompt_id, age_days
        \\ORDER BY te.prompt_id, age_days
    , .{ org_id, cutoff_ms }) catch |err| {
        log.err("prompt trend query failed: {}", .{err});
        return series_by_prompt;
    };
    defer result.deinit();

    while (result.next() catch null) |row| {
        const prompt_id = row.get([]const u8, 0) catch continue;
        const age_days = row.get(i64, 1) catch continue;
        const refer_count = row.get(i64, 2) catch continue;

        if (series_by_prompt.getPtr(prompt_id)) |series_ptr| {
            setTrendBucket(series_ptr.*, age_days, refer_count);
            continue;
        }

        const series = zeroTrendSeries(arena, max_days);
        const key = arena.dupe(u8, prompt_id) catch continue;
        series_by_prompt.put(key, series) catch continue;
        setTrendBucket(series, age_days, refer_count);
    }

    return series_by_prompt;
}

fn queryUserTrendSeries(
    conn: anytype,
    arena: std.mem.Allocator,
    org_id: []const u8,
    max_days: u32,
) std.StringHashMap([]i64) {
    var series_by_user = std.StringHashMap([]i64).init(arena);
    const cutoff_ms = recentCutoffMs(max_days);

    var result = conn.query(
        \\SELECT te.user_id,
        \\  floor(extract(epoch from (date_trunc('day', now()) - date_trunc('day', to_timestamp(te.timestamp / 1000)))) / 86400)::bigint as age_days,
        \\  count(*) as refer_count
        \\FROM trace_events te
        \\JOIN workspaces w ON w.ws_id = te.ws_id
        \\WHERE w.org_id = $1::uuid
        \\  AND te.type = 'refer'
        \\  AND te.user_id IS NOT NULL
        \\  AND te.timestamp >= $2
        \\GROUP BY te.user_id, age_days
        \\ORDER BY te.user_id, age_days
    , .{ org_id, cutoff_ms }) catch |err| {
        log.err("user trend query failed: {}", .{err});
        return series_by_user;
    };
    defer result.deinit();

    while (result.next() catch null) |row| {
        const user_id = row.get([]const u8, 0) catch continue;
        const age_days = row.get(i64, 1) catch continue;
        const refer_count = row.get(i64, 2) catch continue;

        if (series_by_user.getPtr(user_id)) |series_ptr| {
            setTrendBucket(series_ptr.*, age_days, refer_count);
            continue;
        }

        const series = zeroTrendSeries(arena, max_days);
        const key = arena.dupe(u8, user_id) catch continue;
        series_by_user.put(key, series) catch continue;
        setTrendBucket(series, age_days, refer_count);
    }

    return series_by_user;
}

fn queryUserTopPrompts(
    conn: anytype,
    arena: std.mem.Allocator,
    org_id: []const u8,
) std.StringHashMap([]const UserTopPromptStat) {
    var lists = std.StringHashMap(std.ArrayList(UserTopPromptStat)).init(arena);

    var result = conn.query(
        \\SELECT te.user_id, te.prompt_id, count(*) as refer_count
        \\FROM trace_events te
        \\JOIN workspaces w ON w.ws_id = te.ws_id
        \\WHERE w.org_id = $1::uuid
        \\  AND te.type = 'refer'
        \\  AND te.user_id IS NOT NULL
        \\  AND te.prompt_id IS NOT NULL
        \\GROUP BY te.user_id, te.prompt_id
        \\ORDER BY te.user_id, refer_count DESC, te.prompt_id
    , .{org_id}) catch |err| {
        log.err("user top prompts query failed: {}", .{err});
        const empty = std.StringHashMap([]const UserTopPromptStat).init(arena);
        return empty;
    };
    defer result.deinit();

    while (result.next() catch null) |row| {
        const user_id = row.get([]const u8, 0) catch continue;
        const prompt_id = row.get([]const u8, 1) catch continue;
        const refer_count = row.get(i64, 2) catch continue;

        if (lists.getPtr(user_id)) |list_ptr| {
            if (list_ptr.items.len >= 3) continue;
            list_ptr.append(arena, .{
                .prompt_id = arena.dupe(u8, prompt_id) catch continue,
                .refer_count = refer_count,
            }) catch continue;
            continue;
        }

        const key = arena.dupe(u8, user_id) catch continue;
        lists.put(key, .empty) catch continue;
        const list_ptr = lists.getPtr(user_id) orelse continue;
        list_ptr.append(arena, .{
            .prompt_id = arena.dupe(u8, prompt_id) catch continue,
            .refer_count = refer_count,
        }) catch continue;
    }

    var frozen = std.StringHashMap([]const UserTopPromptStat).init(arena);
    var it = lists.iterator();
    while (it.next()) |entry| {
        frozen.put(entry.key_ptr.*, entry.value_ptr.items) catch continue;
    }
    return frozen;
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
        // Validate caller has access to the target workspace
        if (!std.mem.eql(u8, user.role, "maintainer") and !auth.checkWorkspaceMember(conn, event.ws_id, user.user_id)) {
            deduplicated += 1;
            continue;
        }

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
        const rows_affected = conn.exec(
            \\INSERT INTO trace_events (user_id, ws_id, session_id, event_id, type, timestamp,
            \\  prompt_id, prompt_hash, constraint_id, reason, content, content_hash)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            \\ON CONFLICT (ws_id, session_id, event_id) DO NOTHING
        , .{
            user.user_id,             event.ws_id,       event.session_id,
            @as(i64, event.event_id), event.type,        @as(i64, event.timestamp),
            event.prompt_id,          event.prompt_hash, event.constraint_id,
            event.reason,             event.content,     event.content_hash,
        }) catch {
            deduplicated += 1;
            continue;
        };
        if (rows_affected != null and rows_affected.? > 0) {
            accepted += 1;
        } else {
            deduplicated += 1;
        }
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
    if (!auth.requireScope(user, "stats:read", res)) return;

    const qs = req.query() catch {
        return apiError(res, 400, "BAD_REQUEST", "invalid query string");
    };
    const period = qs.get("period") orelse "daily";
    const sql_trunc = parsePeriod(period) orelse {
        return apiError(res, 400, "BAD_REQUEST", "invalid period; use daily, weekly, or monthly");
    };
    const max_days: u32 = if (qs.get("days")) |ds| blk: {
        const d = std.fmt.parseInt(u32, ds, 10) catch {
            return apiError(res, 400, "BAD_REQUEST", "invalid days parameter; must be a positive integer");
        };
        if (d == 0 or d > 3650) {
            return apiError(res, 400, "BAD_REQUEST", "days must be between 1 and 3650");
        }
        break :blk d;
    } else defaultDays(period);

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
        try res.json(OrgStatsResponse{
            .total_refer_count = 0,
            .workspace_count = 0,
            .prompt_count = 0,
            .prompts = &.{},
            .users = &.{},
            .trend = TrendSeries{ .period = period, .data = &.{} },
        }, .{});
        return;
    };
    const total_refer_count = try row.get(i64, 0);
    const workspace_count = try row.get(i64, 1);
    const prompt_count = try row.get(i64, 2);
    row.deinit() catch {};

    const prompt_trends = queryPromptTrendSeries(conn, req.arena, user.org_id, max_days);
    const user_trends = queryUserTrendSeries(conn, req.arena, user.org_id, max_days);
    const user_top_prompts = queryUserTopPrompts(conn, req.arena, user.org_id);

    // Per-prompt aggregated stats via LEFT JOINs
    var prompt_list: std.ArrayList(OrgPromptStats) = .empty;
    var prompt_result = conn.query(
        \\SELECT p.prompt_id,
        \\  COALESCE(te_stats.refer_count, 0),
        \\  COALESCE(te_stats.active_constraints, 0),
        \\  COALESCE(ws_stats.workspace_count, 0),
        \\  COALESCE(bp_stats.bundle_count, 0),
        \\  COALESCE(pr_stats.open_pr_count, 0),
        \\  te_stats.last_referred_at
        \\FROM prompts p
        \\LEFT JOIN (
        \\  SELECT te.prompt_id, count(*) as refer_count,
        \\    count(DISTINCT te.constraint_id) as active_constraints,
        \\    max(te.timestamp) as last_referred_at
        \\  FROM trace_events te JOIN workspaces w ON w.ws_id = te.ws_id
        \\  WHERE w.org_id = $1::uuid AND te.type = 'refer' AND te.prompt_id IS NOT NULL
        \\  GROUP BY te.prompt_id
        \\) te_stats ON te_stats.prompt_id = p.prompt_id
        \\LEFT JOIN (
        \\  SELECT wp.prompt_id, count(DISTINCT wp.ws_id) as workspace_count
        \\  FROM workspace_prompts wp JOIN workspaces w ON w.ws_id = wp.ws_id
        \\  WHERE w.org_id = $1::uuid
        \\  GROUP BY wp.prompt_id
        \\) ws_stats ON ws_stats.prompt_id = p.prompt_id
        \\LEFT JOIN (
        \\  SELECT bp.prompt_id, count(*) as bundle_count
        \\  FROM bundle_prompts bp JOIN bundles b ON b.bundle_id = bp.bundle_id
        \\  WHERE b.org_id = $1::uuid
        \\  GROUP BY bp.prompt_id
        \\) bp_stats ON bp_stats.prompt_id = p.prompt_id
        \\LEFT JOIN (
        \\  SELECT op.prompt_id, count(DISTINCT op.pr_id) as open_pr_count
        \\  FROM prompt_pr_operations op
        \\  JOIN prompt_prs pr ON pr.pr_id = op.pr_id
        \\  WHERE pr.org_id = $1::uuid AND pr.status = 'open' AND op.prompt_id IS NOT NULL
        \\  GROUP BY op.prompt_id
        \\) pr_stats ON pr_stats.prompt_id = p.prompt_id
        \\WHERE p.org_id = $1::uuid
        \\ORDER BY COALESCE(te_stats.refer_count, 0) DESC
    , .{user.org_id}) catch |err| blk: {
        log.err("org stats prompt query failed: {}", .{err});
        break :blk null;
    };
    if (prompt_result) |*pr| {
        defer pr.*.deinit();
        while (true) {
            const prow = pr.*.next() catch |err| {
                log.err("org stats prompt query next failed: {}", .{err});
                break;
            } orelse break;
            prompt_list.append(req.arena, .{
                .prompt_id = req.arena.dupe(u8, prow.get([]const u8, 0) catch |err| {
                    log.err("org stats prompt_id get failed: {}", .{err});
                    continue;
                }) catch continue,
                .refer_count = prow.get(i64, 1) catch |err| {
                    log.err("org stats refer_count get failed: {}", .{err});
                    continue;
                },
                .active_constraint_count = prow.get(i64, 2) catch |err| {
                    log.err("org stats active_constraint_count get failed: {}", .{err});
                    continue;
                },
                .workspace_count = prow.get(i64, 3) catch |err| {
                    log.err("org stats workspace_count get failed: {}", .{err});
                    continue;
                },
                .bundle_count = prow.get(i64, 4) catch |err| {
                    log.err("org stats bundle_count get failed: {}", .{err});
                    continue;
                },
                .open_pr_count = prow.get(i64, 5) catch |err| {
                    log.err("org stats open_pr_count get failed: {}", .{err});
                    continue;
                },
                .last_referred_at = prow.get(?i64, 6) catch |err| blk: {
                    log.err("org stats last_referred_at get failed: {}", .{err});
                    break :blk null;
                },
                .trend = if (prompt_trends.get(prow.get([]const u8, 0) catch "")) |trend| trend else zeroTrendSeries(req.arena, max_days),
            }) catch continue;
        }
    }

    var user_list: std.ArrayList(OrgUserStats) = .empty;
    var user_result = conn.query(
        \\SELECT u.user_id,
        \\  u.username,
        \\  COALESCE(stats.refer_count, 0),
        \\  COALESCE(stats.active_days, 0),
        \\  stats.last_referred_at
        \\FROM users u
        \\LEFT JOIN (
        \\  SELECT te.user_id,
        \\    count(*) as refer_count,
        \\    count(DISTINCT date_trunc('day', to_timestamp(te.timestamp / 1000))) as active_days,
        \\    max(te.timestamp) as last_referred_at
        \\  FROM trace_events te
        \\  JOIN workspaces w ON w.ws_id = te.ws_id
        \\  WHERE w.org_id = $1::uuid
        \\    AND te.type = 'refer'
        \\    AND te.user_id IS NOT NULL
        \\  GROUP BY te.user_id
        \\) stats ON stats.user_id = u.user_id
        \\WHERE u.org_id = $1::uuid
        \\ORDER BY COALESCE(stats.refer_count, 0) DESC, u.username
    , .{user.org_id}) catch |err| blk: {
        log.err("org stats user query failed: {}", .{err});
        break :blk null;
    };
    if (user_result) |*ur| {
        defer ur.*.deinit();
        while (true) {
            const urow = ur.*.next() catch |err| {
                log.err("org stats user query next failed: {}", .{err});
                break;
            } orelse break;
            const user_id = urow.get([]const u8, 0) catch |err| {
                log.err("org stats user_id get failed: {}", .{err});
                continue;
            };
            user_list.append(req.arena, .{
                .user_id = req.arena.dupe(u8, user_id) catch continue,
                .username = req.arena.dupe(u8, urow.get([]const u8, 1) catch |err| {
                    log.err("org stats username get failed: {}", .{err});
                    continue;
                }) catch continue,
                .refer_count = urow.get(i64, 2) catch |err| {
                    log.err("org stats user refer_count get failed: {}", .{err});
                    continue;
                },
                .active_days = urow.get(i64, 3) catch |err| {
                    log.err("org stats user active_days get failed: {}", .{err});
                    continue;
                },
                .last_referred_at = urow.get(?i64, 4) catch |err| blk: {
                    log.err("org stats user last_referred_at get failed: {}", .{err});
                    break :blk null;
                },
                .trend = if (user_trends.get(user_id)) |trend| trend else zeroTrendSeries(req.arena, max_days),
                .top_prompts = if (user_top_prompts.get(user_id)) |tops| tops else &.{},
            }) catch continue;
        }
    }
    const trend_data = queryTrend(
        conn,
        req.arena,
        sql_trunc,
        "ws_id IN (SELECT ws_id FROM workspaces WHERE org_id = $1::uuid)",
        .{user.org_id},
        max_days,
    );

    try res.json(OrgStatsResponse{
        .total_refer_count = total_refer_count,
        .workspace_count = workspace_count,
        .prompt_count = prompt_count,
        .prompts = prompt_list.items,
        .users = user_list.items,
        .trend = TrendSeries{ .period = period, .data = trend_data },
    }, .{});
}

pub fn handleWorkspaceStats(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "stats:read", res)) return;

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
    const max_days: u32 = if (qs.get("days")) |ds| blk: {
        const d = std.fmt.parseInt(u32, ds, 10) catch {
            return apiError(res, 400, "BAD_REQUEST", "invalid days parameter; must be a positive integer");
        };
        if (d == 0 or d > 3650) {
            return apiError(res, 400, "BAD_REQUEST", "days must be between 1 and 3650");
        }
        break :blk d;
    } else defaultDays(period);

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
        try res.json(WorkspaceStatsResponse{
            .ws_id = ws_id,
            .total_refer_count = 0,
            .constraint_coverage = 0,
            .prompts = &.{},
            .trend = TrendSeries{ .period = period, .data = &.{} },
        }, .{});
        return;
    };
    const total_refer_count = try row.get(i64, 0);
    row.deinit() catch {};

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
    var prompt_list: std.ArrayList(WorkspacePromptStat) = .empty;

    var prompt_result = conn.query(
        "SELECT prompt_id, count(*) FROM trace_events WHERE ws_id = $1 AND type = 'refer' AND prompt_id IS NOT NULL GROUP BY prompt_id ORDER BY count(*) DESC",
        .{ws_id},
    ) catch |err| blk: {
        log.err("workspace stats prompt query failed: {}", .{err});
        break :blk null;
    };
    if (prompt_result) |*pr| {
        defer pr.*.deinit();
        while (true) {
            const prow = pr.*.next() catch |err| {
                log.err("workspace stats prompt query next failed: {}", .{err});
                break;
            } orelse break;
            prompt_list.append(req.arena, .{
                .prompt_id = req.arena.dupe(u8, prow.get([]const u8, 0) catch |err| {
                    log.err("workspace stats prompt_id get failed: {}", .{err});
                    continue;
                }) catch continue,
                .refer_count = prow.get(i64, 1) catch |err| {
                    log.err("workspace stats refer_count get failed: {}", .{err});
                    continue;
                },
            }) catch continue;
        }
    }
    const trend_data = queryTrend(conn, req.arena, sql_trunc, "ws_id = $1", .{ws_id}, max_days);

    try res.json(WorkspaceStatsResponse{
        .ws_id = ws_id,
        .total_refer_count = total_refer_count,
        .constraint_coverage = coverage,
        .prompts = prompt_list.items,
        .trend = TrendSeries{ .period = period, .data = trend_data },
    }, .{});
}

pub fn handlePromptStats(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    const user = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };
    if (!auth.requireScope(user, "stats:read", res)) return;

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
    const max_days: u32 = if (qs.get("days")) |ds| blk: {
        const d = std.fmt.parseInt(u32, ds, 10) catch {
            return apiError(res, 400, "BAD_REQUEST", "invalid days parameter; must be a positive integer");
        };
        if (d == 0 or d > 3650) {
            return apiError(res, 400, "BAD_REQUEST", "days must be between 1 and 3650");
        }
        break :blk d;
    } else defaultDays(period);

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

    const trend_data = queryTrend(conn, req.arena, sql_trunc, "prompt_id = $1", .{prompt_id}, max_days);

    try res.json(.{
        .prompt_id = prompt_id,
        .total_refer_count = total_refer_count,
        .constraints = constraints.items,
        .trend = .{ .period = period, .data = trend_data },
    }, .{});
}
