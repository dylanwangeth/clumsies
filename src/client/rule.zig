//! Rule resolution engine. Resolves rules from the workspace cache (synced from Hub via
//! manifest) with draft overlay support. Handles discovery (listing by kind/group), content
//! loading (drafts override cache), and constraint parsing (extracting atomic tracking units
//! from rule markdown for the refer protocol).
const std = @import("std");
const testing = std.testing;
const util_hash = @import("clumsies_lib").util.hash;
const drafts = @import("drafts.zig");
const path_util = @import("clumsies_lib").util.path_util;

const MAX_FILE_SIZE = 10 * 1024 * 1024;

/// Strip file extension from a rule filename to get the display name.
fn displayNameFromFilename(filename: []const u8) []const u8 {
    const ext_idx = std.mem.lastIndexOfScalar(u8, filename, '.');
    return if (ext_idx) |idx| filename[0..idx] else filename;
}

pub const RuleKind = enum {
    rule,
    workflow,
    context,
};

pub const SetupPriority = enum(u8) {
    high,
    normal,
};

pub const RuleItem = struct {
    id: []const u8,
    kind: RuleKind,
    path: []const u8,
    name: []const u8,
    group: ?[]const u8,
    hash: []const u8,
    priority: SetupPriority,
    description: ?[]const u8 = null,
    has_draft: bool = false,
};

pub const KnownHash = struct {
    id: []const u8,
    hash: []const u8,
};

pub const LoadedRule = struct {
    id: []const u8,
    kind: RuleKind,
    path: []const u8,
    name: []const u8,
    group: ?[]const u8,
    hash: []const u8,
    changed: bool,
    content: ?[]const u8,
    has_draft: bool = false,
    draft_base_hash: ?[]const u8 = null,
};

pub const LoadResult = struct {
    items: std.ArrayList(LoadedRule) = .empty,

    pub fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| {
            allocator.free(item.id);
            allocator.free(item.path);
            allocator.free(item.name);
            if (item.group) |group| allocator.free(group);
            allocator.free(item.hash);
            if (item.content) |content| allocator.free(content);
            if (item.draft_base_hash) |bh| allocator.free(bh);
        }
        self.items.deinit(allocator);
    }
};

const ResolvedLoadContent = struct {
    hash: []const u8,
    changed: bool,
    content: ?[]const u8,

    fn deinit(self: *ResolvedLoadContent, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
        if (self.content) |content| allocator.free(content);
    }
};

fn priorityForKind(kind: RuleKind) SetupPriority {
    return switch (kind) {
        .rule, .workflow, .context => .normal,
    };
}

pub fn kindToString(kind: RuleKind) []const u8 {
    return switch (kind) {
        .rule => "rule",
        .workflow => "workflow",
        .context => "context",
    };
}

pub const MetaPromptResult = struct {
    content: ?[]const u8,
    hash: ?[]const u8,

    pub fn deinit(self: *MetaPromptResult, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.hash) |h| allocator.free(h);
    }
};

/// Load META_PROMPT.md from the workspace cache directory.
/// `ws_dir` is the workspace root (~/.clumsies/workspaces/{ws_id}).
/// MPF lives at `{ws_dir}/cache/META_PROMPT.md` — reserved paths
/// sit at the cache root rather than under the `rule/` namespace
/// so a future MPF rename does not reshuffle the rule tree.
/// If a draft exists for META_PROMPT, the draft content is returned
/// instead of the cached version — mirroring the draft resolution
/// that `loadRules` applies to rules and contexts.
pub fn loadMpf(allocator: std.mem.Allocator, ws_dir: []const u8, known_hash: ?[]const u8) !MetaPromptResult {
    var draft_index = try drafts.loadIndex(allocator, ws_dir);
    defer draft_index.deinit(allocator);

    const draft_entry = draft_index.findByCurrentPath(.meta_prompt, "META_PROMPT.md");

    if (draft_entry) |entry| {
        if (entry.operation == .delete) return .{ .content = null, .hash = null };
    }

    const content: []const u8 = if (draft_entry) |entry|
        try drafts.readDraftFile(allocator, ws_dir, .meta_prompt, entry.draft_path)
    else blk: {
        const mpf_path = try std.fs.path.join(allocator, &.{ ws_dir, "cache", "META_PROMPT.md" });
        defer allocator.free(mpf_path);
        const file = std.fs.openFileAbsolute(mpf_path, .{}) catch return .{ .content = null, .hash = null };
        defer file.close();
        var read_buf: [4096]u8 = undefined;
        var fr = std.fs.File.Reader.init(file, &read_buf);
        break :blk fr.interface.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024)) catch return .{ .content = null, .hash = null };
    };
    errdefer allocator.free(content);

    const hash = try util_hash.sha256HexAlloc(allocator, content);
    errdefer allocator.free(hash);

    if (known_hash) |kh| {
        if (std.mem.eql(u8, kh, hash)) {
            allocator.free(content);
            return .{ .content = null, .hash = hash };
        }
    }

    return .{ .content = content, .hash = hash };
}

pub const ManifestEntry = struct {
    path: []const u8,
    hash: []const u8,
    description: []const u8 = "",
};

/// Parsed local manifest. Both maps borrow strings from an arena owned by
/// this struct; deinit drops the arena and invalidates all keys/values.
pub const Manifest = struct {
    arena_state: *std.heap.ArenaAllocator,
    rules: std.StringHashMapUnmanaged(ManifestEntry) = .empty,
    context: std.StringHashMapUnmanaged(ManifestEntry) = .empty,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        self.arena_state.deinit();
        allocator.destroy(self.arena_state);
    }
};

/// Read `{ws_dir}/manifest.json` into an in-memory map. Returns an empty
/// manifest (no error) if the file does not exist — that is the expected
/// state before the first sync. Invalid JSON or a non-object top-level
/// value returns `InvalidManifest`. Malformed rules/context entries
/// inside an otherwise valid top-level object are silently skipped so a
/// single bad row doesn't block discovery of the rest.
pub fn loadManifest(allocator: std.mem.Allocator, ws_dir: []const u8) !Manifest {
    const arena_state = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena_state);
    arena_state.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();

    var manifest: Manifest = .{ .arena_state = arena_state };
    const arena = arena_state.allocator();

    const manifest_path = try std.fs.path.join(arena, &.{ ws_dir, "manifest.json" });

    const file = std.fs.openFileAbsolute(manifest_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return manifest,
        else => return err,
    };
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = try fr.interface.allocRemaining(arena, std.io.Limit.limited(4 * 1024 * 1024));

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{}) catch return error.InvalidManifest;
    if (parsed != .object) return error.InvalidManifest;

    if (parsed.object.get("rules")) |rules_val| {
        try parseManifestSection(arena, &manifest.rules, rules_val);
    }
    if (parsed.object.get("context")) |context_val| {
        try parseManifestSection(arena, &manifest.context, context_val);
    }

    return manifest;
}

fn parseManifestSection(
    arena: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(ManifestEntry),
    value: std.json.Value,
) !void {
    if (value != .object) return;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const obj = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };
        const path_str = if (obj.get("path")) |v| switch (v) {
            .string => |s| s,
            else => continue,
        } else continue;
        const hash_str = if (obj.get("hash")) |v| switch (v) {
            .string => |s| s,
            else => continue,
        } else continue;

        const desc_str = if (obj.get("description")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";

        try map.put(arena, entry.key_ptr.*, .{ .path = path_str, .hash = hash_str, .description = desc_str });
    }
}

fn freeRuleItem(allocator: std.mem.Allocator, item: RuleItem) void {
    allocator.free(item.id);
    allocator.free(item.path);
    allocator.free(item.name);
    if (item.group) |group| allocator.free(group);
    allocator.free(item.hash);
    if (item.description) |desc| allocator.free(desc);
}

pub fn deinitRuleItems(allocator: std.mem.Allocator, items: *std.ArrayList(RuleItem)) void {
    for (items.items) |item| freeRuleItem(allocator, item);
    items.deinit(allocator);
}

fn kindFromPath(path: []const u8) ?RuleKind {
    if (std.mem.eql(u8, path, "META_PROMPT.md")) return null;
    if (std.mem.eql(u8, path, "PIN.md")) return null;
    if (std.mem.startsWith(u8, path, "workflow/")) return .workflow;
    return .rule;
}

fn groupFromPath(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "META_PROMPT.md")) return null;
    if (std.mem.eql(u8, path, "PIN.md")) return null;
    const first_slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    if (std.mem.startsWith(u8, path, "workflow/")) {
        const after_kind = path[first_slash + 1 ..];
        const next_slash = std.mem.indexOfScalar(u8, after_kind, '/') orelse return null;
        return after_kind[0..next_slash];
    }
    return path[0..first_slash];
}

fn matchesGroup(item_group: []const u8, filter: []const u8) bool {
    if (std.mem.eql(u8, item_group, filter)) return true;
    if (std.mem.startsWith(u8, item_group, filter) and filter.len < item_group.len and item_group[filter.len] == '/') return true;
    return false;
}

fn matchesQuery(haystack: []const u8, query: []const u8) bool {
    var tokens = std.mem.splitAny(u8, query, " \t");
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        if (token.len > haystack.len) continue;
        var i: usize = 0;
        while (i + token.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + token.len], token)) return true;
        }
    }
    return false;
}

/// Discover rules and context available for memory.discover. Iterates the
/// local manifest, classifies each entry by path prefix or category, and
/// applies optional kind/group filters. Reserved paths (META_PROMPT.md) are
/// excluded. Context entries have kind = .context and group derived from
/// their path's first component.
///
/// Drafts are merged into the result: delete-drafts hide their manifest
/// entries, modify/rename drafts set has_draft = true, and create-drafts
/// (which have no manifest entry) are appended using local_temp_id as id.
pub fn discoverSearchable(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    kind_filter: ?RuleKind,
    group_filter: ?[]const u8,
    query_filter: ?[]const u8,
) !std.ArrayList(RuleItem) {
    var items: std.ArrayList(RuleItem) = .empty;
    errdefer deinitRuleItems(allocator, &items);

    var manifest = try loadManifest(allocator, ws_dir);
    defer manifest.deinit(allocator);

    var draft_index = try drafts.loadIndex(allocator, ws_dir);
    defer draft_index.deinit(allocator);

    var it = manifest.rules.iterator();
    while (it.next()) |entry| {
        const m_entry = entry.value_ptr.*;

        if (std.mem.eql(u8, m_entry.path, "META_PROMPT.md")) continue;

        const kind = kindFromPath(m_entry.path) orelse continue;
        if (kind_filter) |kf| {
            if (kf != kind) continue;
        }

        // Check for a delete draft — hide this entry
        const draft_entry = draft_index.findByCurrentPath(.rule, m_entry.path);
        if (draft_entry) |de| {
            if (de.operation == .delete) continue;
        }

        const group_slice = groupFromPath(m_entry.path);
        if (group_filter) |gf| {
            const g = group_slice orelse continue;
            if (!matchesGroup(g, gf)) continue;
        }

        if (query_filter) |q| {
            const trimmed = std.mem.trim(u8, q, " \t");
            if (trimmed.len == 0) {
                // empty/whitespace-only query is treated as no filter
            } else {
                const in_path = matchesQuery(m_entry.path, trimmed);
                const in_desc = m_entry.description.len > 0 and matchesQuery(m_entry.description, trimmed);
                if (!in_path and !in_desc) continue;
            }
        }

        const display_name = displayNameFromFilename(std.fs.path.basename(m_entry.path));

        const id_owned = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(id_owned);
        const path_owned = try allocator.dupe(u8, m_entry.path);
        errdefer allocator.free(path_owned);
        const name_owned = try allocator.dupe(u8, display_name);
        errdefer allocator.free(name_owned);
        const group_owned = if (group_slice) |g| try allocator.dupe(u8, g) else null;
        errdefer if (group_owned) |g| allocator.free(g);
        const hash_owned = try allocator.dupe(u8, m_entry.hash);
        errdefer allocator.free(hash_owned);
        const desc_owned = if (m_entry.description.len > 0) try allocator.dupe(u8, m_entry.description) else null;
        errdefer if (desc_owned) |d| allocator.free(d);

        try items.append(allocator, .{
            .id = id_owned,
            .kind = kind,
            .path = path_owned,
            .name = name_owned,
            .group = group_owned,
            .hash = hash_owned,
            .priority = priorityForKind(kind),
            .description = desc_owned,
            .has_draft = draft_entry != null,
        });
    }

    if (kind_filter == null or kind_filter.? == .context) {
        var ctx_it = manifest.context.iterator();
        while (ctx_it.next()) |entry| {
            const m_entry = entry.value_ptr.*;

            // Check for a delete draft — hide this entry
            const draft_entry = draft_index.findByCurrentPath(.context, m_entry.path);
            if (draft_entry) |de| {
                if (de.operation == .delete) continue;
            }

            const group_slice = groupFromPath(m_entry.path);
            if (group_filter) |gf| {
                const g = group_slice orelse continue;
                if (!matchesGroup(g, gf)) continue;
            }

            if (query_filter) |q| {
                const in_path = matchesQuery(m_entry.path, q);
                const in_desc = m_entry.description.len > 0 and matchesQuery(m_entry.description, q);
                if (!in_path and !in_desc) continue;
            }

            const display_name = displayNameFromFilename(std.fs.path.basename(m_entry.path));

            const id_owned = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(id_owned);
            const path_owned = try allocator.dupe(u8, m_entry.path);
            errdefer allocator.free(path_owned);
            const name_owned = try allocator.dupe(u8, display_name);
            errdefer allocator.free(name_owned);
            const group_owned = if (group_slice) |g| try allocator.dupe(u8, g) else null;
            errdefer if (group_owned) |g| allocator.free(g);
            const hash_owned = try allocator.dupe(u8, m_entry.hash);
            errdefer allocator.free(hash_owned);
            const ctx_desc_owned = if (m_entry.description.len > 0) try allocator.dupe(u8, m_entry.description) else null;
            errdefer if (ctx_desc_owned) |d| allocator.free(d);

            try items.append(allocator, .{
                .id = id_owned,
                .kind = .context,
                .path = path_owned,
                .name = name_owned,
                .group = group_owned,
                .hash = hash_owned,
                .priority = .normal,
                .description = ctx_desc_owned,
                .has_draft = draft_entry != null,
            });
        }
    }

    // Append create-only drafts (no corresponding manifest entry)
    for (draft_index.entries.items) |de| {
        if (de.operation != .create) continue;

        const kind: RuleKind = switch (de.category) {
            .context => .context,
            .rule => kindFromPath(de.draft_path) orelse continue,
            .meta_prompt => continue,
        };
        if (kind_filter) |kf| {
            if (kf != kind) continue;
        }

        // Use local_temp_id if available, otherwise fall back to draft_path as a stable identifier.
        const effective_id = de.local_temp_id orelse de.draft_path;

        const group_slice = groupFromPath(de.draft_path);
        if (group_filter) |gf| {
            const g = group_slice orelse continue;
            if (!matchesGroup(g, gf)) continue;
        }

        if (query_filter) |q| {
            const trimmed = std.mem.trim(u8, q, " \t");
            if (trimmed.len > 0) {
                const in_path = matchesQuery(de.draft_path, trimmed);
                const in_desc = if (de.description) |desc| matchesQuery(desc, trimmed) else false;
                if (!in_path and !in_desc) continue;
            }
        }

        const display_name = displayNameFromFilename(std.fs.path.basename(de.draft_path));

        const id_owned = try allocator.dupe(u8, effective_id);
        errdefer allocator.free(id_owned);
        const path_owned = try allocator.dupe(u8, de.draft_path);
        errdefer allocator.free(path_owned);
        const name_owned = try allocator.dupe(u8, display_name);
        errdefer allocator.free(name_owned);
        const group_owned = if (group_slice) |g| try allocator.dupe(u8, g) else null;
        errdefer if (group_owned) |g| allocator.free(g);
        const desc_owned = if (de.description) |desc| try allocator.dupe(u8, desc) else null;
        errdefer if (desc_owned) |d| allocator.free(d);

        try items.append(allocator, .{
            .id = id_owned,
            .kind = kind,
            .path = path_owned,
            .name = name_owned,
            .group = group_owned,
            .hash = try allocator.dupe(u8, ""),
            .priority = priorityForKind(kind),
            .description = desc_owned,
            .has_draft = true,
        });
    }

    std.mem.sort(RuleItem, items.items, {}, lessThanRuleItem);
    return items;
}

fn lessThanRuleItem(_: void, a: RuleItem, b: RuleItem) bool {
    const prio_order = std.math.order(@intFromEnum(a.priority), @intFromEnum(b.priority));
    if (prio_order != .eq) return prio_order == .lt;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// Load rule content by hub-issued rule_id. Resolves each id through
/// the local manifest, then consults drafts/index.json: an active draft
/// with operation != "delete" wins over the cache copy. Unknown ids return
/// `error.UnknownRuleId`. Drafts marked for deletion behave as NotFound.
pub fn loadRules(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    ids: []const []const u8,
    known: []const KnownHash,
) !LoadResult {
    var manifest = try loadManifest(allocator, ws_dir);
    defer manifest.deinit(allocator);

    var draft_index = try drafts.loadIndex(allocator, ws_dir);
    defer draft_index.deinit(allocator);

    var result: LoadResult = .{};
    errdefer result.deinit(allocator);

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(@constCast(k.*));
        seen.deinit();
    }

    for (ids) |id| {
        if (seen.contains(id)) continue;
        const seen_key = try allocator.dupe(u8, id);
        seen.put(seen_key, {}) catch |err| {
            allocator.free(seen_key);
            return err;
        };

        if (manifest.rules.get(id)) |m_entry| {
            const kind = kindFromPath(m_entry.path) orelse return error.UnknownRuleId;

            const known_hash = knownHashFor(id, known);
            const draft_entry = draft_index.findByCurrentPath(.rule, m_entry.path);
            if (draft_entry) |entry| {
                if (entry.operation == .delete) return error.UnknownRuleId;
            }

            var resolved = try resolveLoadContent(
                allocator,
                ws_dir,
                .rule,
                m_entry.path,
                m_entry.hash,
                known_hash,
                draft_entry,
            );
            errdefer resolved.deinit(allocator);

            const display_name = displayNameFromFilename(std.fs.path.basename(m_entry.path));
            const group_slice = groupFromPath(m_entry.path);

            const has_draft = draft_entry != null;
            const draft_base = if (draft_entry) |entry|
                if (entry.base_hash) |bh| try allocator.dupe(u8, bh) else null
            else
                null;
            errdefer if (draft_base) |bh| allocator.free(bh);

            try result.items.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .kind = kind,
                .path = try allocator.dupe(u8, m_entry.path),
                .name = try allocator.dupe(u8, display_name),
                .group = if (group_slice) |g| try allocator.dupe(u8, g) else null,
                .hash = resolved.hash,
                .changed = resolved.changed,
                .content = resolved.content,
                .has_draft = has_draft,
                .draft_base_hash = draft_base,
            });
        } else if (manifest.context.get(id)) |m_entry| {
            const known_hash = knownHashFor(id, known);
            const draft_entry = draft_index.findByCurrentPath(.context, m_entry.path);
            if (draft_entry) |entry| {
                if (entry.operation == .delete) return error.UnknownRuleId;
            }

            var resolved = try resolveLoadContent(
                allocator,
                ws_dir,
                .context,
                m_entry.path,
                m_entry.hash,
                known_hash,
                draft_entry,
            );
            errdefer resolved.deinit(allocator);

            const display_name = displayNameFromFilename(std.fs.path.basename(m_entry.path));
            const group_slice = groupFromPath(m_entry.path);

            const has_draft = draft_entry != null;
            const draft_base = if (draft_entry) |entry|
                if (entry.base_hash) |bh| try allocator.dupe(u8, bh) else null
            else
                null;
            errdefer if (draft_base) |bh| allocator.free(bh);

            try result.items.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .kind = .context,
                .path = try allocator.dupe(u8, m_entry.path),
                .name = try allocator.dupe(u8, display_name),
                .group = if (group_slice) |g| try allocator.dupe(u8, g) else null,
                .hash = resolved.hash,
                .changed = resolved.changed,
                .content = resolved.content,
                .has_draft = has_draft,
                .draft_base_hash = draft_base,
            });
        } else {
            // Fallback: try loading a create-draft by local_temp_id or draft_path
            const draft_entry = draft_index.findByLocalTempId(id) orelse
                draft_index.findCreateByDraftPath(id) orelse
                return error.UnknownRuleId;
            if (draft_entry.operation != .create) return error.UnknownRuleId;

            switch (draft_entry.category) {
                .meta_prompt => return error.UnknownRuleId,
                else => {},
            }

            const content = try drafts.readDraftFile(
                allocator,
                ws_dir,
                draft_entry.category,
                draft_entry.draft_path,
            );
            errdefer allocator.free(content);

            const effective_hash = try util_hash.sha256HexAlloc(allocator, content);
            errdefer allocator.free(effective_hash);

            const kind: RuleKind = if (draft_entry.category == .context)
                .context
            else
                kindFromPath(draft_entry.draft_path) orelse return error.UnknownRuleId;
            const display_name = displayNameFromFilename(
                std.fs.path.basename(draft_entry.draft_path),
            );
            const group_slice = groupFromPath(draft_entry.draft_path);

            try result.items.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .kind = kind,
                .path = try allocator.dupe(u8, draft_entry.draft_path),
                .name = try allocator.dupe(u8, display_name),
                .group = if (group_slice) |g| try allocator.dupe(u8, g) else null,
                .hash = effective_hash,
                .changed = true,
                .content = content,
                .has_draft = true,
                .draft_base_hash = null,
            });
        }
    }

    return result;
}

fn resolveLoadContent(
    allocator: std.mem.Allocator,
    ws_dir: []const u8,
    category: drafts.DraftCategory,
    cache_path: []const u8,
    manifest_hash: []const u8,
    known_hash: ?[]const u8,
    draft_entry: ?*const drafts.DraftEntry,
) !ResolvedLoadContent {
    if (draft_entry) |entry| {
        const draft_content = try drafts.readDraftFile(allocator, ws_dir, category, entry.draft_path);
        const effective_hash = util_hash.sha256HexAlloc(allocator, draft_content) catch |err| {
            allocator.free(draft_content);
            return err;
        };
        errdefer allocator.free(effective_hash);

        const changed = known_hash == null or !std.mem.eql(u8, known_hash.?, effective_hash);
        if (changed) {
            return .{
                .hash = effective_hash,
                .changed = true,
                .content = draft_content,
            };
        }

        allocator.free(draft_content);
        return .{
            .hash = effective_hash,
            .changed = false,
            .content = null,
        };
    }

    const effective_hash = try allocator.dupe(u8, manifest_hash);
    errdefer allocator.free(effective_hash);

    const changed = known_hash == null or !std.mem.eql(u8, known_hash.?, effective_hash);
    const content = if (changed)
        switch (category) {
            .rule => try readCacheFileAlloc(allocator, ws_dir, cache_path),
            .context => try readContextCacheFile(allocator, ws_dir, cache_path),
            .meta_prompt => unreachable,
        }
    else
        null;
    errdefer if (content) |owned| allocator.free(owned);

    return .{
        .hash = effective_hash,
        .changed = changed,
        .content = content,
    };
}

fn readCacheFileAlloc(allocator: std.mem.Allocator, ws_dir: []const u8, rel_path: []const u8) ![]const u8 {
    if (!path_util.isSafeRelative(rel_path)) return error.UnsafeCachePath;
    return readRuleCacheFile(allocator, ws_dir, rel_path);
}

pub fn readRuleCacheFile(allocator: std.mem.Allocator, ws_dir: []const u8, rel_path: []const u8) ![]const u8 {
    const abs_path = try std.fs.path.join(allocator, &.{ ws_dir, "cache", "rule", rel_path });
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    return try fr.interface.allocRemaining(allocator, std.io.Limit.limited(MAX_FILE_SIZE));
}

pub fn readContextCacheFile(allocator: std.mem.Allocator, ws_dir: []const u8, rel_path: []const u8) ![]const u8 {
    if (!path_util.isSafeRelative(rel_path)) return error.UnsafeCachePath;

    const abs_path = try std.fs.path.join(allocator, &.{ ws_dir, "cache", "context", rel_path });
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    return try fr.interface.allocRemaining(allocator, std.io.Limit.limited(MAX_FILE_SIZE));
}

fn knownHashFor(id: []const u8, known: []const KnownHash) ?[]const u8 {
    for (known) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry.hash;
    }
    return null;
}

pub const ParsedConstraint = struct {
    id: []const u8,
    name: []const u8,
    text: []const u8,
    text_hash: []const u8,
};

pub const ValidateResult = struct {
    valid: bool,
    constraints: std.ArrayList(ParsedConstraint),
    issues: std.ArrayList([]const u8),

    pub fn deinit(self: *ValidateResult, allocator: std.mem.Allocator) void {
        for (self.constraints.items) |c| {
            allocator.free(c.id);
            allocator.free(c.name);
            allocator.free(c.text);
            allocator.free(c.text_hash);
        }
        self.constraints.deinit(allocator);
        for (self.issues.items) |issue| {
            allocator.free(issue);
        }
        self.issues.deinit(allocator);
    }
};

fn computeTextHash(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(text);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    var hex: [64]u8 = undefined;
    const encoding = @import("clumsies_lib").util.encoding;
    encoding.hexEncode(&hash, &hex);
    return try allocator.dupe(u8, &hex);
}

/// Parse constraints from rule content according to s2 format standard.
/// Rules: # = title (skip), ## = constraint region, list items within region
/// are individual constraints, otherwise the whole region is one constraint.
pub fn parseConstraints(allocator: std.mem.Allocator, content: []const u8) !ValidateResult {
    var constraints: std.ArrayList(ParsedConstraint) = .empty;
    errdefer {
        for (constraints.items) |c| {
            allocator.free(c.id);
            allocator.free(c.name);
            allocator.free(c.text);
            allocator.free(c.text_hash);
        }
        constraints.deinit(allocator);
    }
    var issues: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (issues.items) |i| allocator.free(i);
        issues.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;
    var constraint_counter: usize = 0;

    var in_region = false;
    var region_start: usize = 0;
    var region_has_list = false;
    var region_heading: []const u8 = "";

    while (lines.next()) |line| {
        line_num += 1;
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "# ") and !std.mem.startsWith(u8, trimmed, "## ")) {
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "## ")) {
            const heading_text = trimmed[3..];

            const is_steps = std.ascii.eqlIgnoreCase(heading_text, "Steps") or
                std.ascii.eqlIgnoreCase(heading_text, "steps");
            const is_examples = std.ascii.eqlIgnoreCase(heading_text, "Examples") or
                std.ascii.eqlIgnoreCase(heading_text, "examples") or
                std.ascii.eqlIgnoreCase(heading_text, "Example") or
                std.ascii.eqlIgnoreCase(heading_text, "example");

            if (in_region and !region_has_list) {
                try appendParsedConstraint(allocator, &constraints, &constraint_counter, region_heading, region_heading);
            }

            if (is_steps or is_examples) {
                in_region = false;
                continue;
            }

            in_region = true;
            region_start = line_num;
            region_has_list = false;
            region_heading = trimmed;
            continue;
        }

        if (in_region and (std.mem.startsWith(u8, trimmed, "- ") or isOrderedListItem(trimmed))) {
            if (std.mem.startsWith(u8, trimmed, "- **理由**") or
                std.mem.startsWith(u8, trimmed, "- **示例**"))
                continue;

            region_has_list = true;
            try appendParsedConstraint(allocator, &constraints, &constraint_counter, trimmed, region_heading);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "**理由**") or
            std.mem.startsWith(u8, trimmed, "**示例**") or
            std.mem.startsWith(u8, trimmed, "✅") or
            std.mem.startsWith(u8, trimmed, "❌"))
        {
            continue;
        }
    }

    if (in_region and !region_has_list) {
        try appendParsedConstraint(allocator, &constraints, &constraint_counter, region_heading, region_heading);
    }

    if (constraint_counter == 0 and content.len > 0) {
        try appendParsedConstraint(allocator, &constraints, &constraint_counter, content, content);
    }

    if (constraint_counter == 0) {
        try issues.append(allocator, try allocator.dupe(u8, "File contains no parseable constraints"));
    }

    return .{
        .valid = issues.items.len == 0,
        .constraints = constraints,
        .issues = issues,
    };
}

fn appendParsedConstraint(
    allocator: std.mem.Allocator,
    constraints: *std.ArrayList(ParsedConstraint),
    constraint_counter: *usize,
    source: []const u8,
    name_source: []const u8,
) !void {
    constraint_counter.* += 1;
    const id = try std.fmt.allocPrint(allocator, "c-{d}", .{constraint_counter.*});
    errdefer allocator.free(id);

    const name = try allocator.dupe(u8, constraintDisplayText(name_source));
    errdefer allocator.free(name);

    const text = try allocator.dupe(u8, constraintDisplayText(source));
    errdefer allocator.free(text);

    const th = try computeTextHash(allocator, source);
    errdefer allocator.free(th);

    try constraints.append(allocator, .{
        .id = id,
        .name = name,
        .text = text,
        .text_hash = th,
    });
}

fn constraintDisplayText(source: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "## ")) {
        return std.mem.trim(u8, trimmed[3..], " \t");
    }
    if (std.mem.startsWith(u8, trimmed, "- ")) {
        return std.mem.trim(u8, trimmed[2..], " \t");
    }
    if (orderedListMarkerEnd(trimmed)) |end| {
        return std.mem.trim(u8, trimmed[end..], " \t");
    }
    return trimmed;
}

fn orderedListMarkerEnd(line: []const u8) ?usize {
    var idx: usize = 0;
    while (idx < line.len and std.ascii.isDigit(line[idx])) : (idx += 1) {}
    if (idx == 0 or idx >= line.len or line[idx] != '.') return null;
    idx += 1;
    if (idx < line.len and line[idx] == ' ') idx += 1;
    return idx;
}

fn isOrderedListItem(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == 0 or i >= line.len) return false;
    return line[i] == '.' and i + 1 < line.len and line[i + 1] == ' ';
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

fn writeTestManifest(dir: std.fs.Dir, json: []const u8) !void {
    try writeFile(dir, "manifest.json", json);
}

test "loadManifest: parses rules and context entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestManifest(tmp.dir,
        \\{
        \\  "revision": 7,
        \\  "rules": {
        \\    "p-1": {"path": "coding/STYLE.md", "hash": "sha256:abc"},
        \\    "p-2": {"path": "workflow/cmd/COMMIT.md", "hash": "sha256:def"}
        \\  },
        \\  "context": {
        \\    "c-1": {"path": "spec/API.md", "hash": "sha256:xyz"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var manifest = try loadManifest(testing.allocator, root);
    defer manifest.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), manifest.rules.count());
    try testing.expectEqual(@as(usize, 1), manifest.context.count());

    const p1 = manifest.rules.get("p-1").?;
    try testing.expectEqualStrings("coding/STYLE.md", p1.path);
    try testing.expectEqualStrings("sha256:abc", p1.hash);

    const c1 = manifest.context.get("c-1").?;
    try testing.expectEqualStrings("spec/API.md", c1.path);
}

test "loadManifest: missing file returns empty manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var manifest = try loadManifest(testing.allocator, root);
    defer manifest.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), manifest.rules.count());
    try testing.expectEqual(@as(usize, 0), manifest.context.count());
}

test "discoverSearchable: returns hub rule_ids classified by path prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule/pedagogy");
    try tmp.dir.makePath("cache/rule/coding");
    try tmp.dir.makePath("cache/rule/workflow");
    try writeFile(tmp.dir, "cache/rule/pedagogy/TEACHING.md", "teaching");
    try writeFile(tmp.dir, "cache/rule/coding/STYLE.md", "style");
    try writeFile(tmp.dir, "cache/rule/workflow/COMMIT.md", "commit");

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {
        \\    "p-teach": {"path": "pedagogy/TEACHING.md", "hash": "sha256:1"},
        \\    "p-style": {"path": "coding/STYLE.md", "hash": "sha256:2"},
        \\    "p-commit": {"path": "workflow/COMMIT.md", "hash": "sha256:3"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var items = try discoverSearchable(testing.allocator, root, null, null, null);
    defer deinitRuleItems(testing.allocator, &items);

    try testing.expectEqual(@as(usize, 3), items.items.len);

    var found_teach = false;
    var found_style = false;
    var found_commit = false;
    for (items.items) |item| {
        if (std.mem.eql(u8, item.id, "p-teach")) {
            found_teach = true;
            try testing.expectEqual(RuleKind.rule, item.kind);
            try testing.expectEqualStrings("pedagogy/TEACHING.md", item.path);
            try testing.expectEqualStrings("pedagogy", item.group.?);
        }
        if (std.mem.eql(u8, item.id, "p-style")) {
            found_style = true;
            try testing.expectEqual(RuleKind.rule, item.kind);
            try testing.expectEqualStrings("coding/STYLE.md", item.path);
            try testing.expectEqualStrings("coding", item.group.?);
        }
        if (std.mem.eql(u8, item.id, "p-commit")) {
            found_commit = true;
            try testing.expectEqual(RuleKind.workflow, item.kind);
            try testing.expect(item.group == null);
        }
    }
    try testing.expect(found_teach);
    try testing.expect(found_style);
    try testing.expect(found_commit);

    var coding_filtered = try discoverSearchable(testing.allocator, root, null, "coding", null);
    defer deinitRuleItems(testing.allocator, &coding_filtered);
    try testing.expectEqual(@as(usize, 1), coding_filtered.items.len);
    try testing.expectEqualStrings("p-style", coding_filtered.items[0].id);
}

test "discoverSearchable: kind filter narrows results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {
        \\    "p-style": {"path": "coding/STYLE.md", "hash": "sha256:1"},
        \\    "p-commit": {"path": "workflow/cmd/COMMIT.md", "hash": "sha256:2"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var rules = try discoverSearchable(testing.allocator, root, .rule, null, null);
    defer deinitRuleItems(testing.allocator, &rules);

    try testing.expectEqual(@as(usize, 1), rules.items.len);
    try testing.expectEqualStrings("p-style", rules.items[0].id);
}

test "discoverSearchable: group filter matches first path component" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {
        \\    "p-1": {"path": "coding/STYLE.md", "hash": "sha256:1"},
        \\    "p-2": {"path": "zig/NAMING.md", "hash": "sha256:2"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var zig_rules = try discoverSearchable(testing.allocator, root, .rule, "zig", null);
    defer deinitRuleItems(testing.allocator, &zig_rules);

    try testing.expectEqual(@as(usize, 1), zig_rules.items.len);
    try testing.expectEqualStrings("p-2", zig_rules.items[0].id);
}

test "discoverSearchable: META_PROMPT.md is excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {
        \\    "p-mpf": {"path": "META_PROMPT.md", "hash": "sha256:abc"},
        \\    "p-style": {"path": "coding/STYLE.md", "hash": "sha256:1"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var items = try discoverSearchable(testing.allocator, root, null, null, null);
    defer deinitRuleItems(testing.allocator, &items);

    try testing.expectEqual(@as(usize, 1), items.items.len);
    try testing.expectEqualStrings("p-style", items.items[0].id);
}

test "loadRules: looks up by hub rule_id and reads cache file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule/coding");
    try writeFile(tmp.dir, "cache/rule/coding/STYLE.md", "style content");

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {
        \\    "p-style": {"path": "coding/STYLE.md", "hash": "sha256:zzz"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try loadRules(testing.allocator, root, &.{"p-style"}, &.{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.items.items.len);
    try testing.expectEqualStrings("p-style", result.items.items[0].id);
    try testing.expect(result.items.items[0].changed);
    try testing.expectEqualStrings("style content", result.items.items[0].content.?);
}

test "loadRules: known hash matches returns delta with no content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule/coding");
    try writeFile(tmp.dir, "cache/rule/coding/STYLE.md", "style content");

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {
        \\    "p-style": {"path": "coding/STYLE.md", "hash": "sha256:zzz"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const known = [_]KnownHash{.{ .id = "p-style", .hash = "sha256:zzz" }};
    var result = try loadRules(testing.allocator, root, &.{"p-style"}, &known);
    defer result.deinit(testing.allocator);

    try testing.expect(!result.items.items[0].changed);
    try testing.expect(result.items.items[0].content == null);
}

test "loadRules: unknown id returns UnknownRuleId" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestManifest(tmp.dir,
        \\{"rules": {}}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try testing.expectError(error.UnknownRuleId, loadRules(testing.allocator, root, &.{"p-missing"}, &.{}));
}

test "loadRules: context id reads from cache/context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/context/spec");
    try writeFile(tmp.dir, "cache/context/spec/API.md", "api spec content");

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {},
        \\  "context": {
        \\    "c-api": {"path": "spec/API.md", "hash": "sha256:abc"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try loadRules(testing.allocator, root, &.{"c-api"}, &.{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.items.items.len);
    try testing.expectEqualStrings("c-api", result.items.items[0].id);
    try testing.expectEqual(RuleKind.context, result.items.items[0].kind);
    try testing.expect(result.items.items[0].changed);
    try testing.expectEqualStrings("api spec content", result.items.items[0].content.?);
}

test "loadRules: mixed rule and context ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule/coding");
    try writeFile(tmp.dir, "cache/rule/coding/STYLE.md", "style");
    try tmp.dir.makePath("cache/context/spec");
    try writeFile(tmp.dir, "cache/context/spec/API.md", "api");

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {
        \\    "p-style": {"path": "coding/STYLE.md", "hash": "sha256:aaa"}
        \\  },
        \\  "context": {
        \\    "c-api": {"path": "spec/API.md", "hash": "sha256:bbb"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try loadRules(testing.allocator, root, &.{ "p-style", "c-api" }, &.{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.items.items.len);
    try testing.expectEqualStrings("p-style", result.items.items[0].id);
    try testing.expectEqual(RuleKind.rule, result.items.items[0].kind);
    try testing.expectEqualStrings("c-api", result.items.items[1].id);
    try testing.expectEqual(RuleKind.context, result.items.items[1].kind);
}

test "loadRules: draft content overrides cache when indexed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule/coding");
    try writeFile(tmp.dir, "cache/rule/coding/STYLE.md", "cache content");

    try tmp.dir.makePath("drafts/rule/coding");
    try writeFile(tmp.dir, "drafts/rule/coding/STYLE.md", "draft override");
    try writeFile(tmp.dir, "drafts/index.json",
        \\{
        \\  "drafts": [
        \\    {
        \\      "category": "rule",
        \\      "rule_id": "p-style",
        \\      "current_path": "coding/STYLE.md",
        \\      "draft_path": "coding/STYLE.md",
        \\      "operation": "modify",
        \\      "base_hash": "sha256:original",
        \\      "status": "editing"
        \\    }
        \\  ]
        \\}
    );

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {
        \\    "p-style": {"path": "coding/STYLE.md", "hash": "sha256:zzz"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try loadRules(testing.allocator, root, &.{"p-style"}, &.{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.items.items.len);
    const item = result.items.items[0];
    try testing.expect(item.has_draft);
    try testing.expectEqualStrings("sha256:original", item.draft_base_hash.?);
    try testing.expectEqualStrings("draft override", item.content.?);
}

test "loadRules: rule draft change ignores matching manifest known hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule/coding");
    try writeFile(tmp.dir, "cache/rule/coding/STYLE.md", "cache content");

    try tmp.dir.makePath("drafts/rule/coding");
    try writeFile(tmp.dir, "drafts/rule/coding/STYLE.md", "draft override");
    try writeFile(tmp.dir, "drafts/index.json",
        \\{
        \\  "drafts": [
        \\    {
        \\      "category": "rule",
        \\      "rule_id": "p-style",
        \\      "current_path": "coding/STYLE.md",
        \\      "draft_path": "coding/STYLE.md",
        \\      "operation": "modify",
        \\      "base_hash": "sha256:manifest",
        \\      "status": "editing"
        \\    }
        \\  ]
        \\}
    );

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {
        \\    "p-style": {"path": "coding/STYLE.md", "hash": "sha256:manifest"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const known = [_]KnownHash{.{ .id = "p-style", .hash = "sha256:manifest" }};
    var result = try loadRules(testing.allocator, root, &.{"p-style"}, &known);
    defer result.deinit(testing.allocator);

    const item = result.items.items[0];
    try testing.expect(item.changed);
    try testing.expectEqualStrings("draft override", item.content.?);
    try testing.expect(!std.mem.eql(u8, "sha256:manifest", item.hash));

    const known_draft = [_]KnownHash{.{ .id = "p-style", .hash = item.hash }};
    var delta = try loadRules(testing.allocator, root, &.{"p-style"}, &known_draft);
    defer delta.deinit(testing.allocator);

    try testing.expect(!delta.items.items[0].changed);
    try testing.expect(delta.items.items[0].content == null);
    try testing.expectEqualStrings(item.hash, delta.items.items[0].hash);
}

test "loadRules: context draft change ignores matching manifest known hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/context/spec");
    try writeFile(tmp.dir, "cache/context/spec/API.md", "cache api");

    try tmp.dir.makePath("drafts/context/spec");
    try writeFile(tmp.dir, "drafts/context/spec/API.md", "draft api");
    try writeFile(tmp.dir, "drafts/index.json",
        \\{
        \\  "drafts": [
        \\    {
        \\      "category": "context",
        \\      "context_id": "c-api",
        \\      "current_path": "spec/API.md",
        \\      "draft_path": "spec/API.md",
        \\      "operation": "modify",
        \\      "base_hash": "sha256:manifest",
        \\      "status": "editing"
        \\    }
        \\  ]
        \\}
    );

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {},
        \\  "context": {
        \\    "c-api": {"path": "spec/API.md", "hash": "sha256:manifest"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    const known = [_]KnownHash{.{ .id = "c-api", .hash = "sha256:manifest" }};
    var result = try loadRules(testing.allocator, root, &.{"c-api"}, &known);
    defer result.deinit(testing.allocator);

    const item = result.items.items[0];
    try testing.expectEqual(RuleKind.context, item.kind);
    try testing.expect(item.changed);
    try testing.expectEqualStrings("draft api", item.content.?);
    try testing.expect(!std.mem.eql(u8, "sha256:manifest", item.hash));
}

test "loadRules: draft marked delete behaves as UnknownRuleId" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule/coding");
    try writeFile(tmp.dir, "cache/rule/coding/STYLE.md", "cache content");

    try tmp.dir.makePath("drafts");
    try writeFile(tmp.dir, "drafts/index.json",
        \\{
        \\  "drafts": [
        \\    {
        \\      "category": "rule",
        \\      "rule_id": "p-style",
        \\      "current_path": "coding/STYLE.md",
        \\      "draft_path": "coding/STYLE.md",
        \\      "operation": "delete",
        \\      "base_hash": "sha256:original",
        \\      "status": "editing"
        \\    }
        \\  ]
        \\}
    );

    try writeTestManifest(tmp.dir,
        \\{
        \\  "rules": {
        \\    "p-style": {"path": "coding/STYLE.md", "hash": "sha256:zzz"}
        \\  }
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try testing.expectError(error.UnknownRuleId, loadRules(testing.allocator, root, &.{"p-style"}, &.{}));
}

test "loadMpf: returns content and hash from cache subdirectory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache");
    try writeFile(tmp.dir, "cache/META_PROMPT.md", "bootstrap rules");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try loadMpf(testing.allocator, root, null);
    defer result.deinit(testing.allocator);

    try testing.expect(result.content != null);
    try testing.expectEqualStrings("bootstrap rules", result.content.?);
    try testing.expect(result.hash != null);
}

test "loadMpf: delta when hash matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache");
    try writeFile(tmp.dir, "cache/META_PROMPT.md", "bootstrap rules");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var first = try loadMpf(testing.allocator, root, null);
    const hash = try testing.allocator.dupe(u8, first.hash.?);
    defer testing.allocator.free(hash);
    first.deinit(testing.allocator);

    var second = try loadMpf(testing.allocator, root, hash);
    defer second.deinit(testing.allocator);

    try testing.expect(second.content == null);
    try testing.expect(second.hash != null);
}

test "loadMpf: returns null when file missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try loadMpf(testing.allocator, root, null);
    defer result.deinit(testing.allocator);

    try testing.expect(result.content == null);
    try testing.expect(result.hash == null);
}

test "loadMpf: draft content overrides cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache");
    try writeFile(tmp.dir, "cache/META_PROMPT.md", "cached mpf");

    try tmp.dir.makePath("drafts/meta_prompt");
    try writeFile(tmp.dir, "drafts/meta_prompt/META_PROMPT.md", "draft mpf");
    try tmp.dir.makePath("drafts");
    try writeFile(tmp.dir, "drafts/index.json",
        \\{
        \\  "drafts": [
        \\    {
        \\      "category": "meta_prompt",
        \\      "current_path": "META_PROMPT.md",
        \\      "draft_path": "META_PROMPT.md",
        \\      "operation": "modify",
        \\      "status": "editing"
        \\    }
        \\  ]
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try loadMpf(testing.allocator, root, null);
    defer result.deinit(testing.allocator);

    try testing.expect(result.content != null);
    try testing.expectEqualStrings("draft mpf", result.content.?);
    try testing.expect(result.hash != null);
}

test "loadMpf: delete draft makes mpf appear absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache");
    try writeFile(tmp.dir, "cache/META_PROMPT.md", "cached mpf");

    try tmp.dir.makePath("drafts");
    try writeFile(tmp.dir, "drafts/index.json",
        \\{
        \\  "drafts": [
        \\    {
        \\      "category": "meta_prompt",
        \\      "current_path": "META_PROMPT.md",
        \\      "draft_path": "META_PROMPT.md",
        \\      "operation": "delete",
        \\      "status": "editing"
        \\    }
        \\  ]
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try loadMpf(testing.allocator, root, null);
    defer result.deinit(testing.allocator);

    try testing.expect(result.content == null);
    try testing.expect(result.hash == null);
}

test "loadMpf: delta works with draft content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache");
    try writeFile(tmp.dir, "cache/META_PROMPT.md", "cached mpf");

    try tmp.dir.makePath("drafts/meta_prompt");
    try writeFile(tmp.dir, "drafts/meta_prompt/META_PROMPT.md", "draft mpf");
    try tmp.dir.makePath("drafts");
    try writeFile(tmp.dir, "drafts/index.json",
        \\{
        \\  "drafts": [
        \\    {
        \\      "category": "meta_prompt",
        \\      "current_path": "META_PROMPT.md",
        \\      "draft_path": "META_PROMPT.md",
        \\      "operation": "modify",
        \\      "status": "editing"
        \\    }
        \\  ]
        \\}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var first = try loadMpf(testing.allocator, root, null);
    const hash = try testing.allocator.dupe(u8, first.hash.?);
    defer testing.allocator.free(hash);
    first.deinit(testing.allocator);

    var second = try loadMpf(testing.allocator, root, hash);
    defer second.deinit(testing.allocator);

    try testing.expect(second.content == null);
    try testing.expect(second.hash != null);
    try testing.expectEqualStrings(hash, second.hash.?);
}

test "parseConstraints: list items become individual constraints" {
    const content =
        \\# Code Style
        \\
        \\## Naming
        \\
        \\- Use snake_case for functions
        \\- Use PascalCase for types
        \\
        \\## Forbidden
        \\
        \\- No Hungarian notation
        \\- No single-letter names
    ;
    var result = try parseConstraints(testing.allocator, content);
    defer result.deinit(testing.allocator);

    try testing.expect(result.valid);
    try testing.expectEqual(@as(usize, 4), result.constraints.items.len);
    try testing.expectEqualStrings("c-1", result.constraints.items[0].id);
    try testing.expectEqualStrings("Naming", result.constraints.items[0].name);
    try testing.expectEqualStrings("Use snake_case for functions", result.constraints.items[0].text);
    try testing.expectEqualStrings("c-4", result.constraints.items[3].id);
    try testing.expectEqualStrings("Forbidden", result.constraints.items[3].name);
}

test "parseConstraints: region without list is single constraint" {
    const content =
        \\# My Rule
        \\
        \\## Core principle
        \\
        \\Write code that is easy to read.
        \\Prefer clarity over cleverness.
    ;
    var result = try parseConstraints(testing.allocator, content);
    defer result.deinit(testing.allocator);

    try testing.expect(result.valid);
    try testing.expectEqual(@as(usize, 1), result.constraints.items.len);
    try testing.expectEqualStrings("Core principle", result.constraints.items[0].name);
    try testing.expectEqualStrings("Core principle", result.constraints.items[0].text);
}

test "parseConstraints: no headings no lists is one constraint" {
    const content = "Always use English in code comments.";
    var result = try parseConstraints(testing.allocator, content);
    defer result.deinit(testing.allocator);

    try testing.expect(result.valid);
    try testing.expectEqual(@as(usize, 1), result.constraints.items.len);
    try testing.expectEqualStrings("c-1", result.constraints.items[0].id);
    try testing.expectEqualStrings("Always use English in code comments.", result.constraints.items[0].name);
    try testing.expectEqualStrings("Always use English in code comments.", result.constraints.items[0].text);
}

test "parseConstraints: empty content" {
    var result = try parseConstraints(testing.allocator, "");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.valid);
    try testing.expectEqual(@as(usize, 0), result.constraints.items.len);
    try testing.expectEqual(@as(usize, 1), result.issues.items.len);
}

test "matchesQuery: single token matches substring" {
    try testing.expect(matchesQuery("zig/ZIG_STYLE.md", "style"));
    try testing.expect(matchesQuery("zig/ZIG_STYLE.md", "ZIG"));
    try testing.expect(!matchesQuery("zig/ZIG_STYLE.md", "python"));
}

test "matchesQuery: multi-token query matches any token" {
    try testing.expect(matchesQuery("zig/ZIG_STYLE.md", "zig style"));
    try testing.expect(matchesQuery("coding/STYLE.md", "zig style"));
    try testing.expect(!matchesQuery("coding/STYLE.md", "zig python"));
}

test "matchesQuery: empty or whitespace query matches nothing" {
    try testing.expect(!matchesQuery("any/path.md", ""));
    try testing.expect(!matchesQuery("any/path.md", "   "));
}
