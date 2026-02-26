const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;
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
    update,
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
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try showHelp(stdout);
            return;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sync")) {
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
        } else if (std.mem.eql(u8, arg, "update")) {
            subcmd = .update;
            subcmd_args_start = i + 1;
        } else if (subcmd == .none and std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try showUsage(stderr);
            return;
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
        .update => try runUpdate(stdout, stderr, allocator, filtered_args.items, sync),
        .none => try showUsage(stderr),
    }
}

fn showUsage(stderr: anytype) !void {
    try stderr.print("{s}{s}{s}Error:{s} Subcommand required\n", .{ P, Color.bold, Color.red, Color.reset });
    try printPromptHelp(stderr);
}

fn showHelp(stdout: anytype) !void {
    try printPromptHelp(stdout);
}

fn printPromptHelp(out: anytype) !void {
    try out.print("{s}Usage: {s}clumsies prompt [-s] <command>{s}\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Commands:\n", .{P});
    try out.print("{s}  {s}list{s}              List prompts in registry\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}register{s} <file> [--desc/--cat]  Register prompt to registry\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}update{s} <hash> [--desc/--cat]    Update prompt metadata\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}show{s} <hash>                     Show prompt content\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}rm{s} <hash>...                    Remove prompt(s) from registry\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}import{s} <hash>... [--cat <cat>...]  Import prompt(s) to .prompts/\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-h, --help{s}        Show this help\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-s, --sync{s}        Sync registry before command\n\n", .{ P, Color.cyan, Color.reset });
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
    try stdout.print("{s}  {s}HASH{s}      {s}CATEGORY{s}          {s}NAME{s}                  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
    try stdout.print("{s}──────────────────────────────────────────────────────────────────────────────────────\n", .{P});

    std.mem.sort(std.json.Value, items.array.items, {}, struct {
        fn lessThan(_: void, a: std.json.Value, b: std.json.Value) bool {
            const a_name = if (a.object.get("name")) |n| n.string else "";
            const b_name = if (b.object.get("name")) |n| n.string else "";
            return std.mem.order(u8, a_name, b_name) == .lt;
        }
    }.lessThan);

    for (items.array.items) |item| {
        const hash = if (item.object.get("hash")) |h| h.string else continue;
        const name = if (item.object.get("name")) |n| n.string else "-";
        const desc = if (item.object.get("description")) |d| d.string else "-";
        const category = if (item.object.get("category")) |c| c.string else "conduct";

        const short_hash = if (hash.len > 8) hash[0..8] else hash;
        try stdout.print("{s}  {s}{s: <8}{s}  {s: <16}  {s: <20}  {s}\n", .{ P, Color.cyan, short_hash, Color.reset, category, name, desc });
    }
    try stdout.writeAll("\n");
}

fn runRegister(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    var file_path_arg: ?[]const u8 = null;
    var desc_flag: ?[]const u8 = null;
    var cat_flag: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--desc")) {
            if (i + 1 < args.len) {
                i += 1;
                desc_flag = args[i];
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --desc requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.eql(u8, arg, "--cat")) {
            if (i + 1 < args.len) {
                i += 1;
                cat_flag = args[i];
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --cat requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try stderr.print("{s}Usage: {s}clumsies prompt register <file> [--desc \"...\"] [--cat \"...\"]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        } else if (file_path_arg == null) {
            file_path_arg = arg;
        }
    }

    if (file_path_arg == null) {
        try stderr.print("{s}{s}{s}Error:{s} File required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt register <file> [--desc \"...\"] [--cat \"...\"]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

    const file_path = file_path_arg.?;

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

    // Metadata from flags, name always from filename
    const raw_name = basename[0..name_end];
    const name = stripSequencePrefix(raw_name);
    const description = desc_flag orelse "-";
    const prompt_category = cat_flag orelse "conduct";

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
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try stderr.print("{s}Usage: {s}clumsies prompt show <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
    }
    if (args.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
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
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try stderr.print("{s}Usage: {s}clumsies prompt rm <hash>...{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
    }
    if (args.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt rm <hash>...{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

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

    // Track removed prompts
    var removed_hashes: std.ArrayListUnmanaged([]const u8) = .{};
    defer removed_hashes.deinit(allocator);

    var new_prompts: std.ArrayListUnmanaged(u8) = .{};
    defer new_prompts.deinit(allocator);

    try new_prompts.appendSlice(allocator, "{\n  \"prompts\": [");
    var first = true;

    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;

        // Check if this hash matches any of the args
        var should_remove = false;
        for (args) |hash| {
            if (std.mem.startsWith(u8, item_hash, hash)) {
                should_remove = true;
                try removed_hashes.append(allocator, item_hash);
                break;
            }
        }

        if (should_remove) continue;

        const item_name = if (item.object.get("name")) |n| n.string else "-";
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

    if (removed_hashes.items.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} No matching prompts found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    // Delete prompt files
    for (removed_hashes.items) |hash| {
        const prompt_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", hash });
        defer allocator.free(prompt_path);
        fs.deleteFileAbsolute(prompt_path) catch {};
    }

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

    const commit_msg = if (removed_hashes.items.len == 1) "Remove prompt" else "Remove prompts";
    var commit_output2: GitOutput = .{};
    defer commit_output2.deinit(allocator);
    git.commit(allocator, registry_path, commit_msg, &commit_output2) catch {};

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

    try stdout.print("{s}{s}{s}✓{s} Removed {d} prompt(s)\n\n", .{ P, Color.bold, Color.green, Color.reset, removed_hashes.items.len });
}

fn runUpdate(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    var hash_arg: ?[]const u8 = null;
    var desc_flag: ?[]const u8 = null;
    var cat_flag: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--desc")) {
            if (i + 1 < args.len) {
                i += 1;
                desc_flag = args[i];
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --desc requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.eql(u8, arg, "--cat")) {
            if (i + 1 < args.len) {
                i += 1;
                cat_flag = args[i];
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --cat requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try stderr.print("{s}Usage: {s}clumsies prompt update <hash> [--desc \"...\"] [--cat \"...\"]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        } else if (hash_arg == null) {
            hash_arg = arg;
        }
    }

    if (hash_arg == null) {
        try stderr.print("{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt update <hash> [--desc \"...\"] [--cat \"...\"]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if (desc_flag == null and cat_flag == null) {
        try stderr.print("{s}{s}{s}Error:{s} At least one of --desc or --cat required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt update <hash> [--desc \"...\"] [--cat \"...\"]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const hash = hash_arg.?;

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

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

    // Rebuild index with updated fields
    var found = false;
    var new_index: std.ArrayListUnmanaged(u8) = .{};
    defer new_index.deinit(allocator);

    try new_index.appendSlice(allocator, "{\n  \"prompts\": [");
    var first = true;

    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        const item_name = if (item.object.get("name")) |n| n.string else "-";
        var item_desc = if (item.object.get("description")) |d| d.string else "-";
        const item_format = if (item.object.get("format")) |f| f.string else "md";
        var item_category = if (item.object.get("category")) |p| p.string else "conduct";
        const item_created = if (item.object.get("created_at")) |c| c.string else "0";

        // Apply updates to matching prompt
        if (std.mem.startsWith(u8, item_hash, hash)) {
            found = true;
            if (desc_flag) |d| item_desc = d;
            if (cat_flag) |c| item_category = c;
        }

        if (!first) try new_index.appendSlice(allocator, ",");
        first = false;

        const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_desc, item_format, item_category, item_created });
        defer allocator.free(entry);
        try new_index.appendSlice(allocator, entry);
    }
    try new_index.appendSlice(allocator, "\n  ]\n}\n");

    if (!found) {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, hash });
        return;
    }

    // Write updated index
    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(new_index.items) catch {};

    // Commit and push
    var sp = spinner.init(stdout, "Updating prompt metadata");
    sp.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {};

    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    git.commit(allocator, registry_path, "Update prompt metadata", &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.push(allocator, registry_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output);
        try stderr.print("{s}{s}{s}Warning:{s} Updated locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output);

    try stdout.print("{s}{s}{s}✓{s} Updated prompt metadata\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Hash: {s}{s}{s}\n", .{ P, Color.cyan, hash, Color.reset });
    if (desc_flag) |d| try stdout.print("{s}  Description: {s}\n", .{ P, d });
    if (cat_flag) |c| try stdout.print("{s}  Category: {s}\n", .{ P, c });
    try stdout.writeAll("\n");
}

fn runImport(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    // Parse --cat flags and positional hash args
    var hash_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer hash_args.deinit(allocator);
    var cat_filters: std.ArrayListUnmanaged([]const u8) = .empty;
    defer cat_filters.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--cat")) {
            if (i + 1 < args.len) {
                i += 1;
                try cat_filters.append(allocator, args[i]);
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --cat requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try stderr.print("{s}Usage: {s}clumsies prompt import <hash>... [--cat <category>...]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        } else {
            try hash_args.append(allocator, arg);
        }
    }

    if (hash_args.items.len == 0 and cat_filters.items.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Hash or --cat required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies prompt import <hash>... [--cat <category>...]{s}\n\n", .{ P, Color.cyan, Color.reset });
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

    var success_count: usize = 0;
    var fail_count: usize = 0;

    // Import by hash args
    for (hash_args.items) |hash| {
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

        if (try importPrompt(stdout, stderr, allocator, registry_path, prompts_path, found_hash.?, found_name, found_format, found_category)) {
            success_count += 1;
        } else {
            fail_count += 1;
        }
    }

    // Import by category (prefix match)
    if (cat_filters.items.len > 0) {
        var cat_match_count: usize = 0;
        for (prompts.array.items) |item| {
            const item_hash = if (item.object.get("hash")) |h| h.string else continue;
            const item_name_opt: ?[]const u8 = if (item.object.get("name")) |n| n.string else null;
            const item_format = if (item.object.get("format")) |f| f.string else "md";
            const item_category = if (item.object.get("category")) |p| p.string else "conduct";

            // Check if category matches any filter (prefix match)
            var matches = false;
            for (cat_filters.items) |cat| {
                if (std.mem.eql(u8, item_category, cat) or (std.mem.startsWith(u8, item_category, cat) and (cat.len == item_category.len or item_category[cat.len] == '/'))) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
            cat_match_count += 1;

            if (try importPrompt(stdout, stderr, allocator, registry_path, prompts_path, item_hash, item_name_opt, item_format, item_category)) {
                success_count += 1;
            } else {
                fail_count += 1;
            }
        }

        if (cat_match_count == 0) {
            for (cat_filters.items) |cat| {
                try stderr.print("{s}{s}{s}✗{s} No prompts in category: {s}\n", .{ P, Color.bold, Color.red, Color.reset, cat });
            }
        }
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

fn importPrompt(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, registry_path: []const u8, prompts_path: []const u8, hash: []const u8, name_opt: ?[]const u8, format: []const u8, category: []const u8) !bool {
    const prompt_file_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", hash });
    defer allocator.free(prompt_file_path);

    const target_dir = try std.fs.path.join(allocator, &.{ prompts_path, category });
    defer allocator.free(target_dir);
    fs.cwd().makePath(target_dir) catch {};

    const seq_num = findNextSequence(target_dir);
    const name_part = name_opt orelse hash[0..8];
    const dest_filename = try std.fmt.allocPrint(allocator, "{d:0>2}_{s}.{s}", .{ seq_num, name_part, format });
    defer allocator.free(dest_filename);

    const dest_path = try std.fs.path.join(allocator, &.{ target_dir, dest_filename });
    defer allocator.free(dest_path);

    fs.copyFileAbsolute(prompt_file_path, dest_path, .{}) catch {
        try stderr.print("{s}{s}{s}✗{s} Failed to copy: {s}\n", .{ P, Color.bold, Color.red, Color.reset, name_part });
        return false;
    };

    try stdout.print("{s}{s}{s}✓{s} {s} → .prompts/{s}/{s}\n", .{ P, Color.bold, Color.green, Color.reset, name_part, category, dest_filename });
    return true;
}
