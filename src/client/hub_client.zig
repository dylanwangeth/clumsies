//! HTTP client for the Hub server REST API. Handles Bearer token auth, content-type headers,
//! and provides typed request methods (GET/POST/PUT/DELETE). Used by CLI commands, TUI data
//! fetching, and trace upload.
const std = @import("std");
const http = std.http;
const auth_api = @import("clumsies_lib").protocol.auth_api;

pub const Response = struct {
    status: http.Status,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Response) void {
        self.allocator.free(self.body);
    }
};

/// Callback invoked after a successful token refresh so the caller
/// can persist the rotated pair (typically to the keychain or the
/// auth.json fallback). Failures are swallowed inside HubClient —
/// the in-memory tokens are already updated and the current request
/// will succeed with them; the next process will simply have to
/// refresh again.
pub const PersistFn = *const fn (
    allocator: std.mem.Allocator,
    hub_url: []const u8,
    username: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
) anyerror!void;

pub const HubClient = struct {
    allocator: std.mem.Allocator,
    hub_url: []const u8,
    access_token: ?[]const u8,
    // Persistent std.http.Client lets sequential requests reuse the
    // underlying TCP/TLS connection via the client's internal
    // connection pool. Prior to this, every doFetch built and tore
    // down its own Client, which forced a fresh handshake per call —
    // particularly costly over SSH-tunneled links where sync (~170
    // requests) became minutes of handshake overhead.
    client: http.Client,

    // Optional refresh plumbing. When `refresh_token` is set, any
    // request that returns 401 triggers a single
    // POST /api/auth/refresh attempt; on success the rotated access
    // token replaces `access_token_rotated`, the rotated refresh
    // token replaces `refresh_token`, and the original request is
    // retried exactly once. Callers that do not need refresh leave
    // these null and HubClient behaves identically to the pre-refresh
    // version. Owned memory; freed in deinit.
    refresh_token: ?[]u8 = null,
    username: ?[]u8 = null,
    persist_fn: ?PersistFn = null,
    /// Holds the post-refresh access token. Preferred over
    /// `access_token` once set. Separate field so the initial token
    /// can stay borrowed from the caller's AuthInfo.
    access_token_rotated: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, hub_url: []const u8, access_token: ?[]const u8) HubClient {
        return .{
            .allocator = allocator,
            .hub_url = hub_url,
            .access_token = access_token,
            .client = .{ .allocator = allocator },
        };
    }

    /// Wire refresh-on-401 for this client. `username` is the owner
    /// of the credentials (passed through to `persist_fn`). `persist_fn`
    /// is invoked after a successful refresh so the caller can save
    /// the rotated tokens; its failure does not abort the in-flight
    /// request.
    pub fn enableRefresh(
        self: *HubClient,
        refresh_token: []const u8,
        username: []const u8,
        persist_fn: PersistFn,
    ) !void {
        // Dupe both buffers into owned locals first, then commit into
        // `self.*` only once both succeed. Writing into `self.refresh_token`
        // before the second dupe completes would leave the field pointing at
        // a buffer that errdefer has already freed, so deinit would
        // double-free and any intervening read of `effectiveToken` would
        // touch freed memory.
        const owned_refresh_token = try self.allocator.dupe(u8, refresh_token);
        errdefer self.allocator.free(owned_refresh_token);
        const owned_username = try self.allocator.dupe(u8, username);
        errdefer self.allocator.free(owned_username);

        self.refresh_token = owned_refresh_token;
        self.username = owned_username;
        self.persist_fn = persist_fn;
    }

    pub fn deinit(self: *HubClient) void {
        if (self.refresh_token) |t| self.allocator.free(t);
        if (self.username) |u| self.allocator.free(u);
        if (self.access_token_rotated) |t| self.allocator.free(t);
        self.client.deinit();
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

    pub fn delete(self: *HubClient, path: []const u8) !Response {
        return self.doFetch(.DELETE, path, null);
    }

    pub fn patch(self: *HubClient, path: []const u8, body: []const u8) !Response {
        return self.doFetch(.PATCH, path, body);
    }

    fn effectiveToken(self: *const HubClient) ?[]const u8 {
        return self.access_token_rotated orelse self.access_token;
    }

    fn doFetch(self: *HubClient, method: http.Method, path: []const u8, payload: ?[]const u8) !Response {
        const first = try self.doFetchOnce(method, path, payload);
        // A 401 with no refresh plumbing is passed through unchanged
        // — callers have always handled the status code themselves.
        // With refresh enabled, we try exactly one rotation + retry
        // so long-idle sessions recover transparently.
        if (first.status != .unauthorized) return first;
        if (self.refresh_token == null) return first;

        first.deinit();
        self.refreshAndPersist() catch |err| {
            // Surface the refresh failure rather than the stale 401
            // so the caller sees a recognisable error code. The most
            // common case is a server-revoked refresh token, which
            // this path maps to `error.NotAuthenticated`.
            return err;
        };
        return self.doFetchOnce(method, path, payload);
    }

    fn refreshAndPersist(self: *HubClient) !void {
        const rt = self.refresh_token orelse return error.NotAuthenticated;
        const un = self.username orelse return error.NotAuthenticated;
        const persist = self.persist_fn orelse return error.NotAuthenticated;

        const body = std.json.Stringify.valueAlloc(
            self.allocator,
            auth_api.RefreshRequest{ .refresh_token = rt },
            .{},
        ) catch return error.OutOfMemory;
        defer self.allocator.free(body);

        const resp = try self.doFetchOnce(.POST, "/api/auth/refresh", body);
        defer resp.deinit();

        if (resp.status != .ok) return error.NotAuthenticated;

        const parsed = std.json.parseFromSlice(auth_api.RefreshResponse, self.allocator, resp.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return error.NotAuthenticated;
        defer parsed.deinit();

        // Swap tokens in place. The previous refresh_token is now
        // revoked server-side, so keeping the old value around would
        // guarantee a 401 on the next refresh attempt.
        const new_access = try self.allocator.dupe(u8, parsed.value.access_token);
        if (self.access_token_rotated) |old| self.allocator.free(old);
        self.access_token_rotated = new_access;

        const new_refresh = try self.allocator.dupe(u8, parsed.value.refresh_token);
        self.allocator.free(rt);
        self.refresh_token = new_refresh;

        // Persist failure is non-fatal — the in-memory tokens are
        // still correct for the rest of this process's lifetime.
        persist(self.allocator, self.hub_url, un, parsed.value.access_token, parsed.value.refresh_token) catch {};
    }

    fn doFetchOnce(self: *HubClient, method: http.Method, path: []const u8, payload: ?[]const u8) !Response {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.hub_url, path });
        defer self.allocator.free(url);

        var extra_headers: [2]http.Header = undefined;
        var header_count: usize = 0;

        extra_headers[header_count] = .{ .name = "content-type", .value = "application/json" };
        header_count += 1;

        var auth_value: ?[]const u8 = null;
        if (self.effectiveToken()) |token| {
            auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
            extra_headers[header_count] = .{ .name = "authorization", .value = auth_value.? };
            header_count += 1;
        }
        defer if (auth_value) |v| self.allocator.free(v);

        // Create an Io.Writer backed by an ArrayList for capturing response body
        var response_writer = std.Io.Writer.Allocating.init(self.allocator);
        errdefer response_writer.deinit();

        const result = try self.client.fetch(.{
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
