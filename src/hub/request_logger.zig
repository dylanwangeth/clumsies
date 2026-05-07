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
        var client_buf: [64]u8 = undefined;
        const client_id = sanitizedClientId(req.header("x-client-id"), &client_buf);
        log.info("{s} {s} client={s} status={d} elapsed_us={d}", .{
            methodText(req),
            redactedPath(req.url.path),
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

fn redactedPath(path: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, path, '?') orelse return path;
    return path[0..query_start];
}

fn sanitizedClientId(raw_opt: ?[]const u8, buf: *[64]u8) []const u8 {
    const raw = raw_opt orelse return "-";
    const len = @min(raw.len, buf.len);
    for (raw[0..len], 0..) |byte, idx| {
        buf[idx] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
    }
    return buf[0..len];
}
