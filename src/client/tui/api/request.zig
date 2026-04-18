//! Single-request vocabulary shared by every endpoint in the TUI fetch layer.
//!
//! `PendingRequest(T)` is the state container attached to each endpoint: it
//! tracks whether a request is in flight, holds the most recently completed
//! result, and uses a monotonic generation counter so that a late `complete`
//! from a cancelled request is safely dropped instead of overwriting the
//! next request's slot.
//!
//! `Result(T)` is the uniform result shape: every request classifies into
//! `ok` / `api_error` / `network_error` / `invalid_response`, so callers do
//! not need to interpret HTTP status codes themselves. `ApiErrorPayload`
//! carries the server-side structured error envelope
//! (`protocol.api_error.ApiErrorEnvelope`) verbatim so UI layers can display
//! the server's `message` and match on the stable `code` string.

const std = @import("std");

pub const ApiErrorPayload = struct {
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
};

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        api_error: ApiErrorPayload,
        network_error,
        invalid_response,
    };
}

pub fn PendingRequest(comptime T: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        state: State = .idle,
        generation: u64 = 0,
        result: T = undefined,

        pub const State = enum { idle, inflight, ready };

        /// Attempt to begin a new request. Returns the generation token on
        /// success, or null if a request is already in flight.
        ///
        /// The returned generation must be passed back to `complete` so
        /// that results from a cancelled request are dropped.
        pub fn tryBegin(self: *@This()) ?u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state == .inflight) return null;
            self.generation +%= 1;
            self.state = .inflight;
            return self.generation;
        }

        /// Deposit a result from the background worker. The value is only
        /// accepted when `gen` matches the current generation and the
        /// request is still in flight. Mismatched completions are
        /// discarded (the value is moved in and then dropped on the floor
        /// — T must tolerate being leaked in that case, which is fine in
        /// practice because results live in the shared arena).
        pub fn complete(self: *@This(), gen: u64, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state != .inflight or self.generation != gen) return;
            self.result = value;
            self.state = .ready;
        }

        /// Consume the result if one is ready. Returns null when the slot
        /// is idle or a request is still in flight. After consumption the
        /// slot returns to `idle` and is ready to accept a new request.
        pub fn consume(self: *@This()) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state != .ready) return null;
            const value = self.result;
            self.state = .idle;
            return value;
        }

        /// Cancel the current in-flight request. The worker thread keeps
        /// running but its eventual `complete` call is dropped because the
        /// generation is bumped. The slot returns to `idle` so a new
        /// request can begin immediately.
        pub fn cancel(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.generation +%= 1;
            self.state = .idle;
        }

        pub fn isInflight(self: *@This()) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.state == .inflight;
        }
    };
}

test "PendingRequest tryBegin / complete / consume happy path" {
    var pending: PendingRequest(u32) = .{};

    const gen = pending.tryBegin() orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(PendingRequest(u32).State.inflight, pending.state);

    pending.complete(gen, 42);
    try std.testing.expectEqual(PendingRequest(u32).State.ready, pending.state);

    const value = pending.consume() orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u32, 42), value);
    try std.testing.expectEqual(PendingRequest(u32).State.idle, pending.state);
}

test "PendingRequest tryBegin rejects concurrent begin while inflight" {
    var pending: PendingRequest(u32) = .{};
    _ = pending.tryBegin() orelse return error.TestUnexpectedNull;
    try std.testing.expect(pending.tryBegin() == null);
}

test "PendingRequest cancel drops late completion from previous generation" {
    var pending: PendingRequest(u32) = .{};
    const gen1 = pending.tryBegin() orelse return error.TestUnexpectedNull;

    pending.cancel();
    try std.testing.expectEqual(PendingRequest(u32).State.idle, pending.state);

    // Late complete from the cancelled request arrives: must be dropped.
    pending.complete(gen1, 99);
    try std.testing.expectEqual(PendingRequest(u32).State.idle, pending.state);
    try std.testing.expect(pending.consume() == null);

    // A fresh request can now begin and complete without interference.
    const gen2 = pending.tryBegin() orelse return error.TestUnexpectedNull;
    try std.testing.expect(gen2 != gen1);
    pending.complete(gen2, 7);
    try std.testing.expectEqual(@as(u32, 7), pending.consume().?);
}

test "PendingRequest consume returns null when idle or inflight" {
    var pending: PendingRequest(u32) = .{};
    try std.testing.expect(pending.consume() == null);

    _ = pending.tryBegin() orelse return error.TestUnexpectedNull;
    try std.testing.expect(pending.consume() == null);
}

test "PendingRequest isInflight tracks state transitions" {
    var pending: PendingRequest(u32) = .{};
    try std.testing.expect(!pending.isInflight());

    const gen = pending.tryBegin() orelse return error.TestUnexpectedNull;
    try std.testing.expect(pending.isInflight());

    pending.complete(gen, 1);
    try std.testing.expect(!pending.isInflight());
}

test "PendingRequest carries Result(T) for classified outcomes" {
    const R = Result(u32);
    var pending: PendingRequest(R) = .{};

    const gen = pending.tryBegin() orelse return error.TestUnexpectedNull;
    pending.complete(gen, .{ .ok = 123 });

    const out = pending.consume() orelse return error.TestUnexpectedNull;
    switch (out) {
        .ok => |v| try std.testing.expectEqual(@as(u32, 123), v),
        else => return error.TestUnexpectedResult,
    }
}

test "Result union carries ApiErrorPayload with structured fields" {
    const err: Result(u32) = .{ .api_error = .{
        .status = .conflict,
        .code = "CONFLICT",
        .message = "workspace with this name already exists",
    } };
    switch (err) {
        .api_error => |payload| {
            try std.testing.expectEqual(std.http.Status.conflict, payload.status);
            try std.testing.expectEqualStrings("CONFLICT", payload.code);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "PendingRequest sequential complete-consume cycles reuse the slot" {
    var pending: PendingRequest(u32) = .{};

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const gen = pending.tryBegin() orelse return error.TestUnexpectedNull;
        pending.complete(gen, i);
        try std.testing.expectEqual(i, pending.consume().?);
    }
}
