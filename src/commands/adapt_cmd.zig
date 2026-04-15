const std = @import("std");
const flag = @import("../flags.zig");
const adapter = @import("../adapter/root.zig");
const styles = @import("../styles.zig");

const FLAG_AGENT: usize = 0;
const FLAG_SCOPE: usize = 1;
const FLAG_UPDATE: usize = 2;
const FLAG_YES: usize = 3;

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const specs = [_]flag.FlagSpec{
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

    const scope = if (parsed.value(FLAG_SCOPE)) |raw_scope|
        parseScopeOrPrint(raw_scope, stderr) orelse return
    else if (parsed.boolean(FLAG_YES))
        if (repoTargetAvailable(repo_target_root_opt)) adapter.model.Scope.repo else adapter.model.Scope.user
    else
        try chooseScope(stdout, allocator, pkg, repo_target_root_opt, user_target_root_opt);

    const selected_target_root = switch (scope) {
        .repo => repo_target_root_opt,
        .user => user_target_root_opt,
    };

    if (selected_target_root == null) {
        try stderr.print(
            "{s}{s}{s}Error:{s} {s} scope is not available for {s} in the current environment.\n",
            .{ P, Color.bold, Color.red, Color.reset, scope.asString(), pkg.display_name },
        );
        return;
    }

    const target_root = try allocator.dupe(u8, selected_target_root.?);
    defer allocator.free(target_root);

    var is_update = parsed.boolean(FLAG_UPDATE);
    var loaded_opt = try adapter.store.loadManifestForTarget(allocator, pkg.id, scope.asString(), target_root);
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
            const prompt = try std.fmt.allocPrint(allocator, "A {s} adapter install is already active here. Apply an update?", .{pkg.display_name});
            defer allocator.free(prompt);
            is_update = try adapter.ui.promptYesNo(stdout, allocator, prompt, true);
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

            const peer_active = try peerScopeActive(allocator, pkg, scope, repo_target_root_opt, user_target_root_opt);
            try printPlan(stdout, allocator, pkg, &plan, peer_active);

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
                .{ P, Color.cyan, scopeDisplayName(plan.scope), plan.target_root, Color.reset },
            );
            try stdout.writeAll("Remove with: ");
            try stdout.print("{s}clumsies remove-adapter --agent {s}", .{ Color.cyan, pkg.id });
            if (scope == .user) {
                try stdout.print(" --scope user{s}\n", .{Color.reset});
            } else {
                try stdout.print(" --scope repo{s}\n", .{Color.reset});
            }
        },
    }
}

fn parseScopeOrPrint(raw_scope: []const u8, stderr: *std.Io.Writer) ?adapter.model.Scope {
    const scope = adapter.model.Scope.parse(raw_scope) orelse {
        stderr.print("{s}{s}{s}Error:{s} --scope must be repo or user.\n", .{ P, Color.bold, Color.red, Color.reset }) catch {};
        return null;
    };
    return scope;
}

fn repoTargetAvailable(repo_target_root_opt: ?[]const u8) bool {
    return repo_target_root_opt != null;
}

fn chooseScope(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    pkg: adapter.packages.AdapterPackage,
    repo_target_root_opt: ?[]const u8,
    user_target_root_opt: ?[]const u8,
) !adapter.model.Scope {
    var choices: [2]adapter.ui.Choice = undefined;
    var count: usize = 0;
    var repo_description_owned: ?[]u8 = null;
    defer if (repo_description_owned) |description| allocator.free(description);
    var user_description_owned: ?[]u8 = null;
    defer if (user_description_owned) |description| allocator.free(description);

    if (repo_target_root_opt) |repo_target_root| {
        _ = repo_target_root;
        repo_description_owned = try allocator.dupe(u8, pkg.repo_scope_description orelse "Only this repository");
        choices[count] = .{
            .key = "repo",
            .label = "Project",
            .description = repo_description_owned.?,
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

    const prompt = "Where should Clumsies be installed?";
    const index = try adapter.ui.promptChoice(stdout, allocator, prompt, choices[0..count], 0);

    return if (repo_target_root_opt != null and index == 0) .repo else .user;
}

fn peerScopeActive(
    allocator: std.mem.Allocator,
    pkg: adapter.packages.AdapterPackage,
    selected_scope: adapter.model.Scope,
    repo_target_root_opt: ?[]const u8,
    user_target_root_opt: ?[]const u8,
) !bool {
    switch (selected_scope) {
        .repo => {
            const user_target_root = user_target_root_opt orelse return false;
            var loaded_opt = try adapter.store.loadManifestForTarget(allocator, pkg.id, "user", user_target_root);
            defer if (loaded_opt) |*loaded| loaded.deinit();
            return if (loaded_opt) |loaded|
                std.mem.eql(u8, loaded.parsed.value.status, "active")
            else
                false;
        },
        .user => {
            const repo_target_root = repo_target_root_opt orelse return false;
            var loaded_opt = try adapter.store.loadManifestForTarget(allocator, pkg.id, "repo", repo_target_root);
            defer if (loaded_opt) |*loaded| loaded.deinit();
            return if (loaded_opt) |loaded|
                std.mem.eql(u8, loaded.parsed.value.status, "active")
            else
                false;
        },
    }
}

fn printPlan(
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
        .{ P, Color.cyan, scopeDisplayName(plan.scope), plan.target_root, Color.reset },
    );
    try stdout.print("{s}Mode: {s}{s}{s}\n\n", .{ P, Color.cyan, prettyMode(plan.mode), Color.reset });

    try printSectionTitle(stdout, "Plan");
    try printDetailLine(stdout, "Install or update Clumsies-managed runtime resources for {s}", .{pkg.display_name});
    if (countResourcesByKind(plan, "json_hooks_registry") > 0) {
        try printDetailLine(stdout, "Merge Clumsies hook handlers into the host hook registry", .{});
    }
    if (countResourcesByKind(plan, "json_mcp_registry") > 0 or countResourcesByKind(plan, "toml_fragment") > 0) {
        try printDetailLine(stdout, "Merge Clumsies-managed config into shared host config files", .{});
    }
    if (countWorkflowSkills(plan) > 0) {
        try printDetailLine(stdout, "Import {d} workflow skill(s) from the current workspace cache", .{countWorkflowSkills(plan)});
    }
    try printDetailLine(stdout, "Record install state in {s} for safe removal", .{state_path});
    try stdout.writeAll("\n");

    try printSectionTitle(stdout, "Files");
    for (plan.steps) |step| {
        const absolute_path = try planStepAbsolutePath(allocator, plan.target_root, step);
        defer allocator.free(absolute_path);
        try printFileAction(stdout, prettyAction(step.action), absolute_path);
    }
    try stdout.writeAll("\n");

    try printSectionTitle(stdout, "Safety");
    try printDetailLine(stdout, "Unrelated config outside Clumsies-managed fragments will be preserved", .{});
    try printDetailLine(stdout, "Shared files are merged instead of blindly overwritten", .{});
    if (peer_scope_active) {
        try printDetailLine(stdout, "Another active install exists in the other scope, so config layers may stack", .{});
    }
    if (std.mem.eql(u8, plan.scope, "user")) {
        try printDetailLine(stdout, "User scope affects all {s} sessions on this machine", .{pkg.display_name});
    }
    try printDetailLine(stdout, "Remove with clumsies remove-adapter --agent {s} --scope {s}", .{ pkg.id, plan.scope });
    try stdout.writeAll("\n");
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies adapt [--agent <name>] [--scope repo|user] [--update] [--yes]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Install or update an agent adapter for the selected scope.\n", .{P});
    try out.print("{s}When multiple adapter packages are available, choose one interactively or pass {s}--agent{s}.\n", .{ P, Color.cyan, Color.reset });
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
        "Which agent do you want to adapt for?",
        choices,
        0,
    );
    return all_packages[index];
}

fn printWizardHeader(stdout: *std.Io.Writer) !void {
    try stdout.print("{s}{s}{s}Clumsies Adapt{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}Set up Clumsies for a coding agent{s}\n\n", .{ P, Color.dim, Color.reset });
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
            std.mem.startsWith(u8, step.resource_id, "claude-code.skills.workflow."))
        {
            count += 1;
        }
    }
    return count;
}
