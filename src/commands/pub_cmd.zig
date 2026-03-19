const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");
const flag = @import("../flags.zig");

const Color = commands.Color;
const P = commands.P;
const Frontmatter = commands.Frontmatter;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;
const parseFrontmatter = commands.parseFrontmatter;
const hexEncode = commands.hexEncode;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const ensureRegistry = commands.ensureRegistry;
const isHexString = commands.isHexString;
const bundleExists = commands.bundleExists;
const PromptRef = commands.PromptRef;
const META_PROMPT_CATEGORY = commands.META_PROMPT_CATEGORY;
const collectAndUploadPrompts = commands.collectAndUploadPrompts;
const updatePromptsIndex = commands.updatePromptsIndex;
const appendBundleEntry = commands.appendBundleEntry;
const freePromptRefs = commands.freePromptRefs;
const jsonEscapeAlloc = commands.jsonEscapeAlloc;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const Q = 0;
    const S = 1;
    const SPECS = [_]flag.FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
        .{ .short = 's', .long = "sync", .kind = .boolean },
    };
    var err_ctx: flag.ErrorContext = .{};
    var result = flag.parse(&SPECS, allocator, args, &err_ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelp(stdout);
            return;
        },
        error.UnknownFlag => {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try printHelp(stderr);
            return;
        },
        error.MissingValue => {
            try stderr.print("{s}{s}{s}Error:{s} {s} requires a value\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer result.deinit(allocator);
    const quiet_git = result.boolean(Q);
    const sync = result.boolean(S);

    if (result.positionals.items.len < 2) {
        try stderr.print("{s}{s}{s}Error:{s} Meta-prompt file and at least one directory required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }

    const meta_prompt_path_arg = result.positionals.items[0];
    const dirs = result.positionals.items[1..];

    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    const meta_prompt_path = if (std.fs.path.isAbsolute(meta_prompt_path_arg))
        try allocator.dupe(u8, meta_prompt_path_arg)
    else
        try std.fs.path.join(allocator, &.{ cwd, meta_prompt_path_arg });
    defer allocator.free(meta_prompt_path);

    // Read meta-prompt file
    const meta_file = fs.openFileAbsolute(meta_prompt_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not open meta-prompt file: {s}\n", .{ P, Color.bold, Color.red, Color.reset, meta_prompt_path_arg });
        return;
    };
    const meta_content = meta_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        meta_file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read meta-prompt file\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    meta_file.close();
    defer allocator.free(meta_content);

    const fm = parseFrontmatter(meta_content);
    const bundle_name = fm.name orelse {
        try stderr.print("{s}{s}{s}Error:{s} Meta-prompt file must have 'name' in frontmatter\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Example:\n", .{P});
        try stderr.print("{s}  {s}---{s}\n", .{ P, Color.dim, Color.reset });
        try stderr.print("{s}  {s}name: my-bundle{s}\n", .{ P, Color.dim, Color.reset });
        try stderr.print("{s}  {s}description: A starter bundle{s}\n", .{ P, Color.dim, Color.reset });
        try stderr.print("{s}  {s}task: coding{s}\n", .{ P, Color.dim, Color.reset });
        try stderr.print("{s}  {s}---{s}\n", .{ P, Color.dim, Color.reset });
        return;
    };
    const description = fm.description orelse "-";
    const task = fm.task orelse "-";

    // Validate bundle name: must contain at least one non-hex character
    if (isHexString(bundle_name)) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle name must contain at least one non-hex character\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Names like '{s}' are ambiguous with prompt hashes\n", .{ P, bundle_name });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync, quiet_git) catch return;
    defer allocator.free(registry_path);

    if (bundleExists(allocator, registry_path, bundle_name)) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle already exists: {s}\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name });
        try stderr.print("{s}Use {s}clumsies rm {s}{s} to remove it first\n", .{ P, Color.cyan, bundle_name, Color.reset });
        return;
    }

    // Ensure registry directories exist
    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    const bundles_dir = try std.fs.path.join(allocator, &.{ registry_path, "bundles" });
    defer allocator.free(bundles_dir);
    fs.cwd().makePath(bundles_dir) catch {};

    // Collect prompts
    var sp = spinner.init(stdout, "Uploading prompts");
    sp.start();

    var prompt_refs: std.ArrayListUnmanaged(PromptRef) = .{};
    defer freePromptRefs(allocator, &prompt_refs);

    for (dirs) |dir_arg| {
        const dir_path = if (std.fs.path.isAbsolute(dir_arg))
            try allocator.dupe(u8, dir_arg)
        else
            try std.fs.path.join(allocator, &.{ cwd, dir_arg });
        defer allocator.free(dir_path);

        const category = std.fs.path.basename(dir_arg);
        collectAndUploadPrompts(allocator, dir_path, category, prompts_dir, &prompt_refs) catch continue;
    }

    if (prompt_refs.items.len == 0) {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} No prompt files found in specified directories\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }
    sp.succeed();

    // Upload meta-prompt file as a regular prompt with category "../"
    var sp_meta = spinner.init(stdout, "Uploading meta-prompt");
    sp_meta.start();

    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(meta_content, &hash_bytes, .{});
    var hash_hex: [64]u8 = undefined;
    hexEncode(&hash_bytes, &hash_hex);
    const meta_prompt_hash = try allocator.dupe(u8, &hash_hex);
    defer allocator.free(meta_prompt_hash);

    const meta_dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, meta_prompt_hash });
    defer allocator.free(meta_dest_path);

    const meta_dest_file = fs.createFileAbsolute(meta_dest_path, .{}) catch {
        sp_meta.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to write meta-prompt to registry\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    meta_dest_file.writeAll(meta_content) catch {
        meta_dest_file.close();
        sp_meta.fail();
        return;
    };
    meta_dest_file.close();

    // Extract meta-prompt name from filename (e.g., "CLAUDE" from "CLAUDE.md")
    const meta_basename = std.fs.path.basename(meta_prompt_path_arg);
    const meta_ext_idx = std.mem.lastIndexOf(u8, meta_basename, ".");
    const meta_name = if (meta_ext_idx) |idx| meta_basename[0..idx] else meta_basename;
    const meta_format = if (meta_ext_idx) |idx| meta_basename[idx + 1 ..] else "md";

    // Add MPF as a PromptRef with category "../"
    try prompt_refs.append(allocator, .{
        .hash = try allocator.dupe(u8, meta_prompt_hash),
        .category = try allocator.dupe(u8, META_PROMPT_CATEGORY),
        .name = try allocator.dupe(u8, meta_name),
        .description = try allocator.dupe(u8, description),
        .format = try allocator.dupe(u8, meta_format),
    });
    sp_meta.succeed();

    // Update prompts/index.json (includes both regular prompts and MPF)
    var sp2 = spinner.init(stdout, "Updating prompts index");
    sp2.start();
    updatePromptsIndex(allocator, registry_path, prompt_refs.items) catch {
        sp2.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to update prompts index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    sp2.succeed();

    // Create bundle entry
    var sp3 = spinner.init(stdout, "Creating bundle");
    sp3.start();

    const index_path = try std.fs.path.join(allocator, &.{ bundles_dir, "index.json" });
    defer allocator.free(index_path);

    var existing_bundles: std.ArrayListUnmanaged(u8) = .{};
    defer existing_bundles.deinit(allocator);
    var has_existing_bundles: bool = false;

    if (fs.openFileAbsolute(index_path, .{})) |idx_file| {
        const idx_content = idx_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            idx_file.close();
            sp3.fail();
            return;
        };
        idx_file.close();
        defer allocator.free(idx_content);

        if (std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value.object.get("bundles")) |bundles| {
                try existing_bundles.appendSlice(allocator, "{\n  \"bundles\": [");
                for (bundles.array.items, 0..) |item, idx| {
                    if (idx > 0) try existing_bundles.appendSlice(allocator, ",");
                    try appendBundleEntry(allocator, &existing_bundles, item);
                    has_existing_bundles = true;
                }
            }
        } else |_| {}
    } else |_| {
        try existing_bundles.appendSlice(allocator, "{\n  \"bundles\": [");
    }

    const timestamp = std.time.timestamp();
    const comma = if (has_existing_bundles) "," else "";

    const esc_bundle_name = try jsonEscapeAlloc(allocator, bundle_name);
    defer allocator.free(esc_bundle_name);
    const esc_task = try jsonEscapeAlloc(allocator, task);
    defer allocator.free(esc_task);
    const esc_description = try jsonEscapeAlloc(allocator, description);
    defer allocator.free(esc_description);

    const new_entry_start = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{d}\",\n      \"meta_prompt\": \"{s}\",\n      \"prompts\": [", .{
        comma,
        esc_bundle_name,
        esc_task,
        esc_description,
        timestamp,
        meta_prompt_hash,
    });
    defer allocator.free(new_entry_start);
    try existing_bundles.appendSlice(allocator, new_entry_start);

    for (prompt_refs.items, 0..) |ref, idx| {
        const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\" }}", .{
            if (idx > 0) "," else "",
            ref.hash,
        });
        defer allocator.free(ref_entry);
        try existing_bundles.appendSlice(allocator, ref_entry);
    }

    try existing_bundles.appendSlice(allocator, "]\n    }\n  ]\n}\n");

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        sp3.fail();
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(existing_bundles.items) catch {
        sp3.fail();
        return;
    };
    sp3.succeed();

    // Commit and push
    var sp4 = spinner.init(stdout, "Pushing to registry");
    sp4.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {
        sp4.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to stage changes\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    git.commit(allocator, registry_path, "Add bundle", &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.push(allocator, registry_path, &git_output) catch {
        sp4.fail();
        printGitOutputRaw(&git_output, quiet_git);
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp4.succeed();
    printGitOutputRaw(&git_output, quiet_git);

    try stdout.print("{s}{s}{s}✓{s} Published bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    try stdout.print("{s}Prompts: {d}\n", .{ P, prompt_refs.items.len });
}

fn printHelp(out: *std.io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies pub <meta-prompt-file> <dirs>... [-s]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Publish a bundle to registry.\n", .{P});
    try out.print("{s}The meta-prompt file must have frontmatter with at least 'name':\n", .{P});
    try out.print("{s}  {s}---{s}\n", .{ P, Color.dim, Color.reset });
    try out.print("{s}  {s}name: my-bundle{s}\n", .{ P, Color.dim, Color.reset });
    try out.print("{s}  {s}description: A starter bundle{s}\n", .{ P, Color.dim, Color.reset });
    try out.print("{s}  {s}task: coding{s}\n", .{ P, Color.dim, Color.reset });
    try out.print("{s}  {s}---{s}\n", .{ P, Color.dim, Color.reset });
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-s, --sync{s}       Sync registry before command\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-Q, --quiet-git{s}  Suppress git output\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-h, --help{s}       Show this help\n", .{ P, Color.cyan, Color.reset });
}
