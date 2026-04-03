const std = @import("std");
const fs = std.fs;
const testing = std.testing;

pub const DEFAULT_META_PROMPT_FILES = [_][]const u8{ "CLAUDE.md", "CURSOR.md", "AGENTS.md", "COPILOT.md" };

/// Registry URL with optional branch parsed from "url#branch".
pub const RegistryInfo = struct {
    url: []const u8,
    branch: ?[]const u8,

    pub fn deinit(self: RegistryInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.branch) |b| allocator.free(b);
    }
};

pub fn getBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.NoHome;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".clumsies" });
}

pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "config.json" });
}

pub fn readConfig(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const file = fs.openFileAbsolute(config_path, .{}) catch return error.NoConfig;
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = try fr.interface.allocRemaining(allocator, std.io.Limit.limited(10 * 1024));
    defer allocator.free(content);

    return std.json.parseFromSlice(std.json.Value, allocator, content, .{});
}

pub fn getRegistry(allocator: std.mem.Allocator) ![]const u8 {
    const parsed = try readConfig(allocator);
    defer parsed.deinit();

    if (parsed.value.object.get("registry")) |value| {
        return switch (value) {
            .string => |s| try allocator.dupe(u8, s),
            else => error.NoRegistry,
        };
    }
    return error.NoRegistry;
}

pub fn parseRegistryUrl(allocator: std.mem.Allocator, raw: []const u8) !RegistryInfo {
    if (std.mem.lastIndexOfScalar(u8, raw, '#')) |idx| {
        const url = try allocator.dupe(u8, raw[0..idx]);
        const branch = try allocator.dupe(u8, raw[idx + 1 ..]);
        return .{ .url = url, .branch = branch };
    }

    return .{
        .url = try allocator.dupe(u8, raw),
        .branch = null,
    };
}

pub fn getRegistryInfo(allocator: std.mem.Allocator) !RegistryInfo {
    const raw = try getRegistry(allocator);
    defer allocator.free(raw);
    return parseRegistryUrl(allocator, raw);
}

pub fn getMetaPromptFilesStr(allocator: std.mem.Allocator) !?[]const u8 {
    const parsed = readConfig(allocator) catch return null;
    defer parsed.deinit();

    if (parsed.value.object.get("meta_prompt_files")) |value| {
        return switch (value) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
    }

    if (parsed.value.object.get("entry_files")) |value| {
        return switch (value) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
    }

    return null;
}

pub fn getMetaPromptFile(allocator: std.mem.Allocator) !?[]const u8 {
    const parsed = readConfig(allocator) catch return null;
    defer parsed.deinit();

    if (parsed.value.object.get("meta_prompt_file")) |value| {
        return switch (value) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
    }
    return null;
}

pub fn freeOwnedStrings(allocator: std.mem.Allocator, items: *std.ArrayList([]const u8)) void {
    for (items.items) |item| allocator.free(item);
    items.deinit(allocator);
}

pub fn parseMetaPromptFiles(allocator: std.mem.Allocator, raw: ?[]const u8) !std.ArrayList([]const u8) {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedStrings(allocator, &files);

    if (raw) |configured| {
        var iter = std.mem.splitScalar(u8, configured, ',');
        while (iter.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len == 0) continue;
            try files.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    if (files.items.len == 0) {
        for (DEFAULT_META_PROMPT_FILES) |mpf| {
            try files.append(allocator, try allocator.dupe(u8, mpf));
        }
    }

    return files;
}

test "parseRegistryUrl: https without branch" {
    const info = try parseRegistryUrl(testing.allocator, "https://github.com/foo/bar.git");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("https://github.com/foo/bar.git", info.url);
    try testing.expect(info.branch == null);
}

test "parseRegistryUrl: https with branch" {
    const info = try parseRegistryUrl(testing.allocator, "https://github.com/foo/bar.git#main");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("https://github.com/foo/bar.git", info.url);
    try testing.expectEqualStrings("main", info.branch.?);
}

test "parseRegistryUrl: ssh with branch" {
    const info = try parseRegistryUrl(testing.allocator, "git@github.com:foo/bar.git#develop");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("git@github.com:foo/bar.git", info.url);
    try testing.expectEqualStrings("develop", info.branch.?);
}

test "parseRegistryUrl: hash at end gives empty branch" {
    const info = try parseRegistryUrl(testing.allocator, "https://github.com/foo/bar#");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("https://github.com/foo/bar", info.url);
    try testing.expectEqualStrings("", info.branch.?);
}

test "parseRegistryUrl: multiple hashes uses last one" {
    const info = try parseRegistryUrl(testing.allocator, "url#first#second");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("url#first", info.url);
    try testing.expectEqualStrings("second", info.branch.?);
}

test "parseRegistryUrl: no hash no branch" {
    const info = try parseRegistryUrl(testing.allocator, "git@github.com:foo/bar.git");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("git@github.com:foo/bar.git", info.url);
    try testing.expect(info.branch == null);
}

test "parseMetaPromptFiles: uses defaults when unset" {
    var files = try parseMetaPromptFiles(testing.allocator, null);
    defer freeOwnedStrings(testing.allocator, &files);
    try testing.expectEqual(@as(usize, DEFAULT_META_PROMPT_FILES.len), files.items.len);
    try testing.expectEqualStrings("CLAUDE.md", files.items[0]);
}

test "parseMetaPromptFiles: trims configured list" {
    var files = try parseMetaPromptFiles(testing.allocator, "AGENTS.md, CUSTOM.md , ,PIN.md");
    defer freeOwnedStrings(testing.allocator, &files);
    try testing.expectEqual(@as(usize, 3), files.items.len);
    try testing.expectEqualStrings("AGENTS.md", files.items[0]);
    try testing.expectEqualStrings("CUSTOM.md", files.items[1]);
    try testing.expectEqualStrings("PIN.md", files.items[2]);
}
