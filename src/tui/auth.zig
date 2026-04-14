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

const SERVICE_NAME = "clumsies";
const ACCOUNT_NAME = "hub-auth";

pub fn getBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.HomeNotSet;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".clumsies" });
}

pub fn saveAuth(allocator: std.mem.Allocator, hub_url: []const u8, username: []const u8, access_token: []const u8, refresh_token: []const u8) !void {
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
        };
    } else {
        try fileFallbackStore(allocator, json);
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

fn cfString(s: []const u8) ?*anyopaque {
    if (comptime !enable_keychain) return null;
    return @ptrCast(@constCast(c.CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), c.kCFStringEncodingUTF8, 0)));
}

fn keychainStore(data: []const u8) !void {
    const cf_service = cfString(SERVICE_NAME) orelse return error.KeychainError;
    defer c.CFRelease(cf_service);
    const cf_account = cfString(ACCOUNT_NAME) orelse return error.KeychainError;
    defer c.CFRelease(cf_account);
    const cf_data: c.CFDataRef = c.CFDataCreate(null, data.ptr, @intCast(data.len)) orelse return error.KeychainError;
    defer c.CFRelease(cf_data);

    // Delete existing
    var del_keys = [_]?*const anyopaque{ c.kSecClass, c.kSecAttrService, c.kSecAttrAccount };
    var del_vals = [_]?*const anyopaque{ c.kSecClassGenericPassword, cf_service, cf_account };
    const del_dict = c.CFDictionaryCreate(null, @ptrCast(&del_keys), @ptrCast(&del_vals), del_keys.len, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks);
    if (del_dict) |d| {
        _ = c.SecItemDelete(d);
        c.CFRelease(d);
    }

    // Add new
    var add_keys = [_]?*const anyopaque{ c.kSecClass, c.kSecAttrService, c.kSecAttrAccount, c.kSecValueData };
    var add_vals = [_]?*const anyopaque{ c.kSecClassGenericPassword, cf_service, cf_account, @ptrCast(@constCast(cf_data)) };
    const add_dict = c.CFDictionaryCreate(null, @ptrCast(&add_keys), @ptrCast(&add_vals), add_keys.len, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks) orelse return error.KeychainError;
    defer c.CFRelease(add_dict);

    const status = c.SecItemAdd(add_dict, null);
    if (status != c.errSecSuccess) return error.KeychainError;
}

fn keychainLookup(allocator: std.mem.Allocator) ![]const u8 {
    const cf_service = cfString(SERVICE_NAME) orelse return error.KeychainError;
    defer c.CFRelease(cf_service);
    const cf_account = cfString(ACCOUNT_NAME) orelse return error.KeychainError;
    defer c.CFRelease(cf_account);

    var keys = [_]?*const anyopaque{ c.kSecClass, c.kSecAttrService, c.kSecAttrAccount, c.kSecReturnData, c.kSecMatchLimit };
    var vals = [_]?*const anyopaque{ c.kSecClassGenericPassword, cf_service, cf_account, c.kCFBooleanTrue, c.kSecMatchLimitOne };
    const dict = c.CFDictionaryCreate(null, @ptrCast(&keys), @ptrCast(&vals), keys.len, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks) orelse return error.KeychainError;
    defer c.CFRelease(dict);

    var result: c.CFTypeRef = null;
    const status = c.SecItemCopyMatching(dict, &result);
    if (status != c.errSecSuccess) return error.NotAuthenticated;

    const cf_data: c.CFDataRef = @ptrCast(result.?);
    defer c.CFRelease(result.?);

    const len: usize = @intCast(c.CFDataGetLength(cf_data));
    const ptr = c.CFDataGetBytePtr(cf_data);
    return try allocator.dupe(u8, ptr[0..len]);
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
    var file_buffer: [4096]u8 = undefined;
    var file_writer = std.fs.File.Writer.init(file, &file_buffer);
    defer file_writer.interface.flush() catch {};
    try file_writer.interface.writeAll(data);
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
