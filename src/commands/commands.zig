const std = @import("std");
const fs = std.fs;
const styles = @import("../styles.zig");
const git = @import("../git.zig");
const spinner = @import("../spinner.zig");
const config = @import("config.zig");

pub const Color = styles.Color;
pub const P = styles.P;
pub const GitOutput = git.GitOutput;

// Shared constants
pub const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB
pub const MAX_SEQUENCE_NUMBER: u8 = 99;

// Frontmatter metadata structure
pub const Frontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    category: ?[]const u8 = null,
    task: ?[]const u8 = null,
};

/// Parse YAML frontmatter from markdown content
pub fn parseFrontmatter(content: []const u8) Frontmatter {
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
        } else if (std.mem.startsWith(u8, trimmed, "category:")) {
            const value = std.mem.trim(u8, trimmed[9..], " \t");
            if (value.len > 0) fm.category = value;
        } else if (std.mem.startsWith(u8, trimmed, "task:")) {
            const value = std.mem.trim(u8, trimmed[5..], " \t");
            if (value.len > 0) fm.task = value;
        }
    }

    return fm;
}

/// Strip sequence prefix (NN_) from filename if present
/// e.g., "01_review_commit" -> "review_commit"
pub fn stripSequencePrefix(name: []const u8) []const u8 {
    if (name.len >= 3 and name[2] == '_') {
        // Check if first two chars are digits
        if (std.ascii.isDigit(name[0]) and std.ascii.isDigit(name[1])) {
            return name[3..];
        }
    }
    return name;
}

/// Encode bytes to hexadecimal string
pub fn hexEncode(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
}

/// Find next available sequence number with gap filling
/// If files 00_, 01_, 03_ exist, returns 2 (fills the gap)
/// If files 00_, 01_, 02_ exist, returns 3 (next number)
pub fn findNextSequence(dir_path: []const u8) u8 {
    var used: [100]bool = [_]bool{false} ** 100;
    var max_seq: u8 = 0;

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
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

    // No gap found, return next number (capped at MAX_SEQUENCE_NUMBER)
    return if (max_seq > MAX_SEQUENCE_NUMBER) MAX_SEQUENCE_NUMBER else max_seq;
}

pub fn getPromptsPath(allocator: std.mem.Allocator) ![]const u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, ".prompts" });
}

pub fn getBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHome;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".clumsies" });
}

pub fn promptsExist() bool {
    var dir = std.fs.cwd().openDir(".prompts", .{}) catch return false;
    dir.close();
    return true;
}

pub fn promptsIsGitRepo() bool {
    var dir = std.fs.cwd().openDir(".prompts/.git", .{}) catch return false;
    dir.close();
    return true;
}

/// Format timestamp to ISO date string (YYYY-MM-DD)
pub fn formatDate(timestamp: i64, buf: *[10]u8) []const u8 {
    const epoch_seconds: u64 = @intCast(if (timestamp < 0) 0 else timestamp);
    const days_since_epoch = epoch_seconds / 86400;

    // Simple date calculation
    var year: u32 = 1970;
    var remaining_days = days_since_epoch;

    while (true) {
        const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
        const days_in_year: u64 = if (is_leap) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    const days_in_months = [_]u8{ 31, if (is_leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u8 = 1;
    for (days_in_months) |days| {
        if (remaining_days < days) break;
        remaining_days -= days;
        month += 1;
    }

    const day: u8 = @intCast(remaining_days + 1);

    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch return "0000-00-00";
    return buf[0..10];
}

/// Print git output in unified format
/// Shows both stdout and stderr with dim styling
pub fn printGitOutput(writer: *std.io.Writer, output: *const GitOutput) void {
    const has_stdout = output.stdout != null and output.stdout.?.len > 0;
    const has_stderr = output.stderr != null and output.stderr.?.len > 0;

    if (!has_stdout and !has_stderr) return;

    writer.print("{s}{s}git:{s}\n", .{ P, Color.dim, Color.reset }) catch return;

    if (has_stdout) {
        const stdout_content = std.mem.trim(u8, output.stdout.?, "\n\r ");
        var lines = std.mem.splitScalar(u8, stdout_content, '\n');
        while (lines.next()) |line| {
            writer.print("{s}  {s}{s}{s}\n", .{ P, Color.dim, line, Color.reset }) catch return;
        }
    }

    if (has_stderr) {
        const stderr_content = std.mem.trim(u8, output.stderr.?, "\n\r ");
        var lines = std.mem.splitScalar(u8, stderr_content, '\n');
        while (lines.next()) |line| {
            writer.print("{s}  {s}{s}{s}\n", .{ P, Color.dim, line, Color.reset }) catch return;
        }
    }
}

/// Print git output using raw stdout (for use after spinner)
/// If quiet=true, output is suppressed.
pub fn printGitOutputRaw(output: *const GitOutput, quiet: bool) void {
    if (quiet) return;
    const has_stdout = output.stdout != null and output.stdout.?.len > 0;
    const has_stderr = output.stderr != null and output.stderr.?.len > 0;

    if (!has_stdout and !has_stderr) return;

    const raw_stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;

    const header = std.fmt.bufPrint(&buf, "{s}{s}git:{s}\n", .{ P, Color.dim, Color.reset }) catch return;
    _ = raw_stdout.write(header) catch return;

    if (has_stdout) {
        const stdout_content = std.mem.trim(u8, output.stdout.?, "\n\r ");
        var lines = std.mem.splitScalar(u8, stdout_content, '\n');
        while (lines.next()) |line| {
            const formatted = std.fmt.bufPrint(&buf, "{s}  {s}{s}{s}\n", .{ P, Color.dim, line, Color.reset }) catch continue;
            _ = raw_stdout.write(formatted) catch continue;
        }
    }

    if (has_stderr) {
        const stderr_content = std.mem.trim(u8, output.stderr.?, "\n\r ");
        var lines = std.mem.splitScalar(u8, stderr_content, '\n');
        while (lines.next()) |line| {
            const formatted = std.fmt.bufPrint(&buf, "{s}  {s}{s}{s}\n", .{ P, Color.dim, line, Color.reset }) catch continue;
            _ = raw_stdout.write(formatted) catch continue;
        }
    }
}

/// Ensure registry exists, optionally sync with remote
/// Caller must free the returned path
/// If sync=false and registry exists locally, skip network operations (fast path)
/// If registry doesn't exist, always clones regardless of sync flag
pub fn ensureRegistry(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, sync: bool, quiet_git: bool) ![]const u8 {
    const registry_info = config.getRegistryInfo(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Registry not configured\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run: {s}clumsies config set registry <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        try stderr.print("{s}Tip: Use {s}<git-url>#<branch>{s} to specify a branch\n\n", .{ P, Color.cyan, Color.reset });
        return error.NoRegistry;
    };
    defer registry_info.deinit(allocator);

    const base_path = getBasePath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine config path\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return error.NoBasePath;
    };
    defer allocator.free(base_path);

    const registry_path = try std.fs.path.join(allocator, &.{ base_path, "registry" });
    errdefer allocator.free(registry_path);

    const registry_exists = blk: {
        var dir = fs.openDirAbsolute(registry_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    if (!registry_exists) {
        // Registry doesn't exist - must clone (requires network)
        const stdout_raw = std.fs.File.stdout();
        _ = stdout_raw.write("\n") catch {};

        var sp = spinner.init(stdout, "Fetching registry");
        sp.start();
        fs.cwd().makePath(base_path) catch {};
        var git_output: GitOutput = .{};
        defer git_output.deinit(allocator);

        git.cloneWithBranch(allocator, registry_info.url, registry_path, registry_info.branch, &git_output) catch {
            sp.fail();
            printGitOutputRaw(&git_output, quiet_git);
            try stderr.print("{s}{s}{s}Error:{s} Failed to clone registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return error.CloneFailed;
        };
        sp.succeed();
        printGitOutputRaw(&git_output, quiet_git);
    } else if (sync) {
        // Registry exists and sync requested - pull latest
        var sp = spinner.init(stdout, "Syncing registry");
        sp.start();

        var git_output: GitOutput = .{};
        defer git_output.deinit(allocator);

        // If branch specified, ensure we're on correct branch
        if (registry_info.branch) |branch| {
            var checkout_output: GitOutput = .{};
            defer checkout_output.deinit(allocator);
            git.fetchAndCheckout(allocator, registry_path, branch, &checkout_output) catch {};
        }
        git.pull(allocator, registry_path, &git_output) catch {};
        sp.succeed();
        printGitOutputRaw(&git_output, quiet_git);
    }
    // else: registry exists and no sync requested - use local cache (fast path)

    return registry_path;
}

// --- Shared types and functions for new flat commands ---

pub const RefKind = enum { prompt, bundle, not_found };

/// Check if a string consists entirely of hexadecimal characters
pub fn isHexString(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
            return false;
        }
    }
    return true;
}

/// Resolve a ref to either a prompt (by hash prefix) or bundle (by name).
/// 1. If ref is hex-only → search prompts/index.json by hash prefix
/// 2. Otherwise → search bundles/index.json by name
/// 3. not_found if neither matches
pub fn resolveRef(allocator: std.mem.Allocator, registry_path: []const u8, ref: []const u8) RefKind {
    if (isHexString(ref)) {
        // Try prompts/index.json hash prefix match
        const index_path = std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" }) catch return .not_found;
        defer allocator.free(index_path);

        const file = fs.openFileAbsolute(index_path, .{}) catch return .not_found;
        defer file.close();
        const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch return .not_found;
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return .not_found;
        defer parsed.deinit();

        const prompts = parsed.value.object.get("prompts") orelse return .not_found;
        for (prompts.array.items) |item| {
            const item_hash = if (item.object.get("hash")) |h| h.string else continue;
            if (std.mem.startsWith(u8, item_hash, ref)) return .prompt;
        }
        return .not_found;
    } else {
        // Try bundles/index.json name match
        const index_path = std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" }) catch return .not_found;
        defer allocator.free(index_path);

        const file = fs.openFileAbsolute(index_path, .{}) catch return .not_found;
        defer file.close();
        const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch return .not_found;
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return .not_found;
        defer parsed.deinit();

        const bundles = parsed.value.object.get("bundles") orelse return .not_found;
        for (bundles.array.items) |item| {
            const item_name = if (item.object.get("name")) |n| n.string else continue;
            if (std.mem.eql(u8, item_name, ref)) return .bundle;
        }
        return .not_found;
    }
}

/// PromptRef represents a prompt reference in a bundle
pub const PromptRef = struct {
    hash: []const u8,
    category: []const u8,
    name: []const u8,
    description: []const u8,
    format: []const u8,
};

/// Free all owned fields in a PromptRef list
pub fn freePromptRefs(allocator: std.mem.Allocator, refs: *std.ArrayListUnmanaged(PromptRef)) void {
    for (refs.items) |ref| {
        allocator.free(ref.hash);
        allocator.free(ref.category);
        allocator.free(ref.name);
        allocator.free(ref.description);
        allocator.free(ref.format);
    }
    refs.deinit(allocator);
}

/// Check if content starts with a YAML frontmatter block (---\n...\n---).
pub fn hasFrontmatter(content: []const u8) bool {
    if (!std.mem.startsWith(u8, content, "---\n") and !std.mem.startsWith(u8, content, "---\r\n")) return false;
    const start = if (std.mem.startsWith(u8, content, "---\r\n")) @as(usize, 5) else @as(usize, 4);
    if (std.mem.indexOf(u8, content[start..], "\n---\n") != null) return true;
    if (std.mem.indexOf(u8, content[start..], "\n---\r\n") != null) return true;
    if (std.mem.endsWith(u8, content, "\n---")) return true;
    return false;
}

/// Strip YAML frontmatter from the beginning of content.
pub fn stripFrontmatter(content: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, content, "---\n") and !std.mem.startsWith(u8, content, "---\r\n")) return content;
    const start = if (std.mem.startsWith(u8, content, "---\r\n")) @as(usize, 5) else @as(usize, 4);

    if (std.mem.indexOf(u8, content[start..], "\n---\n")) |idx| {
        const after = start + idx + 5;
        return std.mem.trimLeft(u8, content[after..], "\r\n");
    }
    if (std.mem.indexOf(u8, content[start..], "\n---\r\n")) |idx| {
        const after = start + idx + 6;
        return std.mem.trimLeft(u8, content[after..], "\r\n");
    }
    if (std.mem.endsWith(u8, content, "\n---")) {
        return "";
    }
    return content;
}

/// Import a single prompt file from registry to .prompts/{category}/
pub fn importPrompt(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, prompts_path: []const u8, hash: []const u8, name_opt: ?[]const u8, format: []const u8, category: []const u8) !bool {
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

/// Check if a bundle exists in the registry by name
pub fn bundleExists(allocator: std.mem.Allocator, registry_path: []const u8, name: []const u8) bool {
    const index_path = std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" }) catch return false;
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch return false;
    defer file.close();

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch return false;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return false;
    defer parsed.deinit();

    const bundles = parsed.value.object.get("bundles") orelse return false;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;
        if (std.mem.eql(u8, item_name, name)) return true;
    }
    return false;
}

/// Recursively collect prompt files from a directory and upload to registry
pub fn collectAndUploadPrompts(allocator: std.mem.Allocator, src_dir: []const u8, base_name: []const u8, prompts_dir: []const u8, refs: *std.ArrayListUnmanaged(PromptRef)) !void {
    var dir = fs.openDirAbsolute(src_dir, .{ .iterate = true }) catch return error.Failed;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return error.Failed) |entry| {
        const src_path = try std.fs.path.join(allocator, &.{ src_dir, entry.name });
        defer allocator.free(src_path);

        if (entry.kind == .directory) {
            const sub_base = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_name, entry.name });
            defer allocator.free(sub_base);
            try collectAndUploadPrompts(allocator, src_path, sub_base, prompts_dir, refs);
        } else if (entry.kind == .file) {
            const ext_idx = std.mem.lastIndexOf(u8, entry.name, ".");
            if (ext_idx == null) continue;
            const format = try allocator.dupe(u8, entry.name[ext_idx.? + 1 ..]);
            const name_end = ext_idx.?;

            const file = fs.openFileAbsolute(src_path, .{}) catch continue;
            const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
                file.close();
                continue;
            };
            file.close();
            defer allocator.free(content);

            var hash_bytes: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(content, &hash_bytes, .{});
            var hash_hex: [64]u8 = undefined;
            hexEncode(&hash_bytes, &hash_hex);
            const hash = try allocator.dupe(u8, &hash_hex);

            const raw_name = entry.name[0..name_end];
            const name = try allocator.dupe(u8, stripSequencePrefix(raw_name));
            const description = try allocator.dupe(u8, "-");

            const dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, hash });
            defer allocator.free(dest_path);
            fs.copyFileAbsolute(src_path, dest_path, .{}) catch {
                // Copy failed — skip this file, don't add to refs
                allocator.free(hash);
                allocator.free(name);
                allocator.free(description);
                allocator.free(format);
                continue;
            };

            try refs.append(allocator, .{
                .hash = hash,
                .category = try allocator.dupe(u8, base_name),
                .name = name,
                .description = description,
                .format = format,
            });
        }
    }
}

/// Merge new prompt refs into prompts/index.json, skipping duplicates by hash
pub fn updatePromptsIndex(allocator: std.mem.Allocator, registry_path: []const u8, refs: []const PromptRef) !void {
    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    const index_path = try std.fs.path.join(allocator, &.{ prompts_dir, "index.json" });
    defer allocator.free(index_path);

    var index_content: std.ArrayListUnmanaged(u8) = .{};
    defer index_content.deinit(allocator);
    try index_content.appendSlice(allocator, "{\n  \"prompts\": [");

    var seen_hashes = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = seen_hashes.keyIterator();
        while (key_iter.next()) |key| {
            allocator.free(@constCast(key.*));
        }
        seen_hashes.deinit();
    }

    var first = true;
    const timestamp = std.time.timestamp();

    if (fs.openFileAbsolute(index_path, .{})) |file| {
        const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            file.close();
            return;
        };
        file.close();
        defer allocator.free(content);

        if (std.json.parseFromSlice(std.json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value.object.get("prompts")) |prompts| {
                for (prompts.array.items) |item| {
                    const item_hash = if (item.object.get("hash")) |h| h.string else continue;

                    const hash_copy = allocator.dupe(u8, item_hash) catch continue;
                    seen_hashes.put(hash_copy, {}) catch {
                        allocator.free(hash_copy);
                    };

                    if (!first) try index_content.appendSlice(allocator, ",");
                    try appendPromptEntry(allocator, &index_content, item);
                    first = false;
                }
            }
        } else |_| {}
    } else |_| {}

    for (refs) |ref| {
        if (seen_hashes.contains(ref.hash)) continue;

        const entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{d}\"\n    }}", .{
            if (first) "" else ",",
            ref.hash,
            ref.name,
            ref.description,
            ref.format,
            ref.category,
            timestamp,
        });
        defer allocator.free(entry);
        try index_content.appendSlice(allocator, entry);
        first = false;
    }

    try index_content.appendSlice(allocator, "\n  ]\n}\n");

    const idx_out = try fs.createFileAbsolute(index_path, .{});
    defer idx_out.close();
    try idx_out.writeAll(index_content.items);
}

/// Serialize a prompt JSON entry to a buffer
pub fn appendPromptEntry(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), item: std.json.Value) !void {
    const item_hash = if (item.object.get("hash")) |h| h.string else return;
    const item_name = if (item.object.get("name")) |n| n.string else "-";
    const item_desc = if (item.object.get("description")) |d| d.string else "-";
    const item_format = if (item.object.get("format")) |f| f.string else "md";
    const item_category = if (item.object.get("category")) |p| p.string else "conduct";
    const item_created = if (item.object.get("created_at")) |c| c.string else "0";

    const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_desc, item_format, item_category, item_created });
    defer allocator.free(entry);
    try buf.appendSlice(allocator, entry);
}

/// Serialize a bundle JSON entry to a buffer (handles both new and old format)
pub fn appendBundleEntry(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), item: std.json.Value) !void {
    const item_name = if (item.object.get("name")) |n| n.string else return;
    const item_task = if (item.object.get("task")) |t| t.string else "-";
    const item_desc = if (item.object.get("description")) |d| d.string else "-";
    const item_created = if (item.object.get("created_at")) |c| c.string else "0";
    const item_meta = if (item.object.get("meta_prompt")) |m| m.string else "";

    const entry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"categories\": [", .{ item_name, item_task, item_desc, item_created, item_meta });
    defer allocator.free(entry_start);
    try buf.appendSlice(allocator, entry_start);

    if (item.object.get("categories")) |categories| {
        for (categories.array.items, 0..) |cat, idx| {
            const cat_entry = try std.fmt.allocPrint(allocator, "{s}\"{s}\"", .{
                if (idx > 0) ", " else "",
                cat.string,
            });
            defer allocator.free(cat_entry);
            try buf.appendSlice(allocator, cat_entry);
        }
    } else if (item.object.get("prompts")) |prompts| {
        var seen_cats = std.StringHashMap(void).init(allocator);
        defer seen_cats.deinit();
        var cat_list: std.ArrayListUnmanaged([]const u8) = .{};
        defer cat_list.deinit(allocator);

        for (prompts.array.items) |ref| {
            const cat = if (ref.object.get("category")) |c| c.string else continue;
            if (!seen_cats.contains(cat)) {
                seen_cats.put(cat, {}) catch {};
                cat_list.append(allocator, cat) catch {};
            }
        }
        for (cat_list.items, 0..) |cat, idx| {
            const cat_entry = try std.fmt.allocPrint(allocator, "{s}\"{s}\"", .{
                if (idx > 0) ", " else "",
                cat,
            });
            defer allocator.free(cat_entry);
            try buf.appendSlice(allocator, cat_entry);
        }
    }

    try buf.appendSlice(allocator, "],\n      \"prompts\": [");

    if (item.object.get("prompts")) |prompts| {
        if (item.object.get("categories") != null) {
            for (prompts.array.items, 0..) |ref, idx| {
                const hash = if (ref.object.get("hash")) |h| h.string else continue;
                const category = if (ref.object.get("category")) |p| p.string else continue;
                const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
                    if (idx > 0) "," else "",
                    hash,
                    category,
                });
                defer allocator.free(ref_entry);
                try buf.appendSlice(allocator, ref_entry);
            }
        }
    }
    try buf.appendSlice(allocator, "]\n    }");
}

