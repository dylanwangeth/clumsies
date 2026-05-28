//! Tool catalogs and implementations for coding-agent surfaces.
//!
//! This package is intentionally outside `agent/core`: choosing which tools to
//! expose is a product/runtime decision, not part of the provider-neutral agent
//! contract.

pub const catalog = @import("catalog.zig");
pub const DEFINITIONS = catalog.DEFINITIONS;

test {
    _ = catalog;
}
