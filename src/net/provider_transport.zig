//! Zig-native transport for OpenAI-compatible provider requests.
//!
//! This module owns the provider network boundary that `std.http.Client` does
//! not expose clearly enough for the agent UI: proxy selection, HTTP CONNECT,
//! target-host TLS, response framing, and stage-specific diagnostics. It is not
//! a general HTTP client; it is intentionally scoped to HTTPS JSON provider
//! calls so the agent loop can get reliable behavior before broader HTTP
//! features are considered.

const std = @import("std");
const http = std.http;
const provider_http = @import("provider_http.zig");
const proxy_config = @import("proxy.zig");

const ProviderTransport = @This();

allocator: std.mem.Allocator,
ca_bundle: std.crypto.Certificate.Bundle = .{},
ca_loaded: bool = false,
last_failure: ?Failure = null,

pub const DEFAULT_MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;

pub const Request = struct {
    method: http.Method,
    url: []const u8,
    payload: []const u8,
    headers: []const http.Header = &.{},
    timeout_ms: ?u64 = null,
    use_env_proxy: bool = true,
    max_response_bytes: usize = DEFAULT_MAX_RESPONSE_BYTES,
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

pub const Failure = struct {
    stage: provider_http.Stage,
    message: []const u8,

    /// Releases the owned diagnostic text retained for CLI/TUI display.
    pub fn deinit(self: Failure, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

pub const Error = error{
    UnsupportedMethod,
    UnsupportedScheme,
    UnsupportedProxy,
    InvalidProviderUrl,
    InvalidProxyResponse,
    ResponseTooLarge,
    MalformedChunkedBody,
    ProviderTransportFailed,
};

/// Creates a provider transport with its own CA bundle cache.
pub fn init(allocator: std.mem.Allocator) ProviderTransport {
    return .{ .allocator = allocator };
}

/// Releases retained diagnostics and loaded certificate roots.
pub fn deinit(self: *ProviderTransport) void {
    self.clearLastFailure();
    self.ca_bundle.deinit(self.allocator);
}

/// Moves the last stage-specific failure out for user-facing diagnostics.
pub fn takeLastFailure(self: *ProviderTransport) ?Failure {
    const failure = self.last_failure;
    self.last_failure = null;
    return failure;
}

/// Performs one HTTPS JSON provider request.
///
/// The request API keeps an HTTP method field for future provider endpoints,
/// but this transport currently validates the real inference path: HTTPS JSON
/// `POST`. Returning `UnsupportedMethod` here is deliberate; it keeps the
/// caller boundary extensible without pretending every HTTP method has already
/// been tested through proxy, TLS, and response framing.
pub fn fetch(self: *ProviderTransport, request: Request) !Response {
    self.clearLastFailure();
    if (request.method != .POST) return self.fail(.write_request, "provider transport currently validates POST only", Error.UnsupportedMethod);

    const target = parseTarget(self.allocator, request.url) catch |err| switch (err) {
        error.UnsupportedScheme => return self.fail(.parse_url, "provider transport only supports https URLs", Error.UnsupportedScheme),
        else => return self.fail(.parse_url, "invalid provider URL", Error.InvalidProviderUrl),
    };
    defer target.deinit(self.allocator);

    try self.ensureCaBundle();

    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    const proxy_decision: proxy_config.Decision = if (request.use_env_proxy) decision: {
        env_map = try std.process.getEnvMap(self.allocator);
        break :decision proxy_config.decide(&env_map.?, .https, target.host);
    } else .direct;

    var stream = switch (proxy_decision) {
        .direct => self.connectTcp(target.host, target.port, .tcp_connect),
        .http => |proxy| stream: {
            var proxy_stream = try self.connectTcp(proxy.host, proxy.port, .tcp_connect);
            errdefer proxy_stream.close();
            try self.connectProxyTunnel(proxy_stream, target);
            break :stream proxy_stream;
        },
        .unsupported => |unsupported| return self.failUnsupportedProxy(unsupported),
    } catch |err| return err;
    defer stream.close();

    try applySocketTimeout(stream, request.timeout_ms);

    var tls_endpoint: provider_http.TlsEndpoint = undefined;
    tls_endpoint.init(stream, target.host, self.ca_bundle) catch |err| {
        return self.failFmt(.tls, "TLS handshake with {s}:{d} failed: {s}", .{ target.host, target.port, @errorName(err) }, Error.ProviderTransportFailed);
    };

    try self.writeRequest(&tls_endpoint.client.writer, target, request);
    tls_endpoint.stream_writer.interface.flush() catch |err| {
        return self.failFmt(.write_request, "failed to flush encrypted provider request: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    return self.readResponse(&tls_endpoint.client.reader, request.max_response_bytes);
}

fn clearLastFailure(self: *ProviderTransport) void {
    if (self.last_failure) |failure| {
        failure.deinit(self.allocator);
        self.last_failure = null;
    }
}

fn ensureCaBundle(self: *ProviderTransport) !void {
    if (self.ca_loaded) return;
    self.ca_bundle.rescan(self.allocator) catch |err| {
        return self.failFmt(.tls, "failed to load system certificate bundle: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    self.ca_loaded = true;
}

fn connectTcp(
    self: *ProviderTransport,
    host: []const u8,
    port: u16,
    stage: provider_http.Stage,
) !std.net.Stream {
    return std.net.tcpConnectToHost(self.allocator, host, port) catch |err| {
        return self.failFmt(stage, "TCP connect to {s}:{d} failed: {s}", .{ host, port, @errorName(err) }, Error.ProviderTransportFailed);
    };
}

/// Upgrades a TCP connection to an HTTP proxy into a tunnel to the provider.
///
/// This function stops immediately after the proxy returns `200`. It must not
/// start TLS itself because the caller uses the same TLS path for direct and
/// proxied streams, and that TLS handshake must verify the provider host, not
/// the proxy host.
fn connectProxyTunnel(self: *ProviderTransport, stream: std.net.Stream, target: Target) !void {
    var write_buffer: [1024]u8 = undefined;
    var stream_writer = stream.writer(&write_buffer);
    const writer = &stream_writer.interface;
    writer.print(
        "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: clumsies-agent\r\nProxy-Connection: close\r\n\r\n",
        .{ target.host, target.port, target.host, target.port },
    ) catch |err| {
        return self.failFmt(.proxy_connect, "failed to write proxy CONNECT request: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    writer.flush() catch |err| {
        return self.failFmt(.proxy_connect, "failed to flush proxy CONNECT request: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };

    var read_buffer: [8192]u8 = undefined;
    var stream_reader = stream.reader(&read_buffer);
    var head_bytes: std.ArrayList(u8) = .empty;
    defer head_bytes.deinit(self.allocator);

    try readUntilHeadEnd(self, stream_reader.interface(), &head_bytes, provider_http.MAX_HEAD_BYTES, .proxy_connect);
    const head = provider_http.parseHead(self.allocator, head_bytes.items) catch |err| {
        return self.failFmt(.proxy_connect, "invalid proxy CONNECT response: {s}", .{@errorName(err)}, Error.InvalidProxyResponse);
    };
    defer head.deinit(self.allocator);

    if (head.status_code != 200) {
        return self.failFmt(.proxy_connect, "proxy refused CONNECT with HTTP {d}", .{head.status_code}, Error.ProviderTransportFailed);
    }
}

/// Writes the provider HTTP/1.1 request over an already-secure stream.
///
/// Provider adapters own auth and API-specific headers, while the transport
/// owns framing headers that must stay consistent with the bytes it writes:
/// `Host`, `Content-Length`, `Connection`, and `Accept-Encoding`.
fn writeRequest(
    self: *ProviderTransport,
    writer: *std.Io.Writer,
    target: Target,
    request: Request,
) !void {
    writer.print("{s} {s} HTTP/1.1\r\n", .{ @tagName(request.method), target.request_target }) catch |err| {
        return self.failFmt(.write_request, "failed to write request line: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    writer.print("Host: {s}\r\n", .{target.host}) catch |err| {
        return self.failFmt(.write_request, "failed to write Host header: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    writer.writeAll("Connection: close\r\nAccept-Encoding: identity\r\n") catch |err| {
        return self.failFmt(.write_request, "failed to write fixed provider headers: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    writer.print("Content-Length: {d}\r\n", .{request.payload.len}) catch |err| {
        return self.failFmt(.write_request, "failed to write Content-Length header: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    for (request.headers) |header| {
        if (isManagedHeader(header.name)) continue;
        writer.print("{s}: {s}\r\n", .{ header.name, header.value }) catch |err| {
            return self.failFmt(.write_request, "failed to write provider header {s}: {s}", .{ header.name, @errorName(err) }, Error.ProviderTransportFailed);
        };
    }
    writer.writeAll("\r\n") catch |err| {
        return self.failFmt(.write_request, "failed to finish provider headers: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    writer.writeAll(request.payload) catch |err| {
        return self.failFmt(.write_request, "failed to write provider request body: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    writer.flush() catch |err| {
        return self.failFmt(.write_request, "failed to flush provider request: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
}

/// Reads one HTTP/1.1 provider response into an owned body.
///
/// The head read may already contain body bytes, especially on fast local tests
/// or small provider responses. Keeping the raw buffer and slicing at the head
/// terminator prevents losing those bytes before content-length/chunked/body-
/// until-close handling starts.
fn readResponse(self: *ProviderTransport, reader: *std.Io.Reader, max_response_bytes: usize) !Response {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(self.allocator);

    try readUntilHeadEnd(self, reader, &raw, provider_http.MAX_HEAD_BYTES, .read_head);
    const body_start = (std.mem.indexOf(u8, raw.items, "\r\n\r\n") orelse return self.fail(.read_head, "provider response head terminator disappeared", Error.ProviderTransportFailed)) + 4;
    const head = provider_http.parseHead(self.allocator, raw.items[0..body_start]) catch |err| {
        return self.failFmt(.read_head, "invalid provider response head: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    defer head.deinit(self.allocator);

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(self.allocator);
    try body.appendSlice(self.allocator, raw.items[body_start..]);
    if (body.items.len > max_response_bytes) return self.fail(.read_body, "provider response body exceeded limit", Error.ResponseTooLarge);

    switch (head.transfer_coding) {
        .chunked => {
            const decoded = try self.decodeChunked(reader, body.items, max_response_bytes);
            body.deinit(self.allocator);
            body = decoded;
        },
        .identity => if (head.content_length) |len| {
            if (len > max_response_bytes) return self.fail(.read_body, "provider response body exceeded limit", Error.ResponseTooLarge);
            try readUntilLength(self, reader, &body, len, max_response_bytes);
        } else {
            try readUntilClose(self, reader, &body, max_response_bytes);
        },
    }

    return .{
        .status = @enumFromInt(head.status_code),
        .body = try body.toOwnedSlice(self.allocator),
        .allocator = self.allocator,
    };
}

fn readUntilHeadEnd(
    self: *ProviderTransport,
    reader: *std.Io.Reader,
    out: *std.ArrayList(u8),
    max_head_bytes: usize,
    stage: provider_http.Stage,
) !void {
    while (std.mem.indexOf(u8, out.items, "\r\n\r\n") == null) {
        if (out.items.len >= max_head_bytes) return self.fail(stage, "HTTP response head exceeded limit", Error.ProviderTransportFailed);
        const byte = readOne(reader) catch |err| {
            return self.failFmt(stage, "failed while reading HTTP response head: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
        };
        try out.append(self.allocator, byte);
    }
}

fn readUntilLength(
    self: *ProviderTransport,
    reader: *std.Io.Reader,
    body: *std.ArrayList(u8),
    len: usize,
    max_response_bytes: usize,
) !void {
    var buffer: [8192]u8 = undefined;
    while (body.items.len < len) {
        const need = @min(buffer.len, len - body.items.len);
        const n = reader.readSliceShort(buffer[0..need]) catch |err| {
            return self.failFmt(.read_body, "failed while reading provider body: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
        };
        if (n == 0) return self.fail(.read_body, "connection closed before Content-Length body completed", Error.ProviderTransportFailed);
        try body.appendSlice(self.allocator, buffer[0..n]);
        if (body.items.len > max_response_bytes) return self.fail(.read_body, "provider response body exceeded limit", Error.ResponseTooLarge);
    }
    if (body.items.len > len) body.shrinkRetainingCapacity(len);
}

fn readUntilClose(
    self: *ProviderTransport,
    reader: *std.Io.Reader,
    body: *std.ArrayList(u8),
    max_response_bytes: usize,
) !void {
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&buffer) catch |err| {
            return self.failFmt(.read_body, "failed while reading provider body: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
        };
        if (n == 0) return;
        try body.appendSlice(self.allocator, buffer[0..n]);
        if (body.items.len > max_response_bytes) return self.fail(.read_body, "provider response body exceeded limit", Error.ResponseTooLarge);
    }
}

/// Decodes `Transfer-Encoding: chunked` while preserving bytes already read.
///
/// The `initial` slice is the response-body remainder captured during head
/// parsing. The decoder appends more encrypted-stream plaintext only when the
/// buffered chunk framing is incomplete.
fn decodeChunked(
    self: *ProviderTransport,
    reader: *std.Io.Reader,
    initial: []const u8,
    max_response_bytes: usize,
) !std.ArrayList(u8) {
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(self.allocator);
    try encoded.appendSlice(self.allocator, initial);

    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(self.allocator);

    var index: usize = 0;
    while (true) {
        const line_end = try self.ensureLine(reader, &encoded, &index);
        const line = encoded.items[index..line_end];
        index = line_end + 2;
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const size_text = std.mem.trim(u8, line[0..semi], " \t");
        const chunk_size = std.fmt.parseInt(usize, size_text, 16) catch {
            return self.fail(.read_body, "invalid chunk size in provider response", Error.MalformedChunkedBody);
        };
        if (chunk_size == 0) return decoded;

        try self.ensureAvailable(reader, &encoded, index + chunk_size + 2);
        try decoded.appendSlice(self.allocator, encoded.items[index .. index + chunk_size]);
        if (decoded.items.len > max_response_bytes) return self.fail(.read_body, "provider response body exceeded limit", Error.ResponseTooLarge);
        index += chunk_size;
        if (!std.mem.eql(u8, encoded.items[index .. index + 2], "\r\n")) {
            return self.fail(.read_body, "chunk data missing CRLF terminator", Error.MalformedChunkedBody);
        }
        index += 2;
    }
}

fn ensureLine(
    self: *ProviderTransport,
    reader: *std.Io.Reader,
    encoded: *std.ArrayList(u8),
    index: *usize,
) !usize {
    while (true) {
        if (std.mem.indexOf(u8, encoded.items[index.*..], "\r\n")) |relative| return index.* + relative;
        try self.readMoreBody(reader, encoded);
    }
}

fn ensureAvailable(
    self: *ProviderTransport,
    reader: *std.Io.Reader,
    encoded: *std.ArrayList(u8),
    end: usize,
) !void {
    while (encoded.items.len < end) try self.readMoreBody(reader, encoded);
}

fn readMoreBody(self: *ProviderTransport, reader: *std.Io.Reader, out: *std.ArrayList(u8)) !void {
    const byte = readOne(reader) catch |err| {
        return self.failFmt(.read_body, "failed while reading chunked provider body: {s}", .{@errorName(err)}, Error.ProviderTransportFailed);
    };
    try out.append(self.allocator, byte);
}

fn readOne(reader: *std.Io.Reader) !u8 {
    var byte: [1]u8 = undefined;
    const n = try reader.readSliceShort(&byte);
    if (n == 0) return error.EndOfStream;
    return byte[0];
}

fn failUnsupportedProxy(self: *ProviderTransport, unsupported: proxy_config.Unsupported) !Response {
    return self.failFmt(.resolve_proxy, "unsupported proxy {s}: {s}", .{ @tagName(unsupported.reason), unsupported.value }, Error.UnsupportedProxy);
}

fn fail(
    self: *ProviderTransport,
    stage: provider_http.Stage,
    message: []const u8,
    err: anyerror,
) anyerror {
    self.clearLastFailure();
    self.last_failure = .{
        .stage = stage,
        .message = self.allocator.dupe(u8, message) catch @panic("failed to allocate provider failure message"),
    };
    return err;
}

fn failFmt(
    self: *ProviderTransport,
    stage: provider_http.Stage,
    comptime format: []const u8,
    args: anytype,
    err: anyerror,
) anyerror {
    self.clearLastFailure();
    self.last_failure = .{
        .stage = stage,
        .message = std.fmt.allocPrint(self.allocator, format, args) catch @panic("failed to allocate provider failure message"),
    };
    return err;
}

const Target = struct {
    host: []const u8,
    port: u16,
    request_target: []const u8,

    fn deinit(self: Target, allocator: std.mem.Allocator) void {
        allocator.free(self.request_target);
    }
};

fn parseTarget(allocator: std.mem.Allocator, url: []const u8) !Target {
    const uri = try std.Uri.parse(url);
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedScheme;
    const host_component = uri.host orelse return error.InvalidProviderUrl;
    const host = switch (host_component) {
        .raw, .percent_encoded => |value| value,
    };
    if (host.len == 0) return error.InvalidProviderUrl;

    const path = if (uri.path.isEmpty()) "/" else uri.path.percent_encoded;
    const request_target = if (uri.query) |query|
        try std.fmt.allocPrint(allocator, "{s}?{s}", .{ path, query.percent_encoded })
    else
        try allocator.dupe(u8, path);

    return .{
        .host = trimIpv6Brackets(host),
        .port = uri.port orelse 443,
        .request_target = request_target,
    };
}

fn trimIpv6Brackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return host;
}

fn isManagedHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "accept-encoding");
}

fn applySocketTimeout(stream: std.net.Stream, timeout_ms: ?u64) !void {
    const timeout = timeout_ms orelse return;
    if (timeout == 0) return;

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

test "parseTarget accepts https provider urls" {
    const target = try parseTarget(std.testing.allocator, "https://api.example.com/v1/chat/completions");
    defer target.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("api.example.com", target.host);
    try std.testing.expectEqual(@as(u16, 443), target.port);
    try std.testing.expectEqualStrings("/v1/chat/completions", target.request_target);
}

test "chunked decoder returns decoded body" {
    var transport = ProviderTransport.init(std.testing.allocator);
    defer transport.deinit();

    var reader = std.Io.Reader.fixed("");
    var decoded = try transport.decodeChunked(
        &reader,
        "4\r\npong\r\n5\r\n test\r\n0\r\n\r\n",
        128,
    );
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pong test", decoded.items);
}

test "readResponse preserves body bytes read with response head" {
    var transport = ProviderTransport.init(std.testing.allocator);
    defer transport.deinit();

    var reader = std.Io.Reader.fixed(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 4\r\n" ++
            "\r\n" ++
            "pong",
    );
    const response = try transport.readResponse(&reader, 128);
    defer response.deinit();

    try std.testing.expectEqual(http.Status.ok, response.status);
    try std.testing.expectEqualStrings("pong", response.body);
}

test "readResponse retains non-OK provider body" {
    var transport = ProviderTransport.init(std.testing.allocator);
    defer transport.deinit();

    var reader = std.Io.Reader.fixed(
        "HTTP/1.1 401 Unauthorized\r\n" ++
            "Content-Length: 20\r\n" ++
            "\r\n" ++
            "{\"error\":\"bad key\"}\n",
    );
    const response = try transport.readResponse(&reader, 128);
    defer response.deinit();

    try std.testing.expectEqual(http.Status.unauthorized, response.status);
    try std.testing.expectEqualStrings("{\"error\":\"bad key\"}\n", response.body);
}
