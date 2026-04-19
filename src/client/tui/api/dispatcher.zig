//! Declarative endpoint runtime. Each endpoint is described by a
//! `RequestSpec(ReqT, RespT)` — method, path builder, optional body
//! builder, and a response parser. The `dispatch` entry point takes a
//! spec, a target `PendingRequest(Result(RespT))`, and a request payload,
//! spawns a worker thread that performs the HTTP call, classifies the
//! response, and calls `pending.complete(gen, result)`.
//!
//! This module replaces the per-endpoint copy-paste pattern in the old
//! fetch.zig (mutex + busy check + param dupe + thread spawn + HTTP call
//! + parse + writeback + mutex + busy reset, hand-written ~40 lines per
//! endpoint) with one shared runtime that every endpoint reuses.
//!
//! Thread ownership is delegated to `ThreadRegistry`, which `main.zig`
//! joins on exit so the TUI never leaves a fetch thread detached when
//! the process tears down.

const std = @import("std");
const HubClient = @import("../../hub_client.zig").HubClient;
const api_error = @import("clumsies_lib").protocol.api_error;
const request = @import("request.zig");

pub const Result = request.Result;
pub const ApiErrorPayload = request.ApiErrorPayload;
pub const PendingRequest = request.PendingRequest;

/// Declarative description of a single Hub endpoint.
///
/// `ReqT` is the input shape a caller hands to `dispatch`. `RespT` is the
/// deserialized success type. For write endpoints that do not need a
/// parsed response (sign out, accept/reject), use `RespT = void` and
/// provide `parse_ok = parseVoid`.
pub fn RequestSpec(comptime ReqT: type, comptime RespT: type) type {
    return struct {
        method: std.http.Method,

        /// Build the URL path (and optional query string) for the request.
        /// The returned slice must be allocated through `alloc`; the
        /// dispatcher frees it before the worker exits.
        path_builder: *const fn (alloc: std.mem.Allocator, req: ReqT) anyerror![]const u8,

        /// Build the request body. Must be `null` for GET / DELETE; must
        /// be non-null for POST / PUT / PATCH. The returned slice is freed
        /// by the dispatcher.
        body_builder: ?*const fn (alloc: std.mem.Allocator, req: ReqT) anyerror![]const u8 = null,

        /// Parse a 2xx response body into `RespT`. The returned value and
        /// any owned strings must live in `alloc`. `req` is the request
        /// payload the dispatcher used to fetch this body; parsers may
        /// dupe fields out of it into `alloc` to produce a response
        /// shape that carries the request key, letting the consumer
        /// route cache writes against the request rather than the
        /// caller's current UI state.
        parse_ok: *const fn (alloc: std.mem.Allocator, req: ReqT, body: []const u8) anyerror!RespT,
    };
}

/// Accumulator for spawned worker threads so the TUI exit path can wait
/// for every in-flight request before tearing down the allocator.
pub const ThreadRegistry = struct {
    mutex: std.Thread.Mutex = .{},
    active: std.ArrayList(std.Thread) = .empty,

    pub fn register(self: *ThreadRegistry, thread: std.Thread, alloc: std.mem.Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.active.append(alloc, thread);
    }

    /// Block until every registered thread completes, then drop their
    /// handles. Safe to call at process exit. Swaps the active list into
    /// a local under the lock before joining so a concurrent `register`
    /// can neither invalidate the slice being iterated nor append a
    /// thread that silently escapes the join.
    pub fn joinAll(self: *ThreadRegistry, alloc: std.mem.Allocator) void {
        while (true) {
            self.mutex.lock();
            var batch = self.active;
            self.active = .empty;
            self.mutex.unlock();

            if (batch.items.len == 0) {
                batch.deinit(alloc);
                return;
            }

            for (batch.items) |t| t.join();
            batch.deinit(alloc);
        }
    }
};

/// Runtime context carried from the caller into the worker thread. The
/// caller hands the dispatcher a spec + pending slot + request payload;
/// the dispatcher copies the payload into `transient_parent` (so the
/// worker is free of UI-thread references) and stores the generation it
/// received from `pending.tryBegin`.
///
/// Two allocators travel on the context because they have different
/// lifetimes:
///
/// * `transient_parent` is a stable, thread-safe heap allocator (the
///   caller's backing GPA). It owns the tiny persistent state the caller
///   hands across the thread boundary — this struct, the url and token
///   dupes, and the deep-copied request. The worker frees them at exit.
///   The worker also creates a per-request `ArenaAllocator` from it to
///   back path/body/HubClient allocations that live for one request.
/// * `result_alloc` is the long-lived arena shared with the UI.
///   `spec.parse_ok` and `parseApiError` write into it so parsed values
///   and api_error strings outlive the worker and land in caches.
fn WorkerContext(comptime ReqT: type, comptime RespT: type) type {
    return struct {
        spec: RequestSpec(ReqT, RespT),
        pending: *PendingRequest(Result(RespT)),
        req: ReqT,
        generation: u64,
        hub_url: []const u8,
        access_token: []const u8,
        transient_parent: std.mem.Allocator,
        result_alloc: std.mem.Allocator,
    };
}

/// Dispatch a request for the given spec. Returns immediately after
/// spawning the worker (or synchronously landing `network_error` on the
/// pending slot if the slot was already busy or spawn failed).
///
/// The caller retains `req`; if `ReqT` contains slices, they must remain
/// valid until `dispatch` returns. The dispatcher deep-copies the payload
/// into `transient_parent` before handing it to the worker thread.
pub fn dispatch(
    comptime ReqT: type,
    comptime RespT: type,
    spec: RequestSpec(ReqT, RespT),
    pending: *PendingRequest(Result(RespT)),
    registry: *ThreadRegistry,
    registry_alloc: std.mem.Allocator,
    hub_url: []const u8,
    access_token: []const u8,
    transient_parent: std.mem.Allocator,
    result_alloc: std.mem.Allocator,
    req: ReqT,
) void {
    const gen = pending.tryBegin() orelse return;

    const req_copy = deepCopy(ReqT, transient_parent, req) catch {
        pending.complete(gen, .network_error);
        return;
    };
    const url_copy = transient_parent.dupe(u8, hub_url) catch {
        freeDeepCopy(ReqT, transient_parent, req_copy);
        pending.complete(gen, .network_error);
        return;
    };
    const token_copy = transient_parent.dupe(u8, access_token) catch {
        transient_parent.free(url_copy);
        freeDeepCopy(ReqT, transient_parent, req_copy);
        pending.complete(gen, .network_error);
        return;
    };

    const Ctx = WorkerContext(ReqT, RespT);
    const ctx_ptr = transient_parent.create(Ctx) catch {
        transient_parent.free(token_copy);
        transient_parent.free(url_copy);
        freeDeepCopy(ReqT, transient_parent, req_copy);
        pending.complete(gen, .network_error);
        return;
    };
    ctx_ptr.* = .{
        .spec = spec,
        .pending = pending,
        .req = req_copy,
        .generation = gen,
        .hub_url = url_copy,
        .access_token = token_copy,
        .transient_parent = transient_parent,
        .result_alloc = result_alloc,
    };

    const thread = std.Thread.spawn(.{}, runWorker(ReqT, RespT), .{ctx_ptr}) catch {
        transient_parent.destroy(ctx_ptr);
        transient_parent.free(token_copy);
        transient_parent.free(url_copy);
        freeDeepCopy(ReqT, transient_parent, req_copy);
        pending.complete(gen, .network_error);
        return;
    };

    registry.register(thread, registry_alloc) catch {
        // Registration failure does not abort the request — the thread
        // is already running. We just will not be able to join it at
        // exit, which matches the pre-refactor behavior.
    };
}

fn runWorker(comptime ReqT: type, comptime RespT: type) fn (ctx: *WorkerContext(ReqT, RespT)) void {
    return struct {
        fn run(ctx: *WorkerContext(ReqT, RespT)) void {
            const transient_parent = ctx.transient_parent;
            const result_alloc = ctx.result_alloc;

            defer transient_parent.destroy(ctx);
            defer transient_parent.free(ctx.access_token);
            defer transient_parent.free(ctx.hub_url);
            defer freeDeepCopy(ReqT, transient_parent, ctx.req);

            // Per-request arena for path, body, HubClient response
            // buffers, and any other single-request scratch. Deinit at
            // end of worker so these do not accumulate in the long-lived
            // UI arena.
            var arena = std.heap.ArenaAllocator.init(transient_parent);
            defer arena.deinit();
            const t_alloc = arena.allocator();

            const path = ctx.spec.path_builder(t_alloc, ctx.req) catch {
                ctx.pending.complete(ctx.generation, .network_error);
                return;
            };

            const body: ?[]const u8 = if (ctx.spec.body_builder) |build_body|
                build_body(t_alloc, ctx.req) catch {
                    ctx.pending.complete(ctx.generation, .network_error);
                    return;
                }
            else
                null;

            var client = HubClient.init(t_alloc, ctx.hub_url, ctx.access_token);
            const resp = switch (ctx.spec.method) {
                .GET => client.get(path),
                .POST => client.post(path, body orelse "{}"),
                .PUT => client.put(path, body orelse "{}"),
                .PATCH => client.patch(path, body orelse "{}"),
                .DELETE => client.delete(path),
                else => unreachable,
            } catch {
                ctx.pending.complete(ctx.generation, .network_error);
                return;
            };
            defer resp.deinit();

            const result = classifyResponse(ReqT, RespT, ctx.spec, result_alloc, ctx.req, resp.status, resp.body);
            ctx.pending.complete(ctx.generation, result);
        }
    }.run;
}

/// Translate an HTTP response into the uniform `Result(RespT)` shape.
///
/// 2xx goes through `spec.parse_ok`. A parse failure becomes
/// `invalid_response` (body was 2xx but malformed, which should not
/// happen in practice and indicates a Hub contract regression).
///
/// Non-2xx tries to decode the shared `ApiErrorEnvelope`. If the body is
/// not valid JSON or missing the envelope, synthesize an `api_error`
/// with `code = "UNKNOWN"` and `message = body` so the UI still has
/// something to show.
pub fn classifyResponse(
    comptime ReqT: type,
    comptime RespT: type,
    spec: anytype,
    alloc: std.mem.Allocator,
    req: ReqT,
    status: std.http.Status,
    body: []const u8,
) Result(RespT) {
    switch (status) {
        .ok, .created, .no_content => {
            const value = spec.parse_ok(alloc, req, body) catch return .invalid_response;
            return .{ .ok = value };
        },
        else => return parseApiError(RespT, alloc, status, body),
    }
}

fn parseApiError(
    comptime RespT: type,
    alloc: std.mem.Allocator,
    status: std.http.Status,
    body: []const u8,
) Result(RespT) {
    const parsed = std.json.parseFromSlice(
        api_error.ApiErrorEnvelope,
        alloc,
        body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const code = alloc.dupe(u8, "UNKNOWN") catch return .invalid_response;
        const message = alloc.dupe(u8, body) catch return .invalid_response;
        return .{ .api_error = .{ .status = status, .code = code, .message = message } };
    };
    defer parsed.deinit();

    const code = alloc.dupe(u8, parsed.value.@"error".code) catch return .invalid_response;
    const message = alloc.dupe(u8, parsed.value.@"error".message) catch return .invalid_response;
    return .{ .api_error = .{ .status = status, .code = code, .message = message } };
}

/// Deep-copy a request payload so the worker thread is independent of
/// caller-owned slice memory. Structs are copied field by field; slices
/// of `u8` (and nullable versions) are duplicated into `alloc`. Other
/// types are copied by value.
fn deepCopy(comptime T: type, alloc: std.mem.Allocator, value: T) !T {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            var out: T = value;
            inline for (info.fields) |f| {
                @field(out, f.name) = try deepCopyField(f.type, alloc, @field(value, f.name));
            }
            break :blk out;
        },
        else => value,
    };
}

fn deepCopyField(comptime T: type, alloc: std.mem.Allocator, value: T) !T {
    if (T == []const u8) return alloc.dupe(u8, value);
    if (T == ?[]const u8) return if (value) |v| try alloc.dupe(u8, v) else null;
    return value;
}

fn freeDeepCopy(comptime T: type, alloc: std.mem.Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |f| {
                freeDeepCopyField(f.type, alloc, @field(value, f.name));
            }
        },
        else => {},
    }
}

fn freeDeepCopyField(comptime T: type, alloc: std.mem.Allocator, value: T) void {
    if (T == []const u8) alloc.free(value);
    if (T == ?[]const u8) {
        if (value) |v| alloc.free(v);
    }
}

/// Path builder that returns a fixed string. Useful for endpoints that
/// take no parameters, e.g. `POST /api/workspaces`. Specialize on the
/// concrete request type so the returned function pointer matches
/// `RequestSpec(ReqT, _).path_builder` exactly.
pub fn staticPath(comptime ReqT: type, comptime path: []const u8) *const fn (std.mem.Allocator, ReqT) anyerror![]const u8 {
    return struct {
        fn build(alloc: std.mem.Allocator, req: ReqT) anyerror![]const u8 {
            _ = req;
            return alloc.dupe(u8, path);
        }
    }.build;
}

/// Body builder that JSON-serializes the request struct with
/// `emit_null_optional_fields = false` so optional fields are omitted
/// from the wire payload.
pub fn jsonBody(comptime T: type) *const fn (std.mem.Allocator, T) anyerror![]const u8 {
    return struct {
        fn build(alloc: std.mem.Allocator, req: T) anyerror![]const u8 {
            return std.json.Stringify.valueAlloc(alloc, req, .{ .emit_null_optional_fields = false });
        }
    }.build;
}

/// Response parser that deserializes the JSON body into `T`, ignoring
/// unknown fields for forward-compat. Uses `parseFromSliceLeaky` so the
/// parsed value's allocations land directly in `alloc` without a
/// `Parsed` wrapper arena that would otherwise leak on every call.
/// Ignores `req` — use this for endpoints where the response body
/// already carries the request key the consumer needs.
pub fn jsonParser(comptime ReqT: type, comptime T: type) *const fn (std.mem.Allocator, ReqT, []const u8) anyerror!T {
    return struct {
        fn parse(alloc: std.mem.Allocator, req: ReqT, body: []const u8) anyerror!T {
            _ = req;
            return std.json.parseFromSliceLeaky(
                T,
                alloc,
                body,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
            );
        }
    }.parse;
}

/// Placeholder parser for endpoints whose success response carries no
/// body (204 No Content or 2xx with a body the caller does not need).
pub fn parseVoid(comptime ReqT: type) *const fn (std.mem.Allocator, ReqT, []const u8) anyerror!void {
    return struct {
        fn parse(alloc: std.mem.Allocator, req: ReqT, body: []const u8) anyerror!void {
            _ = alloc;
            _ = req;
            _ = body;
        }
    }.parse;
}

/// Parser for endpoints whose success body is a raw string (no JSON
/// envelope). Ignores `req`; consumers that need to route the body
/// against a request key should use a custom parser that wraps the
/// body with the relevant request fields.
pub fn parseRawString(comptime ReqT: type) *const fn (std.mem.Allocator, ReqT, []const u8) anyerror![]const u8 {
    return struct {
        fn parse(alloc: std.mem.Allocator, req: ReqT, body: []const u8) anyerror![]const u8 {
            _ = req;
            return alloc.dupe(u8, body);
        }
    }.parse;
}

test "classifyResponse on 201 Created parses body via spec" {
    const Req = struct {};
    const Body = struct { name: []const u8 };
    const spec = .{
        .method = std.http.Method.POST,
        .path_builder = undefined,
        .body_builder = null,
        .parse_ok = jsonParser(Req, Body),
    };

    const result = classifyResponse(Req, Body, spec, std.testing.allocator, .{}, .created, "{\"name\":\"foo\"}");
    defer switch (result) {
        .ok => |v| std.testing.allocator.free(v.name),
        else => {},
    };
    switch (result) {
        .ok => |v| try std.testing.expectEqualStrings("foo", v.name),
        else => return error.TestUnexpectedResult,
    }
}

test "classifyResponse on 409 with envelope yields api_error with code and message" {
    const Req = struct {};
    const spec = .{
        .method = std.http.Method.POST,
        .path_builder = undefined,
        .body_builder = null,
        .parse_ok = parseVoid(Req),
    };

    const body = "{\"error\":{\"code\":\"CONFLICT\",\"message\":\"dup\"}}";
    const result = classifyResponse(Req, void, spec, std.testing.allocator, .{}, .conflict, body);
    switch (result) {
        .api_error => |e| {
            defer std.testing.allocator.free(e.code);
            defer std.testing.allocator.free(e.message);
            try std.testing.expectEqual(std.http.Status.conflict, e.status);
            try std.testing.expectEqualStrings("CONFLICT", e.code);
            try std.testing.expectEqualStrings("dup", e.message);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "classifyResponse on non-JSON error body falls back to UNKNOWN code" {
    const Req = struct {};
    const spec = .{
        .method = std.http.Method.POST,
        .path_builder = undefined,
        .body_builder = null,
        .parse_ok = parseVoid(Req),
    };

    const result = classifyResponse(Req, void, spec, std.testing.allocator, .{}, .internal_server_error, "oops");
    switch (result) {
        .api_error => |e| {
            defer std.testing.allocator.free(e.code);
            defer std.testing.allocator.free(e.message);
            try std.testing.expectEqualStrings("UNKNOWN", e.code);
            try std.testing.expectEqualStrings("oops", e.message);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "classifyResponse on 2xx with malformed body yields invalid_response" {
    const Req = struct {};
    const Body = struct { name: []const u8 };
    const spec = .{
        .method = std.http.Method.GET,
        .path_builder = undefined,
        .body_builder = null,
        .parse_ok = jsonParser(Req, Body),
    };

    const result = classifyResponse(Req, Body, spec, std.testing.allocator, .{}, .ok, "not json");
    try std.testing.expectEqual(Result(Body).invalid_response, result);
}

test "jsonParser ignores req and parses body directly" {
    const Req = struct { key: []const u8 };
    const Body = struct { value: u32 };
    const parse = jsonParser(Req, Body);

    const out = try parse(std.testing.allocator, .{ .key = "unused" }, "{\"value\":7}");
    try std.testing.expectEqual(@as(u32, 7), out.value);
}

test "parseRawString dupes body into allocator and ignores req" {
    const Req = struct {};
    const parse = parseRawString(Req);

    const out = try parse(std.testing.allocator, .{}, "hello");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "staticPath returns the path string allocated in the given arena" {
    const EmptyReq = struct {};
    const build = staticPath(EmptyReq, "/api/foo");
    const out = try build(std.testing.allocator, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("/api/foo", out);
}

test "jsonBody serializes structs and skips null optionals" {
    const Req = struct { name: []const u8, bundle_id: ?[]const u8 = null };
    const build = jsonBody(Req);

    const body = try build(std.testing.allocator, Req{ .name = "foo" });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"name\":\"foo\"}", body);

    const body_with_bundle = try build(std.testing.allocator, Req{ .name = "foo", .bundle_id = "b1" });
    defer std.testing.allocator.free(body_with_bundle);
    try std.testing.expectEqualStrings("{\"name\":\"foo\",\"bundle_id\":\"b1\"}", body_with_bundle);
}

test "ThreadRegistry register and joinAll drain spawned threads" {
    var registry: ThreadRegistry = .{};

    const Worker = struct {
        fn noop(counter: *std.atomic.Value(u32)) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    var counter = std.atomic.Value(u32).init(0);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const t = try std.Thread.spawn(.{}, Worker.noop, .{&counter});
        try registry.register(t, std.testing.allocator);
    }

    registry.joinAll(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), counter.load(.monotonic));
}
