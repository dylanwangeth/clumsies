const std = @import("std");
const http = @import("../http.zig");
const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, task_filter: ?[]const u8, keyword_filter: ?[]const u8) !void {
    _ = task_filter; // No longer used in new protocol

    try stdout.writeAll("\n");

    var index = http.fetchTemplatesIndex(allocator) catch |err| {
        if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}{s}Error:{s} Registry not found. The remote registry may not be set up yet.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else if (err == http.HttpError.InvalidResponse) {
            try stderr.print("{s}{s}{s}Error:{s} Invalid response from registry.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer index.deinit();

    try stdout.print("{s}{s}{s}NAME            VERSION     LANGUAGES   DESCRIPTION{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}────────────────────────────────────────────────────────────────────────────{s}\n", .{ P, Color.dim, Color.reset });

    for (index.templates) |tmpl| {
        // Filter by keyword if provided
        if (keyword_filter) |kw| {
            var found = false;
            if (std.mem.indexOf(u8, tmpl.description, kw) != null) {
                found = true;
            }
            if (std.mem.indexOf(u8, tmpl.name, kw) != null) {
                found = true;
            }
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
