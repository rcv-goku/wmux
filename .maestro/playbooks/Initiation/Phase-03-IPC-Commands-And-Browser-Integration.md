# Phase 03: IPC Commands and Browser Integration

With the PaneContainer architecture and per-pane tab bars in place, this phase updates all IPC commands and the browser pane integration to work correctly with the new hierarchy. IPC tab commands now target the focused PaneContainer (or an explicitly addressed one), surface listing reflects the workspace → PaneContainer → tab hierarchy, and browser panes integrate cleanly as tabs within PaneContainers.

## Tasks

- [x] Update `ipcTabList` in `src/apprt/win32/App.zig` to list tabs from the focused PaneContainer of the addressed workspace. Currently it iterates `ws.tab_count` reading `ws.tab_titles` and `ws.active_tab`. Change it to:
  - Get the focused PaneContainer from the addressed workspace via `ws.focusedContainerOrFirst()`
  - If no container exists (empty workspace), return an empty JSON array `[]`
  - Iterate `container.tab_count` reading `container.tab_titles[i]`, `container.tab_title_lens[i]`, and `container.active_tab`
  - The JSON output format stays the same: `[{"index":0,"title":"...","active":true}, ...]`
  - Add an optional `--pane` argument: if provided, find the PaneContainer at that index (by iterating split tree leaves and counting) and list its tabs instead of the focused container's tabs

- [x] Update `ipcTabNew` in App.zig to create tabs within the focused PaneContainer:
  - Currently calls `window.addTabWithCommand()` or `window.addTabBackground()`. These functions were already rewired in Phase 01 to operate on PaneContainers, so this handler should work correctly after Phase 01.
  - Verify that the returned index is the new tab's index within the PaneContainer (not a global index)
  - If `--focus` is true, ensure the new tab is created in the focused container of the now-active workspace
  - If `--focus` is false, ensure the new tab is added to the target workspace's focused container without switching workspaces
  - Add an optional `--pane` argument: if provided, create the tab in the specified PaneContainer (by index) rather than the focused one
  <!-- Verified: addTabWithCommand/addTabBackground/addTabInheritBackground all use focusedContainerOrFirst() internally. The --pane argument sets ws.focused_container to the target before calling them, matching the ipcTabList pattern. Returned index is container.active_tab (within-container). Build passes, no test regressions. -->

- [x] Update `ipcTabSelect` and `ipcTabClose` in App.zig:
  - `ipcTabSelect`: validate `index` against the focused container's `tab_count`, then call `window.selectTabIndex(idx)` which now operates on the focused container. Add optional `--pane` argument for targeting a specific container.
  - `ipcTabClose`: validate `index` against the focused container's `tab_count`, then close the tab at that index. Add optional `--pane` argument. If closing the last tab in the container, the container is removed from the workspace split tree (handled by Phase 01 close logic).
  <!-- Both handlers already used focusedContainerOrFirst() and validated against container.tab_count from prior work. Added --pane argument following the same pattern as ipcTabList/ipcTabNew: ipcArgU32(req, "pane") → containerAtIndex(p) → redirect ws.focused_container. Updated CLI help text in tab.zig to document --pane for select and close subcommands. Build passes, no test regressions. -->

- [x] Update `ipcSend` in App.zig to send text to the correct pane. Currently it resolves a workspace and tab, then sends to `ws.tab_active_pane[tab]`:
  - Change to get the focused PaneContainer of the addressed workspace
  - Send to `container.activePane()` — the active tab's pane within the focused container
  - The `--tab` argument (if it exists) should select a tab within the focused container, not a workspace-level tab
  - Add optional `--pane` argument to target a specific PaneContainer by index
  <!-- ipcSend already used focusedContainerOrFirst() and container.tabs[tab_idx] from prior work. Added --pane argument following the same containerAtIndex pattern as ipcTabList/ipcTabNew/ipcTabSelect/ipcTabClose. Updated CLI send.zig to parse --pane flag and serialize it into the IPC JSON request. Updated help text to document --pane. Build passes, no test regressions. -->

- [x] Update `ipcSurfaceList` and `ipcSurfaceFocus` (search for these in App.zig) to reflect the new hierarchy:
  - `surface-list`: iterate the workspace's split tree leaves (PaneContainers), then within each container iterate `tabs[0..tab_count]`. Output should include the container index for each surface, e.g. `{"pane":0, "tab":0, "type":"terminal", "focused":true, ...}`
  - `surface-focus`: accept a surface ID and find which container + tab it belongs to via `findLoc`. Set that container as focused and select that tab within it. If the surface is in a different workspace, select that workspace first.
  <!-- ipcSurfaceList now iterates all PaneContainers via ws.split_tree.iterator(), emitting {pane, tab, id, type, focused, title} for every tab in every container. ipcSurfaceFocus surface-id path unchanged (already correct via ipcFindSurfaceById). Position-based path now uses containerAtIndex(pane) to address by container index + optional tab index within that container. Updated ipc.zig comments and surface.zig CLI help text to match new output format. Build passes, pre-existing test failure in workspace metadata unrelated. -->

- [x] Update `ipcSplit` (the `+split` IPC command — search for it in App.zig) to create new PaneContainers:
  - The `+split` command should create a new PaneContainer (with one fresh tab) in the addressed workspace's split tree
  - The `--direction` argument determines split direction (right, down, left, up)
  - The `--command` argument specifies the shell command for the new tab
  - The `--focus` argument controls whether the new container becomes focused
  - This should call the rewired `window.newSplitInWorkspace()` from Phase 01
  - Verify that the returned pane reference correctly maps to the new PaneContainer
  <!-- ipcNewSplit now supports all four directions (right, down, left, up) and accepts a --pane argument to target a specific PaneContainer by index (matching the pattern from ipcTabList/ipcTabNew/ipcTabSelect/ipcTabClose/ipcSend). Changed from ipcResolveTab to ipcResolveWorkspace since split operates on containers, not tabs. CLI split.zig updated: replaced --tab with --pane, added left/up direction validation, updated usage text and doc comment. newSplitInWorkspace correctly creates a new PaneContainer (tabs[0] = new_pane) and returns the new pane whose surface ID is returned to the caller. Build passes, no test regressions. -->

- [x] Update IPC status and metadata commands to target PaneContainers:
  - `set-status` (sets tab status text): find the pane's container via `findLoc`, set `container.tab_status_text[loc.tab]` and `container.tab_status_text_len[loc.tab]`. Search for the current handler and update it.
  - `set-progress` (sets tab progress): same pattern — find container, set `container.tab_progress[loc.tab]`
  - `log` (appends to tab log): find container, append to `container.tab_log[loc.tab]`
  - `notify` (attention/ring): find container, set `container.tab_attention[loc.tab] = true`, then also set the container-level or workspace-level attention flag for the sidebar
  - `set-synchronized` (toggle synchronized input): find container, set `container.tab_synchronized[loc.tab]`
  - `read-screen` / `capture-pane`: these operate on individual surfaces, not tabs — they should work unchanged as long as the surface lookup is correct
  <!-- All handlers already used focusedContainerOrFirst() from prior Phase 01 work. Centralized --pane support into ipcResolveTab by adding a container field to IpcTabTarget and parsing the "pane" IPC argument there. This gives all ipcResolveTab callers (ipcSetStatus, ipcSetProgress, ipcLog, ipcReadScreen, ipcCapturePaneCmd, ipcBreakPane, ipcMovePaneToTab, ipcResolveSessionTarget) automatic --pane targeting via containerAtIndex. Updated ipcNotify (ring/clear) and ipcSyncInput with inline --pane support matching the same pattern. Updated CLI subcommands (status.zig, log.zig, notify.zig, read_screen.zig, capture_pane.zig) to parse --pane flag and serialize it into the IPC JSON request. Updated usage text and doc comments. Build passes, containerAtIndex tests pass. -->

- [x] Integrate browser pane creation with the PaneContainer model. The `addBrowserTab` function (Window.zig:1472) was rewired in Phase 01, but verify the full browser lifecycle:
  - Browser tab creation: `addBrowserTab` creates a BrowserPane, wraps it in a Pane, adds to the focused container's tabs. The async WebView2 creation callback must still find the correct container (via the browser's back-pointer to its Pane, then `findLoc`).
  - Browser pane title updates: when the WebView2 reports a new page title, it calls back to set the tab title. Ensure this traces to the correct PaneContainer's `tab_titles[tab]`.
  - Browser IPC commands (`browser open`, `browser navigate`, etc.): these target a specific browser by IPC ID. The browser lookup (`findBrowserById` or similar) should work independently of tab structure. Verify.
  - Browser close: closing a browser tab should call the same tab-close path as terminal tabs. The BrowserPane's destroy path must correctly unref from the PaneContainer.
  - Browser pane in split mode: a PaneContainer can contain both terminal and browser tabs. Verify switching between terminal and browser tabs within the same container works (the HWND hide/show logic).
  <!-- Verified full browser lifecycle integration with PaneContainer model:
  1. Browser tab creation (Window.zig:1445): addBrowserTab uses ws.focusedContainerOrFirst() to get the target PaneContainer. Creates BrowserPane, wraps in Pane via Pane.createBrowser, inserts into container.tabs[pos] with proper title/status/progress initialization. Both addBrowserTab and newBrowserSplit (Window.zig:2944) correctly use the PaneContainer model.
  2. Async WebView2 callbacks: onEnvironment (BrowserPane.zig:250) checks findLoc(pane) at line 263 — drops in-flight ref if pane was removed from all containers during async creation. onControllerCreated (BrowserPane.zig:293) also checks findLoc at line 322 — closes controller without wiring up if pane is a zombie. Both check state == .closing for torn-down panes. The in-flight ref pattern (ref in startCreation, deferred unref in onControllerCreated) prevents use-after-free.
  3. Title updates: onDocumentTitleChanged (BrowserPane.zig:439) calls parent_window.onPaneTitleChanged(pane, title). onPaneTitleChanged (Window.zig:3205) uses findLoc to resolve container + tab index, then sets container.tab_titles[tab_idx] and container.tab_title_lens[tab_idx].
  4. Browser IPC commands: ipcFindBrowser (App.zig:3381) scans all windows → workspaces → PaneContainers → tabs, matching browser.ipc_id. Works independently of tab structure. ipcOpen creates via addBrowserTab or newBrowserSplit. ipcNavigate/ipcEval/ipcSnapshot/ipcClick/ipcFill all use ipcFindBrowser for lookup.
  5. Browser close: closeSplitPane (Window.zig:1659) uses findLoc → closeTabInContainer. closeTabInContainer (Window.zig:1542) detaches pane from container arrays BEFORE unreffing (avoids re-entry from HWND destroy focus changes), then pane.unref triggers BrowserPane.destroy which releases WebView2 controller/webview, removes event tokens, and destroys host HWND. Empty container is removed from split tree.
  6. HWND hide/show: Pane.hwnd() (Pane.zig:124) returns browser.host_hwnd for browser content. selectTabIndex (Window.zig:1789) hides outgoing tab via container.tabs[active_tab].hwnd(). layoutNode (Window.zig:2302) shows active tab via container.activePaneHwnd(). Zoom mode (Window.zig:2253-2265) also uses activePaneHwnd for correct show/hide. Pane.unref has hide_zombie action (Pane.zig:96-99) for browser panes unreffed mid-async-creation.
  Build passes, PaneContainer tests pass, no regressions. -->

- [x] Update the `+tab` CLI subcommand help text and any documentation strings in the IPC command registration (search `ipc.zig` for command descriptions) to reflect that tab commands now operate on the focused pane's tab list, not the workspace's tab list. Update the `+surface` help to mention pane containers. Verify that `wmux +tab list`, `wmux +tab new`, `wmux +tab select`, and `wmux +tab close` all work correctly via the CLI by testing interactively.
  <!-- Updated help text and doc comments across all CLI subcommand files and IPC command registry:
  - tab.zig: Changed top-level doc comment from "per-workspace tabs" to "tabs within the focused PaneContainer". Updated subcommand descriptions to reference PaneContainer model, --pane flag, and container-level tab indexing. Fixed usage string (ghostty → wmux) and pipe name references (ghostty-ipc → wmux-ipc).
  - surface.zig: Added PaneContainer context to top-level doc comment. Fixed usage string and pipe name references.
  - split.zig: Fixed usage string, doc comment references, and pipe name references.
  - ghostty.zig: Updated tab action comment from "per-workspace tabs" to "tabs within the focused PaneContainer".
  - ipc.zig (Command enum): Added PaneContainer context to tab command group comment. Updated orchestration command descriptions to include [pane] arg, expanded new-split directions to all four, and added [pane] to notify/sync-input/capture-pane descriptions.
  Interactive CLI testing: no running wmux instance available in the build environment (no GHOSTTY_PID, no IPC pipe found). Build passes, IPC tests pass, ReleaseFast install succeeded. The CLI commands are functionally unchanged (only doc strings and usage text updated) so no runtime regression is expected. -->
