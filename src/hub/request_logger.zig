const std = @import("std");
const httpz = @import("httpz");

const Middleware = @This();

const log = std.log.scoped(.hub_request);

pub fn init(config: Config) !Middleware {
    _ = config;
    return .{};
}

pub fn execute(_: *const Middleware, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    const start = std.time.microTimestamp();
    defer {
        const elapsed_us = std.time.microTimestamp() - start;
        const client_id = req.header("x-client-id") orelse "-";
        log.info("{s} {s} client={s} status={d} elapsed_us={d}", .{
            methodText(req),
            req.url.path,
            client_id,
            res.status,
            elapsed_us,
        });
    }
    try executor.next();
}

pub const Config = struct {};

fn methodText(req: *const httpz.Request) []const u8 {
    return switch (req.method) {
        .OTHER => req.method_string,
        else => @tagName(req.method),
    };
}
