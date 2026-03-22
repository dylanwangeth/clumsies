const std = @import("std");
const testing = std.testing;
const lib = @import("clumsies_lib");
const protocol = @import("protocol.zig");

const encoding = lib.encoding;
const workspace_memory = lib.workspace_memory;

pub fn buildInitializeResult(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const esc_version = try encoding.jsonEscapeAlloc(allocator, version);
    defer allocator.free(esc_version);

    const instructions =
        "Call memory.startup at task start, memory.list to discover more memory, " ++ "and memory.activate to select memory ids and receive changed content.";
    const esc_instructions = try encoding.jsonEscapeAlloc(allocator, instructions);
    defer allocator.free(esc_instructions);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"clumsies\",\"version\":\"{s}\"}},\"instructions\":\"{s}\"}}",
        .{ protocol.PROTOCOL_VERSION, esc_version, esc_instructions },
    );
}

pub fn buildToolsListResult(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(
        u8,
        "{\"tools\":[" ++ "{\"name\":\"memory.startup\",\"title\":\"Startup Memory\",\"description\":\"Return startup memory for the current workspace, including PIN and meta-prompt files, and only include content when hashes changed.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"metaPromptFiles\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"known\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"hash\":{\"type\":\"string\"}},\"required\":[\"id\",\"hash\"],\"additionalProperties\":false}}},\"additionalProperties\":false}}," ++ "{\"name\":\"memory.list\",\"title\":\"List Memory\",\"description\":\"List workspace memory metadata with optional kind, group, and query filters.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"includePrompts\":{\"type\":\"boolean\"},\"kind\":{\"type\":\"string\",\"enum\":[\"pin\",\"meta_prompt_file\",\"prompt\"]},\"group\":{\"type\":\"string\"},\"query\":{\"type\":\"string\"}},\"additionalProperties\":false}}," ++ "{\"name\":\"memory.activate\",\"title\":\"Activate Memory\",\"description\":\"Activate selected memory ids, log the activation, and return only changed content.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"known\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"hash\":{\"type\":\"string\"}},\"required\":[\"id\",\"hash\"],\"additionalProperties\":false}},\"taskId\":{\"type\":\"string\"},\"turnId\":{\"type\":\"string\"}},\"required\":[\"ids\"],\"additionalProperties\":false}}]}",
    );
}

pub fn handleToolCall(allocator: std.mem.Allocator, workspace_root: []const u8, params: std.json.Value) ![]u8 {
    const params_obj = switch (params) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };

    const name = if (params_obj.get("name")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else return error.InvalidParams;

    const arguments = params_obj.get("arguments") orelse std.json.Value{ .object = .init(allocator) };
    const args_obj = switch (arguments) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };

    if (std.mem.eql(u8, name, "memory.startup")) {
        return try handleStartupTool(allocator, workspace_root, args_obj);
    }
    if (std.mem.eql(u8, name, "memory.list")) {
        return try handleListTool(allocator, workspace_root, args_obj);
    }
    if (std.mem.eql(u8, name, "memory.activate")) {
        return handleActivateTool(allocator, workspace_root, args_obj) catch |err| switch (err) {
            error.UnknownMemoryId => try buildToolErrorResult(allocator, "Unknown memory id"),
            else => return err,
        };
    }

    return try buildToolErrorResult(allocator, "Unknown tool");
}

fn handleStartupTool(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    var known = try parseKnownList(allocator, args_obj.get("known"));
    defer known.deinit(allocator);

    var meta_prompt_files = try parseStringList(allocator, args_obj.get("metaPromptFiles"));
    defer meta_prompt_files.deinit(allocator);

    var result = try workspace_memory.startupMemory(
        allocator,
        workspace_root,
        if (meta_prompt_files.items.len > 0) meta_prompt_files.items else null,
        known.items,
    );
    defer result.deinit(allocator);

    const structured = try serializeActivationResult(allocator, &result);
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
}

fn handleListTool(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    const kind = if (args_obj.get("kind")) |value|
        try parseMemoryKind(value)
    else
        null;
    const group = if (args_obj.get("group")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else null;
    const query = if (args_obj.get("query")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else null;
    const include_prompts = if (args_obj.get("includePrompts")) |value| switch (value) {
        .bool => |flag| flag,
        else => return error.InvalidParams,
    } else true;

    var items = try workspace_memory.listMemory(allocator, workspace_root, .{
        .include_prompts = include_prompts,
        .kind = kind,
        .group = group,
        .query = query,
    });
    defer workspace_memory.deinitMemoryItems(allocator, &items);

    const structured = try serializeMemoryList(allocator, items.items);
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
}

fn handleActivateTool(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    var ids = try parseRequiredIds(allocator, args_obj.get("ids"));
    defer ids.deinit(allocator);

    var known = try parseKnownList(allocator, args_obj.get("known"));
    defer known.deinit(allocator);

    const task_id = if (args_obj.get("taskId")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else null;
    const turn_id = if (args_obj.get("turnId")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else null;

    var result = try workspace_memory.activateMemory(allocator, workspace_root, .{
        .ids = ids.items,
        .known = known.items,
        .task_id = task_id,
        .turn_id = turn_id,
    });
    defer result.deinit(allocator);

    const structured = try serializeActivationResult(allocator, &result);
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
}

fn buildToolSuccessResult(allocator: std.mem.Allocator, structured_json: []const u8) ![]u8 {
    const esc_text = try encoding.jsonEscapeAlloc(allocator, structured_json);
    defer allocator.free(esc_text);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"structuredContent\":{s},\"isError\":false}}",
        .{ esc_text, structured_json },
    );
}

fn buildToolErrorResult(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const esc_message = try encoding.jsonEscapeAlloc(allocator, message);
    defer allocator.free(esc_message);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"structuredContent\":{{\"error\":\"{s}\"}},\"isError\":true}}",
        .{ esc_message, esc_message },
    );
}

fn parseMemoryKind(value: std.json.Value) !?workspace_memory.MemoryKind {
    const str = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };

    if (std.mem.eql(u8, str, "pin")) return .pin;
    if (std.mem.eql(u8, str, "meta_prompt_file")) return .meta_prompt_file;
    if (std.mem.eql(u8, str, "prompt")) return .prompt;
    return error.InvalidParams;
}

fn parseRequiredIds(allocator: std.mem.Allocator, value_opt: ?std.json.Value) !std.ArrayList([]const u8) {
    var ids = try parseStringList(allocator, value_opt);
    errdefer ids.deinit(allocator);
    if (ids.items.len == 0) return error.InvalidParams;
    return ids;
}

fn parseStringList(allocator: std.mem.Allocator, value_opt: ?std.json.Value) !std.ArrayList([]const u8) {
    var values: std.ArrayList([]const u8) = .empty;
    errdefer values.deinit(allocator);

    const value = value_opt orelse return values;
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidParams,
    };

    for (array.items) |item| {
        const str = switch (item) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        try values.append(allocator, str);
    }

    return values;
}

fn parseKnownList(allocator: std.mem.Allocator, value_opt: ?std.json.Value) !std.ArrayList(workspace_memory.KnownMemory) {
    var known: std.ArrayList(workspace_memory.KnownMemory) = .empty;
    errdefer known.deinit(allocator);

    const value = value_opt orelse return known;
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidParams,
    };

    for (array.items) |item| {
        const object = switch (item) {
            .object => |obj| obj,
            else => return error.InvalidParams,
        };
        const id = if (object.get("id")) |field| switch (field) {
            .string => |s| s,
            else => return error.InvalidParams,
        } else return error.InvalidParams;
        const hash = if (object.get("hash")) |field| switch (field) {
            .string => |s| s,
            else => return error.InvalidParams,
        } else return error.InvalidParams;
        try known.append(allocator, .{ .id = id, .hash = hash });
    }

    return known;
}

fn serializeMemoryList(allocator: std.mem.Allocator, items: []const workspace_memory.MemoryItem) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"items\":[");
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try appendMemoryMetadata(allocator, &buf, item);
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

fn serializeActivationResult(allocator: std.mem.Allocator, result: *workspace_memory.ActivationResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"items\":[");
    for (result.items.items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try appendActivatedMemory(allocator, &buf, item);
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

fn appendMemoryMetadata(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    item: workspace_memory.MemoryItem,
) !void {
    const esc_id = try encoding.jsonEscapeAlloc(allocator, item.id);
    defer allocator.free(esc_id);
    const esc_path = try encoding.jsonEscapeAlloc(allocator, item.path);
    defer allocator.free(esc_path);
    const esc_name = try encoding.jsonEscapeAlloc(allocator, item.name);
    defer allocator.free(esc_name);

    try buf.writer(allocator).print(
        "{{\"id\":\"{s}\",\"kind\":\"{s}\",\"path\":\"{s}\",\"name\":\"{s}\",\"group\":",
        .{ esc_id, @tagName(item.kind), esc_path, esc_name },
    );
    if (item.group) |group| {
        const esc_group = try encoding.jsonEscapeAlloc(allocator, group);
        defer allocator.free(esc_group);
        try buf.writer(allocator).print("\"{s}\"", .{esc_group});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.writer(allocator).print(",\"hash\":\"{s}\",\"priority\":\"{s}\"}}", .{ item.hash, @tagName(item.priority) });
}

fn appendActivatedMemory(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    item: workspace_memory.ActivatedMemory,
) !void {
    const esc_id = try encoding.jsonEscapeAlloc(allocator, item.id);
    defer allocator.free(esc_id);
    const esc_path = try encoding.jsonEscapeAlloc(allocator, item.path);
    defer allocator.free(esc_path);
    const esc_name = try encoding.jsonEscapeAlloc(allocator, item.name);
    defer allocator.free(esc_name);

    try buf.writer(allocator).print(
        "{{\"id\":\"{s}\",\"kind\":\"{s}\",\"path\":\"{s}\",\"name\":\"{s}\",\"group\":",
        .{ esc_id, @tagName(item.kind), esc_path, esc_name },
    );
    if (item.group) |group| {
        const esc_group = try encoding.jsonEscapeAlloc(allocator, group);
        defer allocator.free(esc_group);
        try buf.writer(allocator).print("\"{s}\"", .{esc_group});
    } else {
        try buf.appendSlice(allocator, "null");
    }

    try buf.writer(allocator).print(
        ",\"hash\":\"{s}\",\"priority\":\"{s}\",\"changed\":{s},\"content\":",
        .{ item.hash, @tagName(item.priority), if (item.changed) "true" else "false" },
    );
    if (item.content) |content| {
        const esc_content = try encoding.jsonEscapeAlloc(allocator, content);
        defer allocator.free(esc_content);
        try buf.writer(allocator).print("\"{s}\"", .{esc_content});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}");
}

test "buildToolsListResult: exposes memory tools" {
    const result = try buildToolsListResult(testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"memory.startup\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.activate\"") != null);
}

test "handleToolCall: memory.list returns prompt metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule/coding");
    const file = try tmp.dir.createFile(".prompts/rule/coding/03_PR_WORKFLOW.md", .{});
    defer file.close();
    try file.writeAll("workflow");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmp.dir.realpath(".", &buf) catch return error.RealPathFailed;

    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"memory.list\",\"arguments\":{\"kind\":\"prompt\",\"query\":\"workflow\"}}", .{});
    defer params.deinit();

    const result = try handleToolCall(testing.allocator, root, params.value);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"structuredContent\":{\"items\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"prompt:rule/coding/03_PR_WORKFLOW.md\"") != null);
}
