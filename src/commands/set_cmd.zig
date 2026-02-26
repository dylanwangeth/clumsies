const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;
const hexEncode = commands.hexEncode;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const ensureRegistry = commands.ensureRegistry;
const resolveRef = commands.resolveRef;
const appendBundleEntry = commands.appendBundleEntry;
const PromptRef = commands.PromptRef;
const collectAndUploadPrompts = commands.collectAndUploadPrompts;
const updatePromptsIndex = commands.updatePromptsIndex;
const freePromptRefs = commands.freePromptRefs;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printHelp(stderr);
        return;
    }

    // First positional arg is the ref
    var ref: ?[]const u8 = null;
    var sync: bool = false;
    var quiet_git: bool = false;

    // Quick scan for ref and sync
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-Q") or std.mem.eql(u8, arg, "--quiet-git")) {
            quiet_git = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sync")) {
            sync = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp(stdout);
            return;
        } else if (ref == null and !std.mem.startsWith(u8, arg, "-")) {
            ref = arg;
        }
    }

    if (ref == null) {
        try stderr.print("{s}{s}{s}Error:{s} Reference required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync, quiet_git) catch return;
    defer allocator.free(registry_path);

    const kind = resolveRef(allocator, registry_path, ref.?);

    switch (kind) {
        .prompt => try setPrompt(stdout, stderr, allocator, registry_path, ref.?, args, quiet_git),
        .bundle => try setBundle(stdout, stderr, allocator, registry_path, ref.?, args, quiet_git),
        .not_found => {
            try stderr.print("{s}{s}{s}Error:{s} Not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, ref.? });
        },
    }
}

fn setPrompt(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, hash: []const u8, args: []const []const u8, quiet_git: bool) !void {
    var name_flag: ?[]const u8 = null;
    var desc_flag: ?[]const u8 = null;
    var cat_flag: ?[]const u8 = null;
    var file_flag: ?[]const u8 = null;
    var all_flag: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--name")) {
            if (i + 1 < args.len) {
                i += 1;
                name_flag = args[i];
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --name requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--desc")) {
            if (i + 1 < args.len) {
                i += 1;
                desc_flag = args[i];
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --desc requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cat")) {
            if (i + 1 < args.len) {
                i += 1;
                cat_flag = args[i];
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --cat requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            if (i + 1 < args.len) {
                i += 1;
                file_flag = args[i];
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --file requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.eql(u8, arg, "--all")) {
            all_flag = true;
        }
    }

    // --all requires --cat
    if (all_flag and cat_flag == null) {
        try stderr.print("{s}{s}{s}Error:{s} --all requires --cat\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    // --all with --cat: batch rename category (like old rename-cat)
    if (all_flag and cat_flag != null) {
        try renameCatFromRef(stdout, stderr, allocator, registry_path, hash, cat_flag.?, quiet_git);
        return;
    }

    if (file_flag != null) {
        // Replace content (produces new hash)
        try replacePrompt(stdout, stderr, allocator, registry_path, hash, file_flag.?, desc_flag, cat_flag, quiet_git);
    } else {
        // Update metadata only
        if (name_flag == null and desc_flag == null and cat_flag == null) {
            try stderr.print("{s}{s}{s}Error:{s} At least one of -n, -d, -c, or -f required\n", .{ P, Color.bold, Color.red, Color.reset });
            try stderr.print("{s}Usage: {s}clumsies set <hash> [-n name] [-d desc] [-c cat] [-f file] [--all]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
        try updatePromptMeta(stdout, stderr, allocator, registry_path, hash, name_flag, desc_flag, cat_flag, quiet_git);
    }
}

fn updatePromptMeta(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, hash: []const u8, name_flag: ?[]const u8, desc_flag: ?[]const u8, cat_flag: ?[]const u8, quiet_git: bool) !void {
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

    var found = false;
    var new_index: std.ArrayListUnmanaged(u8) = .{};
    defer new_index.deinit(allocator);

    try new_index.appendSlice(allocator, "{\n  \"prompts\": [");
    var first = true;

    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        var item_name = if (item.object.get("name")) |n| n.string else "-";
        var item_desc = if (item.object.get("description")) |d| d.string else "-";
        const item_format = if (item.object.get("format")) |f| f.string else "md";
        var item_category = if (item.object.get("category")) |p| p.string else "conduct";
        const item_created = if (item.object.get("created_at")) |c| c.string else "0";

        if (std.mem.startsWith(u8, item_hash, hash)) {
            found = true;
            if (name_flag) |n| item_name = n;
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
        printGitOutputRaw(&git_output, quiet_git);
        try stderr.print("{s}{s}{s}Warning:{s} Updated locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output, quiet_git);

    try stdout.print("{s}{s}{s}✓{s} Updated prompt metadata\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Hash: {s}{s}{s}\n", .{ P, Color.cyan, hash, Color.reset });
    if (name_flag) |n| try stdout.print("{s}  Name: {s}\n", .{ P, n });
    if (desc_flag) |d| try stdout.print("{s}  Description: {s}\n", .{ P, d });
    if (cat_flag) |c| try stdout.print("{s}  Category: {s}\n", .{ P, c });
    try stdout.writeAll("\n");
}

fn replacePrompt(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, hash: []const u8, file_path: []const u8, desc_flag: ?[]const u8, cat_flag: ?[]const u8, quiet_git: bool) !void {
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

    const new_file = fs.openFileAbsolute(abs_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not open file: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, file_path });
        return;
    };
    defer new_file.close();

    const new_content = new_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(new_content);

    var new_hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(new_content, &new_hash_bytes, .{});
    var new_hash_hex: [64]u8 = undefined;
    hexEncode(&new_hash_bytes, &new_hash_hex);

    const basename = std.fs.path.basename(file_path);
    const ext_idx = std.mem.lastIndexOf(u8, basename, ".");
    const new_format = if (ext_idx) |idx| basename[idx + 1 ..] else "md";

    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const idx_file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No prompts found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const idx_content = idx_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        idx_file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    idx_file.close();
    defer allocator.free(idx_content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const prompts = parsed.value.object.get("prompts") orelse {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    var old_full_hash: ?[]const u8 = null;
    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (std.mem.startsWith(u8, item_hash, hash)) {
            old_full_hash = item_hash;
            break;
        }
    }

    if (old_full_hash == null) {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, hash });
        return;
    }

    if (std.mem.eql(u8, old_full_hash.?, &new_hash_hex)) {
        if (desc_flag == null and cat_flag == null) {
            try stdout.print("{s}{s}{s}!{s} No changes — new file has the same hash\n", .{ P, Color.bold, Color.orange, Color.reset });
            try stdout.print("{s}  Hash: {s}{s}{s}\n\n", .{ P, Color.cyan, new_hash_hex, Color.reset });
            return;
        }
    }

    const hash_changed = !std.mem.eql(u8, old_full_hash.?, &new_hash_hex);

    if (hash_changed) {
        const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
        defer allocator.free(prompts_dir);

        const new_dest = try std.fs.path.join(allocator, &.{ prompts_dir, &new_hash_hex });
        defer allocator.free(new_dest);

        const dest_file = fs.createFileAbsolute(new_dest, .{}) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to create file in registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer dest_file.close();
        dest_file.writeAll(new_content) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to write file\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };

        const old_path = try std.fs.path.join(allocator, &.{ prompts_dir, old_full_hash.? });
        defer allocator.free(old_path);
        fs.deleteFileAbsolute(old_path) catch {};
    }

    // Rebuild prompts/index.json
    var new_index: std.ArrayListUnmanaged(u8) = .{};
    defer new_index.deinit(allocator);

    try new_index.appendSlice(allocator, "{\n  \"prompts\": [");
    var first = true;

    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        var item_name = if (item.object.get("name")) |n| n.string else "-";
        var item_desc = if (item.object.get("description")) |d| d.string else "-";
        var item_format = if (item.object.get("format")) |f| f.string else "md";
        var item_category = if (item.object.get("category")) |p| p.string else "conduct";
        const item_created = if (item.object.get("created_at")) |c| c.string else "0";

        var use_hash = item_hash;

        if (std.mem.eql(u8, item_hash, old_full_hash.?)) {
            use_hash = &new_hash_hex;
            if (desc_flag) |d| item_desc = d;
            if (cat_flag) |c| item_category = c;
            if (hash_changed) item_format = new_format;
            _ = &item_name;
        }

        if (!first) try new_index.appendSlice(allocator, ",");
        first = false;

        const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ use_hash, item_name, item_desc, item_format, item_category, item_created });
        defer allocator.free(entry);
        try new_index.appendSlice(allocator, entry);
    }
    try new_index.appendSlice(allocator, "\n  ]\n}\n");

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(new_index.items) catch {};

    // Update bundles/index.json hash refs
    if (hash_changed) {
        const bundles_index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
        defer allocator.free(bundles_index_path);

        if (fs.openFileAbsolute(bundles_index_path, .{})) |bfile| {
            const bcontent = bfile.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
                bfile.close();
                return;
            };
            bfile.close();
            defer allocator.free(bcontent);

            if (std.json.parseFromSlice(std.json.Value, allocator, bcontent, .{})) |bparsed| {
                defer bparsed.deinit();

                if (bparsed.value.object.get("bundles")) |bundles| {
                    var new_bidx: std.ArrayListUnmanaged(u8) = .{};
                    defer new_bidx.deinit(allocator);
                    try new_bidx.appendSlice(allocator, "{\n  \"bundles\": [");

                    var bfirst = true;
                    for (bundles.array.items) |bitem| {
                        const bname = if (bitem.object.get("name")) |n| n.string else continue;
                        const btask = if (bitem.object.get("task")) |t| t.string else "-";
                        const bdesc = if (bitem.object.get("description")) |d| d.string else "-";
                        const bcreated = if (bitem.object.get("created_at")) |c| c.string else "0";
                        const bmeta = if (bitem.object.get("meta_prompt")) |m| m.string else "";

                        if (!bfirst) try new_bidx.appendSlice(allocator, ",");
                        bfirst = false;

                        const bentry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"categories\": [", .{ bname, btask, bdesc, bcreated, bmeta });
                        defer allocator.free(bentry_start);
                        try new_bidx.appendSlice(allocator, bentry_start);

                        if (bitem.object.get("categories")) |categories| {
                            for (categories.array.items, 0..) |cat, cidx| {
                                const cat_entry = try std.fmt.allocPrint(allocator, "{s}\"{s}\"", .{
                                    if (cidx > 0) ", " else "",
                                    cat.string,
                                });
                                defer allocator.free(cat_entry);
                                try new_bidx.appendSlice(allocator, cat_entry);
                            }
                        } else if (bitem.object.get("prompts")) |bprompts| {
                            var seen_cats = std.StringHashMap(void).init(allocator);
                            defer seen_cats.deinit();
                            var cat_list: std.ArrayListUnmanaged([]const u8) = .{};
                            defer cat_list.deinit(allocator);
                            for (bprompts.array.items) |ref| {
                                const cat = if (ref.object.get("category")) |c| c.string else continue;
                                if (!seen_cats.contains(cat)) {
                                    seen_cats.put(cat, {}) catch {};
                                    cat_list.append(allocator, cat) catch {};
                                }
                            }
                            for (cat_list.items, 0..) |cat, cidx| {
                                const cat_entry = try std.fmt.allocPrint(allocator, "{s}\"{s}\"", .{
                                    if (cidx > 0) ", " else "",
                                    cat,
                                });
                                defer allocator.free(cat_entry);
                                try new_bidx.appendSlice(allocator, cat_entry);
                            }
                        }

                        try new_bidx.appendSlice(allocator, "],\n      \"prompts\": [");

                        if (bitem.object.get("prompts")) |bprompts| {
                            if (bitem.object.get("categories") != null) {
                                for (bprompts.array.items, 0..) |ref, ridx| {
                                    const ref_hash = if (ref.object.get("hash")) |h| h.string else continue;
                                    const ref_cat = if (ref.object.get("category")) |c| c.string else continue;
                                    const out_hash = if (std.mem.eql(u8, ref_hash, old_full_hash.?)) &new_hash_hex else ref_hash;
                                    const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
                                        if (ridx > 0) "," else "",
                                        out_hash,
                                        ref_cat,
                                    });
                                    defer allocator.free(ref_entry);
                                    try new_bidx.appendSlice(allocator, ref_entry);
                                }
                            }
                        }
                        try new_bidx.appendSlice(allocator, "]\n    }");
                    }
                    try new_bidx.appendSlice(allocator, "\n  ]\n}\n");

                    const bidx_out = fs.createFileAbsolute(bundles_index_path, .{}) catch return;
                    defer bidx_out.close();
                    bidx_out.writeAll(new_bidx.items) catch {};
                }
            } else |_| {}
        } else |_| {}
    }

    // Commit and push
    var sp = spinner.init(stdout, "Replacing prompt");
    sp.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {};

    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    git.commit(allocator, registry_path, "Replace prompt", &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.push(allocator, registry_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output, quiet_git);
        try stderr.print("{s}{s}{s}Warning:{s} Replaced locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output, quiet_git);

    try stdout.print("{s}{s}{s}✓{s} Replaced prompt\n", .{ P, Color.bold, Color.green, Color.reset });
    if (hash_changed) {
        try stdout.print("{s}  Old hash: {s}{s}{s}\n", .{ P, Color.dim, old_full_hash.?, Color.reset });
        try stdout.print("{s}  New hash: {s}{s}{s}\n", .{ P, Color.cyan, new_hash_hex, Color.reset });
    } else {
        try stdout.print("{s}  Hash: {s}{s}{s} (unchanged)\n", .{ P, Color.cyan, new_hash_hex, Color.reset });
    }
    if (desc_flag) |d| try stdout.print("{s}  Description: {s}\n", .{ P, d });
    if (cat_flag) |c| try stdout.print("{s}  Category: {s}\n", .{ P, c });
    try stdout.writeAll("\n");
}

fn renameCatFromRef(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, hash: []const u8, new_cat: []const u8, quiet_git: bool) !void {
    // Read prompts/index.json to find the old category of this prompt
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const idx_file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No prompts found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const idx_content = idx_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        idx_file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    idx_file.close();
    defer allocator.free(idx_content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const prompts = parsed.value.object.get("prompts") orelse {
        try stderr.print("{s}{s}{s}Error:{s} No prompts in index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Find old category from the target prompt
    var old_cat: ?[]const u8 = null;
    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (std.mem.startsWith(u8, item_hash, hash)) {
            old_cat = if (item.object.get("category")) |c| c.string else "conduct";
            break;
        }
    }

    if (old_cat == null) {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, hash });
        return;
    }

    const old = old_cat.?;

    if (std.mem.eql(u8, old, new_cat)) {
        try stderr.print("{s}{s}{s}Error:{s} Old and new category are the same\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    // Rename all prompts with old_cat to new_cat
    var rename_count: usize = 0;
    var new_index: std.ArrayListUnmanaged(u8) = .{};
    defer new_index.deinit(allocator);

    try new_index.appendSlice(allocator, "{\n  \"prompts\": [");
    var first = true;

    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        const item_name = if (item.object.get("name")) |n| n.string else "-";
        const item_desc = if (item.object.get("description")) |d| d.string else "-";
        const item_format = if (item.object.get("format")) |f| f.string else "md";
        var item_category = if (item.object.get("category")) |p| p.string else "conduct";
        const item_created = if (item.object.get("created_at")) |c| c.string else "0";

        if (std.mem.eql(u8, item_category, old)) {
            item_category = new_cat;
            rename_count += 1;
        }

        if (!first) try new_index.appendSlice(allocator, ",");
        first = false;

        const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_desc, item_format, item_category, item_created });
        defer allocator.free(entry);
        try new_index.appendSlice(allocator, entry);
    }
    try new_index.appendSlice(allocator, "\n  ]\n}\n");

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(new_index.items) catch {};

    // Update bundles/index.json
    const bundles_index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(bundles_index_path);

    if (fs.openFileAbsolute(bundles_index_path, .{})) |bfile| {
        const bcontent = bfile.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            bfile.close();
            return;
        };
        bfile.close();
        defer allocator.free(bcontent);

        if (std.json.parseFromSlice(std.json.Value, allocator, bcontent, .{})) |bparsed| {
            defer bparsed.deinit();

            if (bparsed.value.object.get("bundles")) |bundles| {
                var new_bidx: std.ArrayListUnmanaged(u8) = .{};
                defer new_bidx.deinit(allocator);
                try new_bidx.appendSlice(allocator, "{\n  \"bundles\": [");

                var bfirst = true;
                for (bundles.array.items) |bitem| {
                    const bname = if (bitem.object.get("name")) |n| n.string else continue;
                    const btask = if (bitem.object.get("task")) |t| t.string else "-";
                    const bdesc = if (bitem.object.get("description")) |d| d.string else "-";
                    const bcreated = if (bitem.object.get("created_at")) |c| c.string else "0";
                    const bmeta = if (bitem.object.get("meta_prompt")) |m| m.string else "";

                    if (!bfirst) try new_bidx.appendSlice(allocator, ",");
                    bfirst = false;

                    const bentry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"categories\": [", .{ bname, btask, bdesc, bcreated, bmeta });
                    defer allocator.free(bentry_start);
                    try new_bidx.appendSlice(allocator, bentry_start);

                    if (bitem.object.get("categories")) |categories| {
                        for (categories.array.items, 0..) |cat, cidx| {
                            const cat_str = if (std.mem.eql(u8, cat.string, old)) new_cat else cat.string;
                            const cat_entry = try std.fmt.allocPrint(allocator, "{s}\"{s}\"", .{
                                if (cidx > 0) ", " else "",
                                cat_str,
                            });
                            defer allocator.free(cat_entry);
                            try new_bidx.appendSlice(allocator, cat_entry);
                        }
                    }

                    try new_bidx.appendSlice(allocator, "],\n      \"prompts\": [");

                    if (bitem.object.get("prompts")) |bprompts| {
                        for (bprompts.array.items, 0..) |ref, ridx| {
                            const ref_hash = if (ref.object.get("hash")) |h| h.string else continue;
                            const ref_cat = if (ref.object.get("category")) |c| c.string else continue;
                            const out_cat = if (std.mem.eql(u8, ref_cat, old)) new_cat else ref_cat;
                            const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
                                if (ridx > 0) "," else "",
                                ref_hash,
                                out_cat,
                            });
                            defer allocator.free(ref_entry);
                            try new_bidx.appendSlice(allocator, ref_entry);
                        }
                    }
                    try new_bidx.appendSlice(allocator, "]\n    }");
                }
                try new_bidx.appendSlice(allocator, "\n  ]\n}\n");

                const bidx_out = fs.createFileAbsolute(bundles_index_path, .{}) catch return;
                defer bidx_out.close();
                bidx_out.writeAll(new_bidx.items) catch {};
            }
        } else |_| {}
    } else |_| {}

    // Commit and push
    var sp = spinner.init(stdout, "Renaming category");
    sp.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {};

    const commit_msg = try std.fmt.allocPrint(allocator, "Rename category: {s} -> {s}", .{ old, new_cat });
    defer allocator.free(commit_msg);

    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    git.commit(allocator, registry_path, commit_msg, &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.push(allocator, registry_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output, quiet_git);
        try stderr.print("{s}{s}{s}Warning:{s} Renamed locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output, quiet_git);

    try stdout.print("{s}{s}{s}✓{s} Renamed category: {s} → {s}\n", .{ P, Color.bold, Color.green, Color.reset, old, new_cat });
    try stdout.print("{s}  {s}{d}{s} prompt(s) updated\n\n", .{ P, Color.cyan, rename_count, Color.reset });
}

fn setBundle(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, bundle_name: []const u8, args: []const []const u8, quiet_git: bool) !void {
    // Parse bundle-specific flags
    var add_dirs: std.ArrayListUnmanaged([]const u8) = .{};
    defer add_dirs.deinit(allocator);
    var rm_prompt_hashes: std.ArrayListUnmanaged([]const u8) = .{};
    defer rm_prompt_hashes.deinit(allocator);
    var add_prompt_hashes: std.ArrayListUnmanaged([]const u8) = .{};
    defer add_prompt_hashes.deinit(allocator);
    var meta_file_arg: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--add")) {
            i += 1;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                try add_dirs.append(allocator, args[i]);
            }
            if (i < args.len) i -= 1;
        } else if (std.mem.eql(u8, args[i], "--rm-prompt")) {
            i += 1;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                try rm_prompt_hashes.append(allocator, args[i]);
            }
            if (i < args.len) i -= 1;
        } else if (std.mem.eql(u8, args[i], "--add-prompt")) {
            i += 1;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                try add_prompt_hashes.append(allocator, args[i]);
            }
            if (i < args.len) i -= 1;
        } else if (std.mem.eql(u8, args[i], "--meta")) {
            i += 1;
            if (i < args.len and !std.mem.startsWith(u8, args[i], "--")) {
                meta_file_arg = args[i];
            }
        }
    }

    if (add_dirs.items.len == 0 and rm_prompt_hashes.items.len == 0 and add_prompt_hashes.items.len == 0 and meta_file_arg == null) {
        try stderr.print("{s}{s}{s}Error:{s} No changes specified\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies set <bundle> [--add <dirs>] [--rm-prompt <hash>] [--add-prompt <hash>] [--meta <file>]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    // Process --meta
    var new_meta_hash: ?[]const u8 = null;
    defer if (new_meta_hash) |h| allocator.free(h);

    if (meta_file_arg) |meta_arg| {
        const meta_path = if (std.fs.path.isAbsolute(meta_arg))
            try allocator.dupe(u8, meta_arg)
        else
            try std.fs.path.join(allocator, &.{ cwd, meta_arg });
        defer allocator.free(meta_path);

        const meta_file = fs.openFileAbsolute(meta_path, .{}) catch {
            try stderr.print("{s}{s}{s}Error:{s} Could not open meta-prompt file: {s}\n", .{ P, Color.bold, Color.red, Color.reset, meta_arg });
            return;
        };
        const meta_content = meta_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            meta_file.close();
            try stderr.print("{s}{s}{s}Error:{s} Failed to read meta-prompt file\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        meta_file.close();
        defer allocator.free(meta_content);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(meta_content, &hash_bytes, .{});
        var hash_hex: [64]u8 = undefined;
        hexEncode(&hash_bytes, &hash_hex);
        new_meta_hash = try allocator.dupe(u8, &hash_hex);

        const meta_prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "meta-prompts" });
        defer allocator.free(meta_prompts_dir);
        fs.cwd().makePath(meta_prompts_dir) catch {};

        const meta_dest_path = try std.fs.path.join(allocator, &.{ meta_prompts_dir, new_meta_hash.? });
        defer allocator.free(meta_dest_path);

        const meta_dest_file = fs.createFileAbsolute(meta_dest_path, .{}) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to write meta-prompt to registry\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        meta_dest_file.writeAll(meta_content) catch {
            meta_dest_file.close();
            return;
        };
        meta_dest_file.close();
    }

    // Process --add
    var new_refs: std.ArrayListUnmanaged(PromptRef) = .{};
    defer freePromptRefs(allocator, &new_refs);

    if (add_dirs.items.len > 0) {
        var sp_add = spinner.init(stdout, "Uploading prompts");
        sp_add.start();

        for (add_dirs.items) |dir_arg| {
            const dir_path = if (std.fs.path.isAbsolute(dir_arg))
                try allocator.dupe(u8, dir_arg)
            else
                try std.fs.path.join(allocator, &.{ cwd, dir_arg });
            defer allocator.free(dir_path);

            const category = std.fs.path.basename(dir_arg);
            collectAndUploadPrompts(allocator, dir_path, category, prompts_dir, &new_refs) catch continue;
        }

        if (new_refs.items.len == 0) {
            sp_add.fail();
            try stderr.print("{s}{s}{s}Error:{s} No prompt files found in specified directories\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        }
        sp_add.succeed();

        var sp_idx = spinner.init(stdout, "Updating prompts index");
        sp_idx.start();
        updatePromptsIndex(allocator, registry_path, new_refs.items) catch {
            sp_idx.fail();
            try stderr.print("{s}{s}{s}Error:{s} Failed to update prompts index\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        sp_idx.succeed();
    }

    // Update bundle index
    var sp_update = spinner.init(stdout, "Updating bundle");
    sp_update.start();

    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const idx_file = fs.openFileAbsolute(index_path, .{}) catch {
        sp_update.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read bundle index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    const idx_content = idx_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        idx_file.close();
        sp_update.fail();
        return;
    };
    idx_file.close();
    defer allocator.free(idx_content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{}) catch {
        sp_update.fail();
        return;
    };
    defer parsed.deinit();

    const bundles = parsed.value.object.get("bundles") orelse {
        sp_update.fail();
        return;
    };

    var new_index: std.ArrayListUnmanaged(u8) = .{};
    defer new_index.deinit(allocator);
    try new_index.appendSlice(allocator, "{\n  \"bundles\": [");

    var b_first = true;
    var cats_added: usize = 0;
    var prompts_added: usize = 0;
    var prompts_removed: usize = 0;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;

        if (!b_first) try new_index.appendSlice(allocator, ",");
        b_first = false;

        if (std.mem.eql(u8, item_name, bundle_name)) {
            const item_task = if (item.object.get("task")) |t| t.string else "-";
            const item_desc = if (item.object.get("description")) |d| d.string else "-";
            const item_created = if (item.object.get("created_at")) |c| c.string else "0";
            const item_meta = new_meta_hash orelse (if (item.object.get("meta_prompt")) |m| m.string else "");

            const entry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"categories\": [", .{ item_name, item_task, item_desc, item_created, item_meta });
            defer allocator.free(entry_start);
            try new_index.appendSlice(allocator, entry_start);

            // Build categories
            var cat_set = std.StringHashMap(void).init(allocator);
            defer cat_set.deinit();
            var cat_order: std.ArrayListUnmanaged([]const u8) = .{};
            defer cat_order.deinit(allocator);

            if (item.object.get("categories")) |existing_cats| {
                for (existing_cats.array.items) |c| {
                    if (!cat_set.contains(c.string)) {
                        cat_set.put(c.string, {}) catch {};
                        cat_order.append(allocator, c.string) catch {};
                    }
                }
            } else if (item.object.get("prompts")) |old_prompts| {
                for (old_prompts.array.items) |ref| {
                    const cat = if (ref.object.get("category")) |c| c.string else continue;
                    if (!cat_set.contains(cat)) {
                        cat_set.put(cat, {}) catch {};
                        cat_order.append(allocator, cat) catch {};
                    }
                }
            }

            for (new_refs.items) |ref| {
                if (!cat_set.contains(ref.category)) {
                    cat_set.put(ref.category, {}) catch {};
                    cat_order.append(allocator, ref.category) catch {};
                    cats_added += 1;
                }
            }

            var cat_first = true;
            for (cat_order.items) |cat| {
                if (!cat_set.contains(cat)) continue;
                const cat_entry = try std.fmt.allocPrint(allocator, "{s}\"{s}\"", .{
                    if (cat_first) "" else ", ",
                    cat,
                });
                defer allocator.free(cat_entry);
                try new_index.appendSlice(allocator, cat_entry);
                cat_first = false;
            }

            try new_index.appendSlice(allocator, "],\n      \"prompts\": [");

            var prompt_first = true;

            // Keep existing precise prompts minus --rm-prompt
            if (item.object.get("categories") != null) {
                if (item.object.get("prompts")) |existing_prompts| {
                    for (existing_prompts.array.items) |ref| {
                        const ref_hash = if (ref.object.get("hash")) |h| h.string else continue;
                        const cat = if (ref.object.get("category")) |c| c.string else continue;

                        var should_remove = false;
                        for (rm_prompt_hashes.items) |rm_hash| {
                            if (std.mem.startsWith(u8, ref_hash, rm_hash)) {
                                should_remove = true;
                                prompts_removed += 1;
                                break;
                            }
                        }
                        if (should_remove) continue;

                        const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
                            if (prompt_first) "" else ",",
                            ref_hash,
                            cat,
                        });
                        defer allocator.free(ref_entry);
                        try new_index.appendSlice(allocator, ref_entry);
                        prompt_first = false;
                    }
                }
            }

            // Add --add-prompt hashes
            for (add_prompt_hashes.items) |add_hash| {
                var found_cat: []const u8 = "conduct";
                const p_idx_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
                defer allocator.free(p_idx_path);
                if (fs.openFileAbsolute(p_idx_path, .{})) |pf| {
                    defer pf.close();
                    if (pf.readToEndAlloc(allocator, MAX_FILE_SIZE)) |pc| {
                        defer allocator.free(pc);
                        if (std.json.parseFromSlice(std.json.Value, allocator, pc, .{})) |pp| {
                            defer pp.deinit();
                            if (pp.value.object.get("prompts")) |pl| {
                                for (pl.array.items) |p| {
                                    const ph = if (p.object.get("hash")) |h| h.string else continue;
                                    if (std.mem.startsWith(u8, ph, add_hash)) {
                                        found_cat = if (p.object.get("category")) |c| c.string else "conduct";
                                        break;
                                    }
                                }
                            }
                        } else |_| {}
                    } else |_| {}
                } else |_| {}

                const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
                    if (prompt_first) "" else ",",
                    add_hash,
                    found_cat,
                });
                defer allocator.free(ref_entry);
                try new_index.appendSlice(allocator, ref_entry);
                prompt_first = false;
                prompts_added += 1;
            }

            try new_index.appendSlice(allocator, "]\n    }");
        } else {
            try appendBundleEntry(allocator, &new_index, item);
        }
    }
    try new_index.appendSlice(allocator, "\n  ]\n}\n");

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        sp_update.fail();
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(new_index.items) catch {
        sp_update.fail();
        return;
    };
    sp_update.succeed();

    // Commit and push
    var sp_push = spinner.init(stdout, "Pushing to registry");
    sp_push.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {};

    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    git.commit(allocator, registry_path, "Update bundle", &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.push(allocator, registry_path, &git_output) catch {
        sp_push.fail();
        printGitOutputRaw(&git_output, quiet_git);
        try stderr.print("{s}{s}{s}Warning:{s} Updated locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp_push.succeed();
    printGitOutputRaw(&git_output, quiet_git);

    try stdout.print("{s}{s}{s}✓{s} Updated bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    if (new_meta_hash != null) try stdout.print("{s}    Meta-prompt updated\n", .{P});
    if (cats_added > 0) try stdout.print("{s}    Categories added: {d}\n", .{ P, cats_added });
    if (prompts_added > 0) try stdout.print("{s}    Prompts added: {d}\n", .{ P, prompts_added });
    if (prompts_removed > 0) try stdout.print("{s}    Prompts removed: {d}\n", .{ P, prompts_removed });
}

fn printHelp(out: *std.io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies set <ref> [options] [-s]{s}\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Update prompt metadata/content or bundle composition.\n", .{P});
    try out.print("{s}Type is auto-detected: hex = prompt, otherwise = bundle.\n\n", .{P});
    try out.print("{s}{s}{s}Prompt options:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try out.print("{s}  {s}-n, --name{s} <name>   Rename prompt\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-c, --cat{s} <cat>     Change category\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-c --cat{s} <cat> {s}--all{s}  Rename category for all prompts with same old category\n", .{ P, Color.cyan, Color.reset, Color.cyan, Color.reset });
    try out.print("{s}  {s}-d, --desc{s} <desc>   Change description\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-f, --file{s} <file>   Replace content (produces new hash)\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}{s}{s}Bundle options:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try out.print("{s}  {s}--add{s} <dirs>...         Add prompt files from directories\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--rm-prompt{s} <hash>...   Remove prompt from bundle\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--add-prompt{s} <hash>...  Add existing prompt to bundle\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--meta{s} <file>           Update meta-prompt\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Common options:\n", .{P});
    try out.print("{s}  {s}-s, --sync{s}       Sync registry before command\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-Q, --quiet-git{s}  Suppress git output\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-h, --help{s}       Show this help\n\n", .{ P, Color.cyan, Color.reset });
}
