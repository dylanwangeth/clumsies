//! Shared data contracts between Hub Server and clients. These types define the shape of
//! HTTP API responses consumed by CLI, MCP, and TUI to deserialize server data.
pub const revision = @import("revision.zig");
pub const manifest = @import("manifest.zig");
pub const auth_api = @import("auth_api.zig");
pub const workspace_api = @import("workspace_api.zig");
pub const library_api = @import("library_api.zig");
pub const stats_api = @import("stats_api.zig");
pub const collab_api = @import("collab_api.zig");

test {
    _ = revision;
    _ = manifest;
    _ = auth_api;
    _ = workspace_api;
    _ = library_api;
    _ = stats_api;
    _ = collab_api;
}
