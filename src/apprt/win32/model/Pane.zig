//! A Pane is a leaf of the workspace split tree (a cmux "pane"): a tab
//! container with its own tab bar (ARCHITECTURE.md §0.2, ADR-2.3). It owns
//! an ordered list of heap Tabs (one reference each) and implements the
//! SplitTree view protocol (ref/unref/eql, see the doc comment in
//! src/datastruct/split_tree.zig). Splits create new Panes; tabs live
//! within a single Pane. Formerly `PaneContainer` (renamed in W0-A2,
//! ADR-1.8), which kept up to 64 tabs in parallel per-tab arrays; there is
//! no tab cap any more (G7).
const Pane = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Tab = @import("Tab.zig");
const Workspace = @import("Workspace.zig");
const features_ext = @import("../features/ext.zig");
const w32 = @import("../platform/win32.zig");

const TabStatus = Tab.TabStatus;

/// Reference count for SplitTree ownership. Starts at 0 because
/// SplitTree.init() calls ref() to take initial ownership.
ref_count: u32 = 0,

/// The workspace whose split tree holds this pane (null for a pane that
/// is not in a tree yet, and in the fake model graphs of the tests).
workspace: ?*Workspace = null,

/// The tabs, in tab bar order. Each holds one reference owned by this
/// pane.
tabs: std.ArrayList(*Tab) = .empty,

/// Index of the visible (selected) tab.
selected: usize = 0,

/// Full layout rect assigned by layoutSplits (includes tab bar area).
/// Used for painting per-pane tab bars and, through the shared tab bar
/// geometry (ui/tabbar/logic/geometry.zig), for hit-testing them.
layout_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Per-pane feature state (ADR-1.3).
ext: features_ext.PaneExt = .{},

// -------------------------------------------------------------------------
// Per-pane tab bar hover state (split mode only; owned by ui/tabbar)
// -------------------------------------------------------------------------

/// Index of the tab being hovered in this pane's tab bar (null = none).
hovered_tab_idx: ?usize = null,

/// Index of the tab whose close button is being hovered (null = none).
hovered_close_idx: ?usize = null,

/// Whether the "+" new-tab button in this pane's tab bar is hovered.
hovered_new_tab: bool = false,

/// Whether the "▾" dropdown button in this pane's tab bar is hovered.
hovered_dropdown: bool = false,

// -------------------------------------------------------------------------
// Construction / destruction
// -------------------------------------------------------------------------

/// Heap-allocate a Pane with default-initialized fields.
pub fn create(alloc: Allocator) Allocator.Error!*Pane {
    const pane = try alloc.create(Pane);
    pane.* = .{};
    return pane;
}

// -------------------------------------------------------------------------
// SplitTree view protocol
// -------------------------------------------------------------------------

/// Increment reference count, return self.
pub fn ref(self: *Pane, alloc: Allocator) Allocator.Error!*Pane {
    _ = alloc;
    self.ref_count += 1;
    return self;
}

/// Decrement reference count. At zero, unref all owned tabs and free.
pub fn unref(self: *Pane, alloc: Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        for (self.tabs.items) |tab| {
            tab.pane = null;
            tab.unref(alloc);
        }
        self.tabs.deinit(alloc);
        alloc.destroy(self);
    }
}

/// Identity comparison.
pub fn eql(self: *const Pane, other: *const Pane) bool {
    return self == other;
}

// -------------------------------------------------------------------------
// Accessors
// -------------------------------------------------------------------------

/// Number of tabs.
pub fn tabCount(self: *const Pane) usize {
    return self.tabs.items.len;
}

/// The selected tab's content HWND, or null if empty.
pub fn selectedHwnd(self: *const Pane) ?w32.HWND {
    const tab = self.selectedTab() orelse return null;
    return tab.hwnd();
}

/// The selected Tab, or null if empty.
pub fn selectedTab(self: *const Pane) ?*Tab {
    if (self.selected >= self.tabs.items.len) return null;
    return self.tabs.items[self.selected];
}

/// The tab at `index`, or null when out of range.
pub fn tabAt(self: *const Pane, index: usize) ?*Tab {
    if (index >= self.tabs.items.len) return null;
    return self.tabs.items[index];
}

/// The position of `tab` in this pane, or null when it is not here.
pub fn indexOf(self: *const Pane, tab: *const Tab) ?usize {
    for (self.tabs.items, 0..) |t, i| {
        if (t == tab) return i;
    }
    return null;
}

/// The worst status across this pane's tabs: exited > bell > normal.
pub fn aggregateStatus(self: *const Pane) TabStatus {
    var worst: TabStatus = .normal;
    for (self.tabs.items) |tab| {
        switch (tab.legacy.status) {
            .exited => return .exited,
            .bell => worst = .bell,
            .normal => {},
        }
    }
    return worst;
}

/// Whether any tab in this pane is flagged for attention.
pub fn hasAttention(self: *const Pane) bool {
    for (self.tabs.items) |tab| {
        if (tab.legacy.attention) return true;
    }
    return false;
}

/// Give keyboard focus to the selected tab's content.
pub fn focus(self: *const Pane) void {
    if (self.selectedTab()) |tab| tab.focus();
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// A pane over caller-owned placeholder tabs (read-only: the list borrows
/// `ptrs`, so the test must not append to it or deinit it).
fn testPane(tabs: []Tab, ptrs: []*Tab) Pane {
    for (tabs, 0..) |*t, i| ptrs[i] = t;
    return .{ .tabs = .{ .items = ptrs[0..tabs.len], .capacity = tabs.len } };
}

fn placeholderTabs(comptime n: usize) [n]Tab {
    return @splat(.{ .content = .placeholder });
}

test "unit: Pane create returns default state" {
    const pane = try Pane.create(testing.allocator);
    defer testing.allocator.destroy(pane);
    try testing.expectEqual(@as(u32, 0), pane.ref_count);
    try testing.expectEqual(@as(usize, 0), pane.tabCount());
    try testing.expectEqual(@as(usize, 0), pane.selected);
    try testing.expectEqual(@as(?*Workspace, null), pane.workspace);
}

test "unit: Pane ref counts up and returns self" {
    var pane: Pane = .{};
    try testing.expectEqual(@as(u32, 0), pane.ref_count);
    const p = try pane.ref(testing.allocator);
    try testing.expectEqual(&pane, p);
    try testing.expectEqual(@as(u32, 1), pane.ref_count);
    _ = try pane.ref(testing.allocator);
    try testing.expectEqual(@as(u32, 2), pane.ref_count);
}

test "unit: Pane eql is identity" {
    var a: Pane = .{};
    var b: Pane = .{};
    try testing.expect(a.eql(&a));
    try testing.expect(!a.eql(&b));
}

test "unit: Pane aggregateStatus returns worst" {
    var tabs = placeholderTabs(3);
    var ptrs: [3]*Tab = undefined;
    const pane = testPane(&tabs, &ptrs);
    try testing.expectEqual(TabStatus.normal, pane.aggregateStatus());

    tabs[1].legacy.status = .bell;
    try testing.expectEqual(TabStatus.bell, pane.aggregateStatus());

    tabs[2].legacy.status = .exited;
    try testing.expectEqual(TabStatus.exited, pane.aggregateStatus());
}

test "unit: Pane aggregateStatus empty is normal" {
    const pane: Pane = .{};
    try testing.expectEqual(TabStatus.normal, pane.aggregateStatus());
}

test "unit: Pane aggregate status exited beats bell" {
    var tabs = placeholderTabs(4);
    var ptrs: [4]*Tab = undefined;
    const pane = testPane(&tabs, &ptrs);
    tabs[1].legacy.status = .bell;
    try testing.expectEqual(TabStatus.bell, pane.aggregateStatus());
    tabs[3].legacy.status = .exited;
    try testing.expectEqual(TabStatus.exited, pane.aggregateStatus());
    tabs[3].legacy.status = .normal;
    tabs[0].legacy.status = .exited;
    try testing.expectEqual(TabStatus.exited, pane.aggregateStatus());
}

test "unit: Pane aggregate status has no tab cap" {
    // 100 tabs: more than the former 64-slot MAX_TABS arrays held.
    var tabs = placeholderTabs(100);
    var ptrs: [100]*Tab = undefined;
    const pane = testPane(&tabs, &ptrs);
    try testing.expectEqual(TabStatus.normal, pane.aggregateStatus());
    tabs[99].legacy.status = .bell;
    try testing.expectEqual(TabStatus.bell, pane.aggregateStatus());
    tabs[64].legacy.status = .exited;
    try testing.expectEqual(TabStatus.exited, pane.aggregateStatus());
}

test "unit: Pane hasAttention" {
    var tabs = placeholderTabs(2);
    var ptrs: [2]*Tab = undefined;
    const pane = testPane(&tabs, &ptrs);
    try testing.expect(!pane.hasAttention());
    tabs[1].legacy.attention = true;
    try testing.expect(pane.hasAttention());
    tabs[1].legacy.attention = false;
    try testing.expect(!pane.hasAttention());
}

test "unit: Pane attention is orthogonal to bell/exited status" {
    var tabs = placeholderTabs(3);
    var ptrs: [3]*Tab = undefined;
    const pane = testPane(&tabs, &ptrs);
    tabs[0].legacy.status = .exited;
    tabs[2].legacy.attention = true;
    try testing.expectEqual(TabStatus.exited, pane.aggregateStatus());
    try testing.expect(pane.hasAttention());
    tabs[2].legacy.attention = false;
    try testing.expectEqual(TabStatus.exited, pane.aggregateStatus());
    try testing.expect(!pane.hasAttention());
}

test "unit: Pane progress and log store and clear per tab" {
    var tabs = placeholderTabs(2);

    try testing.expectEqual(@as(?u8, null), tabs[0].legacy.progress);
    try testing.expect(tabs[0].legacy.log.latest() == null);

    tabs[1].legacy.progress = 42;
    try testing.expectEqual(@as(?u8, 42), tabs[1].legacy.progress);
    tabs[1].legacy.progress = 100;
    try testing.expectEqual(@as(?u8, 100), tabs[1].legacy.progress);
    tabs[1].legacy.progress = null;
    try testing.expectEqual(@as(?u8, null), tabs[1].legacy.progress);

    tabs[0].legacy.log.push("line one");
    tabs[0].legacy.log.push("line two");
    try testing.expectEqualStrings("line two", tabs[0].legacy.log.latest().?);
    try testing.expectEqualStrings("line one", tabs[0].legacy.log.at(1).?);
    try testing.expect(tabs[1].legacy.log.latest() == null);
}

test "unit: Pane activePane null when empty" {
    const pane: Pane = .{};
    try testing.expectEqual(@as(?*Tab, null), pane.selectedTab());
    try testing.expectEqual(@as(?w32.HWND, null), pane.selectedHwnd());
}

test "unit: Pane activePane returns active tab" {
    var tabs = placeholderTabs(2);
    var ptrs: [2]*Tab = undefined;
    var pane = testPane(&tabs, &ptrs);
    pane.selected = 0;
    try testing.expectEqual(&tabs[0], pane.selectedTab().?);
    pane.selected = 1;
    try testing.expectEqual(&tabs[1], pane.selectedTab().?);
    // An out-of-range selection reads as no tab instead of past the list.
    pane.selected = 2;
    try testing.expectEqual(@as(?*Tab, null), pane.selectedTab());
}

test "unit: Pane indexOf and tabAt agree" {
    var tabs = placeholderTabs(3);
    var ptrs: [3]*Tab = undefined;
    const pane = testPane(&tabs, &ptrs);
    for (0..3) |i| {
        try testing.expectEqual(@as(?usize, i), pane.indexOf(&tabs[i]));
        try testing.expectEqual(&tabs[i], pane.tabAt(i).?);
    }
    var stranger: Tab = .{ .content = .placeholder };
    try testing.expectEqual(@as(?usize, null), pane.indexOf(&stranger));
    try testing.expectEqual(@as(?*Tab, null), pane.tabAt(3));
}

test "unit: Pane focus is noop when empty" {
    const pane: Pane = .{};
    pane.focus();
}

test "unit: Pane default hover state is cleared" {
    const pane: Pane = .{};
    try testing.expectEqual(@as(?usize, null), pane.hovered_tab_idx);
    try testing.expectEqual(@as(?usize, null), pane.hovered_close_idx);
    try testing.expect(!pane.hovered_new_tab);
    try testing.expect(!pane.hovered_dropdown);
}

test "unit: Pane default layout rect is zeroed" {
    const pane: Pane = .{};
    try testing.expectEqual(@as(i32, 0), pane.layout_rect.left);
    try testing.expectEqual(@as(i32, 0), pane.layout_rect.right);
}

test "unit: Pane hover state is independently settable" {
    var pane: Pane = .{};
    pane.hovered_tab_idx = 2;
    pane.hovered_close_idx = 1;
    pane.hovered_new_tab = true;
    pane.hovered_dropdown = true;

    try testing.expectEqual(@as(?usize, 2), pane.hovered_tab_idx);
    try testing.expectEqual(@as(?usize, 1), pane.hovered_close_idx);
    try testing.expect(pane.hovered_new_tab);
    try testing.expect(pane.hovered_dropdown);

    // Clear hover state (as clearAllContainerHover would).
    pane.hovered_tab_idx = null;
    pane.hovered_close_idx = null;
    pane.hovered_new_tab = false;
    pane.hovered_dropdown = false;

    try testing.expectEqual(@as(?usize, null), pane.hovered_tab_idx);
    try testing.expectEqual(@as(?usize, null), pane.hovered_close_idx);
    try testing.expect(!pane.hovered_new_tab);
    try testing.expect(!pane.hovered_dropdown);
}

test "unit: Pane tab bar visibility rule" {
    // A split pane paints its own bar only with 2+ tabs (layoutNode,
    // invalidateTabBar and the tab bar geometry all test tabCount() > 1).
    var tabs = placeholderTabs(5);
    var ptrs: [5]*Tab = undefined;
    for ([_]usize{ 0, 1, 2, 5 }) |n| {
        const pane = testPane(tabs[0..n], ptrs[0..n]);
        try testing.expectEqual(n > 1, pane.tabCount() > 1);
    }
}

test "unit: Pane aggregate status of an empty container is normal" {
    var tabs = placeholderTabs(1);
    tabs[0].legacy.status = .exited;
    var ptrs = [_]*Tab{&tabs[0]};
    // Spare list capacity holding a stale tab pointer is not a tab.
    const pane: Pane = .{ .tabs = .{ .items = ptrs[0..0], .capacity = 1 } };
    try testing.expectEqual(TabStatus.normal, pane.aggregateStatus());
}

test "unit: Pane aggregate status all-normal stays normal" {
    var tabs = placeholderTabs(3);
    var ptrs: [3]*Tab = undefined;
    const pane = testPane(&tabs, &ptrs);
    try testing.expectEqual(TabStatus.normal, pane.aggregateStatus());
}

test "unit: Pane hasAttention ignores slots past tab_count" {
    var tabs = placeholderTabs(2);
    var ptrs = [_]*Tab{ &tabs[0], &tabs[1] };
    tabs[1].legacy.attention = true;
    // Only the list's items are tabs; the second pointer is spare capacity.
    var pane: Pane = .{ .tabs = .{ .items = ptrs[0..1], .capacity = 2 } };
    try testing.expect(!pane.hasAttention());
    pane.tabs.items = ptrs[0..2];
    try testing.expect(pane.hasAttention());
}

test "unit: Pane aggregate status slot visibility at the count boundaries" {
    // 64 tabs, the former MAX_TABS: the last tab counts exactly while it
    // is inside the list.
    const n = 64;
    var tabs = placeholderTabs(n);
    var ptrs: [n]*Tab = undefined;
    var pane = testPane(&tabs, &ptrs);
    tabs[n - 1].legacy.status = .exited;
    try testing.expectEqual(TabStatus.exited, pane.aggregateStatus());
    pane.tabs.items = ptrs[0 .. n - 1];
    try testing.expectEqual(TabStatus.normal, pane.aggregateStatus());
    tabs[n - 1].legacy.status = .bell;
    pane.tabs.items = ptrs[0..n];
    try testing.expectEqual(TabStatus.bell, pane.aggregateStatus());
    pane.tabs.items = ptrs[0..0];
    try testing.expectEqual(TabStatus.normal, pane.aggregateStatus());
}

test "unit: Pane layout_rect stores assigned position" {
    // Simulate layoutSplits assigning rects to panes in a side-by-side split.
    var left: Pane = .{};
    left.layout_rect = .{ .left = 0, .top = 0, .right = 400, .bottom = 300 };
    try testing.expectEqual(@as(i32, 0), left.layout_rect.left);
    try testing.expectEqual(@as(i32, 0), left.layout_rect.top);
    try testing.expectEqual(@as(i32, 400), left.layout_rect.right);
    try testing.expectEqual(@as(i32, 300), left.layout_rect.bottom);

    var right: Pane = .{};
    right.layout_rect = .{ .left = 400, .top = 0, .right = 800, .bottom = 300 };
    try testing.expectEqual(@as(i32, 400), right.layout_rect.left);
    try testing.expectEqual(@as(i32, 800), right.layout_rect.right);

    // Non-overlapping: left.right <= right.left.
    try testing.expect(left.layout_rect.right <= right.layout_rect.left);
}
