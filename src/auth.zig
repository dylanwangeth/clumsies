const std = @import("std");
const build_options = @import("build_options");
const enable_keychain = build_options.enable_keychain;
const log = std.log.scoped(.auth);

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
