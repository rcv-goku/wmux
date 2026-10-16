//! Pure index arithmetic of the window model (ARCHITECTURE.md ADR-1.2:
//! std only, no Win32, no model pointers): tab insert position, the
//! selected-tab fixup after a close, the close-workspace survivor rule
//! and the workspace create guard. Moved out of Window.zig in W0-A2.

const std = @import("std");

/// Where a newly created tab is inserted into a workspace's tab arrays,
/// per the `window-new-tab-position` config: `.current` puts it right
/// after the active tab (or at 0 when empty), `.end` appends. Pure and
/// HWND-free so the create/list/close index contract is unit-testable:
/// the returned position is the index the new tab will occupy AND
/// (because the new tab becomes active) the index `tab-new` reports,
/// `tab-list` enumerates, and `tab-close` accepts — they must agree. The
/// result is always <= count (a valid post-insert index, < new
/// tab_count). Shared by addTabWithCommand, addTabBackground, and
/// addBrowserTab.
pub fn newTabInsertPos(pos_cfg: anytype, count: usize, active: usize) usize {
    return switch (pos_cfg) {
        .current => if (count > 0) active + 1 else 0,
        .end => count,
    };
}

/// Pure active-tab fixup for closeTabAt (model/ops/surface.zig): the tab
/// at `idx` was removed (the list already shifted left) leaving
/// `new_count` >= 1 tabs; return the post-close active index. A surviving
/// active tab follows its shifted slot; closing the active tab selects the
/// tab that slid into its slot, clamped to the new last index.
pub fn closeTabActiveFixup(new_count: usize, active: usize, idx: usize) usize {
    if (active >= new_count) return new_count - 1;
    if (active > idx) return active - 1;
    return active;
}

/// Pure guard for createAndSelectWorkspace: a new workspace may be
/// created only on a non-QuickTerminal (multi-workspace) window. There is
/// no workspace cap (G7; the former limit was 16).
pub fn canCreateWorkspace(is_quick_terminal: bool) bool {
    return !is_quick_terminal;
}

/// Pure index arithmetic for closeWorkspace, HWND-free so it can be
/// unit tested exhaustively. Closing the only workspace closes the
/// window. Otherwise the caller removes the workspace from the list
/// (the later ones shift down one) and selects new_active: a surviving
/// active workspace follows its shifted position, and closing the active
/// one selects the workspace that slid into its position, clamped to the
/// new last index.
pub const CloseWorkspaceArith = union(enum) {
    close_window,
    survivors: struct {
        new_count: usize,
        new_active: usize,
    },
};

pub fn closeWorkspaceArith(count: usize, active: usize, idx: usize) CloseWorkspaceArith {
    if (count == 1) return .close_window;
    const new_count = count - 1;
    const new_active: usize = if (idx == active)
        @min(idx, new_count - 1)
    else if (active > idx)
        active - 1
    else
        active;
    return .{ .survivors = .{ .new_count = new_count, .new_active = new_active } };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: model: new-tab insert position matches config" {
    const Pos = enum { current, end };
    // .current after the active tab; at 0 when empty.
    try testing.expectEqual(@as(usize, 0), newTabInsertPos(Pos.current, 0, 0));
    try testing.expectEqual(@as(usize, 1), newTabInsertPos(Pos.current, 1, 0));
    try testing.expectEqual(@as(usize, 3), newTabInsertPos(Pos.current, 3, 2));
    try testing.expectEqual(@as(usize, 2), newTabInsertPos(Pos.current, 3, 1));
    // .end appends.
    try testing.expectEqual(@as(usize, 0), newTabInsertPos(Pos.end, 0, 0));
    try testing.expectEqual(@as(usize, 3), newTabInsertPos(Pos.end, 3, 1));
}

test "unit: model: tab new returns an index list shows and close accepts (BUG 2)" {
    // The create/list/close index contract: the index `tab-new` reports
    // (the insert position, which becomes the workspace's active_tab) must
    // be a valid index for `tab-list` (0..tab_count) and address THAT same
    // new tab on `tab-close`. Empirically reproduce the round-trip with
    // the pure helpers the real handlers use, for both configs and for a
    // fresh (1-tab) workspace — the report's scenario where tab-new said
    // index 1 but list/close only saw index 0.
    const Pos = enum { current, end };
    const cfgs = [_]Pos{ .current, .end };
    inline for (cfgs) |cfg| {
        // A fresh background workspace has exactly one tab (active_tab 0).
        var count: usize = 1;
        const active: usize = 0;

        // tab-new: insert at the config position; the new tab becomes the
        // workspace's active tab, and tab-new returns that index.
        const new_idx = newTabInsertPos(cfg, count, active);
        count += 1; // the array bookkeeping bumps tab_count

        // tab-list enumerates 0..count and must contain new_idx.
        try testing.expect(new_idx < count);

        // tab-close <new_idx>: must be a valid index (so it never answers
        // UnknownTab for the index tab-new just handed back) and removes
        // the tab at exactly new_idx, leaving the other tab behind.
        try testing.expect(new_idx < count);
        const post_active = closeTabActiveFixup(count - 1, new_idx, new_idx);
        // After closing the just-created tab the survivor (the original
        // tab 0) is the active one.
        try testing.expectEqual(@as(usize, 0), post_active);
    }
}

test "unit: model: workspace close survivor selection table" {
    const Case = struct {
        count: usize,
        active: usize,
        idx: usize,
        new_active: usize,
    };
    const cases = [_]Case{
        // Closing below the active workspace shifts it down with the slots.
        .{ .count = 3, .active = 2, .idx = 0, .new_active = 1 },
        .{ .count = 4, .active = 2, .idx = 1, .new_active = 1 },
        .{ .count = 2, .active = 1, .idx = 0, .new_active = 0 },
        // Closing above the active workspace leaves it in place.
        .{ .count = 3, .active = 0, .idx = 2, .new_active = 0 },
        .{ .count = 4, .active = 1, .idx = 3, .new_active = 1 },
        .{ .count = 2, .active = 0, .idx = 1, .new_active = 0 },
        // Closing the active workspace selects the slot that slid in...
        .{ .count = 3, .active = 1, .idx = 1, .new_active = 1 },
        .{ .count = 4, .active = 0, .idx = 0, .new_active = 0 },
        // ...clamped to the new last index when the last one closes.
        .{ .count = 3, .active = 2, .idx = 2, .new_active = 1 },
        .{ .count = 2, .active = 1, .idx = 1, .new_active = 0 },
    };
    for (cases) |c| {
        const s = closeWorkspaceArith(c.count, c.active, c.idx).survivors;
        try testing.expectEqual(c.count - 1, s.new_count);
        try testing.expectEqual(c.new_active, s.new_active);
    }
}

test "unit: model: workspace close of the only workspace closes the window" {
    try testing.expect(closeWorkspaceArith(1, 0, 0) == .close_window);
    // With siblings, the window never closes from this path.
    try testing.expect(closeWorkspaceArith(2, 0, 0) != .close_window);
    try testing.expect(closeWorkspaceArith(2, 1, 1) != .close_window);
}

test "unit: model: workspace close arithmetic exhaustive over count 1..4" {
    // Every (count, active, idx) combination, verified against an id
    // simulation of the slot shift closeWorkspace publishes: for i in
    // idx..new_count slot[i] = slot[i+1], then the duplicate at
    // new_count is value-initialized.
    var count: usize = 1;
    while (count <= 4) : (count += 1) {
        for (0..count) |active| {
            for (0..count) |idx| {
                const outcome = closeWorkspaceArith(count, active, idx);
                if (count == 1) {
                    // Last close always signals window close.
                    try testing.expect(outcome == .close_window);
                    continue;
                }
                const s = outcome.survivors;
                try testing.expectEqual(count - 1, s.new_count);
                // The new active index is always valid.
                try testing.expect(s.new_active < s.new_count);

                // Simulate the shift over distinct ids; 99 marks the
                // cleared duplicate slot.
                var ids: [4]usize = .{ 0, 1, 2, 3 };
                for (idx..s.new_count) |i| ids[i] = ids[i + 1];
                ids[s.new_count] = 99;

                // The cleared slot is never selected.
                try testing.expect(ids[s.new_active] != 99);
                if (idx != active) {
                    // A background close keeps the same workspace active.
                    try testing.expectEqual(active, ids[s.new_active]);
                } else if (idx < s.new_count) {
                    // Closing the active workspace selects the one that
                    // slid into its slot...
                    try testing.expectEqual(idx + 1, ids[s.new_active]);
                } else {
                    // ...or the new last when the last one was closed.
                    try testing.expectEqual(idx - 1, ids[s.new_active]);
                }
            }
        }
    }
}

test "unit: model: tab close active fixup table" {
    // Args are (new_count, active, idx): the POST-close tab count, the
    // pre-close active index, and the closed index.
    // Closing below the active tab shifts it down.
    try testing.expectEqual(@as(usize, 1), closeTabActiveFixup(3, 2, 0));
    // Closing above the active tab leaves it in place.
    try testing.expectEqual(@as(usize, 1), closeTabActiveFixup(3, 1, 2));
    // Closing the active tab selects the tab that slid into its slot...
    try testing.expectEqual(@as(usize, 1), closeTabActiveFixup(3, 1, 1));
    // ...clamped to the new last index when the last tab closes.
    try testing.expectEqual(@as(usize, 1), closeTabActiveFixup(2, 2, 2));
    // Closing the only sibling of the active first tab keeps index 0.
    try testing.expectEqual(@as(usize, 0), closeTabActiveFixup(1, 0, 1));
}

test "unit: model: tab close active fixup exhaustive over count 2..4" {
    // Every (count, active, idx) with count >= 2 (closing the last tab
    // takes the workspace-collapse/window-close paths before the fixup
    // runs), verified against the ordered removal the tab list does.
    var count: usize = 2;
    while (count <= 4) : (count += 1) {
        for (0..count) |active| {
            for (0..count) |idx| {
                const new_count = count - 1;
                var ids: [4]usize = .{ 0, 1, 2, 3 };
                for (idx..new_count) |i| ids[i] = ids[i + 1];

                const fixed = closeTabActiveFixup(new_count, active, idx);
                // The new active index is always valid.
                try testing.expect(fixed < new_count);
                if (idx != active) {
                    // A surviving active tab stays active.
                    try testing.expectEqual(active, ids[fixed]);
                } else if (idx < new_count) {
                    // Closing the active tab selects the slid-in tab...
                    try testing.expectEqual(idx + 1, ids[fixed]);
                } else {
                    // ...or the new last when the last tab was closed.
                    try testing.expectEqual(idx - 1, ids[fixed]);
                }
            }
        }
    }
}

test "unit: model: workspace create guard only blocks the quick terminal" {
    try testing.expect(canCreateWorkspace(false));
    // QuickTerminal is single-workspace.
    try testing.expect(!canCreateWorkspace(true));
}
