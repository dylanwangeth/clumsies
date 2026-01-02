const std = @import("std");
const http = @import("../http.zig");
const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;
const Language = commands.Language;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, name: []const u8, lang: Language) !void {
    const lang_str = if (lang == .zh) "zh" else "en";

    const remote_path = std.fmt.allocPrint(allocator, "{s}/{s}/CLAUDE.md", .{ name, lang_str }) catch {
        try stderr.print("{s}{s}{s}Error:{s} Out of memory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(remote_path);

    const content = http.downloadFile(allocator, remote_path) catch |err| {
        if (err == http.HttpError.NotFound) {
            try stderr.print("{s}{s}{s}Error:{s} Template '{s}{s}{s}' not found in registry.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        } else if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer allocator.free(content);

    const lang_display = if (lang == .zh) "zh" else "en";
    try stdout.print("\n{s}{s}{s}Template:{s} {s} [{s}]\n", .{ P, Color.bold, Color.orange, Color.reset, name, lang_display });
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
