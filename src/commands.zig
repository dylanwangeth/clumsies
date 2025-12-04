const std = @import("std");
const fs = std.fs;
const http = @import("http.zig");

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
            try stderr.writeAll("Error: Failed to connect to registry. Check your network.\n");
        } else if (err == http.HttpError.NotFound) {
            try stderr.writeAll("Error: Registry not found. The remote registry may not be set up yet.\n");
        } else if (err == http.HttpError.InvalidResponse) {
            try stderr.writeAll("Error: Invalid response from registry.\n");
        } else {
            try stderr.print("Error: {any}\n", .{err});
        }
        return;
    };
    defer index.deinit();

    try stdout.writeAll("NAME            TASK        DESCRIPTION\n");
    try stdout.writeAll("──────────────────────────────────────────────────────────────────\n");

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
        try stderr.writeAll("Error: Out of memory.\n");
        return;
    };
    defer allocator.free(remote_path);

    const content = http.downloadFile(allocator, remote_path) catch |err| {
        if (err == http.HttpError.NotFound) {
            try stderr.print("Error: Template '{s}' not found in registry.\n", .{name});
        } else if (err == http.HttpError.RequestFailed) {
            try stderr.writeAll("Error: Failed to connect to registry. Check your network.\n");
        } else {
            try stderr.print("Error: {any}\n", .{err});
        }
        return;
    };
    defer allocator.free(content);

    try stdout.writeAll(content);
}

/// Apply template to current directory (from installed templates)
pub fn cmdUse(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, name: []const u8, lang: Language, entry_name: []const u8, force: bool) !void {
    const registry_path = getRegistryPath(allocator) catch {
        try stderr.writeAll("Error: Could not determine home directory.\n");
        return;
    };
    defer allocator.free(registry_path);

    const lang_str = if (lang == .zh) "zh" else "en";
    const template_path = try std.fs.path.join(allocator, &.{ registry_path, name, lang_str });
    defer allocator.free(template_path);

    // Check if template is installed
    var template_dir = fs.openDirAbsolute(template_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("Error: Template '{s}' not installed.\n", .{name});
            try stderr.print("Run: clumsies install {s}\n", .{name});
        } else {
            try stderr.print("Error: Could not open template: {any}\n", .{err});
        }
        return;
    };
    defer template_dir.close();

    const lang_display = if (lang == .zh) "zh (中文)" else "en (English)";
    try stdout.print("Applying template '{s}' [{s}]...\n\n", .{ name, lang_display });

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
        try stderr.print("Error: Could not read CLAUDE.md: {any}\n", .{err});
        return;
    };
    defer claude_file.close();

    const claude_content = claude_file.readToEndAlloc(allocator, 1024 * 1024) catch {
        try stderr.writeAll("Error: Could not read CLAUDE.md.\n");
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
        try stdout.print("\nDone! Created {d} files", .{created});
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

    try stdout.print("\nDone! Created {d} files", .{created});
    if (skipped > 0) try stdout.print(", skipped {d} files", .{skipped});
    try stdout.writeAll("\n");
}

/// Install a template from remote registry
pub fn cmdInstall(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, template_name: ?[]const u8, list: bool, force: bool) !void {
    const registry_path = getRegistryPath(allocator) catch {
        try stderr.writeAll("Error: Could not determine home directory.\n");
        return;
    };
    defer allocator.free(registry_path);

    if (list) {
        try listInstalledTemplates(stdout, registry_path);
        return;
    }

    const name = template_name orelse {
        try stderr.writeAll("Error: template name required\nUsage: clumsies install <name>\n");
        return;
    };

    const template_install_path = try std.fs.path.join(allocator, &.{ registry_path, name });
    defer allocator.free(template_install_path);

    try stdout.print("Installing template '{s}'...\n\n", .{name});

    // Check if already exists
    const exists = blk: {
        fs.accessAbsolute(template_install_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (exists) {
        if (force) {
            try stdout.writeAll("  → Removing existing template...\n");
            fs.deleteTreeAbsolute(template_install_path) catch |err| {
                try stderr.print("Error removing existing template: {any}\n", .{err});
                return;
            };
        } else {
            try stderr.print("Error: template '{s}' already installed. Use --force to overwrite.\n", .{name});
            return;
        }
    }

    // Create registry directory
    fs.cwd().makePath(registry_path) catch |err| {
        try stderr.print("Error creating registry directory: {any}\n", .{err});
        return;
    };

    // Get list of files from GitHub API
    try stdout.writeAll("  → Fetching file list from registry...\n");
    var files = http.listTemplateFiles(allocator, name) catch |err| {
        if (err == http.HttpError.NotFound) {
            try stderr.print("Error: template '{s}' not found in registry.\n", .{name});
        } else if (err == http.HttpError.RateLimited) {
            try stderr.writeAll("Error: GitHub API rate limit exceeded. Try again later.\n");
        } else {
            try stderr.print("Error fetching template files: {any}\n", .{err});
        }
        return;
    };
    defer files.deinit();

    if (files.items.len == 0) {
        try stderr.print("Error: template '{s}' not found in registry.\n", .{name});
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
                try stderr.print("  ✗ Not found: {s}\n", .{local_relative});
            } else {
                try stderr.print("  ✗ Failed: {s}\n", .{local_relative});
            }
            failed += 1;
            continue;
        };
        defer allocator.free(content);

        // Write file
        const file = fs.createFileAbsolute(local_path, .{}) catch {
            try stderr.print("  ✗ Cannot write: {s}\n", .{local_relative});
            failed += 1;
            continue;
        };
        defer file.close();

        file.writeAll(content) catch {
            try stderr.print("  ✗ Write error: {s}\n", .{local_relative});
            failed += 1;
            continue;
        };

        try stdout.print("  → {s}\n", .{local_relative});
        downloaded += 1;
    }

    try stdout.writeAll("\n");

    if (failed > 0) {
        try stderr.print("Warning: {d} files failed to download.\n", .{failed});
    }

    if (downloaded > 0) {
        try stdout.print("✓ Installed {d} files to {s}\n", .{ downloaded, template_install_path });
    } else {
        try stderr.writeAll("Error: No files were installed.\n");
    }
}

fn listInstalledTemplates(stdout: anytype, registry_path: []const u8) !void {
    try stdout.writeAll("Installed templates:\n");

    var registry_dir = fs.openDirAbsolute(registry_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.writeAll("  (none)\n");
            return;
        }
        return err;
    };
    defer registry_dir.close();

    var it = registry_dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            try stdout.print("  - {s}\n", .{entry.name});
            count += 1;
        }
    }

    if (count == 0) {
        try stdout.writeAll("  (none)\n");
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
        stdout.print("  skip: {s} (exists, use --force to overwrite)\n", .{path}) catch {};
        return .{ .written = false, .skipped = true };
    }

    const file = dir.createFile(path, .{}) catch |err| {
        stderr.print("Error creating file '{s}': {}\n", .{ path, err }) catch {};
        return .{ .written = false, .skipped = false };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        stderr.print("Error writing file '{s}': {}\n", .{ path, err }) catch {};
        return .{ .written = false, .skipped = false };
    };

    if (file_exists) {
        stdout.print("  overwrite: {s}\n", .{path}) catch {};
    } else {
        stdout.print("  create: {s}\n", .{path}) catch {};
    }

    return .{ .written = true, .skipped = false };
}
