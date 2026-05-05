const std = @import("std");
const httpz = @import("httpz");

const Server = @import("server.zig");

const log = std.log.scoped(.hub_health);

pub fn handle(ctx: *Server.Context, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;

    const conn = ctx.pool.acquire() catch |err| {
        log.warn("pool acquire failed: {}", .{err});
        res.status = 503;
        try res.json(.{ .status = "unhealthy", .database = "unavailable" }, .{});
        return;
    };
    defer conn.release();

    _ = conn.exec("SELECT 1", .{}) catch |err| {
        log.warn("health query failed: {}", .{err});
        res.status = 503;
        try res.json(.{ .status = "unhealthy", .database = "unavailable" }, .{});
        return;
    };

    try res.json(.{ .status = "ok" }, .{});
}
