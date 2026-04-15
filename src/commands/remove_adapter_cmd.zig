const std = @import("std");
const flag = @import("../flags.zig");
const adapter = @import("../adapter/root.zig");
const styles = @import("../styles.zig");

const FLAG_AGENT: usize = 0;
const FLAG_SCOPE: usize = 1;
const FLAG_YES: usize = 2;

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const specs = [_]flag.FlagSpec{
        .{ .short = 'a', .long = "agent", .kind = .value },
        .{ .short = 's', .long = "scope", .kind = .value },
        .{ .short = 'y', .long = "yes", .kind = .boolean },
    };

    var err_ctx: flag.ErrorContext = .{};
    var parsed = flag.parse(&specs, allocator, args, &err_ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelp(stdout);
            return;
        },
        error.UnknownFlag => {
            try stderr.print("Error: unknown flag {s}\n", .{err_ctx.flag.?});
            return;
        },
        error.MissingValue => {
            try stderr.print("Error: {s} requires a value\n", .{err_ctx.flag.?});
            return;
        },
        else => return err,
    };
    defer parsed.deinit(allocator);

    if (!parsed.boolean(FLAG_YES)) {
        try printWizardHeader(stdout);
    }

    const repo_root_opt = try adapter.planner.resolveRepoRoot(allocator);
    defer if (repo_root_opt) |repo_root| allocator.free(repo_root);

    const pkg = if (parsed.value(FLAG_AGENT)) |agent_name|
        resolvePackageOrPrint(agent_name, stderr) orelse return
    else if (parsed.boolean(FLAG_YES))
        defaultPackageOrPrint(stderr) orelse return
    else
        try choosePackage(stdout, allocator);

    const repo_target_root_opt = try pkg.resolveTargetRoot(allocator, .repo, repo_root_opt);
    defer if (repo_target_root_opt) |path| allocator.free(path);

    const user_target_root_opt = try pkg.resolveTargetRoot(allocator, .user, repo_root_opt);
    defer if (user_target_root_opt) |path| allocator.free(path);

    const selected_scope = if (parsed.value(FLAG_SCOPE)) |raw_scope|
        parseScopeOrPrint(raw_scope, stderr) orelse return
    else
        try chooseRemoveScope(stdout, allocator, pkg, parsed.boolean(FLAG_YES), repo_target_root_opt, user_target_root_opt, stderr) orelse return;

    const selected_target_root = switch (selected_scope) {
        .repo => repo_target_root_opt,
        .user => user_target_root_opt,
    };
    if (selected_target_root == null) {
        try stderr.print(
            "{s}{s}{s}Error:{s} {s} scope is not available for {s} in the current environment.\n",
            .{ P, Color.bold, Color.red, Color.reset, selected_scope.asString(), pkg.display_name },
        );
        return;
    }

    const target_root = try allocator.dupe(u8, selected_target_root.?);
    defer allocator.free(target_root);

    var loaded_opt = try adapter.store.loadManifestForTarget(allocator, pkg.id, selected_scope.asString(), target_root);
    if (loaded_opt == null or !std.mem.eql(u8, loaded_opt.?.parsed.value.status, "active")) {
        if (loaded_opt) |*loaded| loaded.deinit();
        try stdout.print(
            "{s}{s}No active {s} adapter install found{s} for target: {s}{s}{s}\n",
            .{ P, Color.orange, pkg.display_name, Color.reset, Color.cyan, scopeDisplayName(selected_scope.asString()), Color.reset },
        );
        return;
    }
    defer loaded_opt.?.deinit();

    const manifest = loaded_opt.?.parsed.value;
    try stdout.print("{s}{s}{s}Clumsies Remove Adapter{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}Agent: {s}{s}{s}\n", .{ P, Color.cyan, pkg.display_name, Color.reset });
    try stdout.print(
        "{s}Target: {s}{s} ({s}){s}\n\n",
        .{ P, Color.cyan, scopeDisplayName(manifest.scope), manifest.target_root, Color.reset },
    );

    try printSectionTitle(stdout, "Plan");
    try printDetailLine(stdout, "Remove Clumsies-managed fragments from shared adapter files", .{});
    try printDetailLine(stdout, "Remove managed helper files under {s}", .{manifest.target_root});
    try printDetailLine(stdout, "Preserve unrelated configuration outside Clumsies-managed content", .{});
    try stdout.writeAll("\n");

    try printSectionTitle(stdout, "Files");
    for (manifest.managed_resources) |resource| {
        if (resource.active) {
            const absolute_path = try resourceAbsolutePath(allocator, manifest.target_root, resource);
            defer allocator.free(absolute_path);
            try printFileAction(stdout, "remove", absolute_path);
        }
    }
    try stdout.writeAll("\n");

    try printSectionTitle(stdout, "Safety");
    try printDetailLine(stdout, "Unrelated configuration will remain in place", .{});
    try printDetailLine(stdout, "Only Clumsies-managed content recorded in the install manifest will be removed", .{});
    try printDetailLine(stdout, "If a managed file drifted after installation, clumsies will leave it in place", .{});
    try stdout.writeAll("\n");

    if (!parsed.boolean(FLAG_YES)) {
        if (!try adapter.ui.promptYesNo(stdout, allocator, "Remove this install?", false)) {
            try stdout.print("{s}{s}Cancelled.{s} No files were removed.\n", .{ P, Color.dim, Color.reset });
            return;
        }
    }

    const summary = try adapter.remove.removeInstall(stdout, allocator, &loaded_opt.?);
    try stdout.print(
        "{s}{s}{s}{s} adapter removed.{s} Removed {d} file(s)",
        .{ P, Color.bold, Color.green, pkg.display_name, Color.reset, summary.removed_count },
    );
    if (summary.blocked_count > 0) {
        try stdout.print(", left {d} in place because they changed after installation.\n", .{summary.blocked_count});
    } else {
        try stdout.writeAll(".\n");
    }
}

fn chooseRemoveScope(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    pkg: adapter.packages.AdapterPackage,
    non_interactive: bool,
    repo_target_root_opt: ?[]const u8,
    user_target_root_opt: ?[]const u8,
    stderr: *std.Io.Writer,
) !?adapter.model.Scope {
    const repo_active = try scopeActive(allocator, pkg.id, .repo, repo_target_root_opt, user_target_root_opt);
    const user_active = try scopeActive(allocator, pkg.id, .user, repo_target_root_opt, user_target_root_opt);

    if (non_interactive) {
        if (repo_active) return .repo;
        if (user_active) return .user;
        try stderr.print("{s}{s}{s}Error:{s} No active {s} adapter install was found.\n", .{ P, Color.bold, Color.red, Color.reset, pkg.display_name });
        return null;
    }

    if (!repo_active and !user_active) {
        try stdout.print("{s}{s}No active {s} adapter install found{s} for repo or user scope.\n", .{ P, Color.orange, pkg.display_name, Color.reset });
        return null;
    }

    if (repo_active and !user_active) return .repo;
    if (user_active and !repo_active) return .user;

    var repo_description_owned: ?[]u8 = null;
    defer if (repo_description_owned) |description| allocator.free(description);
    var user_description_owned: ?[]u8 = null;
    defer if (user_description_owned) |description| allocator.free(description);

    _ = repo_target_root_opt.?;
    _ = user_target_root_opt.?;
    repo_description_owned = try allocator.dupe(u8, pkg.remove_repo_scope_description orelse "Current repository install");
    user_description_owned = try allocator.dupe(u8, pkg.remove_user_scope_description orelse "Machine-wide install");

    const choices = [_]adapter.ui.Choice{
        .{
            .key = "repo",
            .label = "Project",
            .description = repo_description_owned.?,
        },
        .{
            .key = "user",
            .label = "User",
            .description = user_description_owned.?,
        },
    };
    const index = try adapter.ui.promptChoice(
        stdout,
        allocator,
        "Which install do you want to remove?",
        &choices,
        0,
    );
    return if (index == 0) .repo else .user;
}

fn scopeActive(
    allocator: std.mem.Allocator,
    agent_name: []const u8,
    scope: adapter.model.Scope,
    repo_target_root_opt: ?[]const u8,
    user_target_root_opt: ?[]const u8,
) !bool {
    const target_root = switch (scope) {
        .repo => blk: {
            const repo_target_root = repo_target_root_opt orelse return false;
            break :blk try allocator.dupe(u8, repo_target_root);
        },
        .user => blk: {
            const user_target_root = user_target_root_opt orelse return false;
            break :blk try allocator.dupe(u8, user_target_root);
        },
    };
    defer allocator.free(target_root);

    var loaded_opt = try adapter.store.loadManifestForTarget(allocator, agent_name, scope.asString(), target_root);
    defer if (loaded_opt) |*loaded| loaded.deinit();

    return if (loaded_opt) |loaded|
        std.mem.eql(u8, loaded.parsed.value.status, "active")
    else
        false;
}

fn parseScopeOrPrint(raw_scope: []const u8, stderr: *std.Io.Writer) ?adapter.model.Scope {
    const scope = adapter.model.Scope.parse(raw_scope) orelse {
        stderr.print("{s}{s}{s}Error:{s} --scope must be repo or user.\n", .{ P, Color.bold, Color.red, Color.reset }) catch {};
        return null;
    };
    return scope;
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies remove-adapter [--agent <name>] [--scope repo|user] [--yes]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Remove the selected agent adapter from the chosen scope.\n", .{P});
}

fn resolvePackageOrPrint(agent_name: []const u8, stderr: *std.Io.Writer) ?adapter.packages.AdapterPackage {
    const pkg = adapter.packages.resolve(agent_name) orelse {
        stderr.print("{s}{s}{s}Error:{s} Unknown adapter agent: {s}\n", .{ P, Color.bold, Color.red, Color.reset, agent_name }) catch {};
        return null;
    };
    return pkg;
}

fn defaultPackageOrPrint(stderr: *std.Io.Writer) ?adapter.packages.AdapterPackage {
    const all_packages = adapter.packages.all();
    if (all_packages.len == 0) {
        stderr.print("{s}{s}{s}Error:{s} No adapter packages are available.\n", .{ P, Color.bold, Color.red, Color.reset }) catch {};
        return null;
    }
    if (all_packages.len > 1) {
        stderr.print("{s}{s}{s}Error:{s} Multiple adapter packages are available. Re-run with --agent.\n", .{ P, Color.bold, Color.red, Color.reset }) catch {};
        return null;
    }
    return all_packages[0];
}

fn choosePackage(stdout: *std.Io.Writer, allocator: std.mem.Allocator) !adapter.packages.AdapterPackage {
    const all_packages = adapter.packages.all();
    if (all_packages.len == 0) return error.NoAdapterPackages;

    var choices = try allocator.alloc(adapter.ui.Choice, all_packages.len);
    defer allocator.free(choices);

    for (all_packages, 0..) |pkg, idx| {
        choices[idx] = .{
            .key = pkg.id,
            .label = pkg.display_name,
            .description = packageChoiceDescription(pkg),
        };
    }

    const index = try adapter.ui.promptChoice(
        stdout,
        allocator,
        "Which agent install do you want to remove?",
        choices,
        0,
    );
    return all_packages[index];
}

fn printWizardHeader(stdout: *std.Io.Writer) !void {
    try stdout.print("{s}{s}{s}Clumsies Remove Adapter{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}Remove a Clumsies adapter install{s}\n\n", .{ P, Color.dim, Color.reset });
}

fn printSectionTitle(stdout: *std.Io.Writer, title: []const u8) !void {
    try stdout.print("{s}{s}{s}{s}{s}\n", .{ P, Color.bold, Color.orange, title, Color.reset });
}

fn printDetailLine(stdout: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try stdout.writeAll(P);
    try stdout.writeAll("  ");
    try stdout.print(fmt ++ "\n", args);
}

fn printFileAction(stdout: *std.Io.Writer, action: []const u8, path: []const u8) !void {
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

fn writeSpaces(stdout: *std.Io.Writer, count: usize) !void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        try stdout.writeAll(" ");
    }
}

fn scopeDisplayName(scope: []const u8) []const u8 {
    if (std.mem.eql(u8, scope, "repo")) return "Project";
    if (std.mem.eql(u8, scope, "user")) return "User";
    return scope;
}

fn packageChoiceDescription(pkg: adapter.packages.AdapterPackage) []const u8 {
    return pkg.choice_description;
}

fn resourceAbsolutePath(
    allocator: std.mem.Allocator,
    target_root: []const u8,
    resource: adapter.model.ManagedResource,
) ![]u8 {
    if (resource.absolute_path) |absolute_path| {
        return allocator.dupe(u8, absolute_path);
    }
    return std.fs.path.join(allocator, &.{ target_root, resource.relative_path });
}
