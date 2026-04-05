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

pub fn handleUpload(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

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
        try res.json(.{ .total_refer_count = @as(i64, 0), .workspace_count = @as(i64, 0), .prompt_count = @as(i64, 0) }, .{});
        return;
    };
    defer row.deinit() catch {};

    try res.json(.{
        .total_refer_count = try row.get(i64, 0),
        .workspace_count = try row.get(i64, 1),
        .prompt_count = try row.get(i64, 2),
    }, .{});
}

pub fn handleWorkspaceStats(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
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
        "SELECT count(*) FROM trace_events WHERE ws_id = $1 AND type = 'refer'",
        .{ws_id},
    ) catch {
        return apiError(res, 500, "INTERNAL_ERROR", "database query failed");
    } orelse {
        try res.json(.{ .ws_id = ws_id, .total_refer_count = @as(i64, 0) }, .{});
        return;
    };
    defer row.deinit() catch {};

    try res.json(.{
        .ws_id = ws_id,
        .total_refer_count = try row.get(i64, 0),
    }, .{});
}

pub fn handlePromptStats(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = auth.authenticate(ctx, req) catch {
        return apiError(res, 401, "UNAUTHORIZED", "invalid or missing token");
    };

    const prompt_id = req.param("prompt_id") orelse {
        return apiError(res, 400, "BAD_REQUEST", "prompt_id is required");
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
        try res.json(.{ .prompt_id = prompt_id, .total_refer_count = @as(i64, 0) }, .{});
        return;
    };
    defer row.deinit() catch {};

    try res.json(.{
        .prompt_id = prompt_id,
        .total_refer_count = try row.get(i64, 0),
    }, .{});
}
