//! Local persisted workspace content helpers for the TUI and sync-facing paths.
//! These helpers treat `{ws}/cache/` as the durable local copy and keep the
//! existing on-disk layout intact: rules under `cache/rule/`, context under
//! `cache/context/`, and reserved meta-prompt content at the cache root.

const std = @import("std");
const drafts = @import("drafts.zig");
const manifest_protocol = @import("clumsies_lib").protocol.manifest;
const path_util = @import("clumsies_lib").util.path_util;
const util_hash = @import("clumsies_lib").util.hash;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;
const workspace_rule = @import("rule.zig");

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

pub fn writeManifestRuleEntry(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    ws_id: []const u8,
    ws_name: []const u8,
    rule_id: []const u8,
    path: []const u8,
    hash: []const u8,
) !void {
    try writeManifestEntry(allocator, ws_dir, ws_id, ws_name, .rule, rule_id, path, hash);
}

pub fn writeManifestContextEntry(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    ws_id: []const u8,
    ws_name: []const u8,
    context_id: []const u8,
    path: []const u8,
    hash: []const u8,
) !void {
    try writeManifestEntry(allocator, ws_dir, ws_id, ws_name, .context, context_id, path, hash);
}

pub fn removeManifestRuleEntry(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    ws_id: []const u8,
    ws_name: []const u8,
    rule_id: []const u8,
    path: []const u8,
) !void {
    try removeManifestEntry(allocator, ws_dir, ws_id, ws_name, .rule, rule_id, path);
}

pub fn removeManifestContextEntry(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    ws_id: []const u8,
    ws_name: []const u8,
    context_id: []const u8,
    path: []const u8,
) !void {
    try removeManifestEntry(allocator, ws_dir, ws_id, ws_name, .context, context_id, path);
}

fn writeManifestEntry(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    ws_id: []const u8,
    ws_name: []const u8,
    category: drafts.DraftCategory,
    item_id: []const u8,
    path: []const u8,
    hash: []const u8,
) !void {
    if (!path_util.isSafeRelative(path)) return error.UnsafeManifestPath;

    var manifest = try workspace_rule.loadManifest(allocator, ws_dir);
    defer manifest.deinit(allocator);

    const extra_rule: usize = if (category == .rule and !manifest.rules.contains(item_id)) 1 else 0;
    const extra_context: usize = if (category == .context and !manifest.context.contains(item_id)) 1 else 0;
    const rule_items = try allocator.alloc(manifest_protocol.ManifestItem, manifest.rules.count() + extra_rule);
    defer allocator.free(rule_items);
    const context_items = try allocator.alloc(manifest_protocol.ManifestItem, manifest.context.count() + extra_context);
    defer allocator.free(context_items);

    var old_path_to_delete: ?[]const u8 = null;
    var rule_i: usize = 0;
    var rule_it = manifest.rules.iterator();
    while (rule_it.next()) |entry| {
        const is_selected = category == .rule and std.mem.eql(u8, entry.key_ptr.*, item_id);
        if (is_selected and !std.mem.eql(u8, entry.value_ptr.path, path)) {
            old_path_to_delete = entry.value_ptr.path;
        }
        rule_items[rule_i] = .{
            .key = if (is_selected) item_id else entry.key_ptr.*,
            .value = .{
                .path = if (is_selected) path else entry.value_ptr.path,
                .hash = if (is_selected) hash else entry.value_ptr.hash,
                .description = entry.value_ptr.description,
            },
        };
        rule_i += 1;
    }
    if (extra_rule == 1) {
        rule_items[rule_i] = .{
            .key = item_id,
            .value = .{ .path = path, .hash = hash },
        };
        rule_i += 1;
    }

    var context_i: usize = 0;
    var context_it = manifest.context.iterator();
    while (context_it.next()) |entry| {
        const is_selected = category == .context and std.mem.eql(u8, entry.key_ptr.*, item_id);
        if (is_selected and !std.mem.eql(u8, entry.value_ptr.path, path)) {
            old_path_to_delete = entry.value_ptr.path;
        }
        context_items[context_i] = .{
            .key = if (is_selected) item_id else entry.key_ptr.*,
            .value = .{
                .path = if (is_selected) path else entry.value_ptr.path,
                .hash = if (is_selected) hash else entry.value_ptr.hash,
                .description = entry.value_ptr.description,
            },
        };
        context_i += 1;
    }
    if (extra_context == 1) {
        context_items[context_i] = .{
            .key = item_id,
            .value = .{ .path = path, .hash = hash },
        };
        context_i += 1;
    }

    const body = try std.json.Stringify.valueAlloc(allocator, workspace_api.WorkspaceManifestResponse{
        .ws_id = ws_id,
        .name = ws_name,
        .revision = 0,
        .rules = .{ .items = rule_items[0..rule_i] },
        .context = .{ .items = context_items[0..context_i] },
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(body);

    const manifest_path = try std.fs.path.join(allocator, &.{ ws_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const file = try std.fs.createFileAbsolute(manifest_path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    var write_buf: [8192]u8 = undefined;
    var writer = std.fs.File.Writer.init(file, &write_buf);
    try writer.interface.writeAll(body);
    try writer.interface.flush();

    if (old_path_to_delete) |old_path| {
        try deleteCacheFile(allocator, ws_dir, category, old_path);
    }
}

fn removeManifestEntry(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    ws_id: []const u8,
    ws_name: []const u8,
    category: drafts.DraftCategory,
    item_id: []const u8,
    path: []const u8,
) !void {
    if (!path_util.isSafeRelative(path)) return error.UnsafeManifestPath;

    var manifest = try workspace_rule.loadManifest(allocator, ws_dir);
    defer manifest.deinit(allocator);

    const rule_items = try allocator.alloc(manifest_protocol.ManifestItem, manifest.rules.count());
    defer allocator.free(rule_items);
    const context_items = try allocator.alloc(manifest_protocol.ManifestItem, manifest.context.count());
    defer allocator.free(context_items);

    var rule_i: usize = 0;
    var rule_it = manifest.rules.iterator();
    while (rule_it.next()) |entry| {
        if (category == .rule and std.mem.eql(u8, entry.key_ptr.*, item_id)) continue;
        rule_items[rule_i] = .{
            .key = entry.key_ptr.*,
            .value = .{
                .path = entry.value_ptr.path,
                .hash = entry.value_ptr.hash,
                .description = entry.value_ptr.description,
            },
        };
        rule_i += 1;
    }

    var context_i: usize = 0;
    var context_it = manifest.context.iterator();
    while (context_it.next()) |entry| {
        if (category == .context and std.mem.eql(u8, entry.key_ptr.*, item_id)) continue;
        context_items[context_i] = .{
            .key = entry.key_ptr.*,
            .value = .{
                .path = entry.value_ptr.path,
                .hash = entry.value_ptr.hash,
                .description = entry.value_ptr.description,
            },
        };
        context_i += 1;
    }

    const body = try std.json.Stringify.valueAlloc(allocator, workspace_api.WorkspaceManifestResponse{
        .ws_id = ws_id,
        .name = ws_name,
        .revision = 0,
        .rules = .{ .items = rule_items[0..rule_i] },
        .context = .{ .items = context_items[0..context_i] },
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(body);

    const manifest_path = try std.fs.path.join(allocator, &.{ ws_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const file = try std.fs.createFileAbsolute(manifest_path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    var write_buf: [8192]u8 = undefined;
    var writer = std.fs.File.Writer.init(file, &write_buf);
    try writer.interface.writeAll(body);
    try writer.interface.flush();

    try deleteCacheFile(allocator, ws_dir, category, path);
}

fn deleteCacheFile(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: drafts.DraftCategory,
    path: []const u8,
) !void {
    const abs_path = switch (category) {
        .rule => try std.fs.path.join(allocator, &.{ ws_dir, "cache", "rule", path }),
        .context => try std.fs.path.join(allocator, &.{ ws_dir, "cache", "context", path }),
        .meta_prompt => return,
    };
    defer allocator.free(abs_path);
    std.fs.deleteFileAbsolute(abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
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

test "writeManifestContextEntry updates only the selected context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try writeTestFile(tmp.dir, "manifest.json",
        \\{
        \\  "ws_id": "ws-1",
        \\  "name": "demo",
        \\  "revision": 7,
        \\  "rules": {
        \\    "p-1": {"path": "coding/STYLE.md", "hash": "sha256:old-rule"}
        \\  },
        \\  "context": {
        \\    "ctx-1": {"path": "spec/API.md", "hash": "sha256:old-context"},
        \\    "ctx-2": {"path": "spec/OTHER.md", "hash": "sha256:keep-context"}
        \\  }
        \\}
    );

    try writeManifestContextEntry(std.testing.allocator, root, "ws-1", "demo", "ctx-1", "spec/API.md", "sha256:new-context");

    var manifest = try workspace_rule.loadManifest(std.testing.allocator, root);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), manifest.rules.count());
    try std.testing.expectEqual(@as(usize, 2), manifest.context.count());
    try std.testing.expectEqualStrings("sha256:old-rule", manifest.rules.get("p-1").?.hash);
    try std.testing.expectEqualStrings("sha256:new-context", manifest.context.get("ctx-1").?.hash);
    try std.testing.expectEqualStrings("sha256:keep-context", manifest.context.get("ctx-2").?.hash);
}

test "writeManifestRuleEntry adds only the selected rule when manifest is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try writeManifestRuleEntry(std.testing.allocator, root, "ws-1", "demo", "p-1", "coding/STYLE.md", "sha256:new-rule");

    var manifest = try workspace_rule.loadManifest(std.testing.allocator, root);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), manifest.rules.count());
    try std.testing.expectEqual(@as(usize, 0), manifest.context.count());
    try std.testing.expectEqualStrings("coding/STYLE.md", manifest.rules.get("p-1").?.path);
    try std.testing.expectEqualStrings("sha256:new-rule", manifest.rules.get("p-1").?.hash);
}

test "removeManifestRuleEntry removes selected rule and cache file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try write(std.testing.allocator, root, .rule, "coding/STYLE.md", "hello");
    try writeManifestRuleEntry(std.testing.allocator, root, "ws-1", "demo", "p-1", "coding/STYLE.md", "sha256:old");
    try removeManifestRuleEntry(std.testing.allocator, root, "ws-1", "demo", "p-1", "coding/STYLE.md");

    var manifest = try workspace_rule.loadManifest(std.testing.allocator, root);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expect(!manifest.rules.contains("p-1"));
    try std.testing.expectError(error.FileNotFound, read(std.testing.allocator, root, .rule, "coding/STYLE.md"));
}
