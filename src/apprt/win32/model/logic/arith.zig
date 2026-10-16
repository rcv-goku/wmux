//! Pure index arithmetic of the window model (ARCHITECTURE.md ADR-1.2:
//! std only, no Win32, no model pointers): tab insert position, the
//! active-index fixups after a close or a move, and the close-workspace
//! survivor rule. Moved out of Window.zig in W0-A2.

const std = @import("std");

/// Maximum number of workspaces per window.
pub const MAX_WORKSPACES: usize = 16;

/// Pure attention aggregation: true iff any flag in `flags` is set. The
/// caller passes the live tab slice (tab_attention[0..tab_count]) so
/// stale slots past tab_count are never consulted. Factored out of
/// Workspace.hasAttention so the cross-level "a workspace/tab shows the
/// ring when a pane in it is waiting" rule is unit-testable without a
/// live window.
pub fn aggregateAttention(flags: []const bool) bool {
    for (flags) |f| {
        if (f) return true;
    }
    return false;
}

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

/// Shift entries [pos, count) right by one in every array of the
/// tuple, opening a gap at pos. The caller fills the gap and bumps its
/// count.
pub fn tabArraysInsertGap(arrays: anytype, count: usize, pos: usize) void {
    inline for (arrays) |arr| {
        var i: usize = count;
        while (i > pos) : (i -= 1) arr[i] = arr[i - 1];
    }
}

/// Shift entries (idx, count) left by one in every array, overwriting
/// idx. The caller decrements its count (and clears the now-duplicate
/// last slot where stale pointers matter, e.g. tabs).
pub fn tabArraysRemove(arrays: anytype, count: usize, idx: usize) void {
    inline for (arrays) |arr| {
        var i: usize = idx;
        while (i + 1 < count) : (i += 1) arr[i] = arr[i + 1];
    }
}

/// Move the entry at `from` to `to` in every array, shifting the
/// entries between them one slot toward `from`.
pub fn tabArraysMove(arrays: anytype, from: usize, to: usize) void {
    inline for (arrays) |arr| {
        const saved = arr[from];
        var i: usize = from;
        if (from < to) {
            while (i < to) : (i += 1) arr[i] = arr[i + 1];
        } else {
            while (i > to) : (i -= 1) arr[i] = arr[i - 1];
        }
        arr[to] = saved;
    }
}

/// Swap entries a and b in every array.
pub fn tabArraysSwap(arrays: anytype, a: usize, b: usize) void {
    inline for (arrays) |arr| {
        std.mem.swap(@TypeOf(arr[a]), &arr[a], &arr[b]);
    }
}

/// Pure active-tab fixup for closeTabInContainer: the tab at `idx` was
/// removed (arrays already shifted left) leaving `new_count` >= 1 tabs;
/// return the post-close active index. A surviving active tab follows
/// its shifted slot; closing the active tab selects the tab that slid
/// into its slot, clamped to the new last index.
pub fn closeTabActiveFixup(new_count: usize, active: usize, idx: usize) usize {
    if (active >= new_count) return new_count - 1;
    if (active > idx) return active - 1;
    return active;
}

/// Pure guard for createAndSelectWorkspace: a new workspace slot may be
/// created only on a non-QuickTerminal (multi-workspace) window with
/// fewer than MAX_WORKSPACES slots in use.
pub fn canCreateWorkspace(is_quick_terminal: bool, count: usize) bool {
    return !is_quick_terminal and count < MAX_WORKSPACES;
}

/// Pure index arithmetic for closeWorkspace, HWND-free so it can be
/// unit tested exhaustively. Closing the only workspace closes the
/// window. Otherwise the caller shifts slots [idx+1, count) left one
/// (`for (idx..new_count) |i| slot[i] = slot[i+1]`), value-inits the
/// now-duplicate slot at new_count, and selects new_active: a surviving
/// active workspace follows its shifted slot, and closing the active
/// one selects the workspace that slid into its slot, clamped to the
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

/// Pure active-index fixup for moveWorkspaceTo: the slot at `from`
/// moved to `to`, shifting every slot between them one toward `from`;
/// return where the index `active` lands so the same workspace stays
/// active. Identity when from == to. HWND-free so it can be unit
/// tested exhaustively.
pub fn moveActiveFixup(active: usize, from: usize, to: usize) usize {
    if (active == from) return to;
    if (from < to and active > from and active <= to) return active - 1;
    if (from > to and active >= to and active < from) return active + 1;
    return active;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: tab arrays insert gap at the end moves nothing" {
    var ids = [_]u8{ 1, 2, 3, 0xAA };
    var lens = [_]u16{ 10, 20, 30, 0xBBBB };
    tabArraysInsertGap(.{ &ids, &lens }, 3, 3);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0xAA }, &ids);
    try testing.expectEqualSlices(u16, &.{ 10, 20, 30, 0xBBBB }, &lens);
}

test "unit: tab arrays insert gap in the middle shifts the tail right" {
    var ids = [_]u8{ 1, 2, 3, 0 };
    var lens = [_]u16{ 10, 20, 30, 0 };
    tabArraysInsertGap(.{ &ids, &lens }, 3, 1);
    // The gap at 1 still holds its old value (the caller overwrites
    // it); entries 2..3 are the old 1..2.
    try testing.expectEqualSlices(u8, &.{ 1, 2, 2, 3 }, &ids);
    try testing.expectEqualSlices(u16, &.{ 10, 20, 20, 30 }, &lens);
}

test "unit: tab arrays remove at both edges" {
    const Status = enum { normal, bell };
    // Right edge: pure count decrement, no movement.
    {
        var ids = [_]u8{ 1, 2, 3 };
        var status = [_]Status{ .normal, .bell, .bell };
        tabArraysRemove(.{ &ids, &status }, 3, 2);
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &ids);
        try testing.expectEqualSlices(Status, &.{ .normal, .bell, .bell }, &status);
    }
    // Left edge: everything shifts down one (the last slot keeps a
    // duplicate the caller clears where stale pointers matter).
    {
        var ids = [_]u8{ 1, 2, 3 };
        var status = [_]Status{ .bell, .normal, .bell };
        tabArraysRemove(.{ &ids, &status }, 3, 0);
        try testing.expectEqualSlices(u8, &.{ 2, 3, 3 }, &ids);
        try testing.expectEqualSlices(Status, &.{ .normal, .bell, .bell }, &status);
    }
}

test "unit: tab arrays move right, left, and adjacent" {
    {
        var ids = [_]u8{ 1, 2, 3, 4 };
        tabArraysMove(.{&ids}, 0, 3);
        try testing.expectEqualSlices(u8, &.{ 2, 3, 4, 1 }, &ids);
    }
    {
        var ids = [_]u8{ 1, 2, 3, 4 };
        tabArraysMove(.{&ids}, 3, 0);
        try testing.expectEqualSlices(u8, &.{ 4, 1, 2, 3 }, &ids);
    }
    {
        var ids = [_]u8{ 1, 2, 3, 4 };
        tabArraysMove(.{&ids}, 1, 2);
        try testing.expectEqualSlices(u8, &.{ 1, 3, 2, 4 }, &ids);
    }
}

test "unit: tab arrays swap" {
    var ids = [_]u8{ 1, 2, 3 };
    var lens = [_]u16{ 10, 20, 30 };
    tabArraysSwap(.{ &ids, &lens }, 0, 2);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1 }, &ids);
    try testing.expectEqualSlices(u16, &.{ 30, 20, 10 }, &lens);
}

test "unit: tab arrays stay aligned across a mutation sequence" {
    // The real invariant: entry i of every parallel array must describe
    // the same logical tab after any mix of operations. Tab n carries
    // id n and "title" n+100.
    var ids: [5]u8 = undefined;
    var titles: [5]u8 = undefined;
    var count: usize = 0;
    const arrays = .{ &ids, &titles };

    // Insert 1 then 2 at the end, then 3 in the middle: order 1,3,2.
    tabArraysInsertGap(arrays, count, 0);
    ids[0] = 1;
    titles[0] = 101;
    count += 1;
    tabArraysInsertGap(arrays, count, 1);
    ids[1] = 2;
    titles[1] = 102;
    count += 1;
    tabArraysInsertGap(arrays, count, 1);
    ids[1] = 3;
    titles[1] = 103;
    count += 1;

    tabArraysMove(arrays, 0, 2); // 3,2,1
    tabArraysSwap(arrays, 0, 1); // 2,3,1
    tabArraysRemove(arrays, count, 1); // 2,1
    count -= 1;

    try testing.expectEqualSlices(u8, &.{ 2, 1 }, ids[0..count]);
    for (ids[0..count], titles[0..count]) |id, title| {
        try testing.expectEqual(id + 100, title);
    }
}

test "unit: new-tab insert position matches config" {
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

test "unit: tab new returns an index list shows and close accepts (BUG 2)" {
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

test "unit: aggregateAttention is an OR over the slice" {
    try testing.expect(!aggregateAttention(&.{}));
    try testing.expect(!aggregateAttention(&.{ false, false, false }));
    try testing.expect(aggregateAttention(&.{ false, true, false }));
    try testing.expect(aggregateAttention(&.{true}));
    // Trailing true outside a shorter slice the caller passes is never
    // seen — the caller slices to tab_count.
    const flags = [_]bool{ false, false, true };
    try testing.expect(!aggregateAttention(flags[0..2]));
    try testing.expect(aggregateAttention(flags[0..3]));
}

test "unit: workspace close survivor selection table" {
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

test "unit: workspace close of the only workspace closes the window" {
    try testing.expect(closeWorkspaceArith(1, 0, 0) == .close_window);
    // With siblings, the window never closes from this path.
    try testing.expect(closeWorkspaceArith(2, 0, 0) != .close_window);
    try testing.expect(closeWorkspaceArith(2, 1, 1) != .close_window);
}

test "unit: workspace close arithmetic exhaustive over count 1..4" {
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

test "unit: workspace move active fixup table" {
    // Moving the active workspace tracks it to the destination.
    try testing.expectEqual(@as(usize, 3), moveActiveFixup(0, 0, 3));
    try testing.expectEqual(@as(usize, 0), moveActiveFixup(3, 3, 0));
    // Rightward move: actives inside (from, to] shift down one.
    try testing.expectEqual(@as(usize, 1), moveActiveFixup(2, 0, 3));
    try testing.expectEqual(@as(usize, 2), moveActiveFixup(3, 0, 3));
    // Leftward move: actives inside [to, from) shift up one.
    try testing.expectEqual(@as(usize, 2), moveActiveFixup(1, 3, 0));
    try testing.expectEqual(@as(usize, 2), moveActiveFixup(1, 2, 0));
    // Actives outside the shifted span stay put.
    try testing.expectEqual(@as(usize, 0), moveActiveFixup(0, 1, 3));
    try testing.expectEqual(@as(usize, 3), moveActiveFixup(3, 0, 2));
}

test "unit: workspace move active fixup exhaustive over count 1..4" {
    // Every (count, active, from, to) combination — including the
    // from == to identity the call site early-returns — verified
    // against an id simulation of the lift-shift-drop shuffle
    // moveWorkspaceTo performs: the fixed-up index must stay in range
    // and keep pointing at the same workspace id.
    var count: usize = 1;
    while (count <= 4) : (count += 1) {
        for (0..count) |active| {
            for (0..count) |from| {
                for (0..count) |to| {
                    var ids: [4]usize = .{ 0, 1, 2, 3 };
                    const saved = ids[from];
                    if (from < to) {
                        var i: usize = from;
                        while (i < to) : (i += 1) ids[i] = ids[i + 1];
                    } else {
                        var i: usize = from;
                        while (i > to) : (i -= 1) ids[i] = ids[i - 1];
                    }
                    ids[to] = saved;

                    const fixed = moveActiveFixup(active, from, to);
                    try testing.expect(fixed < count);
                    try testing.expectEqual(active, ids[fixed]);
                }
            }
        }
    }
}

test "unit: tab close active fixup table" {
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

test "unit: tab close active fixup exhaustive over count 2..4" {
    // Every (count, active, idx) with count >= 2 (closing the last tab
    // takes the workspace-collapse/window-close paths before the fixup
    // runs), verified against tabArraysRemove's real shift.
    var count: usize = 2;
    while (count <= 4) : (count += 1) {
        for (0..count) |active| {
            for (0..count) |idx| {
                const new_count = count - 1;
                var ids: [4]usize = .{ 0, 1, 2, 3 };
                tabArraysRemove(.{&ids}, count, idx);

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

test "unit: workspace create guard caps at 16 and blocks quick terminal" {
    // Every count below the cap is allowed on a normal window.
    for (0..MAX_WORKSPACES) |count| {
        try testing.expect(canCreateWorkspace(false, count));
    }
    // At (and past) the cap: no new slot.
    try testing.expect(!canCreateWorkspace(false, MAX_WORKSPACES));
    try testing.expect(!canCreateWorkspace(false, MAX_WORKSPACES + 1));
    // QuickTerminal is single-workspace regardless of count.
    try testing.expect(!canCreateWorkspace(true, 0));
    try testing.expect(!canCreateWorkspace(true, 1));
    try testing.expect(!canCreateWorkspace(true, MAX_WORKSPACES));
    // The sidebar's row math and the workspaces array size both assume
    // this exact cap; a silent change must fail a test.
    try testing.expectEqual(@as(usize, 16), MAX_WORKSPACES);
}
