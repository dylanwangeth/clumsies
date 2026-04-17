const std = @import("std");
const flag = @import("../flags.zig");
const adapter = @import("../adapter/root.zig");
const adapter_cli = @import("adapter_cli.zig");
const styles = @import("../styles.zig");
const workspace_config = @import("../workspace_config.zig");

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
        error.UnexpectedArgument => {
            try stderr.print("Error: unexpected argument {s}\n", .{err_ctx.flag.?});
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

    const workspace_root_opt = try workspace_config.resolveCurrentWorkspaceRoot(allocator);
    defer if (workspace_root_opt) |workspace_root| allocator.free(workspace_root);

    const pkg = if (parsed.value(FLAG_AGENT)) |agent_name|
        adapter_cli.resolvePackageOrPrint(agent_name, stderr) orelse return
    else if (parsed.boolean(FLAG_YES))
        adapter_cli.defaultPackageOrPrint(stderr) orelse return
    else
        try adapter_cli.choosePackage(stdout, allocator, "Which agent install do you want to remove?");

    const workspace_target_root_opt = try pkg.resolveTargetRoot(allocator, .workspace, workspace_root_opt);
    defer if (workspace_target_root_opt) |path| allocator.free(path);

    const user_target_root_opt = try pkg.resolveTargetRoot(allocator, .user, workspace_root_opt);
    defer if (user_target_root_opt) |path| allocator.free(path);

    const selected_scope = if (parsed.value(FLAG_SCOPE)) |raw_scope|
        adapter_cli.parseScopeOrPrint(raw_scope, stderr) orelse return
    else
        try chooseRemoveScope(stdout, allocator, pkg, parsed.boolean(FLAG_YES), workspace_target_root_opt, user_target_root_opt, stderr) orelse return;

    const selected_target_root = switch (selected_scope) {
        .workspace => workspace_target_root_opt,
        .user => user_target_root_opt,
    };
    if (selected_target_root == null) {
        if (selected_scope == .workspace) {
            try stderr.print(
                "{s}{s}{s}Error:{s} workspace scope is not available here. Bind this directory to a clumsies workspace first with {s}clumsies init{s}, or use {s}--scope user{s}.\n",
                .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset, Color.cyan, Color.reset },
            );
            return;
        }
        try stderr.print(
            "{s}{s}{s}Error:{s} {s} scope is not available for {s} in the current environment.\n",
            .{ P, Color.bold, Color.red, Color.reset, selected_scope.cliString(), pkg.display_name },
        );
        return;
    }

    const target_root = try allocator.dupe(u8, selected_target_root.?);
    defer allocator.free(target_root);

    var loaded_opt = try adapter.store.loadManifestForTarget(allocator, pkg.id, selected_scope.cliString(), target_root);
    if (loaded_opt == null or !std.mem.eql(u8, loaded_opt.?.parsed.value.status, "active")) {
        if (loaded_opt) |*loaded| loaded.deinit();
        try stdout.print(
            "{s}{s}No active {s} adapter install found{s} for target: {s}{s}{s}\n",
            .{ P, Color.orange, pkg.display_name, Color.reset, Color.cyan, selected_scope.cliString(), Color.reset },
        );
        return;
    }
    defer loaded_opt.?.deinit();

    const manifest = loaded_opt.?.parsed.value;
    try stdout.print("{s}{s}{s}Clumsies Remove Adapter{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}Agent: {s}{s}{s}\n", .{ P, Color.cyan, pkg.display_name, Color.reset });
    try stdout.print(
        "{s}Target: {s}{s} ({s}){s}\n\n",
        .{ P, Color.cyan, adapter_cli.scopeDisplayName(manifest.scope), manifest.target_root, Color.reset },
    );

    try adapter_cli.printSectionTitle(stdout, "Plan");
    try adapter_cli.printDetailLine(stdout, "Remove Clumsies-managed fragments from shared adapter files", .{});
    try adapter_cli.printDetailLine(stdout, "Remove managed helper files under {s}", .{manifest.target_root});
    try adapter_cli.printDetailLine(stdout, "Preserve unrelated configuration outside Clumsies-managed content", .{});
    try stdout.writeAll("\n");

    try adapter_cli.printSectionTitle(stdout, "Files");
    for (manifest.managed_resources) |resource| {
        if (resource.active) {
            const absolute_path = try resourceAbsolutePath(allocator, manifest.target_root, resource);
            defer allocator.free(absolute_path);
            try adapter_cli.printFileAction(stdout, "remove", absolute_path);
        }
    }
    try stdout.writeAll("\n");

    try adapter_cli.printSectionTitle(stdout, "Safety");
    try adapter_cli.printDetailLine(stdout, "Unrelated configuration will remain in place", .{});
    try adapter_cli.printDetailLine(stdout, "Only Clumsies-managed content recorded in the install manifest will be removed", .{});
    try adapter_cli.printDetailLine(stdout, "If a managed file drifted after installation, clumsies will leave it in place", .{});
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
    workspace_target_root_opt: ?[]const u8,
    user_target_root_opt: ?[]const u8,
    stderr: *std.Io.Writer,
) !?adapter.model.Scope {
    const workspace_active = try scopeActive(allocator, pkg.id, .workspace, workspace_target_root_opt, user_target_root_opt);
    const user_active = try scopeActive(allocator, pkg.id, .user, workspace_target_root_opt, user_target_root_opt);

    if (non_interactive) {
        if (workspace_active) return .workspace;
        if (user_active) return .user;
        try stderr.print("{s}{s}{s}Error:{s} No active {s} adapter install was found.\n", .{ P, Color.bold, Color.red, Color.reset, pkg.display_name });
        return null;
    }

    if (!workspace_active and !user_active) {
        try stdout.print("{s}{s}No active {s} adapter install found{s} for workspace or user scope.\n", .{ P, Color.orange, pkg.display_name, Color.reset });
        return null;
    }

    if (workspace_active and !user_active) return .workspace;
    if (user_active and !workspace_active) return .user;

    var workspace_description_owned: ?[]u8 = null;
    defer if (workspace_description_owned) |description| allocator.free(description);
    var user_description_owned: ?[]u8 = null;
    defer if (user_description_owned) |description| allocator.free(description);

    _ = workspace_target_root_opt.?;
    _ = user_target_root_opt.?;
    workspace_description_owned = try allocator.dupe(u8, pkg.remove_workspace_scope_description orelse "Current workspace install");
    user_description_owned = try allocator.dupe(u8, pkg.remove_user_scope_description orelse "Machine-wide install");

    const choices = [_]adapter.ui.Choice{
        .{
            .key = "workspace",
            .label = "Workspace",
            .description = workspace_description_owned.?,
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
    return if (index == 0) .workspace else .user;
}

fn scopeActive(
    allocator: std.mem.Allocator,
    agent_name: []const u8,
    scope: adapter.model.Scope,
    workspace_target_root_opt: ?[]const u8,
    user_target_root_opt: ?[]const u8,
) !bool {
    const target_root = switch (scope) {
        .workspace => blk: {
            const workspace_target_root = workspace_target_root_opt orelse return false;
            break :blk try allocator.dupe(u8, workspace_target_root);
        },
        .user => blk: {
            const user_target_root = user_target_root_opt orelse return false;
            break :blk try allocator.dupe(u8, user_target_root);
        },
    };
    defer allocator.free(target_root);

    var loaded_opt = try adapter.store.loadManifestForTarget(allocator, agent_name, scope.cliString(), target_root);
    defer if (loaded_opt) |*loaded| loaded.deinit();

    return if (loaded_opt) |loaded|
        std.mem.eql(u8, loaded.parsed.value.status, "active")
    else
        false;
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies remove-adapter [--agent <name>] [--scope workspace|user] [--yes]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Remove the selected agent adapter from the chosen scope.\n", .{P});
}

fn printWizardHeader(stdout: *std.Io.Writer) !void {
    try stdout.print("{s}{s}{s}Clumsies Remove Adapter{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}Remove a Clumsies adapter install{s}\n\n", .{ P, Color.dim, Color.reset });
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
