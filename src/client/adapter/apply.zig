//! Adapter plan executor. Writes each managed file from the Plan to disk, creates directories
//! as needed, records a manifest snapshot, and logs WAL events for auditability.
const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");

pub fn applyAdaptPlan(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    plan: *const model.Plan,
) !model.ApplySummary {
    try store.appendWalEvent(allocator, .{
        .event_type = "revision_started",
        .install_id = plan.install_id,
        .revision = plan.revision,
        .mode = plan.mode,
        .timestamp = @import("clumsies_lib").util.time_util.nowMillis(),
        .message = "Starting adapter apply",
    });

    var managed_resources: std.ArrayList(model.ManagedResource) = .empty;
    defer managed_resources.deinit(allocator);

    var wrote_count: usize = 0;
    var kept_count: usize = 0;
    var created_at = @import("clumsies_lib").util.time_util.nowMillis();

    var existing_manifest_opt = try store.loadManifest(allocator, plan.install_id);
    defer if (existing_manifest_opt) |*loaded| loaded.deinit();
    if (existing_manifest_opt) |loaded| {
        created_at = loaded.parsed.value.created_at;
    }

    for (plan.steps, 0..) |step, idx| {
        const absolute_path = try stepAbsolutePath(allocator, plan.target_root, step);
        defer allocator.free(absolute_path);

        try stdout.print("[{d}/{d}] {s} {s}\n", .{ idx + 1, plan.steps.len, step.action, absolute_path });
        try stdout.flush();

        const should_write = !std.mem.eql(u8, step.action, "keep") and !std.mem.eql(u8, step.action, "skip");
        if (should_write) {
            writeManagedFileAbsolute(absolute_path, step.content, step.file_mode) catch |err| {
                try store.appendWalEvent(allocator, .{
                    .event_type = "step_failed",
                    .install_id = plan.install_id,
                    .revision = plan.revision,
                    .mode = plan.mode,
                    .timestamp = @import("clumsies_lib").util.time_util.nowMillis(),
                    .step_id = step.step_id,
                    .resource_id = step.resource_id,
                    .target = step.relative_path,
                    .status = "failed",
                    .message = @errorName(err),
                });
                try store.appendWalEvent(allocator, .{
                    .event_type = "revision_aborted",
                    .install_id = plan.install_id,
                    .revision = plan.revision,
                    .mode = plan.mode,
                    .timestamp = @import("clumsies_lib").util.time_util.nowMillis(),
                    .message = "Adapter apply aborted",
                });
                return err;
            };
            wrote_count += 1;
        } else {
            kept_count += 1;
        }

        const fingerprint = try store.fingerprintForContent(allocator, step.managed_content orelse step.content);
        try managed_resources.append(allocator, .{
            .resource_id = step.resource_id,
            .resource_kind = step.resource_kind,
            .relative_path = step.relative_path,
            .absolute_path = step.absolute_path,
            .ownership = step.ownership,
            .fingerprint = fingerprint,
            .managed_content = if (step.managed_content) |managed_content|
                try allocator.dupe(u8, managed_content)
            else
                null,
            .active = !std.mem.eql(u8, step.action, "skip"),
        });

        try store.appendWalEvent(allocator, .{
            .event_type = "step_applied",
            .install_id = plan.install_id,
            .revision = plan.revision,
            .mode = plan.mode,
            .timestamp = @import("clumsies_lib").util.time_util.nowMillis(),
            .step_id = step.step_id,
            .resource_id = step.resource_id,
            .target = step.relative_path,
            .status = "applied",
            .message = if (std.mem.eql(u8, step.action, "create"))
                "Managed file written"
            else if (std.mem.eql(u8, step.action, "update"))
                "Managed file updated"
            else if (std.mem.eql(u8, step.action, "skip"))
                "Existing unmanaged shared file skipped"
            else
                "Existing managed file kept",
        });
    }

    var manifest = model.InstallManifest{
        .install_id = try allocator.dupe(u8, plan.install_id),
        .adapter_id = plan.agent_name,
        .target_agent = plan.agent_name,
        .scope = plan.scope,
        .target_root = try allocator.dupe(u8, plan.target_root),
        .status = "active",
        .active_revision = plan.revision,
        .managed_resources = try managed_resources.toOwnedSlice(allocator),
        .created_at = created_at,
        .updated_at = @import("clumsies_lib").util.time_util.nowMillis(),
    };
    defer model.deinitOwnedManifest(allocator, &manifest);

    try store.writeManifest(allocator, manifest);

    try store.appendWalEvent(allocator, .{
        .event_type = "revision_committed",
        .install_id = plan.install_id,
        .revision = plan.revision,
        .mode = plan.mode,
        .timestamp = @import("clumsies_lib").util.time_util.nowMillis(),
        .message = "Adapter apply committed",
    });

    return .{
        .wrote_count = wrote_count,
        .kept_count = kept_count,
    };
}

fn writeManagedFileAbsolute(absolute_path: []const u8, content: []const u8, file_mode: u16) !void {
    if (std.fs.path.dirname(absolute_path)) |parent| {
        try ensureDirTreeAbsolute(parent);
    }
    const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, absolute_path, .{ .truncate = true, .mode = file_mode });
    defer file.close(std.Options.debug_io);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, std.Options.debug_io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

fn ensureDirTreeAbsolute(dir_path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(dir_path) orelse return err;
            if (std.mem.eql(u8, parent, dir_path)) return err;
            try ensureDirTreeAbsolute(parent);
            std.Io.Dir.createDirAbsolute(std.Options.debug_io, dir_path, .default_dir) catch |mkdir_err| {
                if (mkdir_err != error.PathAlreadyExists) return mkdir_err;
            };
        },
        else => return err,
    };
}

fn stepAbsolutePath(
    allocator: std.mem.Allocator,
    target_root: []const u8,
    step: model.PlanStep,
) ![]u8 {
    if (step.absolute_path) |absolute_path| {
        return allocator.dupe(u8, absolute_path);
    }
    return std.fs.path.join(allocator, &.{ target_root, step.relative_path });
}
