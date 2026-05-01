//! Public feature namespace for the TUI. Each feature owns one stable
//! product area while the shell imports this facade for top-level routing.

pub const analysis = @import("features/analysis/root.zig");
pub const dashboard = @import("features/dashboard/root.zig");
pub const drafts = @import("features/drafts/root.zig");
pub const library = @import("features/library/root.zig");
pub const review = @import("features/review/root.zig");
pub const settings = @import("features/settings/root.zig");
pub const workspace = @import("features/workspace/root.zig");
