const std = @import("std");
const toml = @import("toml");

pub const TomlPlanResult = union(enum) {
    prepared: PreparedTomlFile,
    conflict: []const u8,
};

pub const PreparedTomlFile = struct {
    action: []const u8,
    rendered_content: []u8,
    managed_content: []u8,

    pub fn deinit(self: *PreparedTomlFile, allocator: std.mem.Allocator) void {
        allocator.free(self.rendered_content);
        allocator.free(self.managed_content);
    }
};

pub const TomlRemoveResult = union(enum) {
    delete_file,
    rewrite: []u8,
    already_absent,
    conflict: []const u8,
};

const conflict_invalid_toml = "Existing TOML file is not valid TOML.";
const conflict_invalid_fragment = "Managed TOML fragment is not valid TOML.";
const conflict_merge = "Existing TOML content conflicts with the clumsies fragment that needs to be installed.";

pub fn prepareTomlFragment(
    allocator: std.mem.Allocator,
    existing_content_opt: ?[]const u8,
    managed_fragment: []const u8,
    previous_managed_fragment_opt: ?[]const u8,
) !TomlPlanResult {
    var managed_parsed = parseTomlTable(allocator, managed_fragment) catch return .{ .conflict = conflict_invalid_fragment };
    defer managed_parsed.deinit();

    if (existing_content_opt == null) {
        return .{ .prepared = .{
            .action = "create",
            .rendered_content = try allocator.dupe(u8, managed_fragment),
            .managed_content = try allocator.dupe(u8, managed_fragment),
        } };
    }

    const existing_content = existing_content_opt.?;
    var current_parsed = parseTomlTable(allocator, existing_content) catch return .{ .conflict = conflict_invalid_toml };
    defer current_parsed.deinit();

    var merge_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer merge_arena_state.deinit();
    const arena = merge_arena_state.allocator();

    var current_root = try cloneTable(arena, current_parsed.value);
    var did_change = false;

    if (previous_managed_fragment_opt) |previous_managed_fragment| {
        if (!std.mem.eql(u8, previous_managed_fragment, managed_fragment)) {
            var previous_parsed = parseTomlTable(allocator, previous_managed_fragment) catch return .{ .conflict = conflict_invalid_fragment };
            defer previous_parsed.deinit();
            removeTableFragment(&current_root, &previous_parsed.value, &did_change) catch return .{ .conflict = conflict_merge };
        }
    }

    mergeTableFragment(arena, &current_root, &managed_parsed.value, &did_change) catch return .{ .conflict = conflict_merge };

    return .{ .prepared = .{
        .action = if (did_change) "update" else "keep",
        .rendered_content = if (did_change)
            try renderTomlAlloc(allocator, current_root)
        else
            try allocator.dupe(u8, existing_content),
        .managed_content = try allocator.dupe(u8, managed_fragment),
    } };
}

pub fn removeTomlFragment(
    allocator: std.mem.Allocator,
    current_content: []const u8,
    managed_fragment: []const u8,
) !TomlRemoveResult {
    var managed_parsed = parseTomlTable(allocator, managed_fragment) catch return .{ .conflict = conflict_invalid_fragment };
    defer managed_parsed.deinit();

    var current_parsed = parseTomlTable(allocator, current_content) catch return .{ .conflict = conflict_invalid_toml };
    defer current_parsed.deinit();

    var current_root = current_parsed.value;
    var did_remove = false;

    removeTableFragment(&current_root, &managed_parsed.value, &did_remove) catch return .{ .conflict = conflict_merge };

    if (!did_remove) return .already_absent;
    if (current_root.count() == 0) return .delete_file;

    return .{ .rewrite = try renderTomlAlloc(allocator, current_root) };
}

fn parseTomlTable(allocator: std.mem.Allocator, content: []const u8) !toml.Parsed(toml.Table) {
    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    return try parser.parseString(content);
}

fn renderTomlAlloc(allocator: std.mem.Allocator, table: toml.Table) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var path: std.ArrayList([]const u8) = .empty;
    defer path.deinit(allocator);

    try renderTable(allocator, &out, &table, &path, true);
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn mergeTableFragment(
    arena: std.mem.Allocator,
    current: *toml.Table,
    managed: *const toml.Table,
    did_change: *bool,
) (error{ OutOfMemory, Conflict })!void {
    var it = managed.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const managed_value = entry.value_ptr.*;

        if (current.getPtr(key)) |current_value| {
            try mergeValueFragment(arena, current_value, managed_value, did_change);
        } else {
            try putOwnedValue(arena, current, key, try cloneValue(arena, managed_value));
            did_change.* = true;
        }
    }
}

fn mergeValueFragment(
    arena: std.mem.Allocator,
    current: *toml.Value,
    managed: toml.Value,
    did_change: *bool,
) (error{ OutOfMemory, Conflict })!void {
    if (current.* == .table and managed == .table) {
        try mergeTableFragment(arena, current.table, managed.table, did_change);
        return;
    }

    if (!valueEql(current.*, managed)) return error.Conflict;
}

fn removeTableFragment(
    current: *toml.Table,
    managed: *const toml.Table,
    did_remove: *bool,
) error{Conflict}!void {
    var it = managed.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const managed_value = entry.value_ptr.*;
        const current_value = current.getPtr(key) orelse continue;

        if (current_value.* == .table and managed_value == .table) {
            try removeTableFragment(current_value.table, managed_value.table, did_remove);
            if (current_value.table.count() == 0) {
                _ = current.remove(key);
                did_remove.* = true;
            }
            continue;
        }

        if (!valueEql(current_value.*, managed_value)) return error.Conflict;
        _ = current.remove(key);
        did_remove.* = true;
    }
}

fn putOwnedValue(
    arena: std.mem.Allocator,
    table: *toml.Table,
    key: []const u8,
    value: toml.Value,
) !void {
    try table.put(try arena.dupe(u8, key), value);
}

fn cloneValue(arena: std.mem.Allocator, value: toml.Value) error{OutOfMemory}!toml.Value {
    return switch (value) {
        .string => |inner| .{ .string = try arena.dupe(u8, inner) },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .boolean => |inner| .{ .boolean = inner },
        .date => |inner| .{ .date = inner },
        .time => |inner| .{ .time = inner },
        .datetime => |inner| .{ .datetime = inner },
        .array => |inner| blk: {
            const list = try arena.create(toml.ValueList);
            list.* = .empty;
            for (inner.items) |item| {
                try list.append(arena, try cloneValue(arena, item));
            }
            break :blk .{ .array = list };
        },
        .table => |inner| blk: {
            const cloned = try arena.create(toml.Table);
            cloned.* = try cloneTable(arena, inner.*);
            break :blk .{ .table = cloned };
        },
    };
}

fn cloneTable(arena: std.mem.Allocator, table: toml.Table) error{OutOfMemory}!toml.Table {
    var cloned = toml.Table.init(arena);
    var it = table.iterator();
    while (it.next()) |entry| {
        try putOwnedValue(arena, &cloned, entry.key_ptr.*, try cloneValue(arena, entry.value_ptr.*));
    }
    return cloned;
}

fn valueEql(left: toml.Value, right: toml.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;

    return switch (left) {
        .string => |inner| std.mem.eql(u8, inner, right.string),
        .integer => |inner| inner == right.integer,
        .float => |inner| inner == right.float,
        .boolean => |inner| inner == right.boolean,
        .date => |inner| std.meta.eql(inner, right.date),
        .time => |inner| std.meta.eql(inner, right.time),
        .datetime => |inner| std.meta.eql(inner, right.datetime),
        .array => |inner| blk: {
            if (inner.items.len != right.array.items.len) break :blk false;
            for (inner.items, right.array.items) |left_item, right_item| {
                if (!valueEql(left_item, right_item)) break :blk false;
            }
            break :blk true;
        },
        .table => |inner| blk: {
            if (inner.count() != right.table.count()) break :blk false;
            var it = inner.iterator();
            while (it.next()) |entry| {
                const other = right.table.get(entry.key_ptr.*) orelse break :blk false;
                if (!valueEql(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn renderTable(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    table: *const toml.Table,
    path: *std.ArrayList([]const u8),
    is_root: bool,
) !void {
    const keys = try sortedKeys(allocator, table);
    defer allocator.free(keys);

    var wrote_header = false;
    if (!is_root and hasScalarEntries(table)) {
        try writeTableHeader(allocator, out, path.items, false);
        wrote_header = true;
    }

    for (keys) |key| {
        const value = table.get(key).?;
        if (isChildTable(value) or isArrayOfTables(value)) continue;
        try out.appendSlice(allocator, key);
        try out.appendSlice(allocator, " = ");
        try renderValue(allocator, out, value);
        try out.append(allocator, '\n');
    }

    for (keys) |key| {
        const value = table.get(key).?;
        if (!isChildTable(value)) continue;

        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        if (out.items.len > 1) {
            try out.append(allocator, '\n');
        }

        try path.append(allocator, key);
        defer _ = path.pop();
        try renderTable(allocator, out, value.table, path, false);
    }

    for (keys) |key| {
        const value = table.get(key).?;
        if (!isArrayOfTables(value)) continue;

        try path.append(allocator, key);
        defer _ = path.pop();

        for (value.array.items, 0..) |item, idx| {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
                try out.append(allocator, '\n');
            }
            if (out.items.len > 1 and idx == 0) {
                try out.append(allocator, '\n');
            }
            try writeTableHeader(allocator, out, path.items, true);
            try renderArrayTableBody(allocator, out, item.table);
        }
    }

    if (!is_root and wrote_header and !hasChildTables(table) and !hasArrayTableEntries(table)) {
        return;
    }
}

fn renderArrayTableBody(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    table: *const toml.Table,
) !void {
    const keys = try sortedKeys(allocator, table);
    defer allocator.free(keys);

    for (keys) |key| {
        const value = table.get(key).?;
        if (isChildTable(value) or isArrayOfTables(value)) continue;
        try out.appendSlice(allocator, key);
        try out.appendSlice(allocator, " = ");
        try renderValue(allocator, out, value);
        try out.append(allocator, '\n');
    }
}

fn writeTableHeader(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: []const []const u8,
    is_array: bool,
) !void {
    try out.appendSlice(allocator, if (is_array) "[[" else "[");
    for (path, 0..) |part, idx| {
        if (idx > 0) try out.append(allocator, '.');
        try renderKey(allocator, out, part);
    }
    try out.appendSlice(allocator, if (is_array) "]]\n" else "]\n");
}

fn renderValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: toml.Value,
) !void {
    switch (value) {
        .string => |inner| try renderString(allocator, out, inner),
        .integer => |inner| try out.print(allocator, "{d}", .{inner}),
        .float => |inner| try out.print(allocator, "{d}", .{inner}),
        .boolean => |inner| try out.appendSlice(allocator, if (inner) "true" else "false"),
        .date => |inner| try out.print(allocator, "{d}-{d:0>2}-{d:0>2}", .{ inner.year, inner.month, inner.day }),
        .time => |inner| {
            try out.print(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ inner.hour, inner.minute, inner.second });
            if (inner.nanosecond != 0) {
                try out.print(allocator, ".{d}", .{inner.nanosecond});
            }
        },
        .datetime => |inner| {
            try renderValue(allocator, out, .{ .date = inner.date });
            try out.append(allocator, 'T');
            try renderValue(allocator, out, .{ .time = inner.time });
            if (inner.offset_minutes) |offset| {
                if (offset == 0) {
                    try out.append(allocator, 'Z');
                } else {
                    const abs_offset = @abs(offset);
                    const hours = @divTrunc(abs_offset, 60);
                    const minutes = @mod(abs_offset, 60);
                    try out.print(allocator, "{s}{d:0>2}:{d:0>2}", .{
                        if (offset < 0) "-" else "+",
                        hours,
                        minutes,
                    });
                }
            }
        },
        .array => |inner| {
            try out.appendSlice(allocator, "[");
            for (inner.items, 0..) |item, idx| {
                if (idx > 0) try out.appendSlice(allocator, ", ");
                try renderValue(allocator, out, item);
            }
            try out.appendSlice(allocator, "]");
        },
        .table => |inner| {
            try out.appendSlice(allocator, "{ ");
            const keys = try sortedKeys(allocator, inner);
            defer allocator.free(keys);
            for (keys, 0..) |key, idx| {
                if (idx > 0) try out.appendSlice(allocator, ", ");
                try renderKey(allocator, out, key);
                try out.appendSlice(allocator, " = ");
                try renderValue(allocator, out, inner.get(key).?);
            }
            try out.appendSlice(allocator, " }");
        },
    }
}

fn renderKey(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
) !void {
    if (isBareKey(key)) {
        try out.appendSlice(allocator, key);
        return;
    }
    try renderString(allocator, out, key);
}

fn renderString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) !void {
    try out.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, byte),
        }
    }
    try out.append(allocator, '"');
}

fn sortedKeys(allocator: std.mem.Allocator, table: *const toml.Table) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);

    var it = table.iterator();
    while (it.next()) |entry| {
        try keys.append(allocator, entry.key_ptr.*);
    }

    std.mem.sortUnstable([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    return keys.toOwnedSlice(allocator);
}

fn hasScalarEntries(table: *const toml.Table) bool {
    var it = table.iterator();
    while (it.next()) |entry| {
        const value = entry.value_ptr.*;
        if (!isChildTable(value) and !isArrayOfTables(value)) return true;
    }
    return false;
}

fn hasChildTables(table: *const toml.Table) bool {
    var it = table.iterator();
    while (it.next()) |entry| {
        if (isChildTable(entry.value_ptr.*)) return true;
    }
    return false;
}

fn hasArrayTableEntries(table: *const toml.Table) bool {
    var it = table.iterator();
    while (it.next()) |entry| {
        if (isArrayOfTables(entry.value_ptr.*)) return true;
    }
    return false;
}

fn isChildTable(value: toml.Value) bool {
    return value == .table;
}

fn isArrayOfTables(value: toml.Value) bool {
    if (value != .array) return false;
    if (value.array.items.len == 0) return false;
    return value.array.items[0] == .table;
}

fn isBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

test "prepareTomlFragment merges managed keys into existing config" {
    const allocator = std.testing.allocator;
    const existing =
        \\model = "gpt-5"
        \\
        \\[sandbox_workspace_write]
        \\network_access = true
        \\
    ;
    const managed =
        \\[features]
        \\hooks = true
        \\
        \\[mcp_servers.clumsies]
        \\command = "clumsies"
        \\args = ["mcp", "serve"]
        \\
    ;

    const result = try prepareTomlFragment(allocator, existing, managed, null);
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
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "model = \"gpt-5\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "[features]") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "hooks = true") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "[mcp_servers.clumsies]") != null);
        },
    }
}

test "prepareTomlFragment conflicts on incompatible nested values" {
    const allocator = std.testing.allocator;
    const existing =
        \\[mcp_servers.clumsies]
        \\command = "other"
        \\args = ["serve"]
        \\
    ;
    const managed =
        \\[features]
        \\hooks = true
        \\
        \\[mcp_servers.clumsies]
        \\command = "clumsies"
        \\args = ["mcp", "serve"]
        \\
    ;

    const result = try prepareTomlFragment(allocator, existing, managed, null);
    switch (result) {
        .conflict => |message| try std.testing.expectEqualStrings(conflict_merge, message),
        else => return error.ExpectedConflict,
    }
}

test "prepareTomlFragment replaces previous managed keys" {
    const allocator = std.testing.allocator;
    const existing =
        \\model = "gpt-5"
        \\
        \\[features]
        \\codex_hooks = true
        \\
    ;
    const previous =
        \\[features]
        \\codex_hooks = true
        \\
    ;
    const managed =
        \\[features]
        \\hooks = true
        \\
    ;

    const result = try prepareTomlFragment(allocator, existing, managed, previous);
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
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "model = \"gpt-5\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "hooks = true") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "codex_hooks") == null);
        },
    }
}

test "removeTomlFragment removes only managed keys and preserves foreign config" {
    const allocator = std.testing.allocator;
    const current =
        \\model = "gpt-5"
        \\
        \\[features]
        \\hooks = true
        \\
        \\[mcp_servers.clumsies]
        \\command = "clumsies"
        \\args = ["mcp", "serve"]
        \\
    ;
    const managed =
        \\[features]
        \\hooks = true
        \\
        \\[mcp_servers.clumsies]
        \\command = "clumsies"
        \\args = ["mcp", "serve"]
        \\
    ;

    const result = try removeTomlFragment(allocator, current, managed);
    switch (result) {
        .rewrite => |content| {
            defer allocator.free(content);
            try std.testing.expect(std.mem.indexOf(u8, content, "model = \"gpt-5\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "hooks") == null);
            try std.testing.expect(std.mem.indexOf(u8, content, "mcp_servers.clumsies") == null);
        },
        else => return error.UnexpectedRemoveResult,
    }
}

test "removeTomlFragment conflicts when managed content drifted" {
    const allocator = std.testing.allocator;
    const current =
        \\[features]
        \\hooks = false
        \\
    ;
    const managed =
        \\[features]
        \\hooks = true
        \\
    ;

    const result = try removeTomlFragment(allocator, current, managed);
    switch (result) {
        .conflict => |message| try std.testing.expectEqualStrings(conflict_merge, message),
        else => return error.ExpectedConflict,
    }
}
