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

    const lib = b.addModule("clumsies_lib", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CLI artifact
    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "clumsies_lib", .module = lib },
            .{ .name = "toml", .module = toml_dep.module("toml") },
        },
    });

    // macOS keychain integration (native macOS builds only)
    if (enable_keychain) {
        cli_module.linkFramework("Security", .{});
        cli_module.linkFramework("CoreFoundation", .{});
    }

    const exe = b.addExecutable(.{
        .name = "clumsies",
        .root_module = cli_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run clumsies CLI");
    run_step.dependOn(&run_cmd.step);

    // Hub Server artifact
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const pg = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    });

    const hub = b.addExecutable(.{
        .name = "clumsies-hub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hub_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "httpz", .module = httpz.module("httpz") },
                .{ .name = "pg", .module = pg.module("pg") },
            },
        }),
    });

    b.installArtifact(hub);

    const hub_run_cmd = b.addRunArtifact(hub);
    hub_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        hub_run_cmd.addArgs(args);
    }

    const hub_run_step = b.step("hub", "Run clumsies Hub Server");
    hub_run_step.dependOn(&hub_run_cmd.step);

    // Seed / data pump artifact
    const seed_exe = b.addExecutable(.{
        .name = "clumsies-seed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/seed/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clumsies_lib", .module = lib },
                .{ .name = "pg", .module = pg.module("pg") },
            },
        }),
    });

    b.installArtifact(seed_exe);

    const seed_run_cmd = b.addRunArtifact(seed_exe);
    seed_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        seed_run_cmd.addArgs(args);
    }

    const seed_step = b.step("seed", "Run data seed / pump tool");
    seed_step.dependOn(&seed_run_cmd.step);

    // CLI tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "clumsies_lib", .module = lib },
            .{ .name = "toml", .module = toml_dep.module("toml") },
        },
    });
    if (enable_keychain) {
        test_module.linkFramework("Security", .{});
        test_module.linkFramework("CoreFoundation", .{});
    }
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run CLI unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Hub tests
    const hub_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hub_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "httpz", .module = httpz.module("httpz") },
                .{ .name = "pg", .module = pg.module("pg") },
            },
        }),
    });

    const run_hub_tests = b.addRunArtifact(hub_tests);
    const hub_test_step = b.step("test-hub", "Run Hub Server unit tests");
    hub_test_step.dependOn(&run_hub_tests.step);
}
