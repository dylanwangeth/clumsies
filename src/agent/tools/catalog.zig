//! Built-in tool catalog for the first coding-agent surface.
//!
//! This module declares the tools that a product surface may choose to expose.
//! It intentionally stays outside `agent/core/tool.zig`: the core tool module
//! defines the provider-neutral contract and runtime, while this catalog is a
//! concrete tool set with product-level names, descriptions, and schemas.

const std = @import("std");
const tool = @import("../core/tool.zig");
const bash = @import("bash.zig");
const discuss = @import("discuss.zig");
const edit = @import("edit.zig");
const glob = @import("glob.zig");
const grep = @import("grep.zig");
const read = @import("read.zig");
const write = @import("write.zig");

/// Minimal tool declarations exposed by the first coding-agent surface.
///
/// These definitions intentionally use Claude Code-style one-word names. They
/// define the provider-facing contract only; concrete invokers can start small
/// and grow behavior behind the same names.
pub const DEFINITIONS = [_]tool.Definition{
    discuss.DEFINITION,
    glob.DEFINITION,
    grep.DEFINITION,
    read.DEFINITION,
    edit.DEFINITION,
    write.DEFINITION,
    bash.DEFINITION,
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
