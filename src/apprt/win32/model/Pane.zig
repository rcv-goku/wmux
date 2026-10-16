//! A Pane is a leaf of the workspace split tree (a cmux "pane"): a tab
//! container with its own tab bar. It owns a set of tabs (each a Tab)
//! and implements the SplitTree view protocol (ref/unref/eql —
//! see the doc comment in src/datastruct/split_tree.zig). Splits create
//! new Panes; tabs live within a single Pane. Formerly `PaneContainer`
//! (renamed in W0-A2, ARCHITECTURE.md ADR-1.8).
const Pane = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Tab = @import("Tab.zig");
const arith = @import("logic/arith.zig");
const log_ring = @import("../features/status/log_ring.zig");
const w32 = @import("../platform/win32.zig");

const TabStatus = Tab.TabStatus;

/// Maximum bytes of a per-tab status string (set-status). Inline, like
/// tab titles, so set-status never allocates; over-long text is byte
/// truncated by the setter.
pub const MAX_STATUS_BYTES: usize = 96;

/// Maximum number of tabs per workspace.
pub const MAX_TABS: usize = 64;

/// Reference count for SplitTree ownership. Starts at 0 because
/// SplitTree.init() calls ref() to take initial ownership.
ref_count: u32 = 0,

/// Number of live tabs in this container.
tab_count: usize = 0,

/// Index of the currently visible tab.
active_tab: usize = 0,

/// Each tab is a single Tab (terminal or browser). No per-tab split
/// tree — in the new model, splits are between Panes.
tabs: [MAX_TABS]*Tab = undefined,

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
tab_log: [MAX_TABS]log_ring.LogRing = @splat(.{}),

/// Per-tab synchronized input flag.
tab_synchronized: [MAX_TABS]bool = @splat(false),

// -------------------------------------------------------------------------
// Per-pane tab bar hit-test state
// -------------------------------------------------------------------------

/// Hit-test rectangles for each tab (in window client coords).
tab_rects: [MAX_TABS]w32.RECT = std.mem.zeroes([MAX_TABS]w32.RECT),

/// Number of valid entries in tab_rects (mirrors tab_count at paint time).
tab_rect_count: usize = 0,

/// Hit-test rectangle for the per-pane "+" (new tab) button.
new_tab_btn_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Hit-test rectangle for the per-pane "▾" (backend picker) button.
new_tab_dropdown_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Per-tab close button hit-test rectangles (in window client coords).
close_btn_rects: [MAX_TABS]w32.RECT = std.mem.zeroes([MAX_TABS]w32.RECT),

/// Full layout rect assigned by layoutSplits (includes tab bar area).
/// Used for painting per-pane tab bars and hit-testing in split mode.
layout_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

// -------------------------------------------------------------------------
// Per-pane tab bar hover state (split mode only)
// -------------------------------------------------------------------------

/// Index of the tab being hovered in this container's tab bar (null = none).
hovered_tab_idx: ?usize = null,

/// Index of the tab whose close button is being hovered (null = none).
hovered_close_idx: ?usize = null,

/// Whether the "+" new-tab button in this container's tab bar is hovered.
hovered_new_tab: bool = false,

/// Whether the "▾" dropdown button in this container's tab bar is hovered.
hovered_dropdown: bool = false,

// -------------------------------------------------------------------------
// Construction / destruction
// -------------------------------------------------------------------------

/// Heap-allocate a Pane with default-initialized fields.
pub fn create(alloc: Allocator) Allocator.Error!*Pane {
    const pc = try alloc.create(Pane);
    pc.* = .{};
    return pc;
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
        for (self.tabs[0..self.tab_count]) |tab| {
            tab.unref(alloc);
        }
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

/// The active tab's content HWND, or null if empty.
pub fn activeTabHwnd(self: *const Pane) ?w32.HWND {
    if (self.tab_count == 0) return null;
    return self.tabs[self.active_tab].hwnd();
}

/// The active Tab, or null if empty.
pub fn activeTab(self: *Pane) ?*Tab {
    if (self.tab_count == 0) return null;
    return self.tabs[self.active_tab];
}

/// The parallel per-tab arrays as a tuple of array pointers, compatible
/// with the tabArraysInsertGap/tabArraysRemove/tabArraysSwap helpers
/// in model/logic/arith.zig.
pub fn tabArrays(self: *Pane) struct {
    *[MAX_TABS]*Tab,
    *[MAX_TABS][256]u16,
    *[MAX_TABS]u16,
    *[MAX_TABS]TabStatus,
    *[MAX_TABS]bool,
    *[MAX_TABS][MAX_STATUS_BYTES]u8,
    *[MAX_TABS]u16,
    *[MAX_TABS]?u8,
    *[MAX_TABS]log_ring.LogRing,
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
pub fn aggregateStatus(self: *const Pane) TabStatus {
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
pub fn hasAttention(self: *const Pane) bool {
    for (self.tab_attention[0..self.tab_count]) |f| {
        if (f) return true;
    }
    return false;
}

/// Give keyboard focus to the active tab's content.
pub fn focus(self: *const Pane) void {
    if (self.tab_count > 0) self.tabs[self.active_tab].focus();
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "unit: Pane create returns default state" {
    const pc = try Pane.create(testing.allocator);
    defer testing.allocator.destroy(pc);
    try testing.expectEqual(@as(u32, 0), pc.ref_count);
    try testing.expectEqual(@as(usize, 0), pc.tab_count);
    try testing.expectEqual(@as(usize, 0), pc.active_tab);
}

test "unit: Pane ref counts up and returns self" {
    var pc: Pane = .{};
    try testing.expectEqual(@as(u32, 0), pc.ref_count);
    const p = try pc.ref(testing.allocator);
    try testing.expectEqual(&pc, p);
    try testing.expectEqual(@as(u32, 1), pc.ref_count);
    _ = try pc.ref(testing.allocator);
    try testing.expectEqual(@as(u32, 2), pc.ref_count);
}

test "unit: Pane eql is identity" {
    var a: Pane = .{};
    var b: Pane = .{};
    try testing.expect(a.eql(&a));
    try testing.expect(!a.eql(&b));
}

test "unit: Pane aggregateStatus returns worst" {
    var pc: Pane = .{};
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

test "unit: Pane aggregateStatus empty is normal" {
    var pc: Pane = .{};
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());
}

test "unit: Pane hasAttention" {
    var pc: Pane = .{};
    pc.tab_count = 2;
    try testing.expect(!pc.hasAttention());

    pc.tab_attention[1] = true;
    try testing.expect(pc.hasAttention());
}

test "unit: Pane activePane null when empty" {
    var pc: Pane = .{};
    try testing.expectEqual(@as(?*Tab, null), pc.activeTab());
    try testing.expectEqual(@as(?w32.HWND, null), pc.activeTabHwnd());
}

test "unit: Pane activePane returns active tab" {
    var pane_a: Tab = .{ .content = .{ .terminal = undefined } };
    var pane_b: Tab = .{ .content = .{ .terminal = undefined } };
    var pc: Pane = .{};
    pc.tabs[0] = &pane_a;
    pc.tabs[1] = &pane_b;
    pc.tab_count = 2;
    pc.active_tab = 0;
    try testing.expectEqual(&pane_a, pc.activeTab().?);

    pc.active_tab = 1;
    try testing.expectEqual(&pane_b, pc.activeTab().?);
}

test "unit: Pane focus is noop when empty" {
    var pc: Pane = .{};
    pc.focus();
}

test "unit: Pane default hover state is cleared" {
    const pc: Pane = .{};
    try testing.expectEqual(@as(?usize, null), pc.hovered_tab_idx);
    try testing.expectEqual(@as(?usize, null), pc.hovered_close_idx);
    try testing.expect(!pc.hovered_new_tab);
    try testing.expect(!pc.hovered_dropdown);
}

test "unit: Pane default hit-test rects are zeroed" {
    const pc: Pane = .{};
    try testing.expectEqual(@as(usize, 0), pc.tab_rect_count);
    try testing.expectEqual(@as(i32, 0), pc.new_tab_btn_rect.left);
    try testing.expectEqual(@as(i32, 0), pc.new_tab_btn_rect.right);
    try testing.expectEqual(@as(i32, 0), pc.new_tab_dropdown_rect.left);
    try testing.expectEqual(@as(i32, 0), pc.new_tab_dropdown_rect.right);
    try testing.expectEqual(@as(i32, 0), pc.layout_rect.left);
    try testing.expectEqual(@as(i32, 0), pc.layout_rect.right);
}

test "unit: Pane hover state is independently settable" {
    var pc: Pane = .{};
    pc.hovered_tab_idx = 2;
    pc.hovered_close_idx = 1;
    pc.hovered_new_tab = true;
    pc.hovered_dropdown = true;

    try testing.expectEqual(@as(?usize, 2), pc.hovered_tab_idx);
    try testing.expectEqual(@as(?usize, 1), pc.hovered_close_idx);
    try testing.expect(pc.hovered_new_tab);
    try testing.expect(pc.hovered_dropdown);

    // Clear hover state (as clearAllContainerHover would).
    pc.hovered_tab_idx = null;
    pc.hovered_close_idx = null;
    pc.hovered_new_tab = false;
    pc.hovered_dropdown = false;

    try testing.expectEqual(@as(?usize, null), pc.hovered_tab_idx);
    try testing.expectEqual(@as(?usize, null), pc.hovered_close_idx);
    try testing.expect(!pc.hovered_new_tab);
    try testing.expect(!pc.hovered_dropdown);
}

test "unit: Pane layout_rect stores assigned position" {
    // Simulate layoutSplits assigning rects to containers in a side-by-side split.
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

test "unit: Pane tab bar visibility rule" {
    var pc: Pane = .{};

    // 0 tabs: no bar (both forced and unforced)
    pc.tab_count = 0;
    try testing.expect(pc.tab_count <= 1);

    // 1 tab: no bar unless forced
    pc.tab_count = 1;
    try testing.expect(pc.tab_count <= 1);

    // 2+ tabs: bar shown regardless of force
    pc.tab_count = 2;
    try testing.expect(pc.tab_count > 1);

    pc.tab_count = 5;
    try testing.expect(pc.tab_count > 1);
}

test "unit: Pane aggregate status of an empty container is normal" {
    var pc: Pane = .{};
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());
    // Status slots past tab_count are ignored even when dirty.
    pc.tab_status[0] = .exited;
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());
}

test "unit: Pane aggregate status all-normal stays normal" {
    var pc: Pane = .{};
    pc.tab_count = 3;
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());
}

test "unit: Pane aggregate status exited beats bell" {
    var pc: Pane = .{};
    pc.tab_count = 4;
    pc.tab_status[1] = .bell;
    try testing.expectEqual(TabStatus.bell, pc.aggregateStatus());
    pc.tab_status[3] = .exited;
    try testing.expectEqual(TabStatus.exited, pc.aggregateStatus());
    pc.tab_status[3] = .normal;
    pc.tab_status[0] = .exited;
    try testing.expectEqual(TabStatus.exited, pc.aggregateStatus());
    pc.tab_status[0] = .normal;
    pc.tab_count = 1;
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());
}

test "unit: Pane hasAttention ignores slots past tab_count" {
    var pc: Pane = .{};
    pc.tab_attention[0] = true;
    try testing.expect(!pc.hasAttention());
    pc.tab_count = 1;
    try testing.expect(pc.hasAttention());
    pc.tab_attention[0] = false;
    pc.tab_count = 2;
    pc.tab_attention[5] = true;
    try testing.expect(!pc.hasAttention());
    pc.tab_attention[1] = true;
    try testing.expect(pc.hasAttention());
}

test "unit: Pane attention is orthogonal to bell/exited status" {
    var pc: Pane = .{};
    pc.tab_count = 3;
    pc.tab_status[0] = .exited;
    pc.tab_attention[2] = true;
    try testing.expectEqual(TabStatus.exited, pc.aggregateStatus());
    try testing.expect(pc.hasAttention());
    pc.tab_attention[2] = false;
    try testing.expectEqual(TabStatus.exited, pc.aggregateStatus());
    try testing.expect(!pc.hasAttention());
}

test "unit: Pane progress and log store and clear per tab" {
    var pc: Pane = .{};
    pc.tab_count = 2;

    try testing.expectEqual(@as(?u8, null), pc.tab_progress[0]);
    try testing.expect(pc.tab_log[0].latest() == null);

    pc.tab_progress[1] = 42;
    try testing.expectEqual(@as(?u8, 42), pc.tab_progress[1]);
    pc.tab_progress[1] = 100;
    try testing.expectEqual(@as(?u8, 100), pc.tab_progress[1]);
    pc.tab_progress[1] = null;
    try testing.expectEqual(@as(?u8, null), pc.tab_progress[1]);

    pc.tab_log[0].push("line one");
    pc.tab_log[0].push("line two");
    try testing.expectEqualStrings("line two", pc.tab_log[0].latest().?);
    try testing.expectEqualStrings("line one", pc.tab_log[0].at(1).?);
    try testing.expect(pc.tab_log[1].latest() == null);
}

test "unit: tab arrays stress at workspace capacity" {
    // Parallel arrays at the real MAX_TABS size: entry i of every array
    // must keep describing the same logical tab through edge-position
    // removes, a front re-insert, full-span moves, and an end swap.
    var ids: [MAX_TABS]u16 = undefined;
    var tags: [MAX_TABS]u32 = undefined;
    const arrays = .{ &ids, &tags };
    for (0..MAX_TABS) |i| {
        ids[i] = @intCast(i);
        tags[i] = @as(u32, @intCast(i)) + 1000;
    }
    var count: usize = MAX_TABS;

    // Remove the first tab: everything shifts down one.
    arith.tabArraysRemove(arrays, count, 0);
    count -= 1; // 63 live: 1..63
    try testing.expectEqual(@as(u16, 1), ids[0]);
    try testing.expectEqual(@as(u16, 63), ids[count - 1]);

    // Remove the last tab (idx == count - 1): pure count decrement.
    arith.tabArraysRemove(arrays, count, count - 1);
    count -= 1; // 62 live: 1..62
    try testing.expectEqual(@as(u16, 62), ids[count - 1]);

    // Re-insert at the front (gap at 0).
    arith.tabArraysInsertGap(arrays, count, 0);
    ids[0] = 0;
    tags[0] = 1000;
    count += 1; // 63 live: 0..62

    // Front-to-back then back-to-front across the whole span: a full
    // round trip must be the identity permutation.
    arith.tabArraysMove(arrays, 0, count - 1);
    arith.tabArraysMove(arrays, count - 1, 0);
    for (0..count) |i| {
        try testing.expectEqual(@as(u16, @intCast(i)), ids[i]);
    }

    // Swap the two ends, then verify every parallel slot still
    // describes the same logical tab.
    arith.tabArraysSwap(arrays, 0, count - 1);
    try testing.expectEqual(@as(u16, 62), ids[0]);
    try testing.expectEqual(@as(u16, 0), ids[count - 1]);
    for (ids[0..count], tags[0..count]) |id, tag| {
        try testing.expectEqual(@as(u32, id) + 1000, tag);
    }
}

test "unit: Pane aggregate status slot visibility at the count boundaries" {
    var pc: Pane = .{};

    for (&pc.tab_status) |*s| s.* = .exited;
    pc.tab_count = 0;
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());

    for (&pc.tab_status) |*s| s.* = .normal;
    pc.tab_status[MAX_TABS - 1] = .exited;
    pc.tab_count = MAX_TABS;
    try testing.expectEqual(TabStatus.exited, pc.aggregateStatus());

    pc.tab_count = MAX_TABS - 1;
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());

    pc.tab_status[MAX_TABS - 1] = .bell;
    pc.tab_count = MAX_TABS;
    try testing.expectEqual(TabStatus.bell, pc.aggregateStatus());
    pc.tab_count = 0;
    try testing.expectEqual(TabStatus.normal, pc.aggregateStatus());
}
