//! The tab bar's context menu items (ARCHITECTURE.md ADR-1.6): the `tab`
//! site (right-click on a tab) and the `tab_bar_blank` site (the empty
//! strip). The targets are the clicked tab and its pane, captured when the
//! menu opened (ui/menus.zig Context) and re-resolved after it, so a
//! command always acts on the pane that was clicked.

const std = @import("std");

const menus = @import("../menus.zig");
const ops_surface = @import("../../model/ops/surface.zig");

const log = std.log.scoped(.win32);

const Context = menus.Context;

pub const menu_items = [_]menus.MenuItem{
    .{ .site = .tab, .group = 0, .order = 0, .title = "Close Tab", .callback = closeTab },
    .{ .site = .tab, .group = 0, .order = 1, .title = "Close Other Tabs", .callback = closeOtherTabs, .enabled = hasOtherTabs },
    .{ .site = .tab, .group = 0, .order = 2, .title = "Close Tabs to the Right", .callback = closeTabsToTheRight, .enabled = hasTabsToTheRight },
    .{ .site = .tab, .group = 1, .order = 0, .title = "New Tab", .callback = newTab },
    .{ .site = .tab_bar_blank, .group = 1, .order = 0, .title = "New Tab", .callback = newTab },
};

fn hasOtherTabs(ctx: *const Context) bool {
    const pane = ctx.pane orelse return false;
    return pane.tabCount() > 1;
}

fn hasTabsToTheRight(ctx: *const Context) bool {
    const pane = ctx.pane orelse return false;
    const index = ctx.tabIndex() orelse return false;
    return index + 1 < pane.tabCount();
}

fn closeTab(ctx: *Context, arg: usize) void {
    _ = arg;
    const index = ctx.tabIndex() orelse return;
    ops_surface.closeTabAt(ctx.window, ctx.workspace.?, ctx.pane.?, index);
}

/// Close every tab of the clicked tab's pane but the clicked one. The pane
/// never empties (the clicked tab survives).
fn closeOtherTabs(ctx: *Context, arg: usize) void {
    _ = arg;
    const pane = ctx.pane orelse return;
    const keep = ctx.tab orelse return;
    var i: usize = pane.tabCount();
    while (i > 0) {
        i -= 1;
        if (i >= pane.tabCount()) continue;
        if (pane.tabs.items[i] != keep) ops_surface.closeTabAt(ctx.window, ctx.workspace.?, pane, i);
    }
}

/// Close the tabs after the clicked tab in its pane.
fn closeTabsToTheRight(ctx: *Context, arg: usize) void {
    _ = arg;
    const pane = ctx.pane orelse return;
    const index = ctx.tabIndex() orelse return;
    while (pane.tabCount() > index + 1) {
        ops_surface.closeTabAt(ctx.window, ctx.workspace.?, pane, pane.tabCount() - 1);
    }
}

/// Plain New Tab inherits the active pane's backend, same as the tab bar
/// "+" button.
fn newTab(ctx: *Context, arg: usize) void {
    _ = arg;
    _ = ops_surface.addTabInherit(ctx.window) catch |err| {
        log.err("failed to create new tab: {}", .{err});
    };
}
