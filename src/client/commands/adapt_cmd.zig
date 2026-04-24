const std = @import("std");
const flag = @import("../flags.zig");
const adapter = @import("../adapter/root.zig");
const adapter_cli = @import("adapter_cli.zig");
const styles = @import("../styles.zig");
const workspace_config = @import("../workspace_config.zig");

const FLAG_INSTALL: usize = 0;
const FLAG_REMOVE: usize = 1;
const FLAG_LIST: usize = 2;
const FLAG_AGENT: usize = 3;
const FLAG_SCOPE: usize = 4;
const FLAG_UPDATE: usize = 5;
const FLAG_YES: usize = 6;

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const specs = [_]flag.FlagSpec{
        .{ .short = 'i', .long = "install", .kind = .boolean },
        .{ .short = 'r', .long = "remove", .kind = .boolean },
        .{ .short = 'l', .long = "list", .kind = .boolean },
        .{ .short = 'a', .long = "agent", .kind = .value },
        .{ .short = 's', .long = "scope", .kind = .value },
        .{ .short = 'u', .long = "update", .kind = .boolean },
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

    const want_remove = parsed.boolean(FLAG_REMOVE);
    const want_list = parsed.boolean(FLAG_LIST);

    if (want_remove and want_list) {
        try stderr.print("{s}{s}{s}Error:{s} --remove and --list are mutually exclusive.\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    if (want_list) {
        try listInstalls(stdout, allocator);
        return;
    }

    if (want_remove) {
        try runRemove(stdout, stderr, allocator, &parsed);
        return;
    }

    try runInstall(stdout, stderr, allocator, &parsed);
}

// ── Install ──────────────────────────────────────────────────────────────────

fn runInstall(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    allocator: std.mem.Allocator,
    parsed: *flag.ParseResult,
) !void {
    if (!parsed.boolean(FLAG_YES)) {
        try printInstallHeader(stdout);
    }

    const workspace_root_opt = try workspace_config.resolveCurrentWorkspaceRoot(allocator);
    defer if (workspace_root_opt) |workspace_root| allocator.free(workspace_root);

    const pkg = if (parsed.value(FLAG_AGENT)) |agent_name|
        adapter_cli.resolvePackageOrPrint(agent_name, stderr) orelse return
    else if (parsed.boolean(FLAG_YES))
        adapter_cli.defaultPackageOrPrint(stderr) orelse return
    else
        try adapter_cli.choosePackage(stdout, allocator, "Which agent do you want to adapt for?");

    const workspace_target_root_opt = try pkg.resolveTargetRoot(allocator, .workspace, workspace_root_opt);
    defer if (workspace_target_root_opt) |path| allocator.free(path);

    const user_target_root_opt = try pkg.resolveTargetRoot(allocator, .user, workspace_root_opt);
    defer if (user_target_root_opt) |path| allocator.free(path);

    const scope = if (parsed.value(FLAG_SCOPE)) |raw_scope|
        adapter_cli.parseScopeOrPrint(raw_scope, stderr) orelse return
    else if (parsed.boolean(FLAG_YES))
        if (workspaceTargetAvailable(workspace_target_root_opt)) adapter.model.Scope.workspace else adapter.model.Scope.user
    else
        try chooseInstallScope(stdout, allocator, pkg, workspace_target_root_opt, user_target_root_opt);

    const selected_target_root = switch (scope) {
        .workspace => workspace_target_root_opt,
        .user => user_target_root_opt,
    };

    if (selected_target_root == null) {
        if (scope == .workspace) {
            try stderr.print(
                "{s}{s}{s}Error:{s} workspace scope is not available here. Bind this directory to a clumsies workspace first with {s}clumsies init{s}, or use {s}--scope user{s}.\n",
                .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset, Color.cyan, Color.reset },
            );
            return;
        }
        try stderr.print(
            "{s}{s}{s}Error:{s} {s} scope is not available for {s} in the current environment.\n",
            .{ P, Color.bold, Color.red, Color.reset, scope.cliString(), pkg.display_name },
        );
        return;
    }

    const target_root = try allocator.dupe(u8, selected_target_root.?);
    defer allocator.free(target_root);

    var is_update = parsed.boolean(FLAG_UPDATE);
    var loaded_opt = try adapter.store.loadManifestForTarget(allocator, pkg.id, scope.cliString(), target_root);
    defer if (loaded_opt) |*loaded| loaded.deinit();

    if (loaded_opt) |loaded| {
        const is_active = std.mem.eql(u8, loaded.parsed.value.status, "active");
        if (is_active and !is_update) {
            if (parsed.boolean(FLAG_YES)) {
                try stderr.print(
                    "{s}{s}{s}Error:{s} This scope already has an active {s} adapter install. Re-run with --update or remove it first.\n",
                    .{ P, Color.bold, Color.red, Color.reset, pkg.display_name },
                );
                return;
            }
            const rule = try std.fmt.allocPrint(allocator, "A {s} adapter install is already active here. Apply an update?", .{pkg.display_name});
            defer allocator.free(rule);
            is_update = try adapter.ui.promptYesNo(stdout, allocator, rule, true);
            if (!is_update) {
                try stdout.print("{s}{s}Cancelled.{s} No files were written.\n", .{ P, Color.dim, Color.reset });
                return;
            }
        } else if (!is_active and is_update) {
            try stderr.print("{s}{s}{s}Error:{s} No active {s} adapter install exists in the selected scope.\n", .{ P, Color.bold, Color.red, Color.reset, pkg.display_name });
            return;
        }
    } else if (is_update) {
        try stderr.print("{s}{s}{s}Error:{s} No active {s} adapter install exists in the selected scope.\n", .{ P, Color.bold, Color.red, Color.reset, pkg.display_name });
        return;
    }

    const plan_result = try adapter.planner.buildAdaptPlan(allocator, pkg, scope, target_root, is_update);
    switch (plan_result) {
        .conflict => |conflict| {
            var owned_conflict = conflict;
            defer owned_conflict.deinit(allocator);
            try printConflict(stderr, &owned_conflict);
            return;
        },
        .plan => |plan| {
            defer {
                var owned_plan = plan;
                owned_plan.deinit(allocator);
            }

            const peer_active = try peerScopeActive(allocator, pkg, scope, workspace_target_root_opt, user_target_root_opt);
            try printInstallPlan(stdout, allocator, pkg, &plan, peer_active);

            if (!parsed.boolean(FLAG_YES)) {
                const confirm_prompt = if (std.mem.eql(u8, plan.mode, "update"))
                    "Apply this update?"
                else
                    "Apply this install?";
                if (!try adapter.ui.promptYesNo(stdout, allocator, confirm_prompt, true)) {
                    try stdout.print("{s}{s}Cancelled.{s} No files were written.\n", .{ P, Color.dim, Color.reset });
                    return;
                }
            }

            const summary = try adapter.apply.applyAdaptPlan(stdout, allocator, &plan);
            try stdout.print(
                "{s}{s}{s}Clumsies adapted {s}.{s} Wrote {d} file(s), left {d} unchanged.\n",
                .{
                    P,
                    Color.bold,
                    Color.green,
                    pkg.display_name,
                    Color.reset,
                    summary.wrote_count,
                    summary.kept_count,
                },
            );
            try stdout.print("{s}Agent: {s}{s}{s}\n", .{ P, Color.cyan, pkg.id, Color.reset });
            try stdout.print(
                "{s}Target: {s}{s} ({s}){s}\n",
                .{ P, Color.cyan, adapter_cli.scopeDisplayName(plan.scope), plan.target_root, Color.reset },
            );
            try stdout.writeAll("Remove with: ");
            try stdout.print("{s}clumsies adapt --remove --agent {s}", .{ Color.cyan, pkg.id });
            try stdout.print(" --scope {s}{s}\n", .{ scope.cliString(), Color.reset });
        },
    }
}

// ── Remove ───────────────────────────────────────────────────────────────────

fn runRemove(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    allocator: std.mem.Allocator,
    parsed: *flag.ParseResult,
) !void {
    if (!parsed.boolean(FLAG_YES)) {
        try printRemoveHeader(stdout);
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

// ── List ─────────────────────────────────────────────────────────────────────

fn listInstalls(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
) !void {
    const installs_dir_path = adapter.store.adaptersBasePath(allocator) catch {
        try stdout.print("{s}{s}No adapter installs found.{s}\n", .{ P, Color.dim, Color.reset });
        return;
    };
    defer allocator.free(installs_dir_path);

    var installs_dir = std.fs.openDirAbsolute(installs_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try stdout.print("{s}{s}No adapter installs found.{s}\n", .{ P, Color.dim, Color.reset });
            return;
        },
        else => return err,
    };
    defer installs_dir.close();

    var manifests: std.ArrayList(adapter.store.LoadedManifest) = .empty;
    defer {
        for (manifests.items) |*m| m.deinit();
        manifests.deinit(allocator);
    }

    var iterator = installs_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;

        const manifest_path = try std.fs.path.join(allocator, &.{ installs_dir_path, entry.name, "manifest.json" });
        defer allocator.free(manifest_path);

        const loaded = adapter.store.loadManifestAtPath(allocator, manifest_path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try manifests.append(allocator, loaded);
    }

    if (manifests.items.len == 0) {
        try stdout.print("{s}{s}No adapter installs found.{s}\n", .{ P, Color.dim, Color.reset });
        return;
    }

    try stdout.print("{s}{s}{s}Installed Adapters{s}\n\n", .{ P, Color.bold, Color.orange, Color.reset });

    for (manifests.items) |loaded| {
        if (!std.mem.eql(u8, loaded.parsed.value.status, "active")) continue;
        const m = loaded.parsed.value;
        const status_color = if (std.mem.eql(u8, m.status, "active")) Color.green else Color.dim;

        try stdout.print("{s}{s}{s}", .{ P, Color.cyan, status_color });
        try stdout.print("{s}", .{if (m.target_agent.len > 0) m.target_agent else m.adapter_id});
        try stdout.print("{s}", .{Color.reset});
        try stdout.print(" ({s})", .{m.scope});
        try stdout.print(" {s}{s}{s}", .{ P, status_color, m.status });
        try stdout.print("{s}\n", .{Color.reset});

        try stdout.print("{s}  revision: {d}{s}\n", .{ P, m.active_revision, Color.reset });

        try stdout.print("{s}  target: {s}{s}{s}\n", .{ P, Color.dim, m.target_root, Color.reset });

        var active_count: usize = 0;
        for (m.managed_resources) |r| {
            if (r.active) active_count += 1;
        }
        try stdout.print("{s}  resources: {d} managed{s}\n", .{ P, active_count, Color.reset });

        const epoch_secs: u64 = @intCast(@max(@divTrunc(m.updated_at, 1000), 0));
        const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
        const epoch_day = epoch.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch.getDaySeconds();
        const hours: u6 = @intCast(@divTrunc(day_secs.secs, 3600));
        const minutes: u6 = @intCast(@divTrunc(@mod(day_secs.secs, 3600), 60));
        const seconds: u6 = @intCast(@mod(day_secs.secs, 60));
        try stdout.print(
            "{s}  updated: {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}{s}\n",
            .{
                P,
                year_day.year,
                month_day.month,
                month_day.day_index + 1,
                hours,
                minutes,
                seconds,
                Color.reset,
            },
        );
        try stdout.writeAll("\n");
    }
}

// ── Shared helpers ───────────────────────────────────────────────────────────

fn workspaceTargetAvailable(workspace_target_root_opt: ?[]const u8) bool {
    return workspace_target_root_opt != null;
}

fn chooseInstallScope(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    pkg: adapter.packages.AdapterPackage,
    workspace_target_root_opt: ?[]const u8,
    user_target_root_opt: ?[]const u8,
) !adapter.model.Scope {
    var choices: [2]adapter.ui.Choice = undefined;
    var count: usize = 0;
    var workspace_description_owned: ?[]u8 = null;
    defer if (workspace_description_owned) |description| allocator.free(description);
    var user_description_owned: ?[]u8 = null;
    defer if (user_description_owned) |description| allocator.free(description);

    if (workspace_target_root_opt) |workspace_target_root| {
        _ = workspace_target_root;
        workspace_description_owned = try allocator.dupe(u8, pkg.workspace_scope_description orelse "Only this workspace");
        choices[count] = .{
            .key = "workspace",
            .label = "Workspace",
            .description = workspace_description_owned.?,
        };
        count += 1;
    }

    if (user_target_root_opt) |user_target_root| {
        _ = user_target_root;
        user_description_owned = try allocator.dupe(u8, pkg.user_scope_description orelse "All sessions on this machine");
        choices[count] = .{
            .key = "user",
            .label = "User",
            .description = user_description_owned.?,
        };
        count += 1;
    }

    const rule = "Where should Clumsies be installed?";
    const index = try adapter.ui.promptChoice(stdout, allocator, rule, choices[0..count], 0);

    return if (workspace_target_root_opt != null and index == 0) .workspace else .user;
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

fn peerScopeActive(
    allocator: std.mem.Allocator,
    pkg: adapter.packages.AdapterPackage,
    selected_scope: adapter.model.Scope,
    workspace_target_root_opt: ?[]const u8,
    user_target_root_opt: ?[]const u8,
) !bool {
    switch (selected_scope) {
        .workspace => {
            const user_target_root = user_target_root_opt orelse return false;
            var loaded_opt = try adapter.store.loadManifestForTarget(allocator, pkg.id, "user", user_target_root);
            defer if (loaded_opt) |*loaded| loaded.deinit();
            return if (loaded_opt) |loaded|
                std.mem.eql(u8, loaded.parsed.value.status, "active")
            else
                false;
        },
        .user => {
            const workspace_target_root = workspace_target_root_opt orelse return false;
            var loaded_opt = try adapter.store.loadManifestForTarget(allocator, pkg.id, adapter.model.Scope.workspace.cliString(), workspace_target_root);
            defer if (loaded_opt) |*loaded| loaded.deinit();
            return if (loaded_opt) |loaded|
                std.mem.eql(u8, loaded.parsed.value.status, "active")
            else
                false;
        },
    }
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

// ── Printers ─────────────────────────────────────────────────────────────────

fn printInstallPlan(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    pkg: adapter.packages.AdapterPackage,
    plan: *const adapter.model.Plan,
    peer_scope_active: bool,
) !void {
    const state_path = try adapter.store.adaptersBasePath(allocator);
    defer allocator.free(state_path);

    try stdout.print("{s}{s}{s}Clumsies Adapt{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}Agent: {s}{s}{s}\n", .{ P, Color.cyan, pkg.display_name, Color.reset });
    try stdout.print(
        "{s}Target: {s}{s} ({s}){s}\n",
        .{ P, Color.cyan, adapter_cli.scopeDisplayName(plan.scope), plan.target_root, Color.reset },
    );
    try stdout.print("{s}Mode: {s}{s}{s}\n\n", .{ P, Color.cyan, prettyMode(plan.mode), Color.reset });

    try adapter_cli.printSectionTitle(stdout, "Plan");
    try adapter_cli.printDetailLine(stdout, "Install or update Clumsies-managed runtime resources for {s}", .{pkg.display_name});
    if (countResourcesByKind(plan, "json_hooks_registry") > 0) {
        try adapter_cli.printDetailLine(stdout, "Merge Clumsies hook handlers into the host hook registry", .{});
    }
    if (countResourcesByKind(plan, "json_mcp_registry") > 0 or countResourcesByKind(plan, "toml_fragment") > 0) {
        try adapter_cli.printDetailLine(stdout, "Merge Clumsies-managed config into shared host config files", .{});
    }
    if (countWorkflowSkills(plan) > 0) {
        try adapter_cli.printDetailLine(stdout, "Import {d} workflow skill(s) from the current workspace cache", .{countWorkflowSkills(plan)});
    }
    try adapter_cli.printDetailLine(stdout, "Record install state in {s} for safe removal", .{state_path});
    for (plan.notes) |note| {
        try adapter_cli.printDetailLine(stdout, "{s}", .{note});
    }
    try stdout.writeAll("\n");

    try adapter_cli.printSectionTitle(stdout, "Files");
    for (plan.steps) |step| {
        const absolute_path = try planStepAbsolutePath(allocator, plan.target_root, step);
        defer allocator.free(absolute_path);
        try adapter_cli.printFileAction(stdout, prettyAction(step.action), absolute_path);
    }
    try stdout.writeAll("\n");

    try adapter_cli.printSectionTitle(stdout, "Safety");
    try adapter_cli.printDetailLine(stdout, "Unrelated config outside Clumsies-managed fragments will be preserved", .{});
    try adapter_cli.printDetailLine(stdout, "Shared files are merged instead of blindly overwritten", .{});
    if (peer_scope_active) {
        try adapter_cli.printDetailLine(stdout, "Another active install exists in the other scope, so config layers may stack", .{});
    }
    if (std.mem.eql(u8, plan.scope, "user")) {
        try adapter_cli.printDetailLine(stdout, "User scope affects all {s} sessions on this machine", .{pkg.display_name});
    }
    try adapter_cli.printDetailLine(stdout, "Remove with clumsies adapt --remove --agent {s} --scope {s}", .{ pkg.id, plan.scope });
    try stdout.writeAll("\n");
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage:{s}\n", .{ P, Color.reset });
    try out.print("{s}  {s}clumsies adapt{s}                  Install or update an agent adapter (default)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}clumsies adapt -i{s}                Same as above (explicit install)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}clumsies adapt -r{s}                Remove an installed adapter\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}clumsies adapt -l{s}                List installed adapters\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Flags:{s}\n", .{ P, Color.reset });
    try out.writeAll("  -i, --install   Install or update (default when no action flag is given)\n");
    try out.writeAll("  -r, --remove    Remove an installed adapter\n");
    try out.writeAll("  -l, --list      List all installed adapters\n");
    try out.writeAll("  -a, --agent     Adapter agent name\n");
    try out.writeAll("  -s, --scope     Scope: workspace or user\n");
    try out.writeAll("  -u, --update    Update an existing install\n");
    try out.writeAll("  -y, --yes       Non-interactive mode\n");
}

fn printConflict(stderr: *std.Io.Writer, conflict: *const adapter.model.Conflict) !void {
    try stderr.print("{s}{s}{s}Error:{s} {s}\n", .{ P, Color.bold, Color.red, Color.reset, conflict.message });
    try stderr.print("{s}Path: {s}{s}{s}\n", .{ P, Color.cyan, conflict.path, Color.reset });

    if (std.mem.endsWith(u8, conflict.path, "config.toml") or std.mem.endsWith(u8, conflict.path, "hooks.json")) {
        try stderr.print(
            "{s}Next step: review that file and merge, move, or remove it before running {s}clumsies adapt{s} again.\n",
            .{ P, Color.cyan, Color.reset },
        );
    }
}

fn printInstallHeader(stdout: *std.Io.Writer) !void {
    try stdout.print("{s}{s}{s}Clumsies Adapt{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}Set up Clumsies for a coding agent{s}\n\n", .{ P, Color.dim, Color.reset });
}

fn printRemoveHeader(stdout: *std.Io.Writer) !void {
    try stdout.print("{s}{s}{s}Clumsies Remove Adapter{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}Remove a Clumsies adapter install{s}\n\n", .{ P, Color.dim, Color.reset });
}

fn prettyMode(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "adapt")) return "install";
    if (std.mem.eql(u8, mode, "update")) return "update";
    return mode;
}

fn prettyAction(action: []const u8) []const u8 {
    if (std.mem.eql(u8, action, "create")) return "create";
    if (std.mem.eql(u8, action, "update")) return "update";
    if (std.mem.eql(u8, action, "keep")) return "keep";
    return action;
}

fn planStepAbsolutePath(
    allocator: std.mem.Allocator,
    target_root: []const u8,
    step: adapter.model.PlanStep,
) ![]u8 {
    if (step.absolute_path) |absolute_path| {
        return allocator.dupe(u8, absolute_path);
    }
    return std.fs.path.join(allocator, &.{ target_root, step.relative_path });
}

fn countResourcesByKind(plan: *const adapter.model.Plan, resource_kind: []const u8) usize {
    var count: usize = 0;
    for (plan.steps) |step| {
        if (std.mem.eql(u8, step.resource_kind, resource_kind)) count += 1;
    }
    return count;
}

fn countWorkflowSkills(plan: *const adapter.model.Plan) usize {
    var count: usize = 0;
    for (plan.steps) |step| {
        if (std.mem.startsWith(u8, step.resource_id, "codex.skills.workflow.") or
            std.mem.startsWith(u8, step.resource_id, "claude-code.skills.workflow.") or
            std.mem.startsWith(u8, step.resource_id, "gemini-cli.skills.workflow."))
        {
            count += 1;
        }
    }
    return count;
}
