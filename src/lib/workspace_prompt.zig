const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");
const prompt = @import("prompt.zig");

pub const PromptKind = enum {
    directive,
    rule,
    workflow,
    data,
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
    .{ .dir = "directive", .kind = .directive },
    .{ .dir = "rule", .kind = .rule },
    .{ .dir = "workflow", .kind = .workflow },
    .{ .dir = "data", .kind = .data },
};

fn priorityForKind(kind: PromptKind) SetupPriority {
    return switch (kind) {
        .directive => .high,
        .rule, .workflow, .data => .normal,
    };
}

pub fn kindToString(kind: PromptKind) []const u8 {
    return switch (kind) {
        .directive => "directive",
        .rule => "rule",
        .workflow => "workflow",
        .data => "data",
    };
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

/// Discover all prompts in the .prompts/ directory, organized by kind.
/// Also detects MPF files (CLAUDE.md, AGENTS.md) at workspace root as directives.
pub fn discoverAll(allocator: std.mem.Allocator, workspace_root: []const u8) !std.ArrayList(PromptItem) {
    var items: std.ArrayList(PromptItem) = .empty;
    errdefer deinitPromptItems(allocator, &items);

    // Backward compat: detect MPF files at workspace root as directives
    try detectMpfAsDirective(allocator, workspace_root, &items);

    // Scan each kind directory under .prompts/
    const prompts_root = try std.fs.path.join(allocator, &.{ workspace_root, ".prompts" });
    defer allocator.free(prompts_root);

    for (kind_dirs) |kd| {
        try scanKindDirectory(allocator, prompts_root, kd.dir, kd.kind, &items);
    }

    std.mem.sort(PromptItem, items.items, {}, lessThanPromptItem);
    return items;
}

/// Discover only directives (for memory.setup).
pub fn discoverDirectives(allocator: std.mem.Allocator, workspace_root: []const u8) !std.ArrayList(PromptItem) {
    var items: std.ArrayList(PromptItem) = .empty;
    errdefer deinitPromptItems(allocator, &items);

    try detectMpfAsDirective(allocator, workspace_root, &items);

    const prompts_root = try std.fs.path.join(allocator, &.{ workspace_root, ".prompts" });
    defer allocator.free(prompts_root);

    try scanKindDirectory(allocator, prompts_root, "directive", .directive, &items);

    std.mem.sort(PromptItem, items.items, {}, lessThanPromptItem);
    return items;
}

/// Discover non-directive prompts (for memory.search).
pub fn discoverSearchable(allocator: std.mem.Allocator, workspace_root: []const u8, kind_filter: ?PromptKind, group_filter: ?[]const u8) !std.ArrayList(PromptItem) {
    var items: std.ArrayList(PromptItem) = .empty;
    errdefer deinitPromptItems(allocator, &items);

    const prompts_root = try std.fs.path.join(allocator, &.{ workspace_root, ".prompts" });
    defer allocator.free(prompts_root);

    const searchable_kinds = [_]struct { dir: []const u8, kind: PromptKind }{
        .{ .dir = "rule", .kind = .rule },
        .{ .dir = "workflow", .kind = .workflow },
        .{ .dir = "data", .kind = .data },
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

/// Load all directives, returning content for changed items (delta).
pub fn loadDirectives(allocator: std.mem.Allocator, workspace_root: []const u8, known: []const KnownHash) !LoadResult {
    var items = try discoverDirectives(allocator, workspace_root);
    defer deinitPromptItems(allocator, &items);

    return try materializeAll(allocator, workspace_root, items.items, known);
}

fn detectMpfAsDirective(allocator: std.mem.Allocator, workspace_root: []const u8, items: *std.ArrayList(PromptItem)) !void {
    const raw_mpf = try config.getMetaPromptFilesStr(allocator);
    defer if (raw_mpf) |raw| allocator.free(raw);

    var mpf_list = try config.parseMetaPromptFiles(allocator, raw_mpf);
    defer config.freeOwnedStrings(allocator, &mpf_list);

    for (mpf_list.items) |mpf_name| {
        const abs_path = try std.fs.path.join(allocator, &.{ workspace_root, mpf_name });
        defer allocator.free(abs_path);

        const file = std.fs.openFileAbsolute(abs_path, .{}) catch continue;
        file.close();

        const display_name = prompt.displayNameFromFilename(std.fs.path.basename(mpf_name));

        try items.append(allocator, .{
            .id = try std.fmt.allocPrint(allocator, "directive:{s}", .{mpf_name}),
            .kind = .directive,
            .path = try allocator.dupe(u8, mpf_name),
            .name = try allocator.dupe(u8, display_name),
            .group = null,
            .hash = try prompt.readFileHashHexAlloc(allocator, abs_path),
            .priority = .high,
        });
    }
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
        const rel_path = try std.fmt.allocPrint(allocator, ".prompts/{s}/{s}", .{ dir_name, entry.path });
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
        errdefer allocator.free(seen_key);
        try seen_ids.put(seen_key, {});

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

    return try file.readToEndAlloc(allocator, prompt.MAX_FILE_SIZE);
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
    line_start: usize,
    line_end: usize,
};

pub const ValidateResult = struct {
    valid: bool,
    constraints: std.ArrayList(ParsedConstraint),
    issues: std.ArrayList([]const u8),

    pub fn deinit(self: *ValidateResult, allocator: std.mem.Allocator) void {
        for (self.constraints.items) |c| {
            allocator.free(c.id);
        }
        self.constraints.deinit(allocator);
        for (self.issues.items) |issue| {
            allocator.free(issue);
        }
        self.issues.deinit(allocator);
    }
};

/// Parse constraints from prompt content according to s2 format standard.
/// Rules: # = title (skip), ## = constraint region, list items within region
/// are individual constraints, otherwise the whole region is one constraint.
pub fn parseConstraints(allocator: std.mem.Allocator, content: []const u8) !ValidateResult {
    var constraints: std.ArrayList(ParsedConstraint) = .empty;
    errdefer {
        for (constraints.items) |c| allocator.free(c.id);
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

    while (lines.next()) |line| {
        line_num += 1;
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // # heading = title, skip
        if (std.mem.startsWith(u8, trimmed, "# ") and !std.mem.startsWith(u8, trimmed, "## ")) {
            continue;
        }

        // ## heading = new constraint region
        if (std.mem.startsWith(u8, trimmed, "## ")) {
            // Close previous region if open
            if (in_region and !region_has_list) {
                constraint_counter += 1;
                const id = try std.fmt.allocPrint(allocator, "c-{d}", .{constraint_counter});
                try constraints.append(allocator, .{
                    .id = id,
                    .line_start = region_start,
                    .line_end = line_num - 1,
                });
            }
            in_region = true;
            region_start = line_num;
            region_has_list = false;
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
            try constraints.append(allocator, .{
                .id = id,
                .line_start = line_num,
                .line_end = line_num,
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
        try constraints.append(allocator, .{
            .id = id,
            .line_start = region_start,
            .line_end = line_num,
        });
    }

    // Rule 4: no ## headings and no list items → whole file is one constraint
    if (constraint_counter == 0 and content.len > 0) {
        constraint_counter += 1;
        const id = try std.fmt.allocPrint(allocator, "c-{d}", .{constraint_counter});
        try constraints.append(allocator, .{
            .id = id,
            .line_start = 1,
            .line_end = line_num,
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

/// Validate a prompt file. For Rule/Workflow: parse constraints. For Directive: just check readable.
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

    if (item.kind == .directive or item.kind == .data) {
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
    try file.writeAll(content);
}

fn tmpDirAbsolutePath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    return tmp.dir.realpath(".", buf) catch "";
}

test "discoverAll: finds directives rules and workflows by kind directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/directive/context");
    try tmp.dir.makePath(".prompts/rule/coding");
    try tmp.dir.makePath(".prompts/workflow");
    try tmp.dir.makePath(".prompts/data/research");

    try writeFile(tmp.dir, ".prompts/directive/PIN.md", "pin content");
    try writeFile(tmp.dir, ".prompts/directive/context/01_ARCH.md", "arch content");
    try writeFile(tmp.dir, ".prompts/rule/coding/00_COMPAT.md", "compat rule");
    try writeFile(tmp.dir, ".prompts/workflow/00_GEN_COMMIT.md", "commit workflow");
    try writeFile(tmp.dir, ".prompts/data/research/R1-0.md", "research data");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var items = try discoverAll(testing.allocator, root);
    defer deinitPromptItems(testing.allocator, &items);

    try testing.expectEqual(@as(usize, 5), items.items.len);

    // Directives should come first (high priority)
    try testing.expectEqual(PromptKind.directive, items.items[0].kind);
    try testing.expectEqual(PromptKind.directive, items.items[1].kind);

    // Check id format: kind:relative_path (relative to kind dir)
    var found_arch = false;
    var found_rule = false;
    var found_workflow = false;
    var found_data = false;
    for (items.items) |item| {
        if (std.mem.eql(u8, item.id, "directive:context/01_ARCH.md")) {
            found_arch = true;
            try testing.expectEqualStrings("context", item.group.?);
        }
        if (std.mem.eql(u8, item.id, "rule:coding/00_COMPAT.md")) {
            found_rule = true;
            try testing.expectEqualStrings("coding", item.group.?);
        }
        if (std.mem.eql(u8, item.id, "workflow:00_GEN_COMMIT.md")) {
            found_workflow = true;
            try testing.expect(item.group == null);
        }
        if (std.mem.eql(u8, item.id, "data:research/R1-0.md")) {
            found_data = true;
            try testing.expectEqualStrings("research", item.group.?);
        }
    }
    try testing.expect(found_arch);
    try testing.expect(found_rule);
    try testing.expect(found_workflow);
    try testing.expect(found_data);
}

test "discoverDirectives: only returns directives" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/directive");
    try tmp.dir.makePath(".prompts/rule");

    try writeFile(tmp.dir, ".prompts/directive/PIN.md", "pin");
    try writeFile(tmp.dir, ".prompts/rule/00_STYLE.md", "style rule");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    var items = try discoverDirectives(testing.allocator, root);
    defer deinitPromptItems(testing.allocator, &items);

    try testing.expectEqual(@as(usize, 1), items.items.len);
    try testing.expectEqual(PromptKind.directive, items.items[0].kind);
    try testing.expectEqualStrings("directive:PIN.md", items.items[0].id);
}

test "discoverSearchable: filters by kind and group" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule/coding");
    try tmp.dir.makePath(".prompts/rule/zig");
    try tmp.dir.makePath(".prompts/workflow");

    try writeFile(tmp.dir, ".prompts/rule/coding/00_COMPAT.md", "compat");
    try writeFile(tmp.dir, ".prompts/rule/zig/00_STYLE.md", "style");
    try writeFile(tmp.dir, ".prompts/workflow/00_COMMIT.md", "commit");

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

test "loadDirectives: delta based on knownHashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/directive");
    try writeFile(tmp.dir, ".prompts/directive/PIN.md", "pin content");
    try writeFile(tmp.dir, ".prompts/directive/OVERVIEW.md", "overview");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpDirAbsolutePath(&tmp, &buf);

    // Get hash of PIN.md
    const pin_path = try std.fs.path.join(testing.allocator, &.{ root, ".prompts/directive/PIN.md" });
    defer testing.allocator.free(pin_path);
    const pin_hash = try prompt.readFileHashHexAlloc(testing.allocator, pin_path);
    defer testing.allocator.free(pin_hash);

    // Load with PIN.md hash known — should get delta (only OVERVIEW content)
    var result = try loadDirectives(testing.allocator, root, &.{
        .{ .id = "directive:PIN.md", .hash = pin_hash },
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.items.items.len);

    for (result.items.items) |item| {
        if (std.mem.eql(u8, item.id, "directive:PIN.md")) {
            try testing.expect(!item.changed);
            try testing.expect(item.content == null);
        }
        if (std.mem.eql(u8, item.id, "directive:OVERVIEW.md")) {
            try testing.expect(item.changed);
            try testing.expectEqualStrings("overview", item.content.?);
        }
    }
}

test "loadPrompts: loads by id with delta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule");
    try writeFile(tmp.dir, ".prompts/rule/00_STYLE.md", "style content");

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
    try testing.expectEqual(@as(usize, 1), result.constraints.items[0].line_start);
}

test "parseConstraints: empty content" {
    var result = try parseConstraints(testing.allocator, "");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.valid);
    try testing.expectEqual(@as(usize, 0), result.constraints.items.len);
    try testing.expectEqual(@as(usize, 1), result.issues.items.len);
}
