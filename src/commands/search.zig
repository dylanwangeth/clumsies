const std = @import("std");
const http = @import("../http.zig");
const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, task_filter: ?[]const u8, keyword_filter: ?[]const u8) !void {
    try stdout.writeAll("\n");

    var index = http.fetchIndex(allocator) catch |err| {
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

    try stdout.print("{s}{s}{s}NAME            TASK        DESCRIPTION{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}──────────────────────────────────────────────────────────────────{s}\n", .{ P, Color.dim, Color.reset });

    for (index.templates) |tmpl| {
        if (task_filter) |tf| {
            if (!std.mem.eql(u8, tmpl.task, tf)) continue;
        }

        if (keyword_filter) |kw| {
            var found = false;
            for (tmpl.keywords) |k| {
                if (std.mem.indexOf(u8, k, kw) != null) {
                    found = true;
                    break;
                }
            }
            if (!found and std.mem.indexOf(u8, tmpl.description, kw) != null) {
                found = true;
            }
            if (!found and std.mem.indexOf(u8, tmpl.name, kw) != null) {
                found = true;
            }
            if (!found) continue;
        }

        try stdout.print("{s}{s: <15} {s: <11} {s}\n", .{
            P,
            tmpl.name,
            tmpl.task,
            tmpl.description,
        });
    }

    try stdout.writeAll("\n");
}
