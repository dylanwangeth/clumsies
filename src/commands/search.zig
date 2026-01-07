const std = @import("std");
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

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, keyword: ?[]const u8, mode: SearchMode, lang_override: ?[]const u8) !void {
    try stdout.writeAll("\n");

    const effective_lang = try config.getLang(allocator, lang_override);
    defer allocator.free(effective_lang);

    var count: usize = 0;

    switch (mode) {
        .templates => {
            // Search templates
            try stdout.print("{s}{s}{s}TASK        NAME                       DESCRIPTION{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
            try stdout.print("{s}{s}───────────────────────────────────────────────────────────────────────{s}\n", .{ P, Color.dim, Color.reset });

            var templates_index = http.fetchTemplatesIndex(allocator) catch |err| {
                try printError(stderr, err);
                return;
            };
            defer templates_index.deinit();

            var name_buf: [25]u8 = undefined;
            for (templates_index.templates) |tmpl| {
                if (keyword) |kw| {
                    if (!containsIgnoreCase(tmpl.name, kw) and
                        !containsIgnoreCase(tmpl.task, kw) and
                        !containsIgnoreCase(tmpl.description, kw)) continue;
                }

                try stdout.print("{s}{s: <10}  {s}{s: <25}{s}  {s}\n", .{
                    P,
                    truncate(tmpl.task, 10),
                    Color.cyan,
                    toLowerTruncate(&name_buf, tmpl.name, 25),
                    Color.reset,
                    truncate(tmpl.description, 40),
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
            try stdout.print("{s}{s}{s}TASK        NAME                       DESCRIPTION{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
            try stdout.print("{s}{s}───────────────────────────────────────────────────────────────────────{s}\n", .{ P, Color.dim, Color.reset });

            var prompts_index = http.fetchPromptsIndex(allocator) catch |err| {
                try printError(stderr, err);
                return;
            };
            defer prompts_index.deinit();

            var name_buf: [25]u8 = undefined;
            for (prompts_index.prompts) |prompt| {
                if (!std.mem.eql(u8, prompt.lang, effective_lang)) continue;
                if (!std.mem.eql(u8, prompt.type, type_str)) continue;

                if (keyword) |kw| {
                    if (!containsIgnoreCase(prompt.name, kw) and
                        !containsIgnoreCase(prompt.task, kw) and
                        !containsIgnoreCase(prompt.description, kw)) continue;
                }

                try stdout.print("{s}{s: <10}  {s}{s: <25}{s}  {s}\n", .{
                    P,
                    truncate(prompt.task, 10),
                    Color.cyan,
                    toLowerTruncate(&name_buf, prompt.name, 25),
                    Color.reset,
                    truncate(prompt.description, 40),
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

fn toLowerTruncate(buf: []u8, s: []const u8, max_len: usize) []const u8 {
    const len = @min(s.len, max_len);
    for (s[0..len], 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf[0..len];
}
