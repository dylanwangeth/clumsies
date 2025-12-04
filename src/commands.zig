const std = @import("std");
const fs = std.fs;
const http = @import("http.zig");

// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    // Zig orange (256-color mode)
    const orange = "\x1b[38;5;214m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
};

pub const Language = enum { en, zh };

pub fn printHelp(stdout: anytype) !void {
    try stdout.writeAll(
        \\clumsies - AI Agent prompts scaffolding tool
        \\
        \\USAGE:
        \\    clumsies <command> [options]
        \\
        \\COMMANDS:
        \\    search              Search available templates (remote)
        \\    detail <name>       Show template's meta-prompt file content
        \\    use <name>          Apply template to current directory
        \\    install <name>      Install a remote template
        \\
        \\SEARCH OPTIONS:
        \\    --task, -t <type>   Filter by task type
        \\    --kw, -k <keyword>  Filter by keyword
        \\
        \\USE OPTIONS:
        \\    --lang, -l <lang>   Language: 'en' or 'zh' (default: en)
        \\    --name, -n <file>   Meta-prompt file name (default: CLAUDE.md)
        \\    --force, -f         Overwrite existing files
        \\
        \\INSTALL OPTIONS:
        \\    --force, -f         Overwrite existing template
        \\    --list              List installed templates
        \\
        \\EXAMPLES:
        \\    clumsies search                      # List all templates
        \\    clumsies search --task code          # Filter by task type
        \\    clumsies search --kw react           # Filter by keyword
        \\    clumsies install solocc              # Install a template
        \\    clumsies detail solocc               # Preview meta-prompt content
        \\    clumsies use solocc                  # Apply template
        \\    clumsies use solocc -l zh -n CURSOR.md
        \\    clumsies install --list              # List installed templates
        \\
        \\VERSION:
        \\    clumsies --version
        \\
    );
}

/// Get the registry path (~/.clumsies/registry)
fn getRegistryPath(allocator: std.mem.Allocator) ![]const u8 {
    const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home_dir);
    return try std.fs.path.join(allocator, &.{ home_dir, ".clumsies", "registry" });
}

/// Search remote templates
pub fn cmdSearch(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, task_filter: ?[]const u8, keyword_filter: ?[]const u8) !void {
    // Fetch remote index
    var index = http.fetchIndex(allocator) catch |err| {
        if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ Color.bold, Color.red, Color.reset });
        } else if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}Error:{s} Registry not found. The remote registry may not be set up yet.\n", .{ Color.bold, Color.red, Color.reset });
        } else if (err == http.HttpError.InvalidResponse) {
            try stderr.print("{s}{s}Error:{s} Invalid response from registry.\n", .{ Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}Error:{s} {any}\n", .{ Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer index.deinit();

    try stdout.print("{s}{s}NAME            TASK        DESCRIPTION{s}\n", .{ Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}──────────────────────────────────────────────────────────────────{s}\n", .{ Color.dim, Color.reset });

    for (index.templates) |tmpl| {
        // Filter by task
        if (task_filter) |tf| {
            if (!std.mem.eql(u8, tmpl.task, tf)) continue;
        }

        // Filter by keyword
        if (keyword_filter) |kw| {
            var found = false;
            for (tmpl.keywords) |k| {
                if (std.mem.indexOf(u8, k, kw) != null) {
                    found = true;
                    break;
                }
            }
            if (!found and std.mem.indexOf(u8, tmpl.description, kw) != null) {
                found = true;
            }
            if (!found and std.mem.indexOf(u8, tmpl.name, kw) != null) {
                found = true;
            }
            if (!found) continue;
        }

        try stdout.print("{s: <15} {s: <11} {s}\n", .{
            tmpl.name,
            tmpl.task,
            tmpl.description,
        });
    }
}

/// Show template detail (fetch from remote)
pub fn cmdDetail(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, name: []const u8, lang: Language) !void {
    const lang_str = if (lang == .zh) "zh" else "en";

    // Build remote path: solocc/en/CLAUDE.md
    const remote_path = std.fmt.allocPrint(allocator, "{s}/{s}/CLAUDE.md", .{ name, lang_str }) catch {
        try stderr.print("{s}{s}Error:{s} Out of memory.\n", .{ Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(remote_path);

    const content = http.downloadFile(allocator, remote_path) catch |err| {
        if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}Error:{s} Template '{s}{s}{s}' not found in registry.\n", .{ Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        } else if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}Error:{s} {any}\n", .{ Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer allocator.free(content);

    try stdout.writeAll(content);
}

/// Apply template to current directory (from installed templates)
pub fn cmdUse(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, name: []const u8, lang: Language, entry_name: []const u8, force: bool) !void {
    const registry_path = getRegistryPath(allocator) catch {
        try stderr.print("{s}{s}Error:{s} Could not determine home directory.\n", .{ Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(registry_path);

    const lang_str = if (lang == .zh) "zh" else "en";
    const template_path = try std.fs.path.join(allocator, &.{ registry_path, name, lang_str });
    defer allocator.free(template_path);

    // Check if template is installed
    var template_dir = fs.openDirAbsolute(template_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("{s}{s}Error:{s} Template '{s}{s}{s}' not installed.\n", .{ Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
            try stderr.print("Run: {s}clumsies install {s}{s}\n", .{ Color.cyan, name, Color.reset });
        } else {
            try stderr.print("{s}{s}Error:{s} Could not open template: {any}\n", .{ Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer template_dir.close();

    const lang_display = if (lang == .zh) "zh (中文)" else "en (English)";
    try stdout.print("Applying template '{s}{s}{s}' [{s}]...\n\n", .{ Color.bold, name, Color.reset, lang_display });

    var cwd = fs.cwd().openDir(".", .{}) catch |err| {
        try stderr.print("Error opening current directory: {}\n", .{err});
        return;
    };
    defer cwd.close();

    var created: usize = 0;
    var skipped: usize = 0;

    // Copy CLAUDE.md as entry file
    const claude_path = try std.fs.path.join(allocator, &.{ template_path, "CLAUDE.md" });
    defer allocator.free(claude_path);

    const claude_file = fs.openFileAbsolute(claude_path, .{}) catch |err| {
        try stderr.print("{s}{s}Error:{s} Could not read CLAUDE.md: {any}\n", .{ Color.bold, Color.red, Color.reset, err });
        return;
    };
    defer claude_file.close();

    const claude_content = claude_file.readToEndAlloc(allocator, 1024 * 1024) catch {
        try stderr.print("{s}{s}Error:{s} Could not read CLAUDE.md.\n", .{ Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(claude_content);

    const entry_result = writeFile(cwd, entry_name, claude_content, force, stdout, stderr);
    if (entry_result.written) created += 1;
    if (entry_result.skipped) skipped += 1;

    // Copy prompts/ directory
    const prompts_path = try std.fs.path.join(allocator, &.{ template_path, "prompts" });
    defer allocator.free(prompts_path);

    var prompts_dir = fs.openDirAbsolute(prompts_path, .{ .iterate = true }) catch {
        // No prompts directory, that's ok
        try stdout.print("\n{s}{s}✓{s} Done! Created {s}{d}{s} files", .{ Color.bold, Color.orange, Color.reset, Color.bold, created, Color.reset });
        if (skipped > 0) try stdout.print(", skipped {d} files", .{skipped});
        try stdout.writeAll("\n");
        return;
    };
    defer prompts_dir.close();

    // Walk prompts directory
    var walker = try prompts_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const dest_path = try std.fs.path.join(allocator, &.{ "prompts", entry.path });
        defer allocator.free(dest_path);

        // Create parent directories
        if (std.fs.path.dirname(dest_path)) |parent| {
            cwd.makePath(parent) catch {};
        }

        // Read source file
        const src_path = try std.fs.path.join(allocator, &.{ prompts_path, entry.path });
        defer allocator.free(src_path);

        const src_file = fs.openFileAbsolute(src_path, .{}) catch continue;
        defer src_file.close();

        const content = src_file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(content);

        const result = writeFile(cwd, dest_path, content, force, stdout, stderr);
        if (result.written) created += 1;
        if (result.skipped) skipped += 1;
    }

    try stdout.print("\n{s}{s}✓{s} Done! Created {s}{d}{s} files", .{ Color.bold, Color.orange, Color.reset, Color.bold, created, Color.reset });
    if (skipped > 0) try stdout.print(", skipped {d} files", .{skipped});
    try stdout.writeAll("\n");
}

/// Install a template from remote registry
pub fn cmdInstall(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, template_name: ?[]const u8, list: bool, force: bool) !void {
    const registry_path = getRegistryPath(allocator) catch {
        try stderr.print("{s}{s}Error:{s} Could not determine home directory.\n", .{ Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(registry_path);

    if (list) {
        try listInstalledTemplates(stdout, registry_path);
        return;
    }

    const name = template_name orelse {
        try stderr.print("{s}{s}Error:{s} template name required\nUsage: {s}clumsies install <name>{s}\n", .{ Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        return;
    };

    const template_install_path = try std.fs.path.join(allocator, &.{ registry_path, name });
    defer allocator.free(template_install_path);

    try stdout.print("Installing template '{s}{s}{s}'...\n\n", .{ Color.bold, name, Color.reset });

    // Check if already exists
    const exists = blk: {
        fs.accessAbsolute(template_install_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (exists) {
        if (force) {
            try stdout.print("  {s}→{s} Removing existing template...\n", .{ Color.orange, Color.reset });
            fs.deleteTreeAbsolute(template_install_path) catch |err| {
                try stderr.print("{s}{s}Error:{s} removing existing template: {any}\n", .{ Color.bold, Color.red, Color.reset, err });
                return;
            };
        } else {
            try stderr.print("{s}{s}Error:{s} template '{s}{s}{s}' already installed. Use {s}--force{s} to overwrite.\n", .{ Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset, Color.cyan, Color.reset });
            return;
        }
    }

    // Create registry directory
    fs.cwd().makePath(registry_path) catch |err| {
        try stderr.print("{s}{s}Error:{s} creating registry directory: {any}\n", .{ Color.bold, Color.red, Color.reset, err });
        return;
    };

    // Get list of files from GitHub API
    try stdout.print("  {s}→{s} Fetching file list from registry...\n", .{ Color.orange, Color.reset });
    var files = http.listTemplateFiles(allocator, name) catch |err| {
        if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}Error:{s} template '{s}{s}{s}' not found in registry.\n", .{ Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        } else if (err == http.HttpError.RateLimited) {
            try stderr.print("{s}{s}Error:{s} GitHub API rate limit exceeded. Try again later.\n", .{ Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}Error:{s} fetching template files: {any}\n", .{ Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer files.deinit();

    if (files.items.len == 0) {
        try stderr.print("{s}{s}Error:{s} template '{s}{s}{s}' not found in registry.\n", .{ Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        return;
    }

    // Download and save each file
    var downloaded: usize = 0;
    var failed: usize = 0;

    for (files.items) |remote_path| {
        const prefix_len = name.len + 1;
        if (remote_path.len <= prefix_len) continue;
        const local_relative = remote_path[prefix_len..];

        const local_path = try std.fs.path.join(allocator, &.{ template_install_path, local_relative });
        defer allocator.free(local_path);

        // Create parent directories
        if (std.fs.path.dirname(local_path)) |parent| {
            fs.cwd().makePath(parent) catch {};
        }

        // Download file
        const content = http.downloadFile(allocator, remote_path) catch |err| {
            if (err == http.HttpError.NotFound) {
                try stderr.print("  {s}{s}✗{s} Not found: {s}\n", .{ Color.bold, Color.red, Color.reset, local_relative });
            } else {
                try stderr.print("  {s}{s}✗{s} Failed: {s}\n", .{ Color.bold, Color.red, Color.reset, local_relative });
            }
            failed += 1;
            continue;
        };
        defer allocator.free(content);

        // Write file
        const file = fs.createFileAbsolute(local_path, .{}) catch {
            try stderr.print("  {s}{s}✗{s} Cannot write: {s}\n", .{ Color.bold, Color.red, Color.reset, local_relative });
            failed += 1;
            continue;
        };
        defer file.close();

        file.writeAll(content) catch {
            try stderr.print("  {s}{s}✗{s} Write error: {s}\n", .{ Color.bold, Color.red, Color.reset, local_relative });
            failed += 1;
            continue;
        };

        try stdout.print("  {s}→{s} {s}\n", .{ Color.orange, Color.reset, local_relative });
        downloaded += 1;
    }

    try stdout.writeAll("\n");

    if (failed > 0) {
        try stderr.print("{s}{s}Warning:{s} {d} files failed to download.\n", .{ Color.bold, Color.orange, Color.reset, failed });
    }

    if (downloaded > 0) {
        try stdout.print("{s}{s}✓{s} Installed {s}{d}{s} files to {s}{s}{s}\n", .{ Color.bold, Color.orange, Color.reset, Color.bold, downloaded, Color.reset, Color.orange, template_install_path, Color.reset });
    } else {
        try stderr.print("{s}{s}Error:{s} No files were installed.\n", .{ Color.bold, Color.red, Color.reset });
    }
}

fn listInstalledTemplates(stdout: anytype, registry_path: []const u8) !void {
    try stdout.print("{s}{s}Installed templates:{s}\n", .{ Color.bold, Color.orange, Color.reset });

    var registry_dir = fs.openDirAbsolute(registry_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.print("  {s}(none){s}\n", .{ Color.dim, Color.reset });
            return;
        }
        return err;
    };
    defer registry_dir.close();

    var it = registry_dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            try stdout.print("  {s}•{s} {s}{s}{s}\n", .{ Color.green, Color.reset, Color.bold, entry.name, Color.reset });
            count += 1;
        }
    }

    if (count == 0) {
        try stdout.print("  {s}(none){s}\n", .{ Color.dim, Color.reset });
    }
}

const WriteResult = struct {
    written: bool,
    skipped: bool,
};

fn writeFile(dir: fs.Dir, path: []const u8, content: []const u8, force: bool, stdout: anytype, stderr: anytype) WriteResult {
    const file_exists = blk: {
        dir.access(path, .{}) catch |err| {
            if (err == error.FileNotFound) break :blk false;
            break :blk true;
        };
        break :blk true;
    };

    if (file_exists and !force) {
        stdout.print("  {s}skip:{s} {s} {s}(exists, use --force){s}\n", .{ Color.dim, Color.reset, path, Color.dim, Color.reset }) catch {};
        return .{ .written = false, .skipped = true };
    }

    const file = dir.createFile(path, .{}) catch |err| {
        stderr.print("{s}{s}Error:{s} creating file '{s}': {}\n", .{ Color.bold, Color.red, Color.reset, path, err }) catch {};
        return .{ .written = false, .skipped = false };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        stderr.print("{s}{s}Error:{s} writing file '{s}': {}\n", .{ Color.bold, Color.red, Color.reset, path, err }) catch {};
        return .{ .written = false, .skipped = false };
    };

    if (file_exists) {
        stdout.print("  {s}{s}overwrite:{s} {s}\n", .{ Color.bold, Color.orange, Color.reset, path }) catch {};
    } else {
        stdout.print("  {s}{s}create:{s} {s}\n", .{ Color.bold, Color.orange, Color.reset, path }) catch {};
    }

    return .{ .written = true, .skipped = false };
}
