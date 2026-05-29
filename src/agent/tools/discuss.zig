//! Built-in `Discuss` tool.
//!
//! `Discuss` represents a model request to stop and involve the user. Until
//! the UI has a pause/resume flow, the runtime returns a model-visible pending
//! result with `.stop_run` so the loop exits cleanly.

const std = @import("std");
const tool = @import("../core/tool.zig");
const tool_result = @import("result.zig");

pub const DEFINITION: tool.Definition = .{
    .name = "Discuss",
    .description = "Discuss uncertainty, options, or feedback with the user before continuing the task.",
    .parameters_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"topic":{"type":"string"},"message":{"type":"string"}},"required":["message"]}
    ,
    .kind = .interaction,
    .scheduling = .serial,
};

/// Local implementation entrypoint used by the built-in tool dispatcher.
///
/// `Discuss` is still named like other tools so the dispatcher has one calling
/// convention. It returns `.stop_run` because user interaction needs a future
/// pause/resume surface instead of another automatic provider turn.
pub fn invoke(allocator: std.mem.Allocator) !tool.Result {
    return tool_result.failWithControl(
        allocator,
        "user_interaction_required",
        "Discuss requires a pause/resume UI before the run can continue",
        .stop_run,
    );
}
