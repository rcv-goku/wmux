//! Moving tabs between panes and within a pane (ARCHITECTURE.md ADR-1.8
//! W0-A2 step 2). Moved out of Window.zig in W0-A2.

const apprt = @import("../../../../apprt.zig");
const Pane = @import("../Pane.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const Tab = @import("../Tab.zig");
const Window = @import("../../ui/Window.zig");
const arith = @import("../logic/arith.zig");

const tabArraysRemove = arith.tabArraysRemove;
const tabArraysSwap = arith.tabArraysSwap;

/// Break a tab out of a multi-tab Pane into a new Pane
/// that becomes a sibling leaf in the workspace split tree. No-op if the
/// container has only one tab. The pane's HWND/surface is NOT destroyed.
pub fn breakPane(self: *Window, pane: *Tab) void {
    const alloc = self.app.core_app.alloc;
    const loc = self.findLoc(pane) orelse return;
    const ws = loc.ws;
    const src_container = loc.container;
    const src_tab = loc.tab;

    if (src_container.tab_count <= 1) return;

    const src_handle = ws.findContainerHandle(src_container) orelse return;

    // Bump pane ref: removing from the source container will unref it.
    _ = pane.ref(alloc) catch return;

    // Remove the pane from the source container.
    tabArraysRemove(src_container.tabArrays(), src_container.tab_count, src_tab);
    src_container.tab_count -= 1;
    if (src_container.active_tab >= src_container.tab_count and src_container.tab_count > 0)
        src_container.active_tab = src_container.tab_count - 1;

    // Create a new Pane with the pane as its sole tab.
    const new_container = Pane.create(alloc) catch {
        pane.unref(alloc);
        return;
    };
    new_container.tabs[0] = pane;
    new_container.tab_count = 1;
    new_container.active_tab = 0;
    // Copy the source tab's title to the new container.
    const title_len = src_container.tab_title_lens[src_tab];
    @memcpy(new_container.tab_titles[0][0..title_len], src_container.tab_titles[src_tab][0..title_len]);
    new_container.tab_title_lens[0] = title_len;

    // Insert the new container into the workspace split tree as a sibling.
    var new_tree = SplitTree(Pane).init(alloc, new_container) catch {
        pane.unref(alloc);
        alloc.destroy(new_container);
        return;
    };
    const split_result = ws.split_tree.split(alloc, src_handle, .right, @as(f16, 0.5), &new_tree) catch {
        new_tree.deinit();
        pane.unref(alloc);
        return;
    };
    var old_tree = ws.split_tree;
    ws.split_tree = split_result;
    old_tree.deinit();

    // The pane is now owned by new_container; drop the extra ref.
    pane.unref(alloc);

    const ws_idx = self.workspaceIndex(ws);
    if (ws_idx == self.active_workspace) {
        ws.focused_container = new_container;
        self.layoutSplits();
        new_container.focus();
        self.updateTabBarVisibility();
    } else {
        self.invalidateSidebar();
    }
}

/// Move a pane (tab) within its container. `.new_tab` breaks it into a
/// new Pane; `.next_tab`/`.prev_tab` swap the tab position
/// within the same container (since splits are between Panes,
/// not within tabs, there is no cross-tab merge).
pub fn movePaneToTab(self: *Window, pane: *Tab, target_enum: apprt.action.MovePaneTarget) void {
    const loc = self.findLoc(pane) orelse return;
    const container = loc.container;
    const src_tab = loc.tab;

    switch (target_enum) {
        .new_tab => {
            self.breakPane(pane);
            return;
        },
        .next_tab => {
            if (src_tab + 1 < container.tab_count) {
                tabArraysSwap(container.tabArrays(), src_tab, src_tab + 1);
                container.active_tab = src_tab + 1;
            }
        },
        .prev_tab => {
            if (src_tab > 0) {
                tabArraysSwap(container.tabArrays(), src_tab, src_tab - 1);
                container.active_tab = src_tab - 1;
            }
        },
    }

    if (loc.ws == self.activeWorkspace()) {
        self.invalidateTabBar();
    }
    self.invalidateSidebar();
}
