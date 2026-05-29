//! Built-in `Bash` tool declaration.
//!
//! Shell execution needs sandbox, timeout, streaming, and approval semantics.
//! The tool remains declared but unimplemented so those policies are not
//! accidentally bypassed by an early local process runner.

const std = @import("std");
const tool = @import("../core/tool.zig");
const tool_result = @import("result.zig");

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
/// Shell execution has extra policy requirements, so this entrypoint exists for
/// dispatcher consistency while refusing to run commands until sandbox,
/// timeout, and approval semantics are implemented.
pub fn invoke(allocator: std.mem.Allocator) !tool.Result {
    return tool_result.fail(
        allocator,
        "not_implemented",
        "Bash is declared but command execution policy is not implemented yet",
    );
}
