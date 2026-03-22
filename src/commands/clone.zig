const std = @import("std");
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");
const flag = @import("../flags.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ already exists\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Use {s}clumsies pull{s} to update\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const Q = 0;
    const SPECS = [_]flag.FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
    };
    var err_ctx: flag.ErrorContext = .{};
    var result = flag.parse(&SPECS, allocator, args, &err_ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try stdout.print("{s}Usage: {s}clumsies clone <git-url>{s}\n", .{ P, Color.cyan, Color.reset });
            return;
        },
        error.UnknownFlag => {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try stderr.print("{s}Usage: {s}clumsies clone <git-url>{s}\n", .{ P, Color.cyan, Color.reset });
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
    const remote_url: ?[]const u8 = if (result.positionals.items.len > 0) result.positionals.items[0] else null;

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
