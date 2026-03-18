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

    if (!commands.promptsIsGitRepo()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ is not a git repository\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies clone <url>{s} first\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    try stdout.print("{s}{s}{s}.prompts/ status:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });

    // Get remote URL
    var remote_output: GitOutput = .{};
    defer remote_output.deinit(allocator);
    const remote_result = git.getRemoteUrl(allocator, prompts_path, &remote_output);
    const remote = remote_result catch "-";
    defer if (remote_result) |r| allocator.free(r) else |_| {};
    try stdout.print("{s}  Remote: {s}{s}{s}\n", .{ P, Color.cyan, remote, Color.reset });

    // Get status
    var status_output: GitOutput = .{};
    defer status_output.deinit(allocator);
    const status_result = git.getStatus(allocator, prompts_path, &status_output);
    const status = status_result catch "";
    defer if (status_result) |s| allocator.free(s) else |_| {};

    if (status.len == 0) {
        try stdout.print("{s}  {s}Clean{s}\n", .{ P, Color.green, Color.reset });
    } else {
        printGitOutput(stdout, &status_output);
    }
}
