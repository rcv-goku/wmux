# Phase 02: Per-Pane Tab Bar Rendering

With Phase 01's rearchitecture complete, each PaneContainer owns its own tabs — but the tab bar still renders at the window top showing only the focused container's tabs. This phase adds per-pane tab bars: when the workspace has multiple PaneContainers (splits), each one draws its own tab bar above its content area. When there's only one PaneContainer (no splits), the tab bar stays at the window top — visually identical to the pre-rearchitecture single tab bar, matching cmux's single-pane behavior.

## Tasks

- [x] Add a per-PaneContainer tab bar rendering method to `PaneContainer.zig`. Create `pub fn paintTabBar(self: *const PaneContainer, hdc: w32.HDC, rect: w32.RECT, scale: f32, config: anytype, is_focused: bool, tab_font: ?*anyopaque, hovered_tab: ?usize, hovered_close: ?usize) void` that draws a tab bar within the given rect. Extract the core tab-painting logic from `Window.paintTabBar` into this method:
  - The rect parameter defines the full area allocated to this PaneContainer — the tab bar occupies the top portion (same height calculation as current `tabBarHeight()`)
  - Draw the tab bar background, tab items (title, attention dot, sync indicator, close button) using the same colors and styling as the current `paintTabBar`
  - The `is_focused` parameter controls whether the tab bar renders with the focused visual treatment (brighter text, accent underline on active tab) or a dimmed unfocused treatment (all text at inactive opacity, no accent underline)
  - Return the tab bar height actually drawn (0 if the container has <=1 tab and the tab bar is hidden), so the caller knows how much vertical space the tab bar consumed
  - Store hit-test rects in PaneContainer for per-container click handling — add `tab_rects: [MAX_TABS]w32.RECT = undefined` and `tab_rect_count: usize = 0` fields, plus `new_tab_btn_rect: w32.RECT = undefined` and `close_btn_rects: [MAX_TABS]w32.RECT = undefined` for the "+" button and per-tab close buttons

- [x] Modify `layoutSplits` in Window.zig to account for per-pane tab bar height. When laying out PaneContainer leaves in the split tree:
  - For each leaf PaneContainer, if it has >1 tab (tab bar visible), subtract `tabBarHeight()` from the top of the allocated rect. The tab bar occupies `rect.top` to `rect.top + bar_h`, and the content pane occupies `rect.top + bar_h` to `rect.bottom`
  - Store the full rect (including tab bar area) on the PaneContainer for later use in painting and hit-testing — add a `layout_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }` field to PaneContainer
  - Position the active tab's pane HWND at the content rect (below the tab bar), not the full rect
  - When there's only ONE PaneContainer in the workspace (no splits), DO NOT subtract tab bar height from the container's rect — the window-level tab bar at the top handles rendering. Set a flag or check `ws.split_tree.isSplit()` to distinguish this case

- [x] Replace the window-level `paintTabBar` with a dispatch that routes to per-container rendering when splits exist:
  - If the workspace has only one PaneContainer (no splits): render using the existing window-top tab bar position and logic (delegates to the container's `paintTabBar` using the window-top rect). This preserves the current single-pane visual appearance exactly.
  - If the workspace has multiple PaneContainers (splits): skip the window-top tab bar entirely. Instead, during `WM_PAINT` / paint handling, iterate all PaneContainer leaves and call each container's `paintTabBar` using their `layout_rect`. Each container draws its own tab bar within its allocated space.
  - Update `updateTabBarVisibility()`: when splits exist, the window-level `tab_bar_visible` should be false (no window-top bar). Each container manages its own tab bar visibility internally based on its `tab_count`.
  - The content area calculation (`surfaceRect()`) should not subtract tab bar height when splits exist — each container handles its own internally.

- [x] Update tab bar hit-testing for per-pane tab bars. When the workspace has splits, clicks need to route to the correct PaneContainer's tab bar:
  - `handleTabBarClick(self, x, y)`: if splits exist, iterate PaneContainer leaves and find which container's `layout_rect` top strip contains the click point (y is within `layout_rect.top` to `layout_rect.top + bar_h`). Then check that container's `tab_rects` for the specific tab clicked. Set that container as `ws.focused_container`, then perform the tab action (select, close, new).
  - `handleTabBarMouseMove(self, x, y)`: same routing — find which container's tab bar the mouse is over, update hover state for that container only. Clear hover state for all other containers.
  - If no splits, the existing window-top hit-testing works as before (single container).
  - Add per-container hover tracking: `hovered_tab_idx: ?usize = null` and `hovered_close_idx: ?usize = null` fields on PaneContainer. The Window's global `hovered_tab` fields are only used in single-pane mode.

- [x] Add visual focus indicator for multi-pane mode. When multiple PaneContainers are visible, the user needs to see which one is focused:
  - The focused container's tab bar renders with full brightness (active text color, accent underline on selected tab) — matching current single-pane appearance
  - Unfocused containers' tab bars render dimmed (all tabs at inactive text color, no accent underline, slightly darker background)
  - When a user clicks anywhere within a PaneContainer's area (tab bar or content), that container becomes focused: set `ws.focused_container = clicked_container`, invalidate all tab bars for repaint
  - The focus indicator integrates with the existing surface focus handling: when a terminal Surface receives `WM_SETFOCUS`, trace back to its PaneContainer and set it as focused

- [ ] Handle tab bar visibility edge cases and transitions:
  - When a container's tab_count drops from 2 to 1 (tab closed): if splits exist, the per-pane tab bar disappears and the content pane expands to fill the full container rect. Call `layoutSplits()` to reposition.
  - When a container's tab_count increases from 1 to 2 (tab added): if splits exist, the per-pane tab bar appears and the content pane shrinks. Call `layoutSplits()`.
  - When the last split is removed (back to single PaneContainer): transition from per-pane tab bars to the window-top tab bar. The content area calculation switches back to using `surfaceRect()` with tab bar height subtracted.
  - When the first split is created (single → multi PaneContainer): transition from window-top tab bar to per-pane tab bars. Hide the window-top bar, each container draws its own.
  - Tab bar inline rename (the edit control for renaming tabs): when splits exist, position the edit control within the correct PaneContainer's tab bar rect, not the window-top bar.

- [ ] Test per-pane tab bar rendering with various configurations:
  - Single pane, 1 tab: no tab bar visible (same as current)
  - Single pane, 3 tabs: tab bar at window top (same as current)
  - Two panes side-by-side (horizontal split), each with 1 tab: no tab bars visible in either pane
  - Two panes side-by-side, left has 3 tabs, right has 1 tab: left pane shows tab bar, right pane does not
  - Two panes stacked (vertical split), both with 2+ tabs: both show tab bars
  - Three-way split (one split, then split again): all containers with >1 tab show tab bars
  - Focus switching: clicking between panes updates which tab bar is highlighted
  - Tab operations in split mode: new tab, close tab, select tab, rename tab all work correctly within the targeted PaneContainer
  - Verify no rendering artifacts at tab bar boundaries (no pixel gaps, no overlap with content)
