//! Auth API response shapes. MeResponse carries the authenticated user's profile plus their
//! accessible workspaces — the first call every client makes after login. DirectoryResponse
//! lists org members for workspace access management.
pub const MeWorkspace = struct {
    ws_id: []const u8,
    name: []const u8,
    role: []const u8 = "",
};

pub const MeResponse = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    scopes: []const u8,
    workspaces: []const MeWorkspace = &.{},
};

pub const DirectoryMember = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    status: []const u8 = "",
    joined_at: []const u8,
};

pub const DirectoryResponse = struct {
    members: []const DirectoryMember = &.{},
};
