//! Registry and dispatcher for built-in coding-agent tools.
//!
//! Individual built-in tools own their definitions and implementations in
//! separate files. `Builtin` only adapts that tool set to the provider-neutral
//! `core.tool.Registry` and `core.tool.Invoker` ports used by the agent loop.

const std = @import("std");
const tool = @import("../core/tool.zig");
const bash = @import("bash.zig");
const catalog = @import("catalog.zig");
const discuss = @import("discuss.zig");
const edit = @import("edit.zig");
const read = @import("read.zig");
const search = @import("search.zig");
const tool_result = @import("result.zig");
const workspace = @import("workspace.zig");
const write = @import("write.zig");

const Builtin = @This();

workspace_path: []const u8 = ".",
max_read_bytes: usize = 64 * 1024,
max_matches: usize = 100,

/// Exposes built-in tool definitions through the core registry port.
///
/// The agent core only knows `tool.Registry`; this adapter keeps the concrete
/// built-in catalog outside `agent/core` while still letting providers declare
/// available tools before each request.
pub fn registry(self: *Builtin) tool.Registry {
    return .{
        .ctx = self,
        .lookup_fn = lookup,
        .list_fn = list,
    };
}

/// Exposes built-in tool execution through the core invoker port.
///
/// Each tool owns its implementation file. The invoker exists so the provider-
/// neutral runtime can execute resolved calls without importing every built-in
/// tool module directly.
pub fn invoker(self: *Builtin) tool.Invoker {
    return .{
        .ctx = self,
        .invoke_fn = invoke,
    };
}

/// Builds the provider-neutral runtime from the built-in registry and invoker.
///
/// CLI and future UI surfaces use this when they want the standard built-in
/// coding-tool set without manually wiring registry and invocation ports.
pub fn runtime(self: *Builtin) tool.Runtime {
    return .{
        .registry = self.registry(),
        .invoker = self.invoker(),
    };
}

/// Narrows runtime configuration to the workspace data individual tools need.
///
/// `Builtin` keeps registry and runtime configuration in one state object, but
/// tool implementations should receive only the workspace root and execution
/// bounds needed for file IO.
fn context(self: Builtin) workspace.Context {
    return .{
        .workspace_path = self.workspace_path,
        .max_read_bytes = self.max_read_bytes,
        .max_matches = self.max_matches,
    };
}

/// Resolves a provider-requested tool name into catalog metadata.
///
/// Execution lookup uses the same definition list as provider request
/// declaration so schema, scheduling, and side-effect metadata cannot drift.
fn lookup(ctx: *anyopaque, name: []const u8) !?tool.Definition {
    _ = ctx;
    for (catalog.DEFINITIONS) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return definition;
    }
    return null;
}

/// Lists built-in definitions for provider request construction.
///
/// Provider adapters call this before each model request to declare the tools
/// currently available to the model.
fn list(ctx: *anyopaque) ![]const tool.Definition {
    _ = ctx;
    return &catalog.DEFINITIONS;
}

/// Dispatches a resolved built-in tool call to its implementation module.
///
/// The core runtime has already resolved the call name to `definition`; this
/// function uses that canonical definition to pick the implementation, keeping
/// raw provider call names out of the dispatch decision.
fn invoke(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    call: tool.Call,
    definition: tool.Definition,
) !tool.Result {
    const self: *Builtin = @ptrCast(@alignCast(ctx));
    const tool_context = self.context();

    // Dispatch by the resolved definition name, not by the raw call name. The
    // registry already validated the call and supplied the canonical tool
    // metadata used for scheduling and provider declarations.
    if (std.mem.eql(u8, definition.name, read.DEFINITION.name)) {
        return read.invoke(allocator, tool_context, call.arguments);
    }
    if (std.mem.eql(u8, definition.name, search.DEFINITION.name)) {
        return search.invoke(allocator, tool_context, call.arguments);
    }
    if (std.mem.eql(u8, definition.name, discuss.DEFINITION.name)) return discuss.invoke(allocator);
    if (std.mem.eql(u8, definition.name, edit.DEFINITION.name)) {
        return edit.invoke(allocator, tool_context, call.arguments);
    }
    if (std.mem.eql(u8, definition.name, write.DEFINITION.name)) {
        return write.invoke(allocator, tool_context, call.arguments);
    }
    if (std.mem.eql(u8, definition.name, bash.DEFINITION.name)) return bash.invoke(allocator);
    return tool_result.fail(
        allocator,
        "not_implemented",
        "built-in tool definition has no dispatcher implementation",
    );
}

const testing = std.testing;

test "built-in registry exposes catalog definitions" {
    var builtins: Builtin = .{};
    const definitions = try builtins.registry().list();

    try testing.expectEqual(catalog.DEFINITIONS.len, definitions.len);
    try testing.expectEqualStrings("Discuss", definitions[0].name);
}

test "built-in registry resolves known and unknown tools" {
    var builtins: Builtin = .{};
    const tool_registry = builtins.registry();

    const read_definition = try tool_registry.lookup("Read");
    try testing.expect(read_definition != null);
    try testing.expectEqualStrings("Read", read_definition.?.name);

    const missing = try tool_registry.lookup("Missing");
    try testing.expect(missing == null);
}

test "built-in runtime dispatches read-only tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "const std = @import(\"std\");\n",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var builtins: Builtin = .{ .workspace_path = try tmp.dir.realpath(".", &path_buf) };
    var tool_runtime = builtins.runtime();
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "Read", .arguments = "{\"path\":\"main.zig\"}" },
        .{ .id = "call_2", .name = "Search", .arguments = "{\"target\":\"content\",\"query\":\"std\",\"glob\":\"*.zig\"}" },
    };

    const results = try tool_runtime.executeBatch(testing.allocator, &calls);
    defer deinitResults(testing.allocator, results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expect(!results[0].is_error);
    try testing.expect(std.mem.indexOf(u8, results[0].content, "file: main.zig") != null);
    try testing.expect(!results[1].is_error);
    try testing.expect(std.mem.indexOf(u8, results[1].content, "main.zig:1:") != null);
}

test "built-in Discuss skeleton stops the run for user interaction" {
    var builtins: Builtin = .{};
    var tool_runtime = builtins.runtime();
    const calls = [_]tool.Call{
        .{ .id = "call_1", .name = "Discuss", .arguments = "{\"message\":\"Need confirmation\"}" },
    };

    const results = try tool_runtime.executeBatch(testing.allocator, &calls);
    defer deinitResults(testing.allocator, results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expect(results[0].is_error);
    try testing.expectEqual(tool.Control.stop_run, results[0].control);
}

/// Releases test-owned result slices returned by `tool.Runtime`.
///
/// Production callers do this in the agent loop; these tests need the same
/// cleanup because read-only built-in tools can return owned output buffers.
fn deinitResults(allocator: std.mem.Allocator, results: []tool.Result) void {
    for (results) |result| result.deinit(allocator);
    allocator.free(results);
}
