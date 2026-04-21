//! Authentication credential storage. Persists Hub URL, username, and tokens to the macOS
//! Keychain (file fallback on other platforms). Shared by CLI login, MCP startup, and TUI init.
const std = @import("std");
const build_options = @import("build_options");
const enable_keychain = build_options.enable_keychain;
const log = std.log.scoped(.auth);
const auth_api = @import("clumsies_lib").protocol.auth_api;
const HubClient = @import("hub_client.zig").HubClient;

pub const AuthInfo = struct {
    hub_url: []const u8,
    username: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,

    pub fn deinit(self: AuthInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.hub_url);
        allocator.free(self.username);
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
    }
};

pub const SaveLocation = enum {
    keychain,
    file_default,
    file_fallback,
};

const SERVICE_NAME = "clumsies";
const ACCOUNT_NAME = "hub-auth";

pub fn getBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.HomeNotSet;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".clumsies" });
}

pub fn saveAuth(allocator: std.mem.Allocator, hub_url: []const u8, username: []const u8, access_token: []const u8, refresh_token: []const u8) !SaveLocation {
    const payload = AuthJson{
        .hub_url = hub_url,
        .username = username,
        .access_token = access_token,
        .refresh_token = refresh_token,
    };
    const json = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return error.SerializationFailed;
    defer allocator.free(json);

    if (comptime enable_keychain) {
        keychainStore(json) catch |err| {
            log.warn("keychain store failed ({s}); falling back to auth.json", .{@errorName(err)});
            try fileFallbackStore(allocator, json);
            return .file_fallback;
        };
        return .keychain;
    } else {
        try fileFallbackStore(allocator, json);
        return .file_default;
    }
}

/// Load credentials and, if the access token is rejected by Hub,
/// transparently refresh using the stored refresh token before
/// returning. Callers that previously used `loadAuth` directly and
/// subsequently saw unexplained 401s are the target consumers —
/// sync, init, trace upload. Falls back to a plain loadAuth result
/// when the refresh round-trip fails; callers still see that as a
/// normal `NotAuthenticated` at the next Hub call and can surface
/// "Run clumsies login" to the user.
pub fn loadAuthAndRefresh(allocator: std.mem.Allocator) !AuthInfo {
    var auth_info = try loadAuth(allocator);
    errdefer auth_info.deinit(allocator);

    var probe = HubClient.init(allocator, auth_info.hub_url, auth_info.access_token);
    defer probe.deinit();

    const probe_resp = probe.get("/api/auth/me") catch {
        // Network failure — don't try to refresh; let the caller's
        // actual Hub request fail with the real network error so the
        // user sees a coherent message.
        return auth_info;
    };
    defer probe_resp.deinit();

    if (probe_resp.status != .unauthorized) return auth_info;

    const refresh_body = std.json.Stringify.valueAlloc(
        allocator,
        auth_api.RefreshRequest{ .refresh_token = auth_info.refresh_token },
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(refresh_body);

    const refresh_resp = probe.post("/api/auth/refresh", refresh_body) catch {
        return auth_info;
    };
    defer refresh_resp.deinit();

    if (refresh_resp.status != .ok) {
        // Refresh token itself is rejected (expired / revoked).
        // Surface a recognisable error so callers can prompt for
        // re-login instead of looping into "Run clumsies login" via
        // a raw 401 from the actual sync request.
        return error.NotAuthenticated;
    }

    const parsed = std.json.parseFromSlice(auth_api.RefreshResponse, allocator, refresh_resp.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return auth_info;
    defer parsed.deinit();

    const new_access = try allocator.dupe(u8, parsed.value.access_token);
    const new_refresh = try allocator.dupe(u8, parsed.value.refresh_token);

    _ = saveAuth(
        allocator,
        auth_info.hub_url,
        auth_info.username,
        new_access,
        new_refresh,
    ) catch |err| {
        log.warn("saveAuth after refresh failed ({s}); using new tokens in-memory only", .{@errorName(err)});
    };

    allocator.free(auth_info.access_token);
    allocator.free(auth_info.refresh_token);
    auth_info.access_token = new_access;
    auth_info.refresh_token = new_refresh;
    return auth_info;
}

pub fn loadAuth(allocator: std.mem.Allocator) !AuthInfo {
    const json = if (comptime enable_keychain)
        keychainLookup(allocator) catch |err| blk: {
            if (err != error.NotAuthenticated) {
                log.warn("keychain lookup failed ({s}); trying auth.json", .{@errorName(err)});
            }
            break :blk fileFallbackLoad(allocator) catch return error.NotAuthenticated;
        }
    else
        fileFallbackLoad(allocator) catch return error.NotAuthenticated;
    defer allocator.free(json);

    const parsed = std.json.parseFromSlice(AuthJson, allocator, json, .{ .allocate = .alloc_always }) catch return error.NotAuthenticated;
    defer parsed.deinit();

    return .{
        .hub_url = try allocator.dupe(u8, parsed.value.hub_url),
        .username = try allocator.dupe(u8, parsed.value.username),
        .access_token = try allocator.dupe(u8, parsed.value.access_token),
        .refresh_token = try allocator.dupe(u8, parsed.value.refresh_token),
    };
}

const AuthJson = struct {
    hub_url: []const u8,
    username: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
};

// macOS Keychain via Security framework
const c = if (enable_keychain) @cImport({
    @cInclude("Security/Security.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
}) else struct {};

fn keychainStore(data: []const u8) !void {
    if (comptime !enable_keychain) return error.KeychainError;

    var item: c.SecKeychainItemRef = null;
    const find_status = c.SecKeychainFindGenericPassword(
        null,
        @as(c.UInt32, @intCast(SERVICE_NAME.len)),
        @as([*c]const u8, @ptrCast(SERVICE_NAME.ptr)),
        @as(c.UInt32, @intCast(ACCOUNT_NAME.len)),
        @as([*c]const u8, @ptrCast(ACCOUNT_NAME.ptr)),
        null,
        null,
        &item,
    );
    defer if (item != null) c.CFRelease(item);

    if (find_status == c.errSecSuccess) {
        const update_status = c.SecKeychainItemModifyAttributesAndData(
            item,
            null,
            @as(c.UInt32, @intCast(data.len)),
            @ptrCast(data.ptr),
        );
        if (update_status != c.errSecSuccess) {
            log.warn("SecKeychainItemModifyAttributesAndData failed with OSStatus {d}", .{update_status});
            return error.KeychainError;
        }
        return;
    }

    if (find_status != c.errSecItemNotFound) {
        log.warn("SecKeychainFindGenericPassword failed with OSStatus {d}", .{find_status});
        return error.KeychainError;
    }

    const add_status = c.SecKeychainAddGenericPassword(
        null,
        @as(c.UInt32, @intCast(SERVICE_NAME.len)),
        @as([*c]const u8, @ptrCast(SERVICE_NAME.ptr)),
        @as(c.UInt32, @intCast(ACCOUNT_NAME.len)),
        @as([*c]const u8, @ptrCast(ACCOUNT_NAME.ptr)),
        @as(c.UInt32, @intCast(data.len)),
        @ptrCast(data.ptr),
        null,
    );
    if (add_status != c.errSecSuccess) {
        log.warn("SecKeychainAddGenericPassword failed with OSStatus {d}", .{add_status});
        return error.KeychainError;
    }
}

fn keychainLookup(allocator: std.mem.Allocator) ![]const u8 {
    if (comptime !enable_keychain) return error.NotAuthenticated;

    var password_len: c.UInt32 = 0;
    var password_data: ?*anyopaque = null;
    var item: c.SecKeychainItemRef = null;
    const status = c.SecKeychainFindGenericPassword(
        null,
        @as(c.UInt32, @intCast(SERVICE_NAME.len)),
        @as([*c]const u8, @ptrCast(SERVICE_NAME.ptr)),
        @as(c.UInt32, @intCast(ACCOUNT_NAME.len)),
        @as([*c]const u8, @ptrCast(ACCOUNT_NAME.ptr)),
        &password_len,
        @ptrCast(&password_data),
        &item,
    );
    defer {
        if (password_data != null) _ = c.SecKeychainItemFreeContent(null, password_data);
    }
    defer if (item != null) c.CFRelease(item);

    if (status != c.errSecSuccess) {
        if (status != c.errSecItemNotFound) {
            log.warn("SecKeychainFindGenericPassword failed with OSStatus {d}", .{status});
        }
        return error.NotAuthenticated;
    }

    const bytes: [*]const u8 = @ptrCast(password_data.?);
    return try allocator.dupe(u8, bytes[0..@as(usize, @intCast(password_len))]);
}

// File fallback for non-macOS (Linux CI etc)
fn fileFallbackStore(allocator: std.mem.Allocator, data: []const u8) !void {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "auth.json" });
    defer allocator.free(path);
    std.fs.makeDirAbsolute(base) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.Writer.init(file, &buf);
    defer writer.interface.flush() catch {};
    try writer.interface.writeAll(data);
}

fn fileFallbackLoad(allocator: std.mem.Allocator) ![]const u8 {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "auth.json" });
    defer allocator.free(path);
    const file = std.fs.openFileAbsolute(path, .{}) catch return error.NotAuthenticated;
    defer file.close();
    var buf: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.read(buf[total..]) catch return error.NotAuthenticated;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return error.NotAuthenticated;
    return try allocator.dupe(u8, buf[0..total]);
}
