const std = @import("std");
const fs = std.fs;
const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;

fn getTemplateName(allocator: std.mem.Allocator, templates_dir: fs.Dir, hash: []const u8) ?[]const u8 {
    const meta_path = std.fs.path.join(allocator, &.{ hash, "meta.json" }) catch return null;
    defer allocator.free(meta_path);

    const file = templates_dir.openFile(meta_path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024) catch return null;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    const name_val = parsed.value.object.get("name") orelse return null;
    return allocator.dupe(u8, name_val.string) catch null;
}

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) !void {
    const templates_path = commands.getTemplatesPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine home directory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(templates_path);

    try stdout.writeAll("\n");
    try stdout.print("{s}{s}{s}Installed templates:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });

    var templates_dir = fs.openDirAbsolute(templates_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.print("{s}  {s}(none){s}\n", .{ P, Color.dim, Color.reset });
            try stdout.writeAll("\n");
            return;
        }
        return err;
    };
    defer templates_dir.close();

    var it = templates_dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            // Try to read template name from meta.json
            const name = getTemplateName(allocator, templates_dir, entry.name) orelse entry.name;
            defer if (name.ptr != entry.name.ptr) allocator.free(name);

            try stdout.print("{s}  {s}•{s} {s}{s}{s} {s}({s}){s}\n", .{
                P,
                Color.green,
                Color.reset,
                Color.bold,
                name,
                Color.reset,
                Color.dim,
                entry.name,
                Color.reset,
            });
            count += 1;
        }
    }

    if (count == 0) {
        try stdout.print("{s}  {s}(none){s}\n", .{ P, Color.dim, Color.reset });
    }

    try stdout.writeAll("\n");
}
