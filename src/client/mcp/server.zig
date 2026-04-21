//! MCP protocol message loop. Reads JSON-RPC requests from stdin line by line, routes
//! initialize/tools-list/tools-call methods to handlers, and writes responses to stdout. This
//! is the core run loop through which the agent communicates.
const std = @import("std");
const testing = std.testing;
const encoding = @import("clumsies_lib").util.encoding;
const protocol = @import("jsonrpc.zig");
const session_mod = @import("session.zig");
const attestation_upload = @import("../attestation_upload.zig");
const tool_names = @import("tool_names.zig");
const tools = @import("tools.zig");

pub const State = struct {
    workspace_root: []const u8,
    session: *session_mod.Session,
    initialized: bool = false,
    initialize_seen: bool = false,
};

pub fn runWithRoot(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    allocator: std.mem.Allocator,
    version: []const u8,
    workspace_root: []const u8,
    session: *session_mod.Session,
) !void {
    _ = stderr;

    var state: State = .{
        .workspace_root = workspace_root,
        .session = session,
    };
    defer flushOnExit(allocator, &state);

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.Reader.init(std.fs.File.stdin(), &stdin_buffer);
    const reader = &stdin_reader.interface;

    while (true) {
        const raw_line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const response = processLine(allocator, &state, version, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try protocol.buildErrorAlloc(allocator, null, .internal_error, @errorName(err)),
        };
        defer if (response) |owned| allocator.free(owned);

        if (response) |owned| {
            try stdout.writeAll(owned);
            try stdout.flush();
        }
    }
}

fn flushOnExit(allocator: std.mem.Allocator, state: *State) void {
    const outcome = attestation_upload.flushWorkspace(allocator, state.session.ws_id);
    switch (outcome) {
        .flushed => |result| {
            if (result.events_sent > 0) {
                std.log.info(
                    "attestation flush on shutdown: sent {d} events in {d} batches",
                    .{ result.events_sent, result.batches_sent },
                );
            }
        },
        .not_authenticated => {},
        .failed => |err| std.log.warn("attestation flush on shutdown failed: {}", .{err}),
    }
}

pub fn processLine(allocator: std.mem.Allocator, state: *State, version: []const u8, line: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return try protocol.buildErrorAlloc(allocator, null, .parse_error, "Invalid JSON");
    };
    defer parsed.deinit();

    return processMessage(allocator, state, version, parsed.value);
}

fn processMessage(allocator: std.mem.Allocator, state: *State, version: []const u8, message: std.json.Value) !?[]u8 {
    const object = switch (message) {
        .object => |obj| obj,
        .array => return try protocol.buildErrorAlloc(allocator, null, .invalid_request, "Batch requests are not supported"),
        else => return try protocol.buildErrorAlloc(allocator, null, .invalid_request, "Expected JSON object"),
    };

    const method = if (object.get("method")) |value| switch (value) {
        .string => |s| s,
        else => return try protocol.buildErrorAlloc(allocator, null, .invalid_request, "Method must be a string"),
    } else return try protocol.buildErrorAlloc(allocator, null, .invalid_request, "Missing method");

    const id = object.get("id");
    const params = object.get("params") orelse std.json.Value{ .null = {} };

    if (id == null) {
        return handleNotification(state, method);
    }

    if (std.mem.eql(u8, method, "initialize")) {
        state.initialize_seen = true;
        const result = try buildInitializeResult(allocator, version);
        defer allocator.free(result);
        return try protocol.buildResultAlloc(allocator, id.?, result);
    }

    if (std.mem.eql(u8, method, "ping")) {
        return try protocol.buildResultAlloc(allocator, id.?, "{}");
    }

    if (!state.initialized) {
        return try protocol.buildErrorAlloc(allocator, id.?, .server_not_initialized, "Server not initialized");
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        const result = try tools.buildListResult(allocator);
        defer allocator.free(result);
        return try protocol.buildResultAlloc(allocator, id.?, result);
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const result = tools.handleCall(allocator, state.workspace_root, state.session, params) catch |err| switch (err) {
            error.InvalidParams => return try protocol.buildErrorAlloc(allocator, id.?, .invalid_params, "Invalid tool arguments"),
            else => return err,
        };
        defer allocator.free(result);
        return try protocol.buildResultAlloc(allocator, id.?, result);
    }

    return try protocol.buildErrorAlloc(allocator, id.?, .method_not_found, "Unknown method");
}

fn handleNotification(state: *State, method: []const u8) ?[]u8 {
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        state.initialized = true;
        return null;
    }
    return null;
}

fn buildInitializeResult(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const esc_version = try encoding.jsonEscapeAlloc(allocator, version);
    defer allocator.free(esc_version);

    const instructions =
        "Call " ++ tool_names.setup ++ " to bootstrap the protocol and get usage instructions, " ++
        tool_names.search ++ " to discover rules/workflows, " ++ tool_names.load ++ " to get content, " ++
        "and " ++ tool_names.refer ++ " to declare constraint usage.";
    const esc_instructions = try encoding.jsonEscapeAlloc(allocator, instructions);
    defer allocator.free(esc_instructions);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"clumsies\",\"version\":\"{s}\"}},\"instructions\":\"{s}\"}}",
        .{ protocol.PROTOCOL_VERSION, esc_version, esc_instructions },
    );
}

test "processLine: initialize then tools list" {
    var session: session_mod.Session = .{
        .ws_id = try testing.allocator.dupe(u8, "ws-test"),
        .session_id = [_]u8{'a'} ** 32,
    };
    defer session.deinit(testing.allocator);

    var state: State = .{
        .workspace_root = "/tmp/workspace",
        .session = &session,
    };

    const init_response = (try processLine(
        testing.allocator,
        &state,
        "0.16.3",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}",
    )).?;
    defer testing.allocator.free(init_response);
    try testing.expect(std.mem.indexOf(u8, init_response, "\"protocolVersion\":\"2025-06-18\"") != null);

    const initialized_response = try processLine(
        testing.allocator,
        &state,
        "0.16.3",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
    );
    try testing.expect(initialized_response == null);

    const tools_response = (try processLine(
        testing.allocator,
        &state,
        "0.16.3",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}",
    )).?;
    defer testing.allocator.free(tools_response);
    try testing.expect(std.mem.indexOf(u8, tools_response, "\"memory.setup\"") != null);
    try testing.expect(std.mem.indexOf(u8, tools_response, "\"memory.search\"") != null);
    try testing.expect(std.mem.indexOf(u8, tools_response, "\"memory.load\"") != null);
    try testing.expect(std.mem.indexOf(u8, tools_response, "\"memory.refer\"") != null);
}
