const std = @import("std");
const http = @import("../http.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const Color = commands.Color;
const P = commands.P;

pub const SearchType = enum {
    template,
    command,
    conduct,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, search_type: SearchType, keyword: ?[]const u8, lang_override: ?[]const u8) !void {
    try stdout.writeAll("\n");

    switch (search_type) {
        .template => try searchTemplates(stdout, stderr, allocator, keyword),
        .command, .conduct => try searchPrompts(stdout, stderr, allocator, search_type, keyword, lang_override),
    }
}

fn searchTemplates(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, keyword: ?[]const u8) !void {
    var index = http.fetchTemplatesIndex(allocator) catch |err| {
        try printError(stderr, err);
        return;
    };
    defer index.deinit();

    try stdout.print("{s}{s}{s}NAME            VERSION     LANGUAGES   DESCRIPTION{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}────────────────────────────────────────────────────────────────────────────{s}\n", .{ P, Color.dim, Color.reset });

    for (index.templates) |tmpl| {
        // Filter by keyword if provided
        if (keyword) |kw| {
            const kw_lower = try toLower(allocator, kw);
            defer allocator.free(kw_lower);
            const name_lower = try toLower(allocator, tmpl.name);
            defer allocator.free(name_lower);
            const desc_lower = try toLower(allocator, tmpl.description);
            defer allocator.free(desc_lower);

            var found = false;
            if (std.mem.indexOf(u8, name_lower, kw_lower) != null) found = true;
            if (std.mem.indexOf(u8, desc_lower, kw_lower) != null) found = true;
            if (!found) continue;
        }

        // Format languages list
        var langs_buf: [32]u8 = undefined;
        var langs_len: usize = 0;
        for (tmpl.languages, 0..) |lang, i| {
            if (i > 0 and langs_len < langs_buf.len - 1) {
                langs_buf[langs_len] = ',';
                langs_len += 1;
            }
            const copy_len = @min(lang.len, langs_buf.len - langs_len);
            @memcpy(langs_buf[langs_len..][0..copy_len], lang[0..copy_len]);
            langs_len += copy_len;
        }
        const langs_str = langs_buf[0..langs_len];

        try stdout.print("{s}{s: <15} {s: <11} {s: <11} {s}\n", .{
            P,
            tmpl.name,
            tmpl.version,
            langs_str,
            tmpl.description,
        });
    }

    try stdout.writeAll("\n");
}

fn searchPrompts(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, search_type: SearchType, keyword: ?[]const u8, lang_override: ?[]const u8) !void {
    var index = http.fetchPromptsIndex(allocator) catch |err| {
        try printError(stderr, err);
        return;
    };
    defer index.deinit();

    const effective_lang = try config.getLang(allocator, lang_override);
    defer allocator.free(effective_lang);

    const type_str = switch (search_type) {
        .command => "command",
        .conduct => "conduct",
        .template => unreachable,
    };

    try stdout.print("{s}{s}{s}NAME                                LANG  DESCRIPTION{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}────────────────────────────────────────────────────────────────────────────{s}\n", .{ P, Color.dim, Color.reset });

    for (index.prompts) |prompt| {
        // Filter by type
        if (!std.mem.eql(u8, prompt.type, type_str)) continue;

        // Filter by language
        if (!std.mem.eql(u8, prompt.lang, effective_lang)) continue;

        // Filter by keyword if provided
        if (keyword) |kw| {
            const kw_lower = try toLower(allocator, kw);
            defer allocator.free(kw_lower);
            const name_lower = try toLower(allocator, prompt.name);
            defer allocator.free(name_lower);
            const desc_lower = try toLower(allocator, prompt.description);
            defer allocator.free(desc_lower);

            var found = false;
            if (std.mem.indexOf(u8, name_lower, kw_lower) != null) found = true;
            if (std.mem.indexOf(u8, desc_lower, kw_lower) != null) found = true;
            if (!found) continue;
        }

        try stdout.print("{s}{s: <35} {s: <5} {s}\n", .{
            P,
            truncate(prompt.name, 35),
            prompt.lang,
            truncate(prompt.description, 40),
        });
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

fn toLower(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return result;
}

fn truncate(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}
