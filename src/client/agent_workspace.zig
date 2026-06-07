//! Local workspace root resolution for client-side agent surfaces.
//!
//! The provider-neutral agent core only receives tool runtimes. CLI and TUI
//! surfaces decide which filesystem root their built-in tools may see, so this
//! module keeps that product boundary out of `src/agent`.

const std = @import("std");
const workspace_config = @import("workspace_config.zig");

/// Resolves the filesystem root used by built-in coding tools.
///
/// When the current directory is inside a bound Clumsies workspace, tools run
/// at that workspace root so launching the TUI from a subdirectory does not
/// shrink the agent's project view. Unbound directories fall back to the
/// process cwd, which preserves standalone CLI smoke-test behavior.
pub fn resolveToolRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (try workspace_config.resolveCurrentWorkspaceRoot(allocator)) |root| {
        return root;
    }
    return try std.fs.cwd().realpathAlloc(allocator, ".");
}
