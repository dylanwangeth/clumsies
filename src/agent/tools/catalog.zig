//! Built-in tool catalog for the first coding-agent surface.
//!
//! This module declares the tools that a product surface may choose to expose.
//! It intentionally stays outside `agent/core/tool.zig`: the core tool module
//! defines the provider-neutral contract and runtime, while this catalog is a
//! concrete tool set with product-level names, descriptions, and schemas.

const std = @import("std");
const tool = @import("../core/tool.zig");

/// Minimal tool declarations exposed by the first coding-agent surface.
///
/// These definitions intentionally use Claude Code-style one-word names. They
/// define the provider-facing contract only; concrete invokers can start small
/// and grow behavior behind the same names.
pub const DEFINITIONS = [_]tool.Definition{
    .{
        .name = "Discuss",
        .description = "Discuss uncertainty, options, or feedback with the user before continuing the task.",
        .parameters_schema =
        \\{"type":"object","additionalProperties":false,"properties":{"topic":{"type":"string"},"message":{"type":"string"}},"required":["message"]}
        ,
        .kind = .interaction,
        .scheduling = .serial,
    },
    .{
        .name = "Glob",
        .description = "Find workspace files matching a glob pattern.",
        .parameters_schema =
        \\{"type":"object","additionalProperties":false,"properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern"]}
        ,
        .kind = .observe,
        .effects = .{ .reads_workspace = true },
    },
    .{
        .name = "Grep",
        .description = "Search workspace files for text or a regular expression.",
        .parameters_schema =
        \\{"type":"object","additionalProperties":false,"properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"}},"required":["pattern"]}
        ,
        .kind = .observe,
        .effects = .{ .reads_workspace = true },
    },
    .{
        .name = "Read",
        .description = "Read a bounded range from a workspace file.",
        .parameters_schema =
        \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"start_line":{"type":"integer","minimum":1},"line_count":{"type":"integer","minimum":1}},"required":["path"]}
        ,
        .kind = .observe,
        .effects = .{ .reads_workspace = true },
    },
    .{
        .name = "Edit",
        .description = "Replace one exact text occurrence in a workspace file.",
        .parameters_schema =
        \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"}},"required":["path","old","new"]}
        ,
        .kind = .mutate,
        .scheduling = .serial,
        .effects = .{ .reads_workspace = true, .writes_workspace = true },
        .failure_policy = .stop_on_error,
    },
    .{
        .name = "Write",
        .description = "Write content to a workspace file.",
        .parameters_schema =
        \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
        .kind = .mutate,
        .scheduling = .serial,
        .effects = .{ .writes_workspace = true },
        .failure_policy = .stop_on_error,
    },
    .{
        .name = "Bash",
        .description = "Run a shell command in the workspace with runtime limits.",
        .parameters_schema =
        \\{"type":"object","additionalProperties":false,"properties":{"command":{"type":"string"},"timeout_ms":{"type":"integer","minimum":1}},"required":["command"]}
        ,
        .kind = .command,
        .scheduling = .serial,
        .effects = .{ .external_side_effect = true },
        .failure_policy = .stop_on_error,
    },
};

const testing = std.testing;

test "tool catalog definitions use one-word names and valid schemas" {
    const expected_names = [_][]const u8{
        "Discuss",
        "Glob",
        "Grep",
        "Read",
        "Edit",
        "Write",
        "Bash",
    };

    try testing.expectEqual(expected_names.len, DEFINITIONS.len);
    for (DEFINITIONS, expected_names) |definition, expected_name| {
        try testing.expectEqualStrings(expected_name, definition.name);
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            definition.parameters_schema,
            .{},
        );
        defer parsed.deinit();
        try testing.expectEqual(std.json.Value.object, std.meta.activeTag(parsed.value));
    }
}
