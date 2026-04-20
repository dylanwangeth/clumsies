//! Local drafts: tracks in-progress edits to prompts and context files per workspace. When a
//! user modifies a Library prompt locally (creating a "local edit"), the draft is stored under
//! ~/.clumsies/workspaces/{ws_id}/drafts/ with an index mapping original paths to draft files.
const std = @import("std");
const testing = std.testing;
const path_util = @import("clumsies_lib").util.path_util;
const util_hash = @import("clumsies_lib").util.hash;

pub const DraftCategory = enum {
    prompt,
    context,

    fn toString(self: DraftCategory) []const u8 {
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
    ready,
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

    /// Find a draft entry matching the given category and current path.
    /// Returns null only when no entry matches — delete-operation entries
    /// are still returned. Callers are expected to inspect `operation` and
    /// handle `.delete` as NotFound themselves, so the lookup stays usable
    /// for other callers that need the full set of tracked drafts.
    pub fn findByCurrentPath(self: *const DraftsIndex, category: DraftCategory, path: []const u8) ?*const DraftEntry {
        for (self.entries.items) |*entry| {
            if (entry.category != category) continue;
            const cur = entry.current_path orelse continue;
            if (std.mem.eql(u8, cur, path)) return entry;
        }
        return null;
    }
};

/// Load `{ws_dir}/drafts/index.json` into memory. Returns an empty index if
/// the file does not exist; this is the expected state before any drafts exist.
pub fn loadIndex(allocator: std.mem.Allocator, ws_dir: []const u8) !DraftsIndex {
    const arena_state = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena_state);
    arena_state.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();

    var index: DraftsIndex = .{ .arena_state = arena_state };
    const arena = arena_state.allocator();

    const index_path = try std.fs.path.join(arena, &.{ ws_dir, "drafts", "index.json" });

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
    else if (std.mem.eql(u8, status_str, "ready"))
        .ready
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
    if (!path_util.isSafeRelative(draft_path)) return error.UnsafeDraftPath;

    const abs_path = try std.fs.path.join(allocator, &.{ ws_dir, "drafts", category.toString(), draft_path });
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    return try fr.interface.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024));
}

/// Parameters for creating a new draft entry. `draft_path` is the target
/// path inside `drafts/{category}/`; `current_path` is null for
/// `create` operations and equals the cache path for `modify` / `delete`
/// (and equals the source path for `rename`; `draft_path` then carries
/// the new path).
pub const CreateDraftParams = struct {
    category: DraftCategory,
    operation: DraftOperation,
    draft_path: []const u8,
    current_path: ?[]const u8 = null,
    base_hash: ?[]const u8 = null,
    prompt_id: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
    local_temp_id: ?[]const u8 = null,
};

/// Create a new draft entry and write its initial content file. Fails
/// if a draft for the same (category, draft_path) already exists —
/// callers should use `saveDraftContent` to update an existing draft.
/// `initial_content` is required except for `.delete` operations.
///
/// Both the content file and the `index.json` are written via
/// temp-file + rename so a mid-write crash cannot leave a torn index.
pub fn createDraft(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    params: CreateDraftParams,
    initial_content: []const u8,
) !void {
    if (!path_util.isSafeRelative(params.draft_path)) return error.UnsafeDraftPath;

    var index = try loadIndex(allocator, ws_dir);
    defer index.deinit(allocator);

    for (index.entries.items) |entry| {
        if (entry.category != params.category) continue;
        if (std.mem.eql(u8, entry.draft_path, params.draft_path)) return error.DraftAlreadyExists;
    }

    if (params.operation != .delete) {
        try writeDraftFileAbs(allocator, ws_dir, params.category, params.draft_path, initial_content);
    }

    const new_entry = DraftEntry{
        .category = params.category,
        .prompt_id = params.prompt_id,
        .context_id = params.context_id,
        .local_temp_id = params.local_temp_id,
        .current_path = params.current_path,
        .draft_path = params.draft_path,
        .operation = params.operation,
        .base_hash = params.base_hash,
        .status = .editing,
    };

    try index.entries.append(index.arena_state.allocator(), new_entry);
    try writeIndexAtomic(allocator, ws_dir, index.entries.items);
}

/// Overwrite the content file of an existing draft. Does not touch the
/// index. Fails if the draft's entry is a `.delete` operation (which
/// has no content file by definition).
pub fn saveDraftContent(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    draft_path: []const u8,
    content: []const u8,
) !void {
    if (!path_util.isSafeRelative(draft_path)) return error.UnsafeDraftPath;
    try writeDraftFileAbs(allocator, ws_dir, category, draft_path, content);
}

/// Remove a draft: delete its content file (if any) and drop its entry
/// from the index. Idempotent when the entry is already absent.
pub fn discardDraft(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    draft_path: []const u8,
) !void {
    if (!path_util.isSafeRelative(draft_path)) return error.UnsafeDraftPath;

    var index = try loadIndex(allocator, ws_dir);
    defer index.deinit(allocator);

    const arena = index.arena_state.allocator();
    var kept: std.ArrayListUnmanaged(DraftEntry) = .empty;
    var removed = false;
    for (index.entries.items) |entry| {
        if (entry.category == category and std.mem.eql(u8, entry.draft_path, draft_path)) {
            removed = true;
            continue;
        }
        try kept.append(arena, entry);
    }

    if (removed) try writeIndexAtomic(allocator, ws_dir, kept.items);

    const abs_path = try std.fs.path.join(allocator, &.{ ws_dir, "drafts", category.toString(), draft_path });
    defer allocator.free(abs_path);
    std.fs.deleteFileAbsolute(abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub const ReconcileSummary = struct {
    conflicted: usize = 0,
};

/// Re-run drift detection on every non-terminal draft in
/// `{ws_dir}/drafts/index.json`. When a modify / rename / delete draft's
/// `base_hash` no longer matches the current cache content at
/// `current_path`, the entry is moved to `.conflicted`. Create-ops
/// have no cache base to compare against and are skipped. Drafts
/// already in `.merged`, `.rejected`, or `.conflicted` are left
/// untouched — terminal and already-flagged states are sticky.
///
/// Hub-PR reconciliation (submitted → merged / rejected) needs the
/// draft's pr_id, which is not tracked yet; that reconciliation is a
/// follow-up. For now submitted drafts stay submitted.
pub fn reconcileDrafts(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    cache_dir: []const u8,
) !ReconcileSummary {
    var index = try loadIndex(allocator, ws_dir);
    defer index.deinit(allocator);

    var summary: ReconcileSummary = .{};
    var changed = false;
    for (index.entries.items) |*entry| {
        switch (entry.status) {
            .merged, .rejected, .conflicted => continue,
            else => {},
        }
        if (entry.operation == .create) continue;
        const base_hash = entry.base_hash orelse continue;
        const cur = entry.current_path orelse continue;

        const rel_dir: []const u8 = switch (entry.category) {
            .prompt => "prompt",
            .context => "context",
        };
        const cache_path = try std.fs.path.join(allocator, &.{ cache_dir, rel_dir, cur });
        defer allocator.free(cache_path);

        const file = std.fs.openFileAbsolute(cache_path, .{}) catch continue;
        defer file.close();

        var read_buf: [4096]u8 = undefined;
        var fr = std.fs.File.Reader.init(file, &read_buf);
        const content = fr.interface.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024)) catch continue;
        defer allocator.free(content);

        const current_hash = util_hash.contentHash(content);
        if (!std.mem.eql(u8, current_hash[0..], base_hash)) {
            entry.status = .conflicted;
            summary.conflicted += 1;
            changed = true;
        }
    }
    if (changed) try writeIndexAtomic(allocator, ws_dir, index.entries.items);
    return summary;
}

/// Transition the status of an existing draft. Fails if the draft does
/// not exist. Idempotent when the draft is already in `new_status`.
pub fn setDraftStatus(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    draft_path: []const u8,
    new_status: DraftStatus,
) !void {
    if (!path_util.isSafeRelative(draft_path)) return error.UnsafeDraftPath;

    var index = try loadIndex(allocator, ws_dir);
    defer index.deinit(allocator);

    var found = false;
    for (index.entries.items) |*entry| {
        if (entry.category == category and std.mem.eql(u8, entry.draft_path, draft_path)) {
            if (entry.status == new_status) return;
            entry.status = new_status;
            found = true;
            break;
        }
    }
    if (!found) return error.DraftNotFound;

    try writeIndexAtomic(allocator, ws_dir, index.entries.items);
}

fn writeDraftFileAbs(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    draft_path: []const u8,
    content: []const u8,
) !void {
    const full_path = try std.fs.path.join(allocator, &.{ ws_dir, "drafts", category.toString(), draft_path });
    defer allocator.free(full_path);

    if (std.fs.path.dirname(full_path)) |parent| {
        try ensureDirTreeAbsolute(parent);
    }

    try atomicWriteAbsolute(allocator, full_path, content);
}

/// Recursively ensure every ancestor of `abs_path` exists. `makeDirAbsolute`
/// errors on missing intermediates; this walks up and creates each
/// segment idempotently.
fn ensureDirTreeAbsolute(abs_path: []const u8) !void {
    std.fs.makeDirAbsolute(abs_path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(abs_path) orelse return err;
            try ensureDirTreeAbsolute(parent);
            std.fs.makeDirAbsolute(abs_path) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
        },
        else => return err,
    };
}

fn atomicWriteAbsolute(allocator: std.mem.Allocator, abs_path: []const u8, content: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{abs_path});
    defer allocator.free(tmp_path);

    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer file.close();
        var buf: [4096]u8 = undefined;
        var fw = std.fs.File.Writer.init(file, &buf);
        try fw.interface.writeAll(content);
        try fw.interface.flush();
    }

    try std.fs.renameAbsolute(tmp_path, abs_path);
}

fn writeIndexAtomic(allocator: std.mem.Allocator, ws_dir: []const u8, entries: []const DraftEntry) !void {
    const drafts_dir = try std.fs.path.join(allocator, &.{ ws_dir, "drafts" });
    defer allocator.free(drafts_dir);
    try ensureDirTreeAbsolute(drafts_dir);

    const index_path = try std.fs.path.join(allocator, &.{ drafts_dir, "index.json" });
    defer allocator.free(index_path);

    const json = try serializeIndex(allocator, entries);
    defer allocator.free(json);

    try atomicWriteAbsolute(allocator, index_path, json);
}

fn serializeIndex(allocator: std.mem.Allocator, entries: []const DraftEntry) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"drafts\": [");
    for (entries, 0..) |entry, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\n    {");
        try writeStringField(allocator, &buf, "category", entry.category.toString(), true);
        try writeOptStringField(allocator, &buf, "prompt_id", entry.prompt_id);
        try writeOptStringField(allocator, &buf, "context_id", entry.context_id);
        try writeOptStringField(allocator, &buf, "local_temp_id", entry.local_temp_id);
        try writeOptStringField(allocator, &buf, "current_path", entry.current_path);
        try writeStringField(allocator, &buf, "draft_path", entry.draft_path, false);
        try writeStringField(allocator, &buf, "operation", operationToString(entry.operation), false);
        try writeOptStringField(allocator, &buf, "base_hash", entry.base_hash);
        try writeStringField(allocator, &buf, "status", statusToString(entry.status), false);
        try buf.appendSlice(allocator, "\n    }");
    }
    if (entries.len > 0) try buf.appendSlice(allocator, "\n  ");
    try buf.appendSlice(allocator, "]\n}\n");

    return try buf.toOwnedSlice(allocator);
}

fn writeStringField(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    key: []const u8,
    value: []const u8,
    first: bool,
) !void {
    if (!first) try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, "\n      \"");
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, "\": \"");
    try appendJsonEscaped(allocator, buf, value);
    try buf.appendSlice(allocator, "\"");
}

fn writeOptStringField(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    key: []const u8,
    value: ?[]const u8,
) !void {
    const v = value orelse return;
    try writeStringField(allocator, buf, key, v, false);
}

fn appendJsonEscaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    for (value) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        else => try buf.append(allocator, c),
    };
}

fn operationToString(op: DraftOperation) []const u8 {
    return switch (op) {
        .create => "create",
        .modify => "modify",
        .rename => "rename",
        .delete => "delete",
    };
}

fn statusToString(status: DraftStatus) []const u8 {
    return switch (status) {
        .editing => "editing",
        .ready => "ready",
        .submitted => "submitted",
        .merged => "merged",
        .rejected => "rejected",
        .conflicted => "conflicted",
    };
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
    try writeFile(tmp.dir, "drafts/index.json",
        \\{
        \\  "drafts": [
        \\    {
        \\      "category": "prompt",
        \\      "prompt_id": "p-style",
        \\      "current_path": "coding/STYLE.md",
        \\      "draft_path": "coding/STYLE.md",
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

    const prompt_entry = index.findByCurrentPath(.prompt, "coding/STYLE.md").?;
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
    try writeFile(tmp.dir, "drafts/index.json",
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

    try tmp.dir.makePath("drafts/prompt/coding");
    try writeFile(tmp.dir, "drafts/prompt/coding/STYLE.md", "draft override content");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const content = try readDraftFile(testing.allocator, root, .prompt, "coding/STYLE.md");
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("draft override content", content);
}

test "createDraft: writes file and index entry round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .prompt,
        .operation = .modify,
        .draft_path = "coding/STYLE.md",
        .current_path = "coding/STYLE.md",
        .base_hash = "sha256:abc",
        .prompt_id = "p-style",
    }, "# STYLE modified\n");

    const content = try readDraftFile(testing.allocator, root, .prompt, "coding/STYLE.md");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("# STYLE modified\n", content);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), index.entries.items.len);
    const entry = index.findByCurrentPath(.prompt, "coding/STYLE.md").?;
    try testing.expectEqual(DraftOperation.modify, entry.operation);
    try testing.expectEqualStrings("p-style", entry.prompt_id.?);
    try testing.expectEqualStrings("sha256:abc", entry.base_hash.?);
    try testing.expectEqual(DraftStatus.editing, entry.status);
}

test "createDraft: rejects duplicate draft for same (category, draft_path)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .create,
        .draft_path = "spec/NEW.md",
    }, "# NEW\n");

    try testing.expectError(error.DraftAlreadyExists, createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .create,
        .draft_path = "spec/NEW.md",
    }, "# NEW again\n"));
}

test "createDraft: delete operation does not write a content file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .prompt,
        .operation = .delete,
        .draft_path = "old/UNUSED.md",
        .current_path = "old/UNUSED.md",
        .prompt_id = "p-unused",
    }, "");

    try testing.expectError(error.FileNotFound, readDraftFile(testing.allocator, root, .prompt, "old/UNUSED.md"));

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    const entry = index.findByCurrentPath(.prompt, "old/UNUSED.md").?;
    try testing.expectEqual(DraftOperation.delete, entry.operation);
}

test "saveDraftContent: overwrites existing draft file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .modify,
        .draft_path = "spec/API.md",
        .current_path = "spec/API.md",
    }, "first version\n");

    try saveDraftContent(testing.allocator, root, .context, "spec/API.md", "second version\n");

    const content = try readDraftFile(testing.allocator, root, .context, "spec/API.md");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("second version\n", content);
}

test "discardDraft: removes entry and file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .prompt,
        .operation = .create,
        .draft_path = "new/FRESH.md",
        .local_temp_id = "local-1",
    }, "# FRESH\n");

    try discardDraft(testing.allocator, root, .prompt, "new/FRESH.md");

    try testing.expectError(error.FileNotFound, readDraftFile(testing.allocator, root, .prompt, "new/FRESH.md"));

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), index.entries.items.len);
}

test "discardDraft: idempotent when draft is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try discardDraft(testing.allocator, root, .prompt, "never/existed.md");
}

test "setDraftStatus: transitions editing to ready and back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .prompt,
        .operation = .modify,
        .draft_path = "x/Y.md",
        .current_path = "x/Y.md",
        .prompt_id = "p-y",
    }, "draft body\n");

    try setDraftStatus(testing.allocator, root, .prompt, "x/Y.md", .ready);

    {
        var index = try loadIndex(testing.allocator, root);
        defer index.deinit(testing.allocator);
        const entry = index.findByCurrentPath(.prompt, "x/Y.md").?;
        try testing.expectEqual(DraftStatus.ready, entry.status);
    }

    try setDraftStatus(testing.allocator, root, .prompt, "x/Y.md", .editing);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    const entry = index.findByCurrentPath(.prompt, "x/Y.md").?;
    try testing.expectEqual(DraftStatus.editing, entry.status);
}

test "setDraftStatus: returns DraftNotFound for missing draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try testing.expectError(error.DraftNotFound, setDraftStatus(testing.allocator, root, .prompt, "nope.md", .ready));
}

test "reconcileDrafts: leaves matching base_hash untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const seed = "hello world\n";
    const seed_hash = util_hash.contentHash(seed);
    try createDraft(testing.allocator, root, .{
        .category = .prompt,
        .operation = .modify,
        .draft_path = "coding/A.md",
        .current_path = "coding/A.md",
        .prompt_id = "p-a",
        .base_hash = seed_hash[0..],
    }, seed);

    try tmp.dir.makePath("cache/prompt/coding");
    try writeFile(tmp.dir, "cache/prompt/coding/A.md", seed);

    const cache_dir = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_dir);

    const summary = try reconcileDrafts(testing.allocator, root, cache_dir);
    try testing.expectEqual(@as(usize, 0), summary.conflicted);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(DraftStatus.editing, index.entries.items[0].status);
}

test "reconcileDrafts: marks conflicted when cache drifted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const seed = "v1 body\n";
    const seed_hash = util_hash.contentHash(seed);
    try createDraft(testing.allocator, root, .{
        .category = .prompt,
        .operation = .modify,
        .draft_path = "coding/A.md",
        .current_path = "coding/A.md",
        .prompt_id = "p-a",
        .base_hash = seed_hash[0..],
    }, seed);

    try tmp.dir.makePath("cache/prompt/coding");
    try writeFile(tmp.dir, "cache/prompt/coding/A.md", "v2 body (someone else merged)\n");

    const cache_dir = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_dir);

    const summary = try reconcileDrafts(testing.allocator, root, cache_dir);
    try testing.expectEqual(@as(usize, 1), summary.conflicted);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(DraftStatus.conflicted, index.entries.items[0].status);
}

test "reconcileDrafts: skips create-operation drafts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .prompt,
        .operation = .create,
        .draft_path = "coding/NEW.md",
    }, "brand new\n");

    const cache_dir = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_dir);

    const summary = try reconcileDrafts(testing.allocator, root, cache_dir);
    try testing.expectEqual(@as(usize, 0), summary.conflicted);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(DraftStatus.editing, index.entries.items[0].status);
}

test "reconcileDrafts: leaves terminal states sticky" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const seed = "merged body\n";
    const seed_hash = util_hash.contentHash(seed);
    try createDraft(testing.allocator, root, .{
        .category = .prompt,
        .operation = .modify,
        .draft_path = "coding/A.md",
        .current_path = "coding/A.md",
        .prompt_id = "p-a",
        .base_hash = seed_hash[0..],
    }, seed);
    try setDraftStatus(testing.allocator, root, .prompt, "coding/A.md", .merged);

    try tmp.dir.makePath("cache/prompt/coding");
    try writeFile(tmp.dir, "cache/prompt/coding/A.md", "totally different body\n");

    const cache_dir = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_dir);

    const summary = try reconcileDrafts(testing.allocator, root, cache_dir);
    try testing.expectEqual(@as(usize, 0), summary.conflicted);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(DraftStatus.merged, index.entries.items[0].status);
}

test "index serialization: multiple entries survive round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .prompt,
        .operation = .modify,
        .draft_path = "a/A.md",
        .current_path = "a/A.md",
        .prompt_id = "p-a",
        .base_hash = "sha256:aaa",
    }, "a\n");
    try createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .create,
        .draft_path = "spec/B.md",
        .local_temp_id = "tmp-b",
    }, "b\n");
    try createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .rename,
        .draft_path = "archive/C.md",
        .current_path = "spec/C.md",
        .context_id = "c-c",
        .base_hash = "sha256:ccc",
    }, "c\n");

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), index.entries.items.len);
}
