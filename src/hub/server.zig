const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");
const auth = @import("auth.zig");
const workspace_handler = @import("workspace.zig");
const library_handler = @import("library.zig");
const Config = @import("config.zig");

const Server = @This();

http: HttpServer,

const HttpServer = httpz.Server(*Context);

pub const Context = struct {
    pool: *pg.Pool,
    config: Config,
    user: ?auth.AuthUser = null,
};

pub fn init(allocator: std.mem.Allocator, config: Config, pool: *pg.Pool) !Server {
    const ctx = try allocator.create(Context);
    ctx.* = .{ .pool = pool, .config = config };

    var server = try HttpServer.init(allocator, .{
        .address = .all(config.port),
    }, ctx);

    const router = try server.router(.{});

    router.post("/api/auth/login", auth.handleLogin, .{});
    router.post("/api/auth/refresh", auth.handleRefresh, .{});
    router.get("/api/auth/me", auth.handleMe, .{});
    router.post("/api/workspaces", workspace_handler.handleCreate, .{});
    router.get("/api/workspaces/:ws_id", workspace_handler.handleGet, .{});
    router.patch("/api/workspaces/:ws_id", workspace_handler.handleUpdate, .{});
    router.get("/api/workspaces/:ws_id/manifest", workspace_handler.handleGetManifest, .{});
    router.post("/api/workspaces/:ws_id/prompts", workspace_handler.handleAddPrompt, .{});
    router.get("/api/org/library/manifest", library_handler.handleGetManifest, .{});
    router.get("/api/org/library/prompts", library_handler.handleListPrompts, .{});

    return .{ .http = server };
}

pub fn deinit(self: *Server) void {
    self.http.deinit();
}

pub fn listen(self: *Server) !void {
    try self.http.listen();
}
