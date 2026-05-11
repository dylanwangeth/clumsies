//! Local drafts: tracks in-progress edits to rules and context files per workspace. When a
//! user modifies a Artifact rule locally (creating a "local edit"), the draft is stored under
//! ~/.clumsies/workspaces/{name}/drafts/ with an index mapping original paths to draft files.
const std = @import("std");
const testing = std.testing;
const path_util = @import("clumsies_lib").util.path_util;
const util_hash = @import("clumsies_lib").util.hash;

pub const DraftCategory = enum {
    rule,
    context,
    meta_prompt,

    fn toString(self: DraftCategory) []const u8 {
        return switch (self) {
            .rule => "rule",
            .context => "context",
            .meta_prompt => "meta_prompt",
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
    draft,
    in_review,
    applied,
    declined,
    conflicted,
};

pub const DraftEntry = struct {
    category: DraftCategory,
    rule_id: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
    local_temp_id: ?[]const u8 = null,
    current_path: ?[]const u8 = null,
    draft_path: []const u8,
    operation: DraftOperation,
    base_hash: ?[]const u8 = null,
    status: DraftStatus,
    description: ?[]const u8 = null,
};

fn isTerminalStatus(status: DraftStatus) bool {
    return switch (status) {
        .applied, .declined, .conflicted => true,
        .draft, .in_review => false,
    };
}

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

    /// Find a draft entry by its local_temp_id.
    pub fn findByLocalTempId(self: *const DraftsIndex, temp_id: []const u8) ?*const DraftEntry {
        for (self.entries.items) |*entry| {
            const tid = entry.local_temp_id orelse continue;
            if (std.mem.eql(u8, tid, temp_id)) return entry;
        }
        return null;
    }

    /// Find a create-draft entry by its draft_path.
    pub fn findCreateByDraftPath(self: *const DraftsIndex, draft_path: []const u8) ?*const DraftEntry {
        for (self.entries.items) |*entry| {
            if (entry.operation != .create) continue;
            if (std.mem.eql(u8, entry.draft_path, draft_path)) return entry;
        }
        return null;
    }

    /// Find a draft entry by any user-facing draft identifier.
    pub fn findDraftById(self: *const DraftsIndex, category: DraftCategory, id: []const u8) ?*const DraftEntry {
        for (self.entries.items) |*entry| {
            if (entry.category != category) continue;
            if (std.mem.eql(u8, entry.draft_path, id)) return entry;
            if (entry.local_temp_id) |value| {
                if (std.mem.eql(u8, value, id)) return entry;
            }
            if (entry.current_path) |value| {
                if (std.mem.eql(u8, value, id)) return entry;
            }
            if (entry.rule_id) |value| {
                if (std.mem.eql(u8, value, id)) return entry;
            }
            if (entry.context_id) |value| {
                if (std.mem.eql(u8, value, id)) return entry;
            }
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
    const category: DraftCategory = if (std.mem.eql(u8, category_str, "rule"))
        .rule
    else if (std.mem.eql(u8, category_str, "context"))
        .context
    else if (std.mem.eql(u8, category_str, "meta_prompt"))
        .meta_prompt
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
    const status: DraftStatus = if (std.mem.eql(u8, status_str, "draft"))
        .draft
    else if (std.mem.eql(u8, status_str, "in_review"))
        .in_review
    else if (std.mem.eql(u8, status_str, "applied"))
        .applied
    else if (std.mem.eql(u8, status_str, "declined"))
        .declined
    else if (std.mem.eql(u8, status_str, "conflicted"))
        .conflicted
    else
        return null;

    return .{
        .category = category,
        .rule_id = stringField(obj, "rule_id"),
        .context_id = stringField(obj, "context_id"),
        .local_temp_id = stringField(obj, "local_temp_id"),
        .current_path = stringField(obj, "current_path"),
        .draft_path = draft_path,
        .operation = operation,
        .base_hash = stringField(obj, "base_hash"),
        .status = status,
        .description = stringField(obj, "description"),
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
    rule_id: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
    local_temp_id: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub fn createDraftLocalTempId(
    allocator: std.mem.Allocator,
    category: DraftCategory,
    draft_path: []const u8,
) ![]const u8 {
    const seed = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ category.toString(), draft_path });
    defer allocator.free(seed);

    const hash = util_hash.contentHash(seed);
    const digest = hash["sha256:".len..];
    return std.fmt.allocPrint(
        allocator,
        "tmp-{s}-{s}",
        .{ localTempIdPrefix(category), digest[0..12] },
    );
}

fn localTempIdPrefix(category: DraftCategory) []const u8 {
    return switch (category) {
        .rule => "rule",
        .context => "context",
        .meta_prompt => "mpf",
    };
}

pub const DraftIdentity = struct {
    draft_path: []const u8,
    previous_path: ?[]const u8 = null,
    local_temp_id: ?[]const u8 = null,

    pub fn deinit(self: DraftIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.draft_path);
        if (self.previous_path) |path| allocator.free(path);
        if (self.local_temp_id) |id| allocator.free(id);
    }
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
        if (isTerminalStatus(entry.status)) continue;
        if (std.mem.eql(u8, entry.draft_path, params.draft_path)) return error.DraftAlreadyExists;
    }

    if (params.operation != .delete) {
        try writeDraftFileAbs(allocator, ws_dir, params.category, params.draft_path, initial_content);
    }

    const arena = index.arena_state.allocator();
    const local_temp_id = params.local_temp_id orelse if (params.operation == .create)
        try createDraftLocalTempId(arena, params.category, params.draft_path)
    else
        null;

    const new_entry = DraftEntry{
        .category = params.category,
        .rule_id = params.rule_id,
        .context_id = params.context_id,
        .local_temp_id = local_temp_id,
        .current_path = params.current_path,
        .draft_path = params.draft_path,
        .operation = params.operation,
        .base_hash = params.base_hash,
        .status = .draft,
        .description = params.description,
    };

    try index.entries.append(arena, new_entry);
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

/// Overwrite an existing modify draft and refresh its index metadata.
/// Returns false when no matching draft exists. Other draft operations
/// are intentionally rejected so create/rename/delete semantics remain
/// explicit.
pub fn updateModifyDraftContent(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    draft_path: []const u8,
    content: []const u8,
    description: ?[]const u8,
) !bool {
    if (!path_util.isSafeRelative(draft_path)) return error.UnsafeDraftPath;

    var index = try loadIndex(allocator, ws_dir);
    defer index.deinit(allocator);

    for (index.entries.items) |*entry| {
        if (entry.category != category) continue;
        if (!std.mem.eql(u8, entry.draft_path, draft_path)) continue;
        if (entry.operation != .modify) return error.DraftOperationConflict;

        try writeDraftFileAbs(allocator, ws_dir, category, draft_path, content);
        if (description) |desc| entry.description = desc;
        entry.status = .draft;
        try writeIndexAtomic(allocator, ws_dir, index.entries.items);
        return true;
    }

    return false;
}

/// Overwrite an existing create draft addressed by any user-facing draft
/// identifier. Returns null when the id does not refer to a create draft.
pub fn updateCreateDraftContentById(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    id: []const u8,
    content: []const u8,
    description: ?[]const u8,
) !?DraftIdentity {
    var index = try loadIndex(allocator, ws_dir);
    defer index.deinit(allocator);

    var maybe_entry: ?*DraftEntry = null;
    for (index.entries.items) |*entry| {
        if (entry.category != category) continue;
        if (std.mem.eql(u8, entry.draft_path, id)) {
            maybe_entry = entry;
            break;
        }
        if (entry.local_temp_id) |value| {
            if (std.mem.eql(u8, value, id)) {
                maybe_entry = entry;
                break;
            }
        }
    }
    const entry = maybe_entry orelse return null;
    if (entry.operation != .create) return null;

    const draft_path = try allocator.dupe(u8, entry.draft_path);
    errdefer allocator.free(draft_path);
    const local_temp_id = if (entry.local_temp_id) |temp_id|
        try allocator.dupe(u8, temp_id)
    else
        null;
    errdefer if (local_temp_id) |temp_id| allocator.free(temp_id);

    try writeDraftFileAbs(allocator, ws_dir, category, entry.draft_path, content);
    if (description) |desc| entry.description = desc;
    entry.status = .draft;
    try writeIndexAtomic(allocator, ws_dir, index.entries.items);

    return .{
        .draft_path = draft_path,
        .local_temp_id = local_temp_id,
    };
}

pub fn renameCreateDraftById(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    id: []const u8,
    new_path: []const u8,
    description: ?[]const u8,
) !?DraftIdentity {
    if (!path_util.isSafeRelative(new_path)) return error.UnsafeDraftPath;

    var index = try loadIndex(allocator, ws_dir);
    defer index.deinit(allocator);

    var entry_opt: ?*DraftEntry = null;
    for (index.entries.items) |*candidate| {
        if (candidate.category != category) continue;
        if (std.mem.eql(u8, candidate.draft_path, id)) {
            entry_opt = candidate;
            break;
        }
        if (candidate.local_temp_id) |value| {
            if (std.mem.eql(u8, value, id)) {
                entry_opt = candidate;
                break;
            }
        }
        if (candidate.current_path) |value| {
            if (std.mem.eql(u8, value, id)) {
                entry_opt = candidate;
                break;
            }
        }
    }
    const entry = entry_opt orelse return null;
    if (entry.operation != .create) return null;

    for (index.entries.items) |*other| {
        if (other == entry) continue;
        if (other.category != category) continue;
        if (isTerminalStatus(other.status)) continue;
        if (std.mem.eql(u8, other.draft_path, new_path)) return error.DraftAlreadyExists;
    }

    const old_path = try allocator.dupe(u8, entry.draft_path);
    errdefer allocator.free(old_path);
    const local_temp_id = if (entry.local_temp_id) |temp_id|
        try allocator.dupe(u8, temp_id)
    else
        null;
    errdefer if (local_temp_id) |temp_id| allocator.free(temp_id);
    const new_path_owned = try allocator.dupe(u8, new_path);
    errdefer allocator.free(new_path_owned);

    const content = try readDraftFile(allocator, ws_dir, category, old_path);
    defer allocator.free(content);
    try writeDraftFileAbs(allocator, ws_dir, category, new_path, content);
    errdefer discardDraftFile(allocator, ws_dir, category, new_path) catch {};

    entry.draft_path = new_path;
    if (description) |desc| entry.description = desc;
    entry.status = .draft;
    try writeIndexAtomic(allocator, ws_dir, index.entries.items);

    discardDraftFile(allocator, ws_dir, category, old_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    return .{
        .draft_path = new_path_owned,
        .previous_path = old_path,
        .local_temp_id = local_temp_id,
    };
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

    try discardDraftFile(allocator, ws_dir, category, draft_path);
}

fn discardDraftFile(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    draft_path: []const u8,
) !void {
    const abs_path = try std.fs.path.join(allocator, &.{ ws_dir, "drafts", category.toString(), draft_path });
    defer allocator.free(abs_path);
    std.fs.deleteFileAbsolute(abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Discard a draft by id, local temp id, current path, or draft path.
/// Returns the discarded draft path, or null when no draft matched.
pub fn discardDraftById(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    id: []const u8,
) !?[]const u8 {
    var index = try loadIndex(allocator, ws_dir);
    defer index.deinit(allocator);

    const entry = index.findDraftById(category, id) orelse return null;
    const draft_path = try allocator.dupe(u8, entry.draft_path);
    errdefer allocator.free(draft_path);

    try discardDraft(allocator, ws_dir, category, draft_path);
    return draft_path;
}

/// Discard a modify draft when its file content still matches the base
/// content. Returns true only when a matching draft was removed.
pub fn discardUnchangedModifyDraft(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    draft_path: []const u8,
    base_content: []const u8,
) !bool {
    if (!path_util.isSafeRelative(draft_path)) return error.UnsafeDraftPath;

    const unchanged = blk: {
        var index = try loadIndex(allocator, ws_dir);
        defer index.deinit(allocator);

        for (index.entries.items) |entry| {
            if (entry.category != category) continue;
            if (!std.mem.eql(u8, entry.draft_path, draft_path)) continue;
            if (entry.operation != .modify) break :blk false;

            const content = try readDraftFile(allocator, ws_dir, category, draft_path);
            defer allocator.free(content);
            break :blk std.mem.eql(u8, content, base_content);
        }

        break :blk false;
    };

    if (!unchanged) return false;
    try discardDraft(allocator, ws_dir, category, draft_path);
    return true;
}

/// Discard a create-only draft addressed by the identity exposed through
/// discovery. Create drafts must have `local_temp_id`; `discardDraft`
/// itself remains intentionally keyed by `draft_path`.
pub fn discardCreateDraftById(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    id: []const u8,
) !?[]const u8 {
    var index = try loadIndex(allocator, ws_dir);
    defer index.deinit(allocator);

    const entry = index.findByLocalTempId(id) orelse return null;
    if (entry.category != category or entry.operation != .create) return null;

    const draft_path = try allocator.dupe(u8, entry.draft_path);
    errdefer allocator.free(draft_path);
    try discardDraft(allocator, ws_dir, category, draft_path);
    return draft_path;
}

pub const ReconcileSummary = struct {
    conflicted: usize = 0,
};

/// Re-run drift detection on every non-terminal draft in
/// `{ws_dir}/drafts/index.json`. When a modify / rename / delete draft's
/// `base_hash` no longer matches the current cache content at
/// `current_path`, the entry is moved to `.conflicted`. Create-ops
/// have no cache base to compare against and are skipped. Drafts
/// already in `.applied`, `.declined`, or `.conflicted` are left
/// untouched — terminal and already-flagged states are sticky.
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
            .applied, .declined, .conflicted => continue,
            else => {},
        }
        if (entry.operation == .create) continue;
        const base_hash = entry.base_hash orelse continue;
        const cur = entry.current_path orelse continue;

        const cache_path = if (entry.category == .meta_prompt)
            try std.fs.path.join(allocator, &.{ cache_dir, cur })
        else blk: {
            const rel_dir: []const u8 = switch (entry.category) {
                .rule => "rule",
                .context => "context",
                else => unreachable,
            };
            break :blk try std.fs.path.join(allocator, &.{ cache_dir, rel_dir, cur });
        };
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

pub fn transitionDraftStatus(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: DraftCategory,
    draft_path: []const u8,
    expected_status: DraftStatus,
    new_status: DraftStatus,
) !bool {
    if (!path_util.isSafeRelative(draft_path)) return error.UnsafeDraftPath;

    var index = try loadIndex(allocator, ws_dir);
    defer index.deinit(allocator);

    for (index.entries.items) |*entry| {
        if (entry.category == category and std.mem.eql(u8, entry.draft_path, draft_path)) {
            if (entry.status != expected_status) return false;
            if (entry.status == new_status) return true;
            entry.status = new_status;
            try writeIndexAtomic(allocator, ws_dir, index.entries.items);
            return true;
        }
    }
    return error.DraftNotFound;
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
        try writeOptStringField(allocator, &buf, "rule_id", entry.rule_id);
        try writeOptStringField(allocator, &buf, "context_id", entry.context_id);
        try writeOptStringField(allocator, &buf, "local_temp_id", entry.local_temp_id);
        try writeOptStringField(allocator, &buf, "current_path", entry.current_path);
        try writeStringField(allocator, &buf, "draft_path", entry.draft_path, false);
        try writeStringField(allocator, &buf, "operation", operationToString(entry.operation), false);
        try writeOptStringField(allocator, &buf, "base_hash", entry.base_hash);
        try writeStringField(allocator, &buf, "status", statusToString(entry.status), false);
        try writeOptStringField(allocator, &buf, "description", entry.description);
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
        .draft => "draft",
        .in_review => "in_review",
        .applied => "applied",
        .declined => "declined",
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

test "loadIndex: parses rule and context entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("drafts");
    try writeFile(tmp.dir, "drafts/index.json",
        \\{
        \\  "drafts": [
        \\    {
        \\      "category": "rule",
        \\      "rule_id": "p-style",
        \\      "current_path": "coding/STYLE.md",
        \\      "draft_path": "coding/STYLE.md",
        \\      "operation": "modify",
        \\      "base_hash": "sha256:abc",
        \\      "status": "draft"
        \\    },
        \\    {
        \\      "category": "context",
        \\      "context_id": "c-spec",
        \\      "current_path": "spec/API.md",
        \\      "draft_path": "spec/API.md",
        \\      "operation": "modify",
        \\      "base_hash": "sha256:xyz",
        \\      "status": "draft"
        \\    }
        \\  ]
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), index.entries.items.len);

    const rule_entry = index.findByCurrentPath(.rule, "coding/STYLE.md").?;
    try testing.expectEqual(DraftOperation.modify, rule_entry.operation);
    try testing.expectEqualStrings("p-style", rule_entry.rule_id.?);

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

    try testing.expect(index.findByCurrentPath(.rule, "anything") == null);
}

test "findByLocalTempId: returns entry matching temp_id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .create,
        .draft_path = "research/NEW.md",
        .local_temp_id = "tmp-abc123",
    }, "# NEW\n");

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);

    const entry = index.findByLocalTempId("tmp-abc123").?;
    try testing.expectEqualStrings("research/NEW.md", entry.draft_path);
    try testing.expect(index.findByLocalTempId("nonexistent") == null);
}

test "createDraft: generates local temp id for create operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .create,
        .draft_path = "research/NEW.md",
    }, "# NEW\n");

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);

    const entry = index.findCreateByDraftPath("research/NEW.md").?;
    try testing.expect(entry.local_temp_id != null);
    try testing.expect(std.mem.startsWith(u8, entry.local_temp_id.?, "tmp-context-"));
}

test "updateCreateDraftContentById: overwrites create draft by path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .create,
        .draft_path = "research/NEW.md",
        .description = "first",
    }, "first body");

    const identity = try updateCreateDraftContentById(
        testing.allocator,
        root,
        .context,
        "research/NEW.md",
        "second body",
        "second",
    ) orelse return error.TestUnexpectedResult;
    defer identity.deinit(testing.allocator);

    try testing.expectEqualStrings("research/NEW.md", identity.draft_path);
    try testing.expect(identity.local_temp_id != null);

    const content = try readDraftFile(testing.allocator, root, .context, "research/NEW.md");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("second body", content);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    const entry = index.findCreateByDraftPath("research/NEW.md") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(DraftOperation.create, entry.operation);
    try testing.expectEqualStrings("second", entry.description.?);
}

test "findCreateByDraftPath: only matches create operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "coding/STYLE.md",
        .current_path = "coding/STYLE.md",
        .base_hash = "sha256:abc",
        .rule_id = "p-style",
    }, "# modified\n");

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);

    try testing.expect(index.findCreateByDraftPath("coding/STYLE.md") == null);
    try testing.expect(index.findCreateByDraftPath("nonexistent") == null);
}

test "readDraftFile: reads from drafts/{category}/{draft_path}" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("drafts/rule/coding");
    try writeFile(tmp.dir, "drafts/rule/coding/STYLE.md", "draft override content");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const content = try readDraftFile(testing.allocator, root, .rule, "coding/STYLE.md");
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("draft override content", content);
}

test "createDraft: writes file and index entry round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "coding/STYLE.md",
        .current_path = "coding/STYLE.md",
        .base_hash = "sha256:abc",
        .rule_id = "p-style",
    }, "# STYLE modified\n");

    const content = try readDraftFile(testing.allocator, root, .rule, "coding/STYLE.md");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("# STYLE modified\n", content);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), index.entries.items.len);
    const entry = index.findByCurrentPath(.rule, "coding/STYLE.md").?;
    try testing.expectEqual(DraftOperation.modify, entry.operation);
    try testing.expectEqualStrings("p-style", entry.rule_id.?);
    try testing.expectEqualStrings("sha256:abc", entry.base_hash.?);
    try testing.expectEqual(DraftStatus.draft, entry.status);
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

test "createDraft: terminal entries do not block a new draft for same path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .create,
        .draft_path = "coding/NEW.md",
    }, "# NEW\n");
    try setDraftStatus(testing.allocator, root, .rule, "coding/NEW.md", .applied);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "coding/NEW.md",
        .current_path = "coding/NEW.md",
        .rule_id = "p-new",
        .base_hash = "sha256:abc",
    }, "# NEW modified\n");

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), index.entries.items.len);
    try testing.expectEqual(DraftStatus.applied, index.entries.items[0].status);
    try testing.expectEqual(DraftStatus.draft, index.entries.items[1].status);
}

test "createDraft: delete operation does not write a content file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .delete,
        .draft_path = "old/UNUSED.md",
        .current_path = "old/UNUSED.md",
        .rule_id = "p-unused",
    }, "");

    try testing.expectError(error.FileNotFound, readDraftFile(testing.allocator, root, .rule, "old/UNUSED.md"));

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    const entry = index.findByCurrentPath(.rule, "old/UNUSED.md").?;
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

test "updateModifyDraftContent: overwrites existing modify draft and metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .modify,
        .draft_path = "spec/API.md",
        .current_path = "spec/API.md",
        .description = "first description",
    }, "first version\n");
    try setDraftStatus(testing.allocator, root, .context, "spec/API.md", .conflicted);

    const updated = try updateModifyDraftContent(
        testing.allocator,
        root,
        .context,
        "spec/API.md",
        "second version\n",
        "second description",
    );
    try testing.expect(updated);

    const content = try readDraftFile(testing.allocator, root, .context, "spec/API.md");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("second version\n", content);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), index.entries.items.len);
    const entry = index.findByCurrentPath(.context, "spec/API.md").?;
    try testing.expectEqual(DraftOperation.modify, entry.operation);
    try testing.expectEqual(DraftStatus.draft, entry.status);
    try testing.expectEqualStrings("second description", entry.description.?);
}

test "updateModifyDraftContent: rejects non-modify draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .create,
        .draft_path = "spec/API.md",
    }, "first version\n");

    try testing.expectError(
        error.DraftOperationConflict,
        updateModifyDraftContent(
            testing.allocator,
            root,
            .context,
            "spec/API.md",
            "second version\n",
            null,
        ),
    );
}

test "discardDraft: removes entry and file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .create,
        .draft_path = "new/FRESH.md",
        .local_temp_id = "local-1",
    }, "# FRESH\n");

    try discardDraft(testing.allocator, root, .rule, "new/FRESH.md");

    try testing.expectError(error.FileNotFound, readDraftFile(testing.allocator, root, .rule, "new/FRESH.md"));

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), index.entries.items.len);
}

test "discardCreateDraftById: accepts local temp id and returns draft path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .context,
        .operation = .create,
        .draft_path = "projects/eth-p2p-z/project-context.md",
        .local_temp_id = "tmp-context-1",
    }, "draft body");

    const draft_path = try discardCreateDraftById(testing.allocator, root, .context, "tmp-context-1") orelse
        return error.TestExpectedEqual;
    defer testing.allocator.free(draft_path);

    try testing.expectEqualStrings("projects/eth-p2p-z/project-context.md", draft_path);
    try testing.expectError(error.FileNotFound, readDraftFile(testing.allocator, root, .context, draft_path));

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expect(index.findByLocalTempId("tmp-context-1") == null);
}

test "discardCreateDraftById: rejects draft path identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);
    const path = "learning/zig-libp2p/eth-p2p-z.md";

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .create,
        .draft_path = path,
    }, "draft body");

    try testing.expect(try discardCreateDraftById(testing.allocator, root, .rule, path) == null);

    const content = try readDraftFile(testing.allocator, root, .rule, path);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("draft body", content);
}

test "discardCreateDraftById: ignores non-create drafts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "coding/STYLE.md",
        .current_path = "coding/STYLE.md",
    }, "draft body");

    try testing.expect(try discardCreateDraftById(testing.allocator, root, .rule, "coding/STYLE.md") == null);
}

test "discardDraftById: accepts rule id for modify draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "coding/STYLE.md",
        .current_path = "coding/STYLE.md",
        .rule_id = "p-style",
    }, "draft body");

    const draft_path = try discardDraftById(testing.allocator, root, .rule, "p-style") orelse
        return error.TestExpectedEqual;
    defer testing.allocator.free(draft_path);

    try testing.expectEqualStrings("coding/STYLE.md", draft_path);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expect(index.findDraftById(.rule, "p-style") == null);
}

test "discardUnchangedModifyDraft: removes modify draft matching base content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "adr/ADR-003.md",
        .current_path = "adr/ADR-003.md",
    }, "# ADR-003\n");

    try testing.expect(try discardUnchangedModifyDraft(
        testing.allocator,
        root,
        .rule,
        "adr/ADR-003.md",
        "# ADR-003\n",
    ));

    try testing.expectError(error.FileNotFound, readDraftFile(testing.allocator, root, .rule, "adr/ADR-003.md"));

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expect(index.findDraftById(.rule, "adr/ADR-003.md") == null);
}

test "discardUnchangedModifyDraft: keeps modify draft with changed content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "adr/ADR-003.md",
        .current_path = "adr/ADR-003.md",
    }, "# ADR-003\n\nChanged.\n");

    try testing.expect(!try discardUnchangedModifyDraft(
        testing.allocator,
        root,
        .rule,
        "adr/ADR-003.md",
        "# ADR-003\n",
    ));

    const content = try readDraftFile(testing.allocator, root, .rule, "adr/ADR-003.md");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("# ADR-003\n\nChanged.\n", content);
}

test "discardUnchangedModifyDraft: ignores create draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .create,
        .draft_path = "adr/ADR-004.md",
    }, "# ADR-004\n");

    try testing.expect(!try discardUnchangedModifyDraft(
        testing.allocator,
        root,
        .rule,
        "adr/ADR-004.md",
        "# ADR-004\n",
    ));

    const content = try readDraftFile(testing.allocator, root, .rule, "adr/ADR-004.md");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("# ADR-004\n", content);
}

test "discardDraft: idempotent when draft is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try discardDraft(testing.allocator, root, .rule, "never/existed.md");
}

test "setDraftStatus: transitions draft to in_review and back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "x/Y.md",
        .current_path = "x/Y.md",
        .rule_id = "p-y",
    }, "draft body\n");

    try setDraftStatus(testing.allocator, root, .rule, "x/Y.md", .in_review);

    {
        var index = try loadIndex(testing.allocator, root);
        defer index.deinit(testing.allocator);
        const entry = index.findByCurrentPath(.rule, "x/Y.md").?;
        try testing.expectEqual(DraftStatus.in_review, entry.status);
    }

    try setDraftStatus(testing.allocator, root, .rule, "x/Y.md", .draft);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    const entry = index.findByCurrentPath(.rule, "x/Y.md").?;
    try testing.expectEqual(DraftStatus.draft, entry.status);
}

test "setDraftStatus: returns DraftNotFound for missing draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try testing.expectError(error.DraftNotFound, setDraftStatus(testing.allocator, root, .rule, "nope.md", .in_review));
}

test "transitionDraftStatus: only updates expected status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "x/Y.md",
        .current_path = "x/Y.md",
        .rule_id = "p-y",
    }, "draft body\n");

    try testing.expect(!try transitionDraftStatus(testing.allocator, root, .rule, "x/Y.md", .in_review, .applied));
    try setDraftStatus(testing.allocator, root, .rule, "x/Y.md", .in_review);
    try testing.expect(try transitionDraftStatus(testing.allocator, root, .rule, "x/Y.md", .in_review, .applied));

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    const entry = index.findByCurrentPath(.rule, "x/Y.md").?;
    try testing.expectEqual(DraftStatus.applied, entry.status);
}

test "reconcileDrafts: leaves matching base_hash untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const seed = "hello world\n";
    const seed_hash = util_hash.contentHash(seed);
    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "coding/A.md",
        .current_path = "coding/A.md",
        .rule_id = "p-a",
        .base_hash = seed_hash[0..],
    }, seed);

    try tmp.dir.makePath("cache/rule/coding");
    try writeFile(tmp.dir, "cache/rule/coding/A.md", seed);

    const cache_dir = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_dir);

    const summary = try reconcileDrafts(testing.allocator, root, cache_dir);
    try testing.expectEqual(@as(usize, 0), summary.conflicted);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(DraftStatus.draft, index.entries.items[0].status);
}

test "reconcileDrafts: marks conflicted when cache drifted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const seed = "v1 body\n";
    const seed_hash = util_hash.contentHash(seed);
    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "coding/A.md",
        .current_path = "coding/A.md",
        .rule_id = "p-a",
        .base_hash = seed_hash[0..],
    }, seed);

    try tmp.dir.makePath("cache/rule/coding");
    try writeFile(tmp.dir, "cache/rule/coding/A.md", "v2 body (someone else merged)\n");

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
        .category = .rule,
        .operation = .create,
        .draft_path = "coding/NEW.md",
    }, "brand new\n");

    const cache_dir = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_dir);

    const summary = try reconcileDrafts(testing.allocator, root, cache_dir);
    try testing.expectEqual(@as(usize, 0), summary.conflicted);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(DraftStatus.draft, index.entries.items[0].status);
}

test "reconcileDrafts: leaves terminal states sticky" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const seed = "merged body\n";
    const seed_hash = util_hash.contentHash(seed);
    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "coding/A.md",
        .current_path = "coding/A.md",
        .rule_id = "p-a",
        .base_hash = seed_hash[0..],
    }, seed);
    try setDraftStatus(testing.allocator, root, .rule, "coding/A.md", .applied);

    try tmp.dir.makePath("cache/rule/coding");
    try writeFile(tmp.dir, "cache/rule/coding/A.md", "totally different body\n");

    const cache_dir = try std.fs.path.join(testing.allocator, &.{ root, "cache" });
    defer testing.allocator.free(cache_dir);

    const summary = try reconcileDrafts(testing.allocator, root, cache_dir);
    try testing.expectEqual(@as(usize, 0), summary.conflicted);

    var index = try loadIndex(testing.allocator, root);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(DraftStatus.applied, index.entries.items[0].status);
}

test "index serialization: multiple entries survive round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try createDraft(testing.allocator, root, .{
        .category = .rule,
        .operation = .modify,
        .draft_path = "a/A.md",
        .current_path = "a/A.md",
        .rule_id = "p-a",
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
