const std = @import("std");
const fs = std.fs;
const http = @import("../http.zig");
const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, template_name: ?[]const u8, list: bool, force: bool) !void {
    const registry_path = commands.getRegistryPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine home directory.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(registry_path);

    if (list) {
        try stdout.writeAll("\n");
        try listInstalledTemplates(stdout, registry_path);
        try stdout.writeAll("\n");
        return;
    }

    const name = template_name orelse {
        try stderr.print("\n{s}{s}{s}Error:{s} template name required\n{s}Usage: {s}clumsies install <name>{s}\n\n", .{ P, Color.bold, Color.red, Color.reset, P, Color.cyan, Color.reset });
        return;
    };

    const template_install_path = try std.fs.path.join(allocator, &.{ registry_path, name });
    defer allocator.free(template_install_path);

    const exists = blk: {
        fs.accessAbsolute(template_install_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (exists and !force) {
        try stderr.print("\n{s}{s}{s}Error:{s} template '{s}{s}{s}' already installed. Use {s}--force{s} to overwrite.\n\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset, Color.cyan, Color.reset });
        return;
    }

    try stdout.print("\n{s}Installing template '{s}{s}{s}'...\n\n", .{ P, Color.bold, name, Color.reset });
    stdout.flush() catch {};

    if (exists) {
        try stdout.print("{s}  {s}→{s} Removing existing template...\n", .{ P, Color.orange, Color.reset });
        fs.deleteTreeAbsolute(template_install_path) catch |err| {
            try stderr.print("{s}{s}{s}Error:{s} removing existing template: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
            return;
        };
    }

    fs.cwd().makePath(registry_path) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} creating registry directory: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };

    try stdout.print("{s}  {s}→{s} Fetching template info...\n", .{ P, Color.orange, Color.reset });
    stdout.flush() catch {};

    var index = http.fetchIndex(allocator) catch |err| {
        if (err == http.HttpError.RequestFailed) {
            try stderr.print("{s}{s}{s}Error:{s} Failed to connect to registry. Check your network.\n", .{ P, Color.bold, Color.red, Color.reset });
        } else {
            try stderr.print("{s}{s}{s}Error:{s} fetching template index: {any}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        }
        return;
    };
    defer index.deinit();

    var template_files: ?[][]const u8 = null;
    for (index.templates) |tmpl| {
        if (std.mem.eql(u8, tmpl.name, name)) {
            template_files = tmpl.files;
            break;
        }
    }

    const files = template_files orelse {
        try stderr.print("{s}{s}{s}Error:{s} template '{s}{s}{s}' not found in registry.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        return;
    };

    if (files.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} template '{s}{s}{s}' has no files.\n", .{ P, Color.bold, Color.red, Color.reset, Color.bold, name, Color.reset });
        return;
    }

    var downloaded: usize = 0;
    var failed: usize = 0;

    for (files) |file_path| {
        const remote_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, file_path }) catch continue;
        defer allocator.free(remote_path);

        const local_relative = file_path;

        const local_path = try std.fs.path.join(allocator, &.{ template_install_path, local_relative });
        defer allocator.free(local_path);

        if (std.fs.path.dirname(local_path)) |parent| {
            fs.cwd().makePath(parent) catch {};
        }

        const content = http.downloadFile(allocator, remote_path) catch |err| {
            if (err == http.HttpError.NotFound) {
                try stderr.print("{s}  {s}{s}✗{s} Not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, local_relative });
            } else {
                try stderr.print("{s}  {s}{s}✗{s} Failed: {s}\n", .{ P, Color.bold, Color.red, Color.reset, local_relative });
            }
            failed += 1;
            continue;
        };
        defer allocator.free(content);

        const file = fs.createFileAbsolute(local_path, .{}) catch {
            try stderr.print("{s}  {s}{s}✗{s} Cannot write: {s}\n", .{ P, Color.bold, Color.red, Color.reset, local_relative });
            failed += 1;
            continue;
        };
        defer file.close();

        file.writeAll(content) catch {
            try stderr.print("{s}  {s}{s}✗{s} Write error: {s}\n", .{ P, Color.bold, Color.red, Color.reset, local_relative });
            failed += 1;
            continue;
        };

        try stdout.print("{s}  {s}→{s} {s}\n", .{ P, Color.orange, Color.reset, local_relative });
        downloaded += 1;
    }

    try stdout.writeAll("\n");

    if (failed > 0) {
        try stderr.print("{s}{s}{s}Warning:{s} {d} files failed to download.\n", .{ P, Color.bold, Color.orange, Color.reset, failed });
    }

    if (downloaded > 0) {
        try stdout.print("{s}{s}{s}✓{s} Installed {s}{d}{s} files to {s}{s}{s}\n\n", .{ P, Color.bold, Color.orange, Color.reset, Color.bold, downloaded, Color.reset, Color.orange, template_install_path, Color.reset });
    } else {
        try stderr.print("{s}{s}{s}Error:{s} No files were installed.\n\n", .{ P, Color.bold, Color.red, Color.reset });
    }
}

fn listInstalledTemplates(stdout: anytype, registry_path: []const u8) !void {
    try stdout.print("{s}{s}{s}Installed templates:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });

    var registry_dir = fs.openDirAbsolute(registry_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.print("{s}  {s}(none){s}\n", .{ P, Color.dim, Color.reset });
            return;
        }
        return err;
    };
    defer registry_dir.close();

    var it = registry_dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            try stdout.print("{s}  {s}•{s} {s}{s}{s}\n", .{ P, Color.green, Color.reset, Color.bold, entry.name, Color.reset });
            count += 1;
        }
    }

    if (count == 0) {
        try stdout.print("{s}  {s}(none){s}\n", .{ P, Color.dim, Color.reset });
    }
}
