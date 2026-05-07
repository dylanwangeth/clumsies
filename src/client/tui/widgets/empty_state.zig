const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const d = @import("draw.zig");
const api_state = @import("../api/state.zig");

pub const EmptyState = struct {
    status: api_state.ConnectionStatus,
    entity_name: []const u8,

    pub fn widget(self: *const EmptyState) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = emptyStateTypeErasedDrawFn,
        };
    }

    fn emptyStateTypeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const EmptyState = @ptrCast(@alignCast(ptr));
        const msg = self.message(ctx.arena);
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        d.fillSurface(&surface, theme.PANEL);
        d.writeText(&surface, ctx, 2, 1, msg, .{ .fg = theme.MUTED, .bg = theme.PANEL });
        return surface;
    }

    pub fn message(self: *const EmptyState, arena: std.mem.Allocator) []const u8 {
        return switch (self.status) {
            .connecting => std.fmt.allocPrint(arena, "Loading {s}...", .{self.entity_name}) catch "Loading...",
            .error_auth => "Authentication required. Use the login panel to continue.",
            .error_network => "Hub unavailable. Check clumsies-hub.",
            .disconnected => "Not connected to hub.",
            .connected => std.fmt.allocPrint(arena, "No {s} loaded.", .{self.entity_name}) catch "No data loaded.",
        };
    }
};

/// Backward-compatible draw helper. Delegates to EmptyState widget.
pub fn drawEmptyState(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    col: u16,
    row: u16,
    status: api_state.ConnectionStatus,
    entity_name: []const u8,
) void {
    const es: EmptyState = .{ .status = status, .entity_name = entity_name };
    const msg = es.message(ctx.arena);
    d.writeText(surface, ctx, col, row, msg, .{ .fg = theme.MUTED, .bg = theme.PANEL });
}
