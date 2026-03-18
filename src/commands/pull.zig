const std = @import("std");
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (!commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies clone <url>{s} first\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    var quiet_git: bool = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-Q") or std.mem.eql(u8, arg, "--quiet-git")) {
            quiet_git = true;
        }
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    var sp = spinner.init(stdout, "Pulling from remote");
    sp.start();

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.pull(allocator, prompts_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output, quiet_git);
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output, quiet_git);

}
