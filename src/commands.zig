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

// Left padding for all output
const P = "  ";

pub const Language = enum { en, zh };

pub fn printHelp(stdout: anytype) !void {
    try stdout.print("\n{s}{s}{s}clumsies{s} - AI Agent prompts scaffolding tool\n\n", .{ P, Color.bold, Color.orange, Color.reset });

    try stdout.print("{s}{s}{s}USAGE:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    clumsies <command> [options]\n\n", .{P});

    try stdout.print("{s}{s}{s}COMMANDS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}search{s}              Search available templates (remote)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}detail{s} <name>       Show template's meta-prompt file content\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}use{s} <name>          Apply template to current directory\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}install{s} <name>      Install a remote template\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}SEARCH OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}--task, -t{s} <type>   Filter by task type\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--kw, -k{s} <keyword>  Filter by keyword\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}USE OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}--lang, -l{s} <lang>   Language: 'en' or 'zh' (default: en)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--name, -n{s} <file>   Meta-prompt file name (default: CLAUDE.md)\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--force, -f{s}         Overwrite existing files\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}INSTALL OPTIONS:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}--force, -f{s}         Overwrite existing template\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}--list{s}              List installed templates\n\n", .{ P, Color.cyan, Color.reset });

    try stdout.print("{s}{s}{s}EXAMPLES:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies search{s}                      {s}# List all templates{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies search --task code{s}          {s}# Filter by task type{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies search --kw react{s}           {s}# Filter by keyword{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies install solocc{s}              {s}# Install a template{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies detail solocc{s}               {s}# Preview meta-prompt{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies use solocc{s}                  {s}# Apply template{s}\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}    {s}clumsies use solocc -l zh -n CURSOR.md{s}\n", .{ P, Color.cyan, Color.reset });
    try stdout.print("{s}    {s}clumsies install --list{s}              {s}# List installed{s}\n\n", .{ P, Color.cyan, Color.reset, Color.dim, Color.reset });

    try stdout.print("{s}{s}{s}VERSION:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}    {s}clumsies --version{s}\n\n", .{ P, Color.cyan, Color.reset });
}

/// Get the registry path (~/.clumsies/registry)
fn getRegistryPath(allocator: std.mem.Allocator) ![]const u8 {
    const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home_dir);
    return try std.fs.path.join(allocator, &.{ home_dir, ".clumsies", "registry" });
}

/// Search remote templates
pub fn cmdSearch(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, task_filter: ?[]const u8, keyword_filter: ?[]const u8) !void {
    try stdout.writeAll("\n");

    // Fetch remote index
    var index = http.fetchIndex(allocator) catch |err| {
        if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}{s}Error:{s} Registry not found. The remote registry may not be set up yet.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else if (err == http.HttpError.InvalidResponse) {
            try stderr.print("{s}{s}{s}Error:{s} Invalid response from registry.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer index.deinit();

    try stdout.print("{s}{s}{s}NAME            TASK        DESCRIPTION{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}──────────────────────────────────────────────────────────────────{s}\n", .{ P, Color.dim, Color.reset });

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

        try stdout.print("{s}{s: <15} {s: <11} {s}\n", .{
            P,
            tmpl.name,
            tmpl.task,
            tmpl.description,
        });
    }

    try stdout.writeAll("\n");
}

/// Show template detail (fetch from remote)
pub fn cmdDetail(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, name: []const u8, lang: Language) !void {
    const lang_str = if (lang == .zh) "zh" else "en";

    // Build remote path: solocc/en/CLAUDE.md
    const remote_path = std.fmt.allocPrint(allocator, "{s}/{s}/CLAUDE.md", .{ name, lang_str }) catch {
        try stderr.print("{s}{s}{s}Error:{s} Out of memory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(remote_path);

    const content = http.downloadFile(allocator, remote_path) catch |err| {
        if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}{s}Error:{s} Template '{s}{s}{s}' not found in registry.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        } else if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer allocator.free(content);

    const lang_display = if (lang == .zh) "zh" else "en";
    try stdout.print("\n{s}{s}{s}Template:{s} {s} [{s}]\n", .{ P, Color.bold, Color.orange, Color.reset, name, lang_display });
    try stdout.print("{s}{s}────────────────────────────────────────────────────────────────{s}\n", .{ P, Color.orange, Color.reset });

    // Print content with left padding for each line
    var line_start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            try stdout.writeAll(P);
            try stdout.writeAll(content[line_start..i]);
            try stdout.writeAll("\n");
            line_start = i + 1;
        }
    }
    // Print remaining content if no trailing newline
    if (line_start < content.len) {
        try stdout.writeAll(P);
        try stdout.writeAll(content[line_start..]);
        try stdout.writeAll("\n");
    }

    try stdout.print("{s}{s}────────────────────────────────────────────────────────────────{s}\n\n", .{ P, Color.orange, Color.reset });
}

/// Apply template to current directory (from installed templates)
pub fn cmdUse(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, name: []const u8, lang: Language, entry_name: []const u8, force: bool) !void {
    try stdout.writeAll("\n");

    const registry_path = getRegistryPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine home directory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(registry_path);

    const lang_str = if (lang == .zh) "zh" else "en";
    const template_path = try std.fs.path.join(allocator, &.{ registry_path, name, lang_str });
    defer allocator.free(template_path);

    // Check if template is installed
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

    const entry_result = writeFile(cwd, entry_name, claude_content, force, stdout, stderr);
    if (entry_result.written) created += 1;
    if (entry_result.skipped) skipped += 1;

    // Copy prompts/ directory
    const prompts_path = try std.fs.path.join(allocator, &.{ template_path, "prompts" });
    defer allocator.free(prompts_path);

    var prompts_dir = fs.openDirAbsolute(prompts_path, .{ .iterate = true }) catch {
        // No prompts directory, that's ok
        try stdout.print("\n{s}{s}{s}✓{s} Done! Created {s}{d}{s} files", .{ P, Color.bold, Color.orange, Color.reset, Color.bold, created, Color.reset });
        if (skipped > 0) try stdout.print(", skipped {d} files", .{skipped});
        try stdout.writeAll("\n\n");
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

    try stdout.print("\n{s}{s}{s}✓{s} Done! Created {s}{d}{s} files", .{ P, Color.bold, Color.orange, Color.reset, Color.bold, created, Color.reset });
    if (skipped > 0) try stdout.print(", skipped {d} files", .{skipped});
    try stdout.writeAll("\n\n");
}

/// Install a template from remote registry
pub fn cmdInstall(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, template_name: ?[]const u8, list: bool, force: bool) !void {
    const registry_path = getRegistryPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine home directory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(registry_path);

    if (list) {
        try stdout.writeAll("\n");
        try listInstalledTemplates(stdout, registry_path);
        try stdout.writeAll("\n");
        return;
    }

    const name = template_name orelse {
        try stderr.print("\n{s}{s}{s}Error:{s} template name required\n{s}Usage: {s}clumsies install <name>{s}\n\n", .{ P, Color.bold, Color.red, Color.reset, P, Color.cyan, Color.reset });
        return;
    };

    const template_install_path = try std.fs.path.join(allocator, &.{ registry_path, name });
    defer allocator.free(template_install_path);

    // Check if already exists
    const exists = blk: {
        fs.accessAbsolute(template_install_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (exists and !force) {
        try stderr.print("\n{s}{s}{s}Error:{s} template '{s}{s}{s}' already installed. Use {s}--force{s} to overwrite.\n\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset, Color.cyan, Color.reset });
        return;
    }

    try stdout.print("\n{s}Installing template '{s}{s}{s}'...\n\n", .{ P, Color.bold, name, Color.reset });
    stdout.flush() catch {};

    if (exists) {
        try stdout.print("{s}  {s}→{s} Removing existing template...\n", .{ P, Color.orange, Color.reset });
        fs.deleteTreeAbsolute(template_install_path) catch |err| {
            try stderr.print("{s}{s}{s}Error:{s} removing existing template: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
            return;
        };
    }

    // Create registry directory
    fs.cwd().makePath(registry_path) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} creating registry directory: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };

    // Fetch index to get file list
    try stdout.print("{s}  {s}→{s} Fetching template info...\n", .{ P, Color.orange, Color.reset });
    stdout.flush() catch {};

    var index = http.fetchIndex(allocator) catch |err| {
        if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} fetching template index: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer index.deinit();

    // Find the template in index
    var template_files: ?[][]const u8 = null;
    for (index.templates) |tmpl| {
        if (std.mem.eql(u8, tmpl.name, name)) {
            template_files = tmpl.files;
            break;
        }
    }

    const files = template_files orelse {
        try stderr.print("{s}{s}{s}Error:{s} template '{s}{s}{s}' not found in registry.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        return;
    };

    if (files.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} template '{s}{s}{s}' has no files.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        return;
    }

    // Download and save each file
    var downloaded: usize = 0;
    var failed: usize = 0;

    for (files) |file_path| {
        // file_path is relative to template dir, e.g. "en/CLAUDE.md"
        const remote_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, file_path }) catch continue;
        defer allocator.free(remote_path);

        const local_relative = file_path;

        const local_path = try std.fs.path.join(allocator, &.{ template_install_path, local_relative });
        defer allocator.free(local_path);

        // Create parent directories
        if (std.fs.path.dirname(local_path)) |parent| {
            fs.cwd().makePath(parent) catch {};
        }

        // Download file
        const content = http.downloadFile(allocator, remote_path) catch |err| {
            if (err == http.HttpError.NotFound) {
                try stderr.print("{s}  {s}{s}✗{s} Not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, local_relative });
            } else {
                try stderr.print("{s}  {s}{s}✗{s} Failed: {s}\n", .{ P, Color.bold, Color.red, Color.reset, local_relative });
            }
            failed += 1;
            continue;
        };
        defer allocator.free(content);

        // Write file
        const file = fs.createFileAbsolute(local_path, .{}) catch {
            try stderr.print("{s}  {s}{s}✗{s} Cannot write: {s}\n", .{ P, Color.bold, Color.red, Color.reset, local_relative });
            failed += 1;
            continue;
        };
        defer file.close();

        file.writeAll(content) catch {
            try stderr.print("{s}  {s}{s}✗{s} Write error: {s}\n", .{ P, Color.bold, Color.red, Color.reset, local_relative });
            failed += 1;
            continue;
        };

        try stdout.print("{s}  {s}→{s} {s}\n", .{ P, Color.orange, Color.reset, local_relative });
        downloaded += 1;
    }

    try stdout.writeAll("\n");

    if (failed > 0) {
        try stderr.print("{s}{s}{s}Warning:{s} {d} files failed to download.\n", .{ P, Color.bold, Color.orange, Color.reset, failed });
    }

    if (downloaded > 0) {
        try stdout.print("{s}{s}{s}✓{s} Installed {s}{d}{s} files to {s}{s}{s}\n\n", .{ P, Color.bold, Color.orange, Color.reset, Color.bold, downloaded, Color.reset, Color.orange, template_install_path, Color.reset });
    } else {
        try stderr.print("{s}{s}{s}Error:{s} No files were installed.\n\n", .{ P, Color.bold, Color.red, Color.reset });
    }
}

fn listInstalledTemplates(stdout: anytype, registry_path: []const u8) !void {
    try stdout.print("{s}{s}{s}Installed templates:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });

    var registry_dir = fs.openDirAbsolute(registry_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.print("{s}  {s}(none){s}\n", .{ P, Color.dim, Color.reset });
            return;
        }
        return err;
    };
    defer registry_dir.close();

    var it = registry_dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            try stdout.print("{s}  {s}•{s} {s}{s}{s}\n", .{ P, Color.green, Color.reset, Color.bold, entry.name, Color.reset });
            count += 1;
        }
    }

    if (count == 0) {
        try stdout.print("{s}  {s}(none){s}\n", .{ P, Color.dim, Color.reset });
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
        stdout.print("{s}  {s}skip:{s} {s} {s}(exists, use --force){s}\n", .{ P, Color.dim, Color.reset, path, Color.dim, Color.reset }) catch {};
        return .{ .written = false, .skipped = true };
    }

    const file = dir.createFile(path, .{}) catch |err| {
        stderr.print("{s}{s}{s}Error:{s} creating file '{s}': {}\n", .{ P, Color.bold, Color.red, Color.reset, path, err }) catch {};
        return .{ .written = false, .skipped = false };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        stderr.print("{s}{s}{s}Error:{s} writing file '{s}': {}\n", .{ P, Color.bold, Color.red, Color.reset, path, err }) catch {};
        return .{ .written = false, .skipped = false };
    };

    if (file_exists) {
        stdout.print("{s}  {s}{s}overwrite:{s} {s}\n", .{ P, Color.bold, Color.orange, Color.reset, path }) catch {};
    } else {
        stdout.print("{s}  {s}{s}create:{s} {s}\n", .{ P, Color.bold, Color.orange, Color.reset, path }) catch {};
    }

    return .{ .written = true, .skipped = false };
}
