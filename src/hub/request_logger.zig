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
        log.info("{s} {s} status={d} elapsed_us={d}", .{
            methodText(req),
            req.url.path,
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
