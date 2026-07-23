const std = @import("std");

pub const HooksPlanResult = union(enum) {
    prepared: PreparedHooksFile,
    conflict: []const u8,
};

pub const PreparedHooksFile = struct {
    action: []const u8,
    rendered_content: []u8,
    managed_content: []u8,

    pub fn deinit(self: *PreparedHooksFile, allocator: std.mem.Allocator) void {
        allocator.free(self.rendered_content);
        allocator.free(self.managed_content);
    }
};

pub const HooksRemoveResult = union(enum) {
    delete_file,
    rewrite: []u8,
    already_absent,
    conflict: []const u8,
};

const conflict_invalid_json = "Existing hooks registry is not valid JSON.";
const conflict_invalid_root = "Existing hooks registry must be a JSON object.";
const conflict_invalid_hooks = "Existing hooks registry has a non-object `hooks` field.";
const conflict_invalid_event = "Existing hooks registry has a non-array hook event entry.";
const conflict_incompatible_item = "Existing hooks registry already contains a clumsies-managed hook entry with incompatible content.";
const conflict_invalid_fragment = "Internal managed hooks fragment is invalid.";
const conflict_incompatible_named_hook = "Existing hooks registry already contains a clumsies-managed named hook with incompatible content.";

pub fn prepareJsonHooksRegistry(
    allocator: std.mem.Allocator,
    existing_content_opt: ?[]const u8,
    managed_fragment: []const u8,
) !HooksPlanResult {
    const managed_parsed = std.json.parseFromSlice(std.json.Value, allocator, managed_fragment, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_fragment };
    defer managed_parsed.deinit();

    const managed_hooks = getHooksObject(managed_parsed.value) orelse return .{ .conflict = conflict_invalid_fragment };

    if (existing_content_opt == null) {
        return .{ .prepared = .{
            .action = "create",
            .rendered_content = try allocator.dupe(u8, managed_fragment),
            .managed_content = try allocator.dupe(u8, managed_fragment),
        } };
    }

    const existing_content = existing_content_opt.?;
    var current_parsed = std.json.parseFromSlice(std.json.Value, allocator, existing_content, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_json };
    defer current_parsed.deinit();

    const current_root = asObjectPtr(&current_parsed.value) orelse return .{ .conflict = conflict_invalid_root };
    const arena = current_parsed.arena.allocator();
    const hooks_object = ensureHooksObject(current_root, arena) catch return .{ .conflict = conflict_invalid_hooks };

    var did_change = try pruneRetiredClumsiesHookItems(allocator, hooks_object, managed_hooks);

    var event_it = managed_hooks.iterator();
    while (event_it.next()) |event_entry| {
        const managed_items = asArray(event_entry.value_ptr.*) orelse return .{ .conflict = conflict_invalid_fragment };
        const current_items = ensureEventArray(hooks_object, event_entry.key_ptr.*, arena) catch return .{ .conflict = conflict_invalid_event };

        for (managed_items.items) |managed_item| {
            switch (inspectManagedItem(current_items.items, managed_item)) {
                .exact => {},
                .replace => |index| {
                    current_items.items[index] = try cloneValue(arena, managed_item);
                    did_change = true;
                },
                .absent => {
                    try current_items.append(try cloneValue(arena, managed_item));
                    did_change = true;
                },
                .conflict => return .{ .conflict = conflict_incompatible_item },
            }
        }
    }

    return .{ .prepared = .{
        .action = if (did_change) "update" else "keep",
        .rendered_content = if (did_change)
            try renderPrettyJsonAlloc(allocator, current_parsed.value)
        else
            try allocator.dupe(u8, existing_content),
        .managed_content = try allocator.dupe(u8, managed_fragment),
    } };
}

pub fn prepareJsonNamedHooksRegistry(
    allocator: std.mem.Allocator,
    existing_content_opt: ?[]const u8,
    managed_fragment: []const u8,
) !HooksPlanResult {
    const managed_parsed = std.json.parseFromSlice(std.json.Value, allocator, managed_fragment, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_fragment };
    defer managed_parsed.deinit();

    const managed_root = asObject(managed_parsed.value) orelse return .{ .conflict = conflict_invalid_fragment };

    if (existing_content_opt == null) {
        return .{ .prepared = .{
            .action = "create",
            .rendered_content = try allocator.dupe(u8, managed_fragment),
            .managed_content = try allocator.dupe(u8, managed_fragment),
        } };
    }

    const existing_content = existing_content_opt.?;
    var current_parsed = std.json.parseFromSlice(std.json.Value, allocator, existing_content, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_json };
    defer current_parsed.deinit();

    const current_root = asObjectPtr(&current_parsed.value) orelse return .{ .conflict = conflict_invalid_root };
    const arena = current_parsed.arena.allocator();

    var did_change = false;
    var it = managed_root.iterator();
    while (it.next()) |entry| {
        const managed_events = asObject(entry.value_ptr.*) orelse return .{ .conflict = conflict_invalid_fragment };
        const current_value = current_root.getPtr(entry.key_ptr.*);
        if (current_value == null) {
            try current_root.put(
                arena,
                try arena.dupe(u8, entry.key_ptr.*),
                try cloneValue(arena, entry.value_ptr.*),
            );
            did_change = true;
            continue;
        }

        const current_events = asObjectPtr(current_value.?) orelse return .{ .conflict = conflict_incompatible_named_hook };
        var event_it = managed_events.iterator();
        while (event_it.next()) |event_entry| {
            const managed_handlers = asArray(event_entry.value_ptr.*) orelse return .{ .conflict = conflict_invalid_fragment };
            const current_handlers = ensureEventArray(current_events, event_entry.key_ptr.*, arena) catch return .{ .conflict = conflict_incompatible_named_hook };

            for (managed_handlers.items) |managed_handler| {
                switch (inspectManagedNamedHook(current_handlers.items, managed_handler)) {
                    .exact => {},
                    .replace => |index| {
                        current_handlers.items[index] = try cloneValue(arena, managed_handler);
                        did_change = true;
                    },
                    .absent => {
                        try current_handlers.append(try cloneValue(arena, managed_handler));
                        did_change = true;
                    },
                    .conflict => return .{ .conflict = conflict_incompatible_named_hook },
                }
            }
        }
    }

    return .{ .prepared = .{
        .action = if (did_change) "update" else "keep",
        .rendered_content = if (did_change)
            try renderPrettyJsonAlloc(allocator, current_parsed.value)
        else
            try allocator.dupe(u8, existing_content),
        .managed_content = try allocator.dupe(u8, managed_fragment),
    } };
}

pub fn removeJsonHooksRegistry(
    allocator: std.mem.Allocator,
    current_content: []const u8,
    managed_fragment: []const u8,
) !HooksRemoveResult {
    const managed_parsed = std.json.parseFromSlice(std.json.Value, allocator, managed_fragment, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_fragment };
    defer managed_parsed.deinit();

    const managed_hooks = getHooksObject(managed_parsed.value) orelse return .{ .conflict = conflict_invalid_fragment };

    var current_parsed = std.json.parseFromSlice(std.json.Value, allocator, current_content, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_json };
    defer current_parsed.deinit();

    const current_root = asObjectPtr(&current_parsed.value) orelse return .{ .conflict = conflict_invalid_root };
    const hooks_value = current_root.getPtr("hooks") orelse return .already_absent;
    const hooks_object = asObjectPtr(hooks_value) orelse return .{ .conflict = conflict_invalid_hooks };

    var did_remove = false;

    var event_it = managed_hooks.iterator();
    while (event_it.next()) |event_entry| {
        const managed_items = asArray(event_entry.value_ptr.*) orelse return .{ .conflict = conflict_invalid_fragment };
        const current_items_value = hooks_object.getPtr(event_entry.key_ptr.*) orelse continue;
        const current_items = asArrayPtr(current_items_value) orelse return .{ .conflict = conflict_invalid_event };

        var indexes_to_remove: std.ArrayList(usize) = .empty;
        defer indexes_to_remove.deinit(allocator);

        for (managed_items.items) |managed_item| {
            const match = inspectManagedItem(current_items.items, managed_item);
            switch (match) {
                .exact => |index| try indexes_to_remove.append(allocator, index),
                .absent => {},
                .replace => return .{ .conflict = conflict_incompatible_item },
                .conflict => return .{ .conflict = conflict_incompatible_item },
            }
        }

        if (indexes_to_remove.items.len == 0) continue;

        std.mem.sortUnstable(usize, indexes_to_remove.items, {}, comptime std.sort.desc(usize));
        for (indexes_to_remove.items) |index| {
            _ = current_items.orderedRemove(index);
            did_remove = true;
        }

        if (current_items.items.len == 0) {
            _ = hooks_object.orderedRemove(event_entry.key_ptr.*);
        }
    }

    if (!did_remove) return .already_absent;

    if (hooks_object.count() == 0) {
        _ = current_root.orderedRemove("hooks");
    }
    if (current_root.count() == 0) {
        return .delete_file;
    }

    return .{ .rewrite = try renderPrettyJsonAlloc(allocator, current_parsed.value) };
}

pub fn removeJsonNamedHooksRegistry(
    allocator: std.mem.Allocator,
    current_content: []const u8,
    managed_fragment: []const u8,
) !HooksRemoveResult {
    const managed_parsed = std.json.parseFromSlice(std.json.Value, allocator, managed_fragment, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_fragment };
    defer managed_parsed.deinit();

    const managed_root = asObject(managed_parsed.value) orelse return .{ .conflict = conflict_invalid_fragment };

    var current_parsed = std.json.parseFromSlice(std.json.Value, allocator, current_content, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_json };
    defer current_parsed.deinit();

    const current_root = asObjectPtr(&current_parsed.value) orelse return .{ .conflict = conflict_invalid_root };

    var did_remove = false;
    var it = managed_root.iterator();
    while (it.next()) |entry| {
        const managed_events = asObject(entry.value_ptr.*) orelse return .{ .conflict = conflict_invalid_fragment };
        const current_value = current_root.getPtr(entry.key_ptr.*) orelse continue;
        const current_events = asObjectPtr(current_value) orelse return .{ .conflict = conflict_incompatible_named_hook };

        var event_it = managed_events.iterator();
        while (event_it.next()) |event_entry| {
            const managed_handlers = asArray(event_entry.value_ptr.*) orelse return .{ .conflict = conflict_invalid_fragment };
            const current_handlers_value = current_events.getPtr(event_entry.key_ptr.*) orelse continue;
            const current_handlers = asArrayPtr(current_handlers_value) orelse return .{ .conflict = conflict_incompatible_named_hook };

            var indexes_to_remove: std.ArrayList(usize) = .empty;
            defer indexes_to_remove.deinit(allocator);

            for (managed_handlers.items) |managed_handler| {
                switch (inspectManagedNamedHook(current_handlers.items, managed_handler)) {
                    .exact => |index| try indexes_to_remove.append(allocator, index),
                    .replace => |index| try indexes_to_remove.append(allocator, index),
                    .absent => {},
                    .conflict => return .{ .conflict = conflict_incompatible_named_hook },
                }
            }

            if (indexes_to_remove.items.len == 0) continue;

            std.mem.sortUnstable(usize, indexes_to_remove.items, {}, comptime std.sort.desc(usize));
            var last_removed_index: ?usize = null;
            for (indexes_to_remove.items) |index| {
                if (last_removed_index == index) continue;
                last_removed_index = index;
                _ = current_handlers.orderedRemove(index);
                did_remove = true;
            }

            if (current_handlers.items.len == 0) {
                _ = current_events.orderedRemove(event_entry.key_ptr.*);
            }
        }

        if (current_events.count() == 0) {
            _ = current_root.orderedRemove(entry.key_ptr.*);
        }
    }

    if (!did_remove) return .already_absent;
    if (current_root.count() == 0) return .delete_file;

    return .{ .rewrite = try renderPrettyJsonAlloc(allocator, current_parsed.value) };
}

const ItemMatch = union(enum) {
    absent,
    exact: usize,
    replace: usize,
    conflict,
};

fn inspectManagedItem(items: []const std.json.Value, managed_item: std.json.Value) ItemMatch {
    var exact_index: ?usize = null;
    var replace_index: ?usize = null;
    var related_non_exact = false;

    for (items, 0..) |item, index| {
        if (valueEql(item, managed_item)) {
            if (exact_index != null) return .conflict;
            exact_index = index;
            continue;
        }
        if (managedHookItemCanReplace(item, managed_item)) {
            if (replace_index != null) return .conflict;
            replace_index = index;
            continue;
        }
        if (itemsOverlapOnCommand(item, managed_item)) {
            related_non_exact = true;
        }
        if (itemsOverlapOnClumsiesHookKind(item, managed_item)) {
            related_non_exact = true;
        }
    }

    if (related_non_exact) return .conflict;
    if (exact_index != null and replace_index != null) return .conflict;
    if (exact_index) |index| return .{ .exact = index };
    if (replace_index) |index| return .{ .replace = index };
    return .absent;
}

fn pruneRetiredClumsiesHookItems(
    allocator: std.mem.Allocator,
    current_hooks: *std.json.ObjectMap,
    managed_hooks: std.json.ObjectMap,
) !bool {
    var empty_events: std.ArrayList([]const u8) = .empty;
    defer empty_events.deinit(allocator);

    var did_change = false;
    var event_it = current_hooks.iterator();
    while (event_it.next()) |event_entry| {
        const current_items = asArrayPtr(event_entry.value_ptr) orelse continue;
        var index = current_items.items.len;
        while (index > 0) {
            index -= 1;
            if (!isRetiredClumsiesHookItem(current_items.items[index], managed_hooks)) continue;
            _ = current_items.orderedRemove(index);
            did_change = true;
        }
        if (current_items.items.len == 0) {
            try empty_events.append(allocator, event_entry.key_ptr.*);
        }
    }

    for (empty_events.items) |event_name| {
        _ = current_hooks.orderedRemove(event_name);
    }
    return did_change;
}

fn isRetiredClumsiesHookItem(
    item: std.json.Value,
    managed_hooks: std.json.ObjectMap,
) bool {
    const hooks = nestedHooksArray(item) orelse return false;
    if (hooks.len == 0) return false;

    var found_clumsies_hook = false;
    for (hooks) |hook| {
        const command = hookCommand(hook) orelse return false;
        const kind = clumsiesHookScriptName(command) orelse return false;
        found_clumsies_hook = true;
        if (managedHooksContainKind(managed_hooks, kind)) return false;
    }
    return found_clumsies_hook;
}

fn managedHooksContainKind(
    managed_hooks: std.json.ObjectMap,
    expected_kind: []const u8,
) bool {
    var event_it = managed_hooks.iterator();
    while (event_it.next()) |event_entry| {
        const items = asArray(event_entry.value_ptr.*) orelse continue;
        for (items.items) |item| {
            const hooks = nestedHooksArray(item) orelse continue;
            for (hooks) |hook| {
                const command = hookCommand(hook) orelse continue;
                const kind = clumsiesHookScriptName(command) orelse continue;
                if (std.mem.eql(u8, kind, expected_kind)) return true;
            }
        }
    }
    return false;
}

fn inspectManagedNamedHook(items: []const std.json.Value, managed_item: std.json.Value) ItemMatch {
    var exact_index: ?usize = null;
    var replace_index: ?usize = null;
    var related_non_exact = false;

    for (items, 0..) |item, index| {
        if (valueEql(item, managed_item)) {
            if (exact_index != null) return .conflict;
            exact_index = index;
            continue;
        }
        if (managedNamedHookCanReplace(item, managed_item)) {
            if (replace_index != null) return .conflict;
            replace_index = index;
            continue;
        }
        if (namedHooksOverlapOnCommand(item, managed_item)) {
            related_non_exact = true;
        }
        if (namedHooksOverlapOnClumsiesHookKind(item, managed_item)) {
            related_non_exact = true;
        }
    }

    if (related_non_exact) return .conflict;
    if (exact_index != null and replace_index != null) return .conflict;
    if (exact_index) |index| return .{ .exact = index };
    if (replace_index) |index| return .{ .replace = index };
    return .absent;
}

fn getHooksObject(root_value: std.json.Value) ?std.json.ObjectMap {
    const root_object = asObject(root_value) orelse return null;
    const hooks_value = root_object.get("hooks") orelse return null;
    return asObject(hooks_value);
}

fn ensureHooksObject(root_object: *std.json.ObjectMap, arena: std.mem.Allocator) !*std.json.ObjectMap {
    if (root_object.getPtr("hooks")) |hooks_value| {
        return asObjectPtr(hooks_value) orelse error.InvalidHooksContainer;
    }
    try root_object.put(arena, "hooks", .{ .object = .empty });
    return asObjectPtr(root_object.getPtr("hooks").?).?;
}

fn ensureEventArray(hooks_object: *std.json.ObjectMap, event_name: []const u8, arena: std.mem.Allocator) !*std.json.Array {
    if (hooks_object.getPtr(event_name)) |event_value| {
        return asArrayPtr(event_value) orelse error.InvalidEventArray;
    }

    const owned_key = try arena.dupe(u8, event_name);
    try hooks_object.put(arena, owned_key, .{ .array = std.json.Array.init(arena) });
    return asArrayPtr(hooks_object.getPtr(event_name).?).?;
}

fn renderPrettyJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const rendered = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(rendered);
    return std.mem.concat(allocator, u8, &.{ rendered, "\n" });
}

fn cloneValue(arena: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try arena.dupe(u8, inner) },
        .string => |inner| .{ .string = try arena.dupe(u8, inner) },
        .array => |inner| blk: {
            var cloned: std.json.Array = .init(arena);
            for (inner.items) |item| {
                try cloned.append(try cloneValue(arena, item));
            }
            break :blk .{ .array = cloned };
        },
        .object => |inner| blk: {
            var cloned: std.json.ObjectMap = .empty;
            var it = inner.iterator();
            while (it.next()) |entry| {
                try cloned.put(
                    arena,
                    try arena.dupe(u8, entry.key_ptr.*),
                    try cloneValue(arena, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = cloned };
        },
    };
}

fn valueEql(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

    return switch (a) {
        .null => true,
        .bool => |inner| inner == b.bool,
        .integer => |inner| inner == b.integer,
        .float => |inner| inner == b.float,
        .number_string => |inner| std.mem.eql(u8, inner, b.number_string),
        .string => |inner| std.mem.eql(u8, inner, b.string),
        .array => |inner| blk: {
            if (inner.items.len != b.array.items.len) break :blk false;
            for (inner.items, b.array.items) |left, right| {
                if (!valueEql(left, right)) break :blk false;
            }
            break :blk true;
        },
        .object => |inner| blk: {
            if (inner.count() != b.object.count()) break :blk false;
            var it = inner.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!valueEql(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn itemsOverlapOnCommand(left: std.json.Value, right: std.json.Value) bool {
    const left_hooks = nestedHooksArray(left) orelse return false;
    const right_hooks = nestedHooksArray(right) orelse return false;

    for (left_hooks) |left_hook| {
        const left_command = hookCommand(left_hook) orelse continue;
        for (right_hooks) |right_hook| {
            const right_command = hookCommand(right_hook) orelse continue;
            if (std.mem.eql(u8, left_command, right_command)) return true;
        }
    }
    return false;
}

fn itemsOverlapOnClumsiesHookKind(left: std.json.Value, right: std.json.Value) bool {
    const left_hooks = nestedHooksArray(left) orelse return false;
    const right_hooks = nestedHooksArray(right) orelse return false;

    for (left_hooks) |left_hook| {
        const left_command = hookCommand(left_hook) orelse continue;
        const left_kind = clumsiesHookScriptName(left_command) orelse continue;
        for (right_hooks) |right_hook| {
            const right_command = hookCommand(right_hook) orelse continue;
            const right_kind = clumsiesHookScriptName(right_command) orelse continue;
            if (std.mem.eql(u8, left_kind, right_kind)) return true;
        }
    }
    return false;
}

fn namedHooksOverlapOnCommand(left: std.json.Value, right: std.json.Value) bool {
    const left_command = hookCommand(left) orelse return false;
    const right_command = hookCommand(right) orelse return false;
    return std.mem.eql(u8, left_command, right_command);
}

fn namedHooksOverlapOnClumsiesHookKind(left: std.json.Value, right: std.json.Value) bool {
    const left_command = hookCommand(left) orelse return false;
    const right_command = hookCommand(right) orelse return false;
    const left_kind = clumsiesHookScriptName(left_command) orelse return false;
    const right_kind = clumsiesHookScriptName(right_command) orelse return false;
    return std.mem.eql(u8, left_kind, right_kind);
}

fn managedHookItemCanReplace(current_item: std.json.Value, managed_item: std.json.Value) bool {
    const current_object = asObject(current_item) orelse return false;
    const managed_object = asObject(managed_item) orelse return false;
    if (current_object.count() != managed_object.count()) return false;

    var it = managed_object.iterator();
    while (it.next()) |entry| {
        const current_value = current_object.get(entry.key_ptr.*) orelse return false;
        if (std.mem.eql(u8, entry.key_ptr.*, "hooks")) {
            if (!hookArraysCanReplace(current_value, entry.value_ptr.*)) return false;
            continue;
        }
        if (!valueEql(current_value, entry.value_ptr.*)) return false;
    }
    return true;
}

fn hookArraysCanReplace(current_hooks_value: std.json.Value, managed_hooks_value: std.json.Value) bool {
    const current_hooks = switch (current_hooks_value) {
        .array => |array| array.items,
        else => return false,
    };
    const managed_hooks = switch (managed_hooks_value) {
        .array => |array| array.items,
        else => return false,
    };
    if (current_hooks.len != managed_hooks.len) return false;

    var replaced_command = false;
    for (current_hooks, managed_hooks) |current_hook, managed_hook| {
        const current_object = asObject(current_hook) orelse return false;
        const managed_object = asObject(managed_hook) orelse return false;
        if (current_object.count() != managed_object.count()) return false;

        var it = managed_object.iterator();
        while (it.next()) |entry| {
            const current_value = current_object.get(entry.key_ptr.*) orelse return false;
            if (std.mem.eql(u8, entry.key_ptr.*, "command")) {
                const current_command = switch (current_value) {
                    .string => |string| string,
                    else => return false,
                };
                const managed_command = switch (entry.value_ptr.*) {
                    .string => |string| string,
                    else => return false,
                };
                if (std.mem.eql(u8, current_command, managed_command)) continue;
                const current_kind = clumsiesHookScriptName(current_command) orelse return false;
                const managed_kind = clumsiesHookScriptName(managed_command) orelse return false;
                if (!std.mem.eql(u8, current_kind, managed_kind)) return false;
                replaced_command = true;
                continue;
            }
            if (!valueEql(current_value, entry.value_ptr.*)) return false;
        }
    }
    return replaced_command;
}

fn managedNamedHookCanReplace(current_item: std.json.Value, managed_item: std.json.Value) bool {
    const current_object = asObject(current_item) orelse return false;
    const managed_object = asObject(managed_item) orelse return false;
    if (current_object.count() != managed_object.count()) return false;

    var it = managed_object.iterator();
    while (it.next()) |entry| {
        const current_value = current_object.get(entry.key_ptr.*) orelse return false;
        if (std.mem.eql(u8, entry.key_ptr.*, "command")) {
            const current_command = switch (current_value) {
                .string => |string| string,
                else => return false,
            };
            const managed_command = switch (entry.value_ptr.*) {
                .string => |string| string,
                else => return false,
            };
            if (std.mem.eql(u8, current_command, managed_command)) continue;
            const current_kind = clumsiesHookScriptName(current_command) orelse return false;
            const managed_kind = clumsiesHookScriptName(managed_command) orelse return false;
            if (!std.mem.eql(u8, current_kind, managed_kind)) return false;
            continue;
        }
        if (!valueEql(current_value, entry.value_ptr.*)) return false;
    }
    return true;
}

fn clumsiesHookScriptName(command: []const u8) ?[]const u8 {
    const names = [_][]const u8{
        "session-start.sh",
        "stop-refer-check.sh",
        "user-prompt-submit.sh",
        "pre-invocation.sh",
    };
    for (names) |name| {
        const name_pos = std.mem.indexOf(u8, command, name) orelse continue;
        const prefix = command[0..name_pos];
        if (std.mem.indexOf(u8, prefix, "/.codex/hooks/") != null or
            std.mem.indexOf(u8, prefix, "/.agents/hooks/") != null)
        {
            return name;
        }
    }
    return null;
}

fn nestedHooksArray(item: std.json.Value) ?[]const std.json.Value {
    const object = asObject(item) orelse return null;
    const hooks = object.get("hooks") orelse return null;
    return switch (hooks) {
        .array => |array| array.items,
        else => null,
    };
}

fn hookCommand(hook: std.json.Value) ?[]const u8 {
    const object = asObject(hook) orelse return null;
    const command = object.get("command") orelse return null;
    return switch (command) {
        .string => |string| string,
        else => null,
    };
}

fn asObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn asObjectPtr(value: *std.json.Value) ?*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*object| object,
        else => null,
    };
}

fn asArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn asArrayPtr(value: *std.json.Value) ?*std.json.Array {
    return switch (value.*) {
        .array => |*array| array,
        else => null,
    };
}

test "prepareJsonHooksRegistry appends managed entries without dropping foreign hooks" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "echo foreign"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup|resume",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/workspace/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try prepareJsonHooksRegistry(allocator, existing, managed);
    switch (result) {
        .conflict => |message| {
            std.debug.print("unexpected conflict: {s}\n", .{message});
            return error.UnexpectedConflict;
        },
        .prepared => |prepared| {
            defer {
                var owned = prepared;
                owned.deinit(allocator);
            }
            try std.testing.expectEqualStrings("update", prepared.action);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "echo foreign") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "session-start.sh") != null);
        },
    }
}

test "prepareJsonHooksRegistry removes retired clumsies hooks and keeps foreign hooks" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/workspace/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      },
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "echo foreign"
        \\          }
        \\        ]
        \\      }
        \\    ],
        \\    "Stop": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/workspace/.codex/hooks/stop-refer-check.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ],
        \\    "UserPromptSubmit": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/workspace/.codex/hooks/user-prompt-submit.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "hooks": {
        \\    "UserPromptSubmit": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/workspace/.codex/hooks/user-prompt-submit.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try prepareJsonHooksRegistry(allocator, existing, managed);
    switch (result) {
        .conflict => |message| {
            std.debug.print("unexpected conflict: {s}\n", .{message});
            return error.UnexpectedConflict;
        },
        .prepared => |prepared| {
            defer {
                var owned = prepared;
                owned.deinit(allocator);
            }
            try std.testing.expectEqualStrings("update", prepared.action);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "session-start.sh") == null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "stop-refer-check.sh") == null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "echo foreign") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "user-prompt-submit.sh") != null);
        },
    }
}

test "prepareJsonHooksRegistry replaces stale clumsies hook paths" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup|resume",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/old/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup|resume",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/new/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try prepareJsonHooksRegistry(allocator, existing, managed);
    switch (result) {
        .conflict => |message| {
            std.debug.print("unexpected conflict: {s}\n", .{message});
            return error.UnexpectedConflict;
        },
        .prepared => |prepared| {
            defer {
                var owned = prepared;
                owned.deinit(allocator);
            }
            try std.testing.expectEqualStrings("update", prepared.action);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "/old/.codex") == null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "/new/.codex/hooks/session-start.sh") != null);
        },
    }
}

test "prepareJsonHooksRegistry rejects drifted stale clumsies hook entries" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "resume-only",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/old/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup|resume",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/new/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try prepareJsonHooksRegistry(allocator, existing, managed);
    switch (result) {
        .conflict => |message| try std.testing.expectEqualStrings(conflict_incompatible_item, message),
        else => return error.ExpectedConflict,
    }
}

test "prepareJsonHooksRegistry rejects exact hook plus stale duplicate" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup|resume",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/new/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      },
        \\      {
        \\        "matcher": "startup|resume",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/old/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup|resume",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/new/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try prepareJsonHooksRegistry(allocator, existing, managed);
    switch (result) {
        .conflict => |message| try std.testing.expectEqualStrings(conflict_incompatible_item, message),
        else => return error.ExpectedConflict,
    }
}

test "removeJsonHooksRegistry keeps foreign hooks and removes managed ones" {
    const allocator = std.testing.allocator;
    const current =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "echo foreign"
        \\          }
        \\        ]
        \\      },
        \\      {
        \\        "matcher": "startup|resume",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/workspace/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup|resume",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/workspace/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try removeJsonHooksRegistry(allocator, current, managed);
    switch (result) {
        .rewrite => |content| {
            defer allocator.free(content);
            try std.testing.expect(std.mem.indexOf(u8, content, "echo foreign") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "session-start.sh") == null);
        },
        else => return error.UnexpectedRemoveResult,
    }
}

test "removeJsonHooksRegistry blocks drifted managed hook entries" {
    const allocator = std.testing.allocator;
    const current =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "resume-only",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/workspace/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup|resume",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "bash \"/workspace/.codex/hooks/session-start.sh\""
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try removeJsonHooksRegistry(allocator, current, managed);
    switch (result) {
        .conflict => |message| try std.testing.expectEqualStrings(conflict_incompatible_item, message),
        else => return error.ExpectedConflict,
    }
}

test "prepareJsonNamedHooksRegistry overwrites empty named hooks without conflict" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "clumsies": {}
        \\}
    ;
    const managed =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/new/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try prepareJsonNamedHooksRegistry(allocator, existing, managed);
    switch (result) {
        .conflict => |message| {
            std.debug.print("unexpected conflict: {s}\n", .{message});
            return error.UnexpectedConflict;
        },
        .prepared => |prepared| {
            defer {
                var owned = prepared;
                owned.deinit(allocator);
            }
            try std.testing.expectEqualStrings("update", prepared.action);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "pre-invocation.sh") != null);
        },
    }
}

test "prepareJsonNamedHooksRegistry handles robust clumsiesHookScriptName checks" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash /old/.agents/hooks/pre-invocation.sh --verbose"
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/new/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try prepareJsonNamedHooksRegistry(allocator, existing, managed);
    switch (result) {
        .conflict => |message| {
            std.debug.print("unexpected conflict: {s}\n", .{message});
            return error.UnexpectedConflict;
        },
        .prepared => |prepared| {
            defer {
                var owned = prepared;
                owned.deinit(allocator);
            }
            try std.testing.expectEqualStrings("update", prepared.action);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "/new/.agents") != null);
        },
    }
}

test "prepareJsonNamedHooksRegistry preserves extra named hook events and handlers" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "echo foreign"
        \\      },
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/old/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ],
        \\    "UserEvent": [
        \\      {
        \\        "type": "command",
        \\        "command": "echo user-event"
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/new/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try prepareJsonNamedHooksRegistry(allocator, existing, managed);
    switch (result) {
        .conflict => |message| {
            std.debug.print("unexpected conflict: {s}\n", .{message});
            return error.UnexpectedConflict;
        },
        .prepared => |prepared| {
            defer {
                var owned = prepared;
                owned.deinit(allocator);
            }
            try std.testing.expectEqualStrings("update", prepared.action);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "echo foreign") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "echo user-event") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "/old/.agents") == null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "/new/.agents/hooks/pre-invocation.sh") != null);
        },
    }
}

test "prepareJsonNamedHooksRegistry preserves generic hooks paths" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/workspace/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/new/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try prepareJsonNamedHooksRegistry(allocator, existing, managed);
    switch (result) {
        .conflict => |message| {
            std.debug.print("unexpected conflict: {s}\n", .{message});
            return error.UnexpectedConflict;
        },
        .prepared => |prepared| {
            defer {
                var owned = prepared;
                owned.deinit(allocator);
            }
            try std.testing.expectEqualStrings("update", prepared.action);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "/workspace/hooks/pre-invocation.sh") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "/new/.agents/hooks/pre-invocation.sh") != null);
        },
    }
}

test "removeJsonNamedHooksRegistry allows removal of drifted named hook paths" {
    const allocator = std.testing.allocator;
    const current =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/old/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/new/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try removeJsonNamedHooksRegistry(allocator, current, managed);
    switch (result) {
        .delete_file => {},
        else => return error.UnexpectedRemoveResult,
    }
}

test "removeJsonNamedHooksRegistry preserves unrelated named hook content" {
    const allocator = std.testing.allocator;
    const current =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "echo foreign"
        \\      },
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/old/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ],
        \\    "UserEvent": [
        \\      {
        \\        "type": "command",
        \\        "command": "echo user-event"
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/new/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try removeJsonNamedHooksRegistry(allocator, current, managed);
    switch (result) {
        .rewrite => |content| {
            defer allocator.free(content);
            try std.testing.expect(std.mem.indexOf(u8, content, "echo foreign") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "echo user-event") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "pre-invocation.sh") == null);
        },
        else => return error.UnexpectedRemoveResult,
    }
}

test "removeJsonNamedHooksRegistry preserves generic hooks paths" {
    const allocator = std.testing.allocator;
    const current =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/workspace/hooks/pre-invocation.sh\""
        \\      },
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/new/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/new/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try removeJsonNamedHooksRegistry(allocator, current, managed);
    switch (result) {
        .rewrite => |content| {
            defer allocator.free(content);
            try std.testing.expect(std.mem.indexOf(u8, content, "/workspace/hooks/pre-invocation.sh") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "/new/.agents/hooks/pre-invocation.sh") == null);
        },
        else => return error.UnexpectedRemoveResult,
    }
}

test "removeJsonNamedHooksRegistry skips duplicate removal indexes" {
    const allocator = std.testing.allocator;
    const current =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/old/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "clumsies": {
        \\    "PreInvocation": [
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/new/.agents/hooks/pre-invocation.sh\""
        \\      },
        \\      {
        \\        "type": "command",
        \\        "command": "bash \"/new/.agents/hooks/pre-invocation.sh\""
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const result = try removeJsonNamedHooksRegistry(allocator, current, managed);
    switch (result) {
        .delete_file => {},
        else => return error.UnexpectedRemoveResult,
    }
}
