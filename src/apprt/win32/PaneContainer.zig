//! A PaneContainer is a per-pane tab container that lives as a leaf in
//! the workspace-level SplitTree. It owns a set of tabs (each a single
//! Pane) and implements the SplitTree view protocol (ref/unref/eql —
//! see the doc comment in src/datastruct/split_tree.zig). Splits create
//! new PaneContainers; tabs live within a single PaneContainer.
const PaneContainer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pane = @import("Pane.zig");
const Window = @import("Window.zig");
const ipc = @import("ipc.zig");
const w32 = @import("win32.zig");

const MAX_TABS = Window.MAX_TABS;
const MAX_STATUS_BYTES = Window.MAX_STATUS_BYTES;
const TabStatus = Window.TabStatus;

/// Reference count for SplitTree ownership. Starts at 0 because
/// SplitTree.init() calls ref() to take initial ownership.
ref_count: u32 = 0,

/// Number of live tabs in this container.
tab_count: usize = 0,

/// Index of the currently visible tab.
active_tab: usize = 0,

/// Each tab is a single Pane (terminal or browser). No per-tab split
/// tree — in the new model, splits are between PaneContainers.
tabs: [MAX_TABS]*Pane = undefined,

/// UTF-16 title buffers for each tab (for painting the tab bar).
tab_titles: [MAX_TABS][256]u16 = undefined,

/// Length of each tab title in UTF-16 code units.
tab_title_lens: [MAX_TABS]u16 = undefined,

/// Per-tab sidebar status. Cleared to .normal when the tab is selected.
tab_status: [MAX_TABS]TabStatus = [_]TabStatus{.normal} ** MAX_TABS,

/// Per-tab "needs attention" flag (the notification ring).
tab_attention: [MAX_TABS]bool = @splat(false),

/// Per-tab orchestration status string (set-status).
tab_status_text: [MAX_TABS][MAX_STATUS_BYTES]u8 = undefined,
tab_status_text_len: [MAX_TABS]u16 = @splat(0),

/// Per-tab progress percent (set-progress), 0..100, or null for none.
tab_progress: [MAX_TABS]?u8 = @splat(null),

/// Per-tab ring log buffer (log).
tab_log: [MAX_TABS]ipc.LogRing = @splat(.{}),

/// Per-tab synchronized input flag.
tab_synchronized: [MAX_TABS]bool = @splat(false),

// -------------------------------------------------------------------------
// Construction / destruction
// -------------------------------------------------------------------------

/// Heap-allocate a PaneContainer with default-initialized fields.
pub fn create(alloc: Allocator) Allocator.Error!*PaneContainer {
    const pc = try alloc.create(PaneContainer);
    pc.* = .{};
    return pc;
}

// -------------------------------------------------------------------------
// SplitTree view protocol
// -------------------------------------------------------------------------

/// Increment reference count, return self.
pub fn ref(self: *PaneContainer, alloc: Allocator) Allocator.Error!*PaneContainer {
    _ = alloc;
    self.ref_count += 1;
    return self;
}

/// Decrement reference count. At zero, unref all owned panes and free.
pub fn unref(self: *PaneContainer, alloc: Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        for (self.tabs[0..self.tab_count]) |pane| {
            pane.unref(alloc);
        }
        alloc.destroy(self);
    }
}

/// Identity comparison.
pub fn eql(self: *const PaneContainer, other: *const PaneContainer) bool {
    return self == other;
}

// -------------------------------------------------------------------------
// Accessors
// -------------------------------------------------------------------------

/// The active tab's pane HWND, or null if empty.
pub fn activePaneHwnd(self: *const PaneContainer) ?w32.HWND {
    if (self.tab_count == 0) return null;
    return self.tabs[self.active_tab].hwnd();
}

/// The active tab's Pane, or null if empty.
pub fn activePane(self: *PaneContainer) ?*Pane {
    if (self.tab_count == 0) return null;
    return self.tabs[self.active_tab];
}

/// The parallel per-tab arrays as a tuple of array pointers, compatible
/// with the tabArraysInsertGap/tabArraysRemove/tabArraysSwap helpers
/// in Window.zig.
pub fn tabArrays(self: *PaneContainer) struct {
    *[MAX_TABS]*Pane,
    *[MAX_TABS][256]u16,
    *[MAX_TABS]u16,
    *[MAX_TABS]TabStatus,
    *[MAX_TABS]bool,
    *[MAX_TABS][MAX_STATUS_BYTES]u8,
    *[MAX_TABS]u16,
    *[MAX_TABS]?u8,
    *[MAX_TABS]ipc.LogRing,
    *[MAX_TABS]bool,
} {
    return .{
        &self.tabs,
        &self.tab_titles,
        &self.tab_title_lens,
        &self.tab_status,
        &self.tab_attention,
        &self.tab_status_text,
        &self.tab_status_text_len,
        &self.tab_progress,
        &self.tab_log,
        &self.tab_synchronized,
    };
}

/// The worst status across this container's tabs: exited > bell > normal.
pub fn aggregateStatus(self: *const PaneContainer) TabStatus {
    var worst: TabStatus = .normal;
    for (self.tab_status[0..self.tab_count]) |s| {
        switch (s) {
            .exited => return .exited,
            .bell => worst = .bell,
            .normal => {},
        }
    }
    return worst;
}

/// Whether any tab in this container is flagged for attention.
pub fn hasAttention(self: *const PaneContainer) bool {
    for (self.tab_attention[0..self.tab_count]) |f| {
        if (f) return true;
    }
    return false;
}

/// Give keyboard focus to the active tab's pane.
pub fn focus(self: *const PaneContainer) void {
    if (self.tab_count > 0) self.tabs[self.active_tab].focus();
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "unit: PaneContainer create returns default state" {
    const pc = try PaneContainer.create(testing.allocator);
    defer testing.allocator.destroy(pc);
    try testing.expectEqual(@as(u32, 0), pc.ref_count);
    try testing.expectEqual(@as(usize, 0), pc.tab_count);
    try testing.expectEqual(@as(usize, 0), pc.active_tab);
}

test "unit: PaneContainer ref counts up and returns self" {
    var pc: PaneContainer = .{};
    try testing.expectEqual(@as(u32, 0), pc.ref_count);
    const p = try pc.ref(testing.allocator);
    try testing.expectEqual(&pc, p);
    try testing.expectEqual(@as(u32, 1), pc.ref_count);
    _ = try pc.ref(testing.allocator);
    try testing.expectEqual(@as(u32, 2), pc.ref_count);
}

test "unit: PaneContainer eql is identity" {
    var a: PaneContainer = .{};
    var b: PaneContainer = .{};
    try testing.expect(a.eql(&a));
    try testing.expect(!a.eql(&b));
}

test "unit: PaneContainer aggregateStatus returns worst" {
    var pc: PaneContainer = .{};
    pc.tab_count = 3;
    pc.tab_status[0] = .normal;
    pc.tab_status[1] = .normal;
    pc.tab_status[2] = .normal;
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());

    pc.tab_status[1] = .bell;
    try testing.expectEqual(TabStatus.bell, pc.aggregateStatus());

    pc.tab_status[2] = .exited;
    try testing.expectEqual(TabStatus.exited, pc.aggregateStatus());
}

test "unit: PaneContainer aggregateStatus empty is normal" {
    var pc: PaneContainer = .{};
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());
}

test "unit: PaneContainer hasAttention" {
    var pc: PaneContainer = .{};
    pc.tab_count = 2;
    try testing.expect(!pc.hasAttention());

    pc.tab_attention[1] = true;
    try testing.expect(pc.hasAttention());
}

test "unit: PaneContainer activePane null when empty" {
    var pc: PaneContainer = .{};
    try testing.expectEqual(@as(?*Pane, null), pc.activePane());
    try testing.expectEqual(@as(?w32.HWND, null), pc.activePaneHwnd());
}

test "unit: PaneContainer activePane returns active tab" {
    var pane_a: Pane = .{ .content = .{ .terminal = undefined } };
    var pane_b: Pane = .{ .content = .{ .terminal = undefined } };
    var pc: PaneContainer = .{};
    pc.tabs[0] = &pane_a;
    pc.tabs[1] = &pane_b;
    pc.tab_count = 2;
    pc.active_tab = 0;
    try testing.expectEqual(&pane_a, pc.activePane().?);

    pc.active_tab = 1;
    try testing.expectEqual(&pane_b, pc.activePane().?);
}

test "unit: PaneContainer focus is noop when empty" {
    var pc: PaneContainer = .{};
    pc.focus();
}
