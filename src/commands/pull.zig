const std = @import("std");
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;
const syncMetaPromptFiles = commands.syncMetaPromptFiles;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) !void {
    if (!commands.promptsExist()) {
        try stderr.print("\n{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies init <bundle> <url>{s} or {s}clumsies clone <url>{s} first\n\n", .{ P, Color.cyan, Color.reset, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    // Use unbuffered stdout for consistent ordering with spinner
    const raw_stdout = std.fs.File.stdout();
    _ = raw_stdout.write("\n") catch {};

    var sp = spinner.init(stdout, "Pulling from remote");
    sp.start();

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.pull(allocator, prompts_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output);
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output);

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // Move meta-prompt files: .prompts/ -> root (delete from .prompts/)
    // If root already has the file, creates .remote.md version
    syncMetaPromptFiles(allocator, prompts_path, cwd, true);

    _ = std.fs.File.stdout().write("\n") catch {};
}
