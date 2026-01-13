const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (!commands.promptsExist()) {
        try stderr.print("\n{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies init <bundle> <url>{s} or {s}clumsies clone <url>{s} first\n\n", .{ P, Color.cyan, Color.reset, Color.cyan, Color.reset });
        return;
    }

    // Parse commit message
    var message: []const u8 = "Update prompts";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if ((std.mem.eql(u8, args[i], "-m") or std.mem.eql(u8, args[i], "--message")) and i + 1 < args.len) {
            message = args[i + 1];
            break;
        }
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // Sync meta-prompt files: root -> .prompts/
    const entry_files_str = config.getEntryFilesStr(allocator) catch null;
    defer if (entry_files_str) |s| allocator.free(s);

    if (entry_files_str) |ef_str| {
        var iter = std.mem.splitSequence(u8, ef_str, ",");
        while (iter.next()) |entry_file| {
            const trimmed = std.mem.trim(u8, entry_file, " ");
            if (trimmed.len == 0) continue;

            const src = try std.fs.path.join(allocator, &.{ cwd, trimmed });
            defer allocator.free(src);
            const dest = try std.fs.path.join(allocator, &.{ prompts_path, trimmed });
            defer allocator.free(dest);

            fs.copyFileAbsolute(src, dest, .{}) catch continue;
        }
    } else {
        for (config.DEFAULT_ENTRY_FILES) |entry_file| {
            const src = try std.fs.path.join(allocator, &.{ cwd, entry_file });
            defer allocator.free(src);
            const dest = try std.fs.path.join(allocator, &.{ prompts_path, entry_file });
            defer allocator.free(dest);

            fs.copyFileAbsolute(src, dest, .{}) catch continue;
        }
    }

    // Git add, commit, push
    git.addAll(allocator, prompts_path) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Failed to stage changes\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Try to commit (may fail if no changes, that's ok - we'll still try to push)
    _ = git.commit(allocator, prompts_path, message) catch {};

    // Use unbuffered stdout for consistent ordering with spinner
    const raw_stdout = std.fs.File.stdout();
    _ = raw_stdout.write("\n") catch {};

    var sp = spinner.init(stdout, "Pushing to remote");
    sp.start();

    var git_err: ?[]const u8 = null;
    defer if (git_err) |e| allocator.free(e);

    git.push(allocator, prompts_path, &git_err) catch {
        sp.fail();
        if (git_err) |e| {
            var buf: [4096]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}{s}git:\n{s}{s}\n", .{ P, Color.dim, std.mem.trim(u8, e, "\n\r "), Color.reset }) catch return;
            _ = raw_stdout.write(line) catch {};
        }
        return;
    };
    sp.succeed();

    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}  Message: {s}\n", .{ P, message }) catch return;
    _ = raw_stdout.write(line) catch {};
}
