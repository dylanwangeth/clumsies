const std = @import("std");
const http = @import("../http.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const Color = commands.Color;
const P = commands.P;

pub const SearchFilter = struct {
    command_only: bool = false,
    conduct_only: bool = false,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, task_filter: ?[]const u8, filter: SearchFilter, lang_override: ?[]const u8) !void {
    try stdout.writeAll("\n");

    const effective_lang = try config.getLang(allocator, lang_override);
    defer allocator.free(effective_lang);

    // Print header
    try stdout.print("{s}{s}{s}TYPE      TASK        NAME                       DESCRIPTION{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}─────────────────────────────────────────────────────────────────────────────────{s}\n", .{ P, Color.dim, Color.reset });

    var count: usize = 0;

    // Fetch and display templates (unless filtering by prompt type only)
    if (!filter.command_only and !filter.conduct_only) {
        var templates_index = http.fetchTemplatesIndex(allocator) catch |err| {
            try printError(stderr, err);
            return;
        };
        defer templates_index.deinit();

        for (templates_index.templates) |tmpl| {
            // Filter by task if provided
            if (task_filter) |task| {
                if (!containsIgnoreCase(tmpl.task, task)) continue;
            }

            try stdout.print("{s}{s}template{s}  {s: <10}  {s: <25}  {s}\n", .{
                P,
                Color.cyan,
                Color.reset,
                truncate(tmpl.task, 10),
                truncate(tmpl.name, 25),
                truncate(tmpl.description, 40),
            });
            count += 1;
        }
    }

    // Fetch and display prompts
    var prompts_index = http.fetchPromptsIndex(allocator) catch |err| {
        // If templates were shown, don't error on prompts failure
        if (count > 0) {
            try stdout.writeAll("\n");
            return;
        }
        try printError(stderr, err);
        return;
    };
    defer prompts_index.deinit();

    for (prompts_index.prompts) |prompt| {
        // Filter by language
        if (!std.mem.eql(u8, prompt.lang, effective_lang)) continue;

        // Filter by type
        if (filter.command_only and !std.mem.eql(u8, prompt.type, "command")) continue;
        if (filter.conduct_only and !std.mem.eql(u8, prompt.type, "conduct")) continue;

        // Filter by task if provided
        if (task_filter) |task| {
            if (!containsIgnoreCase(prompt.task, task)) continue;
        }

        try stdout.print("{s}{s}{s: <8}{s}  {s: <10}  {s: <25}  {s}\n", .{
            P,
            Color.dim,
            prompt.type,
            Color.reset,
            truncate(prompt.task, 10),
            truncate(prompt.name, 25),
            truncate(prompt.description, 40),
        });
        count += 1;
    }

    if (count == 0) {
        try stdout.print("{s}{s}No results found.{s}\n", .{ P, Color.dim, Color.reset });
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
