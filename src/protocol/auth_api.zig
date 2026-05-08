//! Auth API request and response shapes. MeResponse carries the authenticated user's profile
//! plus their accessible workspaces — the first call every client makes after login.
//! LoginResponse / RefreshRequest / RefreshResponse describe the token lifecycle.
//! DirectoryResponse lists org members for workspace access management.
pub const LoginResponse = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: i64 = 0,
};

pub const RefreshRequest = struct {
    refresh_token: []const u8,
};

/// Refresh rotates BOTH tokens: the presented refresh token is
/// revoked server-side, and a new access + refresh pair is issued.
/// Clients must persist both new tokens; reusing the old refresh
/// token on a subsequent refresh will 401. Fixes the original
/// refresh handler which only issued a new access token, leaving
/// clients unable to refresh a second time.
pub const RefreshResponse = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: i64 = 0,
};

pub const MeWorkspace = struct {
    ws_id: []const u8,
    name: []const u8,
    role: []const u8 = "",
    owner: []const u8 = "",
};

pub const MeResponse = struct {
    user_id: []const u8,
    org_name: []const u8,
    username: []const u8,
    role: []const u8,
    scopes: []const u8,
    workspaces: []const MeWorkspace = &.{},
};

pub const UpdateProfileRequest = struct {
    username: ?[]const u8 = null,
    current_password: ?[]const u8 = null,
    new_password: ?[]const u8 = null,
};

pub const UpdateProfileResponse = struct {
    user_id: []const u8,
    org_name: []const u8,
    username: []const u8,
    role: []const u8,
    scopes: []const u8,
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
