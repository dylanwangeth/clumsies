const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (commands.promptsExist()) {
        try stderr.print("\n{s}{s}{s}Error:{s} .prompts/ already exists\n", .{ P, Color.bold, Color.red, Color.reset });
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
        try stderr.print("\n{s}{s}{s}Error:{s} Remote URL required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies clone <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    // Use unbuffered stdout for consistent ordering with spinner
    const raw_stdout = std.fs.File.stdout();
    _ = raw_stdout.write("\n") catch {};

    var sp = spinner.init(stdout, "Cloning repository");
    sp.start();

    git.clone(allocator, remote_url.?, prompts_path) catch {
        sp.fail();
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}{s}{s}Error:{s} Failed to clone repository\n\n", .{ P, Color.bold, Color.red, Color.reset }) catch return;
        _ = raw_stdout.write(line) catch {};
        return;
    };
    sp.succeed();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // Sync meta-prompt files: .prompts/ -> root
    const entry_files_str = config.getEntryFilesStr(allocator) catch null;
    defer if (entry_files_str) |s| allocator.free(s);

    if (entry_files_str) |ef_str| {
        var iter = std.mem.splitSequence(u8, ef_str, ",");
        while (iter.next()) |entry_file| {
            const trimmed = std.mem.trim(u8, entry_file, " ");
            if (trimmed.len == 0) continue;

            const src = try std.fs.path.join(allocator, &.{ prompts_path, trimmed });
            defer allocator.free(src);
            const dest = try std.fs.path.join(allocator, &.{ cwd, trimmed });
            defer allocator.free(dest);

            fs.copyFileAbsolute(src, dest, .{}) catch continue;
        }
    } else {
        for (config.DEFAULT_ENTRY_FILES) |entry_file| {
            const src = try std.fs.path.join(allocator, &.{ prompts_path, entry_file });
            defer allocator.free(src);
            const dest = try std.fs.path.join(allocator, &.{ cwd, entry_file });
            defer allocator.free(dest);

            fs.copyFileAbsolute(src, dest, .{}) catch continue;
        }
    }

    // Use unbuffered stdout for consistent ordering with spinner
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}  Remote: {s}{s}{s}\n\n", .{ P, Color.cyan, remote_url.?, Color.reset }) catch return;
    _ = std.fs.File.stdout().write(line) catch {};
}
