# Phase 01: PaneContainer Core Rearchitecture

This phase performs the foundational architectural change: moving tab ownership from the Workspace level down to per-pane containers. Currently, a Workspace holds parallel arrays of tabs (each tab containing a SplitTree of panes). The target architecture inverts this: a Workspace holds a single SplitTree of PaneContainers, and each PaneContainer manages its own set of tabs. By the end of this phase, the app compiles and runs with the new hierarchy — tabs work within PaneContainers, splits create new PaneContainers, and the tab bar shows the focused PaneContainer's tabs.

## Tasks

- [x] Create `src/apprt/win32/PaneContainer.zig` — the new per-pane tab container struct. This struct holds all the per-tab state that currently lives in Workspace's parallel arrays, plus the SplitTree view protocol methods. Specifically:
  - `ref_count: u32 = 0` — for SplitTree ownership (same pattern as Pane.zig)
  - `tab_count: usize = 0` — number of live tabs in this container
  - `active_tab: usize = 0` — index of the currently visible tab
  - `tabs: [MAX_TABS]*Pane = undefined` — each tab is a single Pane (terminal or browser). No per-tab split tree — in the new model, splits are between PaneContainers, not within tabs
  - `tab_titles: [MAX_TABS][256]u16 = undefined` — UTF-16 title buffers
  - `tab_title_lens: [MAX_TABS]u16 = undefined` — title lengths
  - `tab_status: [MAX_TABS]TabStatus = [_]TabStatus{.normal} ** MAX_TABS` — sidebar status
  - `tab_attention: [MAX_TABS]bool = @splat(false)` — attention flags
  - `tab_status_text: [MAX_TABS][MAX_STATUS_BYTES]u8 = undefined` — orchestration status
  - `tab_status_text_len: [MAX_TABS]u16 = @splat(0)`
  - `tab_progress: [MAX_TABS]?u8 = @splat(null)` — progress percent
  - `tab_log: [MAX_TABS]ipc.LogRing = @splat(.{})` — ring log buffers
  - `tab_synchronized: [MAX_TABS]bool = @splat(false)` — synchronized input
  - Import MAX_TABS and MAX_STATUS_BYTES from Window.zig (or move the constants to a shared location)
  - Import TabStatus from Window.zig, ipc from ipc.zig, Pane from Pane.zig
  - Implement SplitTree view protocol methods following the exact same pattern as Pane.zig:
    - `pub fn ref(self: *PaneContainer, alloc: Allocator) Allocator.Error!*PaneContainer` — increment ref_count, return self
    - `pub fn unref(self: *PaneContainer, alloc: Allocator) void` — decrement ref_count; at zero, iterate `tabs[0..tab_count]` calling `pane.unref(alloc)` on each, then `alloc.destroy(self)`
    - `pub fn eql(self: *const PaneContainer, other: *const PaneContainer) bool` — pointer identity (`self == other`)
  - Add `pub fn create(alloc: Allocator) Allocator.Error!*PaneContainer` — heap-allocate a PaneContainer with default-initialized fields
  - Add `pub fn activePaneHwnd(self: *const PaneContainer) ?w32.HWND` — returns `self.tabs[self.active_tab].hwnd()` if `tab_count > 0`, else null
  - Add `pub fn activePane(self: *PaneContainer) ?*Pane` — returns `self.tabs[self.active_tab]` if `tab_count > 0`, else null
  - Add `pub fn tabArrays(self: *PaneContainer)` returning a tuple of pointers to all parallel arrays, matching the current `Workspace.tabArrays()` signature and return type (but referencing PaneContainer's fields instead of Workspace's). This preserves compatibility with the existing `tabArraysInsertGap`, `tabArraysRemove`, and `tabArraysSwap` helper functions in Window.zig
  - Add `pub fn aggregateStatus(self: *const PaneContainer) TabStatus` — mirrors the current `Workspace.aggregateStatus()` logic, scanning `tab_status[0..tab_count]` for worst status
  - Add `pub fn hasAttention(self: *const PaneContainer) bool` — returns true if any `tab_attention[0..tab_count]` is true
  - Add `pub fn focus(self: *const PaneContainer) void` — convenience to call `self.tabs[self.active_tab].focus()` if tab_count > 0

- [x] Restructure the `Workspace` struct in `src/apprt/win32/Window.zig`. Remove all 11 per-tab parallel arrays and their associated fields from Workspace, replacing them with a PaneContainer-based architecture:
  - Remove these fields from Workspace: `tab_count`, `active_tab`, `tab_trees`, `tab_active_pane`, `tab_titles`, `tab_title_lens`, `tab_status`, `tab_attention`, `tab_status_text`, `tab_status_text_len`, `tab_progress`, `tab_log`, `tab_synchronized`
  - Remove the `tabArrays()` method from Workspace
  - Remove the `aggregateStatus()` method from Workspace (it moves to PaneContainer)
  - Remove the `findHandle()` method from Workspace (no longer needed — PaneContainers don't have split trees within tabs)
  - Add `split_tree: SplitTree(PaneContainer) = .empty` — the workspace's single split tree whose leaves are PaneContainers
  - Add `focused_container: ?*PaneContainer = null` — the currently focused PaneContainer (receives keyboard input, tab operations)
  - Add `pub fn containerCount(self: *const Workspace) usize` — returns the number of leaf PaneContainers by iterating `split_tree.iterator()` and counting leaves. This replaces `tab_count` at the workspace level for workspace-emptiness checks
  - Add `pub fn focusedContainerOrFirst(self: *Workspace) ?*PaneContainer` — returns `focused_container` if set, otherwise finds and returns the first leaf PaneContainer in the split tree via iterator. Returns null if empty
  - Add `pub fn findContainerOf(self: *Workspace, pane: *Pane) ?*PaneContainer` — search all PaneContainers' tab arrays to find which container owns a given pane. Iterate the split tree, for each leaf container check `tabs[0..tab_count]` for pointer equality with `pane`
  - Add `pub fn findContainerHandle(self: *Workspace, container: *PaneContainer) ?SplitTree(PaneContainer).Node.Handle` — find the split tree handle for a given PaneContainer by iterating and comparing with `eql`
  - The `aggregateStatus()` for the workspace (used by the sidebar) should now aggregate across all PaneContainers: iterate the split tree leaves, call `container.aggregateStatus()` on each, return worst
  - Add `const PaneContainer = @import("PaneContainer.zig")` to Window.zig imports
  - Update `const SplitTree` usage — the file already imports SplitTree, but now it needs both `SplitTree(Pane)` (still used within PaneContainer for... actually NO — PaneContainers don't use SplitTree internally). The workspace uses `SplitTree(PaneContainer)`. Individual Pane refs are still used by PaneContainer directly
  - Keep all workspace-level fields unchanged: `name`, `name_len`, `description`, `description_len`, `working_dir`, git metadata fields, `meta_token`

- [x] Update the `Loc` struct and all find/location functions in Window.zig to work with PaneContainers instead of tab indices:
  - Change `Loc` from `struct { ws: *Workspace, tab: usize }` to `struct { ws: *Workspace, container: *PaneContainer, tab: usize }` — where `container` is the PaneContainer that owns the pane, and `tab` is the tab index within that container
  - Update `findLoc(self: *Window, pane: *Pane) ?Loc` — instead of scanning `tab_active_pane` arrays and `tab_trees`, iterate each workspace's split tree leaves (PaneContainers), then scan each container's `tabs[0..tab_count]` for pointer equality with `pane`. Return `Loc{ .ws = ws, .container = container, .tab = tab_index }`
  - Update `findLocOfSurface(self: *Window, surface: *Surface) ?Loc` — same approach but compare `tabs[i].surface() == surface`
  - Update `getActivePane(self: *Window) ?*Pane` — get active workspace, get its focused container, return `container.activePane()`
  - Update `getActiveSurface(self: *Window) ?*Surface` — unchanged logic, just calls updated `getActivePane()`
  - Search for ALL callers of the old `Loc.tab` field and `findLoc`/`findLocOfSurface` throughout Window.zig and App.zig. Update each caller to use `loc.container` instead of indexing into workspace tab arrays. Key callers include: `closeSplitSurface`, `closeSplitPane`, `breakPane`, `closeTabMode`, `jumpToSurface`, `setTabTitle`, `setTabStatusText`, `setTabProgress`, `appendTabLog`, and IPC handlers in App.zig

- [x] Rewire tab creation functions to create tabs within PaneContainers instead of workspace tab arrays. These are the core tab mutation paths:
  - `addTabWithCommand(self, command, title)`: Instead of creating a SplitTree(Pane) and inserting into workspace tab arrays, create a Pane, then add it to the focused PaneContainer's tabs array using the existing `tabArraysInsertGap` helper (called on the container's `tabArrays()`). The insert position logic (`newTabInsertPos`) stays the same. If no focused container exists (empty workspace), create a new PaneContainer via `PaneContainer.create(alloc)`, add the pane as its first tab, and initialize the workspace split tree with `SplitTree(PaneContainer).init(alloc, container)`. Set `ws.focused_container = container`. The title, status, and metadata initialization stays identical but writes to `container.tab_titles[pos]`, etc.
  - `addTabBackground(self, ws_idx, command, title)`: Same pattern but targets a specific workspace. If that workspace's focused container exists, add to it. Otherwise create a new PaneContainer. Don't switch focus.
  - `addBrowserTab(self)`: Currently at line 1472. Same refactor — create BrowserPane, wrap in Pane, add to focused container's tabs.
  - `addTabInherit(self)` and `addTabInheritBackground(self, ws_idx)`: Search for these in the codebase and apply the same pattern. They inherit the current pane's command.
  - Remove the code that creates `SplitTree(Pane)` per tab (`SplitTree(Pane).init(alloc, pane)`) — in the new model, panes are stored directly in PaneContainer.tabs, not wrapped in per-tab split trees. Pane ref counting is managed by PaneContainer (ref on add, unref on remove).
  - Update `updateTabBarVisibility()` to check the focused container's tab_count instead of the workspace's old tab_count

- [x] Rewire tab closing and selection to operate on PaneContainers:
  - `closeTabByIndex(self, idx)`: Now closes tab `idx` in the focused PaneContainer of the active workspace. Use `tabArraysRemove` on the container's `tabArrays()`. Decrement `container.tab_count`. Call `pane.unref(alloc)` on the removed pane. If `container.tab_count` reaches 0, remove the PaneContainer from the workspace split tree (see split close logic below).
  - `closeTabInWorkspace(self, ws_idx, idx)`: Same but targets a specific workspace. The container is identified by finding the container that owns the tab at the given index — or change the API so the caller provides the container reference.
  - `closeTabInWorkspaceForIpc`: Update to route through the new closing logic.
  - `closeTabActiveFixup(new_count, active, idx)`: This pure function stays the same — it computes the post-close active tab index. Apply it to the container's `active_tab`.
  - `selectTabIndex(self, idx)`: Now sets `container.active_tab = idx` on the focused PaneContainer, hides the old tab's pane HWND, shows the new tab's pane HWND, calls `layoutSplits()` and focus. The hide/show logic currently done in `selectTabIndex` (which hides all panes of the old tab tree and shows all panes of the new tab tree) simplifies to hiding one pane and showing one pane (since each tab is a single pane, not a tree).
  - `moveTab(self, amount)` and `moveTabTo(self, from, to)`: Now operate on the focused PaneContainer's tab arrays via `tabArraysSwap`/shift. The logic is identical but uses `container.tabArrays()`.
  - `closeTab(self, pane)`: Find which container owns the pane, close that tab in that container. If container empties, remove from workspace tree.

- [x] Rework split operations to create/destroy PaneContainers in the workspace-level split tree. This is the core behavioral change — splits no longer create panes within a tab's tree, they create entirely new PaneContainers:
  - `newSplit(self, direction)`: Create a new PaneContainer with one fresh tab (a new terminal Surface). The new container is inserted into the workspace's `split_tree` next to the focused container:
    1. Find the focused container's handle in `ws.split_tree` via `ws.findContainerHandle(ws.focused_container)`
    2. Create new Surface, Pane, PaneContainer (container gets one tab)
    3. Create a temporary `SplitTree(PaneContainer)` for the new container
    4. Call `ws.split_tree.split(alloc, handle, direction, 0.5, &new_tree)` to get the updated tree
    5. Replace `ws.split_tree` with the new tree, deinit old
    6. Set `ws.focused_container = new_container` and focus it
    7. Call `layoutSplits()` to position all containers
  - `newSplitWithCommand(self, direction, command)`: Same but with explicit command
  - `newSplitInWorkspace(self, ws_idx, direction, command, focus)`: Generalized version targeting any workspace. The `tab_idx` parameter is no longer needed (remove it or ignore it). Split always targets the focused container of the specified workspace.
  - `closeSplitPane(self, pane)`: Find the container owning the pane. If the container has >1 tabs, just close that tab (call the tab-close logic). If the container has exactly 1 tab:
    - If the workspace split tree has other containers (is split), remove this container from the tree, focus the neighbor, deinit the old tree
    - If this is the only container, close the workspace (or window if last workspace) — same as current "last tab of last workspace" logic
  - `closeSplitSurface(self, surface)`: Unchanged — finds pane from surface, calls `closeSplitPane`
  - `breakPane(self, pane)`: In the new model, "break pane" extracts a tab from a multi-tab PaneContainer into a NEW PaneContainer that becomes a new leaf in the workspace split tree. Find the container owning the pane, remove the pane's tab from it, create a new PaneContainer with that pane as its sole tab, insert the new container into the workspace tree as a sibling split.

- [ ] Update layout and pane navigation for the new PaneContainer split tree:
  - `layoutSplits(self)`: Instead of walking `ws.tab_trees[ws.active_tab]`, walk `ws.split_tree` (a `SplitTree(PaneContainer)`). The `layoutNode` function needs a variant for PaneContainer leaves: when it reaches a leaf PaneContainer, it shows the active tab's pane HWND at the leaf's rect and hides all other tab panes. This means:
    - Rename or refactor `layoutNode` to handle `SplitTree(PaneContainer)` nodes
    - For a leaf node (PaneContainer): position `container.tabs[container.active_tab].hwnd()` at the rect, hide HWNDs of all other tabs in that container
    - For a split node: recursively lay out left/right children with appropriate rects (same gap logic as current)
    - Zoom support: if `ws.split_tree.zoomed` is set, show only the zoomed container's active tab pane full-bleed, hide everything else
  - `gotoSplit(self, goto_target)`: Navigate between PaneContainers in the workspace split tree. Find the focused container's handle, call `ws.split_tree.goto(alloc, handle, target)` to get the destination handle, extract the destination PaneContainer from the leaf node, set `ws.focused_container = dest_container`, and focus it
  - `swapSplit(self, swap_target)`: Find focused container handle, find destination handle via `goto`, call `ws.split_tree.swap(alloc, src, dst)` to get new tree, replace old tree, call `layoutSplits()`
  - `resizeSplit(self, rs)`: Find focused container handle, call `ws.split_tree.resize(alloc, handle, layout, delta)`, replace tree, `layoutSplits()`
  - `equalizeSplits(self)`: Call `ws.split_tree.equalize(alloc)`, replace tree, `layoutSplits()`
  - `selectLayout(self, layout)`: Call `ws.split_tree.selectLayout(alloc, layout)`, replace tree, `layoutSplits()`
  - `toggleSplitZoom(self)`: Operate on `ws.split_tree.zoomed` — same logic but on the workspace tree
  - `updateAttentionRings(self)`: Walk `ws.split_tree` leaves instead of `tab_trees[active_tab]` — position rings around PaneContainers that have attention
  - `updatePaneButtons(self)`: Walk `ws.split_tree` leaves for the per-pane corner buttons
  - `paintDividers(self, hdc)`: Walk `ws.split_tree` to find split positions for divider lines

- [ ] Update the tab bar rendering in `paintTabBar` to read from the focused PaneContainer instead of workspace tab arrays:
  - Get the focused PaneContainer via `ws.focusedContainerOrFirst()` instead of reading `ws.tab_count`, `ws.tab_titles`, etc.
  - Replace all `ws.tab_count` references with `container.tab_count`
  - Replace all `ws.tab_titles[i]` with `container.tab_titles[i]`
  - Replace all `ws.tab_title_lens[i]` with `container.tab_title_lens[i]`
  - Replace all `ws.active_tab` with `container.active_tab`
  - Replace all `ws.tab_status[i]` with `container.tab_status[i]`
  - Replace all `ws.tab_attention[i]` with `container.tab_attention[i]`
  - Replace all `ws.tab_synchronized[i]` with `container.tab_synchronized[i]`
  - `handleTabBarClick` and `handleTabBarMouseMove`: same replacements — use focused container
  - `updateTabBarVisibility()`: show tab bar when focused container has >1 tab, hide when <=1 (same as current logic but reading from container)
  - `updateWindowTitle()`: read title from focused container's active tab
  - For now, keep a single tab bar at the top of the window (per-pane tab bars are Phase 02). The tab bar always shows the focused container's tabs.

- [ ] Update workspace creation, closing, and selection to initialize/tear down PaneContainers:
  - When creating a new workspace (`addWorkspace` / workspace-new IPC): create an initial PaneContainer with one tab (terminal Surface), init the workspace split tree with it, set `focused_container`
  - `closeWorkspace(self, ws_idx)`: iterate the workspace's split tree leaves and call `container.unref(alloc)` on each (which cascades to unref all panes). Then deinit the split tree. Shift workspace arrays as before.
  - `selectWorkspace(self, ws_idx)`: hide all panes of the old workspace (iterate old workspace's split tree leaves, hide each container's active tab HWND). Show panes of the new workspace via `layoutSplits()`. Ensure `ws.focused_container` is valid.
  - Sidebar rendering that reads workspace status: update to iterate PaneContainers instead of old tab arrays. The sidebar dot aggregation (`aggregateStatus`) now iterates containers.
  - `selectTabIndex` callers that switch both workspace and tab: ensure they switch workspace first, then operate on the new workspace's focused container

- [ ] Build the project and fix all compilation errors. Work through each error methodically:
  - Run `zig build` (or the project's build command — check `build.zig` for the build configuration)
  - Fix type mismatches where code still references old Workspace fields (`tab_trees`, `tab_active_pane`, `tab_count`, `active_tab`, etc.)
  - Fix references to `Loc.tab` that need updating to `Loc.container` + `Loc.tab`
  - Fix `SplitTree(Pane)` references that should now be `SplitTree(PaneContainer)` at the workspace level
  - Ensure PaneContainer.zig is added to the build (check if there's an explicit file list or if the build auto-discovers)
  - After clean compilation, run the app and verify:
    - App launches with one workspace, one PaneContainer, one tab
    - Creating a new tab (Ctrl+Shift+T or "+" button) adds a tab within the same PaneContainer
    - Closing a tab removes it from the PaneContainer
    - Splitting (Ctrl+Shift+Enter or equivalent) creates a NEW PaneContainer with its own tab
    - Tab bar shows the focused PaneContainer's tabs
    - Clicking on a split pane focuses that PaneContainer and updates the tab bar
    - Split navigation (Ctrl+arrow or similar) moves between PaneContainers
    - Closing the last tab in a PaneContainer removes it from the split tree and focuses the neighbor
