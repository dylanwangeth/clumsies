const std = @import("std");
const build_options = @import("build_options");

pub const MACH_SERVICE_NAME = "io.github.lilhammerfun.clumsies.agent";

const REQUEST_JSON_KEY = "request_json";
const RESPONSE_JSON_KEY = "response_json";
const enable_xpc = build_options.enable_xpc;

const EmptyPayload = struct {};

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
            ready: bool,
        },
        allocator,
        payload_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    if (!parsed.value.ready) return error.MemoryCacheNotReady;
    const root_path = parsed.value.root_path orelse return error.InvalidDaemonIpcResponse;
    return try allocator.dupe(u8, root_path);
}

pub fn memoryCacheRequestJsonAlloc(allocator: std.mem.Allocator, project_id: []const u8) ![]u8 {
    return requestWithPayloadJsonAlloc(allocator, "memory_cache", .{ .project_id = project_id });
}

pub fn callEmpty(allocator: std.mem.Allocator, service_name: []const u8, method: []const u8) ![]u8 {
    const request_json = try requestJsonAlloc(allocator, method);
    defer allocator.free(request_json);
    return try callJson(allocator, service_name, request_json);
}

pub fn requestJsonAlloc(allocator: std.mem.Allocator, method: []const u8) ![]u8 {
    return requestWithPayloadJsonAlloc(allocator, method, EmptyPayload{});
}

pub fn storeDraftOperationPayloadJson(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    resource: []const u8,
    op: std.json.Value,
) ![]u8 {
    const request_json = try storeDraftOperationRequestJsonAlloc(allocator, project_id, resource, op);
    defer allocator.free(request_json);

    const response_json = try callJson(allocator, MACH_SERVICE_NAME, request_json);
    defer allocator.free(response_json);

    return try payloadJsonFromResponse(allocator, response_json);
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

fn callJson(allocator: std.mem.Allocator, service_name: []const u8, request_json: []const u8) ![]u8 {
    if (comptime !enable_xpc) {
        return error.XpcUnavailable;
    } else {
        const service_name_z = try dupeZ(allocator, service_name);
        defer allocator.free(service_name_z);
        const request_json_z = try dupeZ(allocator, request_json);
        defer allocator.free(request_json_z);

        const connection = c.xpc_connection_create_mach_service(service_name_z.ptr, null, 0) orelse
            return error.XpcReturnedNullConnection;
        defer {
            c.xpc_connection_cancel(connection);
            c.xpc_release(connection);
        }
        c.xpc_connection_resume(connection);

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

    extern "c" fn xpc_connection_create_mach_service(
        name: [*:0]const u8,
        targetq: ?*anyopaque,
        flags: u64,
    ) ?*anyopaque;
    extern "c" fn xpc_connection_resume(connection: *anyopaque) void;
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
        \\{"create":{"path":"META_PROMPT.md","body":"body"}}
    ,
        .{},
    );
    defer parsed.deinit();

    const json = try storeDraftOperationRequestJsonAlloc(
        std.testing.allocator,
        "prj_test",
        "metaprompt",
        parsed.value,
    );
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"store_draft_operation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"project_id\":\"prj_test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scope\":\"project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resource\":\"metaprompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source\":\"mcp_store\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"META_PROMPT.md\"") != null);
}

test "memoryCacheRequestJsonAlloc builds daemon cache envelope" {
    const json = try memoryCacheRequestJsonAlloc(std.testing.allocator, "project_test");
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(
        \\{"method":"memory_cache","payload":{"project_id":"project_test"}}
    , json);
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
