const std = @import("std");
const ws_config = @import("../workspace_config.zig");
const output = @import("../output.zig");

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    if (output.detect() == .human) {
        try stderr.writeAll("This command is for agent environments only (hooks/pipes).\n");
        return;
    }

    const cwd = std.process.getCwdAlloc(allocator) catch return;
    defer allocator.free(cwd);

    const cache_path = blk: {
        const binding = ws_config.resolveWorkspace(allocator, cwd) catch break :blk null;
        defer allocator.free(binding.ws_id);
        defer allocator.free(binding.name);
        break :blk ws_config.getCachePath(allocator, binding.ws_id) catch null;
    };

    if (cache_path) |cp| {
        defer allocator.free(cp);
        const mpf_path = std.fs.path.join(allocator, &.{ cp, "META_PROMPT.md" }) catch return;
        defer allocator.free(mpf_path);

        const file = std.fs.openFileAbsolute(mpf_path, .{}) catch return;
        defer file.close();

        var buf: [64 * 1024]u8 = undefined;
        const n = file.read(&buf) catch return;
        stdout.writeAll(buf[0..n]) catch return;
    }
}
