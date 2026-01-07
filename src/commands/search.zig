const std = @import("std");
const builtin = @import("builtin");
const http = @import("../http.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const Color = commands.Color;
const P = commands.P;

pub const SearchMode = enum {
    templates,
    command,
    conduct,
};

// Fixed column widths: "  " + ID(8) + "  " + TASK(10) + "  " + AUTHOR(10) + "  " + NAME(20) + "  " = 58
const FIXED_COLS_WIDTH: usize = 58;
const MIN_DESC_WIDTH: usize = 20;
const DEFAULT_TERM_WIDTH: usize = 100;

fn getTerminalWidth() usize {
    if (builtin.os.tag == .windows) {
        return DEFAULT_TERM_WIDTH;
    }

    // POSIX: use ioctl to get terminal size
    var winsize: std.posix.winsize = undefined;
    const STDOUT_FILENO = 1;
    const result = std.posix.system.ioctl(STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (result == 0 and winsize.col > 0) {
        return winsize.col;
    }
    return DEFAULT_TERM_WIDTH;
}

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, keyword: ?[]const u8, mode: SearchMode, lang_override: ?[]const u8) !void {
    try stdout.writeAll("\n");

    const effective_lang = try config.getLang(allocator, lang_override);
    defer allocator.free(effective_lang);

    var count: usize = 0;

    // Calculate description column width based on terminal width
    const term_width = getTerminalWidth();
    const desc_width = if (term_width > FIXED_COLS_WIDTH + MIN_DESC_WIDTH)
        term_width - FIXED_COLS_WIDTH
    else
        MIN_DESC_WIDTH;

    // Print header
    try stdout.print("{s}{s}{s}ID        TASK        AUTHOR      NAME                  DESCRIPTION{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    // Dynamic separator line
    try stdout.writeAll(P);
    try stdout.writeAll(Color.dim);
    var sep_i: usize = 0;
    while (sep_i < FIXED_COLS_WIDTH + desc_width) : (sep_i += 1) {
        try stdout.writeAll("─");
    }
    try stdout.writeAll(Color.reset);
    try stdout.writeAll("\n");

    // Buffers for truncation
    var name_buf: [20]u8 = undefined;
    var desc_buf: [256]u8 = undefined;

    switch (mode) {
        .templates => {
            // Search templates
            var templates_index = http.fetchTemplatesIndex(allocator) catch |err| {
                try printError(stderr, err);
                return;
            };
            defer templates_index.deinit();

            for (templates_index.templates) |tmpl| {
                if (keyword) |kw| {
                    if (!containsIgnoreCase(tmpl.name, kw) and
                        !containsIgnoreCase(tmpl.task, kw) and
                        !containsIgnoreCase(tmpl.author, kw) and
                        !containsIgnoreCase(tmpl.description, kw)) continue;
                }

                try stdout.print("{s}{s}{s: <8}{s}  {s: <10}  {s: <10}  {s}{s: <20}{s}  {s}\n", .{
                    P,
                    Color.cyan,
                    truncate(tmpl.hash, 8),
                    Color.reset,
                    truncate(tmpl.task, 10),
                    truncate(tmpl.author, 10),
                    Color.cyan,
                    toLowerTruncate(&name_buf, tmpl.name, 20),
                    Color.reset,
                    truncateWithEllipsis(&desc_buf, tmpl.description, desc_width),
                });
                count += 1;
            }

            if (count == 0) {
                try stdout.print("{s}{s}No templates found.{s}\n", .{ P, Color.dim, Color.reset });
            }
        },
        .command, .conduct => {
            // Search prompts
            const type_str = if (mode == .command) "command" else "conduct";

            var prompts_index = http.fetchPromptsIndex(allocator) catch |err| {
                try printError(stderr, err);
                return;
            };
            defer prompts_index.deinit();

            for (prompts_index.prompts) |prompt| {
                if (!std.mem.eql(u8, prompt.lang, effective_lang)) continue;
                if (!std.mem.eql(u8, prompt.type, type_str)) continue;

                if (keyword) |kw| {
                    if (!containsIgnoreCase(prompt.name, kw) and
                        !containsIgnoreCase(prompt.task, kw) and
                        !containsIgnoreCase(prompt.author, kw) and
                        !containsIgnoreCase(prompt.description, kw)) continue;
                }

                try stdout.print("{s}{s}{s: <8}{s}  {s: <10}  {s: <10}  {s}{s: <20}{s}  {s}\n", .{
                    P,
                    Color.cyan,
                    truncate(prompt.hash, 8),
                    Color.reset,
                    truncate(prompt.task, 10),
                    truncate(prompt.author, 10),
                    Color.cyan,
                    toLowerTruncate(&name_buf, prompt.name, 20),
                    Color.reset,
                    truncateWithEllipsis(&desc_buf, prompt.description, desc_width),
                });
                count += 1;
            }

            if (count == 0) {
                try stdout.print("{s}{s}No {s} prompts found.{s}\n", .{ P, Color.dim, type_str, Color.reset });
            }
        },
    }

    try stdout.writeAll("\n");
}

fn printError(stderr: anytype, err: http.HttpError) !void {
    if (err == http.HttpError.RequestFailed) {
        try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
    } else if (err == http.HttpError.NotFound) {
        try stderr.print("{s}{s}{s}Error:{s} Registry not found. The remote registry may not be set up yet.\n", .{ P, Color.bold, Color.red, Color.reset });
    } else if (err == http.HttpError.InvalidResponse) {
        try stderr.print("{s}{s}{s}Error:{s} Invalid response from registry.\n", .{ P, Color.bold, Color.red, Color.reset });
    } else {
        try stderr.print("{s}{s}{s}Error:{s} {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            const hc_lower = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            const nc_lower = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
            if (hc_lower != nc_lower) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn truncate(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}

fn truncateWithEllipsis(buf: []u8, s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) {
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }
    // Truncate and add "..." at end
    if (max_len <= 3) {
        @memcpy(buf[0..max_len], s[0..max_len]);
        return buf[0..max_len];
    }
    const content_len = max_len - 3;
    @memcpy(buf[0..content_len], s[0..content_len]);
    buf[content_len] = '.';
    buf[content_len + 1] = '.';
    buf[content_len + 2] = '.';
    return buf[0..max_len];
}

fn toLowerTruncate(buf: []u8, s: []const u8, max_len: usize) []const u8 {
    const len = @min(s.len, max_len);
    for (s[0..len], 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf[0..len];
}
