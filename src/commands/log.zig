const std = @import("std");
const git = @import("../git.zig");
const commands = @import("commands.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutput = commands.printGitOutput;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator) !void {
    if (!commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies clone <url>{s} first\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    const log = git.getLog(allocator, prompts_path, 10, &git_output) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to get log\n", .{ P, Color.bold, Color.red, Color.reset });
        printGitOutput(stderr, &git_output);
        return;
    };
    defer allocator.free(log);

    if (log.len == 0) {
        try stdout.print("{s}{s}No commits yet{s}\n", .{ P, Color.dim, Color.reset });
        return;
    }

    try stdout.print("{s}{s}{s}.prompts/ log:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });

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
}
