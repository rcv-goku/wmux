//! Context menus (ARCHITECTURE.md ADR-1.6, ADR-1.8 W0-A2 step 4). Every
//! popup menu is built by `MenuBuilder` from `MenuItem`s that the owning
//! layer contributes for a `MenuSite`:
//!
//! - `tab`, `tab_bar_blank`: ui/tabbar/menu.zig
//! - `workspace_row`: ui/sidebar/menu.zig
//! - `sidebar_gear`, `default_shell`: settings/menu.zig
//! - `new_button` (the backend picker): ui/backend_picker.zig
//! - `terminal`: Surface.zig
//!
//! A command id is 1 + the item's index in the per-invocation table (no
//! reserved id ranges). The targets an item acts on (workspace, pane, tab,
//! surface) are captured in a `Context` before the modal TrackPopupMenuEx
//! loop and re-resolved by address after it; an item whose target vanished
//! meanwhile does nothing. W0-A3 captures them as handles/UUIDs instead and
//! replaces the contributor list with ui/contrib.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../App.zig");
const Pane = @import("../model/Pane.zig");
const Surface = @import("../Surface.zig");
const Tab = @import("../model/Tab.zig");
const Window = @import("Window.zig");
const Workspace = @import("../model/Workspace.zig");
const internal_os = @import("../../../os/main.zig");
const w32 = @import("../platform/win32.zig");

const backend_picker = @import("backend_picker.zig");
const settings_menu = @import("../settings/menu.zig");
const sidebar_menu = @import("sidebar/menu.zig");
const tabbar_menu = @import("tabbar/menu.zig");

const log = std.log.scoped(.win32);

pub const BackendTarget = backend_picker.BackendTarget;

/// Where a menu opens (ADR-1.6). `default_shell` is the second popup of
/// the gear menu's "Set default shell...".
pub const MenuSite = enum {
    terminal,
    tab,
    tab_bar_blank,
    workspace_row,
    sidebar_blank,
    sidebar_gear,
    new_button,
    main,
    notification_row,
    browser_page,
    right_sidebar_mode_bar,
    pane_buttons,
    default_shell,
};

/// What a menu acts on, captured when the menu opens and re-resolved
/// after its modal loop (see `resolve`).
pub const Context = struct {
    app: *App,
    window: *Window,
    /// The click point in window client coordinates (follow-up popups
    /// anchor there).
    client_x: i32 = 0,
    client_y: i32 = 0,
    workspace: ?*Workspace = null,
    pane: ?*Pane = null,
    tab: ?*Tab = null,
    surface: ?*Surface = null,
    /// `new_button`: where the picked backend opens.
    backend_target: BackendTarget = .new_tab,
    /// The WSL distributions the pickers list, enumerated when the menu
    /// opened and owned by the caller for the menu's lifetime.
    distros: []const internal_os.wsl.Distro = &.{},

    /// The index of `tab` in `pane`, if both are set and still linked.
    pub fn tabIndex(self: *const Context) ?usize {
        const pane = self.pane orelse return null;
        const tab = self.tab orelse return null;
        return pane.indexOf(tab);
    }

    /// Re-resolve the captured targets after the modal menu loop, which
    /// dispatched arbitrary messages: the window may be gone or closing,
    /// and tabs, panes and workspaces may have closed or moved. Every
    /// pointer is checked by address before it is dereferenced; a target
    /// that moved is re-located (the tab's pane and workspace follow it).
    /// False when any captured target no longer exists.
    pub fn resolve(self: *Context) bool {
        if (!windowAlive(self.app, self.window)) return false;
        const w = self.window;
        if (w.closing) return false;
        if (self.surface) |s| {
            const loc = w.findLocOfSurface(s) orelse return false;
            if (!s.core_surface_ready) return false;
            self.workspace = loc.ws;
            self.pane = loc.pane;
            self.tab = loc.pane.tabs.items[loc.index];
        } else if (self.tab) |t| {
            const loc = w.findLoc(t) orelse return false;
            self.workspace = loc.ws;
            self.pane = loc.pane;
        }
        if (self.workspace) |ws| {
            if (w.workspaceIndex(ws) >= w.workspaces.items.len) return false;
            if (self.pane) |p| {
                if (ws.paneHandle(p) == null) return false;
            }
        } else if (self.pane != null) return false;
        return true;
    }
};

/// Whether `w` is still one of the app's windows (checked by address,
/// without dereferencing it).
fn windowAlive(app: *App, w: *Window) bool {
    for (app.windows.items) |x| {
        if (x == w) return true;
    }
    if (app.quick_terminal) |qt| {
        if (qt.window == w) return true;
    }
    return false;
}

pub const Callback = *const fn (ctx: *Context, arg: usize) void;
pub const Predicate = *const fn (ctx: *const Context) bool;

/// One contributed menu item (ADR-1.6 `ui.MenuItem`). Items show in
/// `group` order with a separator between groups, then in `order` within
/// a group.
pub const MenuItem = struct {
    site: MenuSite,
    group: u8 = 0,
    order: u16 = 0,
    /// UTF-8 label; a tab separates a right-aligned accelerator hint.
    title: []const u8,
    /// Builds the label into `buf` instead of `title` (e.g. to append the
    /// configured keybinding).
    label: ?*const fn (ctx: *const Context, buf: []u8) []const u8 = null,
    callback: Callback,
    /// `arg` passed to `callback` (lets one callback serve several items).
    arg: usize = 0,
    /// Listed only when true (null: always).
    when: ?Predicate = null,
    /// Grayed out unless true (null: always enabled).
    enabled: ?Predicate = null,
    /// Checked when true (null: never).
    checked: ?Predicate = null,
};

/// One row of a menu being built: a contributed item evaluated against the
/// context, or a dynamic entry (a WSL distro).
pub const Entry = struct {
    group: u8 = 0,
    order: u16 = 0,
    title: []const u8,
    callback: Callback,
    arg: usize = 0,
    enabled: bool = true,
    checked: bool = false,
};

pub const MenuBuilder = struct {
    site: MenuSite,
    ctx: *Context,
    /// Owns the labels and the entry table for one menu invocation.
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator, site: MenuSite, ctx: *Context) MenuBuilder {
        return .{ .site = site, .ctx = ctx, .arena = .init(gpa) };
    }

    pub fn deinit(self: *MenuBuilder) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *MenuBuilder) Allocator {
        return self.arena.allocator();
    }

    /// Add `item` if it belongs to this menu's site and its `when` holds,
    /// evaluating its label and state against the context now (before the
    /// modal loop).
    pub fn addItem(self: *MenuBuilder, item: *const MenuItem) Allocator.Error!void {
        if (item.site != self.site) return;
        if (item.when) |when| if (!when(self.ctx)) return;
        const title = if (item.label) |label| title: {
            var buf: [128]u8 = undefined;
            break :title try self.allocator().dupe(u8, label(self.ctx, &buf));
        } else item.title;
        try self.addEntry(.{
            .group = item.group,
            .order = item.order,
            .title = title,
            .callback = item.callback,
            .arg = item.arg,
            .enabled = if (item.enabled) |enabled| enabled(self.ctx) else true,
            .checked = if (item.checked) |checked| checked(self.ctx) else false,
        });
    }

    /// Add every item of `items` that belongs to this site.
    pub fn addItems(self: *MenuBuilder, items: []const MenuItem) Allocator.Error!void {
        for (items) |*item| try self.addItem(item);
    }

    /// Add a dynamic entry (its title must outlive the builder or be
    /// allocated with `allocator()`).
    pub fn addEntry(self: *MenuBuilder, entry: Entry) Allocator.Error!void {
        try self.entries.append(self.allocator(), entry);
    }

    /// Put the entries in display order: by group, then by order; ties
    /// keep their contribution order. Command id = 1 + the index after
    /// this.
    pub fn sort(self: *MenuBuilder) void {
        std.sort.insertion(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                if (a.group != b.group) return a.group < b.group;
                return a.order < b.order;
            }
        }.lessThan);
    }

    /// Whether a separator goes before display row `index` (a group
    /// boundary). Call after `sort`.
    pub fn separatorBefore(self: *const MenuBuilder, index: usize) bool {
        return index > 0 and self.entries.items[index - 1].group != self.entries.items[index].group;
    }

    /// The entry a TrackPopupMenuEx result selects: 0 (dismissed) and ids
    /// outside the table select nothing, as do grayed entries.
    pub fn commandEntry(self: *const MenuBuilder, cmd: usize) ?Entry {
        if (cmd == 0 or cmd > self.entries.items.len) return null;
        const entry = self.entries.items[cmd - 1];
        if (!entry.enabled) return null;
        return entry;
    }

    /// Build the popup, run its modal loop at `screen` (inside an
    /// app.modal bracket) and return the chosen entry.
    pub fn track(self: *MenuBuilder, owner: w32.HWND, screen: w32.POINT) ?Entry {
        if (self.entries.items.len == 0) return null;
        self.sort();
        const menu = w32.CreatePopupMenu() orelse return null;
        defer _ = w32.DestroyMenu(menu);
        for (self.entries.items, 0..) |entry, i| {
            if (self.separatorBefore(i)) _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
            const title_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator(), entry.title) catch continue;
            var flags: u32 = if (entry.enabled) w32.MF_STRING else w32.MF_GRAYED;
            if (entry.checked) flags |= w32.MF_CHECKED;
            _ = w32.AppendMenuW(menu, flags, i + 1, title_w.ptr);
        }

        const app = self.ctx.app;
        app.modal.enter();
        defer app.modal.leave();
        const cmd = w32.TrackPopupMenuEx(
            menu,
            w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
            screen.x,
            screen.y,
            owner,
            null,
        );
        return self.commandEntry(@intCast(@max(cmd, 0)));
    }
};

/// The layers contributing menu items: each declares `menu_items` and may
/// declare `menuEntries(*MenuBuilder)` for dynamic entries.
const contributors = .{
    tabbar_menu,
    sidebar_menu,
    settings_menu,
    backend_picker,
    Surface,
};

/// Collect the contributions of `sources` for the builder's site.
pub fn collectFrom(b: *MenuBuilder, comptime sources: anytype) Allocator.Error!void {
    inline for (sources) |source| {
        if (@hasDecl(source, "menu_items")) try b.addItems(&source.menu_items);
        if (@hasDecl(source, "menuEntries")) try source.menuEntries(b);
    }
}

/// Show the `site` menu for `ctx` at `screen`, owned by `owner`, and run
/// the chosen item once its targets re-resolve.
pub fn show(site: MenuSite, ctx: *Context, owner: w32.HWND, screen: w32.POINT) void {
    var b = MenuBuilder.init(ctx.app.core_app.alloc, site, ctx);
    defer b.deinit();
    collectFrom(&b, contributors) catch |err| {
        log.err("failed to build the {s} menu: {}", .{ @tagName(site), err });
        return;
    };
    const chosen = b.track(owner, screen) orelse return;
    if (!ctx.resolve()) return;
    chosen.callback(ctx, chosen.arg);
}

/// `show` anchored at window client coordinates (x, y).
fn showAt(self: *Window, site: MenuSite, ctx: *Context, x: i32, y: i32) void {
    const hwnd = self.hwnd orelse return;
    var pt = w32.POINT{ .x = x, .y = y };
    _ = w32.ClientToScreen(hwnd, &pt);
    show(site, ctx, hwnd, pt);
}

// ---------------------------------------------------------------------------
// Menu sites of the window chrome
// ---------------------------------------------------------------------------

/// Show the tab context menu at client coordinates (x, y): the `tab` menu
/// for the clicked tab of the active workspace's focused pane (the tab bar
/// focuses the clicked pane first), or the `tab_bar_blank` menu when the
/// click was not on a tab.
pub fn showTabContextMenu(self: *Window, clicked_tab: ?usize, x: i32, y: i32) void {
    if (self.closing) return;
    var ctx: Context = .{
        .app = self.app,
        .window = self,
        .client_x = x,
        .client_y = y,
    };
    // Only the `tab` menu has targets (the clicked tab and its pane);
    // the blank strip's New Tab acts on whatever pane is active.
    var site: MenuSite = .tab_bar_blank;
    if (clicked_tab) |i| {
        const ws = self.activeWorkspace();
        if (ws.focusedPaneOrFirst()) |pane| {
            if (pane.tabAt(i)) |tab| {
                ctx.workspace = ws;
                ctx.pane = pane;
                ctx.tab = tab;
                site = .tab;
            }
        }
    }
    showAt(self, site, &ctx, x, y);
}

/// Show the workspace row menu for workspace `ws_idx` at client
/// coordinates (x, y).
pub fn showWorkspaceContextMenu(self: *Window, ws_idx: usize, x: i32, y: i32) void {
    if (self.closing or self.is_quick_terminal or ws_idx >= self.workspaces.items.len) return;
    var ctx: Context = .{
        .app = self.app,
        .window = self,
        .client_x = x,
        .client_y = y,
        .workspace = self.workspaces.items[ws_idx],
    };
    showAt(self, .workspace_row, &ctx, x, y);
}

/// Show the settings (gear) menu at client coordinates (x, y).
pub fn showGearContextMenu(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;
    var ctx: Context = .{ .app = self.app, .window = self, .client_x = x, .client_y = y };
    showAt(self, .sidebar_gear, &ctx, x, y);
}

/// Show the backend picker at client coordinates (x, y): the picked
/// backend opens as a new tab, as the first tab of a new workspace, or as
/// a split per `target` (ui/backend_picker.zig).
pub fn showBackendMenu(self: *Window, x: i32, y: i32, target: BackendTarget) void {
    // Quick terminals exclude picker-created tabs/splits entirely.
    // They have no tab bar or sidebar, so the only QT-reachable call
    // site is the surface "Split ... With..." menu (grayed there too).
    if (self.closing or self.is_quick_terminal) return;
    const alloc = self.app.core_app.alloc;
    // Enumerate installed distros at menu-open (a cheap registry read)
    // so new installs show up without restarting.
    const distros: []internal_os.wsl.Distro = internal_os.wsl.list(alloc) catch &.{};
    defer internal_os.wsl.free(alloc, distros);
    var ctx: Context = .{
        .app = self.app,
        .window = self,
        .client_x = x,
        .client_y = y,
        .backend_target = target,
        .distros = distros,
    };
    showAt(self, .new_button, &ctx, x, y);
}

/// Show the default-shell picker at client coordinates (x, y)
/// (settings/menu.zig).
pub fn showDefaultShellMenu(self: *Window, x: i32, y: i32) void {
    if (self.closing or self.is_quick_terminal) return;
    const alloc = self.app.core_app.alloc;
    const distros: []internal_os.wsl.Distro = internal_os.wsl.list(alloc) catch &.{};
    defer internal_os.wsl.free(alloc, distros);
    var ctx: Context = .{
        .app = self.app,
        .window = self,
        .client_x = x,
        .client_y = y,
        .distros = distros,
    };
    showAt(self, .default_shell, &ctx, x, y);
}

/// Show the terminal menu of `surface` at the screen point `screen`
/// (Surface.zig contributes the items).
pub fn showTerminalMenu(surface: *Surface, screen: w32.POINT) void {
    const window = surface.parent_window;
    if (window.closing) return;
    const hwnd = surface.hwnd orelse return;
    var client = screen;
    if (window.hwnd) |wh| _ = w32.ScreenToClient(wh, &client);
    var ctx: Context = .{
        .app = surface.app,
        .window = window,
        .client_x = client.x,
        .client_y = client.y,
        .surface = surface,
    };
    show(.terminal, &ctx, hwnd, screen);
}

// ---------------------------------------------------------------------------
// Shared helpers of the contributors
// ---------------------------------------------------------------------------

/// True if pwsh.exe (PowerShell 7+) is on the executable search path.
pub fn havePwsh() bool {
    var buf: [512]u16 = undefined;
    const n = w32.SearchPathW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe"),
        null,
        buf.len,
        &buf,
        null,
    );
    return n > 0 and n < buf.len;
}

/// Menu label for a WSL distro row: the name, with " (default)"
/// appended for the distro wsl.exe launches without -d. Allocated;
/// caller frees.
pub fn distroMenuLabel(
    alloc: Allocator,
    name: []const u8,
    is_default: bool,
) Allocator.Error![]const u8 {
    return if (is_default)
        std.fmt.allocPrint(alloc, "{s} (default)", .{name})
    else
        alloc.dupe(u8, name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testNoop(ctx: *Context, arg: usize) void {
    _ = ctx;
    _ = arg;
}

fn testNever(ctx: *const Context) bool {
    _ = ctx;
    return false;
}

fn testAlways(ctx: *const Context) bool {
    _ = ctx;
    return true;
}

fn testLabel(ctx: *const Context, buf: []u8) []const u8 {
    _ = ctx;
    return std.fmt.bufPrint(buf, "Close\t{s}", .{"Ctrl+W"}) catch "Close";
}

/// A context that no test dereferences (the builder only hands it to the
/// item predicates and labels).
fn testContext() Context {
    return .{ .app = undefined, .window = undefined };
}

test "unit: ui: menu builder numbers items 1 + index in display order" {
    var ctx = testContext();
    var b = MenuBuilder.init(testing.allocator, .tab, &ctx);
    defer b.deinit();
    const items = [_]MenuItem{
        .{ .site = .tab, .group = 1, .order = 0, .title = "New Tab", .callback = testNoop, .arg = 30 },
        .{ .site = .tab, .group = 0, .order = 2, .title = "Close Right", .callback = testNoop, .arg = 12 },
        .{ .site = .tab, .group = 0, .order = 0, .title = "Close", .callback = testNoop, .arg = 10 },
        .{ .site = .tab, .group = 0, .order = 1, .title = "Close Others", .callback = testNoop, .arg = 11 },
    };
    try b.addItems(&items);
    b.sort();
    const want = [_]usize{ 10, 11, 12, 30 };
    for (want, 1..) |arg, cmd| {
        try testing.expectEqual(arg, b.commandEntry(cmd).?.arg);
    }
    // One separator, between the close group and New Tab.
    try testing.expect(!b.separatorBefore(0));
    try testing.expect(!b.separatorBefore(1));
    try testing.expect(!b.separatorBefore(2));
    try testing.expect(b.separatorBefore(3));
}

test "unit: ui: menu builder keeps only the items of its site" {
    var ctx = testContext();
    var b = MenuBuilder.init(testing.allocator, .tab_bar_blank, &ctx);
    defer b.deinit();
    const items = [_]MenuItem{
        .{ .site = .tab, .title = "Close", .callback = testNoop },
        .{ .site = .tab_bar_blank, .title = "New Tab", .callback = testNoop, .arg = 7 },
        .{ .site = .workspace_row, .title = "Rename", .callback = testNoop },
    };
    try b.addItems(&items);
    try testing.expectEqual(@as(usize, 1), b.entries.items.len);
    try testing.expectEqual(@as(usize, 7), b.commandEntry(1).?.arg);
}

test "unit: ui: menu builder evaluates when, enabled, checked and label at build time" {
    var ctx = testContext();
    var b = MenuBuilder.init(testing.allocator, .terminal, &ctx);
    defer b.deinit();
    const items = [_]MenuItem{
        .{ .site = .terminal, .order = 0, .title = "Hidden", .callback = testNoop, .when = testNever },
        .{ .site = .terminal, .order = 1, .title = "Copy", .callback = testNoop, .enabled = testNever },
        .{ .site = .terminal, .order = 2, .title = "Sync", .callback = testNoop, .checked = testAlways },
        .{ .site = .terminal, .order = 3, .title = "Close", .label = testLabel, .callback = testNoop },
    };
    try b.addItems(&items);
    b.sort();
    try testing.expectEqual(@as(usize, 3), b.entries.items.len);
    try testing.expectEqualStrings("Copy", b.entries.items[0].title);
    try testing.expect(!b.entries.items[0].enabled);
    try testing.expect(b.entries.items[1].checked);
    try testing.expectEqualStrings("Close\tCtrl+W", b.entries.items[2].title);
}

test "unit: ui: menu builder maps dismissal, unknown and grayed commands to no item" {
    var ctx = testContext();
    var b = MenuBuilder.init(testing.allocator, .tab, &ctx);
    defer b.deinit();
    try b.addItem(&.{ .site = .tab, .title = "Close", .callback = testNoop });
    try b.addItem(&.{ .site = .tab, .order = 1, .title = "Grayed", .callback = testNoop, .enabled = testNever });
    b.sort();
    // TrackPopupMenuEx returns 0 when the menu is dismissed.
    try testing.expectEqual(@as(?Entry, null), b.commandEntry(0));
    try testing.expect(b.commandEntry(1) != null);
    try testing.expectEqual(@as(?Entry, null), b.commandEntry(2));
    try testing.expectEqual(@as(?Entry, null), b.commandEntry(3));
    try testing.expectEqual(@as(?Entry, null), b.commandEntry(9001));
}

test "unit: ui: menu builder dynamic entries sort with the contributed items" {
    var ctx = testContext();
    var b = MenuBuilder.init(testing.allocator, .new_button, &ctx);
    defer b.deinit();
    try b.addItem(&.{ .site = .new_button, .group = 2, .title = "Browser", .callback = testNoop, .arg = 99 });
    // 40 dynamic rows: no id range caps them any more.
    for (0..40) |i| {
        const title = try std.fmt.allocPrint(b.allocator(), "distro {d}", .{i});
        try b.addEntry(.{ .group = 1, .order = @intCast(i), .title = title, .callback = testNoop, .arg = i });
    }
    try b.addItem(&.{ .site = .new_button, .group = 0, .title = "Default", .callback = testNoop, .arg = 98 });
    b.sort();
    try testing.expectEqual(@as(usize, 42), b.entries.items.len);
    try testing.expectEqual(@as(usize, 98), b.commandEntry(1).?.arg);
    try testing.expectEqual(@as(usize, 0), b.commandEntry(2).?.arg);
    try testing.expectEqual(@as(usize, 39), b.commandEntry(41).?.arg);
    try testing.expectEqual(@as(usize, 99), b.commandEntry(42).?.arg);
    try testing.expect(b.separatorBefore(1));
    try testing.expect(b.separatorBefore(41));
}

test "unit: distro menu label formats the default marker" {
    const alloc = testing.allocator;
    {
        const label = try distroMenuLabel(alloc, "Ubuntu-24.04", false);
        defer alloc.free(label);
        try testing.expectEqualStrings("Ubuntu-24.04", label);
    }
    {
        const label = try distroMenuLabel(alloc, "Ubuntu-24.04", true);
        defer alloc.free(label);
        try testing.expectEqualStrings("Ubuntu-24.04 (default)", label);
    }
}
