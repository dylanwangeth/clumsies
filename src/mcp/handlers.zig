const std = @import("std");
const testing = std.testing;
const lib = @import("clumsies_lib");
const protocol = @import("protocol.zig");

const encoding = lib.encoding;
const trace = lib.trace;
const workspace_prompt = lib.workspace_prompt;

pub fn buildInitializeResult(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const esc_version = try encoding.jsonEscapeAlloc(allocator, version);
    defer allocator.free(esc_version);

    const instructions =
        "Call memory.setup to bootstrap the protocol and get usage instructions, " ++
        "memory.search to discover rules/workflows, memory.load to get content, " ++
        "and memory.refer to declare constraint usage.";
    const esc_instructions = try encoding.jsonEscapeAlloc(allocator, instructions);
    defer allocator.free(esc_instructions);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"clumsies\",\"version\":\"{s}\"}},\"instructions\":\"{s}\"}}",
        .{ protocol.PROTOCOL_VERSION, esc_version, esc_instructions },
    );
}

pub fn buildToolsListResult(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(u8, "{\"tools\":[" ++
        tool_setup ++ "," ++
        tool_search ++ "," ++
        tool_load ++ "," ++
        tool_refer ++
        "]}");
}

const tool_setup =
    "{\"name\":\"memory.setup\",\"title\":\"Setup\",\"description\":\"Bootstrap the protocol. Returns workspace_id and meta-prompt content with usage instructions (delta based on knownHash).\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"knownHash\":{\"type\":\"string\"}},\"additionalProperties\":false}}";

const tool_search =
    "{\"name\":\"memory.search\",\"title\":\"Search\",\"description\":\"Discover available rules, workflows, and context. Returns fresh metadata from the workspace.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\",\"enum\":[\"rule\",\"workflow\",\"context\"]},\"group\":{\"type\":\"string\"}},\"additionalProperties\":false}}";

const tool_load =
    "{\"name\":\"memory.load\",\"title\":\"Load\",\"description\":\"Load prompt content by ids. Returns delta based on knownHashes. Rule/Workflow content includes a refer reminder.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"knownHashes\":{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"}}},\"required\":[\"ids\"],\"additionalProperties\":false}}";

const tool_refer =
    "{\"name\":\"memory.refer\",\"title\":\"Refer\",\"description\":\"Declare constraint references from loaded prompts. Pass an array of refs, each with promptId and optional constraintId.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"refs\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"promptId\":{\"type\":\"string\"},\"promptHash\":{\"type\":\"string\"},\"constraintId\":{\"type\":\"string\"},\"reason\":{\"type\":\"string\"}},\"required\":[\"promptId\"]}}},\"required\":[\"refs\"],\"additionalProperties\":false}}";

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

    if (std.mem.eql(u8, name, "memory.setup")) {
        return try handleSetup(allocator, workspace_root, args_obj);
    }
    if (std.mem.eql(u8, name, "memory.search")) {
        return try handleSearch(allocator, workspace_root, args_obj);
    }
    if (std.mem.eql(u8, name, "memory.load")) {
        return handleLoad(allocator, workspace_root, args_obj) catch |err| switch (err) {
            error.UnknownPromptId => try buildToolErrorResult(allocator, "Unknown prompt id"),
            else => return err,
        };
    }

    if (std.mem.eql(u8, name, "memory.refer")) {
        return try handleRefer(allocator, workspace_root, args_obj);
    }

    return try buildToolErrorResult(allocator, "Unknown tool");
}

fn handleSetup(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    const known_hash: ?[]const u8 = if (args_obj.get("knownHash")) |value| switch (value) {
        .string => |s| s,
        else => null,
    } else null;

    var mpf = try workspace_prompt.loadMpf(allocator, workspace_root, known_hash);
    defer mpf.deinit(allocator);

    const ws_id = try trace.workspaceId(allocator, workspace_root);
    defer allocator.free(ws_id);

    try trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .setup,
        .mpf_hash = mpf.hash,
    });

    const esc_ws = try encoding.jsonEscapeAlloc(allocator, ws_id);
    defer allocator.free(esc_ws);

    if (mpf.content) |content| {
        const esc_content = try encoding.jsonEscapeAlloc(allocator, content);
        defer allocator.free(esc_content);
        const esc_hash = try encoding.jsonEscapeAlloc(allocator, mpf.hash.?);
        defer allocator.free(esc_hash);
        const structured = try std.fmt.allocPrint(allocator, "{{\"workspaceId\":\"{s}\",\"mpf\":{{\"hash\":\"{s}\",\"content\":\"{s}\"}}}}", .{ esc_ws, esc_hash, esc_content });
        defer allocator.free(structured);
        return try buildToolSuccessResult(allocator, structured);
    } else if (mpf.hash) |hash| {
        const esc_hash = try encoding.jsonEscapeAlloc(allocator, hash);
        defer allocator.free(esc_hash);
        const structured = try std.fmt.allocPrint(allocator, "{{\"workspaceId\":\"{s}\",\"mpf\":{{\"hash\":\"{s}\",\"changed\":false}}}}", .{ esc_ws, esc_hash });
        defer allocator.free(structured);
        return try buildToolSuccessResult(allocator, structured);
    } else {
        const structured = try std.fmt.allocPrint(allocator, "{{\"workspaceId\":\"{s}\",\"mpf\":null}}", .{esc_ws});
        defer allocator.free(structured);
        return try buildToolSuccessResult(allocator, structured);
    }
}

fn handleSearch(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    const kind = if (args_obj.get("kind")) |value|
        try parsePromptKind(value)
    else
        null;
    const group = if (args_obj.get("group")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else null;

    var items = try workspace_prompt.discoverSearchable(allocator, workspace_root, kind, group);
    defer workspace_prompt.deinitPromptItems(allocator, &items);

    // Trace: search event
    const ws_id = try trace.workspaceId(allocator, workspace_root);
    defer allocator.free(ws_id);
    try trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .search,
    });

    const structured = try serializePromptList(allocator, items.items);
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
}

fn handleLoad(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    var ids = try parseRequiredIds(allocator, args_obj.get("ids"));
    defer ids.deinit(allocator);

    var known = try parseKnownHashes(allocator, args_obj.get("knownHashes"));
    defer known.deinit(allocator);

    var result = try workspace_prompt.loadPrompts(allocator, workspace_root, ids.items, known.items);
    defer result.deinit(allocator);

    for (result.items.items) |item| {
        try trace.appendTraceEvent(allocator, workspace_root, .{
            .event_type = .load,
            .prompt_id = item.id,
            .prompt_hash = item.hash,
        });
    }

    const structured = try serializeLoadResultWithConstraints(allocator, &result, workspace_root);
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
}

fn handleRefer(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    const refs_val = args_obj.get("refs") orelse return error.InvalidParams;
    const refs_array = switch (refs_val) {
        .array => |a| a,
        else => return error.InvalidParams,
    };

    if (refs_array.items.len == 0) return error.InvalidParams;

    var count: usize = 0;
    for (refs_array.items) |ref_val| {
        const ref_obj = switch (ref_val) {
            .object => |o| o,
            else => continue,
        };

        const prompt_id = if (ref_obj.get("promptId")) |v| switch (v) {
            .string => |s| s,
            else => continue,
        } else continue;

        const prompt_hash = if (ref_obj.get("promptHash")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;

        const constraint_id = if (ref_obj.get("constraintId")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;

        const reason = if (ref_obj.get("reason")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;

        try trace.appendTraceEvent(allocator, workspace_root, .{
            .event_type = .refer,
            .prompt_id = prompt_id,
            .prompt_hash = prompt_hash,
            .constraint_id = constraint_id,
            .reason = reason,
        });
        count += 1;
    }

    var buf: [64]u8 = undefined;
    const structured = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"count\":{d}}}", .{count}) catch return error.InternalError;
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

fn serializePromptList(allocator: std.mem.Allocator, items: []const workspace_prompt.PromptItem) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"items\":[");
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try appendPromptMetadata(allocator, &buf, item);
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

fn serializeLoadResultWithConstraints(allocator: std.mem.Allocator, result: *workspace_prompt.LoadResult, workspace_root: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const ws_id = try trace.workspaceId(allocator, workspace_root);
    defer allocator.free(ws_id);

    const esc_ws = try encoding.jsonEscapeAlloc(allocator, ws_id);
    defer allocator.free(esc_ws);

    try buf.writer(allocator).print("{{\"workspaceId\":\"{s}\",\"items\":[", .{esc_ws});
    for (result.items.items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');

        // For Rule/Workflow with content, parse constraints first so we can
        // include them in both the refer reminder and the JSON output
        if ((item.kind == .rule or item.kind == .workflow) and item.content != null) {
            var parsed = try workspace_prompt.parseConstraints(allocator, item.content.?);
            defer parsed.deinit(allocator);

            try appendLoadedPromptWithConstraints(allocator, &buf, item, parsed.constraints.items);

            // Reopen the item JSON to append constraints array
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '}') {
                buf.items.len -= 1;
            }

            try buf.appendSlice(allocator, ",\"constraints\":[");
            for (parsed.constraints.items, 0..) |c, cidx| {
                if (cidx > 0) try buf.append(allocator, ',');
                const esc_cid = try encoding.jsonEscapeAlloc(allocator, c.id);
                defer allocator.free(esc_cid);
                const esc_th = try encoding.jsonEscapeAlloc(allocator, c.text_hash);
                defer allocator.free(esc_th);
                try buf.writer(allocator).print("{{\"id\":\"{s}\",\"textHash\":\"{s}\"}}", .{ esc_cid, esc_th });
            }
            try buf.appendSlice(allocator, "]}");
        } else {
            try appendLoadedPrompt(allocator, &buf, item);
        }
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

fn appendPromptMetadata(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    item: workspace_prompt.PromptItem,
) !void {
    const esc_id = try encoding.jsonEscapeAlloc(allocator, item.id);
    defer allocator.free(esc_id);
    const esc_path = try encoding.jsonEscapeAlloc(allocator, item.path);
    defer allocator.free(esc_path);
    const esc_name = try encoding.jsonEscapeAlloc(allocator, item.name);
    defer allocator.free(esc_name);

    try buf.writer(allocator).print(
        "{{\"id\":\"{s}\",\"kind\":\"{s}\",\"path\":\"{s}\",\"name\":\"{s}\",\"group\":",
        .{ esc_id, workspace_prompt.kindToString(item.kind), esc_path, esc_name },
    );
    if (item.group) |group| {
        const esc_group = try encoding.jsonEscapeAlloc(allocator, group);
        defer allocator.free(esc_group);
        try buf.writer(allocator).print("\"{s}\"", .{esc_group});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.writer(allocator).print(",\"hash\":\"{s}\"}}", .{item.hash});
}

fn appendLoadedPrompt(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    item: workspace_prompt.LoadedPrompt,
) !void {
    return appendLoadedPromptWithConstraints(allocator, buf, item, &.{});
}

fn appendLoadedPromptWithConstraints(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    item: workspace_prompt.LoadedPrompt,
    constraints: []const workspace_prompt.ParsedConstraint,
) !void {
    const esc_id = try encoding.jsonEscapeAlloc(allocator, item.id);
    defer allocator.free(esc_id);

    try buf.writer(allocator).print(
        "{{\"id\":\"{s}\",\"kind\":\"{s}\",\"changed\":{s},\"hash\":\"{s}\",\"content\":",
        .{ esc_id, workspace_prompt.kindToString(item.kind), if (item.changed) "true" else "false", item.hash },
    );
    if (item.content) |content| {
        const needs_reminder = item.kind == .rule or item.kind == .workflow;
        if (needs_reminder) {
            // Build constraint list for the reminder
            var constraint_list_buf: std.ArrayList(u8) = .empty;
            defer constraint_list_buf.deinit(allocator);
            for (constraints) |c| {
                try constraint_list_buf.writer(allocator).print("  - {s}\n", .{c.id});
            }
            const constraint_list = if (constraint_list_buf.items.len > 0)
                constraint_list_buf.items
            else
                @as([]const u8, "  (no constraints parsed)\n");

            const reminder = try std.fmt.allocPrint(
                allocator,
                "{s}\n\n---\n[clumsies] When you apply constraints from this prompt, include them in a single memory.refer call at the end of your response.\nrefs entry fields: promptId: {s}, promptHash: {s}, constraintId: pick from below\n{s}---",
                .{ content, item.id, item.hash, constraint_list },
            );
            defer allocator.free(reminder);
            const esc_content = try encoding.jsonEscapeAlloc(allocator, reminder);
            defer allocator.free(esc_content);
            try buf.writer(allocator).print("\"{s}\"", .{esc_content});
        } else {
            const esc_content = try encoding.jsonEscapeAlloc(allocator, content);
            defer allocator.free(esc_content);
            try buf.writer(allocator).print("\"{s}\"", .{esc_content});
        }
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}");
}

fn parsePromptKind(value: std.json.Value) !?workspace_prompt.PromptKind {
    const str = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };

    if (std.mem.eql(u8, str, "rule")) return .rule;
    if (std.mem.eql(u8, str, "workflow")) return .workflow;
    if (std.mem.eql(u8, str, "context")) return .context;
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

fn parseKnownHashes(allocator: std.mem.Allocator, value_opt: ?std.json.Value) !std.ArrayList(workspace_prompt.KnownHash) {
    var known: std.ArrayList(workspace_prompt.KnownHash) = .empty;
    errdefer known.deinit(allocator);

    const value = value_opt orelse return known;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidParams,
    };

    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const hash = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        try known.append(allocator, .{ .id = entry.key_ptr.*, .hash = hash });
    }

    return known;
}

test "buildToolsListResult: exposes all memory tools" {
    const result = try buildToolsListResult(testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"memory.setup\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.search\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.load\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.refer\"") != null);

    // Removed tools should NOT be present
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.begin\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.complete\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.startup\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.list\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.activate\"") == null);
}

test "handleToolCall: memory.setup returns mpf content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts");
    const file = try tmp.dir.createFile(".prompts/META_PROMPT.md", .{});
    defer file.close();
    var tw_buf1: [4096]u8 = undefined;
    var tw1 = std.fs.File.Writer.init(file, &tw_buf1);
    defer tw1.interface.flush() catch {};
    try tw1.interface.writeAll("bootstrap content");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmp.dir.realpath(".", &buf) catch return error.RealPathFailed;

    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"memory.setup\",\"arguments\":{}}", .{});
    defer params.deinit();

    const result = try handleToolCall(testing.allocator, root, params.value);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"workspaceId\":\"ws-") != null);
    try testing.expect(std.mem.indexOf(u8, result, "bootstrap content") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"hash\":\"") != null);
}

test "handleToolCall: memory.setup returns null when no mpf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmp.dir.realpath(".", &buf) catch return error.RealPathFailed;

    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"memory.setup\",\"arguments\":{}}", .{});
    defer params.deinit();

    const result = try handleToolCall(testing.allocator, root, params.value);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"workspaceId\":\"ws-") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"mpf\":null") != null);
}

test "handleToolCall: memory.search returns rule metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule/coding");
    const file = try tmp.dir.createFile(".prompts/rule/coding/00_COMPAT.md", .{});
    defer file.close();
    var tw_buf2: [4096]u8 = undefined;
    var tw2 = std.fs.File.Writer.init(file, &tw_buf2);
    defer tw2.interface.flush() catch {};
    try tw2.interface.writeAll("compat rule");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmp.dir.realpath(".", &buf) catch return error.RealPathFailed;

    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"memory.search\",\"arguments\":{\"kind\":\"rule\"}}", .{});
    defer params.deinit();

    const result = try handleToolCall(testing.allocator, root, params.value);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"rule:coding/00_COMPAT.md\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"group\":\"coding\"") != null);
}

test "handleToolCall: memory.load returns content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule");
    const file = try tmp.dir.createFile(".prompts/rule/00_STYLE.md", .{});
    defer file.close();
    var tw_buf3: [4096]u8 = undefined;
    var tw3 = std.fs.File.Writer.init(file, &tw_buf3);
    defer tw3.interface.flush() catch {};
    try tw3.interface.writeAll("style content");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmp.dir.realpath(".", &buf) catch return error.RealPathFailed;

    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"memory.load\",\"arguments\":{\"ids\":[\"rule:00_STYLE.md\"]}}", .{});
    defer params.deinit();

    const result = try handleToolCall(testing.allocator, root, params.value);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "style content") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"changed\":true") != null);
}
