//! Built-in `Bash` command tool.
//!
//! `Bash` is the first escape hatch from structured workspace tools into local
//! process execution. It stays behind the built-in tool runtime so command
//! limits, workspace cwd, output shaping, and future approval/UI hooks have one
//! boundary instead of leaking into the agent loop.

const std = @import("std");
const tool = @import("../core/tool.zig");
const encoding = @import("../../util/encoding.zig");
const process = @import("process.zig");
const tool_result = @import("result.zig");
const workspace = @import("workspace.zig");

pub const DEFINITION: tool.Definition = .{
    .name = "Bash",
    .description = "Run a shell command in the workspace with runtime limits.",
    .parameters_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"command":{"type":"string"},"timeout_ms":{"type":"integer","minimum":1}},"required":["command"]}
    ,
    .kind = .command,
    .scheduling = .serial,
    .effects = .{ .external_side_effect = true },
    .failure_policy = .stop_on_error,
};

/// Local implementation entrypoint used by the built-in tool dispatcher.
///
/// The provider supplies JSON arguments, but this function owns the local
/// command contract: run in the configured workspace, enforce runtime limits,
/// and return one JSON object that the next model turn can reason about.
pub fn invoke(
    allocator: std.mem.Allocator,
    context: workspace.Context,
    arguments: []const u8,
) !tool.Result {
    const parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{});
    defer parsed.deinit();
    const args = parsed.value;

    if (std.mem.trim(u8, args.command, " \t\r\n").len == 0) {
        return tool_result.fail(allocator, "empty_command", "Bash command must not be empty");
    }

    const timeout_ms = args.timeout_ms orelse context.command_timeout_ms;
    const result = process.run(
        allocator,
        &.{ "/bin/sh", "-c", args.command },
        context.workspace_path,
        .{
            .timeout_ms = timeout_ms,
            .max_output_bytes = context.max_command_output_bytes,
        },
    ) catch |err| return tool_result.fail(
        allocator,
        "command_spawn_failed",
        @errorName(err),
    );
    defer result.deinit(allocator);

    return formatResult(allocator, result);
}

const Args = struct {
    command: []const u8,
    timeout_ms: ?u64 = null,
};

/// Converts local process details into the built-in tool JSON result shape.
///
/// The agent loop treats this as opaque bytes. JSON is chosen here because the
/// next provider turn needs stable fields for exit status, timeout, truncation,
/// stdout, and stderr.
fn formatResult(allocator: std.mem.Allocator, result: process.Result) !tool.Result {
    const esc_stdout = try encoding.jsonEscapeAlloc(allocator, result.stdout);
    defer allocator.free(esc_stdout);
    const esc_stderr = try encoding.jsonEscapeAlloc(allocator, result.stderr);
    defer allocator.free(esc_stderr);

    const exit_code = exitCode(result.term);
    const exit_code_json = try exitCodeJson(allocator, exit_code);
    defer allocator.free(exit_code_json);

    const status = if (isError(result, exit_code)) "error" else "ok";
    const message = resultMessage(result, exit_code);
    const esc_message = try encoding.jsonEscapeAlloc(allocator, message);
    defer allocator.free(esc_message);

    const content = try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"{s}\",\"exit_code\":{s},\"timed_out\":{},\"output_limit_hit\":{},\"stdout_truncated\":{},\"stderr_truncated\":{},\"message\":\"{s}\",\"stdout\":\"{s}\",\"stderr\":\"{s}\"}}\n",
        .{
            status,
            exit_code_json,
            result.timed_out,
            result.output_limit_hit,
            result.stdout_truncated,
            result.stderr_truncated,
            esc_message,
            esc_stdout,
            esc_stderr,
        },
    );

    return .{
        .content = content,
        .owns_content = true,
        .is_error = std.mem.eql(u8, status, "error"),
    };
}

fn exitCode(term: ?std.process.Child.Term) ?u8 {
    const value = term orelse return null;
    return switch (value) {
        .Exited => |code| code,
        .Signal, .Stopped, .Unknown => null,
    };
}

fn exitCodeJson(allocator: std.mem.Allocator, code: ?u8) ![]u8 {
    if (code) |value| return std.fmt.allocPrint(allocator, "{d}", .{value});
    return allocator.dupe(u8, "null");
}

fn isError(result: process.Result, code: ?u8) bool {
    if (result.timed_out or result.output_limit_hit) return true;
    return code == null or code.? != 0;
}

fn resultMessage(result: process.Result, code: ?u8) []const u8 {
    if (result.timed_out) return "command timed out";
    if (result.output_limit_hit) return "command output exceeded limit";
    if (code == null) return "command ended without an exit code";
    if (code.? != 0) return "command exited with non-zero status";
    return "command completed";
}

const testing = std.testing;

test "Bash returns stdout and exit code" {
    const result = try invoke(
        testing.allocator,
        .{ .workspace_path = "." },
        "{\"command\":\"printf agent-core\"}",
    );
    defer result.deinit(testing.allocator);

    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "\"exit_code\":0") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "\"stdout\":\"agent-core\"") != null);
}

test "Bash marks non-zero exit as model-visible error" {
    const result = try invoke(
        testing.allocator,
        .{ .workspace_path = "." },
        "{\"command\":\"printf nope >&2; exit 7\"}",
    );
    defer result.deinit(testing.allocator);

    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "\"exit_code\":7") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "\"stderr\":\"nope\"") != null);
}

test "Bash runs inside the configured workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "marker.txt", .data = "ok\n" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const context: workspace.Context = .{
        .workspace_path = try tmp.dir.realpath(".", &path_buf),
    };

    const result = try invoke(
        testing.allocator,
        context,
        "{\"command\":\"cat marker.txt\"}",
    );
    defer result.deinit(testing.allocator);

    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "\"stdout\":\"ok\\n\"") != null);
}
