//! Authentication credential storage. Persists Server URL, username, and tokens
//! to the configured local credential store. Shared by CLI login, MCP startup,
//! and TUI init.
const std = @import("std");
const build_options = @import("build_options");
const env_util = @import("clumsies_lib").util.env_util;
const enable_keychain = build_options.enable_keychain;
const log = std.log.scoped(.auth);

pub const AuthInfo = struct {
    server_url: []const u8,
    username: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,

    pub fn deinit(self: AuthInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.server_url);
        allocator.free(self.username);
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
    }
};

pub const SaveLocation = enum {
    keychain,
    file_default,
    file_fallback,
    memory,
};

pub const AuthStore = enum {
    file,
    keychain,
    auto,
    memory,
};

const SERVICE_NAME = "clumsies";
const ACCOUNT_NAME = "server-auth";
const STORE_ENV = "CLUMSIES_AUTH_STORE";

pub fn getBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = env_util.homeDir(allocator) catch return error.HomeNotSet;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".clumsies" });
}

pub fn saveAuth(allocator: std.mem.Allocator, server_url: []const u8, username: []const u8, access_token: []const u8, refresh_token: []const u8) !SaveLocation {
    const payload = AuthJson{
        .server_url = server_url,
        .username = username,
        .access_token = access_token,
        .refresh_token = refresh_token,
    };
    const json = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return error.SerializationFailed;
    defer allocator.free(json);

    switch (try currentStore(allocator)) {
        .file => {
            try fileFallbackStore(allocator, json);
            return .file_default;
        },
        .keychain => {
            if (comptime !enable_keychain) return error.KeychainUnavailable;
            try keychainStore(json);
            return .keychain;
        },
        .auto => {
            if (comptime enable_keychain) {
                keychainStore(json) catch |err| {
                    log.warn("keychain store failed ({s}); falling back to auth.json", .{@errorName(err)});
                    try fileFallbackStore(allocator, json);
                    return .file_fallback;
                };
                return .keychain;
            }
            try fileFallbackStore(allocator, json);
            return .file_default;
        },
        .memory => return .memory,
    }
}

/// `ServerClient.PersistFn`-shaped callback. Saves the rotated token
/// pair after ServerClient has refreshed in response to a 401. Thin
/// wrapper around `saveAuth` so the ServerClient module doesn't have
/// to import the keychain plumbing directly.
pub fn persistRotatedTokens(
    allocator: std.mem.Allocator,
    server_url: []const u8,
    username: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
) anyerror!void {
    _ = try saveAuth(allocator, server_url, username, access_token, refresh_token);
}

pub fn loadAuth(allocator: std.mem.Allocator) !AuthInfo {
    const json = switch (try currentStore(allocator)) {
        .file => fileFallbackLoad(allocator) catch return error.NotAuthenticated,
        .keychain => blk: {
            if (comptime !enable_keychain) return error.NotAuthenticated;
            break :blk keychainLookup(allocator) catch return error.NotAuthenticated;
        },
        .auto => blk: {
            if (comptime enable_keychain) {
                break :blk keychainLookup(allocator) catch |err| inner: {
                    if (err != error.NotAuthenticated) {
                        log.warn("keychain lookup failed ({s}); trying auth.json", .{@errorName(err)});
                    }
                    break :inner fileFallbackLoad(allocator) catch return error.NotAuthenticated;
                };
            }
            break :blk fileFallbackLoad(allocator) catch return error.NotAuthenticated;
        },
        .memory => return error.NotAuthenticated,
    };
    defer allocator.free(json);

    const parsed = std.json.parseFromSlice(AuthJson, allocator, json, .{ .allocate = .alloc_always }) catch return error.NotAuthenticated;
    defer parsed.deinit();

    return .{
        .server_url = try allocator.dupe(u8, parsed.value.server_url),
        .username = try allocator.dupe(u8, parsed.value.username),
        .access_token = try allocator.dupe(u8, parsed.value.access_token),
        .refresh_token = try allocator.dupe(u8, parsed.value.refresh_token),
    };
}

pub fn clearAuth(allocator: std.mem.Allocator) !void {
    switch (try currentStore(allocator)) {
        .file => try fileFallbackDelete(allocator),
        .keychain => {
            if (comptime !enable_keychain) return error.KeychainUnavailable;
            try keychainDelete();
        },
        .auto => {
            if (comptime enable_keychain) keychainDelete() catch |err| {
                if (err != error.NotAuthenticated) {
                    log.warn("keychain delete failed ({s}); deleting auth.json", .{@errorName(err)});
                }
            };
            try fileFallbackDelete(allocator);
        },
        .memory => {},
    }
}

const AuthJson = struct {
    server_url: []const u8,
    username: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
};

pub fn currentStore(allocator: std.mem.Allocator) !AuthStore {
    const raw = env_util.getOwned(allocator, STORE_ENV) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return .file,
        else => return err,
    };
    defer allocator.free(raw);
    return parseStore(raw) orelse {
        log.warn("invalid {s}={s}; using file auth store", .{ STORE_ENV, raw });
        return .file;
    };
}

pub fn parseStore(raw: []const u8) ?AuthStore {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "file")) return .file;
    if (std.ascii.eqlIgnoreCase(trimmed, "keychain")) return .keychain;
    if (std.ascii.eqlIgnoreCase(trimmed, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(trimmed, "memory")) return .memory;
    return null;
}

const c = if (enable_keychain) struct {
    pub const OSStatus = i32;
    pub const UInt32 = u32;
    pub const SecKeychainRef = ?*anyopaque;
    pub const SecKeychainItemRef = ?*anyopaque;

    pub const errSecSuccess: OSStatus = 0;
    pub const errSecItemNotFound: OSStatus = -25300;

    extern "c" fn SecKeychainFindGenericPassword(
        keychainOrArray: ?*anyopaque,
        serviceNameLength: UInt32,
        serviceName: [*c]const u8,
        accountNameLength: UInt32,
        accountName: [*c]const u8,
        passwordLength: ?*UInt32,
        passwordData: ?*?*anyopaque,
        itemRef: ?*SecKeychainItemRef,
    ) OSStatus;

    extern "c" fn SecKeychainAddGenericPassword(
        keychain: SecKeychainRef,
        serviceNameLength: UInt32,
        serviceName: [*c]const u8,
        accountNameLength: UInt32,
        accountName: [*c]const u8,
        passwordLength: UInt32,
        passwordData: ?*const anyopaque,
        itemRef: ?*SecKeychainItemRef,
    ) OSStatus;

    extern "c" fn SecKeychainItemModifyAttributesAndData(
        itemRef: SecKeychainItemRef,
        attrList: ?*const anyopaque,
        length: UInt32,
        data: ?*const anyopaque,
    ) OSStatus;

    extern "c" fn SecKeychainItemFreeContent(
        attrList: ?*anyopaque,
        data: ?*anyopaque,
    ) OSStatus;

    extern "c" fn SecKeychainItemDelete(itemRef: SecKeychainItemRef) OSStatus;
    extern "c" fn CFRelease(cf: ?*anyopaque) void;
} else struct {};

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

fn keychainDelete() !void {
    if (comptime !enable_keychain) return error.NotAuthenticated;

    var item: c.SecKeychainItemRef = null;
    const status = c.SecKeychainFindGenericPassword(
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

    if (status == c.errSecItemNotFound) return error.NotAuthenticated;
    if (status != c.errSecSuccess) {
        log.warn("SecKeychainFindGenericPassword for delete failed with OSStatus {d}", .{status});
        return error.KeychainError;
    }
    const delete_status = c.SecKeychainItemDelete(item);
    if (delete_status != c.errSecSuccess) {
        log.warn("SecKeychainItemDelete failed with OSStatus {d}", .{delete_status});
        return error.KeychainError;
    }
}

// File fallback for non-macOS (Linux CI etc)
fn fileFallbackStore(allocator: std.mem.Allocator, data: []const u8) !void {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "auth.json" });
    defer allocator.free(path);
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, base, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
    defer file.close(std.Options.debug_io);
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, std.Options.debug_io, &buf);
    defer writer.interface.flush() catch {};
    try writer.interface.writeAll(data);
}

fn fileFallbackLoad(allocator: std.mem.Allocator) ![]const u8 {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "auth.json" });
    defer allocator.free(path);
    const file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return error.NotAuthenticated;
    defer file.close(std.Options.debug_io);
    var buf: [64 * 1024]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, std.Options.debug_io, &read_buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = reader.interface.readSliceShort(buf[total..]) catch return error.NotAuthenticated;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return error.NotAuthenticated;
    return try allocator.dupe(u8, buf[0..total]);
}

fn fileFallbackDelete(allocator: std.mem.Allocator) !void {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "auth.json" });
    defer allocator.free(path);
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
