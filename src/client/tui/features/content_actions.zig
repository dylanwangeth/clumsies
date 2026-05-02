//! Shared content-row actions for master-detail TUI surfaces.
//!
//! Workspace and Library both expose editable content rows backed by the
//! same draft/cache model. Keeping their operation keys here prevents the
//! two tabs from drifting when actions such as pull or diff are added.

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const w = @import("../widgets.zig");

pub const Surface = enum {
    workspace,
    library,
};

const workspace_context_shortcuts = [_]w.Shortcut{
    .{ .key = "j/k", .label = "move/scroll" },
    .{ .key = "h/l", .label = "switch tab" },
    .{ .key = "n", .label = "new context" },
    .{ .key = "c", .label = "create ws" },
    .{ .key = "w", .label = "workspaces" },
    .{ .key = "y", .label = "copy id" },
    .{ .key = "e", .label = "edit" },
    .{ .key = "p", .label = "submit" },
    .{ .key = "u", .label = "pull" },
    .{ .key = "d", .label = "toggle diff" },
    .{ .key = "D", .label = "discard draft" },
    .{ .key = "m", .label = "mark ready" },
    .{ .key = "?", .label = "help" },
};

const workspace_rule_shortcuts = [_]w.Shortcut{
    .{ .key = "j/k", .label = "move/scroll" },
    .{ .key = "h/l", .label = "switch tab" },
    .{ .key = "c", .label = "create ws" },
    .{ .key = "w", .label = "workspaces" },
    .{ .key = "y", .label = "copy id" },
    .{ .key = "e", .label = "edit" },
    .{ .key = "p", .label = "submit" },
    .{ .key = "u", .label = "pull" },
    .{ .key = "d", .label = "toggle diff" },
    .{ .key = "D", .label = "discard draft" },
    .{ .key = "m", .label = "mark ready" },
    .{ .key = "?", .label = "help" },
};

const library_content_shortcuts = [_]w.Shortcut{
    .{ .key = "j/k", .label = "move/scroll" },
    .{ .key = "Enter", .label = "open" },
    .{ .key = "h/l", .label = "switch tab" },
    .{ .key = "y", .label = "copy id" },
    .{ .key = "n", .label = "new rule" },
    .{ .key = "e", .label = "edit" },
    .{ .key = "p", .label = "submit" },
    .{ .key = "u", .label = "pull" },
    .{ .key = "d", .label = "toggle diff" },
    .{ .key = "D", .label = "discard" },
    .{ .key = "m", .label = "mark ready" },
    .{ .key = "b", .label = "bundle filter" },
    .{ .key = "?", .label = "help" },
    .{ .key = "q", .label = "quit" },
};

pub fn workspaceShortcuts(is_context_tab: bool) []const w.Shortcut {
    return if (is_context_tab) &workspace_context_shortcuts else &workspace_rule_shortcuts;
}

pub fn libraryContentShortcuts() []const w.Shortcut {
    return &library_content_shortcuts;
}

pub fn resetDiff(self: anytype, surface: Surface) void {
    switch (surface) {
        .workspace => self.workspace.show_diff = false,
        .library => self.review.show_diff = false,
    }
}

pub fn showDiff(self: anytype, surface: Surface) bool {
    return switch (surface) {
        .workspace => self.workspace.show_diff,
        .library => self.review.show_diff,
    };
}

pub fn handle(
    self: anytype,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
    surface: Surface,
) bool {
    if (key.matches('y', .{})) {
        if (!self.copySelectedContentId()) {
            self.notifyOp(.warning, "No id to copy.");
        }
        ctx.consumeAndRedraw();
        return true;
    }
    if (key.matches('e', .{})) {
        self.editSelectedDraft();
        ctx.consumeAndRedraw();
        return true;
    }
    if (key.matches('D', .{}) or key.matches('d', .{ .shift = true })) {
        self.requestDiscardSelectedDraft();
        ctx.consumeAndRedraw();
        return true;
    }
    if (key.matches('d', .{})) {
        if (showDiff(self, surface)) {
            resetDiff(self, surface);
            ctx.consumeAndRedraw();
            return true;
        }
        const target = self.selectedDraftTarget() orelse {
            self.notifyOp(.warning, "No draft diff available.");
            ctx.consumeAndRedraw();
            return true;
        };
        if (self.draftContentForView(target.category, target.path) == null) {
            self.notifyOp(.warning, "No draft diff available.");
            ctx.consumeAndRedraw();
            return true;
        }
        switch (surface) {
            .workspace => self.workspace.show_diff = true,
            .library => self.review.show_diff = true,
        }
        ctx.consumeAndRedraw();
        return true;
    }
    if (key.matches('m', .{})) {
        self.toggleSelectedDraftReady();
        ctx.consumeAndRedraw();
        return true;
    }
    if (key.matches('p', .{})) {
        self.openPrComposer();
        ctx.consumeAndRedraw();
        return true;
    }
    if (key.matches('u', .{})) {
        switch (surface) {
            .workspace => self.pullSelectedWorkspaceContent(),
            .library => self.pullSelectedLibraryContent(),
        }
        ctx.consumeAndRedraw();
        return true;
    }
    return false;
}
