const std = @import("std");
const auth_mod = @import("auth.zig");
const HubClient = @import("hub_client.zig").HubClient;
const lib = @import("clumsies_lib");

pub const FlushResult = lib.upload_worker.FlushResult;

pub const FlushOutcome = union(enum) {
    flushed: FlushResult,
    not_authenticated,
    failed: anyerror,
};

const Adapter = struct {
    allocator: std.mem.Allocator,
    client: *HubClient,
    last_status: ?std.http.Status = null,

    fn post(ctx: *anyopaque, body: []const u8) !bool {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        var response = self.client.post("/api/traces", body) catch |err| {
            std.log.warn("POST /api/traces transport error: {}", .{err});
            return err;
        };
        defer response.deinit();
        self.last_status = response.status;
        if (@intFromEnum(response.status) >= 200 and @intFromEnum(response.status) < 300) {
            return true;
        }
        std.log.warn(
            "POST /api/traces rejected status={d} body={s}",
            .{ @intFromEnum(response.status), response.body },
        );
        return false;
    }

    fn uploader(self: *Adapter) lib.upload_worker.Uploader {
        return .{ .ctx = @ptrCast(self), .postFn = Adapter.post };
    }
};

/// Flush pending trace events for the given workspace to the hub server.
/// Loads credentials from `auth.loadAuth`; returns `not_authenticated` if
/// no credentials are available so callers can skip silently.
pub fn flushWorkspace(allocator: std.mem.Allocator, ws_id: []const u8) FlushOutcome {
    const auth_info = auth_mod.loadAuth(allocator) catch |err| switch (err) {
        error.NotAuthenticated => return .not_authenticated,
        else => return .{ .failed = err },
    };
    defer auth_info.deinit(allocator);

    var client = HubClient.init(allocator, auth_info.hub_url, auth_info.access_token);
    var adapter: Adapter = .{ .allocator = allocator, .client = &client };

    const result = lib.upload_worker.flushOnce(allocator, ws_id, adapter.uploader()) catch |err| {
        return .{ .failed = err };
    };
    return .{ .flushed = result };
}
