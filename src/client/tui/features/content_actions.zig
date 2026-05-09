//! Shared content-row actions for master-detail TUI surfaces.
//!
//! Workspace and Artifact both expose editable content rows backed by the
//! same draft/cache model. Keeping their operation keys here prevents the
//! two tabs from drifting when actions such as pull or diff are added.

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const w = @import("../widgets.zig");

pub const Surface = enum {
    workspace,
    artifact,
};

const workspace_context_shortcuts = [_]w.Shortcut{
    .{ .key = "j/k", .label = "move/scroll" },
    .{ .key = "h/l", .label = "switch tab" },
    .{ .key = "n", .label = "new context" },
    .{ .key = "w", .label = "workspaces" },
    .{ .key = "y", .label = "copy id" },
    .{ .key = "e", .label = "edit" },
    .{ .key = "p", .label = "submit" },
    .{ .key = "u", .label = "pull" },
    .{ .key = "d", .label = "toggle diff" },
    .{ .key = "D", .label = "discard draft" },
    .{ .key = "?", .label = "help" },
};

const workspace_rule_shortcuts = [_]w.Shortcut{
    .{ .key = "j/k", .label = "move/scroll" },
    .{ .key = "h/l", .label = "switch tab" },
    .{ .key = "w", .label = "workspaces" },
    .{ .key = "y", .label = "copy id" },
    .{ .key = "e", .label = "edit" },
    .{ .key = "p", .label = "submit" },
    .{ .key = "u", .label = "pull" },
    .{ .key = "d", .label = "toggle diff" },
    .{ .key = "D", .label = "discard draft" },
    .{ .key = "?", .label = "help" },
};

const artifact_content_shortcuts = [_]w.Shortcut{
    .{ .key = "j/k", .label = "move/scroll" },
    .{ .key = "Space", .label = "select" },
    .{ .key = "Enter", .label = "open" },
    .{ .key = "h/l", .label = "switch tab" },
    .{ .key = "y", .label = "copy id" },
    .{ .key = "n", .label = "new rule" },
    .{ .key = "e", .label = "edit" },
    .{ .key = "p", .label = "submit" },
    .{ .key = "u", .label = "pull" },
    .{ .key = "d", .label = "toggle diff" },
    .{ .key = "D", .label = "discard" },
    .{ .key = "b", .label = "bundles" },
    .{ .key = "?", .label = "help" },
    .{ .key = "q", .label = "quit" },
};

pub fn workspaceShortcuts(is_context_tab: bool) []const w.Shortcut {
    return if (is_context_tab) &workspace_context_shortcuts else &workspace_rule_shortcuts;
}

pub fn artifactContentShortcuts() []const w.Shortcut {
    return &artifact_content_shortcuts;
}

pub fn resetHideDiff(self: anytype, surface: Surface) void {
    switch (surface) {
        .workspace => self.workspace.hide_diff = false,
        .artifact => self.review.hide_diff = false,
    }
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
        const target = self.selectedDraftTarget() orelse {
            resetHideDiff(self, surface);
            ctx.consumeAndRedraw();
            return true;
        };
        if (self.draftContentForView(target.category, target.path) == null) {
            resetHideDiff(self, surface);
            ctx.consumeAndRedraw();
            return true;
        }
        switch (surface) {
            .workspace => self.workspace.hide_diff = !self.workspace.hide_diff,
            .artifact => self.review.hide_diff = !self.review.hide_diff,
        }
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
            .artifact => self.pullSelectedArtifactContent(),
        }
        ctx.consumeAndRedraw();
        return true;
    }
    return false;
}
