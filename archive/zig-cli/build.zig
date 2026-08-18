const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = @import("build.zig.zon").version;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    const enable_keychain = target.result.os.tag == .macos and builtin.os.tag == .macos;
    const enable_xpc = target.result.os.tag == .macos and builtin.os.tag == .macos;
    options.addOption(bool, "enable_keychain", enable_keychain);
    options.addOption(bool, "enable_xpc", enable_xpc);
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

    // Local CLI, TUI, and MCP client artifact.
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
        enable_keychain,
        enable_xpc,
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

    // Client tests
    const client_test_module = createClientModule(
        b,
        target,
        optimize,
        build_options_module,
        lib_module,
        toml_dep.module("toml"),
        vaxis_dep.module("vaxis"),
        enable_keychain,
        enable_xpc,
    );
    const unit_tests = b.addTest(.{
        .root_module = client_test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run CLI unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn createClientModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_module: *std.Build.Module,
    lib_module: *std.Build.Module,
    toml_module: *std.Build.Module,
    vaxis_module: *std.Build.Module,
    enable_keychain: bool,
    enable_xpc: bool,
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
    if (enable_keychain) {
        module.linkFramework("Security", .{});
        module.linkFramework("CoreFoundation", .{});
    }
    if (enable_xpc) {
        module.addCSourceFile(.{
            .file = b.path("src/client/daemon/xpc_client.c"),
            .flags = &.{"-fblocks"},
        });
        module.linkSystemLibrary("System", .{});
    }
    return module;
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
    options.addOption([]const u8, "adapter_codex_runtime_issue_run_event_sh", readSourceAsset(
        b,
        "assets/adapters/codex/runtime/hooks/issue-run-event.sh.tpl",
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
    options.addOption([]const u8, "adapter_claude_code_runtime_issue_run_event_sh", readSourceAsset(
        b,
        "assets/adapters/claude-code/runtime/hooks/issue-run-event.sh.tpl",
    ));
}

fn readSourceAsset(b: *std.Build, relative_path: []const u8) []const u8 {
    const absolute_path = b.path(relative_path).getPath(b);
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, absolute_path, b.allocator, .limited(1024 * 1024)) catch |err| {
        std.debug.panic("failed to read asset {s}: {s}", .{ relative_path, @errorName(err) });
    };
}
