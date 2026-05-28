//! Built-in `Edit` tool declaration.
//!
//! The tool is declared now so providers can learn the intended surface, but
//! mutation execution remains pending until file-locking, diff validation, and
//! failure policy behavior are implemented.

const tool = @import("../core/tool.zig");

pub const DEFINITION: tool.Definition = .{
    .name = "Edit",
    .description = "Replace one exact text occurrence in a workspace file.",
    .parameters_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"}},"required":["path","old","new"]}
    ,
    .kind = .mutate,
    .scheduling = .serial,
    .effects = .{ .reads_workspace = true, .writes_workspace = true },
    .failure_policy = .stop_on_error,
};

/// Local implementation entrypoint used by the built-in tool dispatcher.
///
/// The tool is declared before it is executable so provider/tool-call plumbing
/// can stabilize. Execution stays pending until mutation validation and
/// per-file write ordering are designed.
pub fn invoke() tool.Result {
    return .{
        .content = "built-in tool is not implemented yet",
        .is_error = true,
    };
}
