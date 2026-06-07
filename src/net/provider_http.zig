//! Narrow HTTP/TLS building blocks for OpenAI-compatible provider transport.
//!
//! This module is intentionally not a general HTTP client. It collects the
//! pieces that the provider transport must own instead of delegating to
//! `std.http.Client`'s proxy path: after an HTTP proxy `CONNECT`, the transport
//! needs to start TLS against the target provider host, report failures by
//! stage, and keep response parsing small enough to audit.

const std = @import("std");

pub const MAX_HEAD_BYTES = 64 * 1024;

/// Execution stage used to preserve where a provider network failure happened.
pub const Stage = enum {
    parse_url,
    resolve_proxy,
    dns,
    tcp_connect,
    proxy_connect,
    tls,
    write_request,
    read_head,
    read_body,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const TransferCoding = enum {
    identity,
    chunked,
};

pub const Head = struct {
    version: []const u8,
    status_code: u16,
    reason: []const u8,
    headers: []const Header,
    content_length: ?usize = null,
    transfer_coding: TransferCoding = .identity,

    pub fn deinit(self: Head, allocator: std.mem.Allocator) void {
        allocator.free(self.headers);
    }
};

pub const ParseHeadError = error{
    MissingHeadTerminator,
    HeadTooLarge,
    MalformedStatusLine,
    MalformedHeader,
    DuplicateContentLength,
    InvalidContentLength,
    UnsupportedHttpVersion,
    OutOfMemory,
};

/// Owns the buffers required by Zig 0.15.1's `std.crypto.tls.Client`.
///
/// The standard TLS client operates on `std.Io.Reader`/`std.Io.Writer`
/// interfaces supplied by the caller. Keeping these buffers in one endpoint
/// object makes the future provider transport's direct and proxy-CONNECT paths
/// use the same TLS handshake code after they obtain a TCP stream.
pub const TlsEndpoint = struct {
    stream: std.net.Stream,
    tls_read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    socket_write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    socket_read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,
    client: std.crypto.tls.Client,

    /// Starts TLS over an already-connected stream.
    ///
    /// This is the key interface the provider transport needs after either a
    /// direct TCP connection or a successful proxy `CONNECT`: TLS is always
    /// verified against the provider host, not the proxy host.
    ///
    /// Call this on a `TlsEndpoint` stored at its final address. The stream
    /// reader, stream writer, and TLS client keep pointers into this struct's
    /// buffers; returning an initialized endpoint by value would move those
    /// buffers and leave stale pointers behind.
    pub fn init(
        self: *TlsEndpoint,
        stream: std.net.Stream,
        host: []const u8,
        ca_bundle: std.crypto.Certificate.Bundle,
    ) !void {
        self.stream = stream;
        self.stream_reader = stream.reader(&self.socket_read_buffer);
        self.stream_writer = stream.writer(&self.tls_write_buffer);
        self.client = try std.crypto.tls.Client.init(
            self.stream_reader.interface(),
            &self.stream_writer.interface,
            .{
                .host = .{ .explicit = host },
                .ca = .{ .bundle = ca_bundle },
                .read_buffer = &self.tls_read_buffer,
                .write_buffer = &self.socket_write_buffer,
                // HTTP response framing verifies body completeness, so the
                // provider transport can tolerate servers that close without a
                // TLS close_notify after the HTTP body is complete.
                .allow_truncation_attacks = true,
            },
        );
    }
};

/// Parses the HTTP/1.1 response head already read from the network.
///
/// Provider body handling depends on this small contract: `Content-Length`
/// means bounded reads, while `Transfer-Encoding: chunked` switches the body
/// reader into chunk framing. The returned header names and values borrow from
/// `bytes`; only the header slice itself is allocator-owned.
pub fn parseHead(allocator: std.mem.Allocator, bytes: []const u8) ParseHeadError!Head {
    if (bytes.len > MAX_HEAD_BYTES) return error.HeadTooLarge;
    const head_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.MissingHeadTerminator;
    const raw_head = bytes[0..head_end];

    var lines = std.mem.splitSequence(u8, raw_head, "\r\n");
    const status_line = lines.next() orelse return error.MalformedStatusLine;
    const status = try parseStatusLine(status_line);

    var headers: std.ArrayList(Header) = .empty;
    errdefer headers.deinit(allocator);

    var content_length: ?usize = null;
    var transfer_coding: TransferCoding = .identity;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const header = try parseHeader(line);
        try headers.append(allocator, header);

        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
            if (content_length != null) return error.DuplicateContentLength;
            content_length = std.fmt.parseInt(usize, header.value, 10) catch
                return error.InvalidContentLength;
        } else if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) {
            if (containsHeaderToken(header.value, "chunked")) transfer_coding = .chunked;
        }
    }

    return .{
        .version = status.version,
        .status_code = status.status_code,
        .reason = status.reason,
        .headers = try headers.toOwnedSlice(allocator),
        .content_length = content_length,
        .transfer_coding = transfer_coding,
    };
}

const StatusLine = struct {
    version: []const u8,
    status_code: u16,
    reason: []const u8,
};

/// Splits the status line without normalizing it into `std.http.Response`.
///
/// The provider transport wants parser errors to remain in `Stage.read_head`
/// rather than being collapsed into a broader std HTTP client error.
fn parseStatusLine(line: []const u8) ParseHeadError!StatusLine {
    if (!std.mem.startsWith(u8, line, "HTTP/1.1 ") and
        !std.mem.startsWith(u8, line, "HTTP/1.0 "))
    {
        return error.UnsupportedHttpVersion;
    }

    var fields = std.mem.splitScalar(u8, line, ' ');
    const version = fields.next() orelse return error.MalformedStatusLine;
    const code_text = fields.next() orelse return error.MalformedStatusLine;
    if (code_text.len != 3) return error.MalformedStatusLine;
    const status_code = std.fmt.parseInt(u16, code_text, 10) catch
        return error.MalformedStatusLine;

    const reason_start = version.len + 1 + code_text.len;
    const reason = if (line.len > reason_start + 1) line[reason_start + 1 ..] else "";
    return .{
        .version = version,
        .status_code = status_code,
        .reason = reason,
    };
}

/// Parses one header line into borrowed name/value slices.
///
/// Values are trimmed because providers and proxies commonly emit a single
/// space after the colon; names stay unmodified so duplicate or invalid names
/// can be reported by future stricter validation if needed.
fn parseHeader(line: []const u8) ParseHeadError!Header {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedHeader;
    if (colon == 0) return error.MalformedHeader;
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    return .{
        .name = line[0..colon],
        .value = value,
    };
}

/// Matches comma-separated header tokens such as `Transfer-Encoding: gzip, chunked`.
fn containsHeaderToken(value: []const u8, token: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, token)) return true;
    }
    return false;
}

test "parseHead reads status headers and content length" {
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 27\r\n" ++
        "\r\n" ++
        "{\"id\":\"chatcmpl-test\"}\n";

    const head = try parseHead(std.testing.allocator, raw);
    defer head.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 200), head.status_code);
    try std.testing.expectEqualStrings("OK", head.reason);
    try std.testing.expectEqual(@as(?usize, 27), head.content_length);
    try std.testing.expectEqual(TransferCoding.identity, head.transfer_coding);
    try std.testing.expectEqual(@as(usize, 2), head.headers.len);
    try std.testing.expectEqualStrings("Content-Type", head.headers[0].name);
    try std.testing.expectEqualStrings("application/json", head.headers[0].value);
}

test "parseHead recognizes chunked transfer coding" {
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Transfer-Encoding: gzip, chunked\r\n" ++
        "\r\n" ++
        "4\r\n" ++
        "pong\r\n" ++
        "0\r\n\r\n";

    const head = try parseHead(std.testing.allocator, raw);
    defer head.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, null), head.content_length);
    try std.testing.expectEqual(TransferCoding.chunked, head.transfer_coding);
}

test "parseHead rejects malformed inputs" {
    try std.testing.expectError(
        error.MissingHeadTerminator,
        parseHead(std.testing.allocator, "HTTP/1.1 200 OK\r\n"),
    );
    try std.testing.expectError(
        error.UnsupportedHttpVersion,
        parseHead(std.testing.allocator, "HTTP/2 200 OK\r\n\r\n"),
    );
    try std.testing.expectError(
        error.InvalidContentLength,
        parseHead(std.testing.allocator, "HTTP/1.1 200 OK\r\nContent-Length: many\r\n\r\n"),
    );
}

test "TlsEndpoint init compiles against Zig 0.15 TLS IO interfaces" {
    // Keep this branch unreachable at runtime while still forcing semantic
    // analysis of the TLS helper call shape during `zig test`.
    if (std.time.nanoTimestamp() == std.math.minInt(i128)) {
        var endpoint: TlsEndpoint = undefined;
        const stream: std.net.Stream = undefined;
        const ca_bundle: std.crypto.Certificate.Bundle = undefined;
        try endpoint.init(stream, "api.example.test", ca_bundle);
    }
}
