const std = @import("std");
const http = @import("../http.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, hash: []const u8, lang: []const u8) !void {
    try stdout.writeAll("\n");

    // Fetch templates index to find template info by hash
    var sp = spinner.init(stdout, "Fetching template info");
    sp.start();

    var templates_index = http.fetchTemplatesIndex(allocator) catch |err| {
        sp.fail();
        if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} Could not fetch templates index.\n", .{ P, Color.bold, Color.red, Color.reset });
        }
        return;
    };
    defer templates_index.deinit();

    const tmpl = templates_index.findByHash(hash) orelse {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} Template with hash '{s}{s}{s}' not found.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, hash, Color.reset });
        return;
    };
    sp.succeed();

    // Fetch template content
    var sp_content = spinner.init(stdout, "Fetching template content");
    sp_content.start();

    const remote_path = std.fmt.allocPrint(allocator, "templates/{s}/files/{s}/CLAUDE.md", .{ tmpl.name, lang }) catch {
        sp_content.fail();
        try stderr.print("{s}{s}{s}Error:{s} Out of memory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(remote_path);

    const content = http.downloadFile(allocator, remote_path) catch |err| {
        sp_content.fail();
        if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}{s}Error:{s} Template '{s}{s}{s}' not found for language '{s}'.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, tmpl.name, Color.reset, lang });
        } else if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer allocator.free(content);
    sp_content.clear();

    try stdout.print("\n{s}{s}{s}Template:{s} {s} [{s}]\n", .{ P, Color.bold, Color.orange, Color.reset, tmpl.name, lang });
    try stdout.print("{s}{s}────────────────────────────────────────────────────────────────{s}\n", .{ P, Color.orange, Color.reset });

    var line_start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            try stdout.writeAll(P);
            try stdout.writeAll(content[line_start..i]);
            try stdout.writeAll("\n");
            line_start = i + 1;
        }
    }
    if (line_start < content.len) {
        try stdout.writeAll(P);
        try stdout.writeAll(content[line_start..]);
        try stdout.writeAll("\n");
    }

    try stdout.print("{s}{s}────────────────────────────────────────────────────────────────{s}\n\n", .{ P, Color.orange, Color.reset });
}
