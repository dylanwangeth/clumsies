const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");
const prompt = @import("prompt.zig");

pub const MemoryKind = enum {
    pin,
    entry_file,
    prompt,
};

pub const MemoryPriority = enum(u8) {
    highest,
    high,
    normal,
};

pub const MemoryItem = struct {
    id: []const u8,
    kind: MemoryKind,
    path: []const u8,
    name: []const u8,
    group: ?[]const u8,
    hash: []const u8,
    priority: MemoryPriority,
};

pub const DiscoverOptions = struct {
    entry_files_override: ?[]const []const u8 = null,
    include_prompts: bool = true,
};

pub fn deinitMemoryItems(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(MemoryItem)) void {
    for (items.items) |item| {
        allocator.free(item.id);
        allocator.free(item.path);
        allocator.free(item.name);
        if (item.group) |group| allocator.free(group);
        allocator.free(item.hash);
    }
    items.deinit(allocator);
}

pub fn discoverWorkspaceMemory(allocator: std.mem.Allocator, workspace_root: []const u8, options: DiscoverOptions) !std.ArrayListUnmanaged(MemoryItem) {
    var items: std.ArrayListUnmanaged(MemoryItem) = .empty;
    errdefer deinitMemoryItems(allocator, &items);

    var seen_named_paths = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = seen_named_paths.keyIterator();
        while (key_iter.next()) |key| allocator.free(@constCast(key.*));
        seen_named_paths.deinit();
    }

    try maybeAppendNamedFile(allocator, workspace_root, "PIN.md", .pin, .highest, &seen_named_paths, &items);

    if (options.entry_files_override) |entry_files| {
        for (entry_files) |entry_file| {
            try maybeAppendNamedFile(allocator, workspace_root, entry_file, .entry_file, .high, &seen_named_paths, &items);
        }
    } else {
        const raw_entry_files = try config.getEntryFilesStr(allocator);
        defer if (raw_entry_files) |raw| allocator.free(raw);

        var entry_files = try config.parseEntryFiles(allocator, raw_entry_files);
        defer config.freeOwnedStrings(allocator, &entry_files);

        for (entry_files.items) |entry_file| {
            try maybeAppendNamedFile(allocator, workspace_root, entry_file, .entry_file, .high, &seen_named_paths, &items);
        }
    }

    if (options.include_prompts) {
        try appendPromptMemory(allocator, workspace_root, &items);
    }

    std.mem.sort(MemoryItem, items.items, {}, lessThanMemoryItem);
    return items;
}

pub fn discoverStartupMemory(allocator: std.mem.Allocator, workspace_root: []const u8, entry_files_override: ?[]const []const u8) !std.ArrayListUnmanaged(MemoryItem) {
    return discoverWorkspaceMemory(allocator, workspace_root, .{
        .entry_files_override = entry_files_override,
        .include_prompts = false,
    });
}

fn maybeAppendNamedFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    rel_path: []const u8,
    kind: MemoryKind,
    priority: MemoryPriority,
    seen_named_paths: *std.StringHashMap(void),
    items: *std.ArrayListUnmanaged(MemoryItem),
) !void {
    if (seen_named_paths.contains(rel_path)) return;

    const abs_path = try std.fs.path.join(allocator, &.{ workspace_root, rel_path });
    defer allocator.free(abs_path);

    const file = std.fs.openFileAbsolute(abs_path, .{}) catch return;
    file.close();

    const seen_key = try allocator.dupe(u8, rel_path);
    errdefer allocator.free(seen_key);
    try seen_named_paths.put(seen_key, {});

    const name = prompt.displayNameFromFilename(std.fs.path.basename(rel_path));
    const id_prefix = switch (kind) {
        .pin => "pin",
        .entry_file => "entry",
        .prompt => "prompt",
    };

    try items.append(allocator, .{
        .id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ id_prefix, rel_path }),
        .kind = kind,
        .path = try allocator.dupe(u8, rel_path),
        .name = try allocator.dupe(u8, name),
        .group = null,
        .hash = try prompt.readFileHashHexAlloc(allocator, abs_path),
        .priority = priority,
    });
}

fn appendPromptMemory(allocator: std.mem.Allocator, workspace_root: []const u8, items: *std.ArrayListUnmanaged(MemoryItem)) !void {
    const prompts_root = try std.fs.path.join(allocator, &.{ workspace_root, ".prompts" });
    defer allocator.free(prompts_root);

    var prompts_dir = std.fs.openDirAbsolute(prompts_root, .{ .iterate = true }) catch return;
    defer prompts_dir.close();

    var walker = try prompts_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.path, ".git") or std.mem.startsWith(u8, entry.path, ".git/")) continue;

        const abs_path = try std.fs.path.join(allocator, &.{ prompts_root, entry.path });
        defer allocator.free(abs_path);

        const rel_path = try std.fmt.allocPrint(allocator, ".prompts/{s}", .{entry.path});
        errdefer allocator.free(rel_path);

        const id = try std.fmt.allocPrint(allocator, "prompt:{s}", .{entry.path});
        errdefer allocator.free(id);

        const group = if (std.fs.path.dirname(entry.path)) |dir_name|
            try allocator.dupe(u8, dir_name)
        else
            null;
        errdefer if (group) |owned_group| allocator.free(owned_group);

        try items.append(allocator, .{
            .id = id,
            .kind = .prompt,
            .path = rel_path,
            .name = try allocator.dupe(u8, prompt.displayNameFromFilename(std.fs.path.basename(entry.path))),
            .group = group,
            .hash = try prompt.readFileHashHexAlloc(allocator, abs_path),
            .priority = .normal,
        });
    }
}

fn lessThanMemoryItem(_: void, a: MemoryItem, b: MemoryItem) bool {
    const prio_order = std.math.order(@intFromEnum(a.priority), @intFromEnum(b.priority));
    if (prio_order != .eq) return prio_order == .lt;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn writeFile(dir: std.fs.Dir, sub_path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(sub_path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn tmpDirAbsolutePath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    return tmp.dir.realpath(".", buf) catch "";
}

test "discoverWorkspaceMemory: finds pin entry file and prompts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule/coding");
    try writeFile(tmp.dir, "PIN.md", "pin memory");
    try writeFile(tmp.dir, "AGENTS.md", "entry memory");
    try writeFile(tmp.dir, ".prompts/rule/coding/03_PR_WORKFLOW.md", "workflow memory");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var items = try discoverWorkspaceMemory(testing.allocator, root, .{
        .entry_files_override = &.{"AGENTS.md"},
    });
    defer deinitMemoryItems(testing.allocator, &items);

    try testing.expectEqual(@as(usize, 3), items.items.len);
    try testing.expectEqualStrings("PIN.md", items.items[0].path);
    try testing.expectEqualStrings("AGENTS.md", items.items[1].path);
    try testing.expectEqualStrings(".prompts/rule/coding/03_PR_WORKFLOW.md", items.items[2].path);
    try testing.expectEqualStrings("prompt:rule/coding/03_PR_WORKFLOW.md", items.items[2].id);
    try testing.expectEqualStrings("rule/coding", items.items[2].group.?);
    try testing.expectEqualStrings("PR_WORKFLOW", items.items[2].name);
    try testing.expectEqual(@as(usize, 64), items.items[2].hash.len);
}

test "discoverStartupMemory: excludes prompt files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule");
    try writeFile(tmp.dir, "PIN.md", "pin memory");
    try writeFile(tmp.dir, "AGENTS.md", "entry memory");
    try writeFile(tmp.dir, ".prompts/rule/01_NOTE.md", "prompt memory");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var items = try discoverStartupMemory(testing.allocator, root, &.{"AGENTS.md"});
    defer deinitMemoryItems(testing.allocator, &items);

    try testing.expectEqual(@as(usize, 2), items.items.len);
    try testing.expectEqual(MemoryKind.pin, items.items[0].kind);
    try testing.expectEqual(MemoryKind.entry_file, items.items[1].kind);
}
