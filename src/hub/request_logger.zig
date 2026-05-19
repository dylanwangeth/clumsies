const std = @import("std");
const httpz = @import("httpz");
const logger = @import("clumsies_lib").logger;

const Middleware = @This();
const ERROR_CODE_HEADER = "x-clumsies-error-code";
const ERROR_MESSAGE_HEADER = "x-clumsies-error-message";

var next_request_id = std.atomic.Value(u64).init(0);

pub fn init(config: Config) !Middleware {
    _ = config;
    return .{};
}

pub fn execute(_: *const Middleware, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    const start = std.time.nanoTimestamp();
    const request_id = ensureRequestId(req, res);
    defer {
        const elapsed_ns = std.time.nanoTimestamp() - start;
        var client_buf: [64]u8 = undefined;
        var ip_buf: [128]u8 = undefined;
        const client_id = sanitizedClientId(req.header("x-client-id"), &client_buf);
        const ip = clientIp(req, &ip_buf);
        const method = methodText(req);
        const path = redactedPath(req.url.path);
        logRequest(.{
            .status = res.status,
            .elapsed_ns = elapsed_ns,
            .ip = ip,
            .client_id = client_id,
            .request_id = request_id,
            .method = method,
            .path = path,
            .route = classifyRoute(method, path),
            .ws_id = requestParam(req, "ws_id"),
            .pr_id = requestParamAny(req, &.{ "pr_id", "id" }),
            .rule_id = requestParam(req, "rule_id"),
            .context_id = requestParam(req, "context_id"),
            .target_user_id = requestParam(req, "user_id"),
            .error_code = responseHeader(res, ERROR_CODE_HEADER),
            .error_message = responseHeader(res, ERROR_MESSAGE_HEADER),
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

fn logRequest(access: logger.HttpAccess) void {
    logger.httpAccessLogFn(requestLogLevel(access.status), access);
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

fn ensureRequestId(req: *httpz.Request, res: *httpz.Response) []const u8 {
    if (req.header("x-request-id")) |raw| {
        const request_id = sanitizedTextAlloc(req.arena, raw, 96) catch "-";
        res.header("x-request-id", request_id);
        return request_id;
    }

    const counter = next_request_id.fetchAdd(1, .monotonic) + 1;
    const request_id = std.fmt.allocPrint(req.arena, "req-{x}-{x}", .{ @as(u64, @intCast(std.time.nanoTimestamp())), counter }) catch "-";
    res.header("x-request-id", request_id);
    return request_id;
}

fn responseHeader(res: *const httpz.Response, name: []const u8) []const u8 {
    return res.headers.get(name) orelse "-";
}

fn requestParam(req: *httpz.Request, name: []const u8) []const u8 {
    return req.param(name) orelse "-";
}

fn requestParamAny(req: *httpz.Request, names: []const []const u8) []const u8 {
    for (names) |name| {
        if (req.param(name)) |value| return value;
    }
    return "-";
}

const Route = struct {
    method: []const u8,
    pattern: []const u8,
    name: []const u8,
};

const routes = [_]Route{
    .{ .method = "GET", .pattern = "/api/health", .name = "health.check" },
    .{ .method = "POST", .pattern = "/api/auth/login", .name = "auth.login" },
    .{ .method = "POST", .pattern = "/api/auth/activate", .name = "auth.activate" },
    .{ .method = "POST", .pattern = "/api/auth/refresh", .name = "auth.refresh" },
    .{ .method = "GET", .pattern = "/api/auth/me", .name = "auth.me.read" },
    .{ .method = "PATCH", .pattern = "/api/auth/me", .name = "auth.me.update" },
    .{ .method = "DELETE", .pattern = "/api/auth/token", .name = "auth.token.delete" },
    .{ .method = "GET", .pattern = "/api/members", .name = "members.list" },
    .{ .method = "POST", .pattern = "/api/members", .name = "members.invite" },
    .{ .method = "PATCH", .pattern = "/api/members/:user_id", .name = "members.role.update" },
    .{ .method = "DELETE", .pattern = "/api/members/:user_id", .name = "members.remove" },
    .{ .method = "POST", .pattern = "/api/members/:user_id/reissue-invite", .name = "members.invite.reissue" },
    .{ .method = "POST", .pattern = "/api/workspaces", .name = "workspaces.create" },
    .{ .method = "GET", .pattern = "/api/workspaces/:ws_id", .name = "workspaces.read" },
    .{ .method = "PATCH", .pattern = "/api/workspaces/:ws_id", .name = "workspaces.update" },
    .{ .method = "DELETE", .pattern = "/api/workspaces/:ws_id", .name = "workspaces.delete" },
    .{ .method = "GET", .pattern = "/api/workspaces/:ws_id/manifest", .name = "workspaces.manifest" },
    .{ .method = "POST", .pattern = "/api/workspaces/:ws_id/rules", .name = "workspaces.rules.add" },
    .{ .method = "POST", .pattern = "/api/workspaces/:ws_id/rules/content", .name = "workspaces.rules.content" },
    .{ .method = "POST", .pattern = "/api/workspaces/:ws_id/rules/detach", .name = "workspaces.rules.detach" },
    .{ .method = "DELETE", .pattern = "/api/workspaces/:ws_id/rules/:rule_id", .name = "workspaces.rules.remove" },
    .{ .method = "GET", .pattern = "/api/workspaces/:ws_id/context", .name = "workspaces.context.list" },
    .{ .method = "POST", .pattern = "/api/workspaces/:ws_id/context/content", .name = "workspaces.context.content" },
    .{ .method = "POST", .pattern = "/api/workspaces/:ws_id/context/prs", .name = "context_prs.create" },
    .{ .method = "GET", .pattern = "/api/workspaces/:ws_id/context/prs", .name = "context_prs.list" },
    .{ .method = "GET", .pattern = "/api/workspaces/:ws_id/context/prs/:pr_id", .name = "context_prs.read" },
    .{ .method = "PUT", .pattern = "/api/workspaces/:ws_id/context/prs/:pr_id", .name = "context_prs.update" },
    .{ .method = "POST", .pattern = "/api/workspaces/:ws_id/context/prs/:pr_id/comments", .name = "context_prs.comments.add" },
    .{ .method = "GET", .pattern = "/api/workspaces/:ws_id/context/prs/:pr_id/comments", .name = "context_prs.comments.list" },
    .{ .method = "GET", .pattern = "/api/workspaces/:ws_id/members", .name = "workspaces.members.list" },
    .{ .method = "POST", .pattern = "/api/workspaces/:ws_id/members", .name = "workspaces.members.invite" },
    .{ .method = "PATCH", .pattern = "/api/workspaces/:ws_id/members/:user_id", .name = "workspaces.members.role.update" },
    .{ .method = "DELETE", .pattern = "/api/workspaces/:ws_id/members/:user_id", .name = "workspaces.members.remove" },
    .{ .method = "GET", .pattern = "/api/artifact/rules", .name = "artifact.rules.list" },
    .{ .method = "POST", .pattern = "/api/artifact/rules/content", .name = "artifact.rules.content" },
    .{ .method = "GET", .pattern = "/api/bundles", .name = "bundles.list" },
    .{ .method = "GET", .pattern = "/api/bundles/:name", .name = "bundles.read" },
    .{ .method = "POST", .pattern = "/api/bundles", .name = "bundles.create" },
    .{ .method = "PUT", .pattern = "/api/bundles/:name", .name = "bundles.update" },
    .{ .method = "DELETE", .pattern = "/api/bundles/:name", .name = "bundles.delete" },
    .{ .method = "POST", .pattern = "/api/attestations", .name = "attestations.upload" },
    .{ .method = "GET", .pattern = "/api/stats", .name = "stats.org" },
    .{ .method = "GET", .pattern = "/api/stats/workspace/:ws_id", .name = "stats.workspace" },
    .{ .method = "GET", .pattern = "/api/stats/rule/:rule_id", .name = "stats.rule" },
    .{ .method = "GET", .pattern = "/api/prs", .name = "review_prs.list" },
    .{ .method = "POST", .pattern = "/api/prs", .name = "rule_prs.create" },
    .{ .method = "GET", .pattern = "/api/prs/:id", .name = "rule_prs.read" },
    .{ .method = "PUT", .pattern = "/api/prs/:id", .name = "rule_prs.update" },
    .{ .method = "POST", .pattern = "/api/prs/:id/comments", .name = "rule_prs.comments.add" },
    .{ .method = "GET", .pattern = "/api/prs/:id/comments", .name = "rule_prs.comments.list" },
};

fn classifyRoute(method: []const u8, path: []const u8) []const u8 {
    for (&routes) |route| {
        if (std.mem.eql(u8, method, route.method) and pathMatches(route.pattern, path)) return route.name;
    }
    return "unknown";
}

fn pathMatches(pattern: []const u8, path: []const u8) bool {
    var pattern_iter = std.mem.splitScalar(u8, pattern, '/');
    var path_iter = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const pattern_part = pattern_iter.next();
        const path_part = path_iter.next();
        if (pattern_part == null or path_part == null) return pattern_part == null and path_part == null;
        if (pattern_part.?.len > 0 and pattern_part.?[0] == ':') continue;
        if (!std.mem.eql(u8, pattern_part.?, path_part.?)) return false;
    }
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
    return remoteHost(writer.buffered());
}

fn firstForwardedFor(raw: []const u8) []const u8 {
    const comma = std.mem.indexOfScalar(u8, raw, ',') orelse return raw;
    return raw[0..comma];
}

fn remoteHost(raw: []const u8) []const u8 {
    if (raw.len == 0) return raw;
    if (raw[0] == '[') {
        const end = std.mem.indexOfScalar(u8, raw, ']') orelse return raw;
        return raw[1..end];
    }
    const colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return raw;
    if (std.mem.indexOfScalar(u8, raw[0..colon], ':') != null) return raw;
    return raw[0..colon];
}

fn sanitizedText(raw: []const u8, buf: []u8) []const u8 {
    const len = @min(raw.len, buf.len);
    for (raw[0..len], 0..) |byte, idx| {
        buf[idx] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
    }
    return buf[0..len];
}

fn sanitizedTextAlloc(allocator: std.mem.Allocator, raw: []const u8, max_len: usize) ![]const u8 {
    const len = @min(raw.len, max_len);
    const out = try allocator.alloc(u8, len);
    for (raw[0..len], 0..) |byte, idx| {
        out[idx] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
    }
    return out;
}

test "requestLogLevel maps HTTP status classes to severity" {
    try std.testing.expectEqual(std.log.Level.info, requestLogLevel(200));
    try std.testing.expectEqual(std.log.Level.info, requestLogLevel(302));
    try std.testing.expectEqual(std.log.Level.warn, requestLogLevel(400));
    try std.testing.expectEqual(std.log.Level.warn, requestLogLevel(404));
    try std.testing.expectEqual(std.log.Level.err, requestLogLevel(500));
}

test "remoteHost strips ephemeral ports" {
    try std.testing.expectEqualStrings("127.0.0.1", remoteHost("127.0.0.1:59579"));
    try std.testing.expectEqualStrings("192.168.10.127", remoteHost("192.168.10.127:56669"));
    try std.testing.expectEqualStrings("::1", remoteHost("[::1]:8400"));
    try std.testing.expectEqualStrings("fe80::1", remoteHost("fe80::1"));
}

test "classifyRoute gives stable route names" {
    try std.testing.expectEqualStrings("review_prs.list", classifyRoute("GET", "/api/prs"));
    try std.testing.expectEqualStrings("rule_prs.create", classifyRoute("POST", "/api/prs"));
    try std.testing.expectEqualStrings("rule_prs.update", classifyRoute("PUT", "/api/prs/ppr-1"));
    try std.testing.expectEqualStrings("workspaces.context.list", classifyRoute("GET", "/api/workspaces/ws-1/context"));
    try std.testing.expectEqualStrings("workspaces.rules.content", classifyRoute("POST", "/api/workspaces/ws-1/rules/content"));
    try std.testing.expectEqualStrings("context_prs.update", classifyRoute("PUT", "/api/workspaces/ws-1/context/prs/cpr-1"));
    try std.testing.expectEqualStrings("unknown", classifyRoute("GET", "/api/not-real"));
}

test "pathMatches handles literal and parameter segments" {
    try std.testing.expect(pathMatches("/api/prs/:id", "/api/prs/ppr-1"));
    try std.testing.expect(!pathMatches("/api/prs/:id", "/api/prs/ppr-1/comments"));
    try std.testing.expect(!pathMatches("/api/prs/:id/comments", "/api/prs/ppr-1"));
}
