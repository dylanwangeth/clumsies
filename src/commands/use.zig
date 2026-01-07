const std = @import("std");
const fs = std.fs;
const commands = @import("commands.zig");
const http = @import("../http.zig");
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

    const template_path = try std.fs.path.join(allocator, &.{ registry_path, name });
    defer allocator.free(template_path);

    // Check if template exists
    fs.accessAbsolute(template_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Template '{s}{s}{s}' not installed.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        try stderr.print("{s}Run: {s}clumsies install {s}{s}\n", .{ P, Color.cyan, name, Color.reset });
        return;
    };

    // Read meta.json
    const meta_path = try std.fs.path.join(allocator, &.{ template_path, "meta.json" });
    defer allocator.free(meta_path);

    const meta_file = fs.openFileAbsolute(meta_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not read template meta.json.\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Try reinstalling: {s}clumsies install {s} --force{s}\n", .{ P, Color.cyan, name, Color.reset });
        return;
    };
    defer meta_file.close();

    const meta_content = meta_file.readToEndAlloc(allocator, 1024 * 1024) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not read meta.json.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(meta_content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, meta_content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Invalid meta.json format.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const lang_str = if (lang == .zh) "zh" else "en";
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
    const claude_path = try std.fs.path.join(allocator, &.{ template_path, lang_str, "CLAUDE.md" });
    defer allocator.free(claude_path);

    const claude_file = fs.openFileAbsolute(claude_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not read CLAUDE.md for language '{s}'.\n", .{ P, Color.bold, Color.red, Color.reset, lang_str });
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

    // Get prompt hashes for the selected language
    var prompt_hashes: std.ArrayListUnmanaged([]const u8) = .{};
    defer prompt_hashes.deinit(allocator);

    if (parsed.value.object.get("prompts")) |prompts_obj| {
        if (prompts_obj.object.get(lang_str)) |lang_prompts| {
            for (lang_prompts.array.items) |hash_val| {
                prompt_hashes.append(allocator, hash_val.string) catch continue;
            }
        }
    }

    // Process each prompt
    for (prompt_hashes.items) |hash| {
        const prompt_filename = std.fmt.allocPrint(allocator, "{s}.md", .{hash}) catch continue;
        defer allocator.free(prompt_filename);

        const prompt_path = try std.fs.path.join(allocator, &.{ template_path, "prompts", prompt_filename });
        defer allocator.free(prompt_path);

        const prompt_file = fs.openFileAbsolute(prompt_path, .{}) catch {
            try stderr.print("{s}  {s}{s}✗{s} Missing prompt: {s}\n", .{ P, Color.bold, Color.red, Color.reset, hash[0..@min(8, hash.len)] });
            continue;
        };
        defer prompt_file.close();

        const prompt_content = prompt_file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(prompt_content);

        // Extract path from frontmatter
        const dest_path = extractPathFromFrontmatter(allocator, prompt_content) orelse {
            try stderr.print("{s}  {s}{s}✗{s} No path in prompt: {s}\n", .{ P, Color.bold, Color.red, Color.reset, hash[0..@min(8, hash.len)] });
            continue;
        };
        defer allocator.free(dest_path);

        // Strip frontmatter from content
        const clean_content = http.stripFrontmatter(prompt_content);

        // Write to .prompts/{path}
        const full_dest_path = try std.fs.path.join(allocator, &.{ ".prompts", dest_path });
        defer allocator.free(full_dest_path);

        if (std.fs.path.dirname(full_dest_path)) |parent| {
            cwd.makePath(parent) catch {};
        }

        const result = commands.writeFile(cwd, full_dest_path, clean_content, force, stdout, stderr);
        if (result.written) created += 1;
        if (result.skipped) skipped += 1;
    }

    try stdout.print("\n{s}{s}{s}✓{s} Done! Created {s}{d}{s} files", .{ P, Color.bold, Color.orange, Color.reset, Color.bold, created, Color.reset });
    if (skipped > 0) try stdout.print(", skipped {d} files", .{skipped});
    try stdout.writeAll("\n\n");
}

/// Extract path from YAML frontmatter
fn extractPathFromFrontmatter(allocator: std.mem.Allocator, content: []const u8) ?[]const u8 {
    if (content.len < 4) return null;
    if (!std.mem.startsWith(u8, content, "---")) return null;

    // Find the end of frontmatter
    var end_idx: usize = 3;
    while (end_idx < content.len) {
        if (content[end_idx] == '\n') {
            const remaining = content[end_idx + 1 ..];
            if (std.mem.startsWith(u8, remaining, "---")) {
                break;
            }
        }
        end_idx += 1;
    }

    const frontmatter = content[4..end_idx];

    // Simple YAML parsing for "path: value"
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "path:")) {
            const value = std.mem.trim(u8, trimmed[5..], " \t\r");
            return allocator.dupe(u8, value) catch null;
        }
    }

    return null;
}
