//! Built-in `Write` tool declaration.
//!
//! `Write` is intentionally pending while the agent's mutation policy is still
//! being designed. Keeping the definition separate lets the provider contract
//! stabilize without hiding the missing execution semantics.

const tool = @import("../core/tool.zig");

pub const DEFINITION: tool.Definition = .{
    .name = "Write",
    .description = "Write content to a workspace file.",
    .parameters_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
    ,
    .kind = .mutate,
    .scheduling = .serial,
    .effects = .{ .writes_workspace = true },
    .failure_policy = .stop_on_error,
};

/// Local implementation entrypoint used by the built-in tool dispatcher.
///
/// The tool keeps the same `invoke` shape as executable tools, but returns a
/// model-visible pending result until workspace mutation policy is explicit.
pub fn invoke() tool.Result {
    return .{
        .content = "built-in tool is not implemented yet",
        .is_error = true,
    };
}
