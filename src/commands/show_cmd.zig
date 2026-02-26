const std = @import("std");
const fs = std.fs;
const commands = @import("commands.zig");

const Color = commands.Color;
const P = commands.P;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const ensureRegistry = commands.ensureRegistry;
const resolveRef = commands.resolveRef;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var ref: ?[]const u8 = null;
    var show_meta: bool = false;
    var sync: bool = false;
    var quiet_git: bool = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-Q") or std.mem.eql(u8, arg, "--quiet-git")) {
            quiet_git = true;
        } else if (std.mem.eql(u8, arg, "--meta")) {
            show_meta = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sync")) {
            sync = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp(stdout);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try printHelp(stderr);
            return;
        } else if (ref == null) {
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
        .prompt => try showPrompt(stdout, stderr, allocator, registry_path, ref.?),
        .bundle => try showBundle(stdout, stderr, allocator, registry_path, ref.?, show_meta),
        .not_found => {
            try stderr.print("{s}{s}{s}Error:{s} Not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, ref.? });
        },
    }
}

fn showPrompt(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, hash: []const u8) !void {
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

fn showBundle(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, name: []const u8, show_meta: bool) !void {
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found\n\n", .{ P, Color.bold, Color.red, Color.reset });
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

    const bundles = parsed.value.object.get("bundles") orelse {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    var found_bundle: ?std.json.Value = null;
    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;
        if (std.mem.eql(u8, item_name, name)) {
            found_bundle = item;
            break;
        }
    }

    if (found_bundle == null) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, name });
        return;
    }

    const bundle = found_bundle.?;
    const bundle_name = if (bundle.object.get("name")) |n| n.string else "-";
    const bundle_task = if (bundle.object.get("task")) |t| t.string else "-";
    const bundle_desc = if (bundle.object.get("description")) |d| d.string else "-";
    const bundle_meta = if (bundle.object.get("meta_prompt")) |m| m.string else "";

    try stdout.print("{s}{s}{s}Bundle:{s} {s}\n", .{ P, Color.bold, Color.orange, Color.reset, bundle_name });
    try stdout.print("{s}{s}Task:{s} {s}\n", .{ P, Color.orange, Color.reset, bundle_task });
    try stdout.print("{s}{s}Description:{s} {s}\n", .{ P, Color.orange, Color.reset, bundle_desc });
    if (bundle_meta.len > 0) {
        const short_meta = if (bundle_meta.len >= 8) bundle_meta[0..8] else bundle_meta;
        try stdout.print("{s}{s}Meta-prompt:{s} {s}\n", .{ P, Color.orange, Color.reset, short_meta });
    }
    try stdout.writeAll("\n");

    if (show_meta) {
        if (bundle_meta.len == 0) {
            try stderr.print("{s}{s}{s}Error:{s} Bundle has no meta-prompt\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        }
        const meta_path = try std.fs.path.join(allocator, &.{ registry_path, "meta-prompts", bundle_meta });
        defer allocator.free(meta_path);

        const meta_file = fs.openFileAbsolute(meta_path, .{}) catch {
            try stderr.print("{s}{s}{s}Error:{s} Meta-prompt file not found in registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer meta_file.close();

        const meta_content = meta_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to read meta-prompt file\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer allocator.free(meta_content);

        try stdout.writeAll(meta_content);
        if (meta_content.len > 0 and meta_content[meta_content.len - 1] != '\n') {
            try stdout.writeAll("\n");
        }
        return;
    }

    // Read prompts/index.json for resolving categories to prompts
    const prompts_index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(prompts_index_path);

    var prompts_index: ?std.json.Parsed(std.json.Value) = null;
    if (fs.openFileAbsolute(prompts_index_path, .{})) |pf| {
        defer pf.close();
        if (pf.readToEndAlloc(allocator, MAX_FILE_SIZE)) |pc| {
            defer allocator.free(pc);
            prompts_index = std.json.parseFromSlice(std.json.Value, allocator, pc, .{}) catch null;
        } else |_| {}
    } else |_| {}
    defer if (prompts_index) |pi| pi.deinit();

    const prompts_list = if (prompts_index) |pi| pi.value.object.get("prompts") else null;

    const has_categories = bundle.object.get("categories") != null;

    if (has_categories) {
        const categories = bundle.object.get("categories").?;

        try stdout.print("{s}{s}{s}Categories ({d}):{s}\n", .{ P, Color.bold, Color.orange, categories.array.items.len, Color.reset });
        for (categories.array.items) |cat_val| {
            try stdout.print("{s}  {s}{s}{s}\n", .{ P, Color.cyan, cat_val.string, Color.reset });
        }
        try stdout.writeAll("\n");

        try stdout.print("{s}{s}{s}Resolved prompts:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
        try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});
        try stdout.print("{s}  {s}HASH{s}      {s}CATEGORY{s}        {s}NAME{s}                  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
        try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});

        var total: usize = 0;

        if (prompts_list) |pl| {
            for (categories.array.items) |cat_val| {
                const cat = cat_val.string;
                for (pl.array.items) |p| {
                    const p_cat = if (p.object.get("category")) |c| c.string else continue;
                    if (std.mem.eql(u8, p_cat, cat)) {
                        const p_hash = if (p.object.get("hash")) |h| h.string else continue;
                        const p_name = if (p.object.get("name")) |n| n.string else "-";
                        const p_desc = if (p.object.get("description")) |d| d.string else "-";
                        const short_hash = if (p_hash.len >= 8) p_hash[0..8] else p_hash;

                        try stdout.print("{s}  {s}{s: <8}{s}  {s: <14}  {s: <20}  {s}\n", .{ P, Color.cyan, short_hash, Color.reset, p_cat, p_name, p_desc });
                        total += 1;
                    }
                }
            }
        }

        if (bundle.object.get("prompts")) |precise| {
            for (precise.array.items) |ref| {
                const hash = if (ref.object.get("hash")) |h| h.string else continue;
                const ref_cat = if (ref.object.get("category")) |c| c.string else "-";
                const short_hash = if (hash.len >= 8) hash[0..8] else hash;

                var p_name: []const u8 = "-";
                var p_desc: []const u8 = "-";
                if (prompts_list) |pl| {
                    for (pl.array.items) |p| {
                        const p_hash = if (p.object.get("hash")) |h| h.string else continue;
                        if (std.mem.eql(u8, p_hash, hash)) {
                            p_name = if (p.object.get("name")) |n| n.string else "-";
                            p_desc = if (p.object.get("description")) |d| d.string else "-";
                            break;
                        }
                    }
                }

                try stdout.print("{s}  {s}{s: <8}{s}  {s: <14}  {s: <20}  {s}  {s}(precise){s}\n", .{ P, Color.cyan, short_hash, Color.reset, ref_cat, p_name, p_desc, Color.dim, Color.reset });
                total += 1;
            }
        }

        if (total == 0) {
            try stdout.print("{s}  {s}(no matching prompts){s}\n", .{ P, Color.dim, Color.reset });
        }
    } else {
        const prompts_arr = bundle.object.get("prompts") orelse {
            try stdout.print("{s}{s}No prompts in bundle{s}\n\n", .{ P, Color.dim, Color.reset });
            return;
        };

        try stdout.print("{s}{s}{s}Prompts ({d}):{s}\n", .{ P, Color.bold, Color.orange, prompts_arr.array.items.len, Color.reset });
        try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});
        try stdout.print("{s}  {s}HASH{s}      {s}CATEGORY{s}        {s}NAME{s}                  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
        try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});

        for (prompts_arr.array.items) |ref| {
            const hash = if (ref.object.get("hash")) |h| h.string else "-";
            const category = if (ref.object.get("category")) |p| p.string else "-";
            const short_hash = if (hash.len >= 8) hash[0..8] else hash;

            var p_name: []const u8 = "-";
            var p_desc: []const u8 = "-";
            if (prompts_list) |pl| {
                for (pl.array.items) |p| {
                    const p_hash = if (p.object.get("hash")) |h| h.string else continue;
                    if (std.mem.eql(u8, p_hash, hash)) {
                        p_name = if (p.object.get("name")) |n| n.string else "-";
                        p_desc = if (p.object.get("description")) |d| d.string else "-";
                        break;
                    }
                }
            }

            try stdout.print("{s}  {s}{s: <8}{s}  {s: <14}  {s: <20}  {s}\n", .{ P, Color.cyan, short_hash, Color.reset, category, p_name, p_desc });
        }
    }
    try stdout.writeAll("\n");
}

fn printHelp(out: *std.io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies show <ref> [--meta] [-s]{s}\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Show prompt content or bundle details.\n", .{P});
    try out.print("{s}Type is auto-detected: hex = prompt hash, otherwise = bundle name.\n\n", .{P});
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}--meta{s}           Show full meta-prompt content (bundles only)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-s, --sync{s}       Sync registry before command\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-Q, --quiet-git{s}  Suppress git output\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-h, --help{s}       Show this help\n\n", .{ P, Color.cyan, Color.reset });
}
