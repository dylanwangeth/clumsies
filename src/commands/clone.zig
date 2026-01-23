const std = @import("std");
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;
const syncMetaPromptFiles = commands.syncMetaPromptFiles;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ already exists\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Use {s}clumsies pull{s} to update\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    // Get remote URL from args
    var remote_url: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len > 0 and arg[0] != '-') {
            remote_url = arg;
            break;
        }
    }

    if (remote_url == null) {
        try stderr.print("{s}{s}{s}Error:{s} Remote URL required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies clone <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    // Use unbuffered stdout for consistent ordering with spinner
    const raw_stdout = std.fs.File.stdout();
    _ = raw_stdout;

    var sp = spinner.init(stdout, "Cloning repository");
    sp.start();

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.clone(allocator, remote_url.?, prompts_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output);
        try stderr.print("{s}{s}{s}Error:{s} Failed to clone repository\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output);

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // Move meta-prompt files: .prompts/ -> root (delete from .prompts/)
    // If root already has the file, creates .remote.md version
    syncMetaPromptFiles(allocator, prompts_path, cwd, true);

    // Use unbuffered stdout for consistent ordering with spinner
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}  Remote: {s}{s}{s}\n\n", .{ P, Color.cyan, remote_url.?, Color.reset }) catch return;
    _ = std.fs.File.stdout().write(line) catch {};
}
