//! Tool catalogs and implementations for coding-agent surfaces.
//!
//! This package is intentionally outside `agent/core`: choosing which tools to
//! expose is a product/runtime decision, not part of the provider-neutral agent
//! contract.

pub const bash = @import("bash.zig");
pub const Builtin = @import("builtin.zig");
pub const catalog = @import("catalog.zig");
pub const discuss = @import("discuss.zig");
pub const edit = @import("edit.zig");
pub const read = @import("read.zig");
pub const search = @import("search.zig");
pub const workspace = @import("workspace.zig");
pub const write = @import("write.zig");
pub const DEFINITIONS = catalog.DEFINITIONS;

test {
    _ = bash;
    _ = Builtin;
    _ = catalog;
    _ = discuss;
    _ = edit;
    _ = read;
    _ = search;
    _ = workspace;
    _ = write;
}
