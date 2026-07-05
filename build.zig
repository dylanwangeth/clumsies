const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = @import("build.zig.zon").version;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    const enable_keychain = target.result.os.tag == .macos and builtin.os.tag == .macos;
    options.addOption(bool, "enable_keychain", enable_keychain);
    addCodexAdapterAssetOptions(b, options);
    addClaudeCodeAdapterAssetOptions(b, options);
    const build_options_module = options.createModule();
    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });

    const lib_module = b.addModule("clumsies_lib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_module },
            .{ .name = "toml", .module = toml_dep.module("toml") },
        },
    });

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const pg = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    });

    const hub_module = createHubModule(
        b,
        target,
        optimize,
        build_options_module,
        lib_module,
        httpz.module("httpz"),
        pg.module("pg"),
    );

    // Local client and Hub artifact
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const client_module = createClientModule(
        b,
        target,
        optimize,
        build_options_module,
        lib_module,
        toml_dep.module("toml"),
        vaxis_dep.module("vaxis"),
        hub_module,
        enable_keychain,
    );

    const exe = b.addExecutable(.{
        .name = "clumsies",
        .root_module = client_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run clumsies CLI");
    run_step.dependOn(&run_cmd.step);

    const hub_run_cmd = b.addRunArtifact(exe);
    hub_run_cmd.step.dependOn(b.getInstallStep());
    hub_run_cmd.addArg("hub");
    if (b.args) |args| {
        hub_run_cmd.addArgs(args);
    }

    const hub_run_step = b.step("hub", "Run clumsies Hub Server");
    hub_run_step.dependOn(&hub_run_cmd.step);

    // Client tests
    const client_test_module = createClientModule(
        b,
        target,
        optimize,
        build_options_module,
        lib_module,
        toml_dep.module("toml"),
        vaxis_dep.module("vaxis"),
        hub_module,
        enable_keychain,
    );
    const unit_tests = b.addTest(.{
        .root_module = client_test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run CLI unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Hub tests
    const hub_tests = b.addTest(.{
        .root_module = createHubModule(
            b,
            target,
            optimize,
            build_options_module,
            lib_module,
            httpz.module("httpz"),
            pg.module("pg"),
        ),
    });

    const run_hub_tests = b.addRunArtifact(hub_tests);
    const hub_test_step = b.step("test-hub", "Run Hub Server unit tests");
    hub_test_step.dependOn(&run_hub_tests.step);
}

fn createClientModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_module: *std.Build.Module,
    lib_module: *std.Build.Module,
    toml_module: *std.Build.Module,
    vaxis_module: *std.Build.Module,
    hub_module: *std.Build.Module,
    enable_keychain: bool,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/client/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_module },
            .{ .name = "clumsies_lib", .module = lib_module },
            .{ .name = "toml", .module = toml_module },
        },
    });
    module.addImport("vaxis", vaxis_module);
    module.addImport("clumsies_hub_main", hub_module);
    if (enable_keychain) {
        module.linkFramework("Security", .{});
        module.linkFramework("CoreFoundation", .{});
    }
    return module;
}

fn createHubModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_module: *std.Build.Module,
    lib_module: *std.Build.Module,
    httpz_module: *std.Build.Module,
    pg_module: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/hub/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_module },
            .{ .name = "clumsies_lib", .module = lib_module },
            .{ .name = "httpz", .module = httpz_module },
            .{ .name = "pg", .module = pg_module },
        },
    });
}

fn addCodexAdapterAssetOptions(b: *std.Build, options: *std.Build.Step.Options) void {
    options.addOption([]const u8, "adapter_codex_runtime_config_toml", readSourceAsset(
        b,
        "assets/adapters/codex/runtime/config.toml.tpl",
    ));
    options.addOption([]const u8, "adapter_codex_runtime_hooks_json", readSourceAsset(
        b,
        "assets/adapters/codex/runtime/hooks.json.tpl",
    ));
    options.addOption([]const u8, "adapter_codex_runtime_resolve_binary_sh", readSourceAsset(
        b,
        "assets/adapters/codex/runtime/hooks/resolve-binary.sh.tpl",
    ));
    options.addOption([]const u8, "adapter_codex_runtime_session_start_sh", readSourceAsset(
        b,
        "assets/adapters/codex/runtime/hooks/session-start.sh.tpl",
    ));
    options.addOption([]const u8, "adapter_codex_runtime_user_prompt_submit_sh", readSourceAsset(
        b,
        "assets/adapters/codex/runtime/hooks/user-prompt-submit.sh.tpl",
    ));
}

fn addClaudeCodeAdapterAssetOptions(b: *std.Build, options: *std.Build.Step.Options) void {
    options.addOption([]const u8, "adapter_claude_code_runtime_settings_json", readSourceAsset(
        b,
        "assets/adapters/claude-code/runtime/settings.json.tpl",
    ));
    options.addOption([]const u8, "adapter_claude_code_runtime_mcp_json", readSourceAsset(
        b,
        "assets/adapters/claude-code/runtime/mcp.json.tpl",
    ));
    options.addOption([]const u8, "adapter_claude_code_runtime_resolve_binary_sh", readSourceAsset(
        b,
        "assets/adapters/claude-code/runtime/hooks/resolve-binary.sh.tpl",
    ));
    options.addOption([]const u8, "adapter_claude_code_runtime_session_start_sh", readSourceAsset(
        b,
        "assets/adapters/claude-code/runtime/hooks/session-start.sh.tpl",
    ));
    options.addOption([]const u8, "adapter_claude_code_runtime_user_prompt_submit_sh", readSourceAsset(
        b,
        "assets/adapters/claude-code/runtime/hooks/user-prompt-submit.sh.tpl",
    ));
    options.addOption([]const u8, "adapter_claude_code_runtime_skill_activate", readSourceAsset(
        b,
        "assets/adapters/claude-code/runtime/skills/activate/SKILL.md",
    ));
    options.addOption([]const u8, "adapter_claude_code_runtime_skill_ntmd", readSourceAsset(
        b,
        "assets/adapters/claude-code/runtime/skills/ntmd/SKILL.md",
    ));
    options.addOption([]const u8, "adapter_claude_code_runtime_skill_setup", readSourceAsset(
        b,
        "assets/adapters/claude-code/runtime/skills/setup/SKILL.md",
    ));
    options.addOption([]const u8, "adapter_codex_runtime_skill_activate", readSourceAsset(
        b,
        "assets/adapters/codex/runtime/skills/activate/SKILL.md",
    ));
    options.addOption([]const u8, "adapter_codex_runtime_skill_ntmd", readSourceAsset(
        b,
        "assets/adapters/codex/runtime/skills/ntmd/SKILL.md",
    ));
    options.addOption([]const u8, "adapter_codex_runtime_skill_setup", readSourceAsset(
        b,
        "assets/adapters/codex/runtime/skills/setup/SKILL.md",
    ));
}

fn readSourceAsset(b: *std.Build, relative_path: []const u8) []const u8 {
    const absolute_path = b.path(relative_path).getPath(b);
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, absolute_path, b.allocator, .limited(1024 * 1024)) catch |err| {
        std.debug.panic("failed to read asset {s}: {s}", .{ relative_path, @errorName(err) });
    };
}
