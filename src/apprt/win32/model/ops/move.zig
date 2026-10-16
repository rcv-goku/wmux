//! Moving tabs between panes and within a pane (ARCHITECTURE.md ADR-1.8
//! W0-A2 step 2). Moved out of Window.zig in W0-A2.

const std = @import("std");

const apprt = @import("../../../../apprt.zig");
const Pane = @import("../Pane.zig");
const SplitTree = @import("../../../../datastruct/split_tree.zig").SplitTree;
const Tab = @import("../Tab.zig");
const Window = @import("../../ui/Window.zig");
const model_registry = @import("../registry.zig");
const ops_surface = @import("surface.zig");

/// Break a tab out of a multi-tab Pane into a new Pane that becomes a
/// sibling leaf in the workspace split tree. No-op if the pane has only
/// one tab. The tab's HWND/surface is NOT destroyed.
pub fn breakPane(self: *Window, tab: *Tab) void {
    const alloc = self.app.core_app.alloc;
    const loc = self.findLoc(tab) orelse return;
    const ws = loc.ws;
    const src_container = loc.pane;
    const src_tab = loc.index;

    if (src_container.tabCount() <= 1) return;

    const src_handle = ws.paneHandle(src_container) orelse return;

    // Create the new Pane first so a failure leaves the source intact.
    const new_container = Pane.create(alloc) catch return;
    new_container.tabs.ensureTotalCapacity(alloc, 1) catch {
        alloc.destroy(new_container);
        return;
    };
    model_registry.register(&self.app.handles, alloc, new_container) catch {
        new_container.tabs.deinit(alloc);
        alloc.destroy(new_container);
        return;
    };

    // Move the tab (and the reference its pane owns) from the source pane
    // to the new one. The insert cannot fail: the capacity is reserved.
    _ = ops_surface.remove(src_container, src_tab);
    if (src_container.selected >= src_container.tabCount() and src_container.tabCount() > 0)
        src_container.selected = src_container.tabCount() - 1;
    ops_surface.insert(alloc, new_container, tab, 0) catch unreachable;
    new_container.selected = 0;
    new_container.workspace = ws;

    // Insert the new pane into the workspace split tree as a sibling.
    var new_tree = SplitTree(Pane).init(alloc, new_container) catch {
        undoBreak(alloc, src_container, src_tab, new_container, tab);
        return;
    };
    const split_result = ws.tree.split(alloc, src_handle, .right, @as(f16, 0.5), &new_tree) catch {
        // Take the pane back out of the throwaway tree before dropping it.
        _ = new_container.ref(alloc) catch unreachable;
        new_tree.deinit();
        undoBreak(alloc, src_container, src_tab, new_container, tab);
        return;
    };
    new_tree.deinit();
    var old_tree = ws.tree;
    ws.tree = split_result;
    ws.syncZoomed();
    old_tree.deinit();

    // The moved tab keeps its title; the legacy per-tab state (status
    // text, progress, log, bell/exited dot, attention, synchronized input)
    // starts fresh, as the new pane's default-initialized slot did before
    // W0-A2. Other feature state stays with the tab.
    tab.ext.status = .{};
    tab.ext.notifications = .{};
    tab.ext.sync_input = .{};

    const ws_idx = self.workspaceIndex(ws);
    if (ws_idx == self.activeIndex()) {
        ws.focused_pane = new_container;
        self.layoutSplits();
        new_container.focus();
        self.updateTabBarVisibility();
    } else {
        self.invalidateSidebar();
    }
}

/// Put `tab` back at `index` of `src` after a failed break and free the
/// unused new pane.
fn undoBreak(alloc: std.mem.Allocator, src: *Pane, index: usize, new_pane: *Pane, tab: *Tab) void {
    _ = ops_surface.remove(new_pane, 0);
    model_registry.unregister(new_pane);
    new_pane.tabs.deinit(alloc);
    alloc.destroy(new_pane);
    // Cannot fail: the source list kept the capacity of the removed tab.
    ops_surface.insert(alloc, src, tab, index) catch unreachable;
}

/// Move a tab within its pane. `.new_tab` breaks it into a new Pane;
/// `.next_tab`/`.prev_tab` swap the tab position within the same pane
/// (since splits are between Panes, not within tabs, there is no
/// cross-tab merge).
pub fn movePaneToTab(self: *Window, tab: *Tab, target_enum: apprt.action.MovePaneTarget) void {
    const loc = self.findLoc(tab) orelse return;
    const container = loc.pane;
    const src_tab = loc.index;

    switch (target_enum) {
        .new_tab => {
            self.breakPane(tab);
            return;
        },
        .next_tab => {
            if (src_tab + 1 < container.tabCount()) {
                std.mem.swap(*Tab, &container.tabs.items[src_tab], &container.tabs.items[src_tab + 1]);
                container.selected = src_tab + 1;
            }
        },
        .prev_tab => {
            if (src_tab > 0) {
                std.mem.swap(*Tab, &container.tabs.items[src_tab], &container.tabs.items[src_tab - 1]);
                container.selected = src_tab - 1;
            }
        },
    }

    if (loc.ws == self.activeWorkspace()) {
        self.invalidateTabBar();
    }
    self.invalidateSidebar();
}
