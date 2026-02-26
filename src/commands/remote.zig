const std = @import("std");
const git = @import("../git.zig");
const commands = @import("commands.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Remote URL required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies remote <git-url>{s}\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    var quiet_git: bool = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-Q") or std.mem.eql(u8, arg, "--quiet-git")) {
            quiet_git = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try stderr.print("{s}Usage: {s}clumsies remote <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
    }

    if (!commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies init{s} first\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = commands.getPromptsPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine .prompts/ path\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompts_path);

    const remote_url = args[0];

    // Check if remote already exists
    var check_output: GitOutput = .{};
    defer check_output.deinit(allocator);

    const has_remote = git.hasRemote(allocator, prompts_path, &check_output) catch false;

    if (has_remote) {
        // Update existing remote
        var set_output: GitOutput = .{};
        defer set_output.deinit(allocator);

        git.setRemoteUrl(allocator, prompts_path, remote_url, &set_output) catch {
            printGitOutputRaw(&set_output, quiet_git);
            try stderr.print("{s}{s}{s}Error:{s} Failed to update remote\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        try stdout.print("{s}{s}{s}✓{s} Updated remote: {s}\n", .{ P, Color.bold, Color.green, Color.reset, remote_url });
        printGitOutputRaw(&set_output, quiet_git);
    } else {
        // Add new remote
        var add_output: GitOutput = .{};
        defer add_output.deinit(allocator);

        git.addRemote(allocator, prompts_path, remote_url, &add_output) catch {
            printGitOutputRaw(&add_output, quiet_git);
            try stderr.print("{s}{s}{s}Error:{s} Failed to add remote\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        try stdout.print("{s}{s}{s}✓{s} Added remote: {s}\n", .{ P, Color.bold, Color.green, Color.reset, remote_url });
        printGitOutputRaw(&add_output, quiet_git);
    }
}
