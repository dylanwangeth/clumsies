const std = @import("std");
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ already exists\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Use {s}clumsies pull{s} to update\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    // Get remote URL from args
    var remote_url: ?[]const u8 = null;
    var quiet_git: bool = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-Q") or std.mem.eql(u8, arg, "--quiet-git")) {
            quiet_git = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try stderr.print("{s}Usage: {s}clumsies clone <git-url>{s}\n", .{ P, Color.cyan, Color.reset });
            return;
        } else if (remote_url == null) {
            remote_url = arg;
        }
    }

    if (remote_url == null) {
        try stderr.print("{s}{s}{s}Error:{s} Remote URL required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies clone <git-url>{s}\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    var sp = spinner.init(stdout, "Cloning repository");
    sp.start();

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.clone(allocator, remote_url.?, prompts_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output, quiet_git);
        try stderr.print("{s}{s}{s}Error:{s} Failed to clone repository\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output, quiet_git);

    // Use unbuffered stdout for consistent ordering with spinner
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}Remote: {s}{s}{s}\n", .{ P, Color.cyan, remote_url.?, Color.reset }) catch return;
    _ = std.fs.File.stdout().write(line) catch {};
    const tip = std.fmt.bufPrint(&buf, "{s}Tip: Run '{s}clumsies bundle import <name>{s}' to get meta-prompt files\n", .{ P, Color.cyan, Color.reset }) catch return;
    _ = std.fs.File.stdout().write(tip) catch {};
}
