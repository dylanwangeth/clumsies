const std = @import("std");
const httpz = @import("httpz");
const logger = @import("clumsies_lib").logger;

const Middleware = @This();

pub fn init(config: Config) !Middleware {
    _ = config;
    return .{};
}

pub fn execute(_: *const Middleware, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    const start = std.time.nanoTimestamp();
    defer {
        const elapsed_ns = std.time.nanoTimestamp() - start;
        var client_buf: [64]u8 = undefined;
        var ip_buf: [128]u8 = undefined;
        const client_id = sanitizedClientId(req.header("x-client-id"), &client_buf);
        const ip = clientIp(req, &ip_buf);
        logRequest(methodText(req), redactedPath(req.url.path), ip, client_id, res.status, elapsed_ns);
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

fn logRequest(method: []const u8, path: []const u8, ip: []const u8, client_id: []const u8, status: u16, elapsed_ns: i128) void {
    logger.httpAccessLogFn(requestLogLevel(status), status, elapsed_ns, ip, client_id, method, path);
}

fn requestLogLevel(status: u16) std.log.Level {
    if (status >= 500) return .err;
    if (status >= 400) return .warn;
    return .info;
}

fn sanitizedClientId(raw_opt: ?[]const u8, buf: *[64]u8) []const u8 {
    const raw = raw_opt orelse return "-";
    return sanitizedText(raw, buf);
}

fn clientIp(req: *const httpz.Request, buf: *[128]u8) []const u8 {
    if (req.header("x-forwarded-for")) |raw| {
        const first = std.mem.trim(u8, firstForwardedFor(raw), " \t");
        if (first.len > 0) return sanitizedText(first, buf);
    }
    if (req.header("x-real-ip")) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len > 0) return sanitizedText(trimmed, buf);
    }

    var writer: std.Io.Writer = .fixed(buf);
    req.address.format(&writer) catch return "-";
    return writer.buffered();
}

fn firstForwardedFor(raw: []const u8) []const u8 {
    const comma = std.mem.indexOfScalar(u8, raw, ',') orelse return raw;
    return raw[0..comma];
}

fn sanitizedText(raw: []const u8, buf: []u8) []const u8 {
    const len = @min(raw.len, buf.len);
    for (raw[0..len], 0..) |byte, idx| {
        buf[idx] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
    }
    return buf[0..len];
}

test "requestLogLevel maps HTTP status classes to severity" {
    try std.testing.expectEqual(std.log.Level.info, requestLogLevel(200));
    try std.testing.expectEqual(std.log.Level.info, requestLogLevel(302));
    try std.testing.expectEqual(std.log.Level.warn, requestLogLevel(400));
    try std.testing.expectEqual(std.log.Level.warn, requestLogLevel(404));
    try std.testing.expectEqual(std.log.Level.err, requestLogLevel(500));
}
