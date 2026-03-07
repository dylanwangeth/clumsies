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
        try stderr.print("{s}Run {s}clumsies clone <url>{s} first\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    // Parse flags
    var message: []const u8 = "Update prompts";
    var quiet_git: bool = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-Q") or std.mem.eql(u8, args[i], "--quiet-git")) {
            quiet_git = true;
        } else if ((std.mem.eql(u8, args[i], "-m") or std.mem.eql(u8, args[i], "--message")) and i + 1 < args.len) {
            message = args[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, args[i] });
            try stderr.print("{s}Usage: {s}clumsies push [-m <message>]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    // Git add, commit, push
    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);

    git.addAll(allocator, prompts_path, &add_output) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to stage changes\n", .{ P, Color.bold, Color.red, Color.reset });
        printGitOutputRaw(&add_output, quiet_git);
        try stderr.writeAll("\n");
        return;
    };

    // Try to commit (may fail if no changes, that's ok - we'll still try to push)
    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    _ = git.commit(allocator, prompts_path, message, &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    var sp = spinner.init(stdout, "Pushing to remote");
    sp.start();

    git.push(allocator, prompts_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output, quiet_git);
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output, quiet_git);

    try stdout.print("{s}  Message: {s}\n", .{ P, message });
}
