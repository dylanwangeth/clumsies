const std = @import("std");
const testing = std.testing;
const lib = @import("clumsies_lib");
const protocol = @import("protocol.zig");

const encoding = lib.encoding;
const trace = lib.trace;
const workspace_prompt = lib.workspace_prompt;

// --- Initialize ---

pub fn buildInitializeResult(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const esc_version = try encoding.jsonEscapeAlloc(allocator, version);
    defer allocator.free(esc_version);

    const instructions =
        "Call memory.setup to load directives, memory.search to discover rules/workflows, " ++
        "memory.load to get content, memory.refer to declare constraint usage, " ++
        "and memory.complete to finalize a task.";
    const esc_instructions = try encoding.jsonEscapeAlloc(allocator, instructions);
    defer allocator.free(esc_instructions);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"clumsies\",\"version\":\"{s}\"}},\"instructions\":\"{s}\"}}",
        .{ protocol.PROTOCOL_VERSION, esc_version, esc_instructions },
    );
}

// --- Tool list (v2: 9 tools) ---

pub fn buildToolsListResult(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(u8, "{\"tools\":[" ++
        tool_setup ++ "," ++
        tool_begin ++ "," ++
        tool_search ++ "," ++
        tool_load ++ "," ++
        tool_refer ++ "," ++
        tool_shortcut ++ "," ++
        tool_complete ++ "," ++
        tool_stats ++ "," ++
        tool_validate ++
        "]}");
}

const tool_setup =
    "{\"name\":\"memory.setup\",\"title\":\"Setup\",\"description\":\"Sync directives from the .prompts/directive/ directory. Returns workspace_id and directive content (delta based on knownHashes).\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"knownHashes\":{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"}}},\"additionalProperties\":false}}";

const tool_begin =
    "{\"name\":\"memory.begin\",\"title\":\"Begin Task\",\"description\":\"Start a new task. Returns a task_id.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"goalSummary\":{\"type\":\"string\"}},\"required\":[\"goalSummary\"],\"additionalProperties\":false}}";

const tool_search =
    "{\"name\":\"memory.search\",\"title\":\"Search\",\"description\":\"Discover available rules, workflows, and data. Returns fresh metadata from the workspace.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\",\"enum\":[\"rule\",\"workflow\",\"data\"]},\"group\":{\"type\":\"string\"}},\"additionalProperties\":false}}";

const tool_load =
    "{\"name\":\"memory.load\",\"title\":\"Load\",\"description\":\"Load prompt content by ids. Returns delta based on knownHashes. Rule/Workflow content includes a refer reminder.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"taskId\":{\"type\":\"string\"},\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"knownHashes\":{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"}}},\"required\":[\"taskId\",\"ids\"],\"additionalProperties\":false}}";

const tool_refer =
    "{\"name\":\"memory.refer\",\"title\":\"Refer\",\"description\":\"Declare that you referenced a specific constraint from a loaded prompt.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"taskId\":{\"type\":\"string\"},\"promptId\":{\"type\":\"string\"},\"promptHash\":{\"type\":\"string\"},\"constraintId\":{\"type\":\"string\"},\"ranges\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}},\"reason\":{\"type\":\"string\"}},\"required\":[\"taskId\",\"promptId\"],\"additionalProperties\":false}}";

const tool_shortcut =
    "{\"name\":\"memory.shortcut\",\"title\":\"Shortcut\",\"description\":\"Invoke a workflow by name. Searches workflow/ directory and loads matching file.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"taskId\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"}},\"required\":[\"taskId\",\"name\"],\"additionalProperties\":false}}";

const tool_complete =
    "{\"name\":\"memory.complete\",\"title\":\"Complete Task\",\"description\":\"Declare a task as completed or abandoned. No further events accepted for this task.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"taskId\":{\"type\":\"string\"},\"status\":{\"type\":\"string\",\"enum\":[\"completed\",\"abandoned\"]}},\"required\":[\"taskId\",\"status\"],\"additionalProperties\":false}}";

const tool_stats =
    "{\"name\":\"memory.stats\",\"title\":\"Stats\",\"description\":\"Query aggregated trace data. Returns structured data and a pre-rendered text view.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"scope\":{\"type\":\"string\",\"enum\":[\"workspace\",\"prompt\",\"diff\"]},\"promptId\":{\"type\":\"string\"},\"taskId\":{\"type\":\"string\"},\"oldHash\":{\"type\":\"string\"},\"newHash\":{\"type\":\"string\"},\"timeBuckets\":{\"type\":\"string\",\"enum\":[\"daily\",\"weekly\"]}},\"required\":[\"scope\"],\"additionalProperties\":false}}";

const tool_validate =
    "{\"name\":\"memory.validate\",\"title\":\"Validate\",\"description\":\"Validate a prompt file against the standard format. Returns parsed constraints and issues.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"promptId\":{\"type\":\"string\"}},\"required\":[\"promptId\"],\"additionalProperties\":false}}";

// --- Tool dispatch ---

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

    if (std.mem.eql(u8, name, "memory.begin")) {
        return try handleBegin(allocator, workspace_root, args_obj);
    }
    if (std.mem.eql(u8, name, "memory.refer")) {
        return try handleRefer(allocator, workspace_root, args_obj);
    }
    if (std.mem.eql(u8, name, "memory.complete")) {
        return try handleComplete(allocator, workspace_root, args_obj);
    }

    if (std.mem.eql(u8, name, "memory.shortcut")) {
        return handleShortcut(allocator, workspace_root, args_obj) catch |err| switch (err) {
            error.UnknownPromptId => try buildToolErrorResult(allocator, "No matching workflow found"),
            else => return err,
        };
    }

    // Stubs for remaining tools
    if (std.mem.eql(u8, name, "memory.stats")) {
        return try buildToolErrorResult(allocator, "memory.stats: not yet implemented");
    }
    if (std.mem.eql(u8, name, "memory.validate")) {
        return try handleValidate(allocator, workspace_root, args_obj);
    }

    return try buildToolErrorResult(allocator, "Unknown tool");
}

// --- Handlers ---

fn handleSetup(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    var known = try parseKnownHashes(allocator, args_obj.get("knownHashes"));
    defer known.deinit(allocator);

    var result = try workspace_prompt.loadDirectives(allocator, workspace_root, known.items);
    defer result.deinit(allocator);

    // Trace: setup event
    const ws_id = try trace.workspaceId(allocator, workspace_root);
    defer allocator.free(ws_id);
    try trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .setup,
        .workspace_id = ws_id,
        .synced_count = result.items.items.len,
    });

    const structured = try serializeLoadResult(allocator, &result, workspace_root);
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
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

    const structured = try serializeLoadResult(allocator, &result, workspace_root);
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
}

fn handleBegin(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    const goal_summary = if (args_obj.get("goalSummary")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else return error.InvalidParams;

    const ws_id = try trace.workspaceId(allocator, workspace_root);
    defer allocator.free(ws_id);
    const task_id = try trace.generateTaskId(allocator);
    defer allocator.free(task_id);

    try trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .begin,
        .workspace_id = ws_id,
        .task_id = task_id,
        .goal_summary = goal_summary,
    });

    const esc_tid = try encoding.jsonEscapeAlloc(allocator, task_id);
    defer allocator.free(esc_tid);
    const structured = try std.fmt.allocPrint(allocator, "{{\"taskId\":\"{s}\"}}", .{esc_tid});
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
}

fn handleRefer(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    const task_id = if (args_obj.get("taskId")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else return error.InvalidParams;

    const prompt_id = if (args_obj.get("promptId")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else return error.InvalidParams;

    const prompt_hash = if (args_obj.get("promptHash")) |value| switch (value) {
        .string => |s| s,
        else => null,
    } else null;

    const constraint_id = if (args_obj.get("constraintId")) |value| switch (value) {
        .string => |s| s,
        else => null,
    } else null;

    const reason = if (args_obj.get("reason")) |value| switch (value) {
        .string => |s| s,
        else => null,
    } else null;

    const ws_id = try trace.workspaceId(allocator, workspace_root);
    defer allocator.free(ws_id);

    try trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .refer,
        .workspace_id = ws_id,
        .task_id = task_id,
        .prompt_id = prompt_id,
        .prompt_hash = prompt_hash,
        .constraint_id = constraint_id,
        .reason = reason,
    });

    return try buildToolSuccessResult(allocator, "{\"ok\":true}");
}

fn handleComplete(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    const task_id = if (args_obj.get("taskId")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else return error.InvalidParams;

    const status = if (args_obj.get("status")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else return error.InvalidParams;

    const ws_id = try trace.workspaceId(allocator, workspace_root);
    defer allocator.free(ws_id);

    try trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .complete,
        .workspace_id = ws_id,
        .task_id = task_id,
        .status = status,
    });

    const esc_status = try encoding.jsonEscapeAlloc(allocator, status);
    defer allocator.free(esc_status);
    const structured = try std.fmt.allocPrint(allocator, "{{\"taskId\":\"{s}\",\"status\":\"{s}\"}}", .{ task_id, esc_status });
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
}

fn handleValidate(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    const prompt_id = if (args_obj.get("promptId")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else return error.InvalidParams;

    var result = try workspace_prompt.validatePrompt(allocator, workspace_root, prompt_id);
    defer result.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.writer(allocator).print("{{\"valid\":{s},\"constraints\":[", .{if (result.valid) "true" else "false"});
    for (result.constraints.items, 0..) |c, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const esc_id = try encoding.jsonEscapeAlloc(allocator, c.id);
        defer allocator.free(esc_id);
        try buf.writer(allocator).print("{{\"id\":\"{s}\",\"lineStart\":{d},\"lineEnd\":{d}}}", .{ esc_id, c.line_start, c.line_end });
    }
    try buf.appendSlice(allocator, "],\"issues\":[");
    for (result.issues.items, 0..) |issue, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const esc = try encoding.jsonEscapeAlloc(allocator, issue);
        defer allocator.free(esc);
        try buf.writer(allocator).print("\"{s}\"", .{esc});
    }
    try buf.appendSlice(allocator, "]}");

    const structured = try buf.toOwnedSlice(allocator);
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
}

fn handleShortcut(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    args_obj: std.json.ObjectMap,
) ![]u8 {
    const task_id = if (args_obj.get("taskId")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else return error.InvalidParams;

    const name = if (args_obj.get("name")) |value| switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    } else return error.InvalidParams;

    // Search workflow/ for a file matching the name (case-insensitive)
    var workflows = try workspace_prompt.discoverSearchable(allocator, workspace_root, .workflow, null);
    defer workspace_prompt.deinitPromptItems(allocator, &workflows);

    var match_id: ?[]const u8 = null;
    for (workflows.items) |item| {
        if (containsIgnoreCase(item.name, name) or containsIgnoreCase(item.id, name)) {
            match_id = item.id;
            break;
        }
    }

    const workflow_id = match_id orelse return error.UnknownPromptId;

    // Load the matched workflow
    var result = try workspace_prompt.loadPrompts(allocator, workspace_root, &.{workflow_id}, &.{});
    defer result.deinit(allocator);

    // Trace: shortcut event
    const ws_id = try trace.workspaceId(allocator, workspace_root);
    defer allocator.free(ws_id);
    try trace.appendTraceEvent(allocator, workspace_root, .{
        .event_type = .shortcut,
        .workspace_id = ws_id,
        .task_id = task_id,
        .workflow_name = name,
    });

    const structured = try serializeLoadResult(allocator, &result, workspace_root);
    defer allocator.free(structured);
    return try buildToolSuccessResult(allocator, structured);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const last_start = haystack.len - needle.len;
    var start: usize = 0;
    while (start <= last_start) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

// --- Serialization ---

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

fn serializeLoadResult(allocator: std.mem.Allocator, result: *workspace_prompt.LoadResult, workspace_root: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // workspace_id from workspace_root hash
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(workspace_root);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    var hex: [64]u8 = undefined;
    lib.encoding.hexEncode(&hash, &hex);

    try buf.writer(allocator).print("{{\"workspaceId\":\"ws-{s}\",\"items\":[", .{hex[0..16]});
    for (result.items.items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try appendLoadedPrompt(allocator, &buf, item);
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
    const esc_id = try encoding.jsonEscapeAlloc(allocator, item.id);
    defer allocator.free(esc_id);

    try buf.writer(allocator).print(
        "{{\"id\":\"{s}\",\"kind\":\"{s}\",\"changed\":{s},\"hash\":\"{s}\",\"content\":",
        .{ esc_id, workspace_prompt.kindToString(item.kind), if (item.changed) "true" else "false", item.hash },
    );
    if (item.content) |content| {
        // Refer reminder injection for Rule and Workflow
        const needs_reminder = item.kind == .rule or item.kind == .workflow;
        if (needs_reminder) {
            const reminder = try std.fmt.allocPrint(
                allocator,
                "{s}\n\n---\n[clumsies] When you reference constraints from this prompt, call memory.refer:\n  promptId: {s}\n  promptHash: {s}\n  constraintId or ranges: the constraint you used\n---",
                .{ content, item.id, item.hash },
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

// --- Parsing helpers ---

fn parsePromptKind(value: std.json.Value) !?workspace_prompt.PromptKind {
    const str = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };

    if (std.mem.eql(u8, str, "rule")) return .rule;
    if (std.mem.eql(u8, str, "workflow")) return .workflow;
    if (std.mem.eql(u8, str, "data")) return .data;
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

// --- Tests ---

test "buildToolsListResult: exposes v2 tools" {
    const result = try buildToolsListResult(testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"memory.setup\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.begin\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.search\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.load\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.refer\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.shortcut\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.complete\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.stats\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.validate\"") != null);

    // Old tools should NOT be present
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.startup\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.list\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"memory.activate\"") == null);
}

test "handleToolCall: memory.setup returns directives" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/directive");
    const file = try tmp.dir.createFile(".prompts/directive/PIN.md", .{});
    defer file.close();
    try file.writeAll("pin content");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmp.dir.realpath(".", &buf) catch return error.RealPathFailed;

    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"memory.setup\",\"arguments\":{}}", .{});
    defer params.deinit();

    const result = try handleToolCall(testing.allocator, root, params.value);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"workspaceId\":\"ws-") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"directive:PIN.md\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "pin content") != null);
}

test "handleToolCall: memory.search returns rule metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".prompts/rule/coding");
    const file = try tmp.dir.createFile(".prompts/rule/coding/00_COMPAT.md", .{});
    defer file.close();
    try file.writeAll("compat rule");

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
    try file.writeAll("style content");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmp.dir.realpath(".", &buf) catch return error.RealPathFailed;

    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"memory.load\",\"arguments\":{\"taskId\":\"t-1\",\"ids\":[\"rule:00_STYLE.md\"]}}", .{});
    defer params.deinit();

    const result = try handleToolCall(testing.allocator, root, params.value);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "style content") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"changed\":true") != null);
}
