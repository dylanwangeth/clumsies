const std = @import("std");
const build_options = @import("build_options");

pub const MACH_SERVICE_NAME = "ai.clumsies.daemon";

const REQUEST_JSON_KEY = "request_json";
const RESPONSE_JSON_KEY = "response_json";
const enable_xpc = build_options.enable_xpc;

const EmptyPayload = struct {};

pub const OperationResult = struct {
    structured_json: []u8,
    error_message: ?[]u8,

    pub fn deinit(self: *OperationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.structured_json);
        if (self.error_message) |message| allocator.free(message);
        self.* = undefined;
    }

    pub fn isError(self: OperationResult) bool {
        return self.error_message != null;
    }
};

pub const ProjectBinding = struct {
    project_id: []u8,
    workspace_root: []u8,

    pub fn deinit(self: *ProjectBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.project_id);
        allocator.free(self.workspace_root);
        self.* = undefined;
    }
};

pub fn resolveProjectBinding(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
) !ProjectBinding {
    const request_json = try requestWithPayloadJsonAlloc(allocator, "resolve_project_binding", .{
        .workspace_path = workspace_path,
    });
    defer allocator.free(request_json);
    const response_json = try callJson(allocator, MACH_SERVICE_NAME, request_json);
    defer allocator.free(response_json);
    return try projectBindingFromResponse(allocator, response_json);
}

pub fn replaceProjectBinding(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    project_id: []const u8,
    expected_revision: ?i64,
) !ProjectBinding {
    const request_json = try requestWithPayloadJsonAlloc(allocator, "replace_project_binding", .{
        .workspace_root = workspace_root,
        .project_id = project_id,
        .expected_revision = expected_revision,
    });
    defer allocator.free(request_json);
    const response_json = try callJson(allocator, MACH_SERVICE_NAME, request_json);
    defer allocator.free(response_json);
    return try projectBindingFromResponse(allocator, response_json);
}

pub fn serverGetBodyAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const request_json = try requestWithPayloadJsonAlloc(allocator, "server_request", .{
        .method = "GET",
        .path = path,
        .headers = std.json.Value{ .object = .empty },
        .body = @as(?[]const u8, null),
    });
    defer allocator.free(request_json);
    const response_json = try callJson(allocator, MACH_SERVICE_NAME, request_json);
    defer allocator.free(response_json);
    const payload_json = try payloadJsonFromResponse(allocator, response_json);
    defer allocator.free(payload_json);
    const parsed = try std.json.parseFromSlice(
        struct { status: u16, body: []const u8 },
        allocator,
        payload_json,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    if (parsed.value.status < 200 or parsed.value.status >= 300) return error.ServerRequestFailed;
    return try allocator.dupe(u8, parsed.value.body);
}

pub fn retryCommitSync(allocator: std.mem.Allocator) !void {
    const request_json = try requestWithPayloadJsonAlloc(allocator, "retry_sync", .{
        .channel = "commits",
    });
    defer allocator.free(request_json);
    const response_json = try callJson(allocator, MACH_SERVICE_NAME, request_json);
    defer allocator.free(response_json);
    const payload_json = try payloadJsonFromResponse(allocator, response_json);
    allocator.free(payload_json);
}

pub fn healthPayloadJson(allocator: std.mem.Allocator) ![]u8 {
    const response_json = try callEmpty(allocator, MACH_SERVICE_NAME, "health");
    defer allocator.free(response_json);
    return try payloadJsonFromResponse(allocator, response_json);
}

pub fn memoryCacheRootAlloc(allocator: std.mem.Allocator, project_id: []const u8) ![]u8 {
    const request_json = try memoryCacheRequestJsonAlloc(allocator, project_id);
    defer allocator.free(request_json);
    const response_json = try callJson(allocator, MACH_SERVICE_NAME, request_json);
    defer allocator.free(response_json);
    const payload_json = try payloadJsonFromResponse(allocator, response_json);
    defer allocator.free(payload_json);

    const parsed = try std.json.parseFromSlice(
        struct {
            project_id: []const u8,
            commit_id: ?[]const u8,
            root_path: ?[]const u8,
            state: []const u8,
        },
        allocator,
        payload_json,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.state, "ready")) {
        if (std.mem.eql(u8, parsed.value.state, "project_ref_not_synced")) return error.ProjectRefNotSynced;
        if (std.mem.eql(u8, parsed.value.state, "generation_missing")) return error.CommitGenerationMissing;
        if (std.mem.eql(u8, parsed.value.state, "generation_corrupt")) return error.CommitGenerationCorrupt;
        return error.InvalidDaemonIpcResponse;
    }
    const root_path = parsed.value.root_path orelse return error.InvalidDaemonIpcResponse;
    return try allocator.dupe(u8, root_path);
}

pub fn memoryCacheRequestJsonAlloc(allocator: std.mem.Allocator, project_id: []const u8) ![]u8 {
    return requestWithPayloadJsonAlloc(allocator, "memory_cache", .{ .project_id = project_id });
}

pub fn activateMemoryOperation(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    query: []const u8,
    state: ?[]const u8,
) !OperationResult {
    const request_json = try activateMemoryRequestJsonAlloc(allocator, project_id, query, state);
    defer allocator.free(request_json);
    const response_json = try callJson(allocator, MACH_SERVICE_NAME, request_json);
    defer allocator.free(response_json);
    return try operationResultFromResponse(allocator, response_json);
}

pub fn activateMemoryRequestJsonAlloc(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    query: []const u8,
    state: ?[]const u8,
) ![]u8 {
    return requestWithPayloadJsonAlloc(allocator, "activate_memory", .{
        .project_id = project_id,
        .query = query,
        .state = state,
    });
}

pub fn loadMemoryOperation(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    ids: []const []const u8,
    known_hashes: std.json.Value,
) !OperationResult {
    const request_json = try loadMemoryRequestJsonAlloc(
        allocator,
        project_id,
        ids,
        known_hashes,
    );
    defer allocator.free(request_json);
    const response_json = try callJson(allocator, MACH_SERVICE_NAME, request_json);
    defer allocator.free(response_json);
    return try operationResultFromResponse(allocator, response_json);
}

pub fn loadMemoryRequestJsonAlloc(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    ids: []const []const u8,
    known_hashes: std.json.Value,
) ![]u8 {
    return requestWithPayloadJsonAlloc(allocator, "load_memory", .{
        .project_id = project_id,
        .ids = ids,
        .known_hashes = known_hashes,
    });
}

pub fn callEmpty(allocator: std.mem.Allocator, service_name: []const u8, method: []const u8) ![]u8 {
    const request_json = try requestJsonAlloc(allocator, method);
    defer allocator.free(request_json);
    return try callJson(allocator, service_name, request_json);
}

pub fn requestJsonAlloc(allocator: std.mem.Allocator, method: []const u8) ![]u8 {
    return requestWithPayloadJsonAlloc(allocator, method, EmptyPayload{});
}

pub fn storeDraftOperation(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    resource: []const u8,
    op: std.json.Value,
) !OperationResult {
    const request_json = try storeDraftOperationRequestJsonAlloc(allocator, project_id, resource, op);
    defer allocator.free(request_json);

    const response_json = try callJson(allocator, MACH_SERVICE_NAME, request_json);
    defer allocator.free(response_json);

    return try operationResultFromResponse(allocator, response_json);
}

pub fn storeDraftOperationRequestJsonAlloc(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    resource: []const u8,
    op: std.json.Value,
) ![]u8 {
    const payload = struct {
        project_id: []const u8,
        scope: []const u8,
        resource: []const u8,
        op: std.json.Value,
        source: []const u8,
    }{
        .project_id = project_id,
        .scope = "project",
        .resource = resource,
        .op = op,
        .source = "mcp_store",
    };
    return requestWithPayloadJsonAlloc(allocator, "store_draft_operation", payload);
}

fn requestWithPayloadJsonAlloc(allocator: std.mem.Allocator, method: []const u8, payload: anytype) ![]u8 {
    const Request = struct {
        method: []const u8,
        payload: @TypeOf(payload),
    };
    return std.json.Stringify.valueAlloc(allocator, Request{
        .method = method,
        .payload = payload,
    }, .{});
}

pub fn payloadJsonFromResponse(allocator: std.mem.Allocator, response_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidDaemonIpcResponse,
    };
    const ok_value = root.get("ok") orelse return error.InvalidDaemonIpcResponse;
    const ok = switch (ok_value) {
        .bool => |value| value,
        else => return error.InvalidDaemonIpcResponse,
    };
    if (!ok) return error.DaemonIpcRejected;

    const payload = root.get("payload") orelse return error.InvalidDaemonIpcResponse;
    return std.json.Stringify.valueAlloc(allocator, payload, .{ .whitespace = .indent_2 });
}

pub fn operationResultFromResponse(
    allocator: std.mem.Allocator,
    response_json: []const u8,
) !OperationResult {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidDaemonIpcResponse,
    };
    const ok = switch (root.get("ok") orelse return error.InvalidDaemonIpcResponse) {
        .bool => |value| value,
        else => return error.InvalidDaemonIpcResponse,
    };
    if (ok) {
        const payload = root.get("payload") orelse return error.InvalidDaemonIpcResponse;
        return .{
            .structured_json = try std.json.Stringify.valueAlloc(
                allocator,
                payload,
                .{},
            ),
            .error_message = null,
        };
    }

    const daemon_error = root.get("error") orelse return error.InvalidDaemonIpcResponse;
    const error_object = switch (daemon_error) {
        .object => |object| object,
        else => return error.InvalidDaemonIpcResponse,
    };
    const message = switch (error_object.get("message") orelse return error.InvalidDaemonIpcResponse) {
        .string => |value| value,
        else => return error.InvalidDaemonIpcResponse,
    };
    const error_json = try std.json.Stringify.valueAlloc(allocator, daemon_error, .{});
    defer allocator.free(error_json);
    const structured_json = try std.fmt.allocPrint(allocator, "{{\"error\":{s}}}", .{error_json});
    errdefer allocator.free(structured_json);
    return .{
        .structured_json = structured_json,
        .error_message = try allocator.dupe(u8, message),
    };
}

fn projectBindingFromResponse(
    allocator: std.mem.Allocator,
    response_json: []const u8,
) !ProjectBinding {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidDaemonIpcResponse,
    };
    const ok = switch (root.get("ok") orelse return error.InvalidDaemonIpcResponse) {
        .bool => |value| value,
        else => return error.InvalidDaemonIpcResponse,
    };
    if (!ok) {
        const daemon_error = switch (root.get("error") orelse return error.InvalidDaemonIpcResponse) {
            .object => |object| object,
            else => return error.InvalidDaemonIpcResponse,
        };
        const code = switch (daemon_error.get("code") orelse return error.InvalidDaemonIpcResponse) {
            .string => |value| value,
            else => return error.InvalidDaemonIpcResponse,
        };
        if (std.mem.eql(u8, code, "project_binding_not_found")) return error.ProjectBindingNotFound;
        if (std.mem.eql(u8, code, "project_binding_unresolved")) return error.ProjectBindingUnresolved;
        if (std.mem.eql(u8, code, "project_binding_ambiguous")) return error.ProjectBindingAmbiguous;
        if (std.mem.eql(u8, code, "project_binding_changed")) return error.ProjectBindingChanged;
        return error.DaemonIpcRejected;
    }
    const payload = switch (root.get("payload") orelse return error.InvalidDaemonIpcResponse) {
        .object => |object| object,
        else => return error.InvalidDaemonIpcResponse,
    };
    const project_id = switch (payload.get("project_id") orelse return error.InvalidDaemonIpcResponse) {
        .string => |value| value,
        else => return error.InvalidDaemonIpcResponse,
    };
    const workspace_root = switch (payload.get("workspace_root") orelse return error.InvalidDaemonIpcResponse) {
        .string => |value| value,
        else => return error.InvalidDaemonIpcResponse,
    };
    const owned_project_id = try allocator.dupe(u8, project_id);
    errdefer allocator.free(owned_project_id);
    return .{
        .project_id = owned_project_id,
        .workspace_root = try allocator.dupe(u8, workspace_root),
    };
}

fn callJson(allocator: std.mem.Allocator, service_name: []const u8, request_json: []const u8) ![]u8 {
    if (comptime !enable_xpc) {
        return error.XpcUnavailable;
    } else {
        const service_name_z = try dupeZ(allocator, service_name);
        defer allocator.free(service_name_z);
        const request_json_z = try dupeZ(allocator, request_json);
        defer allocator.free(request_json_z);

        const connection = c.clumsies_xpc_connection_create(service_name_z.ptr) orelse
            return error.XpcReturnedNullConnection;
        defer {
            c.xpc_connection_cancel(connection);
            c.xpc_release(connection);
        }
        const message = c.xpc_dictionary_create(null, null, 0) orelse return error.XpcReturnedNullObject;
        defer c.xpc_release(message);
        try setXpcString(message, REQUEST_JSON_KEY, request_json_z);

        const reply = c.xpc_connection_send_message_with_reply_sync(connection, message) orelse
            return error.XpcReturnedNullObject;
        defer c.xpc_release(reply);

        const reply_type = c.xpc_get_type(reply);
        if (reply_type == xpcErrorType()) return error.XpcReturnedErrorObject;
        if (reply_type != xpcDictionaryType()) return error.XpcExpectedDictionary;

        const response_json = try xpcDictionaryString(reply, RESPONSE_JSON_KEY);
        return try allocator.dupe(u8, response_json);
    }
}

fn setXpcString(object: *anyopaque, key: []const u8, value: [:0]const u8) !void {
    const key_z = try dupeZ(std.heap.smp_allocator, key);
    defer std.heap.smp_allocator.free(key_z);
    c.xpc_dictionary_set_string(object, key_z.ptr, value.ptr);
}

fn xpcDictionaryString(object: *anyopaque, key: []const u8) ![]const u8 {
    const key_z = try dupeZ(std.heap.smp_allocator, key);
    defer std.heap.smp_allocator.free(key_z);
    const value = c.xpc_dictionary_get_string(object, key_z.ptr) orelse return error.XpcMissingResponseJson;
    return std.mem.span(value);
}

fn dupeZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result;
}

fn xpcDictionaryType() ?*const anyopaque {
    return @ptrCast(&c._xpc_type_dictionary);
}

fn xpcErrorType() ?*const anyopaque {
    return @ptrCast(&c._xpc_type_error);
}

const c = if (enable_xpc) struct {
    extern "c" var _xpc_type_dictionary: anyopaque;
    extern "c" var _xpc_type_error: anyopaque;

    extern "c" fn clumsies_xpc_connection_create(name: [*:0]const u8) ?*anyopaque;
    extern "c" fn xpc_connection_cancel(connection: *anyopaque) void;
    extern "c" fn xpc_connection_send_message_with_reply_sync(
        connection: *anyopaque,
        message: *anyopaque,
    ) ?*anyopaque;
    extern "c" fn xpc_dictionary_create(
        keys: ?*const [*:0]const u8,
        values: ?*const *anyopaque,
        count: usize,
    ) ?*anyopaque;
    extern "c" fn xpc_dictionary_set_string(
        object: *anyopaque,
        key: [*:0]const u8,
        value: [*:0]const u8,
    ) void;
    extern "c" fn xpc_dictionary_get_string(
        object: *anyopaque,
        key: [*:0]const u8,
    ) ?[*:0]const u8;
    extern "c" fn xpc_get_type(object: *anyopaque) ?*const anyopaque;
    extern "c" fn xpc_release(object: *anyopaque) void;
} else struct {};

test "requestJsonAlloc builds daemon IPC envelope" {
    const json = try requestJsonAlloc(std.testing.allocator, "health");
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(
        \\{"method":"health","payload":{}}
    , json);
}

test "storeDraftOperationRequestJsonAlloc builds daemon store envelope" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"create":{"path":"context/API.md","content":{"kind":"context","content":"body"}}}
    ,
        .{},
    );
    defer parsed.deinit();

    const json = try storeDraftOperationRequestJsonAlloc(
        std.testing.allocator,
        "prj_test",
        "context",
        parsed.value,
    );
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"store_draft_operation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"project_id\":\"prj_test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scope\":\"project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resource\":\"context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source\":\"mcp_store\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"context/API.md\"") != null);
}

test "activateMemoryRequestJsonAlloc builds daemon search envelope" {
    const json = try activateMemoryRequestJsonAlloc(
        std.testing.allocator,
        "prj_test",
        "hybrid retrieval",
        "state-token",
    );
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(
        \\{"method":"activate_memory","payload":{"project_id":"prj_test","query":"hybrid retrieval","state":"state-token"}}
    , json);
}

test "loadMemoryRequestJsonAlloc maps MCP knownHashes to daemon known_hashes" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"ctx_api":"sha256:abc"}
    , .{});
    defer parsed.deinit();
    const json = try loadMemoryRequestJsonAlloc(
        std.testing.allocator,
        "prj_test",
        &.{"ctx_api"},
        parsed.value,
    );
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"load_memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"known_hashes\":{\"ctx_api\":\"sha256:abc\"}") != null);
}

test "memoryCacheRequestJsonAlloc builds daemon cache envelope" {
    const json = try memoryCacheRequestJsonAlloc(std.testing.allocator, "project_test");
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(
        \\{"method":"memory_cache","payload":{"project_id":"project_test"}}
    , json);
}

test "project binding envelopes use workspace paths and canonical project ids" {
    const resolve_json = try requestWithPayloadJsonAlloc(std.testing.allocator, "resolve_project_binding", .{
        .workspace_path = "/tmp/example/packages/app",
    });
    defer std.testing.allocator.free(resolve_json);
    try std.testing.expectEqualStrings(
        \\{"method":"resolve_project_binding","payload":{"workspace_path":"/tmp/example/packages/app"}}
    , resolve_json);

    const replace_json = try requestWithPayloadJsonAlloc(std.testing.allocator, "replace_project_binding", .{
        .workspace_root = "/tmp/example",
        .project_id = "prj_example",
        .expected_revision = @as(?i64, null),
    });
    defer std.testing.allocator.free(replace_json);
    try std.testing.expectEqualStrings(
        \\{"method":"replace_project_binding","payload":{"workspace_root":"/tmp/example","project_id":"prj_example","expected_revision":null}}
    , replace_json);
}

test "projectBindingFromResponse preserves the daemon canonical binding" {
    var binding = try projectBindingFromResponse(std.testing.allocator,
        \\{"ok":true,"payload":{"server_url":"https://app.clumsies.ai","workspace_root":"/tmp/example","project_id":"prj_example","revision":1,"created_at":"2026-07-22T00:00:00Z","updated_at":"2026-07-22T00:00:00Z"},"error":null}
    );
    defer binding.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("prj_example", binding.project_id);
    try std.testing.expectEqualStrings("/tmp/example", binding.workspace_root);
}

test "projectBindingFromResponse keeps binding failures distinct" {
    try std.testing.expectError(
        error.ProjectBindingNotFound,
        projectBindingFromResponse(std.testing.allocator,
            \\{"ok":false,"payload":{},"error":{"code":"project_binding_not_found","message":"not bound"}}
        ),
    );
    try std.testing.expectError(
        error.ProjectBindingUnresolved,
        projectBindingFromResponse(std.testing.allocator,
            \\{"ok":false,"payload":{},"error":{"code":"project_binding_unresolved","message":"missing"}}
        ),
    );
    try std.testing.expectError(
        error.ProjectBindingAmbiguous,
        projectBindingFromResponse(std.testing.allocator,
            \\{"ok":false,"payload":{},"error":{"code":"project_binding_ambiguous","message":"ambiguous"}}
        ),
    );
}

test "payloadJsonFromResponse returns successful payload JSON" {
    const payload = try payloadJsonFromResponse(std.testing.allocator,
        \\{"ok":true,"payload":{"daemon_version":"dev","local_db":{"ready":true}},"error":null}
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"daemon_version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"local_db\"") != null);
}

test "payloadJsonFromResponse rejects failed daemon response" {
    try std.testing.expectError(
        error.DaemonIpcRejected,
        payloadJsonFromResponse(std.testing.allocator,
            \\{"ok":false,"payload":{},"error":{"code":"IPC_ERROR","message":"failed"}}
        ),
    );
}

test "operationResultFromResponse preserves daemon error code and message" {
    var result = try operationResultFromResponse(std.testing.allocator,
        \\{"ok":false,"payload":{},"error":{"code":"invalid_activation_state","message":"state is invalid"}}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.isError());
    try std.testing.expectEqualStrings("state is invalid", result.error_message.?);
    try std.testing.expect(std.mem.indexOf(u8, result.structured_json, "\"code\":\"invalid_activation_state\"") != null);
}

test "operationResultFromResponse keeps successful MCP payloads on one line" {
    var result = try operationResultFromResponse(std.testing.allocator,
        \\{"ok":true,"payload":{"fragments":[{"action":"add"}]},"error":null}
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.isError());
    try std.testing.expectEqualStrings(
        \\{"fragments":[{"action":"add"}]}
    , result.structured_json);
    try std.testing.expect(std.mem.indexOfScalar(u8, result.structured_json, '\n') == null);
}
