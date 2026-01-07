const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const http = @import("../http.zig");
const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;
const Sha256 = std.crypto.hash.sha2.Sha256;

fn getPlatformString() []const u8 {
    const os = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => @compileError("Unsupported OS"),
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => @compileError("Unsupported architecture"),
    };
    return os ++ "-" ++ arch;
}

fn bytesToHex(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

/// Get version from installed binary by running it
fn getInstalledVersion(allocator: std.mem.Allocator, bin_path: []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ bin_path, "--version" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse "clumsies X.Y.Z" -> "X.Y.Z"
    const output = std.mem.trim(u8, result.stdout, " \t\n\r");
    if (std.mem.lastIndexOf(u8, output, " ")) |space_idx| {
        return allocator.dupe(u8, output[space_idx + 1 ..]) catch null;
    }
    return null;
}

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, current_version: []const u8) !void {
    try stdout.writeAll("\n");

    const platform = comptime getPlatformString();
    const binary_name = comptime "clumsies-" ++ platform;

    try stdout.print("{s}Checking for updates ({s}{s}{s})...\n\n", .{ P, Color.bold, platform, Color.reset });
    try stdout.print("{s}  Current version: {s}{s}{s}\n", .{ P, Color.bold, current_version, Color.reset });

    try stdout.print("{s}  {s}→{s} Fetching latest release...\n", .{ P, Color.orange, Color.reset });
    stdout.flush() catch {};

    const checksums_url = comptime http.RELEASES_BASE ++ "/checksums.txt";
    const checksums_content = http.fetchUrl(allocator, checksums_url) catch |err| {
        if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}{s}Error:{s} No release available.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer allocator.free(checksums_content);

    var expected_checksum: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, checksums_content, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, binary_name)) |_| {
            var parts = std.mem.splitSequence(u8, line, "  ");
            expected_checksum = parts.first();
            break;
        }
    }

    const checksum = expected_checksum orelse {
        try stderr.print("{s}{s}{s}Error:{s} Checksum not found for {s}\n", .{ P, Color.bold, Color.red, Color.reset, binary_name });
        return;
    };

    if (checksum.len != 64) {
        try stderr.print("{s}{s}{s}Error:{s} Invalid checksum format\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    try stdout.print("{s}  {s}→{s} Downloading binary...\n", .{ P, Color.orange, Color.reset });
    stdout.flush() catch {};

    const binary_url = comptime http.RELEASES_BASE ++ "/" ++ binary_name;
    const binary_content = http.fetchUrl(allocator, binary_url) catch |err| {
        if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}{s}Error:{s} Binary not found for {s}\n", .{ P, Color.bold, Color.red, Color.reset, platform });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} Failed to download binary: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer allocator.free(binary_content);

    try stdout.print("{s}  {s}→{s} Verifying checksum...\n", .{ P, Color.orange, Color.reset });

    var hash: [32]u8 = undefined;
    Sha256.hash(binary_content, &hash, .{});

    var hash_hex: [64]u8 = undefined;
    bytesToHex(&hash, &hash_hex);

    if (!std.mem.eql(u8, &hash_hex, checksum)) {
        try stderr.print("{s}{s}{s}Error:{s} Checksum verification failed!\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}  Expected: {s}\n", .{ P, checksum });
        try stderr.print("{s}  Got:      {s}\n", .{ P, &hash_hex });
        return;
    }

    try stdout.print("{s}  {s}✓{s} Checksum verified\n", .{ P, Color.green, Color.reset });

    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine home directory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(home_dir);

    const bin_path = std.fs.path.join(allocator, &.{ home_dir, ".clumsies", "bin", "clumsies" }) catch {
        try stderr.print("{s}{s}{s}Error:{s} Out of memory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(bin_path);

    try stdout.print("{s}  {s}→{s} Installing...\n", .{ P, Color.orange, Color.reset });

    {
        const file = fs.createFileAbsolute(bin_path, .{ .mode = 0o755 }) catch |err| {
            try stderr.print("{s}{s}{s}Error:{s} Cannot write to {s}: {any}\n", .{ P, Color.bold, Color.red, Color.reset, bin_path, err });
            return;
        };
        defer file.close();

        file.writeAll(binary_content) catch |err| {
            try stderr.print("{s}{s}{s}Error:{s} Failed to write binary: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
            return;
        };
    }

    // Get new version from installed binary (file must be closed first)
    const new_version = getInstalledVersion(allocator, bin_path);
    defer if (new_version) |v| allocator.free(v);

    try stdout.writeAll("\n");

    if (new_version) |nv| {
        if (std.mem.eql(u8, nv, current_version)) {
            try stdout.print("{s}{s}{s}✓{s} Already up to date ({s}{s}{s})\n\n", .{ P, Color.bold, Color.green, Color.reset, Color.bold, current_version, Color.reset });
        } else {
            try stdout.print("{s}{s}{s}✓{s} Upgraded: {s}{s}{s} → {s}{s}{s}\n\n", .{ P, Color.bold, Color.orange, Color.reset, Color.dim, current_version, Color.reset, Color.bold, nv, Color.reset });
        }
    } else {
        try stdout.print("{s}{s}{s}✓{s} Upgrade complete\n\n", .{ P, Color.bold, Color.orange, Color.reset });
    }
}
