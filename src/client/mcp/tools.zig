//! Agent-facing MCP memory tools. The Rust daemon owns Effective Memory,
//! retrieval, loading, and Draft persistence; this module validates MCP input
//! and adapts it to daemon XPC JSON.
const std = @import("std");
const testing = std.testing;
const daemon_ipc = @import("../daemon/ipc.zig");
const session_mod = @import("session.zig");
const tool_names = @import("tool_names.zig");
const tool_result = @import("tool_result.zig");

const activate_schema =
    "{\"name\":\"" ++ tool_names.activate ++ "\",\"title\":\"Activate\",\"description\":\"Activate the memory fragments most useful for the current task. Call once at the start of each substantive task. The daemon performs BM25 and vector recall, RRF fusion, reranking, budget control, and fragment delta calculation. Pass state only while fragments from the preceding activation remain in the model context.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++
    "\"query\":{\"type\":\"string\",\"minLength\":1,\"description\":\"Natural-language representation of the current task or retrieval cue.\"}," ++
    "\"state\":{\"type\":\"string\",\"description\":\"Opaque next_state from a preceding activation whose fragments are still present in the current model context.\"}" ++
    "},\"required\":[\"query\"],\"additionalProperties\":false}}";

const load_schema =
    "{\"name\":\"" ++ tool_names.load ++ "\",\"title\":\"Load\",\"description\":\"Load complete current memory resources by stable id or exact path. Use for deep reading or before editing a known resource; activate already returns directly usable fragments and does not require a follow-up load.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++
    "\"ids\":{\"type\":\"array\",\"minItems\":1,\"uniqueItems\":true,\"items\":{\"type\":\"string\",\"minLength\":1},\"description\":\"Stable resource ids or exact paths.\"}," ++
    "\"knownHashes\":{\"type\":\"object\",\"description\":\"Optional known content hashes keyed by requested id or path. Unchanged resources omit content.\",\"additionalProperties\":{\"type\":\"string\"}}" ++
    "},\"required\":[\"ids\"],\"additionalProperties\":false}}";

const store_schema =
    "{\"name\":\"" ++ tool_names.store ++ "\",\"title\":\"Store\",\"description\":\"Create, update, rename, delete, or discard a local Context, Rule, or Workflow Draft only when the user explicitly requests memory maintenance. Before update, load the complete resource and use its content_hash with exact text replacements; update never accepts a complete document body. A successful call means durable local persistence and queued synchronization, not authoritative publication. Pass exactly one tagged operation.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++
    "\"resource\":{\"type\":\"string\",\"enum\":[\"context\",\"rule\",\"workflow\"],\"description\":\"Memory resource type.\"}," ++
    "\"op\":{\"type\":\"object\",\"minProperties\":1,\"maxProperties\":1,\"properties\":{" ++
    "\"create\":{\"$ref\":\"#/$defs/writeCreate\"}," ++
    "\"update\":{\"$ref\":\"#/$defs/writeUpdate\"}," ++
    "\"rename\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"minLength\":1},\"new_path\":{\"type\":\"string\",\"minLength\":1},\"description\":{\"type\":\"string\"}},\"required\":[\"id\",\"new_path\"],\"additionalProperties\":false}," ++
    "\"delete\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"minLength\":1},\"description\":{\"type\":\"string\"}},\"required\":[\"id\"],\"additionalProperties\":false}," ++
    "\"discard\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"minLength\":1}},\"required\":[\"id\"],\"additionalProperties\":false}" ++
    "},\"additionalProperties\":false}" ++
    "},\"required\":[\"resource\",\"op\"],\"additionalProperties\":false," ++
    "\"$defs\":{" ++
    "\"writeCreate\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"minLength\":1},\"body\":{\"type\":\"string\",\"minLength\":1},\"description\":{\"type\":\"string\"}},\"required\":[\"path\",\"body\"],\"additionalProperties\":false}," ++
    "\"writeUpdate\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"minLength\":1,\"description\":\"Stable resource_id returned by load, not a path.\"},\"expected_hash\":{\"type\":\"string\",\"minLength\":1,\"description\":\"Complete-resource content_hash returned by load.\"},\"replacements\":{\"type\":\"array\",\"minItems\":1,\"description\":\"Atomic, non-overlapping exact text replacements matched against the loaded resource.\",\"items\":{\"$ref\":\"#/$defs/textReplacement\"}},\"description\":{\"type\":\"string\"}},\"required\":[\"id\",\"expected_hash\",\"replacements\"],\"additionalProperties\":false}," ++
    "\"textReplacement\":{\"type\":\"object\",\"properties\":{\"old_text\":{\"type\":\"string\",\"minLength\":1},\"new_text\":{\"type\":\"string\"}},\"required\":[\"old_text\",\"new_text\"],\"additionalProperties\":false}" ++
    "}}}";

pub fn buildListResult(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(
        u8,
        "{\"tools\":[" ++ activate_schema ++ "," ++ load_schema ++ "," ++ store_schema ++ "]}",
    );
}

pub fn handleCall(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    params: std.json.Value,
) ![]u8 {
    const params_obj = switch (params) {
        .object => |object| object,
        else => return try tool_result.buildErrorResult(allocator, "invalid request: params must be a JSON object"),
    };
    const name = requiredString(params_obj, "name") orelse
        return try tool_result.buildErrorResult(allocator, "invalid request: name is required and must be a string");
    const arguments = params_obj.get("arguments") orelse std.json.Value{ .object = .empty };
    const args = switch (arguments) {
        .object => |object| object,
        else => return try tool_result.buildErrorResult(allocator, "invalid request: arguments must be a JSON object"),
    };

    if (std.mem.eql(u8, name, tool_names.activate)) {
        return handleActivate(allocator, session, args) catch |err| daemonToolError(allocator, err, "activate memory");
    }
    if (std.mem.eql(u8, name, tool_names.load)) {
        return handleLoad(allocator, session, args) catch |err| daemonToolError(allocator, err, "load memory");
    }
    if (std.mem.eql(u8, name, tool_names.store)) {
        return handleStore(allocator, session, args) catch |err| daemonToolError(allocator, err, "store the Draft operation");
    }
    return try tool_result.buildErrorResult(allocator, "Unknown tool");
}

fn handleActivate(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    args: std.json.ObjectMap,
) ![]u8 {
    if (try rejectUnexpectedFields(allocator, args, &.{ "query", "state" }, "activate")) |result| {
        return result;
    }
    const query = requiredString(args, "query") orelse
        return try tool_result.buildErrorResult(allocator, "query is required and must be a non-empty string");
    if (std.mem.trim(u8, query, " \t\r\n").len == 0) {
        return try tool_result.buildErrorResult(allocator, "query must not be empty");
    }
    const state = if (args.get("state")) |value| switch (value) {
        .string => |string| string,
        else => return try tool_result.buildErrorResult(allocator, "state must be an opaque string"),
    } else null;
    var operation = try daemon_ipc.activateMemoryOperation(
        allocator,
        session.project_id,
        query,
        state,
    );
    defer operation.deinit(allocator);
    return try buildDaemonOperationResult(allocator, operation);
}

fn handleLoad(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    args: std.json.ObjectMap,
) ![]u8 {
    if (try rejectUnexpectedFields(allocator, args, &.{ "ids", "knownHashes" }, "load")) |result| {
        return result;
    }
    var ids = try parseIds(allocator, args.get("ids"));
    defer ids.deinit(allocator);
    const known_hashes = if (args.get("knownHashes")) |value| switch (value) {
        .object => |object| blk: {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .string) {
                    return try tool_result.buildErrorResult(allocator, "knownHashes values must be strings");
                }
            }
            break :blk value;
        },
        else => return try tool_result.buildErrorResult(allocator, "knownHashes must be an object map"),
    } else std.json.Value{ .object = .empty };
    var operation = try daemon_ipc.loadMemoryOperation(
        allocator,
        session.project_id,
        ids.items,
        known_hashes,
    );
    defer operation.deinit(allocator);
    return try buildDaemonOperationResult(allocator, operation);
}

fn parseIds(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) !std.ArrayList([]const u8) {
    const array = switch (value orelse return error.InvalidIds) {
        .array => |array| array,
        else => return error.InvalidIds,
    };
    if (array.items.len == 0) return error.InvalidIds;
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(allocator);
    for (array.items) |item| {
        const id = switch (item) {
            .string => |string| string,
            else => return error.InvalidIds,
        };
        if (id.len == 0) return error.InvalidIds;
        for (ids.items) |existing| {
            if (std.mem.eql(u8, existing, id)) return error.InvalidIds;
        }
        try ids.append(allocator, id);
    }
    return ids;
}

const StoreResource = enum { context, rule, workflow };
const DraftOp = enum { create, update, rename, delete, discard };

fn handleStore(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    args: std.json.ObjectMap,
) ![]u8 {
    if (try rejectUnexpectedFields(allocator, args, &.{ "resource", "op" }, "store")) |result| {
        return result;
    }
    const resource_name = requiredString(args, "resource") orelse
        return try tool_result.buildErrorResult(allocator, "resource is required");
    const resource = parseStoreResource(resource_name) orelse
        return try tool_result.buildErrorResult(allocator, "resource must be 'context', 'rule', or 'workflow'");
    const tagged = switch (args.get("op") orelse return try tool_result.buildErrorResult(allocator, "op is required")) {
        .object => |object| object,
        else => return try tool_result.buildErrorResult(allocator, "op must be a JSON object"),
    };
    const op = parseDraftOp(tagged) orelse
        return try tool_result.buildErrorResult(allocator, "op must contain exactly one tagged Draft operation");
    const op_args = switch (tagged.get(draftOpName(op)).?) {
        .object => |object| object,
        else => return try tool_result.buildErrorResult(allocator, "operation details must be a JSON object"),
    };
    if (try validateStoreOperation(allocator, resource, op, op_args)) |error_result| {
        return error_result;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const daemon_op = try daemonDraftOperationValue(
        arena.allocator(),
        resource,
        op,
        op_args,
        .{ .object = tagged },
    );
    var operation = try daemon_ipc.storeDraftOperation(
        allocator,
        session.project_id,
        daemonResourceName(resource),
        daemon_op,
    );
    defer operation.deinit(allocator);
    return try buildDaemonOperationResult(allocator, operation);
}

fn buildDaemonOperationResult(
    allocator: std.mem.Allocator,
    operation: daemon_ipc.OperationResult,
) ![]u8 {
    if (operation.error_message) |message| {
        return try tool_result.buildStructuredErrorResult(
            allocator,
            message,
            operation.structured_json,
        );
    }
    return try tool_result.buildSuccessResult(allocator, operation.structured_json);
}

fn daemonDraftOperationValue(
    allocator: std.mem.Allocator,
    resource: StoreResource,
    op: DraftOp,
    args: std.json.ObjectMap,
    original: std.json.Value,
) !std.json.Value {
    if (op != .create) return original;
    const body = requiredString(args, "body") orelse return error.InvalidParams;
    var content: std.json.ObjectMap = .empty;
    try content.put(allocator, "kind", .{ .string = daemonResourceName(resource) });
    try content.put(allocator, "content", .{ .string = body });

    var details: std.json.ObjectMap = .empty;
    try details.put(allocator, "path", .{ .string = requiredString(args, "path").? });
    try details.put(allocator, "content", .{ .object = content });
    if (args.get("description")) |description| {
        try details.put(allocator, "description", description);
    }
    var tagged: std.json.ObjectMap = .empty;
    try tagged.put(allocator, draftOpName(op), .{ .object = details });
    return .{ .object = tagged };
}

fn validateStoreOperation(
    allocator: std.mem.Allocator,
    resource: StoreResource,
    op: DraftOp,
    args: std.json.ObjectMap,
) !?[]u8 {
    const allowed: []const []const u8 = switch (op) {
        .create => &.{ "path", "body", "description" },
        .update => &.{ "id", "expected_hash", "replacements", "description" },
        .rename => &.{ "id", "new_path", "description" },
        .delete => &.{ "id", "description" },
        .discard => &.{"id"},
    };
    if (try rejectUnexpectedFields(allocator, args, allowed, draftOpName(op))) |result| {
        return result;
    }
    switch (op) {
        .create => {
            const path = requiredString(args, "path") orelse return try tool_result.buildErrorResult(allocator, "path is required and must not be empty");
            const body = requiredString(args, "body") orelse return try tool_result.buildErrorResult(allocator, "body is required and must not be empty");
            if (path.len == 0 or body.len == 0) return try tool_result.buildErrorResult(allocator, "path and body must not be empty");
            if (resource == .workflow and !std.mem.startsWith(u8, path, "workflow/")) {
                return try tool_result.buildErrorResult(allocator, "workflow paths must use the workflow/ namespace");
            }
        },
        .update => {
            const id = requiredString(args, "id") orelse return try tool_result.buildErrorResult(allocator, "id is required and must not be empty");
            const expected_hash = requiredString(args, "expected_hash") orelse return try tool_result.buildErrorResult(allocator, "expected_hash is required and must not be empty");
            if (id.len == 0 or expected_hash.len == 0) {
                return try tool_result.buildErrorResult(allocator, "id and expected_hash must not be empty");
            }
            if (try validateTextReplacements(allocator, args.get("replacements"))) |error_result| {
                return error_result;
            }
        },
        .rename => {
            const id = requiredString(args, "id") orelse return try tool_result.buildErrorResult(allocator, "id is required and must not be empty");
            const path = requiredString(args, "new_path") orelse return try tool_result.buildErrorResult(allocator, "new_path is required and must not be empty");
            if (id.len == 0 or path.len == 0) return try tool_result.buildErrorResult(allocator, "id and new_path must not be empty");
            if (resource == .workflow and !std.mem.startsWith(u8, path, "workflow/")) {
                return try tool_result.buildErrorResult(allocator, "workflow paths must use the workflow/ namespace");
            }
        },
        .delete, .discard => {
            const id = requiredString(args, "id") orelse return try tool_result.buildErrorResult(allocator, "id is required and must not be empty");
            if (id.len == 0) return try tool_result.buildErrorResult(allocator, "id must not be empty");
        },
    }
    return null;
}

fn validateTextReplacements(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) !?[]u8 {
    const replacements = switch (value orelse
        return try tool_result.buildErrorResult(allocator, "replacements is required")) {
        .array => |array| array,
        else => return try tool_result.buildErrorResult(allocator, "replacements must be an array"),
    };
    if (replacements.items.len == 0) {
        return try tool_result.buildErrorResult(allocator, "replacements must contain at least one text replacement");
    }
    for (replacements.items) |replacement| {
        const object = switch (replacement) {
            .object => |object| object,
            else => return try tool_result.buildErrorResult(allocator, "each replacement must be a JSON object"),
        };
        if (try rejectUnexpectedFields(
            allocator,
            object,
            &.{ "old_text", "new_text" },
            "replacement",
        )) |result| {
            return result;
        }
        const old_text = requiredString(object, "old_text") orelse
            return try tool_result.buildErrorResult(allocator, "replacement old_text is required and must be a string");
        _ = requiredString(object, "new_text") orelse
            return try tool_result.buildErrorResult(allocator, "replacement new_text is required and must be a string");
        if (old_text.len == 0) {
            return try tool_result.buildErrorResult(allocator, "replacement old_text must not be empty");
        }
    }
    return null;
}

fn parseStoreResource(value: []const u8) ?StoreResource {
    if (std.mem.eql(u8, value, "context")) return .context;
    if (std.mem.eql(u8, value, "rule")) return .rule;
    if (std.mem.eql(u8, value, "workflow")) return .workflow;
    return null;
}

fn daemonResourceName(resource: StoreResource) []const u8 {
    return switch (resource) {
        .context => "context",
        .rule => "rule",
        .workflow => "workflow",
    };
}

fn parseDraftOp(object: std.json.ObjectMap) ?DraftOp {
    if (object.count() != 1) return null;
    inline for (.{ DraftOp.create, DraftOp.update, DraftOp.rename, DraftOp.delete, DraftOp.discard }) |op| {
        if (object.get(draftOpName(op)) != null) return op;
    }
    return null;
}

fn draftOpName(op: DraftOp) []const u8 {
    return switch (op) {
        .create => "create",
        .update => "update",
        .rename => "rename",
        .delete => "delete",
        .discard => "discard",
    };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |string| string,
        else => null,
    };
}

fn rejectUnexpectedFields(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    allowed: []const []const u8,
    label: []const u8,
) !?[]u8 {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const known = for (allowed) |field| {
            if (std.mem.eql(u8, entry.key_ptr.*, field)) break true;
        } else false;
        if (!known) {
            const message = try std.fmt.allocPrint(
                allocator,
                "{s} contains unsupported field '{s}'",
                .{ label, entry.key_ptr.* },
            );
            defer allocator.free(message);
            return try tool_result.buildErrorResult(allocator, message);
        }
    }
    return null;
}

fn daemonToolError(allocator: std.mem.Allocator, err: anyerror, operation: []const u8) []u8 {
    _ = operation;
    const message = switch (err) {
        error.InvalidIds => "ids is required and must contain unique non-empty strings",
        error.XpcUnavailable => "local daemon IPC is only implemented on macOS",
        error.XpcReturnedNullConnection,
        error.XpcReturnedNullObject,
        error.XpcReturnedErrorObject,
        error.XpcExpectedDictionary,
        error.XpcMissingResponseJson,
        error.InvalidDaemonIpcResponse,
        error.DaemonIpcRejected,
        => "local daemon is unavailable or rejected the memory operation",
        else => "internal error while adapting the memory operation",
    };
    return tool_result.buildErrorResult(allocator, message) catch @constCast("{\"error\":{\"code\":-32603,\"message\":\"internal error\"}}");
}

test "buildListResult exposes activate load and store without old retrieval controls" {
    const result = try buildListResult(testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"activate\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"load\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"store\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"retrieve\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "META_PROMPT") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"kind\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"group\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"workflow\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "handleCall rejects removed retrieve tool without compatibility dispatch" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"name":"retrieve","arguments":{"ids":["ctx_test"]}}
    , .{});
    defer parsed.deinit();
    var session: session_mod.Session = .{
        .project_id = try testing.allocator.dupe(u8, "prj_test"),
        .workspace_root = try testing.allocator.dupe(u8, "/tmp/workspace"),
    };
    defer session.deinit(testing.allocator);
    const result = try handleCall(testing.allocator, &session, parsed.value);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Unknown tool") != null);
}

test "store maps Workflow text to typed daemon content" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"create":{"path":"workflow/CODING.md","body":"# Coding"}}
    , .{});
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try daemonDraftOperationValue(
        arena.allocator(),
        .workflow,
        .create,
        parsed.value.object.get("create").?.object,
        parsed.value,
    );
    const json = try daemon_ipc.storeDraftOperationRequestJsonAlloc(
        testing.allocator,
        "prj_test",
        "workflow",
        value,
    );
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"resource\":\"workflow\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"workflow\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"content\":\"# Coding\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"body\"") == null);
}

test "store forwards Rule text replacements without full content" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"update":{"id":"rule_test","expected_hash":"sha256:old","replacements":[{"old_text":"Use Zig","new_text":"Use Rust"}]}}
    , .{});
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try daemonDraftOperationValue(
        arena.allocator(),
        .rule,
        .update,
        parsed.value.object.get("update").?.object,
        parsed.value,
    );
    const json = try std.json.Stringify.valueAlloc(testing.allocator, value, .{});
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"expected_hash\":\"sha256:old\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"old_text\":\"Use Zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"new_text\":\"Use Rust\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"body\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"content\"") == null);
}

test "tool validation rejects undeclared and type-specific fields" {
    const activate = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"query":"search","kind":"context"}
    ,
        .{},
    );
    defer activate.deinit();
    const unexpected = (try rejectUnexpectedFields(
        testing.allocator,
        activate.value.object,
        &.{ "query", "state" },
        "activate",
    )).?;
    defer testing.allocator.free(unexpected);
    try testing.expect(std.mem.indexOf(u8, unexpected, "unsupported field 'kind'") != null);

    const context_write = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"path":"context/API.md","body":"body","tags":["invalid"]}
    ,
        .{},
    );
    defer context_write.deinit();
    const invalid_metadata = (try validateStoreOperation(
        testing.allocator,
        .context,
        .create,
        context_write.value.object,
    )).?;
    defer testing.allocator.free(invalid_metadata);
    try testing.expect(std.mem.indexOf(u8, invalid_metadata, "unsupported field 'tags'") != null);

    const full_body_update = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"id":"ctx_test","body":"complete replacement"}
    ,
        .{},
    );
    defer full_body_update.deinit();
    const rejected_body = (try validateStoreOperation(
        testing.allocator,
        .context,
        .update,
        full_body_update.value.object,
    )).?;
    defer testing.allocator.free(rejected_body);
    try testing.expect(std.mem.indexOf(u8, rejected_body, "unsupported field 'body'") != null);

    const exact_update = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"id":"ctx_test","expected_hash":"sha256:test","replacements":[{"old_text":"first","new_text":"one"},{"old_text":"second","new_text":""}]}
    ,
        .{},
    );
    defer exact_update.deinit();
    try testing.expect((try validateStoreOperation(
        testing.allocator,
        .context,
        .update,
        exact_update.value.object,
    )) == null);
}
