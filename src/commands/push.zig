const std = @import("std");
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");
const flag = @import("../flags.zig");

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

    const Q = 0;
    const M = 1;
    const SPECS = [_]flag.FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
        .{ .short = 'm', .long = "message", .kind = .value },
    };
    var err_ctx: flag.ErrorContext = .{};
    var result = flag.parse(&SPECS, allocator, args, &err_ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try stdout.print("{s}Usage: {s}clumsies push [-m <message>]{s}\n", .{ P, Color.cyan, Color.reset });
            return;
        },
        error.UnknownFlag => {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try stderr.print("{s}Usage: {s}clumsies push [-m <message>]{s}\n", .{ P, Color.cyan, Color.reset });
            return;
        },
        error.MissingValue => {
            try stderr.print("{s}{s}{s}Error:{s} {s} requires a value\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer result.deinit(allocator);
    const quiet_git = result.boolean(Q);
    const message = result.value(M) orelse "Update prompts";

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    // Git add, commit, push
    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);

    git.addAll(allocator, prompts_path, &add_output) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to stage changes\n", .{ P, Color.bold, Color.red, Color.reset });
        printGitOutputRaw(&add_output, quiet_git);
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

    try stdout.print("{s}Message: {s}\n", .{ P, message });
}
