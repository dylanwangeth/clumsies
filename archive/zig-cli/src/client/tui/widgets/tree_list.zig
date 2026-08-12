const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const theme = @import("../theme.zig");
const draw = @import("draw.zig");

pub const Selector = enum {
    none,
    off,
    on,
};

pub const SelectorPlacement = enum {
    left,
    right,
};

pub const Item = struct {
    text: []const u8,
    trailing: []const u8 = "",
    cursor: bool = false,
    active: bool = false,
    selector: Selector = .none,
    selector_placement: SelectorPlacement = .left,
    style: ?vaxis.Style = null,
    trailing_style: ?vaxis.Style = null,
};

pub const Options = struct {
    background: vaxis.Color = theme.PANEL,
    text: vaxis.Color = theme.TEXT,
    text_soft: vaxis.Color = theme.TEXT_SOFT,
    muted: vaxis.Color = theme.MUTED,
    cursor: vaxis.Color = theme.ACCENT_SOFT,
    cursor_col: u16 = 0,
    text_col: u16 = 1,
    trailing_gap: u16 = 2,
    show_cursor_marker: bool = true,
};

pub const Window = struct {
    start: usize,
    len: usize,
};

pub const Machine = struct {
    cursor: usize = 0,
    active_leaf: ?usize = null,
    selection_mode: bool = false,
    selected_leaves: std.AutoHashMapUnmanaged(usize, void) = .empty,

    pub fn deinit(self: *Machine, allocator: std.mem.Allocator) void {
        self.selected_leaves.deinit(allocator);
    }

    pub fn reset(self: *Machine) void {
        self.cursor = 0;
        self.active_leaf = null;
        self.exitSelectionMode();
    }

    pub fn sync(self: *Machine, tree: anytype) void {
        const count = tree.rowCount();
        if (count == 0) {
            self.cursor = 0;
            self.active_leaf = null;
            return;
        }
        if (self.cursor >= count) self.cursor = count - 1;
        if (tree.leafIndexAt(self.cursor)) |leaf| {
            self.active_leaf = leaf;
            return;
        }
        if (tree.dirPathAt(self.cursor) != null) {
            if (self.active_leaf == null) self.active_leaf = self.firstVisibleLeaf(tree);
            return;
        }
        if (!self.leafVisible(tree, self.active_leaf)) {
            self.active_leaf = self.firstVisibleLeaf(tree);
        }
    }

    pub fn moveBy(self: *Machine, tree: anytype, delta: isize) bool {
        const count = tree.rowCount();
        const moved = moveCursorBy(&self.cursor, count, delta);
        self.sync(tree);
        return moved;
    }

    pub fn toggleDirAtCursor(self: *Machine, allocator: std.mem.Allocator, tree: anytype) bool {
        if (tree.dirPathAt(self.cursor)) |dir| {
            tree.toggleDir(allocator, dir);
            self.sync(tree);
            return true;
        }
        return false;
    }

    pub fn toggleAllDirs(self: *Machine, allocator: std.mem.Allocator, tree: anytype) void {
        tree.toggleAll(allocator);
        self.sync(tree);
    }

    pub fn toggleSelectedAtCursor(self: *Machine, allocator: std.mem.Allocator, tree: anytype) bool {
        if (tree.leafIndexAt(self.cursor)) |leaf| {
            return self.toggleLeaf(allocator, leaf);
        }
        if (tree.dirPathAt(self.cursor)) |dir| {
            return self.toggleDirSelection(allocator, tree, dir);
        }
        return false;
    }

    pub fn toggleSelectedLeaf(self: *Machine, allocator: std.mem.Allocator, tree: anytype) bool {
        const leaf = tree.leafIndexAt(self.cursor) orelse return false;
        return self.toggleLeaf(allocator, leaf);
    }

    fn toggleLeaf(self: *Machine, allocator: std.mem.Allocator, leaf: usize) bool {
        self.selection_mode = true;
        if (self.selected_leaves.fetchRemove(leaf)) |_| return true;
        self.selected_leaves.put(allocator, leaf, {}) catch return false;
        return true;
    }

    fn toggleDirSelection(self: *Machine, allocator: std.mem.Allocator, tree: anytype, dir: []const u8) bool {
        const leaf_count = tree.leafCountUnderDir(dir);
        if (leaf_count == 0) return false;
        const should_select = !self.dirFullySelected(tree, dir);
        self.selection_mode = true;

        var idx: usize = 0;
        var changed = false;
        while (idx < leaf_count) : (idx += 1) {
            const leaf = tree.leafIndexUnderDirAt(dir, idx) orelse continue;
            if (should_select) {
                if (!self.selected_leaves.contains(leaf)) {
                    self.selected_leaves.put(allocator, leaf, {}) catch return changed;
                    changed = true;
                }
            } else {
                if (self.selected_leaves.fetchRemove(leaf)) |_| changed = true;
            }
        }
        return changed;
    }

    pub fn exitSelectionMode(self: *Machine) void {
        self.selection_mode = false;
        self.selected_leaves.clearRetainingCapacity();
    }

    pub fn selectorForLeaf(self: *const Machine, leaf: usize) Selector {
        if (!self.selection_mode) return .none;
        return if (self.selected_leaves.contains(leaf)) .on else .off;
    }

    pub fn selectorForDirAt(self: *const Machine, tree: anytype, row: usize) Selector {
        if (!self.selection_mode) return .none;
        const dir = tree.dirPathAt(row) orelse return .off;
        if (tree.leafCountUnderDir(dir) == 0) return .off;
        return if (self.dirFullySelected(tree, dir)) .on else .off;
    }

    pub fn selectedCount(self: *const Machine) usize {
        return self.selected_leaves.count();
    }

    fn leafVisible(self: *const Machine, tree: anytype, maybe_leaf: ?usize) bool {
        _ = self;
        const leaf = maybe_leaf orelse return false;
        const count = tree.rowCount();
        var row: usize = 0;
        while (row < count) : (row += 1) {
            if (tree.leafIndexAt(row)) |visible_leaf| {
                if (visible_leaf == leaf) return true;
            }
        }
        return false;
    }

    fn firstVisibleLeaf(self: *const Machine, tree: anytype) ?usize {
        _ = self;
        const count = tree.rowCount();
        var row: usize = 0;
        while (row < count) : (row += 1) {
            if (tree.leafIndexAt(row)) |leaf| return leaf;
        }
        return null;
    }

    fn dirFullySelected(self: *const Machine, tree: anytype, dir: []const u8) bool {
        const leaf_count = tree.leafCountUnderDir(dir);
        if (leaf_count == 0) return false;
        var idx: usize = 0;
        while (idx < leaf_count) : (idx += 1) {
            const leaf = tree.leafIndexUnderDirAt(dir, idx) orelse return false;
            if (!self.selected_leaves.contains(leaf)) return false;
        }
        return true;
    }
};

pub const RowWidget = struct {
    item: Item,
    options: Options = .{},

    pub fn widget(self: *const RowWidget) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const RowWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *const RowWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width: u16 = if (ctx.min.width > 0) ctx.min.width else if (ctx.max.width) |w| w else 80;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = width,
            .height = 1,
        });
        @memset(surface.buffer, theme.blank(self.options.background));
        drawItem(&surface, ctx, 0, width, self.item, self.options);
        return surface;
    }
};

pub fn drawItem(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    row: u16,
    width: u16,
    item: Item,
    options: Options,
) void {
    if (row >= surface.size.height or width == 0) return;
    if (item.cursor and options.show_cursor_marker) writeCursorMarker(surface, options.cursor_col, row, options);

    const style = itemStyle(item, options);
    const right_selector_width: u16 = if (item.selector != .none and item.selector_placement == .right) 4 else 0;
    const right_limit = width -| right_selector_width;
    var col = options.text_col;
    if (item.selector != .none and item.selector_placement == .left) {
        const marker = if (item.selector == .on) "[*] " else "[ ] ";
        draw.writeText(surface, ctx, col, row, marker, selectorStyle(item.selector, options));
        col +|= @intCast(ctx.stringWidth(marker));
    }

    const trailing_width: u16 = if (item.trailing.len == 0)
        0
    else
        @intCast(@min(ctx.stringWidth(item.trailing), width));
    const trailing_col = if (trailing_width > 0 and trailing_width + options.trailing_gap < right_limit)
        right_limit - trailing_width
    else
        right_limit;
    const text_width = if (trailing_col > col + options.trailing_gap)
        trailing_col - col - options.trailing_gap
    else
        right_limit -| col;
    draw.writeTextMax(surface, ctx, col, row, text_width, item.text, style);
    if (trailing_width > 0 and trailing_col < width) {
        draw.writeText(surface, ctx, trailing_col, row, item.trailing, item.trailing_style orelse .{
            .fg = options.muted,
            .bg = options.background,
        });
    }
    if (item.selector != .none and item.selector_placement == .right and right_selector_width > 0) {
        const marker = if (item.selector == .on) "[*]" else "[ ]";
        draw.writeText(surface, ctx, width -| right_selector_width, row, marker, selectorStyle(item.selector, options));
    }
}

pub fn visibleWindow(cursor: usize, count: usize, max_rows: usize) Window {
    if (count == 0 or max_rows == 0) return .{ .start = 0, .len = 0 };
    const len = @min(count, max_rows);
    const start = if (cursor >= len) cursor - len + 1 else 0;
    return .{ .start = start, .len = len };
}

fn moveCursorBy(cursor: *usize, count: usize, delta: isize) bool {
    if (count == 0) {
        cursor.* = 0;
        return false;
    }
    const old = @min(cursor.*, count - 1);
    const next = if (delta < 0)
        old -| @as(usize, @intCast(-delta))
    else
        @min(count - 1, old + @as(usize, @intCast(delta)));
    cursor.* = next;
    return next != old;
}

fn itemStyle(item: Item, options: Options) vaxis.Style {
    if (item.style) |style| return normalizeStyle(style, options.background);
    if (item.cursor) return .{
        .fg = options.text,
        .bg = options.background,
        .bold = true,
    };
    return .{
        .fg = if (item.active) options.text else options.text_soft,
        .bg = options.background,
    };
}

fn selectorStyle(selector: Selector, options: Options) vaxis.Style {
    return .{
        .fg = if (selector == .on) options.text_soft else options.muted,
        .bg = options.background,
    };
}

fn normalizeStyle(style: vaxis.Style, background: vaxis.Color) vaxis.Style {
    var out = style;
    if (out.bg == .default) out.bg = background;
    return out;
}

fn writeCursorMarker(surface: *vxfw.Surface, col: u16, row: u16, options: Options) void {
    if (col >= surface.size.width or row >= surface.size.height) return;
    surface.writeCell(col, row, .{
        .char = .{ .grapheme = "\xe2\x96\x8c", .width = 1 },
        .style = .{ .fg = options.cursor, .bg = options.background },
    });
}

test "visibleWindow keeps cursor visible" {
    try std.testing.expectEqualDeep(Window{ .start = 0, .len = 3 }, visibleWindow(1, 5, 3));
    try std.testing.expectEqualDeep(Window{ .start = 2, .len = 3 }, visibleWindow(4, 5, 3));
}

const FakeTree = struct {
    leaves: []const ?usize,
    depths: []const u8 = &.{},
    paths: []const []const u8 = &.{},
    orig: []const usize = &.{},

    fn rowCount(self: *const FakeTree) usize {
        return self.leaves.len;
    }

    fn leafIndexAt(self: *const FakeTree, row: usize) ?usize {
        if (row >= self.leaves.len) return null;
        return self.leaves[row];
    }

    fn dirPathAt(self: *const FakeTree, row: usize) ?[]const u8 {
        if (row >= self.leaves.len or self.leaves[row] != null) return null;
        if (row < self.paths.len and std.mem.endsWith(u8, self.paths[row], "/")) return self.paths[row];
        return "dir/";
    }

    fn depthAt(self: *const FakeTree, row: usize) u8 {
        if (row < self.depths.len) return self.depths[row];
        return if (row == 0) 0 else 1;
    }

    fn leafCountUnderDir(self: *const FakeTree, prefix: []const u8) usize {
        var count: usize = 0;
        for (self.paths) |path| {
            if (std.mem.endsWith(u8, path, "/")) continue;
            if (std.mem.startsWith(u8, path, prefix)) count += 1;
        }
        return count;
    }

    fn leafIndexUnderDirAt(self: *const FakeTree, prefix: []const u8, offset: usize) ?usize {
        var seen: usize = 0;
        for (self.paths, 0..) |path, idx| {
            if (std.mem.endsWith(u8, path, "/")) continue;
            if (!std.mem.startsWith(u8, path, prefix)) continue;
            if (seen == offset) {
                if (idx < self.orig.len) return self.orig[idx];
                return self.leafIndexAt(idx);
            }
            seen += 1;
        }
        return null;
    }
};

test "Machine keeps active leaf when cursor rests on a directory" {
    const leaves = [_]?usize{ null, 10, null, 20 };
    const tree = FakeTree{ .leaves = leaves[0..] };
    var machine: Machine = .{ .cursor = 1 };

    machine.sync(&tree);
    try std.testing.expectEqual(@as(?usize, 10), machine.active_leaf);

    machine.cursor = 2;
    machine.sync(&tree);
    try std.testing.expectEqual(@as(?usize, 10), machine.active_leaf);
}

test "Machine falls back when active leaf is filtered out" {
    const initial_leaves = [_]?usize{ null, 10, 20 };
    const initial_tree = FakeTree{ .leaves = initial_leaves[0..] };
    var machine: Machine = .{ .cursor = 2 };
    machine.sync(&initial_tree);
    try std.testing.expectEqual(@as(?usize, 20), machine.active_leaf);

    const filtered_leaves = [_]?usize{ null, 30 };
    const filtered_tree = FakeTree{ .leaves = filtered_leaves[0..] };
    machine.cursor = 1;
    machine.sync(&filtered_tree);
    try std.testing.expectEqual(@as(?usize, 30), machine.active_leaf);
}

test "Machine preserves active leaf when directory collapse hides it" {
    const expanded_leaves = [_]?usize{ null, 10, 20 };
    const expanded_tree = FakeTree{ .leaves = expanded_leaves[0..] };
    var machine: Machine = .{ .cursor = 2 };

    machine.sync(&expanded_tree);
    try std.testing.expectEqual(@as(?usize, 20), machine.active_leaf);

    const collapsed_leaves = [_]?usize{null};
    const collapsed_tree = FakeTree{ .leaves = collapsed_leaves[0..] };
    machine.cursor = 0;
    machine.sync(&collapsed_tree);
    try std.testing.expectEqual(@as(?usize, 20), machine.active_leaf);
}

test "Machine toggles selector state for current leaf" {
    const leaves = [_]?usize{ null, 10 };
    const tree = FakeTree{ .leaves = leaves[0..] };
    var machine: Machine = .{ .cursor = 1 };
    defer machine.deinit(std.testing.allocator);

    try std.testing.expect(machine.toggleSelectedLeaf(std.testing.allocator, &tree));
    try std.testing.expectEqual(Selector.on, machine.selectorForLeaf(10));
    try std.testing.expect(machine.toggleSelectedLeaf(std.testing.allocator, &tree));
    try std.testing.expectEqual(Selector.off, machine.selectorForLeaf(10));
}

test "Machine toggles selector state for directory descendants" {
    const leaves = [_]?usize{ null, null, 10, 20, null, 30 };
    const depths = [_]u8{ 0, 1, 2, 2, 1, 2 };
    const paths = [_][]const u8{ "dir/", "dir/a/", "dir/a/one", "dir/a/two", "dir/b/", "dir/b/three" };
    const tree = FakeTree{ .leaves = leaves[0..], .depths = depths[0..], .paths = paths[0..] };
    var machine: Machine = .{ .cursor = 1 };
    defer machine.deinit(std.testing.allocator);

    try std.testing.expect(machine.toggleSelectedAtCursor(std.testing.allocator, &tree));
    try std.testing.expectEqual(Selector.on, machine.selectorForLeaf(10));
    try std.testing.expectEqual(Selector.on, machine.selectorForLeaf(20));
    try std.testing.expectEqual(Selector.off, machine.selectorForLeaf(30));
    try std.testing.expectEqual(Selector.on, machine.selectorForDirAt(&tree, 1));
    try std.testing.expectEqual(Selector.off, machine.selectorForDirAt(&tree, 0));

    try std.testing.expect(machine.toggleSelectedAtCursor(std.testing.allocator, &tree));
    try std.testing.expectEqual(Selector.off, machine.selectorForLeaf(10));
    try std.testing.expectEqual(Selector.off, machine.selectorForLeaf(20));
}

test "Machine toggles selector state for collapsed directory descendants" {
    const leaves = [_]?usize{ null, null };
    const depths = [_]u8{ 0, 1 };
    const paths = [_][]const u8{ "dir/", "dir/a/", "dir/a/one", "dir/a/two" };
    const orig = [_]usize{ 0, 0, 10, 20 };
    const tree = FakeTree{
        .leaves = leaves[0..],
        .depths = depths[0..],
        .paths = paths[0..],
        .orig = orig[0..],
    };
    var machine: Machine = .{ .cursor = 1 };
    defer machine.deinit(std.testing.allocator);

    try std.testing.expect(machine.toggleSelectedAtCursor(std.testing.allocator, &tree));
    try std.testing.expectEqual(Selector.on, machine.selectorForLeaf(10));
    try std.testing.expectEqual(Selector.on, machine.selectorForLeaf(20));
    try std.testing.expectEqual(Selector.on, machine.selectorForDirAt(&tree, 1));
}
