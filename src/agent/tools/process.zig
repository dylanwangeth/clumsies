//! Local process runner used by command-oriented built-in tools.
//!
//! This module is deliberately below the provider-neutral tool runtime. It
//! knows how to spawn a local process, collect bounded stdout/stderr, and stop
//! work on timeout or output overflow, but it does not know anything about
//! provider messages or run-message conversion.

const std = @import("std");
const builtin = @import("builtin");

/// Process execution limits supplied by the built-in tool configuration.
pub const Options = struct {
    timeout_ms: u64,
    max_output_bytes: usize,
};

/// Captured result of one local process execution.
///
/// `stdout` and `stderr` are allocator-owned tail slices. If the original
/// stream exceeded `Options.max_output_bytes`, `truncated` is set and the slice
/// contains only the final bytes kept for the model-visible tool result.
pub const Result = struct {
    term: ?std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool = false,
    output_limit_hit: bool = false,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Runs `argv` in `cwd` with bounded output and a hard timeout.
///
/// `std.process.Child.run` has the right collection shape but no timeout hook,
/// so command tools use this wrapper. It mirrors the standard-library poller
/// approach while adding two command-agent policies: terminate long-running
/// processes and avoid unbounded output growth.
pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    options: Options,
) !Result {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    try child.spawn();
    errdefer terminatePosix(&child) catch {};

    var term: ?std.process.Child.Term = null;
    var timed_out = false;
    var output_limit_hit = false;

    {
        var poller = std.Io.poll(allocator, enum { stdout, stderr }, .{
            .stdout = child.stdout.?,
            .stderr = child.stderr.?,
        });
        defer poller.deinit();

        const stdout_reader = poller.reader(.stdout);
        stdout_reader.buffer = stdout.allocatedSlice();
        stdout_reader.seek = 0;
        stdout_reader.end = stdout.items.len;

        const stderr_reader = poller.reader(.stderr);
        stderr_reader.buffer = stderr.allocatedSlice();
        stderr_reader.seek = 0;
        stderr_reader.end = stderr.items.len;

        defer {
            stdout = .{
                .items = stdout_reader.buffer[0..stdout_reader.end],
                .capacity = stdout_reader.buffer.len,
            };
            stderr = .{
                .items = stderr_reader.buffer[0..stderr_reader.end],
                .capacity = stderr_reader.buffer.len,
            };
            stdout_reader.buffer = &.{};
            stderr_reader.buffer = &.{};
        }

        const started_ms = std.time.milliTimestamp();
        const timeout_ms = std.math.cast(i64, options.timeout_ms) orelse std.math.maxInt(i64);
        const deadline_ms = started_ms + timeout_ms;
        const max_buffered_bytes = options.max_output_bytes + 4096;
        var terminated = false;

        while (try poller.pollTimeout(10 * std.time.ns_per_ms)) {
            if (!terminated and std.time.milliTimestamp() >= deadline_ms) {
                timed_out = true;
                try terminatePosix(&child);
                terminated = true;
            }

            if (!terminated and
                (stdout_reader.bufferedLen() > max_buffered_bytes or
                    stderr_reader.bufferedLen() > max_buffered_bytes))
            {
                output_limit_hit = true;
                try terminatePosix(&child);
                terminated = true;
            }
        }
    }

    term = try child.wait();

    const stdout_tail = try tailAlloc(allocator, stdout.items, options.max_output_bytes);
    errdefer allocator.free(stdout_tail.bytes);
    const stderr_tail = try tailAlloc(allocator, stderr.items, options.max_output_bytes);
    errdefer allocator.free(stderr_tail.bytes);

    return .{
        .term = term,
        .stdout = stdout_tail.bytes,
        .stderr = stderr_tail.bytes,
        .timed_out = timed_out,
        .output_limit_hit = output_limit_hit,
        .stdout_truncated = stdout_tail.truncated,
        .stderr_truncated = stderr_tail.truncated,
    };
}

/// Sends SIGTERM without closing the child's stdout/stderr pipes.
///
/// `Child.kill` also cleans up stream handles, which would race with the poller
/// that is still draining captured output. The command runner therefore sends
/// the signal directly and lets `child.wait()` perform normal cleanup later.
fn terminatePosix(child: *std.process.Child) !void {
    std.posix.kill(child.id, std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => |e| return e,
    };
}

const Tail = struct {
    bytes: []u8,
    truncated: bool,
};

/// Copies the stream tail that should be exposed to the model.
///
/// Keeping the tail follows shell-tool practice: for long compiler/test output,
/// the last lines usually contain the actionable failure.
fn tailAlloc(allocator: std.mem.Allocator, bytes: []const u8, max_bytes: usize) !Tail {
    if (bytes.len <= max_bytes) {
        return .{ .bytes = try allocator.dupe(u8, bytes), .truncated = false };
    }
    return .{
        .bytes = try allocator.dupe(u8, bytes[bytes.len - max_bytes ..]),
        .truncated = true,
    };
}

const testing = std.testing;

test "process runner captures successful output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try run(
        testing.allocator,
        &.{ "/bin/sh", "-c", "printf hello" },
        ".",
        .{ .timeout_ms = 1000, .max_output_bytes = 1024 },
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term.?);
    try testing.expectEqualStrings("hello", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "process runner keeps tail when output is long" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try run(
        testing.allocator,
        &.{ "/bin/sh", "-c", "printf 123456789" },
        ".",
        .{ .timeout_ms = 1000, .max_output_bytes = 4 },
    );
    defer result.deinit(testing.allocator);

    try testing.expect(result.stdout_truncated);
    try testing.expectEqualStrings("6789", result.stdout);
}

test "process runner terminates timed out commands" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try run(
        testing.allocator,
        &.{ "/bin/sh", "-c", "sleep 2" },
        ".",
        .{ .timeout_ms = 10, .max_output_bytes = 1024 },
    );
    defer result.deinit(testing.allocator);

    try testing.expect(result.timed_out);
}
