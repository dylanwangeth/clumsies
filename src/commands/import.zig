const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const styles = @import("../styles.zig");
const lib = @import("clumsies_lib");
const sequence = lib.sequence;
const encoding = lib.encoding;
const index = @import("index.zig");

const Color = styles.Color;
const P = styles.P;

const MAX_FILE_SIZE = 10 * 1024 * 1024;
const META_PROMPT_GROUP = "../";

pub const PromptRef = index.PromptRef;

/// Import a single prompt file from registry to .prompts/{group}/
pub const ImportResult = enum { imported, skipped, failed };

pub fn importPrompt(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, prompts_path: []const u8, hash: []const u8, name_opt: ?[]const u8, format: []const u8, group: []const u8) !ImportResult {
    const prompt_file_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", hash });
    defer allocator.free(prompt_file_path);

    const name_part = name_opt orelse hash[0..8];

    // Meta-prompt files (group "../") go to project root without sequence prefix
    if (std.mem.eql(u8, group, META_PROMPT_GROUP)) {
        const cwd = std.process.getCwdAlloc(allocator) catch {
            try stderr.print("{s}{s}{s}✗{s} Failed to determine project root\n", .{ P, Color.bold, Color.red, Color.reset });
            return .failed;
        };
        defer allocator.free(cwd);

        const dest_filename = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ name_part, format });
        defer allocator.free(dest_filename);

        const dest_path = try std.fs.path.join(allocator, &.{ cwd, dest_filename });
        defer allocator.free(dest_path);

        // Check if already exists
        if (fs.openFileAbsolute(dest_path, .{})) |f| {
            f.close();
            try stdout.print("{s}{s}{s}~{s} {s} (already exists)\n", .{ P, Color.bold, Color.dim, Color.reset, dest_filename });
            return .skipped;
        } else |_| {}

        fs.copyFileAbsolute(prompt_file_path, dest_path, .{}) catch {
            try stderr.print("{s}{s}{s}✗{s} Failed to copy: {s}\n", .{ P, Color.bold, Color.red, Color.reset, dest_filename });
            return .failed;
        };

        try stdout.print("{s}{s}{s}✓{s} {s} → ./{s}\n", .{ P, Color.bold, Color.green, Color.reset, name_part, dest_filename });
        return .imported;
    }

    const target_dir = try std.fs.path.join(allocator, &.{ prompts_path, group });
    defer allocator.free(target_dir);
    fs.cwd().makePath(target_dir) catch {};

    // Check if a file with the same name suffix already exists (e.g. *_CODE_COMMENTS.md)
    const suffix = try std.fmt.allocPrint(allocator, "_{s}.{s}", .{ name_part, format });
    defer allocator.free(suffix);

    if (fs.openDirAbsolute(target_dir, .{ .iterate = true })) |dir_handle| {
        var dir = dir_handle;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, suffix)) {
                try stdout.print("{s}{s}{s}~{s} {s} (already exists)\n", .{ P, Color.bold, Color.dim, Color.reset, name_part });
                return .skipped;
            }
        }
    } else |_| {}

    const seq_num = sequence.findNextSequence(target_dir);
    const dest_filename = try std.fmt.allocPrint(allocator, "{d:0>2}_{s}.{s}", .{ seq_num, name_part, format });
    defer allocator.free(dest_filename);

    const dest_path = try std.fs.path.join(allocator, &.{ target_dir, dest_filename });
    defer allocator.free(dest_path);

    fs.copyFileAbsolute(prompt_file_path, dest_path, .{}) catch {
        try stderr.print("{s}{s}{s}✗{s} Failed to copy: {s}\n", .{ P, Color.bold, Color.red, Color.reset, name_part });
        return .failed;
    };

    try stdout.print("{s}{s}{s}✓{s} {s} → .prompts/{s}/{s}\n", .{ P, Color.bold, Color.green, Color.reset, name_part, group, dest_filename });
    return .imported;
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
            encoding.hexEncode(&hash_bytes, &hash_hex);
            const hash = try allocator.dupe(u8, &hash_hex);

            const raw_name = entry.name[0..name_end];
            const name = try allocator.dupe(u8, sequence.stripSequencePrefix(raw_name));
            const description = try allocator.dupe(u8, "-");

            const dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, hash });
            defer allocator.free(dest_path);
            fs.copyFileAbsolute(src_path, dest_path, .{}) catch {
                allocator.free(hash);
                allocator.free(name);
                allocator.free(description);
                allocator.free(format);
                continue;
            };

            try refs.append(allocator, .{
                .hash = hash,
                .group = try allocator.dupe(u8, base_name),
                .name = name,
                .description = description,
                .format = format,
            });
        }
    }
}
