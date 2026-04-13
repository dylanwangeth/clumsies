const std = @import("std");
const ws_config = @import("../workspace_config.zig");
const output = @import("../output.zig");

/// Internal `_agent workspace-info` command. Resolves the workspace binding
/// for the current directory and prints two shell-eval lines:
///
///     export WS_ID=ws-...
///     export CACHE_DIR=/Users/.../.clumsies/workspaces/ws-.../cache
///
/// Used by cc-plugin hook scripts to locate the cache directory before
/// scanning workflow files. Silent no-output if the current directory is
/// not bound to any workspace — callers should treat empty output as
/// "clumsies inactive in this project".
pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    if (output.detect() == .human) {
        try stderr.writeAll("This command is for agent environments only (hooks/pipes).\n");
        return;
    }

    const cwd = std.process.getCwdAlloc(allocator) catch return;
    defer allocator.free(cwd);

    const binding = ws_config.resolveWorkspace(allocator, cwd) catch return;
    defer allocator.free(binding.ws_id);
    defer allocator.free(binding.name);

    const cache_dir = ws_config.getCachePath(allocator, binding.ws_id) catch return;
    defer allocator.free(cache_dir);

    try stdout.print("export WS_ID={s}\n", .{binding.ws_id});
    try stdout.print("export CACHE_DIR={s}\n", .{cache_dir});
}
