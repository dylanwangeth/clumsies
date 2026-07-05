const std = @import("std");

pub const McpPlanResult = union(enum) {
    prepared: PreparedMcpFile,
    conflict: []const u8,
};

pub const PreparedMcpFile = struct {
    action: []const u8,
    rendered_content: []u8,
    managed_content: []u8,

    pub fn deinit(self: *PreparedMcpFile, allocator: std.mem.Allocator) void {
        allocator.free(self.rendered_content);
        allocator.free(self.managed_content);
    }
};

pub const McpRemoveResult = union(enum) {
    delete_file,
    rewrite: []u8,
    already_absent,
    conflict: []const u8,
};

const conflict_invalid_json = "Existing MCP registry is not valid JSON.";
const conflict_invalid_root = "Existing MCP registry must be a JSON object.";
const conflict_invalid_mcp_servers = "Existing MCP registry has a non-object `mcpServers` field.";
const conflict_incompatible_entry = "Existing MCP registry already contains a clumsies-managed MCP server with incompatible content.";
const conflict_invalid_fragment = "Internal managed MCP fragment is invalid.";

pub fn prepareJsonMcpRegistry(
    allocator: std.mem.Allocator,
    existing_content_opt: ?[]const u8,
    managed_fragment: []const u8,
) !McpPlanResult {
    const managed_parsed = std.json.parseFromSlice(std.json.Value, allocator, managed_fragment, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_fragment };
    defer managed_parsed.deinit();

    const managed_servers = getMcpServersObject(managed_parsed.value) orelse return .{ .conflict = conflict_invalid_fragment };

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
    const current_servers = ensureMcpServersObject(current_root, arena) catch return .{ .conflict = conflict_invalid_mcp_servers };

    var did_change = false;
    var it = managed_servers.iterator();
    while (it.next()) |entry| {
        const current_value = current_servers.getPtr(entry.key_ptr.*);
        if (current_value == null) {
            try current_servers.put(
                arena,
                try arena.dupe(u8, entry.key_ptr.*),
                try cloneValue(arena, entry.value_ptr.*),
            );
            did_change = true;
            continue;
        }
        if (!valueEql(current_value.?.*, entry.value_ptr.*)) {
            return .{ .conflict = conflict_incompatible_entry };
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

pub fn removeJsonMcpRegistry(
    allocator: std.mem.Allocator,
    current_content: []const u8,
    managed_fragment: []const u8,
) !McpRemoveResult {
    const managed_parsed = std.json.parseFromSlice(std.json.Value, allocator, managed_fragment, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_fragment };
    defer managed_parsed.deinit();

    const managed_servers = getMcpServersObject(managed_parsed.value) orelse return .{ .conflict = conflict_invalid_fragment };

    var current_parsed = std.json.parseFromSlice(std.json.Value, allocator, current_content, .{
        .allocate = .alloc_always,
    }) catch return .{ .conflict = conflict_invalid_json };
    defer current_parsed.deinit();

    const current_root = asObjectPtr(&current_parsed.value) orelse return .{ .conflict = conflict_invalid_root };
    const current_servers_value = current_root.getPtr("mcpServers") orelse return .already_absent;
    const current_servers = asObjectPtr(current_servers_value) orelse return .{ .conflict = conflict_invalid_mcp_servers };

    var did_remove = false;
    var it = managed_servers.iterator();
    while (it.next()) |entry| {
        const current_value = current_servers.get(entry.key_ptr.*) orelse continue;
        if (!valueEql(current_value, entry.value_ptr.*)) {
            return .{ .conflict = conflict_incompatible_entry };
        }
        _ = current_servers.orderedRemove(entry.key_ptr.*);
        did_remove = true;
    }

    if (!did_remove) return .already_absent;

    if (current_servers.count() == 0) {
        _ = current_root.orderedRemove("mcpServers");
    }
    if (current_root.count() == 0) {
        return .delete_file;
    }

    return .{ .rewrite = try renderPrettyJsonAlloc(allocator, current_parsed.value) };
}

fn getMcpServersObject(root_value: std.json.Value) ?std.json.ObjectMap {
    const root_object = asObject(root_value) orelse return null;
    const mcp_servers_value = root_object.get("mcpServers") orelse return null;
    return asObject(mcp_servers_value);
}

fn ensureMcpServersObject(root_object: *std.json.ObjectMap, arena: std.mem.Allocator) !*std.json.ObjectMap {
    if (root_object.getPtr("mcpServers")) |value| {
        return asObjectPtr(value) orelse error.InvalidMcpServersContainer;
    }
    try root_object.put(arena, "mcpServers", .{ .object = .empty });
    return asObjectPtr(root_object.getPtr("mcpServers").?).?;
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

test "prepareJsonMcpRegistry appends managed servers without dropping foreign servers" {
    const allocator = std.testing.allocator;
    const existing =
        \\{
        \\  "mcpServers": {
        \\    "foreign": {
        \\      "command": "foreign"
        \\    }
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "mcpServers": {
        \\    "clumsies": {
        \\      "command": "clumsies",
        \\      "args": ["mcp", "serve"]
        \\    }
        \\  }
        \\}
    ;

    const result = try prepareJsonMcpRegistry(allocator, existing, managed);
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
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "\"foreign\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, prepared.rendered_content, "\"clumsies\"") != null);
        },
    }
}

test "removeJsonMcpRegistry keeps foreign servers and removes managed ones" {
    const allocator = std.testing.allocator;
    const current =
        \\{
        \\  "mcpServers": {
        \\    "foreign": {
        \\      "command": "foreign"
        \\    },
        \\    "clumsies": {
        \\      "command": "clumsies",
        \\      "args": ["mcp", "serve"]
        \\    }
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "mcpServers": {
        \\    "clumsies": {
        \\      "command": "clumsies",
        \\      "args": ["mcp", "serve"]
        \\    }
        \\  }
        \\}
    ;

    const result = try removeJsonMcpRegistry(allocator, current, managed);
    switch (result) {
        .rewrite => |content| {
            defer allocator.free(content);
            try std.testing.expect(std.mem.indexOf(u8, content, "\"foreign\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "\"clumsies\"") == null);
        },
        else => return error.UnexpectedRemoveResult,
    }
}

test "removeJsonMcpRegistry blocks drifted managed servers" {
    const allocator = std.testing.allocator;
    const current =
        \\{
        \\  "mcpServers": {
        \\    "clumsies": {
        \\      "command": "clumsies-alt",
        \\      "args": ["mcp", "serve"]
        \\    }
        \\  }
        \\}
    ;
    const managed =
        \\{
        \\  "mcpServers": {
        \\    "clumsies": {
        \\      "command": "clumsies",
        \\      "args": ["mcp", "serve"]
        \\    }
        \\  }
        \\}
    ;

    const result = try removeJsonMcpRegistry(allocator, current, managed);
    switch (result) {
        .conflict => |message| try std.testing.expectEqualStrings(conflict_incompatible_entry, message),
        else => return error.ExpectedConflict,
    }
}
