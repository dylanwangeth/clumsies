const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

const SubCommand = enum {
    list,
    create,
    show,
    rm,
    import,
    none,
};

// Frontmatter metadata
const Frontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

fn parseFrontmatter(content: []const u8) Frontmatter {
    var fm = Frontmatter{};

    // Check for frontmatter delimiter
    if (!std.mem.startsWith(u8, content, "---")) return fm;

    // Find end delimiter
    const rest = content[3..];
    const end_idx = std.mem.indexOf(u8, rest, "\n---") orelse return fm;
    const frontmatter_block = rest[0..end_idx];

    // Parse line by line
    var lines = std.mem.splitScalar(u8, frontmatter_block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            const value = std.mem.trim(u8, trimmed[5..], " \t");
            if (value.len > 0) fm.name = value;
        } else if (std.mem.startsWith(u8, trimmed, "description:")) {
            const value = std.mem.trim(u8, trimmed[12..], " \t");
            if (value.len > 0) fm.description = value;
        }
    }

    return fm;
}

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try showUsage(stderr);
        return;
    }

    var subcmd: SubCommand = .none;
    const subcmd_args_start: usize = 1;

    if (std.mem.eql(u8, args[0], "list")) {
        subcmd = .list;
    } else if (std.mem.eql(u8, args[0], "create")) {
        subcmd = .create;
    } else if (std.mem.eql(u8, args[0], "show")) {
        subcmd = .show;
    } else if (std.mem.eql(u8, args[0], "rm") or std.mem.eql(u8, args[0], "remove")) {
        subcmd = .rm;
    } else if (std.mem.eql(u8, args[0], "import")) {
        subcmd = .import;
    }

    const subcmd_args = args[subcmd_args_start..];

    switch (subcmd) {
        .list => try runList(stdout, stderr, allocator),
        .create => try runCreate(stdout, stderr, allocator, subcmd_args),
        .show => try runShow(stdout, stderr, allocator, subcmd_args),
        .rm => try runRm(stdout, stderr, allocator, subcmd_args),
        .import => try runImport(stdout, stderr, allocator, subcmd_args),
        .none => try showUsage(stderr),
    }
}

fn showUsage(stderr: anytype) !void {
    try stderr.print("\n{s}{s}{s}Error:{s} Subcommand required\n", .{ P, Color.bold, Color.red, Color.reset });
    try stderr.print("{s}Usage: {s}clumsies prompt <command>{s}\n\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}Commands:\n", .{P});
    try stderr.print("{s}  {s}list{s}              List prompts in registry\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}create{s} <file>     Create prompt in registry\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}show{s} <hash>       Show prompt content\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}rm{s} <hash>         Remove prompt from registry\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}import{s} <hash>     Import prompt to .prompts/\n\n", .{ P, Color.cyan, Color.reset });
}

fn ensureRegistry(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) ![]const u8 {
    const registry_url = config.getRegistry(allocator) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Registry not configured\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run: {s}clumsies config set registry <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return error.NoRegistry;
    };
    defer allocator.free(registry_url);

    const base_path = commands.getBasePath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine config path\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return error.NoBasePath;
    };
    defer allocator.free(base_path);

    const registry_path = try std.fs.path.join(allocator, &.{ base_path, "registry" });

    const registry_exists = blk: {
        var dir = fs.openDirAbsolute(registry_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    // Print leading newline for spinner output (only once per command)
    const stdout_raw = std.fs.File.stdout();
    _ = stdout_raw.write("\n") catch {};

    if (!registry_exists) {
        var sp = spinner.init(stdout, "Fetching registry");
        sp.start();
        fs.cwd().makePath(base_path) catch {};
        git.clone(allocator, registry_url, registry_path) catch {
            sp.fail();
            try stderr.print("{s}{s}{s}Error:{s} Failed to clone registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
            allocator.free(registry_path);
            return error.CloneFailed;
        };
        sp.succeed();
    } else {
        var sp = spinner.init(stdout, "Syncing registry");
        sp.start();
        git.pull(allocator, registry_path) catch {};
        sp.succeed();
    }

    return registry_path;
}

fn runList(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) !void {
    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stdout.print("{s}{s}No prompts found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const items = parsed.value.object.get("prompts") orelse {
        try stdout.print("{s}{s}No prompts found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    };

    if (items.array.items.len == 0) {
        try stdout.print("{s}{s}No prompts found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    }

    try stdout.print("{s}{s}{s}Prompts in registry:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});
    try stdout.print("{s}  {s}HASH{s}      {s}CREATED{s}     {s}NAME{s}                 {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});

    for (items.array.items) |item| {
        const hash = if (item.object.get("hash")) |h| h.string else continue;
        const name = if (item.object.get("name")) |n| n.string else "-";
        const desc = if (item.object.get("description")) |d| d.string else "-";
        const created_str = if (item.object.get("created_at")) |c| c.string else "0";

        const created_ts = std.fmt.parseInt(i64, created_str, 10) catch 0;
        var date_buf: [10]u8 = undefined;
        const date_str = commands.formatDate(created_ts, &date_buf);

        const short_hash = if (hash.len > 8) hash[0..8] else hash;
        try stdout.print("{s}  {s}{s}{s}  {s}  {s: <20}  {s}\n", .{ P, Color.cyan, short_hash, Color.reset, date_str, name, desc });
    }
    try stdout.writeAll("\n");
}

fn runCreate(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} File required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt create <file.md>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    const file_path = args[0];

    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    const abs_path = if (std.fs.path.isAbsolute(file_path))
        try allocator.dupe(u8, file_path)
    else
        try std.fs.path.join(allocator, &.{ cwd, file_path });
    defer allocator.free(abs_path);

    const file = fs.openFileAbsolute(abs_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not open file: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, file_path });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(content);

    // Compute SHA-256 hash
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});
    var hash_hex: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        hash_hex[i * 2] = hex_chars[byte >> 4];
        hash_hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    // Extract file extension (format)
    const basename = std.fs.path.basename(file_path);
    const ext_idx = std.mem.lastIndexOf(u8, basename, ".");
    const format = if (ext_idx) |idx| basename[idx + 1 ..] else "md";
    const name_end = ext_idx orelse basename.len;

    // Extract path (conduct or command) from file path
    const prompt_path = if (std.mem.indexOf(u8, file_path, "conduct") != null)
        "conduct"
    else if (std.mem.indexOf(u8, file_path, "command") != null)
        "command"
    else
        "conduct"; // default to conduct

    // Parse frontmatter for metadata
    const fm = parseFrontmatter(content);
    const name = fm.name orelse basename[0..name_end];
    const description = fm.description orelse "-";

    // Create prompts directory
    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    // Copy file to registry (pure hash, no extension)
    const dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, &hash_hex });
    defer allocator.free(dest_path);

    // Check if already exists
    if (fs.openFileAbsolute(dest_path, .{})) |existing| {
        existing.close();
        try stdout.print("{s}{s}{s}!{s} Prompt already exists in registry\n", .{ P, Color.bold, Color.orange, Color.reset });
        try stdout.print("{s}  Hash: {s}{s}{s}\n\n", .{ P, Color.cyan, hash_hex, Color.reset });
        return;
    } else |_| {}

    // Write content
    const dest_file = fs.createFileAbsolute(dest_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to create file in registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer dest_file.close();
    dest_file.writeAll(content) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Update index.json
    const index_path = try std.fs.path.join(allocator, &.{ prompts_dir, "index.json" });
    defer allocator.free(index_path);

    var existing_prompts: std.ArrayListUnmanaged(u8) = .{};
    defer existing_prompts.deinit(allocator);

    if (fs.openFileAbsolute(index_path, .{})) |idx_file| {
        const idx_content = idx_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
            idx_file.close();
            try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        idx_file.close();
        defer allocator.free(idx_content);

        if (std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value.object.get("prompts")) |prompts| {
                try existing_prompts.appendSlice(allocator, "{\n  \"prompts\": [");
                for (prompts.array.items, 0..) |item, idx| {
                    if (idx > 0) try existing_prompts.appendSlice(allocator, ",");
                    const item_hash = if (item.object.get("hash")) |h| h.string else continue;
                    const item_name = if (item.object.get("name")) |n| n.string else "-";
                    const item_desc = if (item.object.get("description")) |d| d.string else "-";
                    const item_format = if (item.object.get("format")) |f| f.string else "md";
                    const item_created = if (item.object.get("created_at")) |c| c.string else "0";

                    const item_path = if (item.object.get("path")) |p| p.string else "conduct";

                    const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"path\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_desc, item_format, item_path, item_created });
                    defer allocator.free(entry);
                    try existing_prompts.appendSlice(allocator, entry);
                }
            }
        } else |_| {}
    } else |_| {
        try existing_prompts.appendSlice(allocator, "{\n  \"prompts\": [");
    }

    const timestamp = std.time.timestamp();
    const new_entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"path\": \"{s}\",\n      \"created_at\": \"{d}\"\n    }}\n  ]\n}}\n", .{
        if (existing_prompts.items.len > 20) "," else "",
        hash_hex,
        name,
        description,
        format,
        prompt_path,
        timestamp,
    });
    defer allocator.free(new_entry);
    try existing_prompts.appendSlice(allocator, new_entry);

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(existing_prompts.items) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Commit and push
    var sp = spinner.init(stdout, "Creating in registry");
    sp.start();
    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Add prompt") catch {};
    git.push(allocator, registry_path) catch {
        sp.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
    };
    sp.succeed();

    try stdout.print("{s}{s}{s}✓{s} Created prompt in registry\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Hash: {s}{s}{s}\n", .{ P, Color.cyan, hash_hex, Color.reset });
    try stdout.print("{s}  Name: {s}\n\n", .{ P, name });
}

fn runShow(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt show <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    const hash = args[0];

    // Read index to find prompt
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No prompts found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const prompts = parsed.value.object.get("prompts") orelse {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Find prompt by hash prefix
    var found_hash: ?[]const u8 = null;
    var found_name: ?[]const u8 = null;

    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (std.mem.startsWith(u8, item_hash, hash)) {
            found_hash = item_hash;
            found_name = if (item.object.get("name")) |n| n.string else null;
            break;
        }
    }

    if (found_hash == null) {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, hash });
        return;
    }

    // Read prompt file (pure hash, no extension)
    const prompt_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", found_hash.? });
    defer allocator.free(prompt_path);

    const prompt_file = fs.openFileAbsolute(prompt_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Prompt file not found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer prompt_file.close();

    const prompt_content = prompt_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read prompt\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompt_content);

    if (found_name) |n| {
        try stdout.print("{s}{s}{s}Prompt:{s} {s}\n", .{ P, Color.bold, Color.orange, Color.reset, n });
    }
    try stdout.print("{s}{s}Hash:{s} {s}\n", .{ P, Color.orange, Color.reset, found_hash.? });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});
    try stdout.print("{s}\n", .{prompt_content});
}

fn runRm(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt rm <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    const hash = args[0];

    // Read index
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No prompts found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    file.close();
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const prompts = parsed.value.object.get("prompts") orelse {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Find and remove prompt
    var found_hash: ?[]const u8 = null;
    var found_name: ?[]const u8 = null;
    var new_prompts: std.ArrayListUnmanaged(u8) = .{};
    defer new_prompts.deinit(allocator);

    try new_prompts.appendSlice(allocator, "{\n  \"prompts\": [");
    var first = true;

    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        const item_name = if (item.object.get("name")) |n| n.string else "-";

        if (std.mem.startsWith(u8, item_hash, hash)) {
            found_hash = item_hash;
            found_name = item_name;
            continue;
        }

        const item_desc = if (item.object.get("description")) |d| d.string else "-";
        const item_format = if (item.object.get("format")) |f| f.string else "md";
        const item_path = if (item.object.get("path")) |p| p.string else "conduct";
        const item_created = if (item.object.get("created_at")) |c| c.string else "0";

        if (!first) try new_prompts.appendSlice(allocator, ",");
        first = false;

        const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"path\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_desc, item_format, item_path, item_created });
        defer allocator.free(entry);
        try new_prompts.appendSlice(allocator, entry);
    }
    try new_prompts.appendSlice(allocator, "\n  ]\n}\n");

    if (found_hash == null) {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, hash });
        return;
    }

    // Delete prompt file (pure hash, no extension)
    const prompt_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", found_hash.? });
    defer allocator.free(prompt_path);
    fs.deleteFileAbsolute(prompt_path) catch {};

    // Write updated index
    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(new_prompts.items) catch {};

    // Commit and push
    var sp = spinner.init(stdout, "Removing from registry");
    sp.start();
    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Remove prompt") catch {};
    git.push(allocator, registry_path) catch {
        sp.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Removed locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
    };
    sp.succeed();

    try stdout.print("{s}{s}{s}✓{s} Removed prompt: {s}\n\n", .{ P, Color.bold, Color.green, Color.reset, found_name orelse "-" });
}

fn runImport(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt import <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    // Check .prompts/ exists
    const prompts_path = commands.getPromptsPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine .prompts/ path\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompts_path);

    if (!commands.promptsExist()) {
        try stderr.print("{s}{s}{s}Error:{s} .prompts/ directory not found\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies init <git-url>{s} first\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    const hash = args[0];

    // Read index to find prompt
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No prompts found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const prompts = parsed.value.object.get("prompts") orelse {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Find prompt by hash prefix
    var found_hash: ?[]const u8 = null;
    var found_name: ?[]const u8 = null;
    var found_format: []const u8 = "md";
    var found_path: []const u8 = "conduct";

    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (std.mem.startsWith(u8, item_hash, hash)) {
            found_hash = item_hash;
            found_name = if (item.object.get("name")) |n| n.string else null;
            found_format = if (item.object.get("format")) |f| f.string else "md";
            found_path = if (item.object.get("path")) |p| p.string else "conduct";
            break;
        }
    }

    if (found_hash == null) {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, hash });
        return;
    }

    // Read prompt file (pure hash, no extension)
    const prompt_file_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", found_hash.? });
    defer allocator.free(prompt_file_path);

    // Copy to .prompts/{path}/
    var sp = spinner.init(stdout, "Importing prompt");
    sp.start();

    const target_dir = try std.fs.path.join(allocator, &.{ prompts_path, found_path });
    defer allocator.free(target_dir);
    fs.cwd().makePath(target_dir) catch {};

    // Find next available sequence number with gap filling
    const seq_num = findNextSequence(allocator, target_dir);

    // Build filename: NN_name.format
    const name_part = found_name orelse found_hash.?[0..8];
    const dest_filename = try std.fmt.allocPrint(allocator, "{d:0>2}_{s}.{s}", .{ seq_num, name_part, found_format });
    defer allocator.free(dest_filename);

    const dest_path = try std.fs.path.join(allocator, &.{ target_dir, dest_filename });
    defer allocator.free(dest_path);

    fs.copyFileAbsolute(prompt_file_path, dest_path, .{}) catch {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to copy prompt\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    sp.succeed();

    try stdout.print("{s}{s}{s}✓{s} Imported prompt to .prompts/{s}/\n", .{ P, Color.bold, Color.green, Color.reset, found_path });
    try stdout.print("{s}  File: {s}{s}{s}\n\n", .{ P, Color.cyan, dest_filename, Color.reset });
}

/// Find next available sequence number with gap filling
/// If files 00_, 01_, 03_ exist, returns 2 (fills the gap)
/// If files 00_, 01_, 02_ exist, returns 3 (next number)
fn findNextSequence(allocator: std.mem.Allocator, dir_path: []const u8) u8 {
    var used: [100]bool = [_]bool{false} ** 100;
    var max_seq: u8 = 0;

    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        // Parse sequence number from filename (NN_...)
        if (entry.name.len < 3) continue;
        if (entry.name[2] != '_') continue;

        const seq = std.fmt.parseInt(u8, entry.name[0..2], 10) catch continue;
        if (seq < 100) {
            used[seq] = true;
            if (seq >= max_seq) max_seq = seq + 1;
        }
    }

    // Find first gap
    var i: u8 = 0;
    while (i < max_seq) : (i += 1) {
        if (!used[i]) return i;
    }

    // No gap found, return next number
    _ = allocator;
    return max_seq;
}
