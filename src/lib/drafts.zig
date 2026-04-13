const std = @import("std");
const testing = std.testing;

pub const DraftCategory = enum {
    prompt,
    context,

    pub fn toString(self: DraftCategory) []const u8 {
        return switch (self) {
            .prompt => "prompt",
            .context => "context",
        };
    }
};

pub const DraftOperation = enum {
    create,
    modify,
    rename,
    delete,
};

pub const DraftStatus = enum {
    editing,
    submitted,
    merged,
    rejected,
    conflicted,
};

pub const DraftEntry = struct {
    category: DraftCategory,
    prompt_id: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
    local_temp_id: ?[]const u8 = null,
    current_path: ?[]const u8 = null,
    draft_path: []const u8,
    operation: DraftOperation,
    base_hash: ?[]const u8 = null,
    status: DraftStatus,
};

/// Parsed drafts index. Strings borrow from an arena; deinit drops the arena.
pub const DraftsIndex = struct {
    arena_state: *std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(DraftEntry) = .empty,

    pub fn deinit(self: *DraftsIndex, allocator: std.mem.Allocator) void {
        self.arena_state.deinit();
        allocator.destroy(self.arena_state);
    }

    /// Find an active draft entry matching the given category and current path.
    /// Returns null if no entry matches or if the matching entry is a delete
    /// operation (callers should treat delete as NotFound).
    pub fn findByCurrentPath(self: *const DraftsIndex, category: DraftCategory, path: []const u8) ?*const DraftEntry {
        for (self.entries.items) |*entry| {
            if (entry.category != category) continue;
            const cur = entry.current_path orelse continue;
            if (std.mem.eql(u8, cur, path)) return entry;
        }
        return null;
    }
};

/// Load `{ws_dir}/drafts/_index.json` into memory. Returns an empty index if
/// the file does not exist; this is the expected state before any drafts exist.
pub fn loadIndex(allocator: std.mem.Allocator, ws_dir: []const u8) !DraftsIndex {
    const arena_state = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena_state);
    arena_state.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();

    var index: DraftsIndex = .{ .arena_state = arena_state };
    const arena = arena_state.allocator();

    const index_path = try std.fs.path.join(arena, &.{ ws_dir, "drafts", "_index.json" });

    const file = std.fs.openFileAbsolute(index_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return index,
        else => return err,
    };
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = try fr.interface.allocRemaining(arena, std.io.Limit.limited(1 * 1024 * 1024));

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{}) catch return error.InvalidDraftsIndex;
    if (parsed != .object) return error.InvalidDraftsIndex;

    const drafts_val = parsed.object.get("drafts") orelse return index;
    if (drafts_val != .array) return error.InvalidDraftsIndex;

    for (drafts_val.array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const entry = parseEntry(obj) orelse continue;
        try index.entries.append(arena, entry);
    }

    return index;
}

fn parseEntry(obj: std.json.ObjectMap) ?DraftEntry {
    const category_str = stringField(obj, "category") orelse return null;
    const category: DraftCategory = if (std.mem.eql(u8, category_str, "prompt"))
        .prompt
    else if (std.mem.eql(u8, category_str, "context"))
        .context
    else
        return null;

    const draft_path = stringField(obj, "draft_path") orelse return null;

    const op_str = stringField(obj, "operation") orelse return null;
    const operation: DraftOperation = if (std.mem.eql(u8, op_str, "create"))
        .create
    else if (std.mem.eql(u8, op_str, "modify"))
        .modify
    else if (std.mem.eql(u8, op_str, "rename"))
        .rename
    else if (std.mem.eql(u8, op_str, "delete"))
        .delete
    else
        return null;

    const status_str = stringField(obj, "status") orelse return null;
    const status: DraftStatus = if (std.mem.eql(u8, status_str, "editing"))
        .editing
    else if (std.mem.eql(u8, status_str, "submitted"))
        .submitted
    else if (std.mem.eql(u8, status_str, "merged"))
        .merged
    else if (std.mem.eql(u8, status_str, "rejected"))
        .rejected
    else if (std.mem.eql(u8, status_str, "conflicted"))
        .conflicted
    else
        return null;

    return .{
        .category = category,
        .prompt_id = stringField(obj, "prompt_id"),
        .context_id = stringField(obj, "context_id"),
        .local_temp_id = stringField(obj, "local_temp_id"),
        .current_path = stringField(obj, "current_path"),
        .draft_path = draft_path,
        .operation = operation,
        .base_hash = stringField(obj, "base_hash"),
        .status = status,
    };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Read a draft file from `{ws_dir}/drafts/{category}/{draft_path}`.
pub fn readDraftFile(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    draft_path: []const u8,
) ![]const u8 {
    const abs_path = try std.fs.path.join(allocator, &.{ ws_dir, "drafts", category.toString(), draft_path });
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    return try fr.interface.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024));
}

fn writeFile(dir: std.fs.Dir, sub_path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(sub_path, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.Writer.init(file, &buf);
    defer fw.interface.flush() catch {};
    try fw.interface.writeAll(content);
}

fn tmpDirAbsolutePath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    return tmp.dir.realpath(".", buf) catch "";
}

test "loadIndex: missing file returns empty index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), index.entries.items.len);
}

test "loadIndex: parses prompt and context entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("drafts");
    try writeFile(tmp.dir, "drafts/_index.json",
        \\{
        \\  "drafts": [
        \\    {
        \\      "category": "prompt",
        \\      "prompt_id": "p-style",
        \\      "current_path": "rule/coding/STYLE.md",
        \\      "draft_path": "rule/coding/STYLE.md",
        \\      "operation": "modify",
        \\      "base_hash": "sha256:abc",
        \\      "status": "editing"
        \\    },
        \\    {
        \\      "category": "context",
        \\      "context_id": "c-spec",
        \\      "current_path": "spec/API.md",
        \\      "draft_path": "spec/API.md",
        \\      "operation": "modify",
        \\      "base_hash": "sha256:xyz",
        \\      "status": "editing"
        \\    }
        \\  ]
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), index.entries.items.len);

    const prompt_entry = index.findByCurrentPath(.prompt, "rule/coding/STYLE.md").?;
    try testing.expectEqual(DraftOperation.modify, prompt_entry.operation);
    try testing.expectEqualStrings("p-style", prompt_entry.prompt_id.?);

    const ctx_entry = index.findByCurrentPath(.context, "spec/API.md").?;
    try testing.expectEqual(DraftCategory.context, ctx_entry.category);
    try testing.expectEqualStrings("c-spec", ctx_entry.context_id.?);
}

test "loadIndex: invalid drafts array returns error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("drafts");
    try writeFile(tmp.dir, "drafts/_index.json",
        \\{"drafts": "not an array"}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try testing.expectError(error.InvalidDraftsIndex, loadIndex(testing.allocator, root));
}

test "findByCurrentPath: returns null for unknown path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);

    try testing.expect(index.findByCurrentPath(.prompt, "anything") == null);
}

test "readDraftFile: reads from drafts/{category}/{draft_path}" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("drafts/prompt/rule/coding");
    try writeFile(tmp.dir, "drafts/prompt/rule/coding/STYLE.md", "draft override content");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const content = try readDraftFile(testing.allocator, root, .prompt, "rule/coding/STYLE.md");
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("draft override content", content);
}
