const std = @import("std");
const fs = std.fs;
const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;
const Language = commands.Language;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, name: []const u8, lang: Language, entry_name: []const u8, force: bool) !void {
    try stdout.writeAll("\n");

    const registry_path = commands.getRegistryPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine home directory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(registry_path);

    const lang_str = if (lang == .zh) "zh" else "en";
    const template_path = try std.fs.path.join(allocator, &.{ registry_path, name, lang_str });
    defer allocator.free(template_path);

    var template_dir = fs.openDirAbsolute(template_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("{s}{s}{s}Error:{s} Template '{s}{s}{s}' not installed.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
            try stderr.print("{s}Run: {s}clumsies install {s}{s}\n", .{ P, Color.cyan, name, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} Could not open template: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer template_dir.close();

    const lang_display = if (lang == .zh) "zh (中文)" else "en (English)";
    try stdout.print("{s}Applying template '{s}{s}{s}' [{s}]...\n\n", .{ P, Color.bold, name, Color.reset, lang_display });

    var cwd = fs.cwd().openDir(".", .{}) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} opening current directory: {}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };
    defer cwd.close();

    var created: usize = 0;
    var skipped: usize = 0;

    // Copy CLAUDE.md as entry file
    const claude_path = try std.fs.path.join(allocator, &.{ template_path, "CLAUDE.md" });
    defer allocator.free(claude_path);

    const claude_file = fs.openFileAbsolute(claude_path, .{}) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} Could not read CLAUDE.md: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };
    defer claude_file.close();

    const claude_content = claude_file.readToEndAlloc(allocator, 1024 * 1024) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not read CLAUDE.md.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(claude_content);

    const entry_result = commands.writeFile(cwd, entry_name, claude_content, force, stdout, stderr);
    if (entry_result.written) created += 1;
    if (entry_result.skipped) skipped += 1;

    // Copy .prompts/ directory
    const prompts_path = try std.fs.path.join(allocator, &.{ template_path, ".prompts" });
    defer allocator.free(prompts_path);

    var prompts_dir = fs.openDirAbsolute(prompts_path, .{ .iterate = true }) catch {
        try stdout.print("\n{s}{s}{s}✓{s} Done! Created {s}{d}{s} files", .{ P, Color.bold, Color.orange, Color.reset, Color.bold, created, Color.reset });
        if (skipped > 0) try stdout.print(", skipped {d} files", .{skipped});
        try stdout.writeAll("\n\n");
        return;
    };
    defer prompts_dir.close();

    var walker = try prompts_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const dest_path = try std.fs.path.join(allocator, &.{ ".prompts", entry.path });
        defer allocator.free(dest_path);

        if (std.fs.path.dirname(dest_path)) |parent| {
            cwd.makePath(parent) catch {};
        }

        const src_path = try std.fs.path.join(allocator, &.{ prompts_path, entry.path });
        defer allocator.free(src_path);

        const src_file = fs.openFileAbsolute(src_path, .{}) catch continue;
        defer src_file.close();

        const content = src_file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(content);

        const result = commands.writeFile(cwd, dest_path, content, force, stdout, stderr);
        if (result.written) created += 1;
        if (result.skipped) skipped += 1;
    }

    try stdout.print("\n{s}{s}{s}✓{s} Done! Created {s}{d}{s} files", .{ P, Color.bold, Color.orange, Color.reset, Color.bold, created, Color.reset });
    if (skipped > 0) try stdout.print(", skipped {d} files", .{skipped});
    try stdout.writeAll("\n\n");
}
