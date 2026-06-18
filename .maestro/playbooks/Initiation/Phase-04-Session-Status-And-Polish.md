# Phase 04: Session Save/Restore, Status Propagation, and Polish

This final phase completes the rearchitecture by updating session persistence, status/attention propagation, synchronized input, and all remaining edge cases. By the end, the full Workspace → PaneContainer → Tab hierarchy is production-ready with all features working correctly.

## Tasks

- [x] Update `src/apprt/win32/SessionState.zig` to save and restore the new hierarchy. The current session model is `SessionData { workspaces: [WorkspaceData { tabs: [TabData { tree: SplitNodeData }] }] }`. Change it to reflect Workspace → PaneContainer split tree → Tabs:
  - Add a new `PaneContainerData` struct: `{ tabs: []TabData, active_tab: usize }` where each `TabData` is `{ title: ?[]const u8, kind: PaneKind, cwd: ?[]const u8 }`. Remove the `tree: ?SplitNodeData` field from `TabData` since tabs no longer have split trees.
  - Change `WorkspaceData` to contain a split tree of PaneContainers: `{ name: ?[]const u8, split_tree: ?SplitNodeData, active_container: usize, working_dir: ?[]const u8 }` where `SplitNodeData` leaves reference `PaneContainerData` instead of `PaneData`. Add a `container: ?PaneContainerData` field to `SplitNodeData` for leaf nodes (replacing the old `pane` field).
  - Update the `save` function: walk the workspace's `SplitTree(PaneContainer)` recursively. For each leaf (PaneContainer), serialize its tabs array. For each split node, serialize direction and ratio with left/right children. Save the focused container index.
  - Update the `restore` function: parse the new JSON structure. For each workspace, recursively rebuild the `SplitTree(PaneContainer)` from the serialized tree. For each PaneContainerData, create a PaneContainer, then create tabs within it (using `addTabWithCommand` or equivalent). The existing limitation (v1: complex trees not reconstructed) can be relaxed — since the tree is now at the workspace level and each leaf is just a PaneContainer with simple tabs, full tree reconstruction is simpler.
  - Handle backward compatibility: if the session file has the old format (tabs with split trees), gracefully migrate by creating one PaneContainer per old tab and putting them all in a flat (unsplit) workspace. Log a warning about format upgrade.

- [x] Update synchronized input for the PaneContainer model. Currently `tab_synchronized[tab]` broadcasts keyboard input to all terminal panes in a tab's split tree. In the new model, each tab in a PaneContainer is a single pane (no split tree within tabs), so "synchronized within a tab" doesn't make sense. Rethink synchronized input for the new hierarchy:
  - Option A (per-container sync): when `container.tab_synchronized` is true for the active tab, broadcast input to all OTHER tabs' panes within the same PaneContainer. This lets you type into multiple terminals within one container simultaneously.
  - Option B (workspace-level sync): broadcast input to the active pane of ALL PaneContainers in the workspace. This matches the old "all panes in a tab" behavior but at the workspace level.
  - Implement Option A (per-container) as it most closely matches the intent — synchronized input within a logical group:
    - When the focused container's active tab has `tab_synchronized` set, find all other terminal panes in `container.tabs[0..container.tab_count]` and write the input to their PTYs
    - The sync indicator (⇄) in the tab bar shows per-tab
    - Toggle via the existing keybinding or IPC command
  - Update the `handleKeyInput` or equivalent input dispatch to check `container.tab_synchronized[container.active_tab]` instead of `ws.tab_synchronized[ws.active_tab]`

- [x] Update attention and status propagation for the new hierarchy. Attention flows from Surface → Pane → PaneContainer → Workspace → Sidebar:
  - When a Surface sets its attention flag (OSC sequence or `+notify ring`): find the owning PaneContainer via `findLoc`, set `container.tab_attention[loc.tab] = true`. Then check if the container is the focused container AND the tab is the active tab — if so, the user is already looking at it, so clear the flag immediately. Otherwise leave it set.
  - Clearing attention: when a tab becomes active (`selectTabIndex`), clear `container.tab_attention[container.active_tab]`. When a container becomes focused, clear the active tab's attention.
  - Workspace-level attention for the sidebar: `ws.aggregateStatus()` and attention aggregation should iterate all PaneContainers' tabs. The sidebar dot shows if ANY tab in ANY container has attention or non-normal status.
  - Tab bar rendering already reads `container.tab_attention[i]` (done in Phase 02). Verify the blue attention dot appears on the correct tabs in the correct containers.
  - Status text (`tab_status_text`): set per-tab per-container via IPC. The sidebar can show the focused container's active tab's status text, or aggregate. Keep it simple — show focused container's active tab status.
  - Progress (`tab_progress`): same pattern — per-tab per-container. Sidebar shows focused container's active tab progress.
  - Log (`tab_log`): per-tab per-container. Sidebar shows focused container's active tab's latest log line.

- [x] Update `breakPane` and `closeTabMode` for the new architecture:
  - `breakPane(self, pane)`: in the new model, "break pane" should extract a tab from a multi-tab PaneContainer into a NEW PaneContainer. Find the container owning the pane via `findLoc`. If the container has only 1 tab, this is a no-op (can't break the only tab). Remove the pane's tab from the source container (shift arrays, decrement tab_count). Create a new PaneContainer with that pane as its sole tab. Insert the new container into the workspace split tree as a sibling of the source container (split in a default direction, e.g., right). Focus the new container. Call `layoutSplits()`.
  - `closeTabMode(self, mode, surface)`: currently supports `.this` (close this tab), `.other` (close all other tabs), `.right` (close tabs to the right). In the new model:
    - `.this`: close the pane's tab in its container — same as `closeSplitPane`
    - `.other`: within the same PaneContainer, close all tabs except the one containing this surface. Iterate tabs in reverse, close each that isn't the current one.
    - `.right`: within the same PaneContainer, close all tabs to the right of the current one. Iterate from end toward current+1, close each.
  - These modes operate WITHIN a PaneContainer (not across containers). Cross-container close-all would be a different operation.

- [x] Update the sidebar rendering in `src/apprt/win32/Sidebar.zig` (or wherever the sidebar is rendered) to correctly reflect PaneContainer state:
  - Each workspace sidebar row should aggregate status across ALL PaneContainers in that workspace, not just one container
  - The sidebar dot color (normal/bell/exited) comes from the worst status across all containers' tabs
  - The sidebar workspace name, description, git branch, ports, and PR state remain workspace-level (unchanged)
  - If the sidebar shows a tab count or tab list preview per workspace, update to show the total tab count across all containers, or the focused container's tab count — whichever makes more sense for the UX
  - The sidebar's status text line (agent-pushed label) should show the focused container's active tab's status text — this is the most relevant information for the user
  <!-- Already implemented in prior phases: Workspace.aggregateStatus() and hasAttention() walk the split_tree of PaneContainers; firstStatusText() prioritizes focused container's active tab; sidebar paint() uses these workspace-level methods; no tab count is shown in the sidebar. All sidebar tests pass. -->

- [ ] Handle keyboard shortcuts and action dispatch for the new hierarchy. Search Window.zig for all action handlers that reference the old tab/split model and verify they work correctly:
  - `Ctrl+Shift+T` (new tab): creates tab in focused container — verify
  - `Ctrl+W` or `Ctrl+Shift+W` (close tab/pane): closes focused container's active tab — verify
  - `Ctrl+Tab` / `Ctrl+Shift+Tab` (next/prev tab): cycles tabs within focused container — verify
  - `Ctrl+Shift+Enter` (new split): creates new PaneContainer — verify
  - `Ctrl+Shift+Arrow` or `Alt+Arrow` (navigate between splits): navigates between PaneContainers — verify
  - `Ctrl+Shift+[/]` (resize split): resizes between PaneContainers — verify
  - `Ctrl+Shift+Z` (toggle zoom): zooms the focused PaneContainer — verify
  - Tab rename (F2 or double-click): targets the correct tab in the focused container — verify
  - Search for any action handlers that still reference `ws.tab_trees`, `ws.tab_active_pane`, `ws.tab_count`, or `ws.active_tab` — these are bugs. Fix each one to use the PaneContainer.

- [ ] Final integration testing and edge case verification:
  - Test the full lifecycle: launch → create tabs → split → create tabs in each split → close tabs → close splits → only one container left → app returns to single-pane mode
  - Session persistence: save session with multiple workspaces, each with splits and multiple tabs per container. Restart app. Verify restore recreates the layout.
  - Stress test: create 5+ PaneContainers with 10+ tabs each. Verify rendering, scrolling, and interaction remain responsive. Verify memory usage is reasonable.
  - Browser tabs: create browser tabs in different PaneContainers. Navigate between them. Verify WebView2 rendering is correct in each container.
  - Quick terminal mode (if supported): verify it still works with the new architecture. Quick terminal typically has a single workspace with a single pane.
  - Multiple windows (if supported): verify each window independently manages its own workspace/PaneContainer hierarchy.
  - DPI scaling: verify per-pane tab bars render correctly at different DPI scales and when the window moves between monitors with different DPI.
  - Verify the CLAUDE.md wmux command documentation still accurately describes the hierarchy (Workspace → Panes → Tabs). Update if needed: the commands like `wmux +tab list` now implicitly target the focused pane's tabs.
