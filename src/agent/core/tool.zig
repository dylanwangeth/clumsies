//! Tool-call types and local execution runtime for the agent loop.
//!
//! This module defines the provider-neutral tool boundary. Providers produce
//! normalized `Call` values, the runtime resolves them through a registry,
//! invokes local implementations, and returns one `Result` per call. Provider
//! adapters separately translate `Definition` values into their request-level
//! tool schema format.

const std = @import("std");

/// A provider-normalized request to invoke one local tool.
pub const Call = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8 = "",
};

/// Result of one local tool invocation.
///
/// This is not a provider transcript message yet. The agent loop combines a
/// `Call.id` with this result to produce `transcript.ToolResultMessage`, which
/// provider adapters then serialize as request-side tool messages.
///
/// `owns_content` marks content allocated by the invoker with the same
/// allocator passed to `invoke`. The agent loop copies the content into the
/// transcript before calling `deinit`.
pub const Result = struct {
    content: []const u8,
    owns_content: bool = false,
    is_error: bool = false,
    control: Control = .continue_run,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        if (self.owns_content) allocator.free(self.content);
    }
};

/// Runtime control signal carried by a tool result.
///
/// This is separate from `Result.is_error`. A tool error is model-visible data:
/// the result is appended to the transcript and the provider can recover in the
/// next turn. `.stop_run` is a control-plane signal: after the runtime records
/// the current assistant turn's full tool-result batch, it stops the run instead
/// of asking the provider for another turn.
///
/// For example, a failed grep or test command should usually be returned as
/// `Result{ .is_error = true, .control = .continue_run }` so the model can
/// react. A user cancellation, safety stop, or approval denial that must halt
/// the agent should use `.stop_run`.
pub const Control = enum {
    continue_run,
    stop_run,
};

/// Static runtime and provider-declaration metadata for one registered tool.
///
/// `parameters_schema` is raw JSON Schema so the registry stays independent of
/// any one provider's structs. Provider adapters parse and embed it in their
/// own wire format when they declare available tools.
pub const Definition = struct {
    name: []const u8,
    description: []const u8 = "",
    parameters_schema: []const u8 =
        \\{"type":"object","properties":{}}
    ,
    kind: Kind = .extension,
    scheduling: Scheduling = .parallel,
    effects: Effects = .{},
    failure_policy: FailurePolicy = .collect_all,
};

/// Runtime-facing tool category used by policy and UI layers.
///
/// Tool kinds do not create execution layers: every tool is still registered
/// and invoked through the same flat runtime. The kind only explains what sort
/// of action is being requested.
pub const Kind = enum {
    interaction,
    observe,
    mutate,
    command,
    extension,
};

/// Whether calls to this tool can share an execution segment with other work.
pub const Scheduling = enum {
    parallel,
    serial,
};

/// Side-effect metadata used by registries, executors, dashboards, and policy UIs.
///
/// The core runtime does not enforce these flags. A caller that needs
/// permission prompts should expose only currently allowed tools through its
/// registry, or later add an explicit pause/resume approval flow.
pub const Effects = struct {
    reads_workspace: bool = false,
    writes_workspace: bool = false,
    external_side_effect: bool = false,
};

/// How a model-visible failure should affect later calls in the same batch.
pub const FailurePolicy = enum {
    collect_all,
    stop_on_error,
};

/// Tool definition lookup boundary shared by the runtime and future UIs.
///
/// `lookup` serves execution after the model requests a tool by name. `list`
/// serves provider request construction before each model call, where adapters
/// need the currently available tool definitions for `tools[]`.
pub const Registry = struct {
    ctx: *anyopaque,
    lookup_fn: *const fn (
        ctx: *anyopaque,
        name: []const u8,
    ) anyerror!?Definition,
    list_fn: *const fn (ctx: *anyopaque) anyerror![]const Definition,

    pub fn lookup(self: Registry, name: []const u8) anyerror!?Definition {
        return self.lookup_fn(self.ctx, name);
    }

    pub fn list(self: Registry) anyerror![]const Definition {
        return self.list_fn(self.ctx);
    }
};

/// Concrete invocation boundary used by `Runtime`.
pub const Invoker = struct {
    ctx: *anyopaque,
    invoke_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        call: Call,
        definition: Definition,
    ) anyerror!Result,

    pub fn invoke(
        self: Invoker,
        allocator: std.mem.Allocator,
        call: Call,
        definition: Definition,
    ) anyerror!Result {
        return self.invoke_fn(self.ctx, allocator, call, definition);
    }
};

/// How the runtime handles a model request for an unregistered tool.
pub const UnknownToolPolicy = enum {
    return_error_result,
    fail_batch,
};

/// Registry-backed runtime for local tools.
///
/// `Runtime` is deliberately provider-neutral. It consumes normalized tool
/// calls and returns normalized results; the agent loop and provider adapters
/// handle transcript and JSON-message conversion.
pub const Runtime = struct {
    registry: Registry,
    invoker: Invoker,
    unknown_tool_policy: UnknownToolPolicy = .return_error_result,

    /// Returns tool definitions currently exposed to provider requests.
    pub fn definitions(self: *Runtime) anyerror![]const Definition {
        return self.registry.list();
    }

    /// Executes one assistant-requested tool batch.
    ///
    /// The returned slice has exactly one `Result` per input `Call`, in the
    /// same order. The agent loop relies on that invariant to attach provider
    /// call ids when it builds tool-result messages.
    pub fn executeBatch(
        self: *Runtime,
        allocator: std.mem.Allocator,
        calls: []const Call,
    ) anyerror![]Result {
        const resolved = try self.resolveBatch(allocator, calls);
        defer allocator.free(resolved);

        const results = try allocator.alloc(Result, calls.len);
        errdefer allocator.free(results);

        var index: usize = 0;
        while (index < resolved.len) {
            // Serial calls are execution boundaries. A stop_on_error failure
            // here prevents later calls from running.
            if (resolved[index].scheduling() == .serial) {
                const should_stop = try self.executeOne(
                    allocator,
                    resolved[index],
                    &results[index],
                );
                index += 1;
                if (should_stop) {
                    fillSkipped(results[index..]);
                    break;
                }
                continue;
            }

            // Consecutive parallel-capable calls form one deterministic
            // segment. The current runtime still executes them in order, but a
            // future concurrent executor can run this segment in parallel while
            // preserving result order.
            const segment_start = index;
            while (index < resolved.len and resolved[index].scheduling() == .parallel) {
                index += 1;
            }

            const should_stop = try self.executeParallelCapableSegment(
                allocator,
                resolved[segment_start..index],
                results[segment_start..index],
            );
            if (should_stop) {
                // The segment has completed, so every requested call up to
                // `index` has a result. Later calls are skipped to preserve the
                // provider invariant: one result per original tool call.
                fillSkipped(results[index..]);
                break;
            }
        }

        return results;
    }

    /// Resolves every provider-requested call before any tool can run.
    ///
    /// That keeps lookup errors and unknown-tool policy decisions separate
    /// from execution side effects; after this function returns, the runtime
    /// only walks already-classified calls.
    fn resolveBatch(
        self: *Runtime,
        allocator: std.mem.Allocator,
        calls: []const Call,
    ) anyerror![]ResolvedCall {
        const resolved = try allocator.alloc(ResolvedCall, calls.len);
        errdefer allocator.free(resolved);

        for (calls, resolved) |call, *item| {
            item.* = try self.resolveCall(call);
        }
        return resolved;
    }

    /// Converts one raw provider call into executable runtime type-state.
    ///
    /// A resolved call is either executable with a concrete definition or a
    /// model-visible unavailable result. Keeping this decision here avoids
    /// re-looking-up metadata while tools are being invoked.
    fn resolveCall(self: *Runtime, call: Call) anyerror!ResolvedCall {
        if (try self.registry.lookup(call.name)) |definition| {
            return .{ .call = call, .action = .{ .invoke = definition } };
        }

        return switch (self.unknown_tool_policy) {
            .return_error_result => .{
                .call = call,
                .action = .{ .unavailable = .unknown_tool },
            },
            .fail_batch => error.UnknownTool,
        };
    }

    /// Executes one segment whose calls are all parallel-capable.
    ///
    /// The current implementation is deterministic and sequential. The segment
    /// boundary exists so a future executor can run this group concurrently
    /// while still returning results in assistant call order.
    fn executeParallelCapableSegment(
        self: *Runtime,
        allocator: std.mem.Allocator,
        calls: []const ResolvedCall,
        results: []Result,
    ) anyerror!bool {
        var should_stop_after_segment = false;
        for (calls, results) |call, *result| {
            if (try self.executeOne(allocator, call, result)) {
                should_stop_after_segment = true;
            }
        }
        return should_stop_after_segment;
    }

    /// Executes or materializes one resolved call result.
    ///
    /// Tool invocation errors become model-visible results. Returning an error
    /// from `executeBatch` is reserved for runtime failures such as registry or
    /// allocation failures.
    fn executeOne(
        self: *Runtime,
        allocator: std.mem.Allocator,
        resolved: ResolvedCall,
        result: *Result,
    ) anyerror!bool {
        switch (resolved.action) {
            .invoke => |definition| {
                result.* = self.invoker.invoke(allocator, resolved.call, definition) catch |err| .{
                    .content = @errorName(err),
                    .is_error = true,
                };
                return definition.failure_policy == .stop_on_error and result.is_error;
            },
            .unavailable => |reason| {
                result.* = unavailableResult(reason);
                return false;
            },
        }
    }

    /// Converts a non-executable resolved call into a model-visible result.
    ///
    /// Unknown or unavailable tools still need a result slot so provider
    /// `tool_call_id` ordering remains valid.
    fn unavailableResult(reason: UnavailableReason) Result {
        return switch (reason) {
            .unknown_tool => .{
                .content = "unknown tool",
                .is_error = true,
            },
        };
    }

    /// Fills unexecuted result slots after `stop_on_error` halts the batch.
    ///
    /// The runtime preserves one result per original call even when later calls
    /// are skipped, because provider APIs require every tool call to receive a
    /// corresponding tool-result message.
    fn fillSkipped(results: []Result) void {
        for (results) |*result| {
            result.* = .{
                .content = "skipped after tool failure",
                .is_error = true,
            };
        }
    }
};

const ResolvedCall = struct {
    call: Call,
    action: Action,

    /// Private type-state for runtime execution.
    ///
    /// Public API stays at `Call` and `Result`; this only prevents the executor
    /// from re-looking-up tool metadata after calls have been resolved.
    const Action = union(enum) {
        invoke: Definition,
        unavailable: UnavailableReason,
    };

    /// Returns execution scheduling for the resolved action.
    ///
    /// Unavailable calls are treated as parallel because they only materialize
    /// local error results and have no side effects.
    fn scheduling(self: ResolvedCall) Scheduling {
        return switch (self.action) {
            .invoke => |definition| definition.scheduling,
            .unavailable => .parallel,
        };
    }
};

const UnavailableReason = enum {
    unknown_tool,
};

const testing = std.testing;

test "tool runtime invokes registered tools" {
    const definitions = [_]Definition{
        .{ .name = "read" },
        .{ .name = "grep" },
    };
    const calls = [_]Call{
        .{ .id = "call_1", .name = "read" },
        .{ .id = "call_2", .name = "grep" },
    };
    var registry_state: TestRegistry = .{ .definitions = &definitions };
    var invoker_state: TestInvoker = .{};
    var runtime: Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };

    const results = try runtime.executeBatch(testing.allocator, &calls);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("read", results[0].content);
    try testing.expectEqualStrings("grep", results[1].content);
    try testing.expectEqual(@as(usize, 2), registry_state.lookups);
    try testing.expectEqual(@as(usize, 2), invoker_state.calls);
}

test "tool runtime returns model-visible result for unknown tools by default" {
    const calls = [_]Call{
        .{ .id = "call_1", .name = "missing" },
    };
    var registry_state: TestRegistry = .{ .definitions = &.{} };
    var invoker_state: TestInvoker = .{};
    var runtime: Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };

    const results = try runtime.executeBatch(testing.allocator, &calls);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expect(results[0].is_error);
    try testing.expectEqualStrings("unknown tool", results[0].content);
    try testing.expectEqual(@as(usize, 0), invoker_state.calls);
}

test "tool runtime can fail batch on unknown tools" {
    const calls = [_]Call{
        .{ .id = "call_1", .name = "missing" },
    };
    var registry_state: TestRegistry = .{ .definitions = &.{} };
    var invoker_state: TestInvoker = .{};
    var runtime: Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
        .unknown_tool_policy = .fail_batch,
    };

    try testing.expectError(error.UnknownTool, runtime.executeBatch(testing.allocator, &calls));
}

test "tool runtime stops later calls after serial stop_on_error failure" {
    const definitions = [_]Definition{
        .{ .name = "fail", .scheduling = .serial, .failure_policy = .stop_on_error },
        .{ .name = "later", .scheduling = .serial },
    };
    const calls = [_]Call{
        .{ .id = "call_1", .name = "fail" },
        .{ .id = "call_2", .name = "later" },
    };
    var registry_state: TestRegistry = .{ .definitions = &definitions };
    var invoker_state: TestInvoker = .{ .fail_name = "fail" };
    var runtime: Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };

    const results = try runtime.executeBatch(testing.allocator, &calls);
    defer testing.allocator.free(results);

    try testing.expect(results[0].is_error);
    try testing.expect(results[1].is_error);
    try testing.expectEqualStrings("skipped after tool failure", results[1].content);
    try testing.expectEqual(@as(usize, 1), invoker_state.calls);
}

test "tool runtime completes parallel-capable segment before stop_on_error takes effect" {
    const definitions = [_]Definition{
        .{ .name = "fail", .scheduling = .parallel, .failure_policy = .stop_on_error },
        .{ .name = "peer", .scheduling = .parallel },
        .{ .name = "later", .scheduling = .serial },
    };
    const calls = [_]Call{
        .{ .id = "call_1", .name = "fail" },
        .{ .id = "call_2", .name = "peer" },
        .{ .id = "call_3", .name = "later" },
    };
    var registry_state: TestRegistry = .{ .definitions = &definitions };
    var invoker_state: TestInvoker = .{ .fail_name = "fail" };
    var runtime: Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };

    const results = try runtime.executeBatch(testing.allocator, &calls);
    defer testing.allocator.free(results);

    try testing.expect(results[0].is_error);
    try testing.expect(!results[1].is_error);
    try testing.expect(results[2].is_error);
    try testing.expectEqualStrings("peer", results[1].content);
    try testing.expectEqualStrings("skipped after tool failure", results[2].content);
    try testing.expectEqual(@as(usize, 2), invoker_state.calls);
}

test "tool runtime resolves calls once in input order" {
    const definitions = [_]Definition{
        .{ .name = "read", .scheduling = .parallel },
        .{ .name = "edit", .scheduling = .serial },
    };
    const calls = [_]Call{
        .{ .id = "call_1", .name = "read" },
        .{ .id = "call_2", .name = "edit" },
        .{ .id = "call_3", .name = "missing" },
    };
    var registry_state: TestRegistry = .{ .definitions = &definitions };

    var invoker_state: TestInvoker = .{};
    var runtime: Runtime = .{
        .registry = registry_state.registry(),
        .invoker = invoker_state.invoker(),
    };

    const resolved = try runtime.resolveBatch(testing.allocator, &calls);
    defer testing.allocator.free(resolved);

    try testing.expectEqual(@as(usize, 3), resolved.len);
    try testing.expectEqual(@as(usize, 3), registry_state.lookups);
    try testing.expectEqual(ResolvedCall.Action.invoke, std.meta.activeTag(resolved[0].action));
    try testing.expectEqual(ResolvedCall.Action.invoke, std.meta.activeTag(resolved[1].action));
    try testing.expectEqual(ResolvedCall.Action.unavailable, std.meta.activeTag(resolved[2].action));
    try testing.expectEqual(Scheduling.parallel, resolved[0].scheduling());
    try testing.expectEqual(Scheduling.serial, resolved[1].scheduling());
}

const TestRegistry = struct {
    definitions: []const Definition,
    lookups: usize = 0,

    fn registry(self: *TestRegistry) Registry {
        return .{ .ctx = self, .lookup_fn = lookup, .list_fn = list };
    }

    fn lookup(ctx: *anyopaque, name: []const u8) !?Definition {
        const self: *TestRegistry = @ptrCast(@alignCast(ctx));
        self.lookups += 1;
        for (self.definitions) |definition| {
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }

    fn list(ctx: *anyopaque) ![]const Definition {
        const self: *TestRegistry = @ptrCast(@alignCast(ctx));
        return self.definitions;
    }
};

const TestInvoker = struct {
    calls: usize = 0,
    fail_name: []const u8 = "",

    fn invoker(self: *TestInvoker) Invoker {
        return .{ .ctx = self, .invoke_fn = invoke };
    }

    fn invoke(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        call: Call,
        definition: Definition,
    ) !Result {
        _ = allocator;
        _ = definition;
        const self: *TestInvoker = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return .{
            .content = call.name,
            .is_error = std.mem.eql(u8, call.name, self.fail_name),
        };
    }
};
