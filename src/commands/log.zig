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

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    const log = git.getLog(allocator, prompts_path, 10) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Failed to get log\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(log);

    if (log.len == 0) {
        try stdout.print("\n{s}{s}No commits yet{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    }

    try stdout.print("\n{s}{s}{s}.prompts/ log:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });

    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            // Split at first space to get hash
            if (std.mem.indexOf(u8, line, " ")) |space_idx| {
                const hash = line[0..space_idx];
                const msg = line[space_idx + 1 ..];
                try stdout.print("{s}  {s}{s}{s} {s}\n", .{ P, Color.cyan, hash, Color.reset, msg });
            } else {
                try stdout.print("{s}  {s}\n", .{ P, line });
            }
        }
    }
    try stdout.writeAll("\n");
}
