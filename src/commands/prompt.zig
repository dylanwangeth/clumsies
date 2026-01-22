const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;
const Frontmatter = commands.Frontmatter;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;
const parseFrontmatter = commands.parseFrontmatter;
const stripSequencePrefix = commands.stripSequencePrefix;
const hexEncode = commands.hexEncode;
const findNextSequence = commands.findNextSequence;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const ensureRegistry = commands.ensureRegistry;

const SubCommand = enum {
    list,
    register,
    show,
    rm,
    import,
    none,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try showUsage(stderr);
        return;
    }

    var subcmd: SubCommand = .none;
    var subcmd_args_start: usize = 1;
    var sync: bool = false;

    // Parse subcommand and options
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sync")) {
            sync = true;
        } else if (std.mem.eql(u8, arg, "list")) {
            subcmd = .list;
            subcmd_args_start = i + 1;
        } else if (std.mem.eql(u8, arg, "register")) {
            subcmd = .register;
            subcmd_args_start = i + 1;
        } else if (std.mem.eql(u8, arg, "show")) {
            subcmd = .show;
            subcmd_args_start = i + 1;
        } else if (std.mem.eql(u8, arg, "rm") or std.mem.eql(u8, arg, "remove")) {
            subcmd = .rm;
            subcmd_args_start = i + 1;
        } else if (std.mem.eql(u8, arg, "import")) {
            subcmd = .import;
            subcmd_args_start = i + 1;
        }
    }

    // Filter out -s/--sync from subcmd_args
    var filtered_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer filtered_args.deinit(allocator);
    for (args[subcmd_args_start..]) |arg| {
        if (!std.mem.eql(u8, arg, "-s") and !std.mem.eql(u8, arg, "--sync")) {
            try filtered_args.append(allocator, arg);
        }
    }

    switch (subcmd) {
        .list => try runList(stdout, stderr, allocator, sync),
        .register => try runRegister(stdout, stderr, allocator, filtered_args.items, sync),
        .show => try runShow(stdout, stderr, allocator, filtered_args.items, sync),
        .rm => try runRm(stdout, stderr, allocator, filtered_args.items, sync),
        .import => try runImport(stdout, stderr, allocator, filtered_args.items, sync),
        .none => try showUsage(stderr),
    }
}

fn showUsage(stderr: anytype) !void {
    try stderr.print("\n{s}{s}{s}Error:{s} Subcommand required\n", .{ P, Color.bold, Color.red, Color.reset });
    try stderr.print("{s}Usage: {s}clumsies prompt [-s] <command>{s}\n\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}Commands:\n", .{P});
    try stderr.print("{s}  {s}list{s}              List prompts in registry\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}register{s} <file>   Register prompt to registry\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}show{s} <hash>       Show prompt content\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}rm{s} <hash>         Remove prompt from registry\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}import{s} <hash>...  Import prompt(s) to .prompts/\n\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}Options:\n", .{P});
    try stderr.print("{s}  {s}-s, --sync{s}        Sync registry before command\n\n", .{ P, Color.cyan, Color.reset });
}

fn runList(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, sync: bool) !void {
    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stdout.print("{s}{s}No prompts found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
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
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});
    try stdout.print("{s}  {s}HASH{s}      {s}CATEGORY{s}  {s}NAME{s}                  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});

    for (items.array.items) |item| {
        const hash = if (item.object.get("hash")) |h| h.string else continue;
        const name = if (item.object.get("name")) |n| n.string else "-";
        const desc = if (item.object.get("description")) |d| d.string else "-";
        const category = if (item.object.get("category")) |c| c.string else "conduct";

        const short_hash = if (hash.len > 8) hash[0..8] else hash;
        try stdout.print("{s}  {s}{s: <8}{s}  {s: <8}  {s: <20}  {s}\n", .{ P, Color.cyan, short_hash, Color.reset, category, name, desc });
    }
    try stdout.writeAll("\n");
}

fn runRegister(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} File required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt register <file>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
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

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(content);

    // Compute SHA-256 hash
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});
    var hash_hex: [64]u8 = undefined;
    hexEncode(&hash, &hash_hex);

    // Extract file extension (format)
    const basename = std.fs.path.basename(file_path);
    const ext_idx = std.mem.lastIndexOf(u8, basename, ".");
    const format = if (ext_idx) |idx| basename[idx + 1 ..] else "md";
    const name_end = ext_idx orelse basename.len;

    // Parse frontmatter for metadata
    const fm = parseFrontmatter(content);

    // Extract category: frontmatter > file path detection > default
    const prompt_category = if (fm.category) |cat|
        cat
    else if (std.mem.indexOf(u8, file_path, "conduct") != null)
        "conduct"
    else if (std.mem.indexOf(u8, file_path, "command") != null)
        "command"
    else
        "conduct"; // default to conduct
    const raw_name = basename[0..name_end];
    // Strip sequence prefix (NN_) if present
    const name = fm.name orelse stripSequencePrefix(raw_name);
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
        const idx_content = idx_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
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

                    const item_category = if (item.object.get("category")) |p| p.string else "conduct";

                    const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_desc, item_format, item_category, item_created });
                    defer allocator.free(entry);
                    try existing_prompts.appendSlice(allocator, entry);
                }
            }
        } else |_| {}
    } else |_| {
        try existing_prompts.appendSlice(allocator, "{\n  \"prompts\": [");
    }

    const timestamp = std.time.timestamp();
    const new_entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{d}\"\n    }}\n  ]\n}}\n", .{
        if (existing_prompts.items.len > 20) "," else "",
        hash_hex,
        name,
        description,
        format,
        prompt_category,
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
    var sp = spinner.init(stdout, "Registering prompt");
    sp.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {};

    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    git.commit(allocator, registry_path, "Add prompt", &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.push(allocator, registry_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output);
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output);

    try stdout.print("{s}{s}{s}✓{s} Registered prompt in registry\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Hash: {s}{s}{s}\n", .{ P, Color.cyan, hash_hex, Color.reset });
    try stdout.print("{s}  Name: {s}\n\n", .{ P, name });
}

fn runShow(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt show <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
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

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
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

    const prompt_content = prompt_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
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

fn runRm(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt rm <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

    const hash = args[0];

    // Read index
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No prompts found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
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
        const item_category = if (item.object.get("category")) |p| p.string else "conduct";
        const item_created = if (item.object.get("created_at")) |c| c.string else "0";

        if (!first) try new_prompts.appendSlice(allocator, ",");
        first = false;

        const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_desc, item_format, item_category, item_created });
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

    var add_output2: GitOutput = .{};
    defer add_output2.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output2) catch {};

    var commit_output2: GitOutput = .{};
    defer commit_output2.deinit(allocator);
    git.commit(allocator, registry_path, "Remove prompt", &commit_output2) catch {};

    var git_output2: GitOutput = .{};
    defer git_output2.deinit(allocator);

    git.push(allocator, registry_path, &git_output2) catch {
        sp.fail();
        printGitOutputRaw(&git_output2);
        try stderr.print("{s}{s}{s}Warning:{s} Removed locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output2);

    try stdout.print("{s}{s}{s}✓{s} Removed prompt: {s}\n\n", .{ P, Color.bold, Color.green, Color.reset, found_name orelse "-" });
}

fn runImport(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt import <hash>...{s}\n\n", .{ P, Color.cyan, Color.reset });
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
        try stderr.print("{s}Run {s}clumsies init <bundle> <url>{s} or {s}clumsies clone <url>{s} first\n\n", .{ P, Color.cyan, Color.reset, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

    // Read index once for all imports
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No prompts found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
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
        try stderr.print("{s}{s}{s}Error:{s} No prompts in registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Import each hash
    var success_count: usize = 0;
    var fail_count: usize = 0;

    for (args) |hash| {
        // Find prompt by hash prefix
        var found_hash: ?[]const u8 = null;
        var found_name: ?[]const u8 = null;
        var found_format: []const u8 = "md";
        var found_category: []const u8 = "conduct";

        for (prompts.array.items) |item| {
            const item_hash = if (item.object.get("hash")) |h| h.string else continue;
            if (std.mem.startsWith(u8, item_hash, hash)) {
                found_hash = item_hash;
                found_name = if (item.object.get("name")) |n| n.string else null;
                found_format = if (item.object.get("format")) |f| f.string else "md";
                found_category = if (item.object.get("category")) |p| p.string else "conduct";
                break;
            }
        }

        if (found_hash == null) {
            try stderr.print("{s}{s}{s}✗{s} Not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, hash });
            fail_count += 1;
            continue;
        }

        // Read prompt file (pure hash, no extension)
        const prompt_file_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", found_hash.? });
        defer allocator.free(prompt_file_path);

        // Copy to .prompts/{category}/
        const target_dir = try std.fs.path.join(allocator, &.{ prompts_path, found_category });
        defer allocator.free(target_dir);
        fs.cwd().makePath(target_dir) catch {};

        // Find next available sequence number with gap filling
        const seq_num = findNextSequence(target_dir);

        // Build filename: NN_name.format
        const name_part = found_name orelse found_hash.?[0..8];
        const dest_filename = try std.fmt.allocPrint(allocator, "{d:0>2}_{s}.{s}", .{ seq_num, name_part, found_format });
        defer allocator.free(dest_filename);

        const dest_path = try std.fs.path.join(allocator, &.{ target_dir, dest_filename });
        defer allocator.free(dest_path);

        fs.copyFileAbsolute(prompt_file_path, dest_path, .{}) catch {
            try stderr.print("{s}{s}{s}✗{s} Failed to copy: {s}\n", .{ P, Color.bold, Color.red, Color.reset, name_part });
            fail_count += 1;
            continue;
        };

        try stdout.print("{s}{s}{s}✓{s} {s} → .prompts/{s}/{s}\n", .{ P, Color.bold, Color.green, Color.reset, name_part, found_category, dest_filename });
        success_count += 1;
    }

    // Summary
    try stdout.writeAll("\n");
    if (success_count > 0 and fail_count == 0) {
        try stdout.print("{s}Imported {s}{d}{s} prompt{s}\n\n", .{ P, Color.green, success_count, Color.reset, if (success_count > 1) "s" else "" });
    } else if (success_count > 0 and fail_count > 0) {
        try stdout.print("{s}Imported {s}{d}{s}, failed {s}{d}{s}\n\n", .{ P, Color.green, success_count, Color.reset, Color.red, fail_count, Color.reset });
    } else {
        try stderr.print("{s}No prompts imported\n\n", .{P});
    }
}
