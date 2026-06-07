//! HTTP transport boundary for provider and client network calls.
//!
//! This module deliberately keeps provider IO inside Zig instead of shelling
//! out to curl or another process. The current implementation is a thin
//! `std.http.Client` wrapper plus explicit diagnostics for the proxy semantics
//! Zig 0.15.1 cannot model reliably enough for interactive agent runs.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;

const HttpTransport = @This();

allocator: std.mem.Allocator,
client: http.Client,
proxy_arena: std.heap.ArenaAllocator,
proxies_loaded: bool = false,

pub const Request = struct {
    method: http.Method,
    url: []const u8,
    payload: ?[]const u8 = null,
    headers: []const http.Header = &.{},
    keep_alive: bool = true,
    timeout_ms: ?u64 = null,
    use_env_proxy: bool = false,
};

pub const Error = error{
    HttpsEnvProxyUnsupported,
};

pub const Response = struct {
    status: http.Status,
    body: []const u8,
    allocator: std.mem.Allocator,

    /// Releases the response body owned by this transport response.
    pub fn deinit(self: Response) void {
        self.allocator.free(self.body);
    }
};

/// Creates one reusable HTTP transport backed by `std.http.Client`.
pub fn init(allocator: std.mem.Allocator) HttpTransport {
    return .{
        .allocator = allocator,
        .client = .{ .allocator = allocator },
        .proxy_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

/// Releases the underlying `std.http.Client` resources.
pub fn deinit(self: *HttpTransport) void {
    self.client.deinit();
    self.proxy_arena.deinit();
}

/// Performs one request and returns an allocator-owned response body.
///
/// Provider adapters use this as the network boundary. HTTPS-through-env-proxy
/// is rejected explicitly because Zig 0.15.1's proxy path does not give us the
/// complete CONNECT + target TLS + deadline behavior required by the agent UI.
pub fn fetch(self: *HttpTransport, request: Request) !Response {
    const uri = try std.Uri.parse(request.url);
    if (request.use_env_proxy and std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return Error.HttpsEnvProxyUnsupported;
    }
    if (request.use_env_proxy) try self.ensureDefaultProxies();

    var response_writer = std.Io.Writer.Allocating.init(self.allocator);
    errdefer response_writer.deinit();

    var client_request = try self.client.request(request.method, uri, .{
        .extra_headers = request.headers,
        .keep_alive = request.keep_alive,
        .redirect_behavior = .unhandled,
    });
    defer client_request.deinit();

    const connection = client_request.connection orelse return error.ConnectionUnavailable;
    try applySocketTimeout(connection, request.timeout_ms);

    if (request.payload) |payload| {
        client_request.transfer_encoding = .{ .content_length = payload.len };
        // Zig 0.15.1 `Client.fetch` misses this flush for HTTPS POST payloads,
        // which can surface as `HttpConnectionClosing` before response headers.
        // Keep the lower-level request path until the toolchain includes:
        // https://github.com/ziglang/zig/pull/24926
        // https://github.com/ziglang/zig/issues/25002
        var body = try client_request.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try connection.flush();
    } else {
        try client_request.sendBodiless();
    }

    var response = try client_request.receiveHead(&.{});
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&response_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    return .{
        .status = response.head.status,
        .body = try response_writer.toOwnedSlice(),
        .allocator = self.allocator,
    };
}

/// Loads process proxy configuration before the first plain HTTP proxy request.
///
/// Zig's HTTP client does not read `HTTP_PROXY`/`HTTPS_PROXY` automatically.
/// The allocated proxy strings must outlive the client, so the transport owns a
/// small arena dedicated to std's proxy configuration.
fn ensureDefaultProxies(self: *HttpTransport) !void {
    if (self.proxies_loaded) return;
    try self.client.initDefaultProxies(self.proxy_arena.allocator());
    self.proxies_loaded = true;
}

/// Applies send/receive socket timeouts after the HTTP client opens a socket.
///
/// `std.http.Client` does not expose a full request deadline in Zig 0.15.1:
/// DNS, TCP connect, and TLS setup already happened before this function can
/// touch the socket. This is still useful for bounded body upload and response
/// reads, but it is not the final provider timeout design.
fn applySocketTimeout(connection: *http.Client.Connection, timeout_ms: ?u64) !void {
    const timeout = timeout_ms orelse return;
    if (timeout == 0) return;

    const stream = connection.stream_reader.getStream();
    if (builtin.os.tag == .windows) {
        const timeout_u32: u32 = @intCast(@min(timeout, std.math.maxInt(u32)));
        const opt = std.mem.asBytes(&timeout_u32);
        try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, opt);
        try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, opt);
        return;
    }

    const seconds = timeout / std.time.ms_per_s;
    const micros = (timeout % std.time.ms_per_s) * std.time.us_per_ms;
    const tv = std.posix.timeval{
        .sec = @intCast(seconds),
        .usec = @intCast(micros),
    };
    const opt = std.mem.asBytes(&tv);
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, opt);
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, opt);
}

test "response deinit frees owned body" {
    const body = try std.testing.allocator.dupe(u8, "ok");
    const response: Response = .{
        .status = .ok,
        .body = body,
        .allocator = std.testing.allocator,
    };
    response.deinit();
}

test "https env proxy fails explicitly until transport owns CONNECT TLS" {
    var transport = HttpTransport.init(std.testing.allocator);
    defer transport.deinit();

    const result = transport.fetch(.{
        .method = .GET,
        .url = "https://api.example.test/v1/chat/completions",
        .use_env_proxy = true,
    });
    try std.testing.expectError(Error.HttpsEnvProxyUnsupported, result);
}
