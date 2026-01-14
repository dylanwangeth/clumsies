const std = @import("std");
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;
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

    var git_err: ?[]const u8 = null;
    defer if (git_err) |e| allocator.free(e);

    git.pull(allocator, prompts_path, &git_err) catch {
        sp.fail();
        if (git_err) |e| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}{s}git:\n{s}{s}\n", .{ P, Color.dim, std.mem.trim(u8, e, "\n\r "), Color.reset }) catch return;
            _ = raw_stdout.write(line) catch {};
        }
        return;
    };
    sp.succeed();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // Sync meta-prompt files: .prompts/ -> root
    syncMetaPromptFiles(allocator, prompts_path, cwd);

    _ = std.fs.File.stdout().write("\n") catch {};
}
