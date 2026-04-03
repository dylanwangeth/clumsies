const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");
const prompt = @import("prompt.zig");
const usage_log = @import("usage_log.zig");

pub const MemoryKind = enum {
    pin,
    meta_prompt_file,
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
    meta_prompt_files_override: ?[]const []const u8 = null,
    include_prompts: bool = true,
};

pub const ListRequest = struct {
    include_prompts: bool = true,
    kind: ?MemoryKind = null,
    group: ?[]const u8 = null,
    query: ?[]const u8 = null,
};

pub const KnownMemory = struct {
    id: []const u8,
    hash: []const u8,
};

pub const ActivateRequest = struct {
    ids: []const []const u8,
    known: []const KnownMemory = &.{},
    task_id: ?[]const u8 = null,
    turn_id: ?[]const u8 = null,
};

pub const ActivatedMemory = struct {
    id: []const u8,
    kind: MemoryKind,
    path: []const u8,
    name: []const u8,
    group: ?[]const u8,
    hash: []const u8,
    priority: MemoryPriority,
    changed: bool,
    content: ?[]const u8,
};

pub const ActivationResult = struct {
    items: std.ArrayList(ActivatedMemory) = .empty,

    pub fn deinit(self: *ActivationResult, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| {
            allocator.free(item.id);
            allocator.free(item.path);
            allocator.free(item.name);
            if (item.group) |group| allocator.free(group);
            allocator.free(item.hash);
            if (item.content) |content| allocator.free(content);
        }
        self.items.deinit(allocator);
    }
};

pub fn deinitMemoryItems(allocator: std.mem.Allocator, items: *std.ArrayList(MemoryItem)) void {
    for (items.items) |item| {
        allocator.free(item.id);
        allocator.free(item.path);
        allocator.free(item.name);
        if (item.group) |group| allocator.free(group);
        allocator.free(item.hash);
    }
    items.deinit(allocator);
}

pub fn discoverWorkspaceMemory(allocator: std.mem.Allocator, workspace_root: []const u8, options: DiscoverOptions) !std.ArrayList(MemoryItem) {
    var items: std.ArrayList(MemoryItem) = .empty;
    errdefer deinitMemoryItems(allocator, &items);

    var seen_named_paths = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = seen_named_paths.keyIterator();
        while (key_iter.next()) |key| allocator.free(@constCast(key.*));
        seen_named_paths.deinit();
    }

    try maybeAppendNamedFile(allocator, workspace_root, "PIN.md", .pin, .highest, &seen_named_paths, &items);

    if (options.meta_prompt_files_override) |meta_prompt_files| {
        for (meta_prompt_files) |meta_prompt_file| {
            try maybeAppendNamedFile(allocator, workspace_root, meta_prompt_file, .meta_prompt_file, .high, &seen_named_paths, &items);
        }
    } else {
        const raw_meta_prompt_files = try config.getMetaPromptFilesStr(allocator);
        defer if (raw_meta_prompt_files) |raw| allocator.free(raw);

        var meta_prompt_files = try config.parseMetaPromptFiles(allocator, raw_meta_prompt_files);
        defer config.freeOwnedStrings(allocator, &meta_prompt_files);

        for (meta_prompt_files.items) |meta_prompt_file| {
            try maybeAppendNamedFile(allocator, workspace_root, meta_prompt_file, .meta_prompt_file, .high, &seen_named_paths, &items);
        }
    }

    if (options.include_prompts) {
        try appendPromptMemory(allocator, workspace_root, &items);
    }

    std.mem.sort(MemoryItem, items.items, {}, lessThanMemoryItem);
    return items;
}

pub fn discoverStartupMemory(allocator: std.mem.Allocator, workspace_root: []const u8, meta_prompt_files_override: ?[]const []const u8) !std.ArrayList(MemoryItem) {
    return discoverWorkspaceMemory(allocator, workspace_root, .{
        .meta_prompt_files_override = meta_prompt_files_override,
        .include_prompts = false,
    });
}

pub fn listMemory(allocator: std.mem.Allocator, workspace_root: []const u8, request: ListRequest) !std.ArrayList(MemoryItem) {
    var discovered = try discoverWorkspaceMemory(allocator, workspace_root, .{
        .include_prompts = request.include_prompts,
    });
    errdefer deinitMemoryItems(allocator, &discovered);

    if (request.kind == null and request.group == null and request.query == null) {
        return discovered;
    }

    var filtered: std.ArrayList(MemoryItem) = .empty;
    errdefer deinitMemoryItems(allocator, &filtered);

    for (discovered.items) |item| {
        if (!matchesListRequest(item, request)) continue;
        try filtered.append(allocator, item);
    }

    discovered.items.len = 0;
    deinitMemoryItems(allocator, &discovered);
    return filtered;
}

pub fn startupMemory(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    meta_prompt_files_override: ?[]const []const u8,
    known: []const KnownMemory,
) !ActivationResult {
    var items = try discoverStartupMemory(allocator, workspace_root, meta_prompt_files_override);
    defer deinitMemoryItems(allocator, &items);

    return try materializeAll(allocator, workspace_root, items.items, known);
}

pub fn activateMemory(allocator: std.mem.Allocator, workspace_root: []const u8, request: ActivateRequest) !ActivationResult {
    var inventory = try discoverWorkspaceMemory(allocator, workspace_root, .{});
    defer deinitMemoryItems(allocator, &inventory);

    var result = try materializeSelection(allocator, workspace_root, inventory.items, request.ids, request.known);
    errdefer result.deinit(allocator);

    var refs: std.ArrayList(usage_log.ActivationRef) = .empty;
    defer refs.deinit(allocator);
    try refs.ensureTotalCapacity(allocator, result.items.items.len);
    for (result.items.items) |item| {
        refs.appendAssumeCapacity(.{
            .id = item.id,
            .hash = item.hash,
        });
    }

    try usage_log.appendActivation(allocator, workspace_root, "activate", request.task_id, request.turn_id, refs.items);
    return result;
}

fn maybeAppendNamedFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    rel_path: []const u8,
    kind: MemoryKind,
    priority: MemoryPriority,
    seen_named_paths: *std.StringHashMap(void),
    items: *std.ArrayList(MemoryItem),
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
        .meta_prompt_file => "mpf",
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

fn appendPromptMemory(allocator: std.mem.Allocator, workspace_root: []const u8, items: *std.ArrayList(MemoryItem)) !void {
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

fn matchesListRequest(item: MemoryItem, request: ListRequest) bool {
    if (request.kind) |kind| {
        if (item.kind != kind) return false;
    }

    if (request.group) |group| {
        const item_group = item.group orelse return false;
        if (!matchesGroupFilter(item_group, group)) return false;
    }

    if (request.query) |query| {
        if (!(containsIgnoreCase(item.id, query) or
            containsIgnoreCase(item.path, query) or
            containsIgnoreCase(item.name, query) or
            (item.group != null and containsIgnoreCase(item.group.?, query))))
        {
            return false;
        }
    }

    return true;
}

fn matchesGroupFilter(item_group: []const u8, group: []const u8) bool {
    if (std.mem.eql(u8, item_group, group)) return true;
    if (!std.mem.startsWith(u8, item_group, group)) return false;
    return group.len < item_group.len and item_group[group.len] == '/';
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    const last_start = haystack.len - needle.len;
    var start: usize = 0;
    while (start <= last_start) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn materializeAll(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    items: []const MemoryItem,
    known: []const KnownMemory,
) !ActivationResult {
    var result: ActivationResult = .{};
    errdefer result.deinit(allocator);

    try result.items.ensureTotalCapacity(allocator, items.len);
    for (items) |item| {
        try result.items.append(allocator, try materializeItem(allocator, workspace_root, item, knownHashFor(item.id, known)));
    }
    return result;
}

fn materializeSelection(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    inventory: []const MemoryItem,
    ids: []const []const u8,
    known: []const KnownMemory,
) !ActivationResult {
    var result: ActivationResult = .{};
    errdefer result.deinit(allocator);

    var seen_ids = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = seen_ids.keyIterator();
        while (key_iter.next()) |key| allocator.free(@constCast(key.*));
        seen_ids.deinit();
    }

    for (ids) |id| {
        if (seen_ids.contains(id)) continue;

        const seen_key = try allocator.dupe(u8, id);
        errdefer allocator.free(seen_key);
        try seen_ids.put(seen_key, {});

        const item = findMemoryById(inventory, id) orelse return error.UnknownMemoryId;
        try result.items.append(allocator, try materializeItem(allocator, workspace_root, item, knownHashFor(id, known)));
    }

    return result;
}

fn materializeItem(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    item: MemoryItem,
    known_hash: ?[]const u8,
) !ActivatedMemory {
    const changed = known_hash == null or !std.mem.eql(u8, known_hash.?, item.hash);
    const content = if (changed)
        try readWorkspaceFileAlloc(allocator, workspace_root, item.path)
    else
        null;
    errdefer if (content) |owned| allocator.free(owned);

    return .{
        .id = try allocator.dupe(u8, item.id),
        .kind = item.kind,
        .path = try allocator.dupe(u8, item.path),
        .name = try allocator.dupe(u8, item.name),
        .group = if (item.group) |group| try allocator.dupe(u8, group) else null,
        .hash = try allocator.dupe(u8, item.hash),
        .priority = item.priority,
        .changed = changed,
        .content = content,
    };
}

fn readWorkspaceFileAlloc(allocator: std.mem.Allocator, workspace_root: []const u8, rel_path: []const u8) ![]const u8 {
    const abs_path = try std.fs.path.join(allocator, &.{ workspace_root, rel_path });
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    return try fr.interface.allocRemaining(allocator, std.io.Limit.limited(prompt.MAX_FILE_SIZE));
}

fn findMemoryById(inventory: []const MemoryItem, id: []const u8) ?MemoryItem {
    for (inventory) |item| {
        if (std.mem.eql(u8, item.id, id)) return item;
    }
    return null;
}

fn knownHashFor(id: []const u8, known: []const KnownMemory) ?[]const u8 {
    for (known) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry.hash;
    }
    return null;
}

fn writeFile(dir: std.fs.Dir, sub_path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(sub_path, .{});
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var fw = std.fs.File.Writer.init(file, &write_buf);
    defer fw.interface.flush() catch {};
    try fw.interface.writeAll(content);
}

fn tmpDirAbsolutePath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    return tmp.dir.realpath(".", buf) catch "";
}

test "discoverWorkspaceMemory: finds pin MPF and prompts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule/coding");
    try writeFile(tmp.dir, "PIN.md", "pin memory");
    try writeFile(tmp.dir, "AGENTS.md", "mpf memory");
    try writeFile(tmp.dir, ".prompts/rule/coding/03_PR_WORKFLOW.md", "workflow memory");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var items = try discoverWorkspaceMemory(testing.allocator, root, .{
        .meta_prompt_files_override = &.{"AGENTS.md"},
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
    try writeFile(tmp.dir, "AGENTS.md", "mpf memory");
    try writeFile(tmp.dir, ".prompts/rule/01_NOTE.md", "prompt memory");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var items = try discoverStartupMemory(testing.allocator, root, &.{"AGENTS.md"});
    defer deinitMemoryItems(testing.allocator, &items);

    try testing.expectEqual(@as(usize, 2), items.items.len);
    try testing.expectEqual(MemoryKind.pin, items.items[0].kind);
    try testing.expectEqual(MemoryKind.meta_prompt_file, items.items[1].kind);
}

test "listMemory: filters by kind group and query" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule/coding");
    try tmp.dir.makePath(".prompts/rule/writing");
    try writeFile(tmp.dir, "AGENTS.md", "mpf memory");
    try writeFile(tmp.dir, ".prompts/rule/coding/03_PR_WORKFLOW.md", "workflow memory");
    try writeFile(tmp.dir, ".prompts/rule/writing/01_BLOG.md", "blog memory");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var coding_items = try listMemory(testing.allocator, root, .{
        .group = "rule/coding",
    });
    defer deinitMemoryItems(testing.allocator, &coding_items);
    try testing.expectEqual(@as(usize, 1), coding_items.items.len);
    try testing.expectEqualStrings("prompt:rule/coding/03_PR_WORKFLOW.md", coding_items.items[0].id);

    var prompt_items = try listMemory(testing.allocator, root, .{
        .kind = .prompt,
        .query = "blog",
    });
    defer deinitMemoryItems(testing.allocator, &prompt_items);
    try testing.expectEqual(@as(usize, 1), prompt_items.items.len);
    try testing.expectEqualStrings("BLOG", prompt_items.items[0].name);
}

test "startupMemory: only changed items include content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "PIN.md", "pin memory");
    try writeFile(tmp.dir, "AGENTS.md", "mpf memory");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const pin_hash = try prompt.readFileHashHexAlloc(testing.allocator, try std.fs.path.join(testing.allocator, &.{ root, "PIN.md" }));
    defer testing.allocator.free(pin_hash);

    var result = try startupMemory(testing.allocator, root, &.{"AGENTS.md"}, &.{
        .{ .id = "pin:PIN.md", .hash = pin_hash },
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.items.items.len);
    try testing.expect(!result.items.items[0].changed);
    try testing.expect(result.items.items[0].content == null);
    try testing.expect(result.items.items[1].changed);
    try testing.expectEqualStrings("mpf memory", result.items.items[1].content.?);
}

test "activateMemory: deduplicates ids and logs activation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule");
    try writeFile(tmp.dir, ".prompts/rule/01_NOTE.md", "prompt memory");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try activateMemory(testing.allocator, root, .{
        .ids = &.{ "prompt:rule/01_NOTE.md", "prompt:rule/01_NOTE.md" },
        .task_id = "task-1",
        .turn_id = "turn-2",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.items.items.len);
    try testing.expect(result.items.items[0].changed);
    try testing.expectEqualStrings("prompt memory", result.items.items[0].content.?);

    const log_path = try usage_log.getActivationLogPath(testing.allocator, root);
    defer testing.allocator.free(log_path);
    const file = try std.fs.openFileAbsolute(log_path, .{});
    defer file.close();
    var tr_buf: [4096]u8 = undefined;
    var tr = std.fs.File.Reader.init(file, &tr_buf);
    const content = try tr.interface.readAllAlloc(testing.allocator, 4096);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"task_id\":\"task-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"id\":\"prompt:rule/01_NOTE.md\"") != null);
}

test "activateMemory: unknown id fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try testing.expectError(error.UnknownMemoryId, activateMemory(testing.allocator, root, .{
        .ids = &.{"prompt:missing.md"},
    }));
}
