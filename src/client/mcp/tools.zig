//! Agent-facing MCP memory tools. The Rust daemon owns Effective Memory,
//! retrieval, loading, and Draft persistence; this module validates MCP input
//! and adapts it to daemon XPC JSON.
const std = @import("std");
const testing = std.testing;
const daemon_ipc = @import("../daemon/ipc.zig");
const session_mod = @import("session.zig");
const tool_names = @import("tool_names.zig");
const tool_result = @import("tool_result.zig");

const MAX_ISSUE_EXTERNAL_REFERENCES: usize = 16;
const MAX_ISSUE_EXTERNAL_REFERENCE_URL_BYTES: usize = 2_048;

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
    "{\"name\":\"" ++ tool_names.store ++ "\",\"title\":\"Store\",\"description\":\"Create, update, rename, delete, or discard a local Context, Rule, or Workflow Draft when the user explicitly requests memory maintenance. Issues are native objects managed by the issue tool, not Context documents. Before update, load the complete resource and use its content_hash with exact text replacements; update never accepts a complete document body. A successful call means durable local persistence and queued synchronization, not authoritative publication. Pass exactly one tagged operation.\"," ++
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

const issue_external_references_schema =
    "{\"type\":\"array\",\"maxItems\":" ++ std.fmt.comptimePrint("{d}", .{MAX_ISSUE_EXTERNAL_REFERENCES}) ++ ",\"description\":\"Typed external Issue and pull request links. On create, omission defaults to an empty list. On update, omission leaves the list unchanged and an explicit empty list clears it.\",\"items\":{\"$ref\":\"#/$defs/externalReference\"}}";

const issue_external_reference_definition =
    "{\"type\":\"object\",\"properties\":{" ++
    "\"kind\":{\"type\":\"string\",\"enum\":[\"issue\",\"pull_request\"]}," ++
    "\"url\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":" ++ std.fmt.comptimePrint("{d}", .{MAX_ISSUE_EXTERNAL_REFERENCE_URL_BYTES}) ++ ",\"format\":\"uri\",\"description\":\"Absolute HTTP(S) URL with a non-empty host and no embedded credentials.\"}" ++
    "},\"required\":[\"kind\",\"url\"],\"additionalProperties\":false}";

const issue_schema =
    "{\"name\":\"" ++ tool_names.kanban ++ "\",\"title\":\"Kanban\",\"description\":\"Manage the native project Kanban (distinct from remote GitHub Issues): get by global Issue ID, create, update, list, or make an explicit semantic transition on native project Issues. Create and update accept typed external_references; list and get return them with each Issue. Create Todo for durable follow-up work; call begin_work only when the current prompt begins or continues that Issue; request_closure only after judging its acceptance criteria satisfied. User approval is intentionally unavailable to Agents. AgentRun lifecycle events never make these decisions. Pass exactly one tagged operation.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{" ++
    "\"op\":{\"type\":\"object\",\"minProperties\":1,\"maxProperties\":1,\"properties\":{" ++
    "\"list\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}," ++
    "\"get\":{\"type\":\"object\",\"properties\":{\"issue_id\":{\"type\":\"string\",\"pattern\":\"^issue_[0-9a-f]{32}$\",\"description\":\"Globally unique Issue ID copied from Kanban.\"}},\"required\":[\"issue_id\"],\"additionalProperties\":false}," ++
    "\"create\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":240},\"description\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":65536},\"acceptance_criteria\":{\"type\":\"array\",\"maxItems\":64,\"items\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":2000}},\"external_references\":" ++ issue_external_references_schema ++ "},\"required\":[\"title\",\"description\"],\"additionalProperties\":false}," ++
    "\"update\":{\"type\":\"object\",\"properties\":{\"issue_key\":{\"type\":\"string\",\"pattern\":\"^ISSUE-(?!000$)[0-9]{3}$\"},\"expected_revision\":{\"type\":\"integer\",\"minimum\":1},\"title\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":240},\"description\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":65536},\"acceptance_criteria\":{\"type\":\"array\",\"maxItems\":64,\"items\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":2000}},\"external_references\":" ++ issue_external_references_schema ++ "},\"required\":[\"issue_key\",\"expected_revision\"],\"additionalProperties\":false}," ++
    "\"begin_work\":{\"type\":\"object\",\"description\":\"Bind the current AgentRun to this Issue and enter In Progress; requires run_id and the current revision.\",\"properties\":{\"run_id\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":256},\"issue_key\":{\"type\":\"string\",\"pattern\":\"^ISSUE-(?!000$)[0-9]{3}$\"},\"expected_revision\":{\"type\":\"integer\",\"minimum\":1}},\"required\":[\"run_id\",\"issue_key\",\"expected_revision\"],\"additionalProperties\":false}," ++
    "\"request_closure\":{\"type\":\"object\",\"properties\":{\"run_id\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":256},\"summary\":{\"type\":\"string\",\"maxLength\":1000},\"expected_revision\":{\"type\":\"integer\",\"minimum\":1}},\"required\":[\"run_id\",\"expected_revision\"],\"additionalProperties\":false}" ++
    "},\"additionalProperties\":false}" ++
    "},\"required\":[\"op\"],\"additionalProperties\":false,\"$defs\":{\"externalReference\":" ++ issue_external_reference_definition ++ "}}}";

pub fn buildListResult(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(
        u8,
        "{\"tools\":[" ++ activate_schema ++ "," ++ load_schema ++ "," ++ store_schema ++ "," ++ issue_schema ++ "]}",
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
    if (std.mem.eql(u8, name, tool_names.kanban)) {
        return handleIssue(allocator, session, args) catch |err| daemonToolError(allocator, err, "apply the Issue operation");
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

const IssueOp = enum { list, get, create, update, begin_work, request_closure };

fn handleIssue(
    allocator: std.mem.Allocator,
    session: *session_mod.Session,
    args: std.json.ObjectMap,
) ![]u8 {
    if (try rejectUnexpectedFields(allocator, args, &.{"op"}, "issue")) |result| {
        return result;
    }
    const tagged = switch (args.get("op") orelse return try tool_result.buildErrorResult(allocator, "op is required")) {
        .object => |object| object,
        else => return try tool_result.buildErrorResult(allocator, "op must be a JSON object"),
    };
    const op = parseIssueOp(tagged) orelse
        return try tool_result.buildErrorResult(allocator, "op must contain exactly one of list, get, create, update, begin_work, or request_closure");
    const op_args = switch (tagged.get(issueOpName(op)).?) {
        .object => |object| object,
        else => return try tool_result.buildErrorResult(allocator, "operation details must be a JSON object"),
    };

    var operation = switch (op) {
        .list => blk: {
            if (try rejectUnexpectedFields(allocator, op_args, &.{}, "list")) |result| return result;
            break :blk try daemon_ipc.listIssueBoardOperation(allocator, session.project_id);
        },
        .get => blk: {
            if (try rejectUnexpectedFields(allocator, op_args, &.{"issue_id"}, "get")) |result| return result;
            const issue_id = requiredString(op_args, "issue_id") orelse
                return try tool_result.buildErrorResult(allocator, "issue_id is required and must be a string");
            if (!isIssueId(issue_id)) {
                return try tool_result.buildErrorResult(allocator, "issue_id must match issue_<32 lowercase hexadecimal characters>");
            }
            break :blk try daemon_ipc.getIssueOperation(allocator, issue_id);
        },
        .create => blk: {
            if (try validateIssueCreate(allocator, op_args)) |result| return result;
            break :blk try daemon_ipc.issueOperation(
                allocator,
                "create_issue",
                session.project_id,
                op_args,
            );
        },
        .update => blk: {
            if (try validateIssueUpdate(allocator, op_args)) |result| return result;
            break :blk try daemon_ipc.issueOperation(
                allocator,
                "update_issue",
                session.project_id,
                op_args,
            );
        },
        .begin_work => blk: {
            if (try validateIssueBeginWork(allocator, op_args)) |result| return result;
            break :blk try daemon_ipc.startIssueWorkOperation(
                allocator,
                session.project_id,
                requiredString(op_args, "run_id").?,
                requiredString(op_args, "issue_key").?,
                requiredRevision(op_args, "expected_revision").?,
            );
        },
        .request_closure => blk: {
            if (try validateIssueClosureRequest(allocator, op_args)) |result| return result;
            break :blk try daemon_ipc.requestIssueClosureOperation(
                allocator,
                session.project_id,
                requiredString(op_args, "run_id").?,
                optionalString(op_args, "summary"),
                requiredRevision(op_args, "expected_revision").?,
            );
        },
    };
    defer operation.deinit(allocator);
    return try buildDaemonOperationResult(allocator, operation);
}

fn parseIssueOp(object: std.json.ObjectMap) ?IssueOp {
    if (object.count() != 1) return null;
    inline for (.{ IssueOp.list, IssueOp.get, IssueOp.create, IssueOp.update, IssueOp.begin_work, IssueOp.request_closure }) |op| {
        if (object.get(issueOpName(op)) != null) return op;
    }
    return null;
}

fn issueOpName(op: IssueOp) []const u8 {
    return switch (op) {
        .list => "list",
        .get => "get",
        .create => "create",
        .update => "update",
        .begin_work => "begin_work",
        .request_closure => "request_closure",
    };
}

fn validateIssueCreate(allocator: std.mem.Allocator, args: std.json.ObjectMap) !?[]u8 {
    if (try rejectUnexpectedFields(allocator, args, &.{ "title", "description", "acceptance_criteria", "external_references" }, "create")) |result| return result;
    const title = requiredString(args, "title") orelse
        return try tool_result.buildErrorResult(allocator, "title is required and must be a string");
    const description = requiredString(args, "description") orelse
        return try tool_result.buildErrorResult(allocator, "description is required and must be a string");
    if (title.len == 0 or title.len > 240) return try tool_result.buildErrorResult(allocator, "title must contain 1 to 240 bytes");
    if (description.len == 0 or description.len > 65536) return try tool_result.buildErrorResult(allocator, "description must contain 1 to 65536 bytes");
    if (try validateIssueStringArray(allocator, args.get("acceptance_criteria"), 64, 2000, "acceptance_criteria")) |result| return result;
    if (try validateIssueExternalReferences(allocator, args.get("external_references"))) |result| return result;
    return null;
}

fn validateIssueUpdate(allocator: std.mem.Allocator, args: std.json.ObjectMap) !?[]u8 {
    if (try rejectUnexpectedFields(allocator, args, &.{ "issue_key", "expected_revision", "title", "description", "acceptance_criteria", "external_references" }, "update")) |result| return result;
    const issue_key = requiredString(args, "issue_key") orelse
        return try tool_result.buildErrorResult(allocator, "issue_key is required and must be a string");
    if (!isIssueKey(issue_key)) return try tool_result.buildErrorResult(allocator, "issue_key must use the ISSUE-NNN form");
    if (requiredRevision(args, "expected_revision") == null) return try tool_result.buildErrorResult(allocator, "expected_revision is required and must be a positive integer");
    if (args.count() == 2) return try tool_result.buildErrorResult(allocator, "update must provide at least one semantic field");
    if (try validateOptionalIssueString(allocator, args.get("title"), 240, "title", false)) |result| return result;
    if (try validateOptionalIssueString(allocator, args.get("description"), 65536, "description", false)) |result| return result;
    if (try validateIssueStringArray(allocator, args.get("acceptance_criteria"), 64, 2000, "acceptance_criteria")) |result| return result;
    if (try validateIssueExternalReferences(allocator, args.get("external_references"))) |result| return result;
    return null;
}

fn validateIssueExternalReferences(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) !?[]u8 {
    const references = switch (value orelse return null) {
        .array => |array| array.items,
        else => return try tool_result.buildErrorResult(allocator, "external_references must be an array"),
    };
    if (references.len > MAX_ISSUE_EXTERNAL_REFERENCES) {
        return try tool_result.buildErrorResult(allocator, "external_references must contain at most 16 items");
    }
    for (references) |reference| {
        const object = switch (reference) {
            .object => |object| object,
            else => return try tool_result.buildErrorResult(allocator, "each external reference must be a JSON object"),
        };
        if (try rejectUnexpectedFields(allocator, object, &.{ "kind", "url" }, "external reference")) |result| {
            return result;
        }
        const kind = requiredString(object, "kind") orelse
            return try tool_result.buildErrorResult(allocator, "external reference kind is required and must be a string");
        if (!std.mem.eql(u8, kind, "issue") and !std.mem.eql(u8, kind, "pull_request")) {
            return try tool_result.buildErrorResult(allocator, "external reference kind must be 'issue' or 'pull_request'");
        }
        const url = requiredString(object, "url") orelse
            return try tool_result.buildErrorResult(allocator, "external reference url is required and must be a string");
        const trimmed_url = std.mem.trim(u8, url, &std.ascii.whitespace);
        if (trimmed_url.len == 0 or trimmed_url.len > MAX_ISSUE_EXTERNAL_REFERENCE_URL_BYTES) {
            return try tool_result.buildErrorResult(allocator, "external reference url must contain 1 to 2048 bytes after trimming");
        }
        const uri = std.Uri.parse(trimmed_url) catch
            return try tool_result.buildErrorResult(allocator, "external reference url must be an absolute HTTP(S) URL");
        if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or
            uri.host == null or uri.host.?.isEmpty())
        {
            return try tool_result.buildErrorResult(allocator, "external reference url must be an absolute HTTP(S) URL with a non-empty host");
        }
        if (uri.user != null or uri.password != null) {
            return try tool_result.buildErrorResult(allocator, "external reference url must not contain embedded credentials");
        }
    }
    return null;
}

fn validateIssueStringArray(allocator: std.mem.Allocator, value: ?std.json.Value, max_items: usize, max_bytes: usize, name: []const u8) !?[]u8 {
    const candidate = value orelse return null;
    const items = switch (candidate) {
        .array => |array| array.items,
        else => {
            const message = try std.fmt.allocPrint(allocator, "{s} must be an array of strings", .{name});
            defer allocator.free(message);
            return try tool_result.buildErrorResult(allocator, message);
        },
    };
    if (items.len > max_items) {
        const message = try std.fmt.allocPrint(allocator, "{s} contains too many items", .{name});
        defer allocator.free(message);
        return try tool_result.buildErrorResult(allocator, message);
    }
    for (items) |item| {
        const string = switch (item) {
            .string => |string| string,
            else => {
                const message = try std.fmt.allocPrint(allocator, "{s} must contain only strings", .{name});
                defer allocator.free(message);
                return try tool_result.buildErrorResult(allocator, message);
            },
        };
        if (string.len == 0 or string.len > max_bytes) {
            const message = try std.fmt.allocPrint(allocator, "{s} contains an invalid string", .{name});
            defer allocator.free(message);
            return try tool_result.buildErrorResult(allocator, message);
        }
    }
    return null;
}

fn validateOptionalIssueString(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    max_bytes: usize,
    name: []const u8,
    allows_empty: bool,
) !?[]u8 {
    const candidate = value orelse return null;
    const string = switch (candidate) {
        .string => |string| string,
        else => {
            const message = try std.fmt.allocPrint(allocator, "{s} must be a string", .{name});
            defer allocator.free(message);
            return try tool_result.buildErrorResult(allocator, message);
        },
    };
    if ((!allows_empty and string.len == 0) or string.len > max_bytes) {
        const message = try std.fmt.allocPrint(allocator, "{s} has an invalid length", .{name});
        defer allocator.free(message);
        return try tool_result.buildErrorResult(allocator, message);
    }
    return null;
}

fn validateIssueBeginWork(
    allocator: std.mem.Allocator,
    args: std.json.ObjectMap,
) !?[]u8 {
    if (try rejectUnexpectedFields(allocator, args, &.{ "run_id", "issue_key", "expected_revision" }, "begin_work")) |result| {
        return result;
    }
    const run_id = requiredString(args, "run_id") orelse
        return try tool_result.buildErrorResult(allocator, "run_id is required and must be a string");
    if (run_id.len == 0 or run_id.len > 256) {
        return try tool_result.buildErrorResult(allocator, "run_id must contain 1 to 256 bytes");
    }
    const issue_key = requiredString(args, "issue_key") orelse
        return try tool_result.buildErrorResult(allocator, "issue_key is required and must be a string");
    if (!isIssueKey(issue_key)) {
        return try tool_result.buildErrorResult(allocator, "issue_key must use the ISSUE-NNN form");
    }
    if (requiredRevision(args, "expected_revision") == null) {
        return try tool_result.buildErrorResult(allocator, "expected_revision is required and must be a positive integer");
    }
    return null;
}

fn validateIssueClosureRequest(
    allocator: std.mem.Allocator,
    args: std.json.ObjectMap,
) !?[]u8 {
    if (try rejectUnexpectedFields(allocator, args, &.{ "run_id", "summary", "expected_revision" }, "request_closure")) |result| {
        return result;
    }
    const run_id = requiredString(args, "run_id") orelse
        return try tool_result.buildErrorResult(allocator, "run_id is required and must be a string");
    if (run_id.len == 0 or run_id.len > 256) {
        return try tool_result.buildErrorResult(allocator, "run_id must contain 1 to 256 bytes");
    }
    if (args.get("summary")) |value| {
        const summary = switch (value) {
            .string => |string| string,
            else => return try tool_result.buildErrorResult(allocator, "summary must be a string"),
        };
        if (summary.len > 1000) {
            return try tool_result.buildErrorResult(allocator, "summary must not exceed 1000 UTF-8 bytes");
        }
    }
    if (requiredRevision(args, "expected_revision") == null) {
        return try tool_result.buildErrorResult(allocator, "expected_revision is required and must be a positive integer");
    }
    return null;
}

fn isIssueKey(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "ISSUE-")) return false;
    const digits = value["ISSUE-".len..];
    if (digits.len != 3) return false;
    var all_zero = true;
    for (digits) |digit| {
        if (!std.ascii.isDigit(digit)) return false;
        if (digit != '0') all_zero = false;
    }
    if (all_zero) return false;
    return true;
}

fn isIssueId(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "issue_")) return false;
    const suffix = value["issue_".len..];
    if (suffix.len != 32) return false;
    for (suffix) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
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

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |string| string,
        else => null,
    };
}

fn requiredRevision(object: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (object.get(key) orelse return null) {
        .integer => |value| if (value > 0) value else null,
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

test "buildListResult exposes memory and explicit Issue workflow tools without old retrieval controls" {
    const result = try buildListResult(testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"activate\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"load\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"store\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"kanban\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"list\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"get\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "global Issue ID") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"create\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"update\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"begin_work\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"request_closure\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "TaskCreated") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"retrieve\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "META_PROMPT") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"group\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"workflow\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "issue schema exposes bounded typed external references" {
    const result = try buildListResult(testing.allocator);
    defer testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array.items;
    const issue_tool = for (tools) |tool| {
        const object = tool.object;
        if (std.mem.eql(u8, object.get("name").?.string, tool_names.kanban)) break object;
    } else unreachable;
    const input_schema = issue_tool.get("inputSchema").?.object;
    const operations = input_schema.get("properties").?.object.get("op").?.object.get("properties").?.object;
    inline for (.{ "create", "update" }) |operation_name| {
        const external_references = operations.get(operation_name).?.object
            .get("properties").?.object
            .get("external_references").?.object;
        try testing.expectEqual(@as(i64, MAX_ISSUE_EXTERNAL_REFERENCES), external_references.get("maxItems").?.integer);
        try testing.expectEqualStrings("#/$defs/externalReference", external_references.get("items").?.object.get("$ref").?.string);
    }

    const definition = input_schema.get("$defs").?.object.get("externalReference").?.object;
    try testing.expectEqual(false, definition.get("additionalProperties").?.bool);
    const properties = definition.get("properties").?.object;
    const kinds = properties.get("kind").?.object.get("enum").?.array.items;
    try testing.expectEqual(@as(usize, 2), kinds.len);
    try testing.expectEqualStrings("issue", kinds[0].string);
    try testing.expectEqualStrings("pull_request", kinds[1].string);
    try testing.expectEqual(@as(i64, MAX_ISSUE_EXTERNAL_REFERENCE_URL_BYTES), properties.get("url").?.object.get("maxLength").?.integer);
}

test "issue accepts only canonical global Issue IDs for get" {
    try testing.expect(isIssueId("issue_0123456789abcdef0123456789abcdef"));
    try testing.expect(!isIssueId("ISSUE-007"));
    try testing.expect(!isIssueId("issue_0123456789ABCDEF0123456789ABCDEF"));
    try testing.expect(!isIssueId("issue_0123456789abcdef"));
    try testing.expect(!isIssueId("issue_0123456789abcdef0123456789abcdeg"));
}

test "issue validates native create and semantic update inputs before daemon IPC" {
    const create = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"title":"Export native Issues","description":"Add an explicit Markdown export operation.","acceptance_criteria":["Preserve stable keys"],"external_references":[{"kind":"issue","url":"https://github.com/acme/clumsies/issues/11"},{"kind":"pull_request","url":"https://github.com/acme/clumsies/pull/12?diff=split#discussion"}]}
    ,
        .{},
    );
    defer create.deinit();
    try testing.expect((try validateIssueCreate(testing.allocator, create.value.object)) == null);

    const update = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"issue_key":"ISSUE-007","expected_revision":2,"external_references":[]}
    ,
        .{},
    );
    defer update.deinit();
    try testing.expect((try validateIssueUpdate(testing.allocator, update.value.object)) == null);

    const empty_update = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"issue_key":"ISSUE-007","expected_revision":2}
    ,
        .{},
    );
    defer empty_update.deinit();
    const update_error = (try validateIssueUpdate(testing.allocator, empty_update.value.object)).?;
    defer testing.allocator.free(update_error);
    try testing.expect(std.mem.indexOf(u8, update_error, "semantic field") != null);
}

test "issue rejects malformed external references before daemon IPC" {
    const invalid_cases = [_]struct {
        json: []const u8,
        expected_error: []const u8,
    }{
        .{
            .json =
            \\{"title":"Track upstream","description":"Link it.","external_references":[{"kind":"commit","url":"https://github.com/acme/clumsies/commit/abc"}]}
            ,
            .expected_error = "kind must be 'issue' or 'pull_request'",
        },
        .{
            .json =
            \\{"title":"Track upstream","description":"Link it.","external_references":[{"kind":"issue","url":"ftp://github.com/acme/clumsies/issues/11"}]}
            ,
            .expected_error = "absolute HTTP(S) URL with a non-empty host",
        },
        .{
            .json =
            \\{"title":"Track upstream","description":"Link it.","external_references":[{"kind":"pull_request","url":"https://token@github.com/acme/clumsies/pull/12"}]}
            ,
            .expected_error = "must not contain embedded credentials",
        },
        .{
            .json =
            \\{"title":"Track upstream","description":"Link it.","external_references":[{"kind":"issue","url":"https://github.com/acme/clumsies/issues/11","label":"upstream"}]}
            ,
            .expected_error = "unsupported field 'label'",
        },
    };

    for (invalid_cases) |invalid| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, invalid.json, .{});
        defer parsed.deinit();
        const result = (try validateIssueCreate(testing.allocator, parsed.value.object)).?;
        defer testing.allocator.free(result);
        try testing.expect(std.mem.indexOf(u8, result, invalid.expected_error) != null);
    }

    var reference: std.json.ObjectMap = .empty;
    defer reference.deinit(testing.allocator);
    try reference.put(testing.allocator, "kind", .{ .string = "issue" });
    try reference.put(testing.allocator, "url", .{ .string = "https://github.com/acme/clumsies/issues/11" });
    var too_many = std.json.Array.init(testing.allocator);
    defer too_many.deinit();
    for (0..MAX_ISSUE_EXTERNAL_REFERENCES + 1) |_| {
        try too_many.append(.{ .object = reference });
    }
    const limit_error = (try validateIssueExternalReferences(
        testing.allocator,
        .{ .array = too_many },
    )).?;
    defer testing.allocator.free(limit_error);
    try testing.expect(std.mem.indexOf(u8, limit_error, "at most 16 items") != null);
}

test "issue forwards external references in list and get daemon payloads" {
    const payloads = [_][]const u8{
        \\{"issues":[{"external_references":[{"kind":"issue","url":"https://github.com/acme/clumsies/issues/11"}]}]}
        ,
        \\{"issue":{"external_references":[{"kind":"pull_request","url":"https://github.com/acme/clumsies/pull/12"}]}}
        ,
    };

    for (payloads) |payload| {
        var operation: daemon_ipc.OperationResult = .{
            .structured_json = try testing.allocator.dupe(u8, payload),
            .error_message = null,
        };
        defer operation.deinit(testing.allocator);
        const result = try buildDaemonOperationResult(testing.allocator, operation);
        defer testing.allocator.free(result);
        try testing.expect(std.mem.indexOf(u8, result, "\"structuredContent\"") != null);
        try testing.expect(std.mem.indexOf(u8, result, "\"external_references\"") != null);
        try testing.expect(std.mem.indexOf(u8, result, "https://github.com/acme/clumsies/") != null);
    }
}

test "issue validates tagged start and request_closure inputs before daemon IPC" {
    const start = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"run_id":"arun_1","issue_key":"ISSUE-003","expected_revision":4}
    ,
        .{},
    );
    defer start.deinit();
    try testing.expect((try validateIssueBeginWork(testing.allocator, start.value.object)) == null);

    const zero_revision = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"run_id":"arun_1","issue_key":"ISSUE-003","expected_revision":0}
    ,
        .{},
    );
    defer zero_revision.deinit();
    const revision_error = (try validateIssueBeginWork(testing.allocator, zero_revision.value.object)).?;
    defer testing.allocator.free(revision_error);
    try testing.expect(std.mem.indexOf(u8, revision_error, "positive integer") != null);

    const github_number = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"run_id":"arun_1","issue_key":"#3","expected_revision":4}
    ,
        .{},
    );
    defer github_number.deinit();
    const issue_error = (try validateIssueBeginWork(testing.allocator, github_number.value.object)).?;
    defer testing.allocator.free(issue_error);
    try testing.expect(std.mem.indexOf(u8, issue_error, "ISSUE-NNN") != null);

    const zero_issue = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"run_id":"arun_1","issue_key":"ISSUE-000","expected_revision":4}
    ,
        .{},
    );
    defer zero_issue.deinit();
    const zero_issue_error = (try validateIssueBeginWork(testing.allocator, zero_issue.value.object)).?;
    defer testing.allocator.free(zero_issue_error);
    try testing.expect(std.mem.indexOf(u8, zero_issue_error, "ISSUE-NNN") != null);

    const wide_issue = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"run_id":"arun_1","issue_key":"ISSUE-0003","expected_revision":4}
    ,
        .{},
    );
    defer wide_issue.deinit();
    const wide_issue_error = (try validateIssueBeginWork(testing.allocator, wide_issue.value.object)).?;
    defer testing.allocator.free(wide_issue_error);
    try testing.expect(std.mem.indexOf(u8, wide_issue_error, "ISSUE-NNN") != null);

    const request_closure = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"run_id":"arun_1","summary":"Acceptance criteria are satisfied","expected_revision":5}
    ,
        .{},
    );
    defer request_closure.deinit();
    try testing.expect((try validateIssueClosureRequest(testing.allocator, request_closure.value.object)) == null);

    const inferred_outcome = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"run_id":"arun_1","outcome":"completed","expected_revision":5}
    ,
        .{},
    );
    defer inferred_outcome.deinit();
    const outcome_error = (try validateIssueClosureRequest(testing.allocator, inferred_outcome.value.object)).?;
    defer testing.allocator.free(outcome_error);
    try testing.expect(std.mem.indexOf(u8, outcome_error, "unsupported field 'outcome'") != null);
}

test "issue rejects multiple tags without calling daemon" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\{"name":"kanban","arguments":{"op":{"list":{},"begin_work":{"run_id":"arun_1","issue_key":"ISSUE-003","expected_revision":1}}}}
    ,
        .{},
    );
    defer parsed.deinit();
    var session: session_mod.Session = .{
        .project_id = try testing.allocator.dupe(u8, "prj_test"),
        .workspace_root = try testing.allocator.dupe(u8, "/tmp/workspace"),
    };
    defer session.deinit(testing.allocator);

    const result = try handleCall(testing.allocator, &session, parsed.value);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, result, "exactly one") != null);
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
