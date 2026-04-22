const std = @import("std");
const adapter = @import("../adapter/root.zig");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

pub fn parseScopeOrPrint(raw_scope: []const u8, stderr: *std.Io.Writer) ?adapter.model.Scope {
    const scope = adapter.model.Scope.parseCli(raw_scope) orelse {
        stderr.print(
            "{s}{s}{s}Error:{s} --scope must be workspace or user.\n",
            .{ P, Color.bold, Color.red, Color.reset },
        ) catch {};
        return null;
    };
    return scope;
}

pub fn resolvePackageOrPrint(
    agent_name: []const u8,
    stderr: *std.Io.Writer,
) ?adapter.packages.AdapterPackage {
    const pkg = adapter.packages.resolve(agent_name) orelse {
        stderr.print(
            "{s}{s}{s}Error:{s} Unknown adapter agent: {s}\n",
            .{ P, Color.bold, Color.red, Color.reset, agent_name },
        ) catch {};
        return null;
    };
    return pkg;
}

pub fn defaultPackageOrPrint(stderr: *std.Io.Writer) ?adapter.packages.AdapterPackage {
    const all_packages = adapter.packages.all();
    if (all_packages.len == 0) {
        stderr.print(
            "{s}{s}{s}Error:{s} No adapter packages are available.\n",
            .{ P, Color.bold, Color.red, Color.reset },
        ) catch {};
        return null;
    }
    if (all_packages.len > 1) {
        stderr.print(
            "{s}{s}{s}Error:{s} Multiple adapter packages are available. Re-run with --agent.\n",
            .{ P, Color.bold, Color.red, Color.reset },
        ) catch {};
        return null;
    }
    return all_packages[0];
}

pub fn choosePackage(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    rule: []const u8,
) !adapter.packages.AdapterPackage {
    const all_packages = adapter.packages.all();
    if (all_packages.len == 0) return error.NoAdapterPackages;

    var choices = try allocator.alloc(adapter.ui.Choice, all_packages.len);
    defer allocator.free(choices);

    for (all_packages, 0..) |pkg, idx| {
        choices[idx] = .{
            .key = pkg.id,
            .label = pkg.display_name,
            .description = pkg.choice_description,
        };
    }

    const index = try adapter.ui.promptChoice(stdout, allocator, rule, choices, 0);
    return all_packages[index];
}

pub fn printSectionTitle(stdout: *std.Io.Writer, title: []const u8) !void {
    try stdout.print("{s}{s}{s}{s}{s}\n", .{ P, Color.bold, Color.orange, title, Color.reset });
}

pub fn printDetailLine(stdout: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try stdout.writeAll(P);
    try stdout.writeAll("  ");
    try stdout.print(fmt ++ "\n", args);
}

pub fn printFileAction(stdout: *std.Io.Writer, action: []const u8, path: []const u8) !void {
    try stdout.writeAll(P);
    try stdout.writeAll("  ");
    try stdout.writeAll(action);
    if (action.len < 7) {
        try writeSpaces(stdout, 7 - action.len);
    }
    try stdout.writeAll("  ");
    try stdout.writeAll(path);
    try stdout.writeAll("\n");
}

pub fn scopeDisplayName(scope: []const u8) []const u8 {
    if (std.mem.eql(u8, scope, "workspace")) return "Workspace";
    if (std.mem.eql(u8, scope, "user")) return "User";
    return scope;
}

fn writeSpaces(stdout: *std.Io.Writer, count: usize) !void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        try stdout.writeAll(" ");
    }
}
