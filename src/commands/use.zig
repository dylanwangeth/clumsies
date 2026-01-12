const std = @import("std");
const fs = std.fs;
const commands = @import("commands.zig");
const http = @import("../http.zig");
const spinner = @import("../spinner.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, hash: []const u8, lang: []const u8, entry_name: []const u8, force: bool) !void {
    try stdout.writeAll("\n");

    // Fetch templates index to find template info by hash
    var sp = spinner.init(stdout, "Fetching template info");
    sp.start();

    var templates_index = http.fetchTemplatesIndex(allocator) catch |err| {
        sp.fail();
        if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} Could not fetch templates index.\n", .{ P, Color.bold, Color.red, Color.reset });
        }
        return;
    };
    defer templates_index.deinit();

    sp.succeed();

    const tmpl = templates_index.findByHash(hash) orelse {
        try stderr.print("{s}{s}{s}Error:{s} Template with hash '{s}{s}{s}' not found.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, hash, Color.reset });
        return;
    };

    // Use first 8 chars of hash as directory name
    const hash8 = tmpl.hash[0..@min(8, tmpl.hash.len)];

    const templates_path = commands.getTemplatesPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine home directory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(templates_path);

    const prompts_path = commands.getPromptsPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine home directory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompts_path);

    const template_path = try std.fs.path.join(allocator, &.{ templates_path, hash8 });
    defer allocator.free(template_path);

    // Check if template exists locally, if not, download it
    const template_exists = blk: {
        fs.accessAbsolute(template_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!template_exists) {
        try stdout.print("{s}Template not cached locally, downloading...\n\n", .{P});
        stdout.flush() catch {};

        // Download template (integrated from install logic)
        try downloadTemplate(stdout, stderr, allocator, tmpl, templates_path, prompts_path, template_path);
    }

    // Now apply the template
    try applyTemplate(stdout, stderr, allocator, tmpl, template_path, prompts_path, lang, entry_name, force);
}

fn downloadTemplate(
    stdout: anytype,
    stderr: anytype,
    allocator: std.mem.Allocator,
    tmpl: http.TemplateInfo,
    templates_path: []const u8,
    prompts_path: []const u8,
    template_path: []const u8,
) !void {
    // Create directories
    fs.cwd().makePath(templates_path) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} creating templates directory: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return error.DirectoryCreationFailed;
    };
    fs.cwd().makePath(prompts_path) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} creating prompts directory: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return error.DirectoryCreationFailed;
    };

    // Fetch template meta.json
    var sp_meta = spinner.init(stdout, "Fetching template meta");
    sp_meta.start();

    var meta_result = http.fetchTemplateMeta(allocator, tmpl.name) catch |err| {
        sp_meta.fail();
        if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}{s}Error:{s} template '{s}{s}{s}' not found in registry.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, tmpl.name, Color.reset });
        } else if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} fetching template: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return error.FetchFailed;
    };
    defer meta_result.deinit();
    sp_meta.succeed();

    // Fetch prompts index for metadata
    var sp_prompts = spinner.init(stdout, "Fetching prompts index");
    sp_prompts.start();

    var prompts_index = http.fetchPromptsIndex(allocator) catch |err| {
        sp_prompts.fail();
        try stderr.print("{s}{s}{s}Error:{s} fetching prompts index: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return error.FetchFailed;
    };
    defer prompts_index.deinit();
    sp_prompts.succeed();

    // Create template directory
    fs.cwd().makePath(template_path) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} creating template directory: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return error.DirectoryCreationFailed;
    };

    // Save meta.json to template directory
    const meta_local_path = try std.fs.path.join(allocator, &.{ template_path, "meta.json" });
    defer allocator.free(meta_local_path);

    {
        const meta_file = fs.createFileAbsolute(meta_local_path, .{}) catch {
            spinner.err(stderr, "Cannot write: meta.json");
            return error.WriteFailed;
        };
        defer meta_file.close();

        meta_file.writeAll(meta_result.json_str) catch {
            spinner.err(stderr, "Write error: meta.json");
            return error.WriteFailed;
        };
    }
    spinner.success(stdout, "meta.json");

    // Download entry files (CLAUDE.md) for each supported language
    var sp_files = spinner.init(stdout, "Downloading template files");
    sp_files.start();

    var files_downloaded: usize = 0;
    var files_failed: usize = 0;

    for (tmpl.languages) |lang| {
        for (meta_result.meta.files) |file| {
            const content = http.fetchTemplateFile(allocator, tmpl.name, lang, file) catch |err| {
                if (err != http.HttpError.NotFound) {
                    files_failed += 1;
                }
                continue;
            };
            defer allocator.free(content);

            // Store in templates/{name}/files/{lang}/{file}
            const local_path = std.fs.path.join(allocator, &.{ template_path, "files", lang, file }) catch continue;
            defer allocator.free(local_path);

            if (std.fs.path.dirname(local_path)) |parent| {
                fs.cwd().makePath(parent) catch {};
            }

            const out_file = fs.createFileAbsolute(local_path, .{}) catch {
                files_failed += 1;
                continue;
            };
            defer out_file.close();

            out_file.writeAll(content) catch {
                files_failed += 1;
                continue;
            };

            files_downloaded += 1;
        }
    }

    if (files_failed > 0) {
        sp_files.fail();
    } else {
        sp_files.succeed();
    }

    // Collect all unique hashes
    const all_hashes = blk: {
        var hashes: std.ArrayListUnmanaged([]const u8) = .{};
        for (meta_result.meta.prompts_en) |h| {
            hashes.append(allocator, h) catch continue;
        }
        for (meta_result.meta.prompts_zh) |h| {
            var found = false;
            for (hashes.items) |existing| {
                if (std.mem.eql(u8, existing, h)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                hashes.append(allocator, h) catch continue;
            }
        }
        break :blk hashes.toOwnedSlice(allocator) catch return error.OutOfMemory;
    };
    defer allocator.free(all_hashes);

    // Download prompts to global prompts directory
    var sp_prompts_dl = spinner.init(stdout, "Downloading prompts");
    sp_prompts_dl.start();

    var prompts_downloaded: usize = 0;
    var prompts_cached: usize = 0;
    var prompts_failed: usize = 0;

    for (all_hashes) |prompt_hash| {
        const filename = std.fmt.allocPrint(allocator, "{s}.md", .{prompt_hash}) catch continue;
        defer allocator.free(filename);

        const prompt_local_path = std.fs.path.join(allocator, &.{ prompts_path, filename }) catch continue;
        defer allocator.free(prompt_local_path);

        // Check if prompt already exists locally
        const prompt_exists = blk: {
            fs.accessAbsolute(prompt_local_path, .{}) catch break :blk false;
            break :blk true;
        };

        if (prompt_exists) {
            prompts_cached += 1;
            continue;
        }

        const content = http.fetchPromptContent(allocator, prompt_hash) catch {
            prompts_failed += 1;
            continue;
        };
        defer allocator.free(content);

        const prompt_file = fs.createFileAbsolute(prompt_local_path, .{}) catch {
            prompts_failed += 1;
            continue;
        };
        defer prompt_file.close();

        prompt_file.writeAll(content) catch {
            prompts_failed += 1;
            continue;
        };

        prompts_downloaded += 1;
    }

    if (prompts_failed > 0) {
        sp_prompts_dl.fail();
    } else {
        sp_prompts_dl.succeed();
    }

    // Save local prompts index
    try saveLocalPromptsIndex(allocator, prompts_path, prompts_index, all_hashes);

    try stdout.print("\n{s}{s}{s}✓{s} Template cached locally\n\n", .{ P, Color.bold, Color.green, Color.reset });
}

fn applyTemplate(
    stdout: anytype,
    stderr: anytype,
    allocator: std.mem.Allocator,
    tmpl: http.TemplateInfo,
    template_path: []const u8,
    prompts_path: []const u8,
    lang: []const u8,
    entry_name: []const u8,
    force: bool,
) !void {
    // Read meta.json
    const meta_path = try std.fs.path.join(allocator, &.{ template_path, "meta.json" });
    defer allocator.free(meta_path);

    const meta_file = fs.openFileAbsolute(meta_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not read template meta.json.\n", .{ P, Color.bold, Color.red, Color.reset });
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

    try stdout.print("{s}Applying template '{s}{s}{s}' [{s}]...\n\n", .{ P, Color.bold, tmpl.name, Color.reset, lang });

    var cwd = fs.cwd().openDir(".", .{}) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} opening current directory: {}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };
    defer cwd.close();

    var created: usize = 0;
    var skipped: usize = 0;

    // Copy CLAUDE.md as entry file (now in files/{lang}/)
    const claude_path = try std.fs.path.join(allocator, &.{ template_path, "files", lang, "CLAUDE.md" });
    defer allocator.free(claude_path);

    const claude_file = fs.openFileAbsolute(claude_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not read CLAUDE.md for language '{s}'.\n", .{ P, Color.bold, Color.red, Color.reset, lang });
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
        if (prompts_obj.object.get(lang)) |lang_prompts| {
            for (lang_prompts.array.items) |hash_val| {
                prompt_hashes.append(allocator, hash_val.string) catch continue;
            }
        }
    }

    // Process each prompt (now from global prompts directory)
    for (prompt_hashes.items) |prompt_hash| {
        const prompt_filename = std.fmt.allocPrint(allocator, "{s}.md", .{prompt_hash}) catch continue;
        defer allocator.free(prompt_filename);

        // Read from global prompts directory
        const prompt_path = try std.fs.path.join(allocator, &.{ prompts_path, prompt_filename });
        defer allocator.free(prompt_path);

        const prompt_file = fs.openFileAbsolute(prompt_path, .{}) catch {
            try stderr.print("{s}  {s}{s}✗{s} Missing prompt: {s}\n", .{ P, Color.bold, Color.red, Color.reset, prompt_hash[0..@min(8, prompt_hash.len)] });
            continue;
        };
        defer prompt_file.close();

        const prompt_content = prompt_file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(prompt_content);

        // Extract path from frontmatter
        const dest_path = extractPathFromFrontmatter(allocator, prompt_content) orelse {
            try stderr.print("{s}  {s}{s}✗{s} No path in prompt: {s}\n", .{ P, Color.bold, Color.red, Color.reset, prompt_hash[0..@min(8, prompt_hash.len)] });
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

fn saveLocalPromptsIndex(allocator: std.mem.Allocator, prompts_path: []const u8, remote_index: http.PromptsIndex, hashes: []const []const u8) !void {
    const index_path = try std.fs.path.join(allocator, &.{ prompts_path, "index.json" });
    defer allocator.free(index_path);

    // Build JSON manually
    var json_buf: std.ArrayListUnmanaged(u8) = .{};
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "{\n  \"version\": \"1\",\n  \"prompts\": [\n");

    var first = true;
    for (hashes) |hash_item| {
        if (remote_index.findByHash(hash_item)) |meta| {
            if (!first) {
                try json_buf.appendSlice(allocator, ",\n");
            }
            first = false;

            try json_buf.appendSlice(allocator, "    {\n");
            try json_buf.writer(allocator).print("      \"hash\": \"{s}\",\n", .{meta.hash});
            try json_buf.writer(allocator).print("      \"type\": \"{s}\",\n", .{meta.type});
            try json_buf.writer(allocator).print("      \"lang\": \"{s}\",\n", .{meta.lang});
            try json_buf.writer(allocator).print("      \"path\": \"{s}\",\n", .{meta.path});
            try json_buf.writer(allocator).print("      \"author\": \"{s}\",\n", .{meta.author});
            try json_buf.appendSlice(allocator, "      \"publication\": {\n");
            try json_buf.writer(allocator).print("        \"name\": \"{s}\",\n", .{meta.name});
            try json_buf.writer(allocator).print("        \"description\": \"{s}\"\n", .{meta.description});
            try json_buf.appendSlice(allocator, "      }\n    }");
        }
    }

    try json_buf.appendSlice(allocator, "\n  ]\n}\n");

    const file = fs.createFileAbsolute(index_path, .{}) catch return;
    defer file.close();
    file.writeAll(json_buf.items) catch {};
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
