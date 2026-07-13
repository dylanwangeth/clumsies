//! Attestation upload orchestrator. Authenticates with the Server and wraps batch_upload with an HTTP
//! POST uploader targeting /api/attestations for the TUI background upload task.
const std = @import("std");
const upload_worker = @import("batch_upload.zig");
const auth_mod = @import("auth.zig");
const ServerClient = @import("server_client.zig").ServerClient;

const log = std.log.scoped(.attestation_upload);

pub const FlushResult = upload_worker.FlushResult;

pub const FlushOutcome = union(enum) {
    flushed: FlushResult,
    not_authenticated,
    failed: anyerror,
};

const ServerUploader = struct {
    allocator: std.mem.Allocator,
    client: *ServerClient,
    last_status: ?std.http.Status = null,

    fn post(ctx: *anyopaque, body: []const u8) !bool {
        const self: *ServerUploader = @ptrCast(@alignCast(ctx));
        var response = self.client.post("/api/attestations", body) catch |err| {
            log.warn("POST /api/attestations transport error: {}", .{err});
            return err;
        };
        defer response.deinit();
        self.last_status = response.status;
        if (@intFromEnum(response.status) >= 200 and @intFromEnum(response.status) < 300) {
            return true;
        }
        log.warn(
            "POST /api/attestations rejected status={d} body={s}",
            .{ @intFromEnum(response.status), response.body },
        );
        return false;
    }

    fn uploader(self: *ServerUploader) upload_worker.Uploader {
        return .{ .ctx = @ptrCast(self), .postFn = ServerUploader.post };
    }
};

/// Flush pending attestation events for the given workspace to the Server.
/// Loads credentials from `auth.loadAuth`; returns `not_authenticated` if
/// no credentials are available so callers can skip silently.
pub fn flushWorkspace(allocator: std.mem.Allocator, ws_id: []const u8) FlushOutcome {
    const auth_info = auth_mod.loadAuth(allocator) catch |err| switch (err) {
        error.NotAuthenticated => return .not_authenticated,
        else => return .{ .failed = err },
    };
    defer auth_info.deinit(allocator);

    var server = ServerClient.init(allocator, auth_info.server_url, auth_info.access_token);
    defer server.deinit();
    server.enableRefresh(auth_info.refresh_token, auth_info.username, auth_mod.persistRotatedTokens) catch |err| return .{ .failed = err };
    var adapter: ServerUploader = .{ .allocator = allocator, .client = &server };

    return flushWorkspaceWithUploader(allocator, ws_id, adapter.uploader());
}

pub fn flushWorkspaceWithUploader(allocator: std.mem.Allocator, ws_id: []const u8, uploader: upload_worker.Uploader) FlushOutcome {
    const result = upload_worker.flushOnce(allocator, ws_id, uploader) catch |err| {
        return .{ .failed = err };
    };
    return .{ .flushed = result };
}
