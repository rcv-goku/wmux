# Tier 1: Splits, move_tab, close_tab modes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add split panes (5 actions), move_tab, and close_tab modes to the Win32 Ghostty apprt.

**Architecture:** Reuse `SplitTree(*Surface)` from `src/datastruct/split_tree.zig`. Each tab owns a split tree instead of a bare `*Surface`. Window.zig positions child HWNDs via recursive layout and paints dividers via GDI.

**Tech Stack:** Zig, Win32 API (GDI, HWND management, SetCapture/ReleaseCapture), `SplitTree(V)` data structure

**Spec:** `docs/superpowers/specs/2026-03-23-tier1-splits-tabs-design.md`

---

## File Structure

| File | Responsibility | Action |
|------|---------------|--------|
| `src/apprt/win32/Surface.zig` | Terminal surface (child HWND, OpenGL, PTY) | Modify: add ref/unref/eql for SplitTree protocol |
| `src/apprt/win32/Window.zig` | Top-level window, tab+split management | Modify: replace tab_surfaces with tab_trees, add layout/paint/drag/move/close |
| `src/apprt/win32/App.zig` | Action dispatch, window procedures | Modify: wire split/move_tab/close_tab handlers |

---

### Task 1: Add SplitTree View Protocol to Surface

**Files:**
- Modify: `src/apprt/win32/Surface.zig:21-106` (struct fields), around line 109 (before init)

- [ ] **Step 1: Add ref_count field**

In `src/apprt/win32/Surface.zig`, add after the last struct field (after `search_active: bool = false`):

```zig
/// Reference count for SplitTree view protocol. Starts at 0 because
/// SplitTree.init() calls ref() to take ownership.
ref_count: u32 = 0,
```

- [ ] **Step 2: Add ref, unref, eql functions**

Add after all struct fields, before `pub fn init(...)`:

```zig
/// SplitTree view protocol: increment reference count.
pub fn ref(self: *Surface, alloc: Allocator) Allocator.Error!*Surface {
    _ = alloc;
    self.ref_count += 1;
    return self;
}

/// SplitTree view protocol: decrement reference count.
pub fn unref(self: *Surface, alloc: Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        if (self.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        self.deinit();
        alloc.destroy(self);
    }
}

/// SplitTree view protocol: identity comparison.
pub fn eql(self: *const Surface, other: *const Surface) bool {
    return self == other;
}
```

Verify `Allocator` is already imported (it is, via `std.mem.Allocator` or through other imports).

- [ ] **Step 3: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/Surface.zig
git commit -m "feat(win32): add SplitTree view protocol (ref/unref/eql) to Surface"
```

---

### Task 2: Migrate Window.zig from tab_surfaces to tab_trees

**Files:**
- Modify: `src/apprt/win32/Window.zig` (multiple sections)

This replaces `tab_surfaces: [64]*Surface` with `tab_trees: [64]SplitTree(*Surface)` and `tab_active_surface: [64]*Surface`. Every access to `tab_surfaces[i]` changes accordingly. Single-leaf trees behave identically.

- [ ] **Step 1: Add SplitTree import and update struct fields**

Add import after line 11 (`const Surface = ...`):

```zig
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
```

Replace `tab_surfaces` field (line 27):

```zig
// Before:
tab_surfaces: [64]*Surface = undefined,

// After:
tab_trees: [64]SplitTree(*Surface) = undefined,
tab_active_surface: [64]*Surface = undefined,
```

- [ ] **Step 2: Update getActiveSurface (line 206)**

```zig
// Before:
pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.tab_count == 0) return null;
    return self.tab_surfaces[self.active_tab];
}

// After:
pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.tab_count == 0) return null;
    return self.tab_active_surface[self.active_tab];
}
```

- [ ] **Step 3: Add helper functions**

Add after `getActiveSurface`:

```zig
/// Find the tab index containing a given surface.
/// Checks tab_active_surface first, then scans all trees.
pub fn findTabIndex(self: *Window, surface: *Surface) ?usize {
    // Fast path: check active surfaces.
    for (self.tab_active_surface[0..self.tab_count], 0..) |s, i| {
        if (s == surface) return i;
    }
    // Slow path: scan all tree leaves.
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return i;
        }
    }
    return null;
}

/// Find the Node.Handle for a surface in a given tab's tree.
fn findHandle(self: *Window, tab_idx: usize, surface: *Surface) ?SplitTree(*Surface).Node.Handle {
    var it = self.tab_trees[tab_idx].iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) return entry.handle;
    }
    return null;
}
```

- [ ] **Step 4: Update addTab (lines 213-257)**

Replace the full `addTab` function:

```zig
pub fn addTab(self: *Window) !*Surface {
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(self.app, self);

    // Create single-node split tree for this surface.
    const tree = SplitTree(*Surface).init(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };

    // Determine insert position based on config.
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tab_count > 0) self.active_tab + 1 else 0,
        .end => self.tab_count,
    };

    // Shift elements right to make room at pos.
    var i: usize = self.tab_count;
    while (i > pos) : (i -= 1) {
        self.tab_trees[i] = self.tab_trees[i - 1];
        self.tab_active_surface[i] = self.tab_active_surface[i - 1];
        self.tab_titles[i] = self.tab_titles[i - 1];
        self.tab_title_lens[i] = self.tab_title_lens[i - 1];
    }
    self.tab_trees[pos] = tree;
    self.tab_active_surface[pos] = surface;
    self.tab_count += 1;

    // Set default title.
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);

    if (self.tab_count == 1) {
        if (self.hwnd) |h| {
            _ = w32.ShowWindow(h, w32.SW_SHOW);
            _ = w32.UpdateWindow(h);
        }
        self.active_tab = pos;
        self.updateWindowTitle();
        if (surface.hwnd) |h| _ = w32.SetFocus(h);
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    return surface;
}
```

- [ ] **Step 5: Update closeTab (lines 262-305)**

Replace the full `closeTab` function. Tree deinit calls `unref` on all leaves, which handles Surface cleanup when ref_count reaches 0.

```zig
pub fn closeTab(self: *Window, surface: *Surface) void {
    log.debug("closeTab called for surface={x} tab_count={}", .{ @intFromPtr(surface), self.tab_count });
    const idx = self.findTabIndex(surface) orelse return;
    self.closeTabByIndex(idx);
}

/// Close a tab by its index. Deinits the tree (which unrefs all surfaces).
fn closeTabByIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;

    // Deinit the tree — this unrefs all surfaces in the tree.
    // When ref_count hits 0, Surface.unref hides HWND, calls deinit, frees.
    var tree = self.tab_trees[idx];
    tree.deinit();

    // Shift left to fill gap.
    var i: usize = idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
    }
    self.tab_count -= 1;

    if (self.tab_count == 0) {
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }

    if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    } else if (self.active_tab > idx) {
        self.active_tab -= 1;
    }
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
}
```

- [ ] **Step 6: Update selectTabIndex (lines 308-331)**

Replace `tab_surfaces[idx]` with `tab_active_surface[idx]`, and hide ALL surfaces of old tab's tree (for future multi-surface trees):

```zig
pub fn selectTabIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;

    // Hide all surfaces of the current tab's tree.
    if (self.active_tab < self.tab_count) {
        var it = self.tab_trees[self.active_tab].iterator();
        while (it.next()) |entry| {
            if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }

    self.active_tab = idx;
    const surface = self.tab_active_surface[idx];

    // Layout all surfaces in the new tab's tree.
    self.layoutSplits();

    if (surface.hwnd) |h| _ = w32.SetFocus(h);
    self.updateWindowTitle();
}
```

- [ ] **Step 7: Add layoutSplits function**

Add after `selectTabIndex`:

```zig
/// Lay out all surfaces in the active tab's split tree within the content area.
pub fn layoutSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    const rect = self.surfaceRect();

    // If zoomed, show only the zoomed surface at full rect, hide everything else.
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle == zoomed_handle) {
                if (entry.view.hwnd) |h| {
                    const w = @max(rect.right - rect.left, 1);
                    const ht = @max(rect.bottom - rect.top, 1);
                    _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                    _ = w32.ShowWindow(h, w32.SW_SHOW);
                }
            } else {
                if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
        return;
    }

    self.layoutNode(tree, .root, rect);
}

/// Recursively position surface HWNDs according to the split tree.
fn layoutNode(self: *Window, tree: SplitTree(*Surface), handle: SplitTree(*Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;

    switch (tree.nodes[handle.idx()]) {
        .leaf => |surface| {
            if (surface.hwnd) |h| {
                const w = @max(rect.right - rect.left, 1);
                const ht = @max(rect.bottom - rect.top, 1);
                _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                _ = w32.ShowWindow(h, w32.SW_SHOW);
            }
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, left_rect);
                self.layoutNode(tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, top_rect);
                self.layoutNode(tree, s.right, bottom_rect);
            }
        },
    }
}
```

- [ ] **Step 8: Update handleResize (lines 685-701)**

Replace the body of `handleResize` to use `layoutSplits` instead of moving a single surface:

```zig
fn handleResize(self: *Window) void {
    self.layoutSplits();
    self.invalidateTabBar();
}
```

- [ ] **Step 9: Update onTabTitleChanged (line 363)**

Replace `tab_surfaces` reference with `tab_active_surface`:

In `onTabTitleChanged`, the loop that finds the surface index searches `tab_surfaces`. Change to use `findTabIndex` which scans all tree leaves (not just active surfaces), so title updates from any split pane are recognized:

```zig
// Before:
for (self.tab_surfaces[0..self.tab_count], 0..) |s, i| {
    if (s == surface) { ... }
}

// After:
const tab_idx = self.findTabIndex(surface) orelse return;
// Use tab_idx to update the title...
```

Also in `updateWindowTitle` (if it references `tab_surfaces`), update similarly.

- [ ] **Step 10: Update paintTabBar tab title access**

In `paintTabBar` (lines 406-632), any references to `tab_surfaces` for title display should use `tab_active_surface`. Search for all `tab_surfaces` references in the file and update.

- [ ] **Step 11: Update remaining tab_surfaces references**

Search for ALL remaining `tab_surfaces` references in Window.zig and update to use the appropriate new field (`tab_trees` or `tab_active_surface`). Key locations:
- `selectTab` (line 334) — uses active surface for tab switching
- `handleTabBarClick` — uses surface for click handling
- `close` / `cleanupAllSurfaces` — cleanup on window destroy
- `deinit` — cleanup

For `close`/`cleanupAllSurfaces`/`deinit`: iterate all trees and deinit each one (which unrefs all surfaces). Update ALL of these functions:

```zig
fn cleanupAllSurfaces(self: *Window) void {
    for (0..self.tab_count) |i| {
        var tree = self.tab_trees[i];
        tree.deinit();
    }
    self.tab_count = 0;
}
```

Also update `deinit()` (line 162) which has its own loop over `tab_surfaces`:

```zig
// Before (in deinit):
const surface = self.tab_surfaces[self.tab_count];
surface.deinit();
alloc.destroy(surface);

// After (in deinit):
// Use cleanupAllSurfaces() or iterate tab_trees[i].deinit()
self.cleanupAllSurfaces();
```

- [ ] **Step 12: Update WM_ENTERSIZEMOVE/WM_EXITSIZEMOVE in windowWndProc**

These currently set `in_live_resize` on a single surface. Update to set on ALL surfaces in the active tab's tree:

```zig
w32.WM_ENTERSIZEMOVE => {
    var it = window.tab_trees[window.active_tab].iterator();
    while (it.next()) |entry| entry.view.in_live_resize = true;
    return 0;
},
w32.WM_EXITSIZEMOVE => {
    var it = window.tab_trees[window.active_tab].iterator();
    while (it.next()) |entry| entry.view.in_live_resize = false;
    return 0;
},
```

- [ ] **Step 13: Verify compilation and test**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -30`

Verify no `tab_surfaces` references remain:

Run: `grep -n "tab_surfaces" src/apprt/win32/Window.zig src/apprt/win32/App.zig`

Expected: No matches.

- [ ] **Step 14: Commit**

```bash
git add src/apprt/win32/Window.zig
git commit -m "feat(win32): migrate tabs from tab_surfaces to SplitTree per tab"
```

---

### Task 3: Implement move_tab

**Files:**
- Modify: `src/apprt/win32/Window.zig` (add moveTab function)
- Modify: `src/apprt/win32/App.zig:575-578` (replace no-op)

- [ ] **Step 1: Add moveTab to Window.zig**

Add after `selectTab`:

```zig
/// Move the active tab by a relative offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    if (self.tab_count <= 1) return;
    const n: isize = @intCast(self.active_tab);
    const count: isize = @intCast(self.tab_count);
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == self.active_tab) return;

    // Swap all tab state between active_tab and new_index.
    std.mem.swap(SplitTree(*Surface), &self.tab_trees[self.active_tab], &self.tab_trees[new_index]);
    std.mem.swap(*Surface, &self.tab_active_surface[self.active_tab], &self.tab_active_surface[new_index]);
    std.mem.swap([256]u16, &self.tab_titles[self.active_tab], &self.tab_titles[new_index]);
    std.mem.swap(u16, &self.tab_title_lens[self.active_tab], &self.tab_title_lens[new_index]);
    self.active_tab = new_index;
    self.invalidateTabBar();
}
```

- [ ] **Step 2: Wire move_tab in App.zig**

Replace lines 575-578:

```zig
// Before:
.move_tab, .toggle_tab_overview => {
    // Acknowledge but no-op until further UI is implemented.
    return true;
},

// After:
.move_tab => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            core_surface.rt_surface.parent_window.moveTab(value.amount);
        },
    }
    return true;
},

.toggle_tab_overview => {
    // Acknowledge but no-op until further UI is implemented.
    return true;
},
```

- [ ] **Step 3: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/App.zig
git commit -m "feat(win32): implement move_tab action with wrapping"
```

---

### Task 4: Implement close_tab Modes

**Files:**
- Modify: `src/apprt/win32/Window.zig` (add closeTabMode)
- Modify: `src/apprt/win32/App.zig:541-550` (pass mode through)

- [ ] **Step 1: Add closeTabMode to Window.zig**

Add after `closeTabByIndex`:

```zig
/// Close tabs based on mode: this (current), other (all but current), right (all after current).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    switch (mode) {
        .this => self.closeTab(surface),
        .other => {
            var current = self.findTabIndex(surface) orelse return;
            // Close in reverse. Track current as indices shift.
            var i: usize = self.tab_count;
            while (i > 0) {
                i -= 1;
                if (i != current) {
                    self.closeTabByIndex(i);
                    if (i < current) current -= 1;
                }
            }
        },
        .right => {
            const current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > current + 1) {
                i -= 1;
                self.closeTabByIndex(i);
            }
        },
    }
}
```

- [ ] **Step 2: Update close_tab handler in App.zig (lines 541-550)**

```zig
// Before:
.close_tab => {
    // Close the current surface (same as close_window for now).
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            core_surface.rt_surface.close(false);
        },
    }
    return true;
},

// After:
.close_tab => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            core_surface.rt_surface.parent_window.closeTabMode(
                value,
                core_surface.rt_surface,
            );
        },
    }
    return true;
},
```

- [ ] **Step 3: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/App.zig
git commit -m "feat(win32): implement close_tab modes (this, other, right)"
```

---

### Task 5: Implement new_split Action

**Files:**
- Modify: `src/apprt/win32/Window.zig` (add newSplit)
- Modify: `src/apprt/win32/App.zig` (wire .new_split)

- [ ] **Step 1: Add newSplit to Window.zig**

Add after `layoutSplits`:

```zig
/// Create a new split in the active tab. Creates a new Surface and
/// splits the tree at the active surface in the given direction.
pub fn newSplit(self: *Window, direction: SplitTree(*Surface).Split.Direction) !void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    // Find the active surface's handle in the tree.
    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    // Create new surface.
    const new_surface = try alloc.create(Surface);
    errdefer {
        new_surface.deinit();
        alloc.destroy(new_surface);
    }
    try new_surface.init(self.app, self);

    // Create a single-node tree for the new surface.
    var insert_tree = try SplitTree(*Surface).init(alloc, new_surface);
    defer insert_tree.deinit();

    // Split the current tree at the active surface.
    var new_tree = try self.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    // Replace old tree.
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    // Focus the new surface.
    self.tab_active_surface[tab] = new_surface;

    // Layout and focus.
    self.layoutSplits();
    if (new_surface.hwnd) |h| _ = w32.SetFocus(h);
}
```

- [ ] **Step 2: Wire new_split in App.zig**

Add before the `else => return false` at line 789:

```zig
.new_split => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            // Map apprt.action.SplitDirection to SplitTree.Split.Direction.
            // Cannot use @enumFromInt -- the enum orderings differ.
            const dir: SplitTree(*Surface).Split.Direction = switch (value) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
            };
            core_surface.rt_surface.parent_window.newSplit(dir) catch |err| {
                log.err("failed to create split: {}", .{err});
            };
        },
    }
    return true;
},
```

Also add the SplitTree import to App.zig:

```zig
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
```

- [ ] **Step 3: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/App.zig
git commit -m "feat(win32): implement new_split action with tree layout"
```

---

### Task 6: Handle Closing a Split Pane

**Files:**
- Modify: `src/apprt/win32/App.zig` (surfaceWndProc WM_CLOSE)
- Modify: `src/apprt/win32/Window.zig` (add closeSplitSurface)

When a surface in a multi-leaf tree is closed, remove it from the tree rather than closing the entire tab.

- [ ] **Step 1: Add closeSplitSurface to Window.zig**

Add after `closeTabMode`:

```zig
/// Close a single surface within a split tree. If it's the last surface
/// in the tab, close the entire tab instead.
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.findTabIndex(surface) orelse return;
    const tree = &self.tab_trees[tab];

    // If single leaf (no splits), close the whole tab.
    if (!tree.isSplit()) {
        self.closeTab(surface);
        return;
    }

    // Find the surface's handle.
    const handle = self.findHandle(tab, surface) orelse return;

    // Find next focus target before removing.
    const next_handle = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null);
    const next_surface: ?*Surface = if (next_handle) |nh|
        switch (tree.nodes[nh.idx()]) {
            .leaf => |v| v,
            .split => null,
        }
    else
        null;

    // Remove the surface from the tree.
    var new_tree = tree.remove(alloc, handle) catch {
        log.err("failed to remove surface from split tree", .{});
        return;
    };
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    // Update active surface.
    if (next_surface) |ns| {
        self.tab_active_surface[tab] = ns;
        self.layoutSplits();
        if (ns.hwnd) |h| _ = w32.SetFocus(h);
    } else {
        // Should not happen if tree had >1 leaf, but handle gracefully.
        self.closeTabByIndex(tab);
    }
}
```

- [ ] **Step 2: Update WM_CLOSE in surfaceWndProc (App.zig line 932)**

```zig
// Before:
w32.WM_CLOSE => {
    surface.parent_window.closeTab(surface);
    return 0;
},

// After:
w32.WM_CLOSE => {
    surface.parent_window.closeSplitSurface(surface);
    return 0;
},
```

- [ ] **Step 3: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/App.zig
git commit -m "feat(win32): close split pane removes from tree instead of closing tab"
```

---

### Task 7: Implement goto_split Action

**Files:**
- Modify: `src/apprt/win32/Window.zig` (add gotoSplit)
- Modify: `src/apprt/win32/App.zig` (wire .goto_split)

- [ ] **Step 1: Add gotoSplit to Window.zig**

Add after `newSplit`:

```zig
/// Navigate to a split in the given direction.
pub fn gotoSplit(self: *Window, target: apprt.action.GotoSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    // Map GotoSplit to SplitTree.Goto.
    const goto_target: SplitTree(*Surface).Goto = switch (target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dest_handle = (tree.goto(alloc, handle, goto_target) catch return) orelse return;

    // Get the surface at the destination.
    switch (tree.nodes[dest_handle.idx()]) {
        .leaf => |surface| {
            self.tab_active_surface[tab] = surface;
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        },
        .split => {},
    }
}
```

- [ ] **Step 2: Wire goto_split in App.zig**

Add before `else => return false`:

```zig
.goto_split => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            core_surface.rt_surface.parent_window.gotoSplit(value);
        },
    }
    return true;
},
```

- [ ] **Step 3: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/App.zig
git commit -m "feat(win32): implement goto_split with directional and sequential navigation"
```

---

### Task 8: Implement resize_split, equalize_splits, toggle_split_zoom

**Files:**
- Modify: `src/apprt/win32/Window.zig` (add resizeSplit, equalizeSplits, toggleSplitZoom)
- Modify: `src/apprt/win32/App.zig` (wire all three)

- [ ] **Step 1: Add resizeSplit to Window.zig**

```zig
/// Resize the nearest split in the given direction by the given pixel amount.
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    // Map direction to layout and sign.
    const layout: SplitTree(*Surface).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    // Convert pixel amount to ratio delta.
    const rect = self.surfaceRect();
    const dimension: f32 = switch (layout) {
        .horizontal => @floatFromInt(@max(rect.right - rect.left, 1)),
        .vertical => @floatFromInt(@max(rect.bottom - rect.top, 1)),
    };
    const sign: f32 = switch (rs.direction) {
        .left, .up => -1.0,
        .right, .down => 1.0,
    };
    const delta: f16 = @floatCast(sign * @as(f32, @floatFromInt(rs.amount)) / dimension);

    var new_tree = tree.resize(alloc, handle, layout, delta) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}
```

- [ ] **Step 2: Add equalizeSplits to Window.zig**

```zig
/// Equalize all splits in the active tab.
pub fn equalizeSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    var new_tree = self.tab_trees[tab].equalize(alloc) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}
```

- [ ] **Step 3: Add toggleSplitZoom to Window.zig**

```zig
/// Toggle zoom on the active split surface.
pub fn toggleSplitZoom(self: *Window) void {
    if (self.tab_count == 0) return;
    const tab = self.active_tab;
    var tree = &self.tab_trees[tab];

    // Only allow zoom if there are splits.
    if (!tree.isSplit()) return;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    // Toggle: if already zoomed to this handle, unzoom; else zoom.
    if (tree.zoomed) |z| {
        if (z == handle) {
            tree.zoom(null);
        } else {
            tree.zoom(handle);
        }
    } else {
        tree.zoom(handle);
    }
    self.layoutSplits();
}
```

- [ ] **Step 4: Wire all three in App.zig**

Add before `else => return false`:

```zig
.resize_split => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            core_surface.rt_surface.parent_window.resizeSplit(value);
        },
    }
    return true;
},

.equalize_splits => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            core_surface.rt_surface.parent_window.equalizeSplits();
        },
    }
    return true;
},

.toggle_split_zoom => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            core_surface.rt_surface.parent_window.toggleSplitZoom();
        },
    }
    return true;
},
```

- [ ] **Step 5: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -20`

- [ ] **Step 6: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/App.zig
git commit -m "feat(win32): implement resize_split, equalize_splits, toggle_split_zoom"
```

---

### Task 9: Paint Dividers Between Split Panes

**Files:**
- Modify: `src/apprt/win32/Window.zig` (add divider painting to WM_PAINT, invalidate content area)

- [ ] **Step 1: Add paintDividers function to Window.zig**

Add after `layoutNode`:

```zig
/// Paint divider lines between split panes in the active tab.
fn paintDividers(self: *Window, hdc: w32.HDC) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return; // No dividers when zoomed.
    const rect = self.surfaceRect();
    self.paintDividerNode(hdc, tree, .root, rect);
}

fn paintDividerNode(self: *Window, hdc: w32.HDC, tree: SplitTree(*Surface), handle: SplitTree(*Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => {},
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            const line_w: i32 = @max(@intFromFloat(@round(1.0 * self.scale)), 1);

            // Create a gray pen for the divider line.
            const pen = w32.CreatePen(0, line_w, 0x00404040) orelse return;
            defer _ = w32.DeleteObject(pen);
            const old_pen = w32.SelectObject(hdc, pen);
            defer _ = w32.SelectObject(hdc, old_pen);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                // Draw vertical divider line.
                _ = w32.MoveToEx(hdc, split_x, rect.top, null);
                _ = w32.LineTo(hdc, split_x, rect.bottom);
                // Recurse.
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, left_rect);
                self.paintDividerNode(hdc, tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                // Draw horizontal divider line.
                _ = w32.MoveToEx(hdc, rect.left, split_y, null);
                _ = w32.LineTo(hdc, rect.right, split_y);
                // Recurse.
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, top_rect);
                self.paintDividerNode(hdc, tree, s.right, bottom_rect);
            }
        },
    }
}
```

- [ ] **Step 2: Add GDI function declarations to win32.zig if missing**

Check if `CreatePen`, `SelectObject`, `DeleteObject`, `MoveToEx`, `LineTo` are declared in `src/apprt/win32/win32.zig`. If not, add them:

```zig
pub extern "gdi32" fn CreatePen(iStyle: i32, cWidth: i32, color: u32) callconv(.c) ?*anyopaque;
pub extern "gdi32" fn MoveToEx(hdc: HDC, x: i32, y: i32, lppt: ?*anyopaque) callconv(.c) i32;
pub extern "gdi32" fn LineTo(hdc: HDC, x: i32, y: i32) callconv(.c) i32;
```

(`SelectObject`, `DeleteObject` likely already exist for tab bar painting.)

- [ ] **Step 3: Update WM_PAINT handler in windowWndProc**

After the existing `paintTabBar()` call, add divider painting. The dividers need to be painted in the content area. Since `paintTabBar` uses `BeginPaint`/`EndPaint` which validates the paint region, we need to paint dividers within the same paint cycle.

Modify `paintTabBar` to also paint dividers after the tab bar. At the end of `paintTabBar`, after the BitBlt for the tab bar, add:

```zig
// Paint split dividers in the content area.
self.paintDividers(hdc_screen);
```

- [ ] **Step 4: Invalidate content area after layout changes**

Add to the end of `layoutSplits()`:

```zig
// Invalidate the content area so divider lines are repainted.
if (self.hwnd) |hwnd| {
    var rect = self.surfaceRect();
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}
```

- [ ] **Step 5: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -20`

- [ ] **Step 6: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/win32.zig
git commit -m "feat(win32): paint divider lines between split panes"
```

---

### Task 10: Implement Divider Drag Resize

**Files:**
- Modify: `src/apprt/win32/Window.zig` (add drag tracking fields and handlers)

- [ ] **Step 1: Add drag state fields to Window struct**

Add after `tracking_mouse` field:

```zig
/// Split divider drag state.
dragging_split: bool = false,
drag_split_handle: SplitTree(*Surface).Node.Handle = .root,
drag_split_layout: SplitTree(*Surface).Split.Layout = .horizontal,
drag_start_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
```

- [ ] **Step 2: Add hitTestDivider function**

Add after `paintDividerNode`:

```zig
/// Hit-test a point against split dividers. Returns the split node handle
/// and layout if the point is within the hit area of a divider.
fn hitTestDivider(self: *Window, x: i32, y: i32) ?struct { handle: SplitTree(*Surface).Node.Handle, layout: SplitTree(*Surface).Split.Layout } {
    if (self.tab_count == 0) return null;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return null;
    if (tree.zoomed != null) return null;
    const rect = self.surfaceRect();
    return self.hitTestDividerNode(tree, .root, rect, x, y);
}

fn hitTestDividerNode(
    self: *Window,
    tree: SplitTree(*Surface),
    handle: SplitTree(*Surface).Node.Handle,
    rect: w32.RECT,
    x: i32,
    y: i32,
) ?struct { handle: SplitTree(*Surface).Node.Handle, layout: SplitTree(*Surface).Split.Layout } {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => return null,
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            const hit_area: i32 = @max(@intFromFloat(@round(3.0 * self.scale)), 3);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                if (x >= split_x - hit_area and x <= split_x + hit_area and y >= rect.top and y <= rect.bottom) {
                    return .{ .handle = handle, .layout = .horizontal };
                }
                // Check children.
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, left_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, right_rect, x, y);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                if (y >= split_y - hit_area and y <= split_y + hit_area and x >= rect.left and x <= rect.right) {
                    return .{ .handle = handle, .layout = .vertical };
                }
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, top_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, bottom_rect, x, y);
            }
        },
    }
}
```

- [ ] **Step 3: Add drag handlers**

```zig
fn startDividerDrag(self: *Window, handle: SplitTree(*Surface).Node.Handle, layout: SplitTree(*Surface).Split.Layout) void {
    self.dragging_split = true;
    self.drag_split_handle = handle;
    self.drag_split_layout = layout;
    self.drag_start_rect = self.surfaceRect();
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

fn updateDividerDrag(self: *Window, x: i32, y: i32) void {
    if (!self.dragging_split) return;
    const rect = self.drag_start_rect;
    const handle = self.drag_split_handle;

    // Calculate new ratio from mouse position.
    const new_ratio: f16 = switch (self.drag_split_layout) {
        .horizontal => ratio: {
            const total: f32 = @floatFromInt(@max(rect.right - rect.left, 1));
            const pos: f32 = @floatFromInt(x - rect.left);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
        .vertical => ratio: {
            const total: f32 = @floatFromInt(@max(rect.bottom - rect.top, 1));
            const pos: f32 = @floatFromInt(y - rect.top);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
    };

    // Use resizeInPlace for live drag (no allocation).
    self.tab_trees[self.active_tab].resizeInPlace(handle, new_ratio);
    self.layoutSplits();
}

fn endDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
}
```

- [ ] **Step 4: Wire mouse messages in windowWndProc**

Update the window procedure to handle divider interaction. Modify the existing `WM_LBUTTONDOWN`, `WM_MOUSEMOVE`, `WM_LBUTTONUP` handling:

For `WM_LBUTTONDOWN` (around line 903), add divider check before tab bar click:

```zig
w32.WM_LBUTTONDOWN => {
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    // Check divider hit first.
    if (window.hitTestDivider(x, y)) |hit| {
        window.startDividerDrag(hit.handle, hit.layout);
        return 0;
    }
    // Then check tab bar.
    if (y < window.tabBarHeight()) {
        window.handleTabBarClick(x, y);
    }
    return 0;
},
```

For `WM_MOUSEMOVE` (around line 909), add drag update:

```zig
w32.WM_MOUSEMOVE => {
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    if (window.dragging_split) {
        window.updateDividerDrag(x, y);
        return 0;
    }
    // Existing tab bar mouse move handling...
    if (y < window.tabBarHeight()) {
        window.handleTabBarMouseMove(x, y);
    }
    return 0;
},
```

Add `WM_LBUTTONUP` handler:

```zig
w32.WM_LBUTTONUP => {
    if (window.dragging_split) {
        window.endDividerDrag();
        return 0;
    }
    return 0;
},
```

- [ ] **Step 5: Add cursor change for divider hover**

In windowWndProc, add `WM_SETCURSOR` handler:

```zig
w32.WM_SETCURSOR => {
    // Check if we're hovering a divider.
    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos(&pt) != 0) {
        if (window.hwnd) |hwnd| _ = w32.ScreenToClient(hwnd, &pt);
        if (window.hitTestDivider(pt.x, pt.y)) |hit| {
            const cursor_id: u32 = if (hit.layout == .horizontal) w32.IDC_SIZEWE else w32.IDC_SIZENS;
            const cursor = w32.LoadCursorW(null, @ptrFromInt(cursor_id));
            _ = w32.SetCursor(cursor);
            return 1; // We handled it.
        }
    }
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
},
```

Add any missing Win32 declarations to win32.zig (`SetCapture`, `ReleaseCapture`, `GetCursorPos`, `ScreenToClient`, `IDC_SIZEWE`, `IDC_SIZENS`).

- [ ] **Step 6: Add double-click to equalize**

Add `WM_LBUTTONDBLCLK` handler in windowWndProc:

```zig
w32.WM_LBUTTONDBLCLK => {
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    if (window.hitTestDivider(x, y)) |hit| {
        window.tab_trees[window.active_tab].resizeInPlace(hit.handle, @as(f16, 0.5));
        window.layoutSplits();
        return 0;
    }
    return 0;
},
```

Also add `w32.CS_DBLCLKS` to the window class style in Window.init (so WM_LBUTTONDBLCLK is generated).

- [ ] **Step 7: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -20`

- [ ] **Step 8: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/win32.zig
git commit -m "feat(win32): implement divider drag resize with cursor feedback"
```

---

### Task 11: Focus Tracking for Split Panes

**Files:**
- Modify: `src/apprt/win32/App.zig` (surfaceWndProc WM_SETFOCUS)

When clicking a split pane, it should become the active surface for its tab.

- [ ] **Step 1: Update WM_SETFOCUS in surfaceWndProc**

Find the existing `WM_SETFOCUS` handler in `surfaceWndProc` and add tab_active_surface update:

```zig
w32.WM_SETFOCUS => {
    // Update the active surface for this tab when a split pane gains focus.
    const tab = surface.parent_window.active_tab;
    surface.parent_window.tab_active_surface[tab] = surface;
    // Existing focus handling...
    surface.handleFocus(true);
    return 0;
},
```

- [ ] **Step 2: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add src/apprt/win32/App.zig
git commit -m "feat(win32): track active surface on split pane focus"
```

---

### Task 12: Final Verification and Integration Test

**Files:**
- All modified files

- [ ] **Step 1: Full build verification**

Run: `zig build -Dapp-runtime=win32 2>&1`

Ensure zero errors and zero warnings.

- [ ] **Step 2: Run existing tests**

Run: `zig build test 2>&1 | tail -20`

Ensure existing tests pass (split_tree tests should still pass since we only consume the API).

- [ ] **Step 3: Grep for any remaining tab_surfaces references**

Run: `grep -rn "tab_surfaces" src/apprt/win32/`

Expected: No matches.

- [ ] **Step 4: Verify all split actions are handled (not falling to else => return false)**

Check App.zig handles: `.new_split`, `.goto_split`, `.resize_split`, `.equalize_splits`, `.toggle_split_zoom`, `.move_tab`, `.close_tab` (with modes).

- [ ] **Step 5: Commit final cleanup if needed**

```bash
git add -A
git commit -m "chore(win32): final cleanup for Tier 1 splits and tab features"
```
