const std = @import("std");
const fs = std.fs;
const commands = @import("commands.zig");
const http = @import("../http.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, hash: []const u8, force: bool) !void {
    try stdout.writeAll("\n");

    // Fetch prompts index to find prompt info by hash
    var prompts_index = http.fetchPromptsIndex(allocator) catch |err| {
        if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} Could not fetch prompts index.\n", .{ P, Color.bold, Color.red, Color.reset });
        }
        return;
    };
    defer prompts_index.deinit();

    const prompt = prompts_index.findByHash(hash) orelse {
        try stderr.print("{s}{s}{s}Error:{s} Prompt with hash '{s}{s}{s}' not found.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, hash, Color.reset });
        return;
    };

    const hash8 = prompt.hash[0..@min(8, prompt.hash.len)];

    try stdout.print("{s}Adding prompt '{s}{s}{s}' ({s})...\n\n", .{ P, Color.bold, prompt.name, Color.reset, hash8 });
    stdout.flush() catch {};

    // Fetch prompt content
    try stdout.print("{s}  {s}->{s} Fetching from registry...\n", .{ P, Color.orange, Color.reset });
    stdout.flush() catch {};

    const content = http.fetchPromptContent(allocator, prompt.hash) catch |err| {
        if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}{s}Error:{s} Prompt content not found in registry.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} Could not fetch prompt content.\n", .{ P, Color.bold, Color.red, Color.reset });
        }
        return;
    };
    defer allocator.free(content);

    // Strip frontmatter from content
    const clean_content = http.stripFrontmatter(content);

    // Destination path: .prompts/{path}
    const dest_path = try std.fs.path.join(allocator, &.{ ".prompts", prompt.path });
    defer allocator.free(dest_path);

    var cwd = fs.cwd().openDir(".", .{}) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} opening current directory: {}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };
    defer cwd.close();

    // Create parent directory if needed
    if (std.fs.path.dirname(dest_path)) |parent| {
        cwd.makePath(parent) catch {};
    }

    const result = commands.writeFile(cwd, dest_path, clean_content, force, stdout, stderr);

    try stdout.writeAll("\n");

    if (result.written) {
        try stdout.print("{s}{s}{s}+{s} Added {s}{s}{s}\n\n", .{ P, Color.bold, Color.orange, Color.reset, Color.bold, dest_path, Color.reset });
    } else if (result.skipped) {
        try stderr.print("{s}File already exists. Use {s}--force{s} to overwrite.\n\n", .{ P, Color.cyan, Color.reset });
    }
}
