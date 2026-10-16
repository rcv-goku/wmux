//! UI contribution registry [frozen] (ARCHITECTURE.md ADR-1.4; written in
//! W0-A3). Aggregates, in manifest order, what features declare in their
//! `features/<id>/mod.zig`:
//!
//!     pub const menu_items = ...;           // []const ui.MenuItem        (ui/menus.zig)
//!     pub const palette_providers = ...;    // []const PaletteProvider    (ui/palette/provider.zig)
//!     pub const sidebar_rows = ...;         // []const RowContributor     (ui/sidebar/contrib.zig)
//!     pub const right_sidebar_modes = ...;  // []const RightSidebarMode   (ui/right_sidebar/mode.zig)
//!     pub const panel_kinds = ...;          // []const *const PanelKind   (web/PanelKind.zig)
//!     pub const window_hooks = ...;         // []const ui.WindowHook      (app/hooks.zig)
//!     pub const app_hooks = ...;            // []const app.AppHook        (app/hooks.zig)
//!
//! Menu items also come from the layers that own chrome menus (tab bar,
//! sidebar, settings, backend picker, terminal), listed before the
//! features. Comptime checks (`@compileError` naming the duplicate): no
//! two palette providers, row contributors, right-sidebar modes or panel
//! kinds share an id, and no two row contributors share a slot.
//!
//! Consumers: ui/menus.zig (menus), the palette (W2-7), the sidebar row
//! pipeline (W1-8), the right sidebar host (W1-8), the web panel framework
//! (W1-6), ui/Window.zig (window hooks), App.msgWndProc and the broadcast
//! window (app hooks).

const std = @import("std");

const PanelKind = @import("../web/PanelKind.zig").PanelKind;
const Surface = @import("../Surface.zig");
const backend_picker = @import("backend_picker.zig");
const hooks = @import("../app/hooks.zig");
const manifest = @import("../features/manifest.zig");
const menus = @import("menus.zig");
const palette_provider = @import("palette/provider.zig");
const right_sidebar_mode = @import("right_sidebar/mode.zig");
const settings_menu = @import("../settings/menu.zig");
const sidebar_contrib = @import("sidebar/contrib.zig");
const sidebar_menu = @import("sidebar/menu.zig");
const tabbar_menu = @import("tabbar/menu.zig");

pub const MenuItem = menus.MenuItem;
pub const PaletteProvider = palette_provider.PaletteProvider;
pub const RowContributor = sidebar_contrib.RowContributor;
pub const RightSidebarMode = right_sidebar_mode.RightSidebarMode;
pub const WindowHook = hooks.WindowHook;
pub const AppHook = hooks.AppHook;

/// Every menu contributor: the chrome layers, then every feature in
/// manifest order. Each may declare `menu_items` and a
/// `menuEntries(*MenuBuilder)` that adds dynamic rows (WSL distros).
pub const menu_sources = .{ tabbar_menu, sidebar_menu, settings_menu, backend_picker, Surface } ++ manifest.modules;

const menu_items_array = collect(MenuItem, menu_sources, "menu_items");
const palette_array = collect(PaletteProvider, manifest.modules, "palette_providers");
const rows_array = collect(RowContributor, manifest.modules, "sidebar_rows");
const modes_array = collect(RightSidebarMode, manifest.modules, "right_sidebar_modes");
const panels_array = collect(*const PanelKind, manifest.modules, "panel_kinds");
const window_hooks_array = collect(WindowHook, manifest.modules, "window_hooks");
const app_hooks_array = collect(AppHook, manifest.modules, "app_hooks");

// The lists and their checks are lazy declarations (no container-level
// comptime block): evaluating a list analyzes every function its entries
// point at, which a test binary must never do for the real features (their
// handlers reach the terminal teardown graph and with it the GTK apprt).

/// Every contributed menu item, in `menu_sources` order.
pub const menu_items: []const MenuItem = &menu_items_array;

pub const palette_providers: []const PaletteProvider = blk: {
    if (firstDuplicateId(PaletteProvider, &palette_array)) |dup|
        @compileError("ui/contrib.zig: duplicate palette provider id '" ++ dup ++ "'");
    break :blk &palette_array;
};

pub const sidebar_rows: []const RowContributor = blk: {
    if (firstDuplicateId(RowContributor, &rows_array)) |dup|
        @compileError("ui/contrib.zig: duplicate sidebar row contributor id '" ++ dup ++ "'");
    if (firstDuplicateSlot(&rows_array)) |dup|
        @compileError("ui/contrib.zig: two sidebar row contributors claim slot '" ++ dup ++ "'");
    break :blk &rows_array;
};

pub const right_sidebar_modes: []const RightSidebarMode = blk: {
    if (firstDuplicateId(RightSidebarMode, &modes_array)) |dup|
        @compileError("ui/contrib.zig: duplicate right sidebar mode id '" ++ dup ++ "'");
    break :blk &modes_array;
};

pub const panel_kinds: []const *const PanelKind = blk: {
    if (firstDuplicatePanel(&panels_array)) |dup|
        @compileError("ui/contrib.zig: duplicate panel kind id '" ++ dup ++ "'");
    break :blk &panels_array;
};

/// Top-level window message hooks, dispatched by ui/Window.zig.
pub const window_hooks: []const WindowHook = &window_hooks_array;

/// App message hooks (msg_hwnd and the broadcast window).
pub const app_hooks: []const AppHook = &app_hooks_array;

/// Add every contributed item of the builder's site, then the dynamic
/// rows of the contributors that declare `menuEntries`, in
/// `menu_sources` order.
pub fn collectMenu(b: *menus.MenuBuilder) std.mem.Allocator.Error!void {
    try b.addItems(menu_items);
    inline for (menu_sources) |source| {
        if (@hasDecl(source, "menuEntries")) try source.menuEntries(b);
    }
}

// ---------------------------------------------------------------------------
// Comptime helpers
// ---------------------------------------------------------------------------

/// A source's `decl` table as a slice (an array, the usual `[_]T{...}`, or
/// a slice).
fn tableOf(comptime T: type, comptime m: type, comptime decl: []const u8) []const T {
    const value = @field(m, decl);
    return switch (@typeInfo(@TypeOf(value))) {
        .array => &value,
        else => value,
    };
}

fn countDecl(comptime T: type, comptime sources: anytype, comptime decl: []const u8) usize {
    var n: usize = 0;
    inline for (sources) |m| {
        if (@hasDecl(m, decl)) n += tableOf(T, m, decl).len;
    }
    return n;
}

/// The `decl` tables of `sources`, concatenated in order.
fn collect(comptime T: type, comptime sources: anytype, comptime decl: []const u8) [countDecl(T, sources, decl)]T {
    @setEvalBranchQuota(1_000_000);
    var out: [countDecl(T, sources, decl)]T = undefined;
    var i: usize = 0;
    inline for (sources) |m| {
        if (@hasDecl(m, decl)) {
            for (tableOf(T, m, decl)) |entry| {
                out[i] = entry;
                i += 1;
            }
        }
    }
    return out;
}

fn firstDuplicateId(comptime T: type, comptime entries: []const T) ?[]const u8 {
    for (entries, 0..) |a, i| {
        for (entries[0..i]) |b| {
            if (std.mem.eql(u8, a.id, b.id)) return a.id;
        }
    }
    return null;
}

fn firstDuplicatePanel(comptime kinds: []const *const PanelKind) ?[]const u8 {
    for (kinds, 0..) |a, i| {
        for (kinds[0..i]) |b| {
            if (std.mem.eql(u8, a.id, b.id)) return a.id;
        }
    }
    return null;
}

fn firstDuplicateSlot(comptime rows: []const RowContributor) ?[]const u8 {
    for (rows, 0..) |a, i| {
        for (rows[0..i]) |b| {
            if (a.slot == b.slot) return @tagName(a.slot);
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestRows = struct {
    fn build(b: *sidebar_contrib.RowBuilder, ws: *const @import("../model/Workspace.zig"), ctx: *const sidebar_contrib.RowContext) void {
        _ = b;
        _ = ws;
        _ = ctx;
    }
};

const TestHooks = struct {
    fn onMsg(app: *@import("../App.zig"), wparam: usize, lparam: isize) ?isize {
        _ = app;
        _ = lparam;
        return @intCast(wparam);
    }
};

const SrcA = struct {
    pub const app_hooks = [_]AppHook{.{ .msg = 1, .handler = TestHooks.onMsg }};
    pub const sidebar_rows = [_]RowContributor{.{ .id = "a.progress", .slot = .progress, .build = TestRows.build }};
};
const SrcB = struct {};
const SrcC = struct {
    pub const app_hooks: []const AppHook = &.{
        .{ .msg = 2, .handler = TestHooks.onMsg },
        .{ .msg = 1, .handler = TestHooks.onMsg },
    };
    pub const sidebar_rows = [_]RowContributor{.{ .id = "c.ports", .slot = .ports, .build = TestRows.build }};
};

test "unit: ui: contrib collects declared tables in source order" {
    const hooks_list = comptime collect(AppHook, .{ SrcA, SrcB, SrcC }, "app_hooks");
    try testing.expectEqual(@as(usize, 3), hooks_list.len);
    try testing.expectEqual(@as(u32, 1), hooks_list[0].msg);
    try testing.expectEqual(@as(u32, 2), hooks_list[1].msg);
    try testing.expectEqual(@as(u32, 1), hooks_list[2].msg);
    // Dispatch over a collected list: the first claim for msg 1 wins.
    try testing.expectEqual(@as(?isize, 7), hooks.dispatchApp(&hooks_list, undefined, 1, 7, 0));
    try testing.expectEqual(@as(?isize, null), hooks.dispatchApp(&hooks_list, undefined, 3, 7, 0));
    const none = comptime collect(AppHook, .{SrcB}, "app_hooks");
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "unit: ui: contrib detects duplicate ids and slots" {
    comptime {
        const rows = collect(RowContributor, .{ SrcA, SrcC }, "sidebar_rows");
        if (firstDuplicateId(RowContributor, &rows) != null) @compileError("distinct ids flagged");
        if (firstDuplicateSlot(&rows) != null) @compileError("distinct slots flagged");
        const twice = collect(RowContributor, .{ SrcA, SrcA }, "sidebar_rows");
        const dup = firstDuplicateId(RowContributor, &twice) orelse @compileError("duplicate id missed");
        if (!std.mem.eql(u8, dup, "a.progress")) @compileError("wrong duplicate id");
        const slot = firstDuplicateSlot(&twice) orelse @compileError("duplicate slot missed");
        if (!std.mem.eql(u8, slot, "progress")) @compileError("wrong duplicate slot");
    }
}

test "unit: ui: contrib entry types are declarable by a feature" {
    const Fns = struct {
        fn collectPalette(ctx: *palette_provider.Context) anyerror!void {
            _ = ctx;
        }
        fn createMode(window: *@import("Window.zig")) anyerror!right_sidebar_mode.Content {
            _ = window;
            return .legacy_strip;
        }
        fn onWindowMsg(window: *@import("Window.zig"), wparam: usize, lparam: isize) ?isize {
            _ = window;
            _ = wparam;
            _ = lparam;
            return null;
        }
    };
    const kind: PanelKind = .{ .id = "about", .app = "about", .title = PanelKind.noTitle, .allow = &.{"panel.*"}, .create = PanelKind.noCreate };
    const Feature = struct {
        pub const palette_providers = [_]PaletteProvider{.{ .id = "workspaces", .collect = Fns.collectPalette }};
        pub const sidebar_rows = [_]RowContributor{.{ .id = "status.progress", .slot = .progress, .build = TestRows.build }};
        pub const right_sidebar_modes = [_]RightSidebarMode{.{ .id = "wmux.status", .title = "Status", .create = Fns.createMode }};
        pub const panel_kinds = [_]*const PanelKind{&kind};
        pub const window_hooks = [_]WindowHook{.{ .msg = 0x02E0, .handler = Fns.onWindowMsg }};
    };
    const sources = .{Feature};
    try testing.expectEqual(@as(usize, 1), comptime collect(PaletteProvider, sources, "palette_providers").len);
    try testing.expectEqual(@as(usize, 1), comptime collect(RowContributor, sources, "sidebar_rows").len);
    try testing.expectEqualStrings("wmux.status", (comptime collect(RightSidebarMode, sources, "right_sidebar_modes"))[0].id);
    try testing.expectEqualStrings("about", (comptime collect(*const PanelKind, sources, "panel_kinds"))[0].id);
    try testing.expectEqual(@as(u32, 0x02E0), (comptime collect(WindowHook, sources, "window_hooks"))[0].msg);
}
