const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");

const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) !void {
    if (!commands.promptsExist()) {
        try stderr.print("\n{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies init <git-url>{s} or {s}clumsies clone <git-url>{s} first\n\n", .{ P, Color.cyan, Color.reset, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    git.pull(allocator, prompts_path) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Failed to pull from remote\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

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

    try stdout.print("\n{s}{s}{s}✓{s} Pulled from remote\n\n", .{ P, Color.bold, Color.green, Color.reset });
}
