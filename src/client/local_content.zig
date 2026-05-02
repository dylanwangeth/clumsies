//! Local persisted workspace content helpers for the TUI and sync-facing paths.
//! These helpers treat `{ws}/cache/` as the durable local copy and keep the
//! existing on-disk layout intact: rules under `cache/rule/`, context under
//! `cache/context/`, and reserved meta-prompt content at the cache root.

const std = @import("std");
const drafts = @import("drafts.zig");
const path_util = @import("clumsies_lib").util.path_util;
const util_hash = @import("clumsies_lib").util.hash;

pub const Freshness = enum {
    fresh,
    stale,
};

pub fn freshness(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: drafts.DraftCategory,
    rel_path: []const u8,
    remote_hash: []const u8,
) Freshness {
    if (normalizedHash(remote_hash).len == 0) return .stale;
    const body = read(allocator, ws_dir, category, rel_path) catch return .stale;
    defer allocator.free(body);
    const local_hash = util_hash.contentHash(body);
    return if (hashesEqual(&local_hash, remote_hash)) .fresh else .stale;
}

pub fn hashesEqual(local_hash: []const u8, remote_hash: []const u8) bool {
    const local = normalizedHash(local_hash);
    const remote = normalizedHash(remote_hash);
    return local.len > 0 and remote.len > 0 and std.ascii.eqlIgnoreCase(local, remote);
}

pub fn read(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: drafts.DraftCategory,
    rel_path: []const u8,
) ![]const u8 {
    if (!path_util.isSafeRelative(rel_path)) return error.UnsafeCachePath;
    const abs_path = switch (category) {
        .rule => try std.fs.path.join(allocator, &.{ ws_dir, "cache", "rule", rel_path }),
        .context => try std.fs.path.join(allocator, &.{ ws_dir, "cache", "context", rel_path }),
        .meta_prompt => try std.fs.path.join(allocator, &.{ ws_dir, "cache", rel_path }),
    };
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    return try fr.interface.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024));
}

pub fn write(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: drafts.DraftCategory,
    rel_path: []const u8,
    body: []const u8,
) !void {
    if (!path_util.isSafeRelative(rel_path)) return error.UnsafeCachePath;
    const abs_path = switch (category) {
        .rule => try std.fs.path.join(allocator, &.{ ws_dir, "cache", "rule", rel_path }),
        .context => try std.fs.path.join(allocator, &.{ ws_dir, "cache", "context", rel_path }),
        .meta_prompt => try std.fs.path.join(allocator, &.{ ws_dir, "cache", rel_path }),
    };
    defer allocator.free(abs_path);

    if (std.fs.path.dirname(abs_path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }
    const file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var writer = std.fs.File.Writer.init(file, &write_buf);
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}

fn normalizedHash(hash: []const u8) []const u8 {
    if (std.mem.startsWith(u8, hash, "sha256:")) return hash["sha256:".len..];
    if (std.mem.startsWith(u8, hash, "SHA256:")) return hash["SHA256:".len..];
    return hash;
}

fn writeTestFile(dir: std.fs.Dir, path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

test "hashesEqual accepts prefixed and bare hashes" {
    try std.testing.expect(hashesEqual(
        "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
    ));
}

test "freshness maps cache paths and detects fresh content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try tmp.dir.makePath("cache/rule/coding");
    try tmp.dir.makePath("cache/context/spec");
    try tmp.dir.makePath("cache");
    try writeTestFile(tmp.dir, "cache/rule/coding/STYLE.md", "hello");
    try writeTestFile(tmp.dir, "cache/context/spec/API.md", "hello");
    try writeTestFile(tmp.dir, "cache/META_PROMPT.md", "hello");

    const remote = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    try std.testing.expectEqual(Freshness.fresh, freshness(std.testing.allocator, root, .rule, "coding/STYLE.md", remote));
    try std.testing.expectEqual(Freshness.fresh, freshness(std.testing.allocator, root, .context, "spec/API.md", remote));
    try std.testing.expectEqual(Freshness.fresh, freshness(std.testing.allocator, root, .meta_prompt, "META_PROMPT.md", remote));
}

test "freshness treats missing or mismatched local content as stale" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try tmp.dir.makePath("cache/rule/coding");
    try writeTestFile(tmp.dir, "cache/rule/coding/STYLE.md", "different");

    const remote = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    try std.testing.expectEqual(Freshness.stale, freshness(std.testing.allocator, root, .rule, "coding/STYLE.md", remote));
    try std.testing.expectEqual(Freshness.stale, freshness(std.testing.allocator, root, .context, "missing.md", remote));
}

test "write creates nested cache path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try write(std.testing.allocator, root, .context, "spec/API.md", "hello");
    const body = try read(std.testing.allocator, root, .context, "spec/API.md");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
}
