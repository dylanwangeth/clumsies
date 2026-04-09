const std = @import("std");
const testing = std.testing;
const prompt = @import("prompt.zig");

pub const PromptKind = enum {
    rule,
    workflow,
    context,
};

pub const SetupPriority = enum(u8) {
    high,
    normal,
};

pub const PromptItem = struct {
    id: []const u8,
    kind: PromptKind,
    path: []const u8,
    name: []const u8,
    group: ?[]const u8,
    hash: []const u8,
    priority: SetupPriority,
};

pub const KnownHash = struct {
    id: []const u8,
    hash: []const u8,
};

pub const LoadedPrompt = struct {
    id: []const u8,
    kind: PromptKind,
    path: []const u8,
    name: []const u8,
    group: ?[]const u8,
    hash: []const u8,
    changed: bool,
    content: ?[]const u8,
};

pub const LoadResult = struct {
    items: std.ArrayList(LoadedPrompt) = .empty,

    pub fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
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

// Kind directory mapping

const kind_dirs = [_]struct { dir: []const u8, kind: PromptKind }{
    .{ .dir = "rule", .kind = .rule },
    .{ .dir = "workflow", .kind = .workflow },
    .{ .dir = "context", .kind = .context },
};

fn priorityForKind(kind: PromptKind) SetupPriority {
    return switch (kind) {
        .rule, .workflow, .context => .normal,
    };
}

pub fn kindToString(kind: PromptKind) []const u8 {
    return switch (kind) {
        .rule => "rule",
        .workflow => "workflow",
        .context => "context",
    };
}

pub const MpfResult = struct {
    content: ?[]const u8,
    hash: ?[]const u8,

    pub fn deinit(self: *MpfResult, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.hash) |h| allocator.free(h);
    }
};

pub fn loadMpf(allocator: std.mem.Allocator, workspace_root: []const u8, known_hash: ?[]const u8) !MpfResult {
    const mpf_path = try std.fs.path.join(allocator, &.{ workspace_root, "META_PROMPT.md" });
    defer allocator.free(mpf_path);

    const file = std.fs.openFileAbsolute(mpf_path, .{}) catch return .{ .content = null, .hash = null };
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = fr.interface.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024)) catch return .{ .content = null, .hash = null };
    errdefer allocator.free(content);

    const hash = try prompt.hashContentHexAlloc(allocator, content);
    errdefer allocator.free(hash);

    if (known_hash) |kh| {
        if (std.mem.eql(u8, kh, hash)) {
            allocator.free(content);
            return .{ .content = null, .hash = hash };
        }
    }

    return .{ .content = content, .hash = hash };
}

// Public API

fn freePromptItem(allocator: std.mem.Allocator, item: PromptItem) void {
    allocator.free(item.id);
    allocator.free(item.path);
    allocator.free(item.name);
    if (item.group) |group| allocator.free(group);
    allocator.free(item.hash);
}

pub fn deinitPromptItems(allocator: std.mem.Allocator, items: *std.ArrayList(PromptItem)) void {
    for (items.items) |item| freePromptItem(allocator, item);
    items.deinit(allocator);
}

/// Discover all prompts in the workspace cache directory, organized by kind.
pub fn discoverAll(allocator: std.mem.Allocator, workspace_root: []const u8) !std.ArrayList(PromptItem) {
    var items: std.ArrayList(PromptItem) = .empty;
    errdefer deinitPromptItems(allocator, &items);

    const prompts_root = workspace_root;

    for (kind_dirs) |kd| {
        try scanKindDirectory(allocator, prompts_root, kd.dir, kd.kind, &items);
    }

    std.mem.sort(PromptItem, items.items, {}, lessThanPromptItem);
    return items;
}

/// Discover prompts for memory.search.
pub fn discoverSearchable(allocator: std.mem.Allocator, workspace_root: []const u8, kind_filter: ?PromptKind, group_filter: ?[]const u8) !std.ArrayList(PromptItem) {
    var items: std.ArrayList(PromptItem) = .empty;
    errdefer deinitPromptItems(allocator, &items);

    const prompts_root = workspace_root;

    const searchable_kinds = [_]struct { dir: []const u8, kind: PromptKind }{
        .{ .dir = "rule", .kind = .rule },
        .{ .dir = "workflow", .kind = .workflow },
        .{ .dir = "context", .kind = .context },
    };

    for (searchable_kinds) |kd| {
        if (kind_filter) |filter| {
            if (filter != kd.kind) continue;
        }
        try scanKindDirectory(allocator, prompts_root, kd.dir, kd.kind, &items);
    }

    // Apply group filter in-place to avoid double-free on shared pointers
    if (group_filter) |gf| {
        var write_idx: usize = 0;
        for (items.items) |item| {
            const item_group = item.group orelse {
                freePromptItem(allocator, item);
                continue;
            };
            if (std.mem.eql(u8, item_group, gf) or
                (std.mem.startsWith(u8, item_group, gf) and gf.len < item_group.len and item_group[gf.len] == '/'))
            {
                items.items[write_idx] = item;
                write_idx += 1;
            } else {
                freePromptItem(allocator, item);
            }
        }
        items.items.len = write_idx;
    }

    std.mem.sort(PromptItem, items.items, {}, lessThanPromptItem);
    return items;
}

/// Load prompts by ids, returning content for changed items (delta).
pub fn loadPrompts(allocator: std.mem.Allocator, workspace_root: []const u8, ids: []const []const u8, known: []const KnownHash) !LoadResult {
    var inventory = try discoverAll(allocator, workspace_root);
    defer deinitPromptItems(allocator, &inventory);

    return try materializeSelection(allocator, workspace_root, inventory.items, ids, known);
}

fn scanKindDirectory(
    allocator: std.mem.Allocator,
    prompts_root: []const u8,
    dir_name: []const u8,
    kind: PromptKind,
    items: *std.ArrayList(PromptItem),
) !void {
    const kind_path = try std.fs.path.join(allocator, &.{ prompts_root, dir_name });
    defer allocator.free(kind_path);

    var kind_dir = std.fs.openDirAbsolute(kind_path, .{ .iterate = true }) catch return;
    defer kind_dir.close();

    var walker = try kind_dir.walk(allocator);
    defer walker.deinit();

    const kind_str = kindToString(kind);

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, ".")) continue;

        const abs_path = try std.fs.path.join(allocator, &.{ kind_path, entry.path });
        defer allocator.free(abs_path);

        // id = "kind:relative_path" where relative_path is relative to the kind directory
        const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ kind_str, entry.path });
        errdefer allocator.free(id);

        // path = relative to workspace root
        const rel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_name, entry.path });
        errdefer allocator.free(rel_path);

        // group = first subdirectory under the kind directory, or null
        const group = if (std.fs.path.dirname(entry.path)) |dir|
            try allocator.dupe(u8, dir)
        else
            null;
        errdefer if (group) |g| allocator.free(g);

        const display_name = prompt.displayNameFromFilename(std.fs.path.basename(entry.path));

        try items.append(allocator, .{
            .id = id,
            .kind = kind,
            .path = rel_path,
            .name = try allocator.dupe(u8, display_name),
            .group = group,
            .hash = try prompt.readFileHashHexAlloc(allocator, abs_path),
            .priority = priorityForKind(kind),
        });
    }
}

fn lessThanPromptItem(_: void, a: PromptItem, b: PromptItem) bool {
    const prio_order = std.math.order(@intFromEnum(a.priority), @intFromEnum(b.priority));
    if (prio_order != .eq) return prio_order == .lt;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn materializeAll(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    items: []const PromptItem,
    known: []const KnownHash,
) !LoadResult {
    var result: LoadResult = .{};
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
    inventory: []const PromptItem,
    ids: []const []const u8,
    known: []const KnownHash,
) !LoadResult {
    var result: LoadResult = .{};
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
        seen_ids.put(seen_key, {}) catch |err| {
            allocator.free(seen_key);
            return err;
        };

        const item = findPromptById(inventory, id) orelse return error.UnknownPromptId;
        try result.items.append(allocator, try materializeItem(allocator, workspace_root, item, knownHashFor(id, known)));
    }

    return result;
}

fn materializeItem(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    item: PromptItem,
    known_hash: ?[]const u8,
) !LoadedPrompt {
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

fn findPromptById(inventory: []const PromptItem, id: []const u8) ?PromptItem {
    for (inventory) |item| {
        if (std.mem.eql(u8, item.id, id)) return item;
    }
    return null;
}

fn knownHashFor(id: []const u8, known: []const KnownHash) ?[]const u8 {
    for (known) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry.hash;
    }
    return null;
}

// Constraint parsing (for validate)

pub const ParsedConstraint = struct {
    id: []const u8,
    text_hash: []const u8,
};

pub const ValidateResult = struct {
    valid: bool,
    constraints: std.ArrayList(ParsedConstraint),
    issues: std.ArrayList([]const u8),

    pub fn deinit(self: *ValidateResult, allocator: std.mem.Allocator) void {
        for (self.constraints.items) |c| {
            allocator.free(c.id);
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
    const encoding = @import("encoding.zig");
    encoding.hexEncode(&hash, &hex);
    return try allocator.dupe(u8, &hex);
}

/// Parse constraints from prompt content according to s2 format standard.
/// Rules: # = title (skip), ## = constraint region, list items within region
/// are individual constraints, otherwise the whole region is one constraint.
pub fn parseConstraints(allocator: std.mem.Allocator, content: []const u8) !ValidateResult {
    var constraints: std.ArrayList(ParsedConstraint) = .empty;
    errdefer {
        for (constraints.items) |c| {
            allocator.free(c.id);
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

    // State: are we inside a ## region?
    var in_region = false;
    var region_start: usize = 0;
    var region_has_list = false;
    var region_heading: []const u8 = "";

    while (lines.next()) |line| {
        line_num += 1;
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // # heading = title, skip
        if (std.mem.startsWith(u8, trimmed, "# ") and !std.mem.startsWith(u8, trimmed, "## ")) {
            continue;
        }

        // ## heading = new constraint region (with reserved heading exceptions)
        if (std.mem.startsWith(u8, trimmed, "## ")) {
            const heading_text = trimmed[3..];

            // Reserved: ## Steps — execution steps, not constraints
            const is_steps = std.ascii.eqlIgnoreCase(heading_text, "Steps") or
                std.ascii.eqlIgnoreCase(heading_text, "steps");
            // Reserved: ## Examples — supporting material
            const is_examples = std.ascii.eqlIgnoreCase(heading_text, "Examples") or
                std.ascii.eqlIgnoreCase(heading_text, "examples") or
                std.ascii.eqlIgnoreCase(heading_text, "Example") or
                std.ascii.eqlIgnoreCase(heading_text, "example");

            // Close previous region if open
            if (in_region and !region_has_list) {
                constraint_counter += 1;
                const id = try std.fmt.allocPrint(allocator, "c-{d}", .{constraint_counter});
                const th = try computeTextHash(allocator, region_heading);
                try constraints.append(allocator, .{
                    .id = id,
                    .text_hash = th,
                });
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

        // List item (- or 1.) within a region = individual constraint
        if (in_region and (std.mem.startsWith(u8, trimmed, "- ") or isOrderedListItem(trimmed))) {
            // Skip support material lines
            if (std.mem.startsWith(u8, trimmed, "- **理由**") or
                std.mem.startsWith(u8, trimmed, "- **示例**"))
                continue;

            region_has_list = true;
            constraint_counter += 1;
            const id = try std.fmt.allocPrint(allocator, "c-{d}", .{constraint_counter});
            const th = try computeTextHash(allocator, trimmed);
            try constraints.append(allocator, .{
                .id = id,
                .text_hash = th,
            });
            continue;
        }

        // **理由** / **示例** = support material, skip
        if (std.mem.startsWith(u8, trimmed, "**理由**") or
            std.mem.startsWith(u8, trimmed, "**示例**") or
            std.mem.startsWith(u8, trimmed, "✅") or
            std.mem.startsWith(u8, trimmed, "❌"))
        {
            continue;
        }
    }

    // Close last region
    if (in_region and !region_has_list) {
        constraint_counter += 1;
        const id = try std.fmt.allocPrint(allocator, "c-{d}", .{constraint_counter});
        const th = try computeTextHash(allocator, region_heading);
        try constraints.append(allocator, .{
            .id = id,
            .text_hash = th,
        });
    }

    if (constraint_counter == 0 and content.len > 0) {
        constraint_counter += 1;
        const id = try std.fmt.allocPrint(allocator, "c-{d}", .{constraint_counter});
        const th = try computeTextHash(allocator, content);
        try constraints.append(allocator, .{
            .id = id,
            .text_hash = th,
        });
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

fn isOrderedListItem(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == 0 or i >= line.len) return false;
    return line[i] == '.' and i + 1 < line.len and line[i + 1] == ' ';
}

/// Validate a prompt file. For Rule/Workflow: parse constraints. For Data: just check readable.
pub fn validatePrompt(allocator: std.mem.Allocator, workspace_root: []const u8, prompt_id: []const u8) !ValidateResult {
    var all = try discoverAll(allocator, workspace_root);
    defer deinitPromptItems(allocator, &all);

    const item = findPromptById(all.items, prompt_id) orelse {
        var issues: std.ArrayList([]const u8) = .empty;
        try issues.append(allocator, try allocator.dupe(u8, "Prompt not found"));
        return .{
            .valid = false,
            .constraints = .empty,
            .issues = issues,
        };
    };

    if (item.kind == .context) {
        // Just check readable
        const content = readWorkspaceFileAlloc(allocator, workspace_root, item.path) catch {
            var issues: std.ArrayList([]const u8) = .empty;
            try issues.append(allocator, try allocator.dupe(u8, "File not readable"));
            return .{
                .valid = false,
                .constraints = .empty,
                .issues = issues,
            };
        };
        allocator.free(content);
        return .{
            .valid = true,
            .constraints = .empty,
            .issues = .empty,
        };
    }

    // Rule or Workflow: parse constraints
    const content = try readWorkspaceFileAlloc(allocator, workspace_root, item.path);
    defer allocator.free(content);
    return try parseConstraints(allocator, content);
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

test "discoverAll: finds rules workflows and data by kind directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("rule/coding");
    try tmp.dir.makePath("workflow");
    try tmp.dir.makePath("context/research");

    try writeFile(tmp.dir, "rule/coding/00_COMPAT.md", "compat rule");
    try writeFile(tmp.dir, "workflow/00_GEN_COMMIT.md", "commit workflow");
    try writeFile(tmp.dir, "context/research/R1-0.md", "research data");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var items = try discoverAll(testing.allocator, root);
    defer deinitPromptItems(testing.allocator, &items);

    try testing.expectEqual(@as(usize, 3), items.items.len);

    var found_rule = false;
    var found_workflow = false;
    var found_data = false;
    for (items.items) |item| {
        if (std.mem.eql(u8, item.id, "rule:coding/00_COMPAT.md")) {
            found_rule = true;
            try testing.expectEqualStrings("coding", item.group.?);
        }
        if (std.mem.eql(u8, item.id, "workflow:00_GEN_COMMIT.md")) {
            found_workflow = true;
            try testing.expect(item.group == null);
        }
        if (std.mem.eql(u8, item.id, "context:research/R1-0.md")) {
            found_data = true;
            try testing.expectEqualStrings("research", item.group.?);
        }
    }
    try testing.expect(found_rule);
    try testing.expect(found_workflow);
    try testing.expect(found_data);
}

test "loadMpf: returns content and hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts");
    try writeFile(tmp.dir, "META_PROMPT.md", "bootstrap rules");

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

    try tmp.dir.makePath(".prompts");
    try writeFile(tmp.dir, "META_PROMPT.md", "bootstrap rules");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    // First load to get hash
    var first = try loadMpf(testing.allocator, root, null);
    const hash = try testing.allocator.dupe(u8, first.hash.?);
    defer testing.allocator.free(hash);
    first.deinit(testing.allocator);

    // Second load with known hash — content should be null (no delta)
    var second = try loadMpf(testing.allocator, root, hash);
    defer second.deinit(testing.allocator);

    try testing.expect(second.content == null);
    try testing.expect(second.hash != null);
}

test "loadMpf: returns null when file missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try loadMpf(testing.allocator, root, null);
    defer result.deinit(testing.allocator);

    try testing.expect(result.content == null);
    try testing.expect(result.hash == null);
}

test "discoverSearchable: filters by kind and group" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("rule/coding");
    try tmp.dir.makePath("rule/zig");
    try tmp.dir.makePath("workflow");

    try writeFile(tmp.dir, "rule/coding/00_COMPAT.md", "compat");
    try writeFile(tmp.dir, "rule/zig/00_STYLE.md", "style");
    try writeFile(tmp.dir, "workflow/00_COMMIT.md", "commit");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    // Filter by kind=rule
    var rules = try discoverSearchable(testing.allocator, root, .rule, null);
    defer deinitPromptItems(testing.allocator, &rules);
    try testing.expectEqual(@as(usize, 2), rules.items.len);

    // Filter by kind=rule, group=zig
    var zig_rules = try discoverSearchable(testing.allocator, root, .rule, "zig");
    defer deinitPromptItems(testing.allocator, &zig_rules);
    try testing.expectEqual(@as(usize, 1), zig_rules.items.len);
    try testing.expectEqualStrings("rule:zig/00_STYLE.md", zig_rules.items[0].id);
}

test "loadPrompts: loads by id with delta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("rule");
    try writeFile(tmp.dir, "rule/00_STYLE.md", "style content");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var result = try loadPrompts(testing.allocator, root, &.{"rule:00_STYLE.md"}, &.{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.items.items.len);
    try testing.expect(result.items.items[0].changed);
    try testing.expectEqualStrings("style content", result.items.items[0].content.?);
}

test "loadPrompts: unknown id fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    try testing.expectError(error.UnknownPromptId, loadPrompts(testing.allocator, root, &.{"rule:missing.md"}, &.{}));
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
    try testing.expectEqualStrings("c-4", result.constraints.items[3].id);
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
}

test "parseConstraints: no headings no lists is one constraint" {
    const content = "Always use English in code comments.";
    var result = try parseConstraints(testing.allocator, content);
    defer result.deinit(testing.allocator);

    try testing.expect(result.valid);
    try testing.expectEqual(@as(usize, 1), result.constraints.items.len);
    try testing.expectEqualStrings("c-1", result.constraints.items[0].id);
}

test "parseConstraints: empty content" {
    var result = try parseConstraints(testing.allocator, "");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.valid);
    try testing.expectEqual(@as(usize, 0), result.constraints.items.len);
    try testing.expectEqual(@as(usize, 1), result.issues.items.len);
}
