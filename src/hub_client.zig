const std = @import("std");
const http = std.http;

pub const Response = struct {
    status: http.Status,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Response) void {
        self.allocator.free(self.body);
    }
};

pub const HubClient = struct {
    allocator: std.mem.Allocator,
    hub_url: []const u8,
    access_token: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, hub_url: []const u8, access_token: ?[]const u8) HubClient {
        return .{
            .allocator = allocator,
            .hub_url = hub_url,
            .access_token = access_token,
        };
    }

    pub fn get(self: *HubClient, path: []const u8) !Response {
        return self.doFetch(.GET, path, null);
    }

    pub fn post(self: *HubClient, path: []const u8, body: []const u8) !Response {
        return self.doFetch(.POST, path, body);
    }

    pub fn put(self: *HubClient, path: []const u8, body: []const u8) !Response {
        return self.doFetch(.PUT, path, body);
    }

    fn doFetch(self: *HubClient, method: http.Method, path: []const u8, payload: ?[]const u8) !Response {
        var client: http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.hub_url, path });
        defer self.allocator.free(url);

        var extra_headers: [2]http.Header = undefined;
        var header_count: usize = 0;

        extra_headers[header_count] = .{ .name = "content-type", .value = "application/json" };
        header_count += 1;

        var auth_value: ?[]const u8 = null;
        if (self.access_token) |token| {
            auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
            extra_headers[header_count] = .{ .name = "authorization", .value = auth_value.? };
            header_count += 1;
        }
        defer if (auth_value) |v| self.allocator.free(v);

        // Create an Io.Writer backed by an ArrayList for capturing response body
        var response_writer = std.Io.Writer.Allocating.init(self.allocator);
        errdefer response_writer.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .extra_headers = extra_headers[0..header_count],
            .response_writer = &response_writer.writer,
        });

        const body = try response_writer.toOwnedSlice();

        return .{
            .status = result.status,
            .body = body,
            .allocator = self.allocator,
        };
    }
};
