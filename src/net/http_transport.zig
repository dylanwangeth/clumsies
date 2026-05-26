//! Thin HTTP transport wrapper over `std.http.Client`.

const std = @import("std");
const http = std.http;

const HttpTransport = @This();

allocator: std.mem.Allocator,
client: http.Client,

pub const Request = struct {
    method: http.Method,
    url: []const u8,
    payload: ?[]const u8 = null,
    headers: []const http.Header = &.{},
    keep_alive: bool = true,
};

pub const Response = struct {
    status: http.Status,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Response) void {
        self.allocator.free(self.body);
    }
};

pub fn init(allocator: std.mem.Allocator) HttpTransport {
    return .{
        .allocator = allocator,
        .client = .{ .allocator = allocator },
    };
}

pub fn deinit(self: *HttpTransport) void {
    self.client.deinit();
}

pub fn fetch(self: *HttpTransport, request: Request) !Response {
    var response_writer = std.Io.Writer.Allocating.init(self.allocator);
    errdefer response_writer.deinit();

    const uri = try std.Uri.parse(request.url);
    var client_request = try self.client.request(request.method, uri, .{
        .extra_headers = request.headers,
        .keep_alive = request.keep_alive,
        .redirect_behavior = .unhandled,
    });
    defer client_request.deinit();

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
        try client_request.connection.?.flush();
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

test "response deinit frees owned body" {
    const body = try std.testing.allocator.dupe(u8, "ok");
    const response: Response = .{
        .status = .ok,
        .body = body,
        .allocator = std.testing.allocator,
    };
    response.deinit();
}
