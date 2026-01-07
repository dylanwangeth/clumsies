const std = @import("std");
const fs = std.fs;
const http = @import("../http.zig");
const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, template_name: ?[]const u8, list: bool, force: bool) !void {
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

    if (list) {
        try stdout.writeAll("\n");
        try listInstalledTemplates(stdout, templates_path);
        try stdout.writeAll("\n");
        return;
    }

    const name = template_name orelse {
        try stderr.print("\n{s}{s}{s}Error:{s} template name required\n{s}Usage: {s}clumsies install <name>{s}\n\n", .{ P, Color.bold, Color.red, Color.reset, P, Color.cyan, Color.reset });
        return;
    };

    const template_install_path = try std.fs.path.join(allocator, &.{ templates_path, name });
    defer allocator.free(template_install_path);

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

    // Create directories
    fs.cwd().makePath(templates_path) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} creating templates directory: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };
    fs.cwd().makePath(prompts_path) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} creating prompts directory: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };

    try stdout.print("{s}  {s}→{s} Fetching template info...\n", .{ P, Color.orange, Color.reset });
    stdout.flush() catch {};

    // Fetch template meta.json
    var meta_result = http.fetchTemplateMeta(allocator, name) catch |err| {
        if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}{s}Error:{s} template '{s}{s}{s}' not found in registry.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        } else if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} fetching template: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer meta_result.deinit();

    // Fetch prompts index for metadata
    var prompts_index = http.fetchPromptsIndex(allocator) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} fetching prompts index: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };
    defer prompts_index.deinit();

    var downloaded: usize = 0;
    var failed: usize = 0;

    // Create template directory
    fs.cwd().makePath(template_install_path) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} creating template directory: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };

    // Save meta.json to template directory
    const meta_local_path = try std.fs.path.join(allocator, &.{ template_install_path, "meta.json" });
    defer allocator.free(meta_local_path);

    {
        const meta_file = fs.createFileAbsolute(meta_local_path, .{}) catch {
            try stderr.print("{s}  {s}{s}✗{s} Cannot write: meta.json\n", .{ P, Color.bold, Color.red, Color.reset });
            failed += 1;
            return;
        };
        defer meta_file.close();

        meta_file.writeAll(meta_result.json_str) catch {
            try stderr.print("{s}  {s}{s}✗{s} Write error: meta.json\n", .{ P, Color.bold, Color.red, Color.reset });
            failed += 1;
            return;
        };
    }
    try stdout.print("{s}  {s}→{s} meta.json\n", .{ P, Color.orange, Color.reset });
    downloaded += 1;

    // Download entry files (CLAUDE.md) for each language
    const languages = [_][]const u8{ "en", "zh" };
    for (languages) |lang| {
        for (meta_result.meta.files) |file| {
            const content = http.fetchTemplateFile(allocator, name, lang, file) catch |err| {
                if (err != http.HttpError.NotFound) {
                    try stderr.print("{s}  {s}{s}✗{s} Failed: files/{s}/{s}\n", .{ P, Color.bold, Color.red, Color.reset, lang, file });
                    failed += 1;
                }
                continue;
            };
            defer allocator.free(content);

            // Store in templates/{name}/files/{lang}/{file}
            const local_path = try std.fs.path.join(allocator, &.{ template_install_path, "files", lang, file });
            defer allocator.free(local_path);

            if (std.fs.path.dirname(local_path)) |parent| {
                fs.cwd().makePath(parent) catch {};
            }

            const out_file = fs.createFileAbsolute(local_path, .{}) catch {
                try stderr.print("{s}  {s}{s}✗{s} Cannot write: files/{s}/{s}\n", .{ P, Color.bold, Color.red, Color.reset, lang, file });
                failed += 1;
                continue;
            };
            defer out_file.close();

            out_file.writeAll(content) catch {
                try stderr.print("{s}  {s}{s}✗{s} Write error: files/{s}/{s}\n", .{ P, Color.bold, Color.red, Color.reset, lang, file });
                failed += 1;
                continue;
            };

            try stdout.print("{s}  {s}→{s} files/{s}/{s}\n", .{ P, Color.orange, Color.reset, lang, file });
            downloaded += 1;
        }
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
        break :blk hashes.toOwnedSlice(allocator) catch return;
    };
    defer allocator.free(all_hashes);

    // Download prompts to global prompts directory
    for (all_hashes) |hash| {
        const filename = std.fmt.allocPrint(allocator, "{s}.md", .{hash}) catch continue;
        defer allocator.free(filename);

        const prompt_local_path = try std.fs.path.join(allocator, &.{ prompts_path, filename });
        defer allocator.free(prompt_local_path);

        // Check if prompt already exists locally
        const prompt_exists = blk: {
            fs.accessAbsolute(prompt_local_path, .{}) catch break :blk false;
            break :blk true;
        };

        const prompt_meta = prompts_index.findByHash(hash);
        const display_name = if (prompt_meta) |pm| pm.path else hash[0..@min(8, hash.len)];

        if (prompt_exists) {
            try stdout.print("{s}  {s}✓{s} {s} {s}(cached){s}\n", .{ P, Color.green, Color.reset, display_name, Color.dim, Color.reset });
            downloaded += 1;
            continue;
        }

        const content = http.fetchPromptContent(allocator, hash) catch |err| {
            if (err == http.HttpError.NotFound) {
                try stderr.print("{s}  {s}{s}✗{s} Not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, display_name });
            } else {
                try stderr.print("{s}  {s}{s}✗{s} Failed: {s}\n", .{ P, Color.bold, Color.red, Color.reset, display_name });
            }
            failed += 1;
            continue;
        };
        defer allocator.free(content);

        const prompt_file = fs.createFileAbsolute(prompt_local_path, .{}) catch {
            try stderr.print("{s}  {s}{s}✗{s} Cannot write: {s}\n", .{ P, Color.bold, Color.red, Color.reset, display_name });
            failed += 1;
            continue;
        };
        defer prompt_file.close();

        prompt_file.writeAll(content) catch {
            try stderr.print("{s}  {s}{s}✗{s} Write error: {s}\n", .{ P, Color.bold, Color.red, Color.reset, display_name });
            failed += 1;
            continue;
        };

        try stdout.print("{s}  {s}→{s} {s}\n", .{ P, Color.orange, Color.reset, display_name });
        downloaded += 1;
    }

    // Save local prompts index
    try saveLocalPromptsIndex(allocator, prompts_path, prompts_index, all_hashes);

    try stdout.writeAll("\n");

    if (failed > 0) {
        try stderr.print("{s}{s}{s}Warning:{s} {d} files failed to download.\n", .{ P, Color.bold, Color.orange, Color.reset, failed });
    }

    if (downloaded > 0) {
        try stdout.print("{s}{s}{s}✓{s} Installed template '{s}{s}{s}'\n\n", .{ P, Color.bold, Color.orange, Color.reset, Color.bold, name, Color.reset });
    } else {
        try stderr.print("{s}{s}{s}Error:{s} No files were installed.\n\n", .{ P, Color.bold, Color.red, Color.reset });
    }
}

fn saveLocalPromptsIndex(allocator: std.mem.Allocator, prompts_path: []const u8, remote_index: http.PromptsIndex, hashes: []const []const u8) !void {
    const index_path = try std.fs.path.join(allocator, &.{ prompts_path, "index.json" });
    defer allocator.free(index_path);

    // Build JSON manually
    var json_buf: std.ArrayListUnmanaged(u8) = .{};
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "{\n  \"version\": \"1\",\n  \"prompts\": [\n");

    var first = true;
    for (hashes) |hash| {
        if (remote_index.findByHash(hash)) |meta| {
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

fn listInstalledTemplates(stdout: anytype, templates_path: []const u8) !void {
    try stdout.print("{s}{s}{s}Installed templates:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });

    var templates_dir = fs.openDirAbsolute(templates_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.print("{s}  {s}(none){s}\n", .{ P, Color.dim, Color.reset });
            return;
        }
        return err;
    };
    defer templates_dir.close();

    var it = templates_dir.iterate();
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
