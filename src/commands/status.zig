const std = @import("std");
const git = @import("../git.zig");
const commands = @import("commands.zig");

const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) !void {
    if (!commands.promptsExist()) {
        try stderr.print("\n{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies init <git-url>{s} first\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if (!commands.promptsIsGitRepo()) {
        try stderr.print("\n{s}{s}{s}Error:{s} .prompts/ is not a git repository\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies init <git-url>{s} to initialize\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    try stdout.print("\n{s}{s}.prompts/ status:{s}\n", .{ P, Color.bold, Color.reset });

    // Get remote URL
    const remote = git.getRemoteUrl(allocator, prompts_path) catch "-";
    defer if (!std.mem.eql(u8, remote, "-")) allocator.free(remote);
    try stdout.print("{s}  Remote: {s}{s}{s}\n", .{ P, Color.cyan, remote, Color.reset });

    // Get status
    const status = git.getStatus(allocator, prompts_path) catch "";
    defer if (status.len > 0) allocator.free(status);

    if (status.len == 0) {
        try stdout.print("{s}  {s}Clean{s}\n\n", .{ P, Color.green, Color.reset });
    } else {
        // Count changed files
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, status, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) count += 1;
        }
        try stdout.print("{s}  {s}{d} uncommitted changes{s}\n\n", .{ P, Color.orange, count, Color.reset });
    }
}
