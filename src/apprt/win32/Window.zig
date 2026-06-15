//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs. The Window manages the tab
//! bar, tab switching, and window-level state (fullscreen, DPI scale).
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const internal_os = @import("../../os/main.zig");

const App = @import("App.zig");
const AttentionRing = @import("AttentionRing.zig").AttentionRing;
const FlashOverlay = @import("FlashOverlay.zig").FlashOverlay;
const BrowserPane = @import("BrowserPane.zig");
const PaneButtonsMod = @import("PaneButtons.zig");
const PaneButtons = PaneButtonsMod.PaneButtons;
const Pane = @import("Pane.zig");
const RightSidebar = @import("RightSidebar.zig");
const Sidebar = @import("Sidebar.zig");
const Surface = @import("Surface.zig");
const SessionState = @import("SessionState.zig");
const WindowState = @import("WindowState.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const ipc = @import("ipc.zig");
const w32 = @import("win32.zig");

/// Maximum bytes of a per-tab status string (set-status). Inline, like
/// tab titles, so set-status never allocates; over-long text is byte
/// truncated by the setter.
const MAX_STATUS_BYTES: usize = 96;

/// Maximum bytes of a workspace's cached git branch name (Stage 2 sidebar
/// metadata). Inline so the async refresh result never allocates on apply;
/// over-long branch names are byte truncated.
pub const MAX_BRANCH_BYTES: usize = 64;

/// Maximum number of distinct listening TCP ports cached per workspace for
/// the sidebar metadata line. The walker dedups and caps at this; extra
/// ports are dropped (the row only has room for a few anyway).
pub const MAX_PORTS: usize = 8;

/// PR review/merge state cached per workspace from `gh pr view`. `none`
/// covers "no gh / not authed / no PR for the branch"; the sidebar only
/// renders a marker for the non-none states.
pub const PrState = enum { none, open, draft, merged, closed };

const log = std.log.scoped(.win32);

/// Maximum number of tabs per workspace.
const MAX_TABS: usize = 64;

/// Maximum number of workspaces per window.
const MAX_WORKSPACES: usize = 16;

/// Width (unscaled px) of the thin re-show strip painted at the window's
/// left edge while the sidebar is runtime-hidden. Clicking it (or Ctrl+B)
/// brings the sidebar back. Kept narrow so it barely covers the surface.
const RESHOW_STRIP_BASE: f32 = 8.0;

/// Per-tab status indicator shown in the session sidebar.
pub const TabStatus = enum { normal, bell, exited };

/// A workspace owns one set of the per-tab parallel arrays: a window
/// holds several workspaces (sidebar rows), each with its own top tab
/// bar. The arrays are indexed by tab position and MUST stay aligned —
/// every per-tab array is listed in tabArrays() so the shared
/// insert/remove/move/swap helpers keep them in lockstep at all
/// mutation sites. Slots MUST be value-initialized (`= .{}`), never left
/// `undefined`: the tab_status @splat default only applies on value-init,
/// and aggregateStatus()/paint read it.
pub const Workspace = struct {
    /// Number of tabs in this workspace.
    tab_count: usize = 0,
    /// Index of the currently active (visible) tab.
    active_tab: usize = 0,
    /// Tab split trees owned by this workspace (first parallel array).
    tab_trees: [MAX_TABS]SplitTree(Pane) = undefined,
    /// The currently focused pane within each tab.
    tab_active_pane: [MAX_TABS]*Pane = undefined,
    /// UTF-16 title buffers for each tab (for painting the tab bar).
    tab_titles: [MAX_TABS][256]u16 = undefined,
    /// Length of each tab title in UTF-16 code units.
    tab_title_lens: [MAX_TABS]u16 = undefined,
    /// Per-tab sidebar status. Cleared to .normal when the tab is selected.
    tab_status: [MAX_TABS]TabStatus = [_]TabStatus{.normal} ** MAX_TABS,
    /// Per-tab "needs attention" flag (the notification ring), separate
    /// from tab_status: a sticky "an agent here is waiting for input"
    /// state set by the attention OSC or `+notify ring`, NOT a transient
    /// bell/exited event. A tab's flag is the OR of its panes' Surface
    /// attention flags; it is cleared when the tab becomes the visible
    /// active tab (selectTabIndex/selectWorkspace), like tab_status. Must
    /// be @splat(false) on value-init (see the struct doc), which the
    /// `= @splat(false)` default guarantees alongside tab_status.
    tab_attention: [MAX_TABS]bool = @splat(false),
    /// Per-tab orchestration status string (set-status): a short
    /// agent-pushed label ("running tests", "waiting", "blocked") the
    /// sidebar renders. UTF-8 in an inline buffer (no alloc on push),
    /// length-prefixed like tab titles. Empty (len 0) = no status. Set by
    /// setTabStatusText; moves verbatim through tab-array shifts.
    tab_status_text: [MAX_TABS][MAX_STATUS_BYTES]u8 = undefined,
    tab_status_text_len: [MAX_TABS]u16 = @splat(0),
    /// Per-tab progress percent (set-progress), 0..100, or null for none.
    /// Rendered by the sidebar as a thin bar (Stage 2).
    tab_progress: [MAX_TABS]?u8 = @splat(null),
    /// Per-tab ring log buffer (log): the last few agent log lines, newest
    /// first. The sidebar surfaces the latest line as the row's
    /// "latest-notification" text (Stage 2). Pure ring lives in ipc.zig so
    /// the wrap/truncation rules are unit-tested there.
    tab_log: [MAX_TABS]ipc.LogRing = @splat(.{}),
    /// Per-tab synchronized input flag. When true, keyboard input to the
    /// focused pane is broadcast to all other terminal panes in the tab.
    tab_synchronized: [MAX_TABS]bool = @splat(false),
    /// Workspace name shown on its sidebar row.
    name: [64]u16 = undefined,
    /// Length of the workspace name in UTF-16 code units.
    name_len: u16 = 0,
    /// Optional workspace description shown below the name in the sidebar.
    /// UTF-16, inline like name (no allocation). Edited via the
    /// edit_workspace_description action or the IPC workspace-set-description
    /// command.
    description: [256]u16 = undefined,
    /// Length of the workspace description in UTF-16 code units.
    description_len: u16 = 0,
    /// Optional working directory this workspace's tabs spawn in (a git
    /// worktree bound via `+workspace new --worktree`). Owned heap copy,
    /// allocated by setWorkingDir and freed by freeWorkingDir. Null = the
    /// configured default (the inherited/home cwd, current behavior). The
    /// path is only consumed when a tab's surface config clone is built
    /// (addTabWithCommand), so it is moved verbatim through workspace-slot
    /// shifts (closeWorkspace) without re-validation.
    working_dir: ?[]const u8 = null,

    // --- Stage 2 orchestration metadata (sidebar second line) ----------
    // All best-effort, populated off the UI thread (git/gh/TCP table) and
    // applied via setMetadata; null/empty when unknown or not yet
    // refreshed. Inline fixed buffers (like name/status_text) so the async
    // apply never allocates and the values move verbatim through
    // workspace-slot shifts (closeWorkspace) exactly like name/working_dir.

    /// Cached git branch of working_dir (rev-parse --abbrev-ref HEAD).
    /// Empty (len 0) = unknown / not a worktree workspace.
    git_branch: [MAX_BRANCH_BYTES]u8 = undefined,
    git_branch_len: u8 = 0,
    /// Cached listening TCP ports of this workspace's tabs' child process
    /// trees, sorted ascending and deduped. ports[0..port_count] are live.
    ports: [MAX_PORTS]u16 = undefined,
    port_count: u8 = 0,
    /// Cached PR state + number for the branch (gh pr view), best-effort.
    pr_state: PrState = .none,
    pr_number: u32 = 0,
    /// Monotonic token stamped when an async metadata refresh job is
    /// dispatched for this workspace and echoed back in the result. The UI
    /// thread applies a result only if the token still matches, so a result
    /// for a since-recycled slot (closeWorkspace shifted a different
    /// workspace into this index) is dropped instead of mis-applied. Bumped
    /// by markMetadataDirty on dispatch.
    meta_token: u64 = 0,

    /// The parallel per-tab arrays as a tuple of array pointers. EVERY
    /// per-tab array must be listed here: the mutation sites
    /// (addTabWithCommand/addBrowserTab insert, closeTabByIndex remove,
    /// moveTabTo reorder, moveTab swap) all operate on this tuple via the
    /// tabArrays* helpers, so an array missing from this list silently
    /// desynchronizes from tab indices.
    pub fn tabArrays(self: *Workspace) struct {
        *[MAX_TABS]SplitTree(Pane),
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
            &self.tab_trees,
            &self.tab_active_pane,
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

    /// The worst status across this workspace's tabs, for the sidebar
    /// dot: exited > bell > normal.
    pub fn aggregateStatus(self: *const Workspace) TabStatus {
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

    /// Whether any of this workspace's tabs is flagged for attention (the
    /// notification ring). Drives the blue dot/ring on the workspace's
    /// sidebar row, orthogonal to aggregateStatus (a tab can be both
    /// "exited" and "waiting"). Pure over tab_attention[0..tab_count] so
    /// the cross-level surfacing rule is unit-testable.
    pub fn hasAttention(self: *const Workspace) bool {
        return aggregateAttention(self.tab_attention[0..self.tab_count]);
    }

    /// Set (or clear, when `text` is empty) the orchestration status
    /// string for tab `tab_idx`. UTF-8 byte-truncated to MAX_STATUS_BYTES.
    /// Caller validates tab_idx < tab_count. No allocation.
    pub fn setTabStatusText(self: *Workspace, tab_idx: usize, text: []const u8) void {
        const n: u16 = @intCast(@min(text.len, MAX_STATUS_BYTES));
        @memcpy(self.tab_status_text[tab_idx][0..n], text[0..n]);
        self.tab_status_text_len[tab_idx] = n;
    }

    /// The status string for tab `tab_idx` (empty when none).
    pub fn tabStatusText(self: *const Workspace, tab_idx: usize) []const u8 {
        return self.tab_status_text[tab_idx][0..self.tab_status_text_len[tab_idx]];
    }

    /// Set or clear (null) the progress percent for tab `tab_idx`. A value
    /// is clamped to 0..100.
    pub fn setTabProgress(self: *Workspace, tab_idx: usize, value: ?u8) void {
        self.tab_progress[tab_idx] = if (value) |v| @min(v, 100) else null;
    }

    /// Append a line to tab `tab_idx`'s ring log (newest-first; wraps).
    pub fn pushTabLog(self: *Workspace, tab_idx: usize, text: []const u8) void {
        self.tab_log[tab_idx].push(text);
    }

    /// The workspace description as a UTF-16 slice (empty when unset).
    pub fn descriptionSlice(self: *const Workspace) []const u16 {
        return self.description[0..self.description_len];
    }

    /// The cached git branch (empty when unknown). Stage 2 metadata.
    pub fn gitBranch(self: *const Workspace) []const u8 {
        return self.git_branch[0..self.git_branch_len];
    }

    /// Store the cached git branch, UTF-8 byte-truncated to the buffer.
    /// Empty `branch` clears it. No allocation.
    pub fn setGitBranch(self: *Workspace, branch: []const u8) void {
        const n: u8 = @intCast(@min(branch.len, MAX_BRANCH_BYTES));
        @memcpy(self.git_branch[0..n], branch[0..n]);
        self.git_branch_len = n;
    }

    /// The cached listening ports (ascending, deduped). Stage 2 metadata.
    pub fn portsSlice(self: *const Workspace) []const u16 {
        return self.ports[0..self.port_count];
    }

    /// Store the cached listening ports, capped at MAX_PORTS. `src` is
    /// expected sorted+deduped by the caller (the off-thread walker).
    pub fn setPorts(self: *Workspace, src: []const u16) void {
        const n: u8 = @intCast(@min(src.len, MAX_PORTS));
        @memcpy(self.ports[0..n], src[0..n]);
        self.port_count = n;
    }

    /// Store the cached PR state + number.
    pub fn setPrStatus(self: *Workspace, state: PrState, number: u32) void {
        self.pr_state = state;
        self.pr_number = number;
    }

    /// Reset Stage 2 metadata to its unknown state. Called when a tab is
    /// inserted into a fresh workspace and when a workspace slot is reused,
    /// so a recycled row never shows the previous occupant's branch/ports.
    pub fn resetMetadata(self: *Workspace) void {
        self.git_branch_len = 0;
        self.port_count = 0;
        self.pr_state = .none;
        self.pr_number = 0;
    }

    /// True when this workspace has any metadata worth a second sidebar
    /// line: a git branch, a listening port, a PR, or an agent status. Used
    /// to decide whether to render the taller two-line row.
    pub fn hasMetadata(self: *const Workspace) bool {
        if (self.description_len > 0) return true;
        if (self.git_branch_len > 0) return true;
        if (self.port_count > 0) return true;
        if (self.pr_state != .none) return true;
        for (0..self.tab_count) |t| {
            if (self.tab_status_text_len[t] > 0) return true;
        }
        return false;
    }

    /// Find the Node.Handle for a pane in this workspace's tab tree.
    pub fn findHandle(self: *Workspace, tab_idx: usize, pane: *Pane) ?SplitTree(Pane).Node.Handle {
        var it = self.tab_trees[tab_idx].iterator();
        while (it.next()) |entry| {
            if (entry.view == pane) return entry.handle;
        }
        return null;
    }

    /// Bind (or replace) this workspace's spawn working directory with an
    /// owned heap copy of `path`. Frees any previous binding first.
    pub fn setWorkingDir(self: *Workspace, alloc: Allocator, path: []const u8) Allocator.Error!void {
        const copy = try alloc.dupe(u8, path);
        if (self.working_dir) |old| alloc.free(old);
        self.working_dir = copy;
    }

    /// Release this workspace's working_dir binding, if any. Idempotent.
    /// Must be called exactly once per workspace whose slot is going away
    /// (window/workspace teardown), never on a slot whose value was moved
    /// into another live slot (closeWorkspace's shift).
    pub fn freeWorkingDir(self: *Workspace, alloc: Allocator) void {
        if (self.working_dir) |dir| {
            alloc.free(dir);
            self.working_dir = null;
        }
    }
};

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

/// A located tab: the workspace that owns it and its index within that
/// workspace. Returned by findLoc/findLocOfSurface.
pub const Loc = struct {
    ws: *Workspace,
    tab: usize,
};

/// What an in-progress inline rename writes back to. `.tab` is an index
/// into the active workspace's tab arrays; `.workspace` is an index into
/// the window's workspaces; `.description` edits a workspace's description.
pub const RenameTarget = union(enum) {
    tab: usize,
    workspace: usize,
    description: usize,
};

/// The parent App.
app: *App,

/// The top-level window handle.
hwnd: ?w32.HWND = null,

/// Workspaces owned by this window (sidebar rows). Each owns its own
/// set of per-tab parallel arrays and top tab bar. Slots MUST be
/// value-initialized before use (see Workspace doc comment); only
/// workspaces[0..workspace_count] are live.
workspaces: [MAX_WORKSPACES]Workspace = undefined,

/// Number of live workspaces.
workspace_count: usize = 0,

/// Index of the currently active (visible) workspace.
active_workspace: usize = 0,

/// Whether the tab bar is visible (shown when >1 tab).
tab_bar_visible: bool = false,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// Hit-test rectangles for each tab in the tab bar. Zero-initialized
/// so input handlers that read it before the first paint (e.g., a
/// synthetic WM_LBUTTONDOWN during startup) get a no-match instead of
/// stack garbage.
tab_rects: [64]w32.RECT = std.mem.zeroes([64]w32.RECT),

/// Hit-test rectangle for the "+" (new tab) button.
new_tab_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Hit-test rectangle for the "▾" (backend picker) segment beside the
/// new-tab button.
new_tab_dropdown_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Index of the tab currently being hovered (-1 = none).
hover_tab: isize = -1,

/// Whether the close button on the hovered tab is being hovered.
hover_close: bool = false,

/// Whether the "+" (new tab) button is being hovered.
hover_new_tab: bool = false,

/// Whether the "▾" (backend picker) segment is being hovered.
hover_new_tab_dropdown: bool = false,

/// Tab drag state: which tab is being dragged (-1 = none).
drag_tab: isize = -1,
/// Starting X position of the drag.
drag_start_x: i16 = 0,
/// Whether the drag has exceeded the threshold and is active.
drag_active: bool = false,

/// Sidebar row drag state: which session row is being dragged
/// (-1 = none). Mirrors drag_tab but tracks the cursor along Y to
/// reorder session rows. Reorders live via moveTabTo on each move.
sidebar_drag_row: isize = -1,
/// Starting Y position of the sidebar row drag, in client pixels.
sidebar_drag_start_y: i32 = 0,
/// Whether the sidebar row drag has exceeded the threshold and is
/// reordering (distinguishes a click-to-select from a drag).
sidebar_drag_active: bool = false,

/// Inline rename: Edit control HWND, font, and what is being renamed.
/// The same overlay Edit serves both a tab title (top tab bar
/// double-click) and a workspace name (sidebar row double-click); the
/// target union routes finishRename's text to the right store.
rename_edit: ?w32.HWND = null,
rename_font: ?*anyopaque = null,
rename_target: RenameTarget = .{ .tab = 0 },

/// Current sidebar hover target.
sidebar_hover: Sidebar.HitTarget = .none,

/// Whether the sidebar notifications panel (toggled by the footer
/// bell icon) is open.
notif_panel_open: bool = false,

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Saved window style for restoring from fullscreen.
saved_style: u32 = 0,

/// Saved window rect for restoring from fullscreen.
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Font used for painting the tab bar (Segoe UI).
tab_font: ?*anyopaque = null,

/// Whether WM_MOUSELEAVE tracking is active for the tab bar.
tracking_mouse: bool = false,

/// Whether this window is a quick terminal (borderless popup, no tabs).
is_quick_terminal: bool = false,

/// Set during init() when restoring persisted state asked for a
/// maximized window. Consumed (reset to false) the first time a tab
/// shows the window so the maximize is a true one-shot at initial
/// bring-up: ShowWindow uses SW_SHOWMAXIMIZED that one time, then
/// SW_SHOW thereafter. This matters because creating/selecting a
/// workspace re-enters the first-tab show path on a fresh
/// (tab_count==1) workspace; without consuming the flag every new
/// workspace would re-maximize the window. Always false for quick
/// terminals and non-first windows. Only the main window
/// persists/restores geometry.
restore_maximized: bool = false,

/// True once this window has persisted at least one good (non-degenerate)
/// placement during the session. Guards against a teardown-time
/// GetWindowPlacement returning a minimized/zero rect overwriting the
/// last good save. See savePlacement.
saved_placement_ok: bool = false,

/// Split divider drag state.
dragging_split: bool = false,
drag_split_handle: SplitTree(Pane).Node.Handle = .root,
drag_split_layout: SplitTree(Pane).Split.Layout = .horizontal,
drag_start_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Sidebar edge drag-resize state. The width override is in unscaled
/// pixels and wins over `window-sidebar-width` until the next config
/// reload (onConfigChange resets it so the config value re-applies).
sidebar_width_override: ?u32 = null,
dragging_sidebar: bool = false,

/// Session-only runtime hide of the sidebar, toggled by `toggle_sidebar`
/// (Ctrl+B), the header collapse chevron, and the re-show edge strip.
/// Overrides `window-show-sidebar` for the life of the window; NOT
/// persisted. Reset to false in onConfigChange so a config reload
/// re-asserts the configured visibility (matching how
/// sidebar_width_override is dropped on reload).
sidebar_hidden: bool = false,

/// Session-only runtime hide of the right sidebar, toggled by
/// `toggle_right_sidebar`. Overrides `window-show-right-sidebar` for
/// the life of the window; NOT persisted. Reset to false in
/// onConfigChange so a config reload re-asserts the configured
/// visibility.
right_sidebar_hidden: bool = false,

/// Whether the right sidebar currently has focus (keyboard input goes
/// to the right sidebar for scrolling log entries etc.).
right_sidebar_focused: bool = false,

/// True after the last tab has been closed and WM_CLOSE has been posted.
/// Input handlers must bail when this is set — between PostMessage(WM_CLOSE)
/// and the dispatch, queued mouse/keyboard messages can otherwise reach
/// handlers that allocate into a window about to be freed (e.g. the
/// new-tab "+" button calling addTab()).
closing: bool = false,

/// Optional resize limits in window-rect pixels (incl. non-client).
/// 0 means "no limit" — the OS default applies. Set by .size_limit
/// and consulted from WM_GETMINMAXINFO.
min_track_w: i32 = 0,
min_track_h: i32 = 0,
max_track_w: i32 = 0,
max_track_h: i32 = 0,

/// Pool of notification-ring overlays (layered popups), grown on demand
/// by updateAttentionRings and reused across layouts. Each ring is
/// positioned around one attention-flagged, non-focused pane in the
/// active tab; surplus rings are hidden. Created lazily so windows that
/// never see an attention signal pay nothing. Freed in deinit().
attention_rings: std.ArrayList(*AttentionRing) = .empty,

/// Flash overlay (layered popup) for the "flash focused pane" action.
/// Created lazily on first use; destroyed in deinit()/onDestroy(). At
/// most one per window — the flash always targets the focused pane.
flash_overlay: ?*FlashOverlay = null,

/// Pool of per-pane corner-button overlays (clickable layered popups),
/// grown on demand by updatePaneButtons and reused across layouts. v1
/// policy: one overlay on the active workspace/tab's FOCUSED pane only
/// (a cheap "where the user is" signal); surplus pool entries are hidden.
/// Created lazily so windows that never need one pay nothing. Freed in
/// deinit().
pane_buttons: std.ArrayList(*PaneButtons) = .empty,

pub const InitOptions = struct {
    is_quick_terminal: bool = false,
    /// If true, start fully opaque regardless of `background-opacity`. Set
    /// when `new_window` inherits from a parent window the user had
    /// toggled to opaque via `toggle_background_opacity`.
    force_opaque: bool = false,
};

/// Apply DWM dark/light + caption color based on the configured
/// background. Light vs dark is decided by luminance; CAPTION_COLOR
/// is silently ignored on Windows 10.
fn applyChromeTheme(hwnd: w32.HWND, bg: anytype) void {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    const dark_mode: u32 = if (luminance < 0.5) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    const caption_color: u32 = (@as(u32, bg.r)) | (@as(u32, bg.g) << 8) | (@as(u32, bg.b) << 16);
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_CAPTION_COLOR,
        @ptrCast(&caption_color),
        @sizeOf(u32),
    );
}

/// Called from App.config_change so the title bar tracks live config
/// reloads (background color in particular).
pub fn onConfigChange(self: *Window) void {
    if (self.hwnd) |hwnd| {
        applyChromeTheme(hwnd, self.app.config.background);
    }
    // window-show-sidebar / window-sidebar-width may have changed:
    // drop any drag-resize override so the config value re-applies,
    // then recompute chrome layout and repaint. The runtime hide is
    // session-only and re-asserts the configured visibility on reload.
    self.sidebar_width_override = null;
    self.sidebar_hidden = false;
    // Right sidebar: re-assert configured visibility on reload.
    self.right_sidebar_hidden = false;
    self.right_sidebar_focused = false;
    self.updateTabBarVisibility();
    self.handleResize();
    self.invalidateSidebar();
    self.invalidateRightSidebar();
}

/// Initialize the Window by creating the top-level HWND and tab bar font.
pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .is_quick_terminal = options.is_quick_terminal,
    };

    // Route corner-button overlay clicks back into Window. A process-wide
    // fn pointer (the overlay WndProc has no Window import) — idempotent
    // across windows since onPaneButtonClick recovers the *Window from the
    // overlay's bound owner pointer.
    PaneButtonsMod.on_click = onPaneButtonClick;

    // Value-init the first workspace before any addTab(): the workspaces
    // array is `undefined`, and the tab_status @splat default only applies
    // on value-init (`= .{}`), not on leaving the slot uninitialized.
    // Every init site (App.run, new_window, QuickTerminal.init) flows
    // through here before its first addTab().
    self.workspaces[0] = .{};
    self.workspace_count = 1;
    self.active_workspace = 0;

    const style: u32 = if (options.is_quick_terminal) w32.WS_POPUP else w32.WS_OVERLAPPEDWINDOW;
    const ex_style: u32 = if (options.is_quick_terminal) w32.WS_EX_TOOLWINDOW else 0;

    // Window geometry. Defaults to a fixed 800x600 at the OS default
    // position. Three cases, in priority order:
    //   1. The FIRST non-quick-terminal window of the session restores
    //      the saved size/position/maximized state (Windows Terminal
    //      style). app.windows is still empty here because init() runs
    //      before App appends the window to the list.
    //   2. Subsequent windows cascade 30px down/right of the previous.
    //   3. Quick terminals are positioned by QuickTerminal.calculateRects.
    const cascade_step: i32 = 30;
    var cx: i32 = w32.CW_USEDEFAULT;
    var cy: i32 = w32.CW_USEDEFAULT;
    var cw: i32 = 800;
    var ch: i32 = 600;
    // Whether to maximize the window once it is first shown (set from
    // restored state). Recorded on self so addTab() can apply it.
    self.restore_maximized = false;
    var have_restored = false;

    const is_first_window = !options.is_quick_terminal and app.windows.items.len == 0;
    if (is_first_window) {
        if (self.restorePlacement()) |saved| {
            // restorePlacement already clamped the rect onto the current
            // virtual screen, so cx/cy/cw/ch are guaranteed visible.
            cx = saved.x;
            cy = saved.y;
            cw = saved.width;
            ch = saved.height;
            self.restore_maximized = saved.maximized;
            have_restored = true;
        }
    }

    if (!options.is_quick_terminal and !have_restored and app.windows.items.len > 0) {
        // Find the previously created window's position and bump.
        const prev = app.windows.items[app.windows.items.len - 1];
        if (prev.hwnd) |ph| {
            var prev_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (w32.GetWindowRect(ph, &prev_rect) != 0) {
                cx = prev_rect.left + cascade_step;
                cy = prev_rect.top + cascade_step;
                // Reset the cascade if it would push off-screen.
                if (cx + 800 > w32.GetSystemMetrics(0) or
                    cy + 600 > w32.GetSystemMetrics(1))
                {
                    cx = w32.CW_USEDEFAULT;
                    cy = w32.CW_USEDEFAULT;
                }
            }
        }
    }

    // Create the top-level container window using the GhosttyWindow class.
    const hwnd = w32.CreateWindowExW(
        ex_style,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        style,
        cx,
        cy,
        cw,
        ch,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;

    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Store the Window pointer in GWLP_USERDATA for the WndProc.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    applyChromeTheme(hwnd, app.config.background);

    // Apply dark theme to common controls (scrollbar, etc.).
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // If background opacity is less than 1.0, make the window transparent.
    // Skip when force_opaque (parent window was toggled to opaque via
    // toggle_background_opacity — inherit that state for the new window).
    if (app.config.@"background-opacity" < 1.0 and !options.force_opaque) {
        const current_ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
        const alpha: u8 = @intFromFloat(@round(app.config.@"background-opacity" * 255.0));
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
    }

    // Query DPI scale.
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    // Create the tab bar font (Segoe UI, 12px at 96 DPI, scaled).
    const font_height: i32 = -@as(i32, @intFromFloat(16.0 * self.scale));
    self.tab_font = w32.CreateFontW(
        font_height, // cHeight (negative = character height)
        0, // cWidth
        0, // cEscapement
        0, // cOrientation
        w32.FW_NORMAL, // cWeight
        0, // bItalic
        0, // bUnderline
        0, // bStrikeOut
        w32.DEFAULT_CHARSET, // iCharSet
        0, // iOutPrecision
        0, // iClipPrecision
        0, // iQuality
        0, // iPitchAndFamily
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );

    // Don't show the window yet — addTab() will show the child
    // surface which triggers ShowWindow on the parent as needed.
    // Showing the parent before the terminal is ready can cause
    // timing issues with ConPTY.
}

/// Name of the persisted window-state file, under %LOCALAPPDATA%\ghostty.
const WINDOW_STATE_FILE = "window-state";

/// Build the absolute path to the window-state file. Mirrors the
/// `update_check_at` convention used elsewhere in this runtime
/// (%LOCALAPPDATA%\ghostty\...). Caller owns the returned slice.
fn windowStatePath(alloc: std.mem.Allocator) ![]u8 {
    const dir = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "ghostty", WINDOW_STATE_FILE });
}

/// Capture the current window placement and persist it. Called on
/// WM_EXITSIZEMOVE (resize/move settle) and on close, so we never write
/// on every pixel of a drag.
///
/// We persist the window's *restored* rect (GetWindowPlacement's
/// rcNormalPosition) plus the maximized flag, so a maximized window still
/// remembers the underlying size it un-maximizes to. Coordinates are
/// physical pixels in workarea space (see WindowState.zig).
///
/// Only the main window participates: quick terminals manage their own
/// geometry, and additional windows would clobber each other. Errors
/// (missing dir, no permission) are swallowed — persistence is best
/// effort and must never affect normal operation.
pub fn savePlacement(self: *Window) void {
    if (self.is_quick_terminal) return;
    // Only the first window in the App's list owns the persisted state.
    // Additional session windows cascade and do not save (avoids two
    // windows fighting over one file).
    if (self.app.windows.items.len == 0 or self.app.windows.items[0] != self) return;
    const hwnd = self.hwnd orelse return;

    var wp: w32.WINDOWPLACEMENT = undefined;
    wp.length = @sizeOf(w32.WINDOWPLACEMENT);
    if (w32.GetWindowPlacement(hwnd, &wp) == 0) return;

    const r = wp.rcNormalPosition;
    const state: WindowState.State = .{
        .width = r.right - r.left,
        .height = r.bottom - r.top,
        .x = r.left,
        .y = r.top,
        // showCmd reflects the persisted (un-minimized) show state.
        // SW_SHOWMAXIMIZED (3) and SW_MAXIMIZE (3) both mean maximized.
        .maximized = wp.showCmd == w32.SW_SHOWMAXIMIZED,
    };

    // Reject a degenerate capture (e.g. a minimized window reporting a
    // tiny/zero normal rect during teardown) so we never clobber a
    // previously-good save with garbage.
    if (!state.validate()) return;

    const alloc = self.app.core_app.alloc;
    const path = windowStatePath(alloc) catch return;
    defer alloc.free(path);

    // Ensure the parent dir exists, then write atomically-ish via
    // truncate. The state is tiny so a partial write is implausible.
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer file.close();
    var buf: [160]u8 = undefined;
    const text = state.serialize(&buf) catch return;
    file.writeAll(text) catch return;
    self.saved_placement_ok = true;
}

/// Read and validate the persisted window state, clamped onto the
/// current virtual screen so the restored window is always visible.
/// Returns null when there is no state, it is corrupt, or the env is
/// unavailable — callers then fall back to defaults. Best effort: any
/// error path yields null.
fn restorePlacement(self: *Window) ?WindowState.State {
    const alloc = self.app.core_app.alloc;
    const path = windowStatePath(alloc) catch return null;
    defer alloc.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    var state = WindowState.State.parse(buf[0..n]) orelse return null;

    // Clamp onto the current virtual screen (handles a removed monitor or
    // an off-screen saved position). Physical pixels throughout.
    const vx = w32.GetSystemMetrics(w32.SM_XVIRTUALSCREEN);
    const vy = w32.GetSystemMetrics(w32.SM_YVIRTUALSCREEN);
    const vw = w32.GetSystemMetrics(w32.SM_CXVIRTUALSCREEN);
    const vh = w32.GetSystemMetrics(w32.SM_CYVIRTUALSCREEN);
    // If the metrics are unavailable (0 span), skip clamping rather than
    // collapsing the window.
    if (vw > 0 and vh > 0) {
        const adjusted = WindowState.clampToVirtualScreen(
            .{ .x = state.x, .y = state.y, .width = state.width, .height = state.height },
            .{ .x = vx, .y = vy, .width = vw, .height = vh },
        );
        state.x = adjusted.x;
        state.y = adjusted.y;
        state.width = adjusted.width;
        state.height = adjusted.height;
    }

    return state;
}

/// Deinitialize the Window: close all tabs, delete font, destroy HWND.
pub fn deinit(self: *Window) void {
    // Close all tab surfaces.
    self.cleanupAllSurfaces();

    // Destroy the notification-ring overlays (owned popups) before the
    // owner window so they never outlive it.
    for (self.attention_rings.items) |ring| ring.destroy();
    self.attention_rings.deinit(self.app.core_app.alloc);

    // Destroy the flash overlay (owned popup) before the owner window.
    if (self.flash_overlay) |fo| {
        fo.destroy();
        self.flash_overlay = null;
    }

    // Destroy the per-pane corner-button overlays (owned popups) before
    // the owner window so they never outlive it.
    for (self.pane_buttons.items) |pb| pb.destroy();
    self.pane_buttons.deinit(self.app.core_app.alloc);

    // Delete the tab bar font.
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }

    // Clear GWLP_USERDATA before destroying to prevent stale pointer access.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Returns the tab bar height in pixels, accounting for DPI scale.
/// Returns 0 if the tab bar is not visible.
pub fn tabBarHeight(self: *const Window) i32 {
    if (!self.tab_bar_visible) return 0;
    return @intFromFloat(@round(32.0 * self.scale));
}

/// Returns the sidebar width in pixels, accounting for DPI scale.
/// Returns 0 when the sidebar is disabled, for quick terminals, or
/// once the window is closing.
pub fn sidebarWidth(self: *const Window) i32 {
    if (self.closing or self.is_quick_terminal) return 0;
    if (!self.app.config.@"window-show-sidebar") return 0;
    if (self.sidebar_hidden) return 0;
    const unscaled = self.sidebar_width_override orelse self.app.config.@"window-sidebar-width";
    const width = std.math.clamp(unscaled, Sidebar.MIN_WIDTH, Sidebar.MAX_WIDTH);
    return @intFromFloat(@round(@as(f32, @floatFromInt(width)) * self.scale));
}

/// Whether the re-show edge strip (the thin affordance that brings the
/// sidebar back when it is runtime-hidden) should be painted/hit-tested
/// right now: the sidebar is enabled by config but hidden this session.
/// QuickTerminals have no sidebar so never show the strip.
pub fn sidebarReshowStripVisible(self: *const Window) bool {
    if (self.closing or self.is_quick_terminal) return false;
    if (!self.app.config.@"window-show-sidebar") return false;
    return self.sidebar_hidden;
}

/// Width of the re-show edge strip in DPI-scaled pixels. Kept thin (8px)
/// so it barely eats surface width; surfaceRect reserves exactly this much
/// at the left edge while hidden so the GL/WebView2 child does not occlude
/// the parent-painted strip.
pub fn sidebarReshowStripWidth(self: *const Window) i32 {
    return @intFromFloat(@round(@as(f32, RESHOW_STRIP_BASE) * self.scale));
}

/// Toggle the runtime (session-only) sidebar hide. No-op on a quick
/// terminal (it has no sidebar). Flips the bool, cancels any in-flight
/// edge drag, then relays out the panes + repaints chrome + re-glues the
/// overlays (handleResize routes through layoutSplits). Distinct from the
/// `window-show-sidebar` config: a config reload re-asserts the
/// configured visibility (onConfigChange resets sidebar_hidden).
pub fn toggleSidebar(self: *Window) void {
    if (self.is_quick_terminal) return;
    self.sidebar_hidden = !self.sidebar_hidden;
    // Abort any half-finished edge drag: the grab band disappears when
    // the width is 0, so a captured drag would otherwise dangle.
    self.dragging_sidebar = false;
    // Switching to/from a 0 width changes surfaceRect; relayout panes,
    // repaint the tab bar + sidebar, and re-glue the over-GL overlays.
    self.handleResize();
    // The re-show strip lives over the surface's left edge (paintChrome
    // draws it when hidden); force a full repaint so it appears/clears.
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
}

/// Returns the right sidebar width in pixels, accounting for DPI scale.
/// Returns 0 when the right sidebar is disabled, for quick terminals, or
/// once the window is closing.
pub fn rightSidebarWidth(self: *const Window) i32 {
    if (self.closing or self.is_quick_terminal) return 0;
    if (!self.app.config.@"window-show-right-sidebar") return 0;
    if (self.right_sidebar_hidden) return 0;
    const unscaled = self.app.config.@"window-right-sidebar-width";
    const width = std.math.clamp(unscaled, RightSidebar.MIN_WIDTH, RightSidebar.MAX_WIDTH);
    return @intFromFloat(@round(@as(f32, @floatFromInt(width)) * self.scale));
}

/// Toggle the runtime (session-only) right sidebar hide. No-op on a
/// quick terminal. Flips the bool, then relays out the panes + repaints.
pub fn toggleRightSidebar(self: *Window) void {
    if (self.is_quick_terminal) return;
    self.right_sidebar_hidden = !self.right_sidebar_hidden;
    // When hiding the right sidebar, also drop focus from it.
    if (self.right_sidebar_hidden) self.right_sidebar_focused = false;
    self.handleResize();
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
}

/// Toggle focus between the right sidebar and the terminal. If the
/// right sidebar is not visible, this is a no-op.
pub fn focusRightSidebar(self: *Window) void {
    if (self.rightSidebarWidth() <= 0) return;
    self.right_sidebar_focused = !self.right_sidebar_focused;
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
}

/// Invalidate the right sidebar region so it gets repainted.
pub fn invalidateRightSidebar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const rs_w = self.rightSidebarWidth();
    if (rs_w <= 0) return;
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    var rect = w32.RECT{
        .left = client_rect.right - rs_w,
        .top = 0,
        .right = client_rect.right,
        .bottom = 32767,
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Whether the sidebar should render the metadata second line on its rows
/// right now: the config toggle is on AND at least one workspace has
/// metadata to show. Computed once and used to pick the row height so the
/// taller stride is uniform across all rows (the index-based hit-testing /
/// drag math assumes a single fixed row height).
pub fn sidebarShowMetadata(self: *const Window) bool {
    if (!self.app.config.@"sidebar-metadata") return false;
    for (self.workspaces[0..self.workspace_count]) |*ws| {
        if (ws.hasMetadata()) return true;
    }
    return false;
}

/// The current sidebar row height: the taller two-line height when the
/// metadata line is active, else the compact single-line height. THE
/// single source of truth for the row stride — every sidebar geometry call
/// site (hitTest, itemRect, drag target, paint) routes through this so
/// painting and hit-testing always agree.
pub fn sidebarItemHeight(self: *const Window) i32 {
    return if (self.sidebarShowMetadata())
        Sidebar.itemHeightMeta(self.scale)
    else
        Sidebar.itemHeight(self.scale);
}

/// Returns the client rect available for the active surface, which is
/// the full client area minus the tab bar height from the top, the
/// sidebar width from the left, and the right sidebar width from the right.
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.tabBarHeight();
    rect.left += self.sidebarWidth();
    rect.right -= self.rightSidebarWidth();
    // While the sidebar is runtime-hidden, reserve the thin re-show strip
    // at the left edge so the GL/WebView2 child does not cover it (a
    // parent-window GDI strip painted inside the surface rect would be
    // occluded by the child HWND). Only 8px, so it barely shrinks the
    // surface; the WM_LBUTTONDOWN handler hit-tests the strip first.
    if (self.sidebarReshowStripVisible()) rect.left += self.sidebarReshowStripWidth();
    return rect;
}

/// The currently active workspace. Always valid on a live window
/// (workspace_count >= 1); only a partially-initialized window (before
/// the init sites set workspace_count=1) has none, and no UI path runs
/// against one.
pub fn activeWorkspace(self: *Window) *Workspace {
    return &self.workspaces[self.active_workspace];
}

/// The index of a workspace pointer within this window's workspaces
/// array. The pointer MUST belong to this window (as returned by
/// findLoc/findLocOfSurface); used to turn a located workspace back into
/// an index for selectWorkspace.
pub fn workspaceIndex(self: *Window, ws: *Workspace) usize {
    const base = @intFromPtr(&self.workspaces[0]);
    return (@intFromPtr(ws) - base) / @sizeOf(Workspace);
}

/// Returns the currently active Pane, or null if there are no tabs.
pub fn getActivePane(self: *Window) ?*Pane {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return null;
    return ws.tab_active_pane[ws.active_tab];
}

/// Returns the currently active terminal Surface, or null if there are
/// no tabs or the active pane has no terminal.
pub fn getActiveSurface(self: *Window) ?*Surface {
    const pane = self.getActivePane() orelse return null;
    return pane.surface();
}

/// Find the workspace+tab containing a given pane, scanning every
/// workspace. Checks tab_active_pane first, then scans all trees.
pub fn findLoc(self: *Window, pane: *Pane) ?Loc {
    for (self.workspaces[0..self.workspace_count]) |*ws| {
        for (ws.tab_active_pane[0..ws.tab_count], 0..) |p, i| {
            if (p == pane) return .{ .ws = ws, .tab = i };
        }
        for (0..ws.tab_count) |i| {
            var it = ws.tab_trees[i].iterator();
            while (it.next()) |entry| {
                if (entry.view == pane) return .{ .ws = ws, .tab = i };
            }
        }
    }
    return null;
}

/// Find the workspace+tab containing a given terminal surface, scanning
/// every workspace. Compares by address against live panes WITHOUT
/// dereferencing `surface`, so callers validating possibly-dangling
/// pointers (jumpToSurface) can use it safely.
pub fn findLocOfSurface(self: *Window, surface: *Surface) ?Loc {
    for (self.workspaces[0..self.workspace_count]) |*ws| {
        for (ws.tab_active_pane[0..ws.tab_count], 0..) |p, i| {
            if (p.surface() == surface) return .{ .ws = ws, .tab = i };
        }
        for (0..ws.tab_count) |i| {
            var it = ws.tab_trees[i].iterator();
            while (it.next()) |entry| {
                if (entry.view.surface() == surface) return .{ .ws = ws, .tab = i };
            }
        }
    }
    return null;
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
fn newTabInsertPos(pos_cfg: anytype, count: usize, active: usize) usize {
    return switch (pos_cfg) {
        .current => if (count > 0) active + 1 else 0,
        .end => count,
    };
}

/// Shift entries [pos, count) right by one in every array of the
/// tuple, opening a gap at pos. The caller fills the gap and bumps its
/// count.
fn tabArraysInsertGap(arrays: anytype, count: usize, pos: usize) void {
    inline for (arrays) |arr| {
        var i: usize = count;
        while (i > pos) : (i -= 1) arr[i] = arr[i - 1];
    }
}

/// Shift entries (idx, count) left by one in every array, overwriting
/// idx. The caller decrements its count (and clears the now-duplicate
/// last slot where stale pointers matter, e.g. tab_trees).
fn tabArraysRemove(arrays: anytype, count: usize, idx: usize) void {
    inline for (arrays) |arr| {
        var i: usize = idx;
        while (i + 1 < count) : (i += 1) arr[i] = arr[i + 1];
    }
}

/// Move the entry at `from` to `to` in every array, shifting the
/// entries between them one slot toward `from`.
fn tabArraysMove(arrays: anytype, from: usize, to: usize) void {
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
fn tabArraysSwap(arrays: anytype, a: usize, b: usize) void {
    inline for (arrays) |arr| {
        std.mem.swap(@TypeOf(arr[a]), &arr[a], &arr[b]);
    }
}

/// Add a new tab surface to this window. The surface is created,
/// initialized, and inserted at the position dictated by config.
pub fn addTab(self: *Window) !*Surface {
    return self.addTabWithCommand(null, null);
}

/// Like addTab, but the new tab inherits the active pane's backend
/// ("follow the current console", mirroring how splits inherit via
/// newSplit): a new tab opened from a WSL or PowerShell tab runs the
/// same shell. Used by the plain new-tab UX paths — the tab bar "+"
/// button, the new_tab binding action, and the New Tab context-menu
/// entries. The backend picker stays an explicit override
/// (addTabWithCommand), and window/workspace creation keeps the
/// configured default (addTab). A null spawn_command (the default
/// shell) or a browser pane (no terminal surface) falls back to the
/// default, matching addTab. Surface.init deep copies the argv, so
/// borrowing the source surface's copy is fine (same as newSplit).
pub fn addTabInherit(self: *Window) !*Surface {
    const command: ?[]const []const u8 = blk: {
        const ws = self.activeWorkspace();
        if (ws.tab_count == 0) break :blk null;
        const src = ws.tab_active_pane[ws.active_tab].surface() orelse break :blk null;
        break :blk src.spawn_command;
    };
    const title: ?[]const u8 = if (command) |argv| titleForCommand(argv) else null;
    return self.addTabWithCommand(command, title);
}

/// Initial tab title for an inherited backend argv, mirroring the
/// titles the backend picker passes to addTabWithCommand: pwsh /
/// powershell → "PowerShell", cmd → "cmd", wsl with an explicit
/// -d/--distribution → the distro name. Anything else (including a
/// bare wsl.exe) returns null, leaving the default title until the
/// shell's OSC title arrives. The distro case returns a slice into
/// `argv`; addTabWithCommand copies the title before returning.
fn titleForCommand(argv: []const []const u8) ?[]const u8 {
    if (argv.len == 0) return null;
    var exe = std.fs.path.basename(argv[0]);
    if (std.ascii.endsWithIgnoreCase(exe, ".exe")) exe = exe[0 .. exe.len - 4];
    if (std.ascii.eqlIgnoreCase(exe, "pwsh") or
        std.ascii.eqlIgnoreCase(exe, "powershell")) return "PowerShell";
    if (std.ascii.eqlIgnoreCase(exe, "cmd")) return "cmd";
    if (std.ascii.eqlIgnoreCase(exe, "wsl")) {
        var i: usize = 1;
        while (i + 1 < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "-d") or
                std.mem.eql(u8, argv[i], "--distribution")) return argv[i + 1];
        }
    }
    return null;
}

/// Like addTab, but optionally overrides the command the new tab runs
/// (the new-session backend picker) and its initial title. The argv
/// and title are copied as needed, so the caller's memory may be freed
/// once this returns. Null command/title behave exactly like addTab.
pub fn addTabWithCommand(
    self: *Window,
    command: ?[]const []const u8,
    title: ?[]const u8,
) !*Surface {
    if (self.closing) return error.WindowClosing;
    const ws = self.activeWorkspace();
    if (ws.tab_count >= MAX_TABS) return error.TooManyTabs;
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    // A workspace bound to a git worktree spawns every new tab in that
    // directory; a null binding falls through to the configured/inherited
    // cwd (current behavior).
    try surface.init(self.app, self, .tab, command, ws.working_dir);
    // After surface.init succeeds, wrap it in a Pane and create the
    // SplitTree which takes ownership via ref(). If this fails, we
    // manually clean up.
    const pane = Pane.create(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    var tree = SplitTree(Pane).init(alloc, pane) catch |err| {
        alloc.destroy(pane);
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit(); // tree.deinit() calls unref() which deinits+frees the pane

    // Determine insert position based on config.
    const pos: usize = newTabInsertPos(self.app.config.@"window-new-tab-position", ws.tab_count, ws.active_tab);

    // Shift elements right to make room at pos.
    tabArraysInsertGap(ws.tabArrays(), ws.tab_count, pos);
    ws.tab_trees[pos] = tree;
    ws.tab_active_pane[pos] = pane;
    ws.tab_status[pos] = .normal;
    // Reset orchestration metadata for the freshly-occupied slot: the gap
    // insert leaves the old [pos] values in place (it shifts toward the
    // tail), so a new tab must not inherit a prior tab's status/progress/
    // log, exactly as tab_status is reset above.
    ws.tab_status_text_len[pos] = 0;
    ws.tab_progress[pos] = null;
    ws.tab_log[pos].clear();
    ws.tab_count += 1;

    // Set the initial title: the picked backend name when given (so the
    // sidebar row is identifiable before the shell's OSC title arrives),
    // otherwise the default. Truncated to the title buffer; an invalid
    // UTF-8 title falls back to the default.
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(ws.tab_titles[pos][0..default_title.len], default_title);
    ws.tab_title_lens[pos] = @intCast(default_title.len);
    if (title) |t| {
        const wlen = std.unicode.utf8ToUtf16Le(
            &ws.tab_titles[pos],
            t[0..@min(t.len, 255)],
        ) catch 0;
        if (wlen > 0) ws.tab_title_lens[pos] = @intCast(@min(wlen, 255));
    }

    if (ws.tab_count == 1) {
        // First tab — show the parent window now that the terminal is ready.
        // Quick terminal windows are shown by QuickTerminal.animateIn() instead.
        // If restored state asked for a maximized window, show it maximized
        // so the OS uses the persisted restored rect as the un-maximize size.
        if (!self.is_quick_terminal) {
            if (self.hwnd) |h| {
                const cmd: i32 = if (self.restore_maximized) w32.SW_SHOWMAXIMIZED else w32.SW_SHOW;
                // One-shot: consume the restore-maximized intent so it
                // applies exactly once, during the initial window
                // bring-up. Creating/selecting a workspace runs addTab on
                // a fresh (tab_count==1) workspace and re-enters this
                // branch — without clearing the flag that would
                // re-maximize the window on every new workspace.
                self.restore_maximized = false;
                _ = w32.ShowWindow(h, cmd);
                _ = w32.UpdateWindow(h);
            }
        }
        ws.active_tab = pos;
        self.updateWindowTitle();
        // Set keyboard focus to the child surface so it receives input.
        if (!self.is_quick_terminal) {
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        }
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.invalidateSidebar();
    return surface;
}

/// Add a tab to a workspace that need not be the active one, WITHOUT
/// switching to it or moving focus. Mirrors addTabWithCommand's per-tab
/// bookkeeping but targets `ws_idx` and keeps the background workspace's
/// panes hidden (the freshly created child HWND is hidden right after
/// Surface.init shows it). When `ws_idx` IS the active workspace this
/// delegates to addTabWithCommand so the active-tab switch/focus behaves
/// exactly as the interactive "+" path. `command` mirrors
/// addTabWithCommand (null = the configured default shell). Used by the
/// agent IPC `+tab new` (no `--focus`): the new tab exists in the
/// background and `selectTabIndex`/`selectWorkspace` shows it later.
/// Returns the new tab's index within `ws_idx`.
pub fn addTabBackground(
    self: *Window,
    ws_idx: usize,
    command: ?[]const []const u8,
    title: ?[]const u8,
) !usize {
    if (self.closing) return error.WindowClosing;
    if (ws_idx >= self.workspace_count) return error.NoWindow;
    // Active workspace: identical to the interactive new-tab path (it
    // both switches to and focuses the new tab — correct, since the user
    // is already looking at this workspace and an explicit IPC add to the
    // foreground workspace is reasonably a focus event there).
    if (ws_idx == self.active_workspace) {
        _ = try self.addTabWithCommand(command, title);
        return self.activeWorkspace().active_tab;
    }

    const ws = &self.workspaces[ws_idx];
    if (ws.tab_count >= MAX_TABS) return error.TooManyTabs;
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    try surface.init(self.app, self, .tab, command, ws.working_dir);
    const pane = Pane.create(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    var tree = SplitTree(Pane).init(alloc, pane) catch |err| {
        alloc.destroy(pane);
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit();

    // Background workspace: hide the child HWND Surface.init showed so it
    // never paints over the visible workspace.
    if (surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);

    const pos: usize = newTabInsertPos(self.app.config.@"window-new-tab-position", ws.tab_count, ws.active_tab);

    tabArraysInsertGap(ws.tabArrays(), ws.tab_count, pos);
    ws.tab_trees[pos] = tree;
    ws.tab_active_pane[pos] = pane;
    ws.tab_status[pos] = .normal;
    // Reset orchestration metadata for the freshly-occupied slot (the gap
    // insert shifts toward the tail, leaving the old [pos] values), matching
    // addTabWithCommand so a background tab never inherits a prior tab's
    // status/progress/log.
    ws.tab_status_text_len[pos] = 0;
    ws.tab_progress[pos] = null;
    ws.tab_log[pos].clear();
    ws.tab_count += 1;

    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(ws.tab_titles[pos][0..default_title.len], default_title);
    ws.tab_title_lens[pos] = @intCast(default_title.len);
    if (title) |t| {
        const wlen = std.unicode.utf8ToUtf16Le(
            &ws.tab_titles[pos],
            t[0..@min(t.len, 255)],
        ) catch 0;
        if (wlen > 0) ws.tab_title_lens[pos] = @intCast(@min(wlen, 255));
    }

    // Make the new tab the workspace's own active tab so a later switch
    // lands on it (its panes stay hidden until then). The previously
    // active tab of THIS background workspace is already hidden, so no
    // hide is needed here.
    ws.active_tab = pos;
    self.invalidateSidebar();
    return pos;
}

/// Like addTabBackground but inherits the source tab's backend, the
/// non-focus counterpart to addTabInherit. The backend is read from the
/// TARGET workspace's active tab (not the window's active workspace), so
/// a background `+tab new` follows the shell of the workspace it lands in.
pub fn addTabInheritBackground(self: *Window, ws_idx: usize) !usize {
    if (ws_idx >= self.workspace_count) return error.NoWindow;
    const command: ?[]const []const u8 = blk: {
        const ws = &self.workspaces[ws_idx];
        if (ws.tab_count == 0) break :blk null;
        const src = ws.tab_active_pane[ws.active_tab].surface() orelse break :blk null;
        break :blk src.spawn_command;
    };
    const title: ?[]const u8 = if (command) |argv| titleForCommand(argv) else null;
    return self.addTabBackground(ws_idx, command, title);
}

/// Add a browser (WebView2) pane as a new tab. Mirrors
/// addTabWithCommand's tab-array bookkeeping with a BrowserPane leaf
/// instead of a terminal surface; the title is "Browser" until the
/// first DocumentTitleChanged. Closing it never prompts (no core
/// surface, so no running-process check applies).
pub fn addBrowserTab(self: *Window) !void {
    if (self.closing) return error.WindowClosing;
    // Quick terminals are transient single-surface popups with no tab
    // bar or sidebar; no UI path offers them a browser tab, but guard
    // anyway so a future caller can't create unreachable chrome.
    if (self.is_quick_terminal) return error.QuickTerminal;
    const ws = self.activeWorkspace();
    if (ws.tab_count >= MAX_TABS) return error.TooManyTabs;
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;

    // Build the single-pane tree. The errdefers only cover the gap
    // until the tree takes ownership via ref() (same shape as
    // newBrowserSplit); past the block the insertion below cannot
    // fail, so the tree is never deinit'd after tab_trees holds it.
    var browser: *BrowserPane = undefined;
    var browser_pane: *Pane = undefined;
    const tree = blk: {
        const b = try BrowserPane.create(alloc, self.app, self);
        errdefer b.destroy(alloc);
        const new_pane = try Pane.createBrowser(alloc, b);
        errdefer alloc.destroy(new_pane);
        const t = try SplitTree(Pane).init(alloc, new_pane);
        browser = b;
        browser_pane = new_pane;
        break :blk t;
    };

    // Determine insert position based on config.
    const pos: usize = newTabInsertPos(self.app.config.@"window-new-tab-position", ws.tab_count, ws.active_tab);

    // Shift elements right to make room at pos.
    tabArraysInsertGap(ws.tabArrays(), ws.tab_count, pos);
    ws.tab_trees[pos] = tree;
    ws.tab_active_pane[pos] = browser_pane;
    ws.tab_status[pos] = .normal;
    ws.tab_status_text_len[pos] = 0;
    ws.tab_progress[pos] = null;
    ws.tab_log[pos].clear();
    ws.tab_count += 1;

    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Browser");
    @memcpy(ws.tab_titles[pos][0..default_title.len], default_title);
    ws.tab_title_lens[pos] = @intCast(default_title.len);

    if (ws.tab_count == 1) {
        // First tab — not reachable from the current UI (the picker
        // only exists on live windows, which always have >= 1 tab),
        // but mirror addTabWithCommand for robustness.
        if (self.hwnd) |h| {
            _ = w32.ShowWindow(h, w32.SW_SHOW);
            _ = w32.UpdateWindow(h);
        }
        ws.active_tab = pos;
        self.updateWindowTitle();
        self.layoutSplits();
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.invalidateSidebar();

    // Begin async WebView2 creation now that the tree owns the pane
    // (the in-flight race guard refs it).
    browser.startCreation();

    // Focus the address bar so the user can type a URL immediately.
    if (browser.address_edit) |edit| {
        _ = w32.SetFocus(edit);
    } else {
        browser_pane.focus();
    }
}

/// Close a tab by pane pointer. Removes from the tab list,
/// deinits the tree, and adjusts the active tab index.
pub fn closeTab(self: *Window, pane: *Pane) void {
    const loc = self.findLoc(pane) orelse return;
    log.debug("closeTab called for pane={x} tab_count={}", .{ @intFromPtr(pane), loc.ws.tab_count });
    // The pane may live in a NON-active workspace (a background shell
    // exiting, an IPC-addressed browser closing): close the tab in the
    // workspace that actually owns it, never the active one.
    self.closeTabInWorkspace(self.workspaceIndex(loc.ws), loc.tab);
}

/// Close a tab by index within the ACTIVE workspace (tab bar / context
/// menu paths, where the index is always active-workspace-relative).
fn closeTabByIndex(self: *Window, idx: usize) void {
    self.closeTabInWorkspace(self.active_workspace, idx);
}

/// Pure active-tab fixup for closeTabInWorkspace: the tab at `idx` was
/// removed (arrays already shifted left) leaving `new_count` >= 1 tabs;
/// return the post-close active index. A surviving active tab follows
/// its shifted slot; closing the active tab selects the tab that slid
/// into its slot, clamped to the new last index. HWND-free so it can be
/// unit tested exhaustively.
fn closeTabActiveFixup(new_count: usize, active: usize, idx: usize) usize {
    if (active >= new_count) return new_count - 1;
    if (active > idx) return active - 1;
    return active;
}

/// Close the tab at `idx` within workspace `ws_idx`, which need not be
/// the active workspace (pane-pointer close paths resolve via findLoc).
fn closeTabInWorkspace(self: *Window, ws_idx: usize, idx: usize) void {
    if (ws_idx >= self.workspace_count) return;
    const ws = &self.workspaces[ws_idx];
    if (idx >= ws.tab_count) return;
    // Cancel any in-progress rename (the edit control may belong to this tab).
    self.cancelTabRename();

    // Detach the tab from the window state BEFORE tree.deinit():
    // deinit can destroy a browser host HWND, which moves focus
    // synchronously and re-enters our wndprocs (WM_SETFOCUS &c).
    // Those handlers read tab_trees/tab_active_pane/active_tab and
    // must never observe the dying tab. The local copy stays valid:
    // SplitTree is a value whose deinit frees the shared heap data.
    var tree = ws.tab_trees[idx];
    tabArraysRemove(ws.tabArrays(), ws.tab_count, idx);
    ws.tab_count -= 1;
    // The shift leaves a duplicate of the last tree past the new
    // count; clear it so nothing can ever walk stale node pointers.
    ws.tab_trees[ws.tab_count] = .empty;

    if (ws.tab_count == 0) {
        if (self.workspace_count > 1) {
            // The last tab of a workspace with siblings closed: collapse
            // the now-empty workspace instead of the window. The tab was
            // already detached above (tab_count is 0), so deinit its tree
            // here, then closeWorkspace shifts the empty slot out and
            // selects a survivor. closeWorkspace's own tab loop is a no-op
            // at tab_count==0, so the tree is freed exactly once.
            tree.deinit();
            self.closeWorkspace(ws_idx);
            return;
        }
        // Last tab of the only workspace → close the window. Set closing
        // before deinit so re-entrant input/focus messages are dropped by
        // the wndproc guards while panes are torn down.
        self.closing = true;
        tree.deinit(); // unrefs all panes → Pane.unref frees at ref_count=0
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }
    ws.active_tab = closeTabActiveFixup(ws.tab_count, ws.active_tab, idx);
    tree.deinit();
    if (ws_idx == self.active_workspace) {
        self.selectTabIndex(ws.active_tab);
        self.updateTabBarVisibility();
    } else {
        // Background workspace: its panes are hidden and stay hidden;
        // selectWorkspace lays it out when it next becomes active. The
        // sidebar dot may change (aggregateStatus over fewer tabs).
        self.invalidateSidebar();
    }
}

/// Public wrapper over closeTabInWorkspace for the agent IPC `tab-close`,
/// which addresses a tab by (workspace index, tab index). Bounds are
/// validated inside; closing the last tab of the only workspace closes
/// the window, exactly as the UI close paths do.
pub fn closeTabInWorkspaceForIpc(self: *Window, ws_idx: usize, idx: usize) void {
    self.closeTabInWorkspace(ws_idx, idx);
}

/// Close tabs based on mode: this (current), other (all but current), right (all after current).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    switch (mode) {
        .this => self.closeSplitSurface(surface),
        .other => {
            // Operate on the workspace that owns the surface (which may
            // not be active, e.g. an IPC-addressed surface). The loop
            // never empties the workspace (current survives), so no
            // workspaces[] shift can invalidate ws_idx mid-loop.
            const loc = self.findLocOfSurface(surface) orelse return;
            const ws_idx = self.workspaceIndex(loc.ws);
            var current = loc.tab;
            var i: usize = loc.ws.tab_count;
            while (i > 0) {
                i -= 1;
                if (i != current) {
                    self.closeTabInWorkspace(ws_idx, i);
                    if (i < current) current -= 1;
                }
            }
        },
        .right => {
            const loc = self.findLocOfSurface(surface) orelse return;
            const ws_idx = self.workspaceIndex(loc.ws);
            const current = loc.tab;
            var i: usize = loc.ws.tab_count;
            while (i > current + 1) {
                i -= 1;
                self.closeTabInWorkspace(ws_idx, i);
            }
        },
    }
}

/// Close a single terminal surface's pane. See closeSplitPane.
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const pane = surface.pane orelse return;
    self.closeSplitPane(pane);
}

/// Close a single pane within a split tree. If it's the last pane
/// in the tab, close the entire tab instead.
pub fn closeSplitPane(self: *Window, pane: *Pane) void {
    const alloc = self.app.core_app.alloc;
    const loc = self.findLoc(pane) orelse {
        log.debug("closeSplitPane: pane not found in any tab", .{});
        return;
    };
    const ws = loc.ws;
    const tab = loc.tab;
    const tree = &ws.tab_trees[tab];

    if (!tree.isSplit()) {
        log.debug("closeSplitPane: not split, closing whole tab", .{});
        self.closeTab(pane);
        return;
    }

    const handle = ws.findHandle(tab, pane) orelse {
        log.debug("closeSplitPane: handle not found", .{});
        return;
    };
    log.debug("closeSplitPane: removing handle={} from tab={}", .{ handle.idx(), tab });

    // Find next focus target BEFORE removing.
    const next_handle = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null);

    // Extract the pane pointer from the next handle before we modify the tree.
    const next_pane: ?*Pane = if (next_handle) |nh| blk: {
        break :blk switch (tree.nodes[nh.idx()]) {
            .leaf => |v| v,
            .split => null,
        };
    } else null;
    log.debug("closeSplitPane: has_next={}", .{next_pane != null});

    const new_tree = tree.remove(alloc, handle) catch {
        log.err("failed to remove pane from split tree", .{});
        return;
    };
    log.debug("closeSplitPane: remove returned, new_tree nodes={}", .{new_tree.nodes.len});

    // Publish the new tree and a surviving active pane BEFORE deiniting
    // the old tree: the deinit can destroy a browser host HWND, which
    // moves focus synchronously and re-enters wndprocs that read
    // tab_trees/tab_active_pane. They must see post-removal state, not
    // the dying pane.
    var old_tree = ws.tab_trees[tab];
    ws.tab_trees[tab] = new_tree;
    const survivor: ?*Pane = next_pane orelse blk: {
        var it = new_tree.iterator();
        break :blk if (it.next()) |entry| entry.view else null;
    };
    if (survivor) |sp| ws.tab_active_pane[tab] = sp;
    old_tree.deinit();

    if (next_pane) |np| {
        // Only lay out and move focus when the pane lives in the ACTIVE
        // workspace: a background workspace's survivors stay hidden (the
        // active-pane slot was already updated above) and focusing one
        // would SetFocus a hidden HWND, stealing keyboard focus from the
        // visible workspace.
        if (ws == self.activeWorkspace()) {
            log.debug("closeSplitPane: focusing next pane", .{});
            self.layoutSplits();
            np.focus();
        }
    } else {
        log.debug("closeSplitPane: no next pane, closing tab", .{});
        // `tab` is an index into loc.ws, which may not be the active
        // workspace — close it where it lives.
        self.closeTabInWorkspace(self.workspaceIndex(ws), tab);
    }
}

/// Break the focused pane out of its split into a new tab in the same
/// workspace. The pane's HWND/surface is NOT destroyed — it is detached
/// from the source tree and becomes the sole root of a fresh tab. If the
/// pane is the only pane in its tab (not split), this is a no-op.
pub fn breakPane(self: *Window, pane: *Pane) void {
    const alloc = self.app.core_app.alloc;
    const loc = self.findLoc(pane) orelse return;
    const ws = loc.ws;
    const src_tab = loc.tab;
    const tree = &ws.tab_trees[src_tab];

    if (!tree.isSplit()) return;
    if (ws.tab_count >= MAX_TABS) return;

    const handle = ws.findHandle(src_tab, pane) orelse return;

    const next_handle = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null);
    const next_pane: ?*Pane = if (next_handle) |nh| switch (tree.nodes[nh.idx()]) {
        .leaf => |v| v,
        .split => null,
    } else null;

    // Bump the pane's ref count: tree.remove will unref all surviving
    // nodes (they get re-reffed into the new tree), and the removed node
    // gets unreffed too. We need the pane to survive the remove+deinit
    // cycle, so add an extra ref that balances the unref the old tree's
    // deinit will perform on the removed node.
    _ = pane.ref(alloc) catch return;

    const new_tree = tree.remove(alloc, handle) catch {
        pane.unref(alloc);
        return;
    };

    var old_tree = ws.tab_trees[src_tab];
    ws.tab_trees[src_tab] = new_tree;
    if (next_pane) |np| ws.tab_active_pane[src_tab] = np;
    old_tree.deinit();

    // Build a single-node tree for the detached pane. SplitTree.init
    // calls ref(), giving the pane a fresh ownership ref in the new tree.
    const pane_tree = SplitTree(Pane).init(alloc, pane) catch {
        pane.unref(alloc);
        return;
    };
    // The extra ref we took above is no longer needed — the new tree's
    // init ref now owns the pane. Drop the spare.
    pane.unref(alloc);

    const pos: usize = src_tab + 1;
    tabArraysInsertGap(ws.tabArrays(), ws.tab_count, pos);
    ws.tab_trees[pos] = pane_tree;
    ws.tab_active_pane[pos] = pane;
    ws.tab_status[pos] = .normal;
    ws.tab_attention[pos] = false;
    ws.tab_status_text_len[pos] = 0;
    ws.tab_progress[pos] = null;
    ws.tab_log[pos].clear();
    ws.tab_count += 1;

    // Copy the source tab's title to the new tab.
    @memcpy(
        ws.tab_titles[pos][0..ws.tab_title_lens[src_tab]],
        ws.tab_titles[src_tab][0..ws.tab_title_lens[src_tab]],
    );
    ws.tab_title_lens[pos] = ws.tab_title_lens[src_tab];

    const ws_idx = self.workspaceIndex(ws);
    if (ws_idx == self.active_workspace) {
        // Re-layout the source tab (it lost a pane).
        self.layoutSplits();
        // Switch to the new tab.
        self.selectTabIndex(pos);
        self.updateTabBarVisibility();
    } else {
        ws.active_tab = pos;
        self.invalidateSidebar();
    }
}

/// Move the focused pane to an adjacent tab as a split. The pane is
/// detached from its current tree without destroying its surface and
/// joined into the target tab's tree. If it was the only pane in the
/// source tab, that tab is closed.
pub fn movePaneToTab(self: *Window, pane: *Pane, target_enum: apprt.action.MovePaneTarget) void {
    const alloc = self.app.core_app.alloc;
    const loc = self.findLoc(pane) orelse return;
    const ws = loc.ws;
    const src_tab = loc.tab;

    const target_tab: ?usize = switch (target_enum) {
        .next_tab => if (src_tab + 1 < ws.tab_count) src_tab + 1 else null,
        .prev_tab => if (src_tab > 0) src_tab - 1 else null,
        .new_tab => {
            self.breakPane(pane);
            return;
        },
    };
    const dst_tab = target_tab orelse return;

    const is_split = ws.tab_trees[src_tab].isSplit();

    // Bump ref to keep the pane alive through the tree rebuild.
    _ = pane.ref(alloc) catch return;

    if (is_split) {
        const handle = ws.findHandle(src_tab, pane) orelse {
            pane.unref(alloc);
            return;
        };
        const next_handle = (ws.tab_trees[src_tab].goto(alloc, handle, .next) catch null) orelse
            (ws.tab_trees[src_tab].goto(alloc, handle, .previous) catch null);
        const next_pane: ?*Pane = if (next_handle) |nh| switch (ws.tab_trees[src_tab].nodes[nh.idx()]) {
            .leaf => |v| v,
            .split => null,
        } else null;

        const new_src = ws.tab_trees[src_tab].remove(alloc, handle) catch {
            pane.unref(alloc);
            return;
        };
        var old_src = ws.tab_trees[src_tab];
        ws.tab_trees[src_tab] = new_src;
        if (next_pane) |np| ws.tab_active_pane[src_tab] = np;
        old_src.deinit();
    }

    // Build a single-node insert tree for the pane.
    var insert_tree = SplitTree(Pane).init(alloc, pane) catch {
        pane.unref(alloc);
        return;
    };
    defer insert_tree.deinit();
    // Drop the spare ref; the insert tree now owns one.
    pane.unref(alloc);

    // If the source tab was the only pane, close it BEFORE inserting
    // into the destination so that tab indices remain consistent. The
    // pane survives because SplitTree.init took a ref above.
    var actual_dst = dst_tab;
    if (!is_split) {
        const ws_idx = self.workspaceIndex(ws);
        self.closeTabInWorkspace(ws_idx, src_tab);
        if (src_tab < dst_tab) actual_dst = dst_tab - 1;
    }

    // Insert into the destination tab's tree at its root.
    const dst_tree = &ws.tab_trees[actual_dst];
    const new_dst = dst_tree.split(
        alloc,
        .root,
        .right,
        @as(f16, 0.5),
        &insert_tree,
    ) catch return;

    var old_dst = ws.tab_trees[actual_dst];
    ws.tab_trees[actual_dst] = new_dst;
    ws.tab_active_pane[actual_dst] = pane;
    old_dst.deinit();

    const ws_idx = self.workspaceIndex(ws);
    if (ws_idx == self.active_workspace) {
        self.selectTabIndex(actual_dst);
        self.updateTabBarVisibility();
    } else {
        ws.active_tab = actual_dst;
        self.invalidateSidebar();
    }
}

/// Switch to the tab at the given index in the active workspace.
pub fn selectTabIndex(self: *Window, idx: usize) void {
    const ws = self.activeWorkspace();
    if (idx >= ws.tab_count) return;
    self.cancelTabRename();
    // Clear any in-progress tab drag
    if (self.drag_tab >= 0) {
        self.drag_tab = -1;
        self.drag_active = false;
        _ = w32.ReleaseCapture();
    }
    // Clear any in-progress sidebar row drag (e.g. a goto_tab keybind
    // fired mid-drag). handleSidebarClick sets this AFTER its own
    // selectTabIndex call, so the click-then-drag path is unaffected.
    if (self.sidebar_drag_row >= 0) {
        self.sidebar_drag_row = -1;
        self.sidebar_drag_active = false;
        _ = w32.ReleaseCapture();
    }
    if (ws.active_tab < ws.tab_count) {
        var it = ws.tab_trees[ws.active_tab].iterator();
        while (it.next()) |entry| {
            if (entry.view.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }
    ws.active_tab = idx;
    ws.tab_status[idx] = .normal;
    // The tab is now visible: clear any pending attention ring on it
    // (mirrors the bell/exited clear above). The pane.focus() below also
    // clears the focused pane, but a backgrounded split pane in this tab
    // must clear too — the user is looking at the whole tab now.
    self.clearTabAttention(ws, idx);
    const pane = ws.tab_active_pane[idx];
    self.layoutSplits();
    pane.focus();
    self.updateWindowTitle();
    self.invalidateSidebar();
    self.invalidateTabBar();
    self.updateAttentionRings();
    self.updatePaneButtons();
}

/// Switch to the workspace at the given index. Hides the outgoing
/// workspace's visible panes BEFORE making the new one active (so two
/// workspaces never show panes at once), then lays out and focuses the
/// new workspace's active tab. QuickTerminal is single-workspace and
/// early-returns. No-op when the workspace is already active.
pub fn selectWorkspace(self: *Window, idx: usize) void {
    if (self.is_quick_terminal) return;
    if (idx >= self.workspace_count) return;
    if (idx == self.active_workspace) return;
    self.cancelTabRename();

    // Clear any in-progress tab or sidebar-row drag (mirrors
    // selectTabIndex): an async switch (notif click, IPC jump) mid-drag
    // must not leave a captured drag reordering the new workspace's
    // tabs or the shifted rows. handleSidebarClick sets its drag state
    // AFTER calling selectWorkspace, so click-then-drag is unaffected.
    if (self.drag_tab >= 0) {
        self.drag_tab = -1;
        self.drag_active = false;
        _ = w32.ReleaseCapture();
    }
    if (self.sidebar_drag_row >= 0) {
        self.sidebar_drag_row = -1;
        self.sidebar_drag_active = false;
        _ = w32.ReleaseCapture();
    }

    // Hide the outgoing workspace's active-tab panes (the only ones the
    // layout has shown) before switching, mirroring selectTabIndex's
    // hide-before-show ordering.
    const old_ws = self.activeWorkspace();
    if (old_ws.active_tab < old_ws.tab_count) {
        var it = old_ws.tab_trees[old_ws.active_tab].iterator();
        while (it.next()) |entry| {
            if (entry.view.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }

    self.active_workspace = idx;

    // The incoming active tab is now visible: clear its bell/exited
    // status (mirrors selectTabIndex — status is "cleared when the tab
    // is selected"), otherwise the sidebar dot sticks after the user
    // has seen the tab.
    const new_ws = self.activeWorkspace();
    if (new_ws.tab_count > 0) {
        new_ws.tab_status[new_ws.active_tab] = .normal;
        // The incoming active tab is now visible — clear its attention
        // ring too (mirrors the bell/exited clear). Other tabs of this
        // workspace keep their attention so the sidebar row dot persists
        // until each is actually viewed.
        self.clearTabAttention(new_ws, new_ws.active_tab);
    }

    // The new workspace may have a different tab count, so the tab bar's
    // visibility can change. This may resize (changing surfaceRect), so
    // run it before laying out the new active tab.
    self.updateTabBarVisibility();
    self.layoutSplits();
    if (self.getActivePane()) |pane| pane.focus();
    self.updateWindowTitle();
    self.invalidateTabBar();
    self.invalidateSidebar();
    self.updateAttentionRings();
    self.updatePaneButtons();

    // Refresh the now-visible workspace's sidebar metadata off-thread (the
    // periodic timer only scans the active workspace, so a freshly-focused
    // one would otherwise wait a full tick — and background ones never
    // refresh until focused).
    self.app.refreshWorkspaceMetadataNow(self, idx);
}

/// Pure guard for createAndSelectWorkspace: a new workspace slot may be
/// created only on a non-QuickTerminal (multi-workspace) window with
/// fewer than MAX_WORKSPACES slots in use.
fn canCreateWorkspace(is_quick_terminal: bool, count: usize) bool {
    return !is_quick_terminal and count < MAX_WORKSPACES;
}

/// Create a new workspace slot (a new sidebar row) and make it active,
/// WITHOUT giving it a tab. Returns the new index, or null for
/// QuickTerminal (single-workspace) or when the MAX_WORKSPACES cap is
/// reached. The slot is value-initialized (`= .{}`) so tab_status
/// starts .normal and name_len starts 0 (see Workspace).
///
/// Callers MUST immediately populate the workspace with one tab — and
/// collapse it via closeWorkspace(idx) if that fails — so the "every
/// workspace has at least one tab" invariant holds. Shared by
/// newWorkspace (default tab) and showBackendMenu's .new_workspace
/// target (picked-backend tab).
pub fn createAndSelectWorkspace(self: *Window) ?usize {
    if (!canCreateWorkspace(self.is_quick_terminal, self.workspace_count)) return null;
    self.cancelTabRename();

    const idx = self.workspace_count;
    self.workspaces[idx] = .{};
    self.workspace_count += 1;

    // selectWorkspace runs the hide-before-show switch onto the (empty)
    // new workspace; the caller's tab creation then populates it.
    self.selectWorkspace(idx);
    return idx;
}

/// Create a new workspace (a new sidebar row), make it active, and give
/// it one tab. No-op for QuickTerminal (single-workspace) or when the
/// MAX_WORKSPACES cap is reached.
pub fn newWorkspace(self: *Window) void {
    const idx = self.createAndSelectWorkspace() orelse return;
    _ = self.addTab() catch |err| {
        // The slot exists but has no tab. Collapse it back so the window
        // never shows an empty workspace.
        log.err("failed to create first tab for new workspace: {}", .{err});
        self.closeWorkspace(idx);
    };
    self.invalidateSidebar();
}

/// Like newWorkspace, but binds the new workspace to `working_dir` (an
/// owned-by-caller path; copied here) BEFORE spawning its first tab, so
/// that tab — and every later tab of this workspace — opens in that
/// directory. Used by `+workspace new --worktree`. Returns the new
/// workspace index, or null when the workspace could not be created
/// (QuickTerminal, MAX_WORKSPACES) or its first tab failed to spawn (the
/// slot is collapsed back, matching newWorkspace). The working_dir copy
/// is freed by the workspace teardown paths (closeWorkspace /
/// cleanupAllSurfaces).
pub fn newWorkspaceWithDir(self: *Window, working_dir: []const u8) ?usize {
    const idx = self.createAndSelectWorkspace() orelse return null;
    // Bind the directory before addTab: addTabWithCommand reads
    // workspaces[active].working_dir to build the surface config clone.
    self.workspaces[idx].setWorkingDir(self.app.core_app.alloc, working_dir) catch {
        // Couldn't even copy the path; collapse the empty slot.
        self.closeWorkspace(idx);
        return null;
    };
    _ = self.addTab() catch |err| {
        log.err("failed to create first tab for new worktree workspace: {}", .{err});
        // closeWorkspace frees the binding we just set.
        self.closeWorkspace(idx);
        return null;
    };
    self.invalidateSidebar();
    // Surface the git branch for the freshly-bound worktree right away
    // rather than waiting for the first periodic tick. The child shell may
    // not have a PID yet (ports come on a later tick), but rev-parse only
    // needs the directory.
    self.app.refreshWorkspaceMetadataNow(self, idx);
    return idx;
}

/// Create a new workspace slot (a new sidebar row) WITHOUT selecting it
/// and WITHOUT touching the active workspace. The counterpart to
/// createAndSelectWorkspace's create-half, kept separate so the agent IPC
/// (`+workspace new` without `--focus`) can create a background workspace
/// the user is NOT yanked into. Returns the new index, or null for
/// QuickTerminal or when MAX_WORKSPACES is reached. Callers MUST populate
/// it with one tab (and collapse via collapseEmptyWorkspaceSlot on
/// failure) so the "every workspace has at least one tab" invariant holds.
fn createWorkspaceSlot(self: *Window) ?usize {
    if (!canCreateWorkspace(self.is_quick_terminal, self.workspace_count)) return null;
    self.cancelTabRename();
    const idx = self.workspace_count;
    self.workspaces[idx] = .{};
    self.workspace_count += 1;
    return idx;
}

/// Add the first tab to a workspace that is NOT the active one, keeping
/// the active workspace visible and focused. Mirrors addTabWithCommand's
/// per-tab bookkeeping but targets `ws_idx` explicitly and, crucially,
/// HIDES the freshly created surface's child HWND: Surface.init shows the
/// child (it needs a visible, sized window to spawn its ConPTY), which
/// would otherwise paint the background workspace's pane over the visible
/// one. The hidden pane is laid out and shown the first time
/// selectWorkspace switches to this workspace, matching the
/// background-workspace discipline used by closeTabInWorkspace /
/// closeSplitPane. The new tab becomes the workspace's own active_tab
/// (index 0) so a later switch lands on it.
fn addFirstTabBackground(self: *Window, ws_idx: usize, command: ?[]const []const u8) !void {
    if (self.closing) return error.WindowClosing;
    if (ws_idx >= self.workspace_count) return error.NoWindow;
    const ws = &self.workspaces[ws_idx];
    std.debug.assert(ws.tab_count == 0);

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    try surface.init(self.app, self, .tab, command, ws.working_dir);
    const pane = Pane.create(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    var tree = SplitTree(Pane).init(alloc, pane) catch |err| {
        alloc.destroy(pane);
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit();

    // Hide the child HWND Surface.init just showed: this workspace is not
    // active, so its pane must not be visible over the active workspace.
    if (surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);

    // First (and only) tab goes in slot 0. The slot was just value-inited
    // by createWorkspaceSlot, so the orchestration metadata arrays
    // (tab_status, tab_status_text_len, tab_progress, tab_log) already
    // hold their clean defaults — no per-tab reset is needed here.
    ws.tab_trees[0] = tree;
    ws.tab_active_pane[0] = pane;
    ws.tab_status[0] = .normal;
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(ws.tab_titles[0][0..default_title.len], default_title);
    ws.tab_title_lens[0] = @intCast(default_title.len);
    ws.active_tab = 0;
    ws.tab_count = 1;

    self.invalidateSidebar();
}

/// Like newWorkspace / newWorkspaceWithDir, but creates the workspace in
/// the BACKGROUND: the active workspace does not change and the user is
/// not pulled in. Used by the agent IPC `+workspace new` (no `--focus`),
/// the non-focus default for programmatic creation. `working_dir` (an
/// owned-by-caller path; copied here) binds the workspace to a git
/// worktree like newWorkspaceWithDir; null keeps the configured cwd.
/// `command` (an argv slice; borrowed, NOT owned) is passed to the first
/// tab's surface.init so the tab runs that command instead of the default
/// shell. Used by `+ssh --workspace` to create a workspace whose first
/// tab runs `ssh user@host`. Returns the new index, or null when the
/// workspace could not be created (QuickTerminal, MAX_WORKSPACES) or its
/// first tab failed to spawn (the slot is collapsed back).
pub fn newWorkspaceBackground(self: *Window, working_dir: ?[]const u8, command: ?[]const []const u8) ?usize {
    const idx = self.createWorkspaceSlot() orelse return null;
    if (working_dir) |dir| {
        self.workspaces[idx].setWorkingDir(self.app.core_app.alloc, dir) catch {
            self.collapseEmptyWorkspaceSlot(idx);
            return null;
        };
    }
    self.addFirstTabBackground(idx, command) catch |err| {
        log.err("failed to create first tab for background workspace: {}", .{err});
        self.collapseEmptyWorkspaceSlot(idx);
        return null;
    };
    self.invalidateSidebar();
    // Surface git/port metadata for a worktree-bound workspace right away
    // (matches newWorkspaceWithDir); harmless for a plain background slot.
    if (working_dir != null) self.app.refreshWorkspaceMetadataNow(self, idx);
    return idx;
}

/// Drop a background workspace slot whose first tab failed to spawn,
/// WITHOUT going through closeWorkspace (which would re-select a survivor
/// and could close the window when this is the last slot — neither is
/// wanted for a never-shown background slot). The slot is the last one
/// (createWorkspaceSlot appends), is empty (tab_count == 0), and is not
/// the active workspace, so dropping it is pure bookkeeping: free its
/// worktree binding and decrement the count.
fn collapseEmptyWorkspaceSlot(self: *Window, idx: usize) void {
    if (idx + 1 != self.workspace_count) return;
    if (idx == self.active_workspace) return;
    self.workspaces[idx].freeWorkingDir(self.app.core_app.alloc);
    self.workspaces[idx] = .{};
    self.workspace_count -= 1;
    self.invalidateSidebar();
}

/// Set workspace `idx`'s sidebar name from a UTF-8 string, mirroring the
/// inline-rename write path (truncated to the name buffer; invalid UTF-8
/// leaves the name unchanged). Used by the agent IPC `workspace-new
/// --name`. No-op for an out-of-range index.
pub fn setWorkspaceName(self: *Window, idx: usize, name: []const u8) void {
    if (idx >= self.workspace_count) return;
    const wsp = &self.workspaces[idx];
    const nlen = std.unicode.utf8ToUtf16Le(
        &wsp.name,
        name[0..@min(name.len, wsp.name.len)],
    ) catch return;
    wsp.name_len = @intCast(@min(nlen, wsp.name.len));
    self.invalidateSidebar();
}

/// Set workspace `idx`'s sidebar description from a UTF-8 string,
/// mirroring setWorkspaceName (truncated to the description buffer;
/// invalid UTF-8 leaves the description unchanged). Used by the IPC
/// `workspace-set-description` command. No-op for an out-of-range index.
pub fn setWorkspaceDescription(self: *Window, idx: usize, text: []const u8) void {
    if (idx >= self.workspace_count) return;
    const wsp = &self.workspaces[idx];
    const dlen = std.unicode.utf8ToUtf16Le(
        &wsp.description,
        text[0..@min(text.len, wsp.description.len)],
    ) catch return;
    wsp.description_len = @intCast(@min(dlen, wsp.description.len));
    self.invalidateSidebar();
}

/// Pure index arithmetic for closeWorkspace, HWND-free so it can be
/// unit tested exhaustively. Closing the only workspace closes the
/// window. Otherwise the caller shifts slots [idx+1, count) left one
/// (`for (idx..new_count) |i| slot[i] = slot[i+1]`), value-inits the
/// now-duplicate slot at new_count, and selects new_active: a surviving
/// active workspace follows its shifted slot, and closing the active
/// one selects the workspace that slid into its slot, clamped to the
/// new last index.
const CloseWorkspaceArith = union(enum) {
    close_window,
    survivors: struct {
        new_count: usize,
        new_active: usize,
    },
};

fn closeWorkspaceArith(count: usize, active: usize, idx: usize) CloseWorkspaceArith {
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

/// Close the workspace at `idx`: deinit all its tab trees (each unrefs
/// its panes), then either close the window (if it was the only
/// workspace) or shift the survivors down and select a neighbor.
pub fn closeWorkspace(self: *Window, idx: usize) void {
    if (self.is_quick_terminal) return;
    if (idx >= self.workspace_count) return;
    self.cancelTabRename();

    const arith = closeWorkspaceArith(self.workspace_count, self.active_workspace, idx);

    // Last workspace → close the whole window. Mirror closeTabByIndex's
    // last-tab path: flag closing FIRST so re-entrant input/focus
    // messages are dropped while the trees tear down, then post WM_CLOSE.
    if (arith == .close_window) {
        self.closing = true;
        const ws = &self.workspaces[idx];
        for (ws.tab_trees[0..ws.tab_count]) |*tree| {
            tree.deinit();
            tree.* = .empty;
        }
        ws.tab_count = 0;
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }

    // If we are closing the active workspace, hide its visible panes
    // first (like selectWorkspace's hide-before-show) so no torn-down
    // panes linger on screen during the deinit.
    if (idx == self.active_workspace) {
        const ws = &self.workspaces[idx];
        if (ws.active_tab < ws.tab_count) {
            var it = ws.tab_trees[ws.active_tab].iterator();
            while (it.next()) |entry| {
                if (entry.view.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
    }

    // The survivor to focus AFTER the shift: the workspace that ends up
    // where this one was, clamped to the new last index. If the active
    // workspace sat after the removed one, its index shifts down. All
    // computed by closeWorkspaceArith above.
    const new_count = arith.survivors.new_count;
    const survivor = arith.survivors.new_active;

    // PUBLISH the post-shift workspaces array + active_workspace BEFORE
    // deiniting the closed workspace's trees: the deinit can destroy a
    // browser host HWND, which moves focus synchronously and re-enters
    // wndprocs that read workspaces/active_workspace. They must observe
    // the shifted, survivor-active state, never the dying workspace.
    // Move the closed workspace's struct OUT first (a value copy) so the
    // shift can overwrite its slot; deinit the copy afterward.
    var dying = self.workspaces[idx];
    for (idx..new_count) |i| {
        self.workspaces[i] = self.workspaces[i + 1];
    }
    // The shift leaves a duplicate of the last workspace past the new
    // count, whose tab_trees alias the live workspace's heap data;
    // value-init the slot so nothing can ever walk it (mirrors
    // closeTabByIndex clearing its duplicated tree slot).
    self.workspaces[new_count] = .{};
    self.workspace_count = new_count;
    self.active_workspace = survivor;

    // Tear down the closed workspace's trees from the value copy now that
    // the live array no longer references them. Free its worktree binding
    // here too: the shift moved every survivor's working_dir pointer down
    // by value, so only this removed slot's copy is unreferenced.
    for (dying.tab_trees[0..dying.tab_count]) |*tree| {
        tree.deinit();
    }
    dying.freeWorkingDir(self.app.core_app.alloc);

    // Lay out and focus the survivor. updateTabBarVisibility first (the
    // survivor may have a different tab count, changing surfaceRect).
    self.updateTabBarVisibility();
    self.layoutSplits();
    if (self.getActivePane()) |pane| pane.focus();
    self.updateWindowTitle();
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Pure active-index fixup for moveWorkspaceTo: the slot at `from`
/// moved to `to`, shifting every slot between them one toward `from`;
/// return where the index `active` lands so the same workspace stays
/// active. Identity when from == to. HWND-free so it can be unit
/// tested exhaustively.
fn moveActiveFixup(active: usize, from: usize, to: usize) usize {
    if (active == from) return to;
    if (from < to and active > from and active <= to) return active - 1;
    if (from > to and active >= to and active < from) return active + 1;
    return active;
}

/// Move the workspace at `from` to `to`, shifting the workspaces between
/// them. Fixes up active_workspace so the same workspace stays active.
/// Analogous to moveTabTo. No-op for QuickTerminal or out-of-range.
pub fn moveWorkspaceTo(self: *Window, from: usize, to: usize) void {
    if (self.is_quick_terminal) return;
    if (from == to) return;
    if (from >= self.workspace_count or to >= self.workspace_count) return;
    self.cancelTabRename();

    // Lift the source workspace out, shift the workspaces between, drop
    // it at the destination (value shuffle of the whole struct).
    const saved = self.workspaces[from];
    if (from < to) {
        var i: usize = from;
        while (i < to) : (i += 1) self.workspaces[i] = self.workspaces[i + 1];
    } else {
        var i: usize = from;
        while (i > to) : (i -= 1) self.workspaces[i] = self.workspaces[i - 1];
    }
    self.workspaces[to] = saved;

    // Fix up active_workspace so the same workspace stays active across
    // the shuffle (pure arithmetic mirroring the shift above).
    self.active_workspace = moveActiveFixup(self.active_workspace, from, to);

    self.invalidateSidebar();
}

/// Layout split panes for the active tab.
pub fn layoutSplits(self: *Window) void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    const tree = ws.tab_trees[ws.active_tab];
    const rect = self.surfaceRect();
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle == zoomed_handle) {
                if (entry.view.hwnd()) |h| {
                    const w = @max(rect.right - rect.left, 1);
                    const ht = @max(rect.bottom - rect.top, 1);
                    _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                    _ = w32.ShowWindow(h, w32.SW_SHOW);
                }
            } else {
                if (entry.view.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
        return;
    }
    self.layoutNode(tree, .root, rect);

    // Paint divider lines directly using GetDC (not BeginPaint, which
    // clips to the invalid region and misses the content area gaps).
    if (self.hwnd) |hwnd| {
        const hdc = w32.GetDC(hwnd);
        if (hdc) |dc| {
            self.paintDividers(dc);
            _ = w32.ReleaseDC(hwnd, dc);
        }
    }

    // Keep the notification rings glued to the just-laid-out panes
    // (resize/split/zoom all flow through here).
    self.updateAttentionRings();
    // Re-glue the per-pane corner buttons too (after the rings so the
    // clickable cluster is never occluded by a ring popup).
    self.updatePaneButtons();
}

fn layoutNode(self: *Window, tree: SplitTree(Pane), handle: SplitTree(Pane).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            if (view.hwnd()) |h| {
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

/// Reconcile the notification-ring overlays with the current attention
/// state and layout. A ring is drawn around each pane of the ACTIVE
/// workspace's ACTIVE tab whose Surface.attention is set AND which is not
/// the focused/visible-active pane — you are never ringed around what you
/// are already looking at. Panes in other tabs/workspaces are not visible,
/// so they carry no ring; the sidebar row dot and top tab dot surface
/// those instead. Rings are reused from a pool; surplus rings are hidden.
/// Safe to call after any layout/attention/focus change; cheap when no
/// pane needs a ring (every existing ring is simply hidden).
pub fn updateAttentionRings(self: *Window) void {
    // No chrome on a closing/zoomed/empty window: hide everything.
    const hwnd = self.hwnd orelse return self.hideAllRings();
    if (self.closing) return self.hideAllRings();
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return self.hideAllRings();
    const tree = ws.tab_trees[ws.active_tab];
    // A zoomed tab shows a single pane full-bleed; ringing it would frame
    // the whole content area, so suppress rings while zoomed.
    if (tree.zoomed != null) return self.hideAllRings();

    const focused = ws.tab_active_pane[ws.active_tab];
    var next: usize = 0;
    self.attentionRingNode(hwnd, tree, .root, self.surfaceRect(), focused, &next);

    // Hide any rings beyond the ones we just positioned this pass.
    var i = next;
    while (i < self.attention_rings.items.len) : (i += 1) {
        self.attention_rings.items[i].hide();
    }
}

/// Hide every ring in the pool (no visible attention pane).
fn hideAllRings(self: *Window) void {
    for (self.attention_rings.items) |ring| ring.hide();
}

/// Borrow ring slot `idx` from the pool, growing it (creating a new
/// layered popup) on demand. Returns null if creation fails (the ring is
/// then simply skipped — attention still surfaces via the sidebar/tab
/// dots, so a GDI handle shortage degrades gracefully).
fn ringAt(self: *Window, idx: usize, hwnd: w32.HWND) ?*AttentionRing {
    if (idx < self.attention_rings.items.len) {
        const ring = self.attention_rings.items[idx];
        ring.setScale(self.scale);
        return ring;
    }
    const ring = AttentionRing.create(self.app.core_app.alloc, self.app.hinstance, hwnd) catch return null;
    ring.setScale(self.scale);
    self.attention_rings.append(self.app.core_app.alloc, ring) catch {
        ring.destroy();
        return null;
    };
    return ring;
}

/// Walk the tab tree mirroring layoutNode's geometry; for each leaf pane
/// that is an attention-flagged terminal other than `focused`, position a
/// pool ring around its client rect (converted to screen coords).
/// `next` is the running count of rings used this pass.
fn attentionRingNode(
    self: *Window,
    hwnd: w32.HWND,
    tree: SplitTree(Pane),
    handle: SplitTree(Pane).Node.Handle,
    rect: w32.RECT,
    focused: *Pane,
    next: *usize,
) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            if (view == focused) return;
            const surface = view.surface() orelse return;
            if (!surface.attention) return;
            const ring = self.ringAt(next.*, hwnd) orelse return;
            // Client rect → screen rect (the popup lives in screen coords).
            var tl = w32.POINT{ .x = rect.left, .y = rect.top };
            var br = w32.POINT{ .x = rect.right, .y = rect.bottom };
            _ = w32.ClientToScreen(hwnd, &tl);
            _ = w32.ClientToScreen(hwnd, &br);
            ring.positionAround(.{ .left = tl.x, .top = tl.y, .right = br.x, .bottom = br.y });
            next.* += 1;
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.attentionRingNode(hwnd, tree, s.left, left_rect, focused, next);
                self.attentionRingNode(hwnd, tree, s.right, right_rect, focused, next);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.attentionRingNode(hwnd, tree, s.left, top_rect, focused, next);
                self.attentionRingNode(hwnd, tree, s.right, bottom_rect, focused, next);
            }
        },
    }
}

/// Reconcile the per-pane corner-button overlays with the current layout.
/// Policy: show a cluster on EVERY visible leaf pane of the active
/// workspace's active tab (every pane gets its action icons, always — not
/// just the focused one). Panes in other tabs/workspaces are not visible,
/// so they carry no cluster. A zoomed tab shows only its focused pane, so
/// it gets a single cluster. Cheap to call after any layout/focus change.
/// Runs AFTER updateAttentionRings each pass (called second in layoutSplits)
/// so the clickable cluster's popup is never occluded by a ring popup at the
/// shared top-right corner. Safe to call repeatedly; surplus overlays in
/// the pool are hidden.
pub fn updatePaneButtons(self: *Window) void {
    // No chrome on a closing/empty window: hide everything.
    const hwnd = self.hwnd orelse return self.hideAllPaneButtons();
    if (self.closing) return self.hideAllPaneButtons();
    // QuickTerminals are bare popups with no tab/pane chrome.
    if (self.is_quick_terminal) return self.hideAllPaneButtons();
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return self.hideAllPaneButtons();

    const tree = ws.tab_trees[ws.active_tab];
    const focused = ws.tab_active_pane[ws.active_tab];

    var next: usize = 0;

    // Locate the focused pane's content rect by walking the same split
    // geometry layoutNode uses, then place one cluster at its top-right.
    if (tree.zoomed) |zoomed_handle| {
        // A zoomed tab shows the focused pane full-bleed; place the
        // cluster at the full surface rect's top-right.
        _ = zoomed_handle;
        self.placePaneButton(hwnd, focused, self.surfaceRect(), &next);
    } else {
        self.paneButtonsNode(hwnd, tree, .root, self.surfaceRect(), &next);
    }

    // Hide any overlays beyond the one we positioned this pass.
    var i = next;
    while (i < self.pane_buttons.items.len) : (i += 1) {
        self.pane_buttons.items[i].hide();
    }
}

/// Hide every corner-button overlay in the pool.
fn hideAllPaneButtons(self: *Window) void {
    for (self.pane_buttons.items) |pb| pb.hide();
}

/// Borrow overlay slot `idx` from the pool, growing it (creating a new
/// layered popup) on demand. Returns null if creation fails (the cluster
/// is then simply skipped — a GDI handle shortage degrades to "no corner
/// icons", which is non-fatal).
fn paneButtonsAt(self: *Window, idx: usize, hwnd: w32.HWND) ?*PaneButtons {
    if (idx < self.pane_buttons.items.len) {
        const pb = self.pane_buttons.items[idx];
        pb.setScale(self.scale);
        return pb;
    }
    const pb = PaneButtons.create(self.app.core_app.alloc, self.app.hinstance, hwnd) catch return null;
    pb.setScale(self.scale);
    self.pane_buttons.append(self.app.core_app.alloc, pb) catch {
        pb.destroy();
        return null;
    };
    return pb;
}

/// Position one corner-button overlay around `pane`'s client rect (in
/// client coords; converted to screen here), binding it to the pane and
/// this window. `next` is the running count of overlays used this pass.
fn placePaneButton(self: *Window, hwnd: w32.HWND, pane: *Pane, rect: w32.RECT, next: *usize) void {
    const pb = self.paneButtonsAt(next.*, hwnd) orelse return;
    var tl = w32.POINT{ .x = rect.left, .y = rect.top };
    var br = w32.POINT{ .x = rect.right, .y = rect.bottom };
    _ = w32.ClientToScreen(hwnd, &tl);
    _ = w32.ClientToScreen(hwnd, &br);
    pb.positionAt(
        .{ .left = tl.x, .top = tl.y, .right = br.x, .bottom = br.y },
        pane,
        @ptrCast(self),
    );
    next.* += 1;
}

/// Walk the tab tree mirroring layoutNode's geometry; place a corner
/// cluster on EVERY leaf pane so the action icons are visible on all
/// panes at all times (not just the focused one). Mirrors
/// attentionRingNode's recursion exactly so the geometry agrees.
fn paneButtonsNode(
    self: *Window,
    hwnd: w32.HWND,
    tree: SplitTree(Pane),
    handle: SplitTree(Pane).Node.Handle,
    rect: w32.RECT,
    next: *usize,
) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            // Every leaf pane gets its own always-visible corner cluster.
            self.placePaneButton(hwnd, view, rect, next);
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.paneButtonsNode(hwnd, tree, s.left, left_rect, next);
                self.paneButtonsNode(hwnd, tree, s.right, right_rect, next);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.paneButtonsNode(hwnd, tree, s.left, top_rect, next);
                self.paneButtonsNode(hwnd, tree, s.right, bottom_rect, next);
            }
        },
    }
}

/// Routed from a corner-button overlay click (PaneButtons.on_click). The
/// `window` opaque is this *Window; `pane` is validated by address before
/// any action runs (it may have been closed since the overlay was
/// positioned). All four actions (New Terminal / New Browser / Split Right
/// / Split Down) operate on the active pane, so the target pane is brought
/// to the foreground and focused first.
pub fn onPaneButtonClick(window: *anyopaque, pane: *Pane, action: PaneButtonsMod.Action) void {
    const self: *Window = @ptrCast(@alignCast(window));
    if (self.closing) return;
    // Validate the pane still exists in this window (by address) and
    // bring its workspace/tab/pane to the foreground so the active-pane
    // actions (New Terminal/Browser/Split Right/Split Down) target it.
    const loc = self.findLoc(pane) orelse return;
    const ws_idx = self.workspaceIndex(loc.ws);
    if (ws_idx != self.active_workspace) self.selectWorkspace(ws_idx);
    if (loc.ws.active_tab != loc.tab) self.selectTabIndex(loc.tab);
    // Make the clicked pane the focused one within its tab so the
    // active-pane operations split/inherit from it.
    loc.ws.tab_active_pane[loc.tab] = pane;
    pane.focus();

    switch (action) {
        .new_terminal => _ = self.addTabInherit() catch |err| {
            log.err("corner New Terminal failed: {}", .{err});
        },
        .new_browser => self.addBrowserTab() catch |err| {
            log.err("corner New Browser failed: {}", .{err});
        },
        .split_right => self.newSplit(.right) catch |err| {
            log.err("corner Split Right failed: {}", .{err});
        },
        .split_down => self.newSplit(.down) catch |err| {
            log.err("corner Split Down failed: {}", .{err});
        },
    }
}

/// Paint divider lines between split panes in the active tab.
fn paintDividers(self: *Window, hdc: w32.HDC) void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    const tree = ws.tab_trees[ws.active_tab];
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return;
    const rect = self.surfaceRect();
    self.paintDividerNode(hdc, tree, .root, rect);
}

fn paintDividerNode(self: *Window, hdc: w32.HDC, tree: SplitTree(Pane), handle: SplitTree(Pane).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => {},
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            const line_w: i32 = @max(@as(i32, @intFromFloat(@round(1.0 * self.scale))), 1);

            const pen = w32.CreatePen(0, line_w, 0x00808080) orelse return;
            defer _ = w32.DeleteObject(pen);
            const old_pen = w32.SelectObject(hdc, pen);
            defer _ = w32.SelectObject(hdc, old_pen);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                _ = w32.MoveToEx(hdc, split_x, rect.top, null);
                _ = w32.LineTo(hdc, split_x, rect.bottom);
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, left_rect);
                self.paintDividerNode(hdc, tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                _ = w32.MoveToEx(hdc, rect.left, split_y, null);
                _ = w32.LineTo(hdc, rect.right, split_y);
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, top_rect);
                self.paintDividerNode(hdc, tree, s.right, bottom_rect);
            }
        },
    }
}

const DividerHit = struct {
    handle: SplitTree(Pane).Node.Handle,
    layout: SplitTree(Pane).Split.Layout,
};

fn hitTestDivider(self: *Window, x: i32, y: i32) ?DividerHit {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return null;
    const tree = ws.tab_trees[ws.active_tab];
    if (!tree.isSplit()) return null;
    if (tree.zoomed != null) return null;
    const rect = self.surfaceRect();
    return self.hitTestDividerNode(tree, .root, rect, x, y);
}

fn hitTestDividerNode(
    self: *Window,
    tree: SplitTree(Pane),
    handle: SplitTree(Pane).Node.Handle,
    rect: w32.RECT,
    x: i32,
    y: i32,
) ?DividerHit {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => return null,
        .split => |s| {
            const gap: i32 = @as(i32, @intFromFloat(@round(5.0 * self.scale)));
            const hit_area: i32 = @max(@as(i32, @intFromFloat(@round(3.0 * self.scale))), 3);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                if (x >= split_x - hit_area and x <= split_x + hit_area and y >= rect.top and y <= rect.bottom) {
                    return .{ .handle = handle, .layout = .horizontal };
                }
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

fn startDividerDrag(self: *Window, handle: SplitTree(Pane).Node.Handle, layout: SplitTree(Pane).Split.Layout) void {
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

    const ws = self.activeWorkspace();
    ws.tab_trees[ws.active_tab].resizeInPlace(handle, new_ratio);
    self.layoutSplits();
}

fn endDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
}

/// True when x is inside the drag-resize grab band along the sidebar's
/// right edge. A hidden sidebar has no band.
fn hitTestSidebarEdge(self: *const Window, x: i32) bool {
    return Sidebar.hitTestEdge(x, self.sidebarWidth(), Sidebar.edgeBandWidth(self.scale));
}

fn startSidebarDrag(self: *Window) void {
    if (self.closing) return;
    self.dragging_sidebar = true;
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

fn updateSidebarDrag(self: *Window, x: i32) void {
    if (!self.dragging_sidebar or self.closing) return;
    const unscaled = std.math.clamp(
        @round(@as(f32, @floatFromInt(x)) / self.scale),
        @as(f32, @floatFromInt(Sidebar.MIN_WIDTH)),
        @as(f32, @floatFromInt(Sidebar.MAX_WIDTH)),
    );
    const new_width: u32 = @intFromFloat(unscaled);
    if (self.sidebar_width_override) |cur| if (cur == new_width) return;
    self.sidebar_width_override = new_width;
    // Same live relayout as the divider drag: move the surfaces and
    // repaint the chrome strips immediately.
    self.handleResize();
    if (self.hwnd) |h| _ = w32.UpdateWindow(h);
}

fn endSidebarDrag(self: *Window) void {
    if (!self.dragging_sidebar) return;
    self.dragging_sidebar = false;
    _ = w32.ReleaseCapture();
}

/// End an in-progress sidebar row drag-reorder, releasing capture if
/// one was held. Idempotent: a no-op when no row drag is active.
fn endSidebarRowDrag(self: *Window) void {
    if (self.sidebar_drag_row < 0) return;
    self.sidebar_drag_row = -1;
    self.sidebar_drag_active = false;
    _ = w32.ReleaseCapture();
}

/// Compute the target workspace row index for a sidebar row drag at
/// client y. Mirrors the tab bar's midpoint rule: the slot whose
/// midpoint the cursor has passed. Clamped to the valid workspace row
/// range (the sidebar lists workspaces, one row each).
fn sidebarDragTarget(self: *const Window, y: i32) usize {
    if (self.workspace_count == 0) return 0;
    const item_h = self.sidebarItemHeight();
    if (item_h <= 0) return 0;
    var target: usize = 0;
    for (0..self.workspace_count) |i| {
        const slot_top: i32 = @as(i32, @intCast(i)) * item_h;
        const slot_mid = slot_top + @divTrunc(item_h, 2);
        if (y >= slot_mid) target = i;
    }
    if (target >= self.workspace_count) target = self.workspace_count - 1;
    return target;
}

/// Create a new split in the active tab. Splits inherit the source
/// pane's backend (Windows Terminal semantics): a split off a WSL or
/// PowerShell tab opens the same shell. Browser panes have no terminal
/// surface, so a split off one falls back to the configured default.
pub fn newSplit(self: *Window, direction: SplitTree(Pane).Split.Direction) !void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    // Surface.init deep copies the argv, so borrowing the source
    // surface's copy is fine.
    const command: ?[]const []const u8 = if (ws.tab_active_pane[ws.active_tab].surface()) |src|
        src.spawn_command
    else
        null;
    return self.newSplitWithCommand(direction, command);
}

/// Like newSplit, but with an explicit command override (the backend
/// picker) instead of inheriting the source pane's backend. Null runs
/// the configured default. The argv is copied by Surface.init, so the
/// caller's memory may be freed once this returns. Splits the ACTIVE
/// workspace's active tab and focuses the new pane (the interactive UX).
pub fn newSplitWithCommand(
    self: *Window,
    direction: SplitTree(Pane).Split.Direction,
    command: ?[]const []const u8,
) !void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    _ = try self.newSplitInWorkspace(self.active_workspace, ws.active_tab, direction, command, true);
}

/// Split the active pane of (ws_idx, tab_idx) — which need NOT be the
/// active workspace/tab — in `direction`. With `focus` true this is the
/// interactive split: the new pane is focused and the tab re-laid-out (the
/// caller must have selected the workspace/tab so it is the active one).
/// With `focus` false this is the background (agent `+split` without
/// `--focus`) path: the new pane is created and inserted into the tab tree
/// but the active workspace/tab/pane is NOT changed and the new pane's
/// child HWND is kept hidden (it is shown on the next layoutSplits when its
/// workspace+tab becomes active), so a programmatic split never yanks the
/// user's focus or foreground. Returns the new pane. `command` mirrors
/// newSplitWithCommand (null inherits/defaults; the argv is copied).
pub fn newSplitInWorkspace(
    self: *Window,
    ws_idx: usize,
    tab_idx: usize,
    direction: SplitTree(Pane).Split.Direction,
    command: ?[]const []const u8,
    focus: bool,
) !*Pane {
    if (self.closing) return error.WindowClosing;
    if (ws_idx >= self.workspace_count) return error.NoWindow;
    const ws = &self.workspaces[ws_idx];
    if (tab_idx >= ws.tab_count) return error.UnknownTab;
    const alloc = self.app.core_app.alloc;

    const active_pane = ws.tab_active_pane[tab_idx];
    const handle = ws.findHandle(tab_idx, active_pane) orelse return error.UnknownPane;

    // Create new surface.
    const new_surface = try alloc.create(Surface);
    errdefer {
        new_surface.deinit();
        alloc.destroy(new_surface);
    }
    // Splits inherit the source pane's live cwd via OSC 7 / pwd
    // (split-inherit-working-directory), so they need no explicit
    // worktree override here.
    try new_surface.init(self.app, self, .split, command, null);

    // A background split (the target tab is not the visible active tab)
    // must hide the child HWND Surface.init showed so it never paints over
    // the active tab; layoutSplits shows it when this tab becomes active.
    const is_visible = focus and ws_idx == self.active_workspace and tab_idx == ws.active_tab;
    if (!is_visible) {
        if (new_surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    }

    // Create a single-node tree for the new surface's pane. The block
    // scopes the pane errdefer to the window between Pane.create and
    // the tree taking ownership via ref().
    var inserted_pane: *Pane = undefined;
    var insert_tree = blk: {
        const new_pane = try Pane.create(alloc, new_surface);
        errdefer alloc.destroy(new_pane);
        const tree = try SplitTree(Pane).init(alloc, new_pane);
        inserted_pane = new_pane;
        break :blk tree;
    };
    defer insert_tree.deinit();

    // Split the current tree at the active pane.
    const new_tree = try ws.tab_trees[tab_idx].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    // Replace old tree.
    var old_tree = ws.tab_trees[tab_idx];
    old_tree.deinit();
    ws.tab_trees[tab_idx] = new_tree;

    if (focus) {
        // Interactive: the new pane becomes the tab's active pane, the
        // (active) tab is re-laid-out, and the new pane takes keyboard
        // focus.
        ws.tab_active_pane[tab_idx] = inserted_pane;
        if (is_visible) self.layoutSplits();
        inserted_pane.focus();
    } else {
        // Background: do NOT change the tab's active pane or focus. If the
        // split happens to land in the currently-visible active tab,
        // re-lay-it-out so the new pane appears without stealing focus;
        // otherwise it stays hidden until its tab is shown.
        if (ws_idx == self.active_workspace and tab_idx == ws.active_tab)
            self.layoutSplits();
    }
    self.invalidateSidebar();
    return inserted_pane;
}

/// Create a new browser (WebView2) split in the active tab, in the
/// given direction off the active pane.
pub fn newBrowserSplit(self: *Window, direction: SplitTree(Pane).Split.Direction) !void {
    if (self.closing) return;
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) {
        // Not reachable from the current UI (the sidebar/context menu
        // only exist on live windows, which always have >= 1 tab).
        log.warn("newBrowserSplit: no tabs, ignoring", .{});
        return;
    }
    // An in-progress inline tab rename owns an Edit control whose
    // teardown re-enters via EN_KILLFOCUS; settle it before mutating
    // the tree (same protocol as addTabWithCommand/selectTabIndex).
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;
    const tab = ws.active_tab;

    const active_pane = ws.tab_active_pane[tab];
    const handle = ws.findHandle(tab, active_pane) orelse return;

    // Build the single-pane insert tree. The errdefers only cover the
    // gap until the tree takes ownership via ref(); after the block,
    // insert_tree.deinit() is the sole cleanup path (no double-free
    // when split() fails).
    var browser: *BrowserPane = undefined;
    var browser_pane: *Pane = undefined;
    var insert_tree = blk: {
        const b = try BrowserPane.create(alloc, self.app, self);
        errdefer b.destroy(alloc);
        const new_pane = try Pane.createBrowser(alloc, b);
        errdefer alloc.destroy(new_pane);
        const tree = try SplitTree(Pane).init(alloc, new_pane);
        browser = b;
        browser_pane = new_pane;
        break :blk tree;
    };
    defer insert_tree.deinit();

    const new_tree = try ws.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    var old_tree = ws.tab_trees[tab];
    old_tree.deinit();
    ws.tab_trees[tab] = new_tree;

    ws.tab_active_pane[tab] = browser_pane;
    self.layoutSplits();

    // Begin async WebView2 creation now that the tree owns the pane
    // (the in-flight race guard refs it).
    browser.startCreation();

    // Focus the address bar so the user can type a URL immediately.
    if (browser.address_edit) |edit| {
        _ = w32.SetFocus(edit);
    } else {
        browser_pane.focus();
    }
}

/// Navigate to a split in the given direction.
pub fn gotoSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = ws.active_tab;
    const tree = &ws.tab_trees[tab];

    const active_pane = ws.tab_active_pane[tab];
    const handle = ws.findHandle(tab, active_pane) orelse return;

    const target: SplitTree(Pane).Goto = switch (goto_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dest_handle = (tree.goto(alloc, handle, target) catch return) orelse return;

    switch (tree.nodes[dest_handle.idx()]) {
        .leaf => |pane| {
            ws.tab_active_pane[tab] = pane;
            pane.focus();
        },
        .split => {},
    }
}

/// Swap the focused split with the split in the given direction.
pub fn swapSplit(self: *Window, swap_target: apprt.action.GotoSplit) void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = ws.active_tab;
    const tree = &ws.tab_trees[tab];

    const active_pane = ws.tab_active_pane[tab];
    const src_handle = ws.findHandle(tab, active_pane) orelse return;

    const target: SplitTree(Pane).Goto = switch (swap_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dst_handle = (tree.goto(alloc, src_handle, target) catch return) orelse return;

    const new_tree = tree.swap(alloc, src_handle, dst_handle) catch return;
    var old_tree = ws.tab_trees[tab];
    old_tree.deinit();
    ws.tab_trees[tab] = new_tree;
    self.layoutSplits();

    const new_handle = ws.findHandle(tab, active_pane) orelse return;
    switch (ws.tab_trees[tab].nodes[new_handle.idx()]) {
        .leaf => |pane| pane.focus(),
        .split => {},
    }
}

/// Resize the nearest split in the given direction by the given pixel amount.
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = ws.active_tab;
    const tree = &ws.tab_trees[tab];

    const active_pane = ws.tab_active_pane[tab];
    const handle = ws.findHandle(tab, active_pane) orelse return;

    const layout: SplitTree(Pane).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

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

    const new_tree = tree.resize(alloc, handle, layout, delta) catch return;
    var old_tree = ws.tab_trees[tab];
    old_tree.deinit();
    ws.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Equalize all splits in the active tab.
pub fn equalizeSplits(self: *Window) void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = ws.active_tab;

    const new_tree = ws.tab_trees[tab].equalize(alloc) catch return;
    var old_tree = ws.tab_trees[tab];
    old_tree.deinit();
    ws.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Rearrange all splits in the active tab into a predefined layout.
pub fn selectLayout(self: *Window, layout: apprt.action.SelectLayout) void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = ws.active_tab;

    const Tree = SplitTree(Pane);
    const tree_layout: Tree.PredefinedLayout = switch (layout) {
        inline else => |tag| @field(Tree.PredefinedLayout, @tagName(tag)),
    };
    const new_tree = ws.tab_trees[tab].selectLayout(alloc, tree_layout) catch return;
    var old_tree = ws.tab_trees[tab];
    old_tree.deinit();
    ws.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Toggle zoom on the active split surface.
pub fn toggleSplitZoom(self: *Window) void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    const tab = ws.active_tab;
    var tree = &ws.tab_trees[tab];

    if (!tree.isSplit()) return;

    const active_pane = ws.tab_active_pane[tab];
    const handle = ws.findHandle(tab, active_pane) orelse return;

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

pub fn toggleSynchronizedInput(self: *Window) void {
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    const tab = ws.active_tab;
    ws.tab_synchronized[tab] = !ws.tab_synchronized[tab];
    self.invalidateTabBar();
}

/// Navigate to a tab by GotoTab target (previous, next, last, or index).
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    const ws = self.activeWorkspace();
    if (ws.tab_count <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (ws.active_tab > 0) ws.active_tab - 1 else ws.tab_count - 1,
        .next => if (ws.active_tab + 1 < ws.tab_count) ws.active_tab + 1 else 0,
        .last => ws.tab_count - 1,
        _ => blk: {
            // GotoTab carries a c_int; clamp non-negative before casting
            // so a negative sentinel doesn't panic the @intCast.
            const raw = @intFromEnum(target);
            if (raw < 0) return false;
            const n: usize = @intCast(raw);
            break :blk if (n < ws.tab_count) n else return false;
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

/// Move the active tab by a relative offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    const ws = self.activeWorkspace();
    if (ws.tab_count <= 1) return;
    const n: isize = @intCast(ws.active_tab);
    const count: isize = @intCast(ws.tab_count);
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == ws.active_tab) return;

    // Swap all tab state between active_tab and new_index.
    tabArraysSwap(ws.tabArrays(), ws.active_tab, new_index);
    ws.active_tab = new_index;
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Update the top-level window title to match the active tab's title.
fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const ws = self.activeWorkspace();
    if (ws.tab_count == 0) return;
    const len = ws.tab_title_lens[ws.active_tab];
    var buf: [257]u16 = undefined;
    @memcpy(buf[0..len], ws.tab_titles[ws.active_tab][0..len]);
    buf[len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
}

/// Called when a terminal surface's title changes. Delegates to the
/// pane variant.
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const pane = surface.pane orelse return;
    self.onPaneTitleChanged(pane, title);
}

/// Called when a pane's title changes. Updates the stored title
/// and refreshes the window title bar / tab bar if needed.
pub fn onPaneTitleChanged(self: *Window, pane: *Pane, title: [:0]const u8) void {
    const loc = self.findLoc(pane) orelse return;
    const ws = loc.ws;
    const tab_idx = loc.tab;
    var wbuf: [256]u16 = undefined;
    // utf8ToUtf16Le ASSERTS the destination is large enough (no
    // DestTooSmall error in std 0.15) and titles can exceed 256
    // UTF-16 units (browser titles are website-controlled; OSC titles
    // up to 511 bytes). One UTF-8 byte produces at most one UTF-16
    // unit, so capping the input at 255 bytes makes the worst case
    // fit.
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, capUtf8(title, 255)) catch 0;
    const len: u16 = @intCast(@min(wlen, 255));
    @memcpy(ws.tab_titles[tab_idx][0..len], wbuf[0..len]);
    ws.tab_title_lens[tab_idx] = len;
    if (ws == self.activeWorkspace() and tab_idx == ws.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Cap a UTF-8 string at `max_bytes`, backing up to a sequence
/// boundary so the cut doesn't strand a partial multi-byte sequence
/// (which would invalidate the whole string and drop the title).
fn capUtf8(title: []const u8, max_bytes: usize) []const u8 {
    if (title.len <= max_bytes) return title;
    var len = max_bytes;
    while (len > 0 and (title[len] & 0xC0) == 0x80) len -= 1;
    return title[0..len];
}

/// Set the sidebar status indicator for the tab containing a surface.
/// No-op if the surface is not in any tab of this window.
pub fn setTabStatusForSurface(self: *Window, surface: *Surface, status: TabStatus) void {
    const loc = self.findLocOfSurface(surface) orelse return;
    if (loc.ws.tab_status[loc.tab] == status) return;
    loc.ws.tab_status[loc.tab] = status;
    self.invalidateSidebar();
}

/// Recompute `tab_attention[tab]` from the live panes of that tab: a tab
/// is "attention" iff any of its terminal panes has Surface.attention.
/// Called after any surface flag flips so the per-tab aggregate the
/// sidebar/tab paint reads stays consistent with the per-pane source of
/// truth. The ring overlay reads the Surface flags directly.
fn recomputeTabAttention(self: *Window, ws: *Workspace, tab: usize) void {
    _ = self;
    var any = false;
    var it = ws.tab_trees[tab].iterator();
    while (it.next()) |entry| {
        if (entry.view.surface()) |s| {
            if (s.attention) {
                any = true;
                break;
            }
        }
    }
    ws.tab_attention[tab] = any;
}

/// Flag (or clear) the notification ring on the pane wrapping `surface`.
/// Sets the per-pane Surface flag, recomputes its tab's aggregate, and
/// repaints the chrome (sidebar row + top tab dot) and the ring overlays.
/// A request to ring a pane in the currently visible+focused position is
/// honored at the data level but the ring overlay only DRAWS on panes
/// that are not the focused/visible-active pane (see updateAttentionRings),
/// so the user is never ringed around what they are already looking at.
/// No-op if the surface is not in any tab of this window.
pub fn setAttentionForSurface(self: *Window, surface: *Surface, on: bool) void {
    const loc = self.findLocOfSurface(surface) orelse return;
    if (surface.attention == on) return;
    surface.attention = on;
    self.recomputeTabAttention(loc.ws, loc.tab);
    self.invalidateSidebar();
    self.invalidateTabBar();
    self.updateAttentionRings();
}

/// Clear the notification ring on the pane wrapping `surface` (the pane
/// gained focus / the user is now looking at it). Thin wrapper over
/// setAttentionForSurface(false) so the focus path reads clearly.
pub fn clearAttentionForSurface(self: *Window, surface: *Surface) void {
    self.setAttentionForSurface(surface, false);
}

/// Clear attention on every pane of a tab and its aggregate. Used when a
/// tab becomes the visible active tab (selectTabIndex/selectWorkspace):
/// the user is now looking at the whole tab, so any pane's pending ring
/// is satisfied. Repainting/ring refresh is the caller's job (the select
/// paths already invalidate + layout).
fn clearTabAttention(self: *Window, ws: *Workspace, tab: usize) void {
    _ = self;
    if (tab >= ws.tab_count) return;
    var it = ws.tab_trees[tab].iterator();
    while (it.next()) |entry| {
        if (entry.view.surface()) |s| s.attention = false;
    }
    ws.tab_attention[tab] = false;
}

/// Flash the currently focused pane with a brief semi-transparent
/// border highlight. The flash auto-dismisses after ~200ms via a
/// WM_TIMER on the overlay's own HWND. Creates the overlay lazily
/// on first use. Safe to call repeatedly (re-triggers reset the timer).
pub fn flashFocusedPane(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const pane = self.getActivePane() orelse return;
    const pane_hwnd = pane.hwnd() orelse return;

    // Get the focused pane's client rect in screen coordinates.
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(pane_hwnd, &client_rect) == 0) return;
    var tl = w32.POINT{ .x = client_rect.left, .y = client_rect.top };
    var br = w32.POINT{ .x = client_rect.right, .y = client_rect.bottom };
    _ = w32.ClientToScreen(pane_hwnd, &tl);
    _ = w32.ClientToScreen(pane_hwnd, &br);
    const screen_rect = w32.RECT{
        .left = tl.x,
        .top = tl.y,
        .right = br.x,
        .bottom = br.y,
    };

    // Lazily create the flash overlay.
    if (self.flash_overlay == null) {
        self.flash_overlay = FlashOverlay.create(
            self.app.core_app.alloc,
            self.app.hinstance,
            hwnd,
        ) catch return;
    }
    const fo = self.flash_overlay.?;
    fo.setScale(self.scale);
    fo.flash(screen_rect);
}

/// Update tab bar visibility based on config and tab count.
fn updateTabBarVisibility(self: *Window) void {
    if (self.is_quick_terminal) {
        self.tab_bar_visible = false;
        return;
    }
    const show_config = self.app.config.@"window-show-tab-bar";
    // The top tab bar now COEXISTS with the sidebar: workspaces live in
    // the sidebar, and the tab bar shows the active workspace's tabs
    // (offset right by the sidebar width, see paintTabBar). Visibility
    // is purely a function of the tab count, never suppressed by the
    // sidebar.
    const should_show = switch (show_config) {
        .always => true,
        .auto => self.activeWorkspace().tab_count > 1,
        .never => false,
    };
    if (should_show != self.tab_bar_visible) {
        self.tab_bar_visible = should_show;
        self.handleResize();
    }
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidateTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = 10000,
        .bottom = self.tabBarHeight(),
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Invalidate the sidebar region so it gets repainted.
pub fn invalidateSidebar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = self.sidebarWidth(),
        .bottom = 32767,
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Handle WM_PAINT: paint the window chrome (tab bar and sidebar)
/// with a single BeginPaint/EndPaint pair.
fn paintChrome(self: *Window) void {
    const hwnd = self.hwnd orelse return;

    var ps: w32.PAINTSTRUCT = undefined;
    const hdc_screen = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    self.paintTabBar(hdc_screen);
    if (self.sidebarWidth() > 0) Sidebar.paint(self, hdc_screen);
    if (self.sidebarReshowStripVisible()) self.paintReshowStrip(hdc_screen);
    if (self.rightSidebarWidth() > 0) RightSidebar.paint(self, hdc_screen);
}

/// Paint the thin re-show strip at the window's left edge while the
/// sidebar is runtime-hidden: a narrow accent band with a "›" chevron so
/// the user can click to bring the sidebar back (Ctrl+B also works). Sits
/// below the tab bar so it doesn't fight the tab chrome. Direct GDI on the
/// parent window (the strip is over the surface's left edge, but the GL
/// child only repaints on its own; this floats on top until the next pane
/// repaint — acceptable for a static affordance, and toggling it off
/// relayouts/repaints the pane).
fn paintReshowStrip(self: *Window, hdc: w32.HDC) void {
    const hwnd = self.hwnd orelse return;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return;
    const top = self.tabBarHeight();
    const w = self.sidebarReshowStripWidth();
    if (w <= 0 or client.bottom <= top) return;

    const bg = self.app.config.background;
    // Strip background: terminal bg + 30 per channel so it reads as a
    // grabbable edge against the surface.
    const sr: u8 = @min(@as(u16, bg.r) + 30, 255);
    const sg: u8 = @min(@as(u16, bg.g) + 30, 255);
    const sb: u8 = @min(@as(u16, bg.b) + 30, 255);
    var strip = w32.RECT{ .left = 0, .top = top, .right = w, .bottom = client.bottom };
    if (w32.CreateSolidBrush(w32.RGB(sr, sg, sb))) |brush| {
        _ = w32.FillRect(hdc, &strip, brush);
        _ = w32.DeleteObject(@ptrCast(brush));
    }

    // A "›" chevron centered vertically near the top of the strip hints
    // at "click to expand". Strip is narrow so it just fits the glyph.
    var old_font: ?*anyopaque = null;
    if (self.tab_font) |font| old_font = w32.SelectObject(hdc, font);
    defer {
        if (old_font) |f| _ = w32.SelectObject(hdc, f);
    }
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    _ = w32.SetTextColor(hdc, w32.RGB(200, 200, 200));
    var glyph_rect = w32.RECT{ .left = 0, .top = top, .right = w, .bottom = top + @as(i32, @intFromFloat(@round(40.0 * self.scale))) };
    if (glyph_rect.bottom > client.bottom) glyph_rect.bottom = client.bottom;
    const chevron = std.unicode.utf8ToUtf16LeStringLiteral("\u{203A}"); // ›
    _ = w32.DrawTextW(
        hdc,
        chevron,
        chevron.len,
        &glyph_rect,
        w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
    );
}

/// Whether client point (x, y) lies within the re-show edge strip (the
/// affordance that brings a runtime-hidden sidebar back). Pure-ish (reads
/// only the strip's visibility + width + tab bar height), so the WndProc
/// can route the click before the surface/divider checks.
fn hitTestReshowStrip(self: *const Window, x: i32, y: i32) bool {
    if (!self.sidebarReshowStripVisible()) return false;
    return x >= 0 and x < self.sidebarReshowStripWidth() and y >= self.tabBarHeight();
}

/// Paint the tab bar using double-buffered GDI painting.
/// Draws tab backgrounds, text labels, close buttons (x), and the new-tab (+) button.
fn paintTabBar(self: *Window, hdc_screen: w32.HDC) void {
    const hwnd = self.hwnd orelse return;
    // The top tab bar paints the active workspace's tabs.
    const ws = self.activeWorkspace();

    // If the tab bar is not visible, there is nothing to paint.
    if (!self.tab_bar_visible) return;

    const bar_h = self.tabBarHeight();
    if (bar_h <= 0) return;

    // The tab bar shares the top strip with the sidebar: it starts at
    // the sidebar's right edge and spans the remaining width. The
    // offscreen bitmap is bar-local (x=0 is the bar's left edge), but the
    // stored hit-test rects below add sidebar_w so they are in TRUE
    // client coords — handleTabBarClick/MouseMove compare them against the
    // raw client cursor X.
    const sidebar_w = self.sidebarWidth();

    // Get client rect width and subtract the sidebar.
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    const client_w = client_rect.right - client_rect.left - sidebar_w;
    if (client_w <= 0) return;

    // Double-buffer: create offscreen DC and bitmap.
    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);

    const mem_bmp = w32.CreateCompatibleBitmap(hdc_screen, client_w, bar_h) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    // --- Colors ---
    const bg = self.app.config.background;
    // Bar background: terminal bg + 20 brightness per channel (slightly lighter).
    const bar_r: u8 = @min(@as(u16, bg.r) + 20, 255);
    const bar_g: u8 = @min(@as(u16, bg.g) + 20, 255);
    const bar_b: u8 = @min(@as(u16, bg.b) + 20, 255);
    const bar_color = w32.RGB(bar_r, bar_g, bar_b);

    // Hover background: bar bg + 15 more (total +35 from terminal bg).
    const hover_r: u8 = @min(@as(u16, bar_r) + 15, 255);
    const hover_g: u8 = @min(@as(u16, bar_g) + 15, 255);
    const hover_b: u8 = @min(@as(u16, bar_b) + 15, 255);
    const hover_color = w32.RGB(hover_r, hover_g, hover_b);

    // Active tab background: terminal bg (darker than bar).
    const active_bg_color = w32.RGB(bg.r, bg.g, bg.b);

    // Accent line color (blue).
    const accent_color = w32.RGB(0x3D, 0x8E, 0xF8);

    // Text colors.
    const active_text_color = w32.RGB(230, 230, 230);
    const inactive_text_color = w32.RGB(150, 150, 150);

    // Close button colors.
    const close_normal_color = w32.RGB(150, 150, 150);
    const close_hover_color = w32.RGB(232, 65, 65);

    // --- Fill bar background ---
    var bar_rect = w32.RECT{ .left = 0, .top = 0, .right = client_w, .bottom = bar_h };
    const bar_brush = w32.CreateSolidBrush(bar_color) orelse return;
    _ = w32.FillRect(mem_dc, &bar_rect, bar_brush);
    _ = w32.DeleteObject(@ptrCast(bar_brush));

    // --- Select font and set text mode ---
    var old_font: ?*anyopaque = null;
    if (self.tab_font) |font| {
        old_font = w32.SelectObject(mem_dc, font);
    }
    defer {
        if (old_font) |f| _ = w32.SelectObject(mem_dc, f);
    }
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    // --- Calculate tab geometry ---
    const new_tab_btn_w: i32 = @intFromFloat(@round(36.0 * self.scale));
    const dropdown_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
    const accent_h: i32 = @intFromFloat(@round(2.0 * self.scale));

    const tab_count_i32: i32 = @intCast(ws.tab_count);
    const available_w = client_w - new_tab_btn_w - dropdown_btn_w;

    // Calculate each tab's width: proportional, min 60px.
    const min_tab_w: i32 = @intFromFloat(@round(60.0 * self.scale));
    const max_tab_w: i32 = @intFromFloat(@round(200.0 * self.scale));

    var tab_w: i32 = if (tab_count_i32 > 0)
        @divTrunc(available_w, tab_count_i32)
    else
        0;
    tab_w = @max(tab_w, min_tab_w);
    tab_w = @min(tab_w, max_tab_w);

    // --- Draw each tab ---
    var x: i32 = 0;
    for (0..ws.tab_count) |i| {
        const is_active = (i == ws.active_tab);
        const is_hovered = (@as(isize, @intCast(i)) == self.hover_tab);

        // Last tab gets remainder width to fill the available area.
        const this_tab_w: i32 = if (i == ws.tab_count - 1 and tab_count_i32 > 0)
            @max(available_w - x, min_tab_w)
        else
            tab_w;

        // Store hit-test rect in TRUE client coords (the draw rects below
        // stay bar-local; only the stored rect adds sidebar_w).
        self.tab_rects[i] = w32.RECT{
            .left = sidebar_w + x,
            .top = 0,
            .right = sidebar_w + x + this_tab_w,
            .bottom = bar_h,
        };

        // Draw tab background. CreateSolidBrush failures are rare (GDI
        // handle exhaustion) and must NOT skip the loop body's geometry
        // update at the bottom — `continue`ing would leave subsequent
        // tabs sharing the same x position.
        if (is_active) {
            var tab_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(active_bg_color)) |brush| {
                _ = w32.FillRect(mem_dc, &tab_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }

            // Draw accent line at bottom.
            var accent_rect = w32.RECT{
                .left = x,
                .top = bar_h - accent_h,
                .right = x + this_tab_w,
                .bottom = bar_h,
            };
            if (w32.CreateSolidBrush(accent_color)) |brush| {
                _ = w32.FillRect(mem_dc, &accent_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        } else if (is_hovered) {
            var hover_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &hover_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        // Attention dot: a small blue glyph at the tab's left edge when a
        // pane in this tab is waiting (the notification ring), surfacing
        // the attention on the top tab bar even when the pane isn't the
        // visible one. The title is shifted right by the dot width so it
        // doesn't overlap. The active tab's pending attention is cleared
        // on select, so in practice the dot only shows on inactive tabs.
        const attn_dot_w: i32 = if (ws.tab_attention[i]) @intFromFloat(@round(12.0 * self.scale)) else 0;
        if (attn_dot_w > 0) {
            _ = w32.SetTextColor(mem_dc, accent_color);
            const dot_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{25CF}");
            var dot_rect = w32.RECT{
                .left = x + text_pad,
                .top = 0,
                .right = x + text_pad + attn_dot_w,
                .bottom = bar_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                dot_char,
                1,
                &dot_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        // Sync indicator: a small orange glyph when synchronized input
        // is active on this tab, drawn between the attention dot and the
        // title so the user has a persistent visual cue.
        const sync_indicator_w: i32 = if (ws.tab_synchronized[i]) @intFromFloat(@round(14.0 * self.scale)) else 0;
        if (sync_indicator_w > 0) {
            _ = w32.SetTextColor(mem_dc, w32.RGB(0xE8, 0x9C, 0x20));
            const sync_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{21C4}");
            var sync_rect = w32.RECT{
                .left = x + text_pad + attn_dot_w,
                .top = 0,
                .right = x + text_pad + attn_dot_w + sync_indicator_w,
                .bottom = bar_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                sync_char,
                1,
                &sync_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        // Draw tab title text.
        const title_len = ws.tab_title_lens[i];
        if (title_len > 0) {
            _ = w32.SetTextColor(mem_dc, if (is_active) active_text_color else inactive_text_color);
            var text_rect = w32.RECT{
                .left = x + text_pad + attn_dot_w + sync_indicator_w,
                .top = 0,
                .right = x + this_tab_w - close_btn_w - text_pad,
                .bottom = bar_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                @ptrCast(&ws.tab_titles[i]),
                @intCast(title_len),
                &text_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );
        }

        // Draw close button (x) — visible on active or hovered tabs.
        if (is_active or is_hovered) {
            const close_x = x + this_tab_w - close_btn_w - @divTrunc(text_pad, 2);
            const close_y_center = @divTrunc(bar_h, 2);
            const close_text_color = if (is_hovered and self.hover_close and @as(isize, @intCast(i)) == self.hover_tab)
                close_hover_color
            else
                close_normal_color;

            _ = w32.SetTextColor(mem_dc, close_text_color);
            const x_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}"); // multiplication sign as close
            var close_rect = w32.RECT{
                .left = close_x,
                .top = close_y_center - @divTrunc(close_btn_w, 2),
                .right = close_x + close_btn_w,
                .bottom = close_y_center + @divTrunc(close_btn_w, 2),
            };
            _ = w32.DrawTextW(
                mem_dc,
                x_char,
                1,
                &close_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        x += this_tab_w;
    }

    // --- Draw new-tab (+) button ---
    // btn_left/btn_right are bar-local (for the offscreen draw); the
    // stored hit-test rect adds sidebar_w to reach client coords.
    {
        const btn_left = x;
        const btn_right = x + new_tab_btn_w;
        self.new_tab_rect = w32.RECT{
            .left = sidebar_w + btn_left,
            .top = 0,
            .right = sidebar_w + btn_right,
            .bottom = bar_h,
        };

        // Hover highlight for new-tab button.
        if (self.hover_new_tab) {
            var btn_rect = w32.RECT{ .left = btn_left, .top = 0, .right = btn_right, .bottom = bar_h };
            const nt_brush = w32.CreateSolidBrush(hover_color);
            if (nt_brush) |brush| {
                _ = w32.FillRect(mem_dc, &btn_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        _ = w32.SetTextColor(mem_dc, inactive_text_color);
        const plus_char = std.unicode.utf8ToUtf16LeStringLiteral("+");
        var plus_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };
        _ = w32.DrawTextW(
            mem_dc,
            plus_char,
            1,
            &plus_rect,
            w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    // --- Draw backend picker (▾) segment beside the new-tab button ---
    // dd_left_local is bar-local (the "+" button's local right edge);
    // the stored hit-test rect adds sidebar_w to reach client coords.
    {
        const dd_left_local = self.new_tab_rect.right - sidebar_w;
        self.new_tab_dropdown_rect = w32.RECT{
            .left = sidebar_w + dd_left_local,
            .top = 0,
            .right = sidebar_w + dd_left_local + dropdown_btn_w,
            .bottom = bar_h,
        };

        var dd_rect_local = w32.RECT{
            .left = dd_left_local,
            .top = 0,
            .right = dd_left_local + dropdown_btn_w,
            .bottom = bar_h,
        };

        // Hover highlight, independent of the "+" half.
        if (self.hover_new_tab_dropdown) {
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &dd_rect_local, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        _ = w32.SetTextColor(mem_dc, if (self.hover_new_tab_dropdown)
            active_text_color
        else
            inactive_text_color);
        const chevron_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{25BE}");
        _ = w32.DrawTextW(
            mem_dc,
            chevron_char,
            1,
            &dd_rect_local,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    // --- BitBlt to screen, offset right by the sidebar width ---
    _ = w32.BitBlt(hdc_screen, sidebar_w, 0, client_w, bar_h, mem_dc, 0, 0, w32.SRCCOPY);
}

/// Toggle fullscreen mode on the top-level window.
/// Saves/restores window style and placement.
pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (!self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);
        _ = w32.SetWindowPos(hwnd, null, self.saved_rect.left, self.saved_rect.top, self.saved_rect.right - self.saved_rect.left, self.saved_rect.bottom - self.saved_rect.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
    }
    self.is_fullscreen = !self.is_fullscreen;
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleWindowDecorations(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;

    if (has_decorations) {
        // Remove decorations: strip caption and thick frame.
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        // Restore decorations.
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
}

/// Handle WM_SIZE: re-layout the active tab's split panes and repaint
/// the tab bar and sidebar.
fn handleResize(self: *Window) void {
    self.layoutSplits();
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Handle a left-button click in the tab bar region.
/// Dispatches to addTab, closeTab, or selectTabIndex depending on hit position.
fn handleTabBarClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    // Check the "▾" backend picker segment beside the new-tab button;
    // anchor the picker under the split button, not at the click.
    if (x >= self.new_tab_dropdown_rect.left and x < self.new_tab_dropdown_rect.right) {
        self.showBackendMenu(self.new_tab_rect.left, self.tabBarHeight(), .new_tab);
        return;
    }

    // Check new-tab button. Plain "+" inherits the active pane's
    // backend; the "▾" picker beside it is the explicit override.
    if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
        _ = self.addTabInherit() catch |err| {
            log.err("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }

    // Check each tab.
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
    for (0..self.activeWorkspace().tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            // Check close button area (right side of tab).
            const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
            if (x >= close_left) {
                self.closeTabByIndex(i);
            } else {
                self.selectTabIndex(i);
                // Start tracking potential tab drag
                self.drag_tab = @intCast(i);
                self.drag_start_x = x;
                self.drag_active = false;
                if (self.hwnd) |h| _ = w32.SetCapture(h);
                self.invalidateTabBar();
            }
            return;
        }
    }
}

/// Handle a middle-button click in the tab bar region: close the
/// clicked tab (the browser / Windows Terminal convention), through
/// the same closeTabByIndex path as the tab's close 'x'. The "+"
/// button, its "▾" segment, and the empty strip are no-ops. Fires on
/// the button-down press, matching how handleTabBarClick fires the
/// close 'x' on WM_LBUTTONDOWN.
fn handleTabBarMiddleClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;
    for (0..self.activeWorkspace().tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            self.closeTabByIndex(i);
            return;
        }
    }
}

/// Handle a middle-button click in the sidebar region: close the
/// clicked workspace row through the same closeWorkspace path as the
/// row's close 'x' (the 'x' band is part of the row, so it closes
/// too). Every other target — "+ New workspace", its "▾" segment, the
/// notification panel, and the footer icons — is a no-op.
fn handleSidebarMiddleClick(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;
    switch (self.sidebarHitTest(x, y)) {
        .workspace, .row_close => |i| self.closeWorkspace(i),
        else => {},
    }
}

/// Move a tab from one index to another, shifting intermediate tabs.
fn moveTabTo(self: *Window, from: usize, to: usize) void {
    const ws = self.activeWorkspace();
    if (from == to) return;
    if (from >= ws.tab_count or to >= ws.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    self.cancelTabRename();

    // Lift the source tab out, shift the tabs between, drop it at the
    // destination.
    tabArraysMove(ws.tabArrays(), from, to);

    ws.active_tab = to;
    self.invalidateTabBar();
    self.invalidateSidebar();
}

/// Handle mouse movement over the tab bar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
fn handleTabBarMouseMove(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;

    // Register for WM_MOUSELEAVE if not already tracking.
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    var new_hover: isize = -1;
    var new_close = false;
    var new_new_tab = false;
    var new_dropdown = false;

    if (y < self.tabBarHeight()) {
        // Check new-tab button and the "▾" segment beside it.
        if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
            new_new_tab = true;
        } else if (x >= self.new_tab_dropdown_rect.left and x < self.new_tab_dropdown_rect.right) {
            new_dropdown = true;
        } else {
            // Check tabs.
            const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
            const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
            for (0..self.activeWorkspace().tab_count) |i| {
                const rect = self.tab_rects[i];
                if (x >= rect.left and x < rect.right) {
                    new_hover = @intCast(i);
                    const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
                    new_close = x >= close_left;
                    break;
                }
            }
        }
    }

    if (new_hover != self.hover_tab or new_close != self.hover_close or
        new_new_tab != self.hover_new_tab or new_dropdown != self.hover_new_tab_dropdown)
    {
        self.hover_tab = new_hover;
        self.hover_close = new_close;
        self.hover_new_tab = new_new_tab;
        self.hover_new_tab_dropdown = new_dropdown;
        self.invalidateTabBar();
    }
}

// Context menu command IDs.
const TAB_CTX_CLOSE: usize = 9001;
const TAB_CTX_CLOSE_OTHERS: usize = 9002;
const TAB_CTX_CLOSE_RIGHT: usize = 9003;
const TAB_CTX_NEW_TAB: usize = 9004;

// Sidebar gear (settings) context menu command IDs.
const GEAR_CTX_OPEN_CONFIG: usize = 9201;
const GEAR_CTX_OPEN_FOLDER: usize = 9202;
const GEAR_CTX_RELOAD: usize = 9203;
// Opens a second popup that writes `command = <choice>` into the user
// config (the default-shell picker). 9410+ avoids every taken range
// (9001-9004/9101-9107/9201-9203/9300-9322/9400 close-pane).
const GEAR_CTX_SET_DEFAULT_SHELL: usize = 9410;

// Default-shell picker command IDs (the second popup opened by
// "Set default shell..."). Each writes the chosen program/argv to the
// `command` config key. Installed WSL distros are appended at
// DEFAULT_SHELL_DISTRO_BASE + index, capped below the next reserved ID.
const DEFAULT_SHELL_PWSH: usize = 9411;
const DEFAULT_SHELL_CMD: usize = 9412;
const DEFAULT_SHELL_DISTRO_BASE: usize = 9420;
const DEFAULT_SHELL_DISTRO_CAP: usize = 9450;

// Backend picker command IDs (right-click on the sidebar "+ New
// session" row or the tab bar "+" button opens it targeting a new
// tab; the surface context menu's "Split ... With..." entries open it
// targeting a split). Installed WSL distros are appended at
// NEW_SESSION_DISTRO_BASE + index; the Browser entry at 9320 caps the
// distro list so a pathological install count can't collide with it.
const NEW_SESSION_DEFAULT: usize = 9300;
const NEW_SESSION_PWSH: usize = 9301;
const NEW_SESSION_CMD: usize = 9302;
const NEW_SESSION_DISTRO_BASE: usize = 9310;
const NEW_SESSION_BROWSER: usize = 9320;

/// What a backend-picker menu ID resolves to. Pure mapping from the
/// TrackPopupMenu result (0 = dismissed) and the number of distro
/// entries that were appended; gaps in the ID space and distro IDs at
/// or past the count resolve to .none.
const PickerSelection = union(enum) {
    none,
    default,
    pwsh,
    cmd,
    distro: usize,
    browser,
};

fn pickerSelection(cmd_id: usize, distro_count: usize) PickerSelection {
    switch (cmd_id) {
        NEW_SESSION_DEFAULT => return .default,
        NEW_SESSION_PWSH => return .pwsh,
        NEW_SESSION_CMD => return .cmd,
        NEW_SESSION_BROWSER => return .browser,
        else => {},
    }
    if (cmd_id < NEW_SESSION_DISTRO_BASE) return .none;
    const idx = cmd_id - NEW_SESSION_DISTRO_BASE;
    if (idx >= distro_count) return .none;
    return .{ .distro = idx };
}

/// Menu label for a WSL distro row: the name, with " (default)"
/// appended for the distro wsl.exe launches without -d. Allocated;
/// caller frees.
fn distroMenuLabel(
    alloc: Allocator,
    name: []const u8,
    is_default: bool,
) Allocator.Error![]const u8 {
    return if (is_default)
        std.fmt.allocPrint(alloc, "{s} (default)", .{name})
    else
        alloc.dupe(u8, name);
}

/// Handle a right-button click in the tab bar region.
/// Shows a context menu for the clicked tab.
fn handleTabBarRightClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    // Right-click on the "+" button or its "▾" segment opens the
    // new-session backend picker instead of the tab context menu.
    if ((x >= self.new_tab_rect.left and x < self.new_tab_rect.right) or
        (x >= self.new_tab_dropdown_rect.left and x < self.new_tab_dropdown_rect.right))
    {
        self.showBackendMenu(x, y, .new_tab);
        return;
    }

    // Hit-test to find which tab was right-clicked.
    var clicked_tab: ?usize = null;
    for (0..self.activeWorkspace().tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            clicked_tab = i;
            break;
        }
    }

    self.showTabContextMenu(clicked_tab, x, y);
}

/// Show the tab context menu at client coordinates (x, y). Shared by
/// the tab bar and the sidebar. If clicked_tab is null (empty area),
/// only "New Tab" is shown.
fn showTabContextMenu(self: *Window, clicked_tab: ?usize, x: i32, y: i32) void {
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    if (clicked_tab) |tab| {
        // Menu-construction reads only; never held across the modal
        // menu loop below (workspaces[] can shift while it pumps).
        const ws = self.activeWorkspace();
        _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab"));
        _ = w32.AppendMenuW(menu, if (ws.tab_count > 1) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_OTHERS, std.unicode.utf8ToUtf16LeStringLiteral("Close Other Tabs"));
        _ = w32.AppendMenuW(menu, if (tab + 1 < ws.tab_count) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Close Tabs to the Right"));
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    }
    _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab"));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    // The modal menu loop dispatched arbitrary messages: tabs may have
    // closed, workspaces may have shifted (closeWorkspace moves the
    // array under any held pointer), the window may be closing. Re-fetch
    // the active workspace and re-validate the clicked index before
    // acting; closeTabByIndex additionally bounds-checks each call.
    if (self.closing) return;
    const ws = self.activeWorkspace();
    switch (@as(usize, @intCast(cmd))) {
        TAB_CTX_CLOSE => {
            if (clicked_tab) |tab| self.closeTabByIndex(tab);
        },
        TAB_CTX_CLOSE_OTHERS => {
            if (clicked_tab) |tab| {
                if (tab >= ws.tab_count) return;
                var current = tab;
                var i: usize = ws.tab_count;
                while (i > 0) {
                    i -= 1;
                    if (i != current) {
                        self.closeTabByIndex(i);
                        if (i < current) current -= 1;
                    }
                }
            }
        },
        TAB_CTX_CLOSE_RIGHT => {
            if (clicked_tab) |tab| {
                var i: usize = ws.tab_count;
                while (i > tab + 1) {
                    i -= 1;
                    self.closeTabByIndex(i);
                }
            }
        },
        TAB_CTX_NEW_TAB => {
            // Plain New Tab inherits the active pane's backend, same
            // as the tab bar "+" button.
            _ = self.addTabInherit() catch |err| {
                log.err("failed to create new tab: {}", .{err});
            };
        },
        else => {},
    }
}

/// Handle WM_MOUSELEAVE: reset all hover state and repaint.
fn handleTabBarMouseLeave(self: *Window) void {
    self.tracking_mouse = false;
    if (self.hover_tab != -1 or self.hover_new_tab or self.hover_new_tab_dropdown) {
        self.hover_tab = -1;
        self.hover_close = false;
        self.hover_new_tab = false;
        self.hover_new_tab_dropdown = false;
        self.invalidateTabBar();
    }
}

/// Hit-test a client point against the sidebar with this window's
/// current geometry and notification state.
fn sidebarHitTest(self: *Window, x: i32, y: i32) Sidebar.HitTarget {
    const hwnd = self.hwnd orelse return .none;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return .none;
    return Sidebar.hitTest(x, y, .{
        .item_h = self.sidebarItemHeight(),
        // The sidebar renders one row per workspace.
        .workspace_count = self.workspace_count,
        .client_h = rect.bottom - rect.top,
        .width = self.sidebarWidth(),
        .scale = self.scale,
        .panel_open = self.notif_panel_open,
        .notif_count = self.app.notifCount(),
    });
}

/// Handle a left-button click in the sidebar region.
/// Selects the clicked workspace row or creates a new workspace.
fn handleSidebarClick(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;
    switch (self.sidebarHitTest(x, y)) {
        .none => {},
        .workspace => |i| {
            // Switch to the clicked workspace, then begin tracking a
            // potential row drag-reorder (moveWorkspaceTo). The drag only
            // activates past the threshold in WM_MOUSEMOVE, so a plain
            // click stays a select. selectWorkspace must run FIRST: it
            // clears any in-progress row drag, which would otherwise wipe
            // the state we set here.
            self.selectWorkspace(i);
            self.sidebar_drag_row = @intCast(i);
            self.sidebar_drag_start_y = y;
            self.sidebar_drag_active = false;
            if (self.hwnd) |h| _ = w32.SetCapture(h);
        },
        .row_close => |i| self.closeWorkspace(i),
        .new_session => self.newWorkspace(),
        .new_session_dropdown => {
            // Anchor the picker under the "+ New workspace" row (Windows
            // Terminal dropdown feel) rather than at the click point. The
            // row sits at index workspace_count (below the workspace rows).
            // The picked backend becomes the FIRST TAB of a NEW WORKSPACE
            // (this row creates workspaces; the tab bar's ▾ is the
            // new-tab-in-active-workspace picker).
            const row = Sidebar.itemRect(
                self.workspace_count,
                self.sidebarWidth(),
                self.sidebarItemHeight(),
            );
            self.showBackendMenu(row.left, row.bottom, .new_workspace);
        },
        .bell_icon => {
            self.notif_panel_open = !self.notif_panel_open;
            self.app.markNotifsRead();
            self.invalidateSidebar();
        },
        .gear_icon => self.app.openConfigFile(),
        .browser_icon => self.newBrowserSplit(.right) catch |err| {
            log.err("failed to open browser split: {}", .{err});
        },
        .collapse_toggle => self.toggleSidebar(),
        .notif_entry => |i| {
            if (self.app.notifAt(i)) |entry| {
                const window = entry.window;
                const surface = entry.surface;
                if (self.app.jumpToSurface(window, surface)) {
                    // Unread → Read for the clicked entry (and lower the
                    // taskbar badge). Opening the panel already marks all
                    // entries Read, but a click is an explicit per-entry view.
                    _ = self.app.markNotifEntryRead(i);
                }
            }
        },
        .notif_clear => {
            self.app.clearNotifs();
            self.invalidateSidebar();
        },
    }
}

/// Handle a right-button click in the sidebar region: show the tab
/// context menu for the active workspace's active tab when a workspace
/// row is clicked, or the settings menu for the gear icon. STEP 3
/// replaces the row context with a workspace context menu (rename, etc.).
fn handleSidebarRightClick(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;
    switch (self.sidebarHitTest(x, y)) {
        // A workspace row (or its close 'x' band) opens the workspace
        // context menu (rename / close / new workspace).
        .workspace => |i| self.showWorkspaceContextMenu(i, x, y),
        .row_close => |i| self.showWorkspaceContextMenu(i, x, y),
        .gear_icon => self.showGearContextMenu(x, y),
        // Right-clicking the "+ New workspace" row (or its ▾ chevron)
        // opens the picker with the same new-workspace target as the
        // chevron's left-click.
        .new_session, .new_session_dropdown => self.showBackendMenu(x, y, .new_workspace),
        else => {},
    }
}

// Workspace row context-menu command IDs (right-click a sidebar row).
// 9500+ avoids the tab/gear/picker ranges (9001-9450).
const WS_CTX_RENAME: usize = 9501;
const WS_CTX_CLOSE: usize = 9502;
const WS_CTX_NEW: usize = 9503;
const WS_CTX_DESCRIPTION: usize = 9504;

/// Show the workspace context menu for the workspace at `ws_idx` at
/// client coordinates (x, y): Rename / Close workspace / New workspace.
fn showWorkspaceContextMenu(self: *Window, ws_idx: usize, x: i32, y: i32) void {
    if (self.is_quick_terminal or ws_idx >= self.workspace_count) return;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, WS_CTX_RENAME, std.unicode.utf8ToUtf16LeStringLiteral("Rename Workspace"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, WS_CTX_DESCRIPTION, std.unicode.utf8ToUtf16LeStringLiteral("Edit Description"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, WS_CTX_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Workspace"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, WS_CTX_NEW, std.unicode.utf8ToUtf16LeStringLiteral("New Workspace"));

    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    // The modal menu loop dispatches arbitrary messages; re-check before
    // acting (a workspace may have closed) and re-validate the index.
    if (self.closing or ws_idx >= self.workspace_count) return;
    switch (@as(usize, @intCast(cmd))) {
        WS_CTX_RENAME => self.renameWorkspace(ws_idx),
        WS_CTX_DESCRIPTION => self.editWorkspaceDescription(ws_idx),
        WS_CTX_CLOSE => self.closeWorkspace(ws_idx),
        WS_CTX_NEW => self.newWorkspace(),
        else => {},
    }
}

/// True if pwsh.exe (PowerShell 7+) is on the executable search path.
fn havePwsh() bool {
    var buf: [512]u16 = undefined;
    const n = w32.SearchPathW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe"),
        null,
        buf.len,
        &buf,
        null,
    );
    return n > 0 and n < buf.len;
}

/// Where a backend picked from showBackendMenu opens: a new tab in the
/// active workspace, the first tab of a brand-new workspace, or a
/// split off the active pane in the given direction.
pub const BackendTarget = union(enum) {
    new_tab,
    new_workspace,
    split: SplitTree(Pane).Split.Direction,
};

/// The operation class showBackendMenu performs for a (selection,
/// target) pair: the decision half of the picker dispatch, kept pure
/// so the full selection x target table is unit-testable. The
/// side-effectful half (the switch at the bottom of showBackendMenu)
/// only performs the class chosen here.
const BackendDispatch = enum {
    /// Menu dismissed, or a stale/foreign command ID: do nothing.
    dismiss,
    /// Browser pane as a new tab in the active workspace.
    browser_tab,
    /// Browser pane as the first tab of a brand-new workspace.
    browser_workspace,
    /// Browser pane as a split off the active pane.
    browser_split,
    /// Terminal (with the resolved argv/title) as a new tab.
    terminal_tab,
    /// Terminal as the first tab of a brand-new workspace.
    terminal_workspace,
    /// Terminal as a split off the active pane.
    terminal_split,
};

/// Map a backend-picker selection and target to the operation class to
/// perform. Browser is a pane kind rather than a command, so it gets
/// its own classes; every terminal-backed selection (including the
/// configured default) shares the terminal classes.
fn backendDispatch(
    selection: PickerSelection,
    target: BackendTarget,
) BackendDispatch {
    return switch (selection) {
        .none => .dismiss,
        .browser => switch (target) {
            .new_tab => .browser_tab,
            .new_workspace => .browser_workspace,
            .split => .browser_split,
        },
        .default, .pwsh, .cmd, .distro => switch (target) {
            .new_tab => .terminal_tab,
            .new_workspace => .terminal_workspace,
            .split => .terminal_split,
        },
    };
}

/// Show the backend picker at client coordinates (x, y): "Default" /
/// "PowerShell" / "Command Prompt", each installed WSL distribution
/// (Windows Terminal style), and "Browser" (a WebView2 pane). The
/// selection opens as a new tab, as the first tab of a new workspace,
/// or as a split per `target`; tabs are titled after the picked
/// backend.
pub fn showBackendMenu(self: *Window, x: i32, y: i32, target: BackendTarget) void {
    // Quick terminals exclude picker-created tabs/splits entirely.
    // They have no tab bar or sidebar, so the only QT-reachable call
    // site is the surface "Split ... With..." menu (grayed there too).
    if (self.closing or self.is_quick_terminal) return;
    const alloc = self.app.core_app.alloc;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_DEFAULT, std.unicode.utf8ToUtf16LeStringLiteral("Default"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_PWSH, std.unicode.utf8ToUtf16LeStringLiteral("PowerShell"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_CMD, std.unicode.utf8ToUtf16LeStringLiteral("Command Prompt"));

    // Enumerate installed distros at menu-open (a cheap registry read)
    // so new installs show up without restarting. Freed after the menu
    // closes; selections copy what they need. Capped to the ID space
    // below NEW_SESSION_BROWSER.
    const all_distros: []internal_os.wsl.Distro = internal_os.wsl.list(alloc) catch &.{};
    defer internal_os.wsl.free(alloc, all_distros);
    const distros = all_distros[0..@min(
        all_distros.len,
        NEW_SESSION_BROWSER - NEW_SESSION_DISTRO_BASE,
    )];

    if (distros.len > 0) {
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
        for (distros, 0..) |distro, i| {
            const label = distroMenuLabel(alloc, distro.name, distro.is_default) catch continue;
            defer alloc.free(label);

            const label_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, label) catch continue;
            defer alloc.free(label_w);
            _ = w32.AppendMenuW(
                menu,
                w32.MF_STRING,
                NEW_SESSION_DISTRO_BASE + i,
                label_w.ptr,
            );
        }
    }

    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, NEW_SESSION_BROWSER, std.unicode.utf8ToUtf16LeStringLiteral("Browser"));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    // The modal menu loop dispatches arbitrary messages; re-check
    // before acting.
    if (self.closing) return;

    // Resolve the picked backend to an argv (null = the configured
    // default — explicit for splits, which otherwise inherit the
    // source pane's backend) and a tab title. Browser is a pane kind,
    // not a command: its dispatch arms below never read the backend.
    const selection = pickerSelection(@intCast(cmd), distros.len);
    const Backend = struct {
        argv: ?[]const []const u8,
        title: ?[]const u8,
    };
    var distro_argv: [5][]const u8 = undefined;
    const backend: Backend = switch (selection) {
        // .none dispatches to .dismiss and .browser to the browser
        // classes, none of which reads the backend; null/null is the
        // same harmless value .default resolves to.
        .none, .browser, .default => .{ .argv = null, .title = null },
        .pwsh => .{
            .argv = if (havePwsh()) &.{"pwsh.exe"} else &.{"powershell.exe"},
            .title = "PowerShell",
        },
        .cmd => .{ .argv = &.{"cmd.exe"}, .title = "cmd" },
        .distro => |idx| blk: {
            const distro = distros[idx];
            distro_argv = .{ "wsl.exe", "--cd", "~", "-d", distro.name };
            break :blk .{ .argv = &distro_argv, .title = distro.name };
        },
    };

    // The *_split classes only arise from a .split target, so the
    // target.split accesses below are guaranteed by backendDispatch.
    switch (backendDispatch(selection, target)) {
        .dismiss => return,
        .browser_tab => self.addBrowserTab() catch |err| {
            log.err("failed to create browser tab: {}", .{err});
        },
        .browser_workspace => {
            const idx = self.createAndSelectWorkspace() orelse return;
            self.addBrowserTab() catch |err| {
                // Same collapse-the-empty-slot path as newWorkspace:
                // never show a 0-tab workspace.
                log.err("failed to create browser tab for new workspace: {}", .{err});
                self.closeWorkspace(idx);
            };
            self.invalidateSidebar();
        },
        .browser_split => self.newBrowserSplit(target.split) catch |err| {
            log.err("failed to open browser split: {}", .{err});
        },
        .terminal_tab => _ = self.addTabWithCommand(backend.argv, backend.title) catch |err| {
            log.err("failed to create new tab: {}", .{err});
        },
        .terminal_workspace => {
            // Create-and-select FIRST so the picked backend becomes the
            // new workspace's first tab (a .default pick passes
            // null/null, identical to newWorkspace's plain addTab).
            const idx = self.createAndSelectWorkspace() orelse return;
            _ = self.addTabWithCommand(backend.argv, backend.title) catch |err| {
                // Same collapse-the-empty-slot path as newWorkspace:
                // never show a 0-tab workspace.
                log.err("failed to create first tab for new workspace: {}", .{err});
                self.closeWorkspace(idx);
            };
            self.invalidateSidebar();
        },
        .terminal_split => self.newSplitWithCommand(target.split, backend.argv) catch |err| {
            log.err("failed to create split: {}", .{err});
        },
    }
}

/// Show the settings (gear) context menu at client coordinates (x, y).
fn showGearContextMenu(self: *Window, x: i32, y: i32) void {
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_OPEN_CONFIG, std.unicode.utf8ToUtf16LeStringLiteral("Open config"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_OPEN_FOLDER, std.unicode.utf8ToUtf16LeStringLiteral("Open config folder"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_RELOAD, std.unicode.utf8ToUtf16LeStringLiteral("Reload config"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, GEAR_CTX_SET_DEFAULT_SHELL, std.unicode.utf8ToUtf16LeStringLiteral("Set default shell..."));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    // The modal menu loop dispatches arbitrary messages; re-check
    // before acting.
    if (self.closing) return;
    switch (@as(usize, @intCast(cmd))) {
        GEAR_CTX_OPEN_CONFIG => self.app.openConfigFile(),
        GEAR_CTX_OPEN_FOLDER => self.app.openConfigFolder(),
        // Same path as the reload_config keybind: core performAction
        // forwards to the apprt's .reload_config handler.
        GEAR_CTX_RELOAD => self.app.core_app.performAction(
            self.app,
            .reload_config,
        ) catch |err| {
            log.err("failed to reload config: {}", .{err});
        },
        // Open the default-shell picker anchored where the gear menu
        // was. A second popup keeps this off the modal stack of the
        // first (TrackPopupMenuEx has already returned).
        GEAR_CTX_SET_DEFAULT_SHELL => self.showDefaultShellMenu(x, y),
        else => {},
    }
}

/// Resolve a default-shell picker command ID and the distro count that
/// was shown to the config value to write (e.g. "pwsh.exe" or
/// "wsl.exe --cd ~ -d Ubuntu"), or null when the menu was dismissed or
/// the ID is out of range. Pure mapping so it can be unit-tested; the
/// distro value is written into `distro_buf` and the slice returned
/// points into it.
fn defaultShellValue(
    cmd_id: usize,
    distros: []const internal_os.wsl.Distro,
    distro_buf: []u8,
) ?[]const u8 {
    switch (cmd_id) {
        DEFAULT_SHELL_PWSH => return if (havePwsh()) "pwsh.exe" else "powershell.exe",
        DEFAULT_SHELL_CMD => return "cmd.exe",
        else => {},
    }
    if (cmd_id < DEFAULT_SHELL_DISTRO_BASE) return null;
    const idx = cmd_id - DEFAULT_SHELL_DISTRO_BASE;
    if (idx >= distros.len) return null;
    // wsl.exe needs the distro selected explicitly so the default shell
    // is deterministic regardless of the WSL default.
    return std.fmt.bufPrint(
        distro_buf,
        "wsl.exe --cd ~ -d {s}",
        .{distros[idx].name},
    ) catch null;
}

/// Show the default-shell picker at client coordinates (x, y):
/// "PowerShell" / "Command Prompt" / each installed WSL distribution.
/// The chosen backend is written to the `command` config key (via
/// App.setDefaultShell), which the default-tab path already honors, and
/// the config is reloaded so it takes effect for new tabs/splits.
fn showDefaultShellMenu(self: *Window, x: i32, y: i32) void {
    if (self.closing or self.is_quick_terminal) return;
    const alloc = self.app.core_app.alloc;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    _ = w32.AppendMenuW(menu, w32.MF_STRING, DEFAULT_SHELL_PWSH, std.unicode.utf8ToUtf16LeStringLiteral("PowerShell"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, DEFAULT_SHELL_CMD, std.unicode.utf8ToUtf16LeStringLiteral("Command Prompt"));

    // Enumerate installed distros at menu-open (mirrors showBackendMenu).
    const all_distros: []internal_os.wsl.Distro = internal_os.wsl.list(alloc) catch &.{};
    defer internal_os.wsl.free(alloc, all_distros);
    const distros = all_distros[0..@min(
        all_distros.len,
        DEFAULT_SHELL_DISTRO_CAP - DEFAULT_SHELL_DISTRO_BASE,
    )];

    if (distros.len > 0) {
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
        for (distros, 0..) |distro, i| {
            const label = distroMenuLabel(alloc, distro.name, distro.is_default) catch continue;
            defer alloc.free(label);
            const label_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, label) catch continue;
            defer alloc.free(label_w);
            _ = w32.AppendMenuW(
                menu,
                w32.MF_STRING,
                DEFAULT_SHELL_DISTRO_BASE + i,
                label_w.ptr,
            );
        }
    }

    var pt = w32.POINT{ .x = x, .y = y };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    if (self.closing) return;

    var distro_buf: [512]u8 = undefined;
    const value = defaultShellValue(@intCast(cmd), distros, &distro_buf) orelse return;
    self.app.setDefaultShell(value);
}

/// Handle mouse movement over the sidebar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
fn handleSidebarMouseMove(self: *Window, x: i32, y: i32) void {
    if (self.closing) return;

    // Register for WM_MOUSELEAVE if not already tracking.
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    const new_hover = self.sidebarHitTest(x, y);
    if (!std.meta.eql(new_hover, self.sidebar_hover)) {
        self.sidebar_hover = new_hover;
        self.invalidateSidebar();
    }
}

/// Reset sidebar hover state when the mouse leaves the sidebar.
fn clearSidebarHover(self: *Window) void {
    if (self.sidebar_hover != .none) {
        self.sidebar_hover = .none;
        self.invalidateSidebar();
    }
}

/// Rename edit control child ID.
const RENAME_EDIT_ID: u16 = 300;

/// Start inline editing of a tab title. Creates a small Edit control
/// overlay on the tab and pre-fills it with the current title.
pub fn startTabRename(self: *Window, tab_idx: usize) void {
    const ws = self.activeWorkspace();
    if (tab_idx >= ws.tab_count) return;
    const rect = self.tab_rects[tab_idx];
    const tlen = ws.tab_title_lens[tab_idx];
    self.startRename(rect, ws.tab_titles[tab_idx][0..tlen], .{ .tab = tab_idx });
}

/// Start inline editing of a workspace name. Overlays the Edit control
/// on the workspace's sidebar row and pre-fills it with the current name
/// (empty when the workspace is unnamed — the user types a fresh name).
pub fn renameWorkspace(self: *Window, ws_idx: usize) void {
    // QuickTerminal is single-workspace with no sidebar chrome; it must
    // early-return from every workspace op (matches newWorkspace/
    // closeWorkspace/moveWorkspaceTo/selectWorkspace). Currently
    // unreachable for QT (sidebarWidth()==0 gates every caller), but the
    // guard keeps the invariant explicit against future direct callers.
    if (self.is_quick_terminal) return;
    if (ws_idx >= self.workspace_count) return;
    const wsp = &self.workspaces[ws_idx];
    const rect = Sidebar.itemRect(ws_idx, self.sidebarWidth(), self.sidebarItemHeight());
    self.startRename(rect, wsp.name[0..wsp.name_len], .{ .workspace = ws_idx });
}

/// Start inline editing of a workspace description. Overlays the Edit
/// control on the workspace's sidebar row (same as renameWorkspace but
/// targeting the description field and pre-filled with the current
/// description text, which is empty when no description has been set).
pub fn editWorkspaceDescription(self: *Window, ws_idx: usize) void {
    if (self.is_quick_terminal) return;
    if (ws_idx >= self.workspace_count) return;
    const wsp = &self.workspaces[ws_idx];
    const rect = Sidebar.itemRect(ws_idx, self.sidebarWidth(), self.sidebarItemHeight());
    self.startRename(rect, wsp.description[0..wsp.description_len], .{ .description = ws_idx });
}

/// Create the inline rename Edit overlay at `rect`, pre-filled with
/// `initial` (a UTF-16 slice), targeting `target`. Shared by tab and
/// workspace rename; finishRename routes the committed text per target.
fn startRename(self: *Window, rect: w32.RECT, initial: []const u16, target: RenameTarget) void {
    // Cancel any existing rename
    self.cancelTabRename();

    const hwnd = self.hwnd orelse return;

    // The source slice holds only the valid u16s; CreateWindowExW reads a
    // NUL-terminated wide string, so copy and NUL-terminate so the Edit
    // doesn't display garbage past the real text.
    var text_buf: [257]u16 = undefined;
    const tlen = @min(initial.len, 256);
    @memcpy(text_buf[0..tlen], initial[0..tlen]);
    text_buf[tlen] = 0;

    // Create an Edit control overlaid on the tab/row.
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&text_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        rect.left + 2,
        rect.top + 2,
        rect.right - rect.left - 4,
        rect.bottom - rect.top - 4,
        hwnd,
        @ptrFromInt(@as(usize, RENAME_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        edit,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Set font — stored for cleanup
    self.rename_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(12.0 * self.scale))),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (self.rename_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Select all text
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)

    _ = w32.SetFocus(edit);
    self.rename_edit = edit;
    self.rename_target = target;
}

/// Apply the edit text to the rename target and destroy the edit control.
pub fn finishTabRename(self: *Window) void {
    const edit = self.rename_edit orelse return;
    const target = self.rename_target;

    // Read the edit control text
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, 256));
    if (wlen > 0) {
        const len: u16 = @intCast(@min(wlen, 255));
        switch (target) {
            .tab => |tab_idx| {
                const ws = self.activeWorkspace();
                // The active workspace may have changed while the Edit was
                // open (a keybind can switch workspaces); validate the
                // index against the current workspace before writing.
                if (tab_idx < ws.tab_count) {
                    @memcpy(ws.tab_titles[tab_idx][0..len], wbuf[0..len]);
                    ws.tab_title_lens[tab_idx] = len;
                    if (tab_idx == ws.active_tab) self.updateWindowTitle();
                }
            },
            .workspace => |ws_idx| {
                if (ws_idx < self.workspace_count) {
                    const wsp = &self.workspaces[ws_idx];
                    const nlen: u16 = @intCast(@min(wlen, wsp.name.len));
                    @memcpy(wsp.name[0..nlen], wbuf[0..nlen]);
                    wsp.name_len = nlen;
                }
            },
            .description => |ws_idx| {
                if (ws_idx < self.workspace_count) {
                    const wsp = &self.workspaces[ws_idx];
                    const dlen: u16 = @intCast(@min(wlen, wsp.description.len));
                    @memcpy(wsp.description[0..dlen], wbuf[0..dlen]);
                    wsp.description_len = dlen;
                }
            },
        }
    } else {
        // Empty text: for description edits, clear the description
        // (allows the user to remove a description by blanking it).
        switch (target) {
            .description => |ws_idx| {
                if (ws_idx < self.workspace_count) {
                    self.workspaces[ws_idx].description_len = 0;
                }
            },
            else => {},
        }
    }

    // Clear our state BEFORE DestroyWindow: the Edit synchronously emits
    // EN_KILLFOCUS as it's torn down, which re-enters this function via
    // the WM_COMMAND handler. The early `orelse return` then makes that
    // re-entrant call a no-op.
    self.rename_edit = null;
    _ = w32.DestroyWindow(edit);
    if (self.rename_font) |f| {
        _ = w32.DeleteObject(f);
        self.rename_font = null;
    }
    self.invalidateTabBar();
    self.invalidateSidebar();

    // Return focus to the active pane
    if (self.getActivePane()) |p| p.focus();
}

/// Cancel inline rename without applying changes.
pub fn cancelTabRename(self: *Window) void {
    if (self.rename_edit) |edit| {
        // Same re-entry concern as finishTabRename: null before destroy.
        self.rename_edit = null;
        _ = w32.DestroyWindow(edit);
        if (self.rename_font) |f| {
            _ = w32.DeleteObject(f);
            self.rename_font = null;
        }
        if (self.getActivePane()) |p| p.focus();
    }
}

/// Handle WM_CLOSE: clean up all tabs, then destroy the window.
/// OpenGL contexts and DCs must be released BEFORE DestroyWindow,
/// because Win32 destroys child HWNDs during DestroyWindow and the
/// OpenGL driver crashes if contexts are still active on destroyed windows.
pub fn close(self: *Window) void {
    // Flag teardown FIRST: destroying a browser pane's host HWND inside
    // cleanupAllSurfaces moves focus synchronously back into
    // windowWndProc (WM_SETFOCUS), and other queued input can be
    // dispatched during the destroy. The closing guards drop those
    // messages so nothing touches the mid-teardown tab arrays.
    self.closing = true;

    // Cleanly shut down all surfaces (renderer/IO threads, WGL, DC).
    self.cleanupAllSurfaces();

    // Now safe to destroy the parent HWND (children already cleaned up).
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}

/// Deinit and free all tab trees (which unrefs and frees surfaces)
/// across every workspace.
fn cleanupAllSurfaces(self: *Window) void {
    // Deinit in place and reset to .empty. SplitTree.deinit sets self.*
    // to undefined; deinit'ing a local copy would only mark the copy,
    // leaving stale arena/node pointers in tab_trees that any post-WM_CLOSE
    // message walking the slot could dereference.
    const alloc = self.app.core_app.alloc;
    for (self.workspaces[0..self.workspace_count]) |*ws| {
        for (ws.tab_trees[0..ws.tab_count]) |*tree| {
            tree.deinit();
            tree.* = .empty;
        }
        ws.tab_count = 0;
        ws.freeWorkingDir(alloc);
    }
}

/// Handle WM_DESTROY: remove this window from the App's list,
/// free resources, and start the quit timer if no windows remain.
/// Surfaces are already cleaned up by close() before DestroyWindow.
fn onDestroy(self: *Window) void {
    const app = self.app;

    // Invalidate any in-flight desktop-notification click targets that
    // point at this window before its memory is freed.
    app.dropDesktopNotifsForWindow(self);

    // Quick terminal windows are managed by QuickTerminal, not the windows list.
    if (self.is_quick_terminal) {
        if (self.tab_font) |font| {
            _ = w32.DeleteObject(font);
            self.tab_font = null;
        }
        self.hwnd = null;
        // QuickTerminal handles the rest of cleanup (freeing self, quit timer).
        if (app.quick_terminal) |qt| {
            qt.onWindowDestroyed();
        }
        return;
    }

    // Remove from App's window list.
    for (app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = app.windows.orderedRemove(i);
            break;
        }
    }

    // Clean up Window-level resources.
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }

    // Drain the per-window overlay pools. The owned-popup HWNDs are already
    // reclaimed by the OS as this owner is destroyed, but the heap-side
    // *AttentionRing / *PaneButtons structs and their ArrayList buffers are
    // not — and this interactive-close path bypasses deinit() (which clears
    // GWLP_USERDATA before DestroyWindow, so onDestroy never runs on the
    // deinit path; the two paths are mutually exclusive). Without this, every
    // interactively-closed window leaks its overlays — unbounded growth in an
    // agent workflow that repeatedly opens and closes windows.
    for (self.attention_rings.items) |ring| ring.destroy();
    self.attention_rings.deinit(app.core_app.alloc);
    if (self.flash_overlay) |fo| {
        fo.destroy();
        self.flash_overlay = null;
    }
    for (self.pane_buttons.items) |pb| pb.destroy();
    self.pane_buttons.deinit(app.core_app.alloc);

    self.hwnd = null;

    // Free the Window allocation.
    app.core_app.alloc.destroy(self);

    // If no windows remain (and no quick terminal), start the quit timer.
    if (app.windows.items.len == 0 and app.quick_terminal == null) {
        app.startQuitTimer();
    }
}

/// Window procedure for top-level container HWNDs (GhosttyWindow class).
/// GWLP_USERDATA stores a *Window pointer.
pub fn windowWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const window: *Window = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Once the last tab is closed and WM_CLOSE has been posted, drop any
    // input messages still queued for this window. They could otherwise
    // mutate state (allocate, capture mouse, start drags) on a window
    // about to be destroyed. WM_CLOSE/WM_DESTROY/paint/size still flow
    // through so close itself can complete cleanly.
    if (window.closing) switch (msg) {
        w32.WM_LBUTTONDOWN,
        w32.WM_LBUTTONUP,
        w32.WM_LBUTTONDBLCLK,
        w32.WM_RBUTTONUP,
        w32.WM_MBUTTONDOWN,
        w32.WM_MOUSEMOVE,
        w32.WM_MOUSELEAVE,
        w32.WM_MOUSEWHEEL,
        w32.WM_MOUSEHWHEEL,
        w32.WM_KEYDOWN,
        w32.WM_KEYUP,
        w32.WM_SYSKEYDOWN,
        w32.WM_SYSKEYUP,
        w32.WM_CHAR,
        w32.WM_SETFOCUS,
        w32.WM_SETCURSOR,
        => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        else => {},
    };

    switch (msg) {
        w32.WM_GETOBJECT => {
            // Opt out of MSAA accessibility for OBJID_CLIENT on the
            // top-level window too. See the matching handler in
            // App.surfaceWndProc for the rationale: returning 0 here
            // prevents oleacc from creating an AccWrap proxy whose
            // later destruction can re-enter our WindowProc via
            // SetFocus and deadlock on a COM marshaling reply.
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SIZE => {
            window.handleResize();
            return 0;
        },
        w32.WM_MOVE => {
            // Top-level move: child surface HWNDs do NOT receive WM_MOVE
            // (their position relative to the parent is unchanged), but the
            // scrollbar is a screen-positioned popup that must follow its
            // owner. Reposition every surface's scrollbar across all
            // workspaces and tabs so hidden tabs/workspaces don't surface a
            // stale position when activated.
            for (window.workspaces[0..window.workspace_count]) |*ws| {
                for (0..ws.tab_count) |i| {
                    var it = ws.tab_trees[i].iterator();
                    while (it.next()) |entry| switch (entry.view.content) {
                        .terminal => |s| if (s.scrollbar) |sb| {
                            _ = sb.repositionAndResize();
                        },
                        .browser => |b| b.onParentWindowMoved(),
                    };
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_GETMINMAXINFO => {
            // Apply user-configured size limits if any. lparam points
            // to a MINMAXINFO the OS will consult for resize clamping.
            if (window.min_track_w > 0 or window.min_track_h > 0 or
                window.max_track_w > 0 or window.max_track_h > 0)
            {
                const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (window.min_track_w > 0) mmi.ptMinTrackSize.x = window.min_track_w;
                if (window.min_track_h > 0) mmi.ptMinTrackSize.y = window.min_track_h;
                if (window.max_track_w > 0) mmi.ptMaxTrackSize.x = window.max_track_w;
                if (window.max_track_h > 0) mmi.ptMaxTrackSize.y = window.max_track_h;
                return 0;
            }
            // No limits → fall through to DefWindowProc.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ENTERSIZEMOVE => {
            const ws = window.activeWorkspace();
            if (ws.tab_count > 0) {
                var it = ws.tab_trees[ws.active_tab].iterator();
                while (it.next()) |entry| switch (entry.view.content) {
                    .terminal => |s| s.in_live_resize = true,
                    .browser => {},
                };
            }
            return 0;
        },
        w32.WM_EXITSIZEMOVE => {
            const ws = window.activeWorkspace();
            if (ws.tab_count > 0) {
                var it = ws.tab_trees[ws.active_tab].iterator();
                while (it.next()) |entry| switch (entry.view.content) {
                    .terminal => |s| s.in_live_resize = false,
                    .browser => {},
                };
            }
            // Resize/move drag settled — persist the new geometry. This
            // debounces saves: nothing is written during the live drag
            // (WM_SIZE/WM_MOVE), only once on settle.
            window.savePlacement();
            return 0;
        },
        w32.WM_CLOSE => {
            // Capture final geometry before teardown. close() flips the
            // closing flag and destroys the HWND, after which the rect is
            // unrecoverable.
            window.savePlacement();
            // Persist the session layout (workspaces/tabs/cwds) alongside
            // the window geometry so it can be restored on next launch.
            SessionState.save(window.app.core_app.alloc, window) catch {};
            window.close();
            return 0;
        },
        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            window.onDestroy();
            return 0;
        },
        w32.WM_PAINT => {
            window.paintChrome();
            return 0;
        },
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            // Tab rename Edit lost focus — commit (standard Win32
            // convention, matches Explorer file rename and Edge tabs).
            // Esc still cancels via the message-loop intercept that
            // catches VK_ESCAPE before it reaches the Edit.
            if (control_id == RENAME_EDIT_ID and notification == w32.EN_KILLFOCUS) {
                window.finishTabRename();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETFOCUS => {
            // Forward keyboard focus to the active child pane.
            // Without this, keyboard input stays on the parent and
            // is never delivered to the content.
            if (window.getActivePane()) |p| p.focus();
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            // The re-show strip (sidebar runtime-hidden) sits over the
            // surface's left edge; check it before the surface/divider
            // routing so a click on it brings the sidebar back.
            if (window.hitTestReshowStrip(x, y)) {
                window.toggleSidebar();
                return 0;
            }
            if (window.hitTestSidebarEdge(x)) {
                window.startSidebarDrag();
                return 0;
            }
            if (x < window.sidebarWidth()) {
                window.handleSidebarClick(x, y);
                return 0;
            }
            if (window.hitTestDivider(x, y)) |hit| {
                window.startDividerDrag(hit.handle, hit.layout);
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarClick(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.dragging_split) {
                window.endDividerDrag();
                return 0;
            }
            if (window.dragging_sidebar) {
                window.endSidebarDrag();
                return 0;
            }
            if (window.sidebar_drag_row >= 0) {
                window.endSidebarRowDrag();
                return 0;
            }
            if (window.drag_tab >= 0) {
                window.drag_tab = -1;
                window.drag_active = false;
                _ = w32.ReleaseCapture();
                return 0;
            }
            return 0;
        },
        w32.WM_LBUTTONDBLCLK => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            // Double-click on a sidebar workspace row starts an inline
            // workspace rename. Checked before the tab bar: the sidebar
            // occupies x < sidebarWidth across the full height, including
            // the top strip that the tab bar shares (the tab bar is offset
            // right of the sidebar).
            if (x < window.sidebarWidth()) {
                switch (window.sidebarHitTest(x, y)) {
                    .workspace => |i| window.renameWorkspace(i),
                    else => {},
                }
                return 0;
            }
            // Double-click on tab bar starts inline rename
            if (y < window.tabBarHeight()) {
                for (0..window.activeWorkspace().tab_count) |i| {
                    const rect = window.tab_rects[i];
                    if (x >= rect.left and x < rect.right) {
                        window.startTabRename(i);
                        return 0;
                    }
                }
                return 0;
            }
            if (window.hitTestDivider(x, y)) |hit| {
                const ws = window.activeWorkspace();
                ws.tab_trees[ws.active_tab].resizeInPlace(hit.handle, @as(f16, 0.5));
                window.layoutSplits();
                return 0;
            }
            return 0;
        },
        w32.WM_RBUTTONUP => {
            const x: i16 = @truncate(lparam & 0xFFFF);
            const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
            if (x < window.sidebarWidth()) {
                window.handleSidebarRightClick(x, y);
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarRightClick(x, y);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MBUTTONDOWN => {
            // Middle-click closes the clicked tab / workspace row
            // (browser convention). Only the window's own chrome is
            // routed: middle clicks over the terminal go to the
            // surface child HWND's wndproc (paste / mouse reporting)
            // and never arrive here; anything else (split dividers,
            // sidebar edge) falls through untouched. The closing
            // guard above already drops this message during teardown.
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (x < window.sidebarWidth()) {
                window.handleSidebarMiddleClick(x, y);
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarMiddleClick(@truncate(x), @truncate(y));
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.dragging_split) {
                window.updateDividerDrag(x, y);
                return 0;
            }
            if (window.dragging_sidebar) {
                window.updateSidebarDrag(x);
                return 0;
            }
            // Handle tab drag reorder
            if (window.drag_tab >= 0) {
                const xi16: i16 = @truncate(x);
                const dx = if (xi16 > window.drag_start_x) xi16 - window.drag_start_x else window.drag_start_x - xi16;
                if (!window.drag_active and dx > 5) {
                    window.drag_active = true;
                }
                if (window.drag_active and window.activeWorkspace().tab_count > 1) {
                    // Use uniform tab widths for drag target calculation,
                    // not the painted widths (the last tab gets stretched
                    // to fill remaining space, skewing its midpoint).
                    const tab_count = window.activeWorkspace().tab_count;
                    const from: usize = @intCast(window.drag_tab);
                    // tab_rects are in client coords (offset by the sidebar
                    // width), so slot 0 starts at tab_rects[0].left, not 0.
                    const origin_x = window.tab_rects[0].left;
                    const first_w = window.tab_rects[0].right - window.tab_rects[0].left;
                    var target: usize = 0;
                    for (0..tab_count) |i| {
                        const slot_left: i32 = origin_x + @as(i32, @intCast(i)) * first_w;
                        const slot_mid = slot_left + @divTrunc(first_w, 2);
                        if (x >= slot_mid) {
                            target = i;
                        }
                    }
                    // Clamp to valid range
                    if (target >= tab_count) target = tab_count - 1;
                    if (target != from) {
                        window.moveTabTo(from, target);
                        window.drag_tab = @intCast(target);
                        if (window.hwnd) |h| _ = w32.UpdateWindow(h);
                    }
                }
                return 0;
            }
            // Handle sidebar row drag-reorder.
            if (window.sidebar_drag_row >= 0) {
                const dy = if (y > window.sidebar_drag_start_y)
                    y - window.sidebar_drag_start_y
                else
                    window.sidebar_drag_start_y - y;
                const threshold = Sidebar.dragThreshold(window.scale);
                if (!window.sidebar_drag_active and dy > threshold) {
                    window.sidebar_drag_active = true;
                }
                if (window.sidebar_drag_active and window.workspace_count > 1) {
                    const from: usize = @intCast(window.sidebar_drag_row);
                    const target = window.sidebarDragTarget(y);
                    if (target != from) {
                        // Reorder workspaces (sidebar rows ARE workspaces).
                        window.moveWorkspaceTo(from, target);
                        window.sidebar_drag_row = @intCast(target);
                        if (window.hwnd) |h| _ = w32.UpdateWindow(h);
                    }
                }
                return 0;
            }
            if (window.hitTestSidebarEdge(x)) {
                // Over the resize band: suppress row hover so the
                // band reads as a grab edge, not a row.
                window.clearSidebarHover();
                return 0;
            }
            if (x < window.sidebarWidth()) {
                // The tab bar shares the top strip with the sidebar:
                // moving left out of the tab bar into the sidebar gets no
                // WM_MOUSELEAVE (still in the client area), so clear the
                // tab-bar hover here or it sticks highlighted.
                window.handleTabBarMouseLeave();
                window.handleSidebarMouseMove(x, y);
                return 0;
            }
            window.clearSidebarHover();
            if (y < window.tabBarHeight()) {
                window.handleTabBarMouseMove(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_SETCURSOR => {
            // While dragging the sidebar edge the cursor can leave the
            // band (the width is clamped), so don't re-hit-test.
            if (window.dragging_sidebar) {
                if (w32.LoadCursorW(null, w32.IDC_SIZEWE)) |cursor| {
                    _ = w32.SetCursor(cursor);
                }
                return 1;
            }
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                if (window.hwnd) |h| _ = w32.ScreenToClient(h, &pt);
                if (window.hitTestSidebarEdge(pt.x)) {
                    if (w32.LoadCursorW(null, w32.IDC_SIZEWE)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
                if (window.hitTestDivider(pt.x, pt.y)) |hit| {
                    const cursor_id: usize = if (hit.layout == .horizontal) w32.IDC_SIZEWE else w32.IDC_SIZENS;
                    if (w32.LoadCursorW(null, cursor_id)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSELEAVE => {
            window.handleTabBarMouseLeave();
            window.clearSidebarHover();
            return 0;
        },
        w32.WM_CAPTURECHANGED => {
            // Capture stolen (e.g. a menu or modal opened mid-drag):
            // end the sidebar edge drag and any row drag-reorder so they
            // stop tracking the mouse. Re-entry from our own
            // ReleaseCapture is a no-op via the dragging_sidebar /
            // sidebar_drag_row guards.
            window.endSidebarDrag();
            window.endSidebarRowDrag();
            return 0;
        },
        w32.WM_ACTIVATE => {
            const activated = @as(u16, @truncate(wparam & 0xFFFF));
            if (activated == w32.WA_INACTIVE and window.is_quick_terminal) {
                if (window.app.quick_terminal) |qt| {
                    qt.onFocusLost();
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: window title cap ascii passes through" {
    try testing.expectEqualStrings("hello", capUtf8("hello", 255));
}

test "unit: window title cap exact boundary is unchanged" {
    try testing.expectEqualStrings("abcd", capUtf8("abcd", 4));
}

test "unit: window title cap truncates past the boundary" {
    try testing.expectEqualStrings("abc", capUtf8("abcdef", 3));
}

test "unit: window title cap backs up over a split multi-byte sequence" {
    // "aé" = 61 C3 A9; a cap of 2 lands inside é.
    try testing.expectEqualStrings("a", capUtf8("a\xC3\xA9", 2));
    // 4-byte emoji (U+1F600 = F0 9F 98 80) split at every interior byte.
    const emoji = "ab\xF0\x9F\x98\x80";
    try testing.expectEqualStrings("ab", capUtf8(emoji, 3));
    try testing.expectEqualStrings("ab", capUtf8(emoji, 4));
    try testing.expectEqualStrings("ab", capUtf8(emoji, 5));
}

test "unit: window title cap at a sequence boundary keeps the sequence" {
    try testing.expectEqualStrings("a\xC3\xA9", capUtf8("a\xC3\xA9b", 3));
}

test "unit: window title cap empty and degenerate inputs" {
    try testing.expectEqualStrings("", capUtf8("", 255));
    try testing.expectEqualStrings("", capUtf8("abc", 0));
    // All continuation bytes (malformed input): backs up to empty
    // rather than returning a partial sequence.
    try testing.expectEqualStrings("", capUtf8("\x80\x80\x80", 2));
}

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

test "unit: picker selection maps the fixed entries" {
    try testing.expectEqual(PickerSelection.default, pickerSelection(NEW_SESSION_DEFAULT, 0));
    try testing.expectEqual(PickerSelection.pwsh, pickerSelection(NEW_SESSION_PWSH, 0));
    try testing.expectEqual(PickerSelection.cmd, pickerSelection(NEW_SESSION_CMD, 0));
    try testing.expectEqual(PickerSelection.browser, pickerSelection(NEW_SESSION_BROWSER, 0));
}

test "unit: picker selection maps distro ids by index" {
    try testing.expectEqual(PickerSelection{ .distro = 0 }, pickerSelection(NEW_SESSION_DISTRO_BASE, 3));
    try testing.expectEqual(PickerSelection{ .distro = 2 }, pickerSelection(NEW_SESSION_DISTRO_BASE + 2, 3));
    // At or past the appended count: stale or foreign ID, no action.
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_DISTRO_BASE + 3, 3));
}

test "unit: picker selection ignores dismissal and unknown ids" {
    // TrackPopupMenu returns 0 when the menu is dismissed.
    try testing.expectEqual(PickerSelection.none, pickerSelection(0, 5));
    // Gaps in the ID space around the distro range.
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_CMD + 1, 5));
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_DISTRO_BASE - 1, 5));
    // The Surface "Split ... With..." IDs (9321/9322) live above the
    // browser entry and must not resolve here.
    try testing.expectEqual(PickerSelection.none, pickerSelection(NEW_SESSION_BROWSER + 1, 5));
}

test "unit: picker browser id can never be claimed by a distro" {
    // The call site caps the distro list below NEW_SESSION_BROWSER;
    // even an uncapped count must resolve 9320 to browser, with the
    // last representable distro index directly below it.
    try testing.expectEqual(PickerSelection.browser, pickerSelection(NEW_SESSION_BROWSER, 64));
    const cap = NEW_SESSION_BROWSER - NEW_SESSION_DISTRO_BASE;
    try testing.expectEqual(
        PickerSelection{ .distro = cap - 1 },
        pickerSelection(NEW_SESSION_BROWSER - 1, cap),
    );
}

test "unit: picker menu ids match the reserved registry" {
    // 9300-9302 shells, 9310-9319 distros, 9320 browser (see the menu
    // ID comment block); a change here collides with other menus.
    try testing.expectEqual(@as(usize, 9300), NEW_SESSION_DEFAULT);
    try testing.expectEqual(@as(usize, 9301), NEW_SESSION_PWSH);
    try testing.expectEqual(@as(usize, 9302), NEW_SESSION_CMD);
    try testing.expectEqual(@as(usize, 9310), NEW_SESSION_DISTRO_BASE);
    try testing.expectEqual(@as(usize, 9320), NEW_SESSION_BROWSER);
}

test "unit: distro menu label formats the default marker" {
    const alloc = testing.allocator;
    {
        const label = try distroMenuLabel(alloc, "Ubuntu-24.04", false);
        defer alloc.free(label);
        try testing.expectEqualStrings("Ubuntu-24.04", label);
    }
    {
        const label = try distroMenuLabel(alloc, "Ubuntu-24.04", true);
        defer alloc.free(label);
        try testing.expectEqualStrings("Ubuntu-24.04 (default)", label);
    }
}

test "unit: default-shell value maps the fixed shells" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{};

    // cmd is deterministic.
    try testing.expectEqualStrings(
        "cmd.exe",
        defaultShellValue(DEFAULT_SHELL_CMD, distros, &buf).?,
    );

    // pwsh resolves to one of the two PowerShell exes depending on
    // whether PowerShell 7 is installed on the test host.
    const pwsh = defaultShellValue(DEFAULT_SHELL_PWSH, distros, &buf).?;
    try testing.expect(
        std.mem.eql(u8, pwsh, "pwsh.exe") or
            std.mem.eql(u8, pwsh, "powershell.exe"),
    );
}

test "unit: default-shell value formats the distro argv" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{
        .{ .name = "Ubuntu", .guid = "{x}", .is_default = true, .version = 2 },
        .{ .name = "Debian", .guid = "{y}", .is_default = false, .version = 2 },
    };
    try testing.expectEqualStrings(
        "wsl.exe --cd ~ -d Ubuntu",
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE, distros, &buf).?,
    );
    try testing.expectEqualStrings(
        "wsl.exe --cd ~ -d Debian",
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE + 1, distros, &buf).?,
    );
}

test "unit: default-shell value ignores dismissal and out-of-range ids" {
    var buf: [512]u8 = undefined;
    const distros: []const internal_os.wsl.Distro = &.{
        .{ .name = "Ubuntu", .guid = "{x}", .is_default = true, .version = 2 },
    };
    // Dismissal (0) and ids in gaps / past the distro count.
    try testing.expectEqual(@as(?[]const u8, null), defaultShellValue(0, distros, &buf));
    try testing.expectEqual(
        @as(?[]const u8, null),
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE - 1, distros, &buf),
    );
    try testing.expectEqual(
        @as(?[]const u8, null),
        defaultShellValue(DEFAULT_SHELL_DISTRO_BASE + 1, distros, &buf),
    );
}

test "unit: default-shell menu ids match the reserved registry" {
    // 9410 set-default entry, 9411/9412 shells, 9420+ distros capped at
    // 9450 (see the menu ID comment block). A change here risks a
    // collision with another menu's IDs.
    try testing.expectEqual(@as(usize, 9410), GEAR_CTX_SET_DEFAULT_SHELL);
    try testing.expectEqual(@as(usize, 9411), DEFAULT_SHELL_PWSH);
    try testing.expectEqual(@as(usize, 9412), DEFAULT_SHELL_CMD);
    try testing.expectEqual(@as(usize, 9420), DEFAULT_SHELL_DISTRO_BASE);
    try testing.expectEqual(@as(usize, 9450), DEFAULT_SHELL_DISTRO_CAP);
}

// Pull the persisted window-state module's unit tests (serialize/parse
// round-trip, corrupt-input tolerance, off-screen clamp) into the test
// binary. Window.zig uses WindowState's decls, but Zig only auto-includes
// a referenced file's `test` blocks when the file itself is referenced
// for testing — hence this explicit reference.
test {
    _ = WindowState;
}

// ---------------------------------------------------------------------------
// Additional unit tests. Kept in their own section at the very end of
// the file so concurrent Window.zig changes merge cleanly around them.
// ---------------------------------------------------------------------------

test "unit: workspace aggregate status of an empty workspace is normal" {
    var ws: Workspace = .{};
    try testing.expectEqual(TabStatus.normal, ws.aggregateStatus());
    // Status slots past tab_count are ignored even when dirty.
    ws.tab_status[0] = .exited;
    try testing.expectEqual(TabStatus.normal, ws.aggregateStatus());
}

test "unit: workspace aggregate status all-normal stays normal" {
    var ws: Workspace = .{};
    ws.tab_count = 3;
    try testing.expectEqual(TabStatus.normal, ws.aggregateStatus());
}

test "unit: workspace aggregate status exited beats bell" {
    var ws: Workspace = .{};
    ws.tab_count = 4;
    ws.tab_status[1] = .bell;
    try testing.expectEqual(TabStatus.bell, ws.aggregateStatus());
    // Any exited tab wins regardless of position relative to the bell.
    ws.tab_status[3] = .exited;
    try testing.expectEqual(TabStatus.exited, ws.aggregateStatus());
    ws.tab_status[3] = .normal;
    ws.tab_status[0] = .exited;
    try testing.expectEqual(TabStatus.exited, ws.aggregateStatus());
    // Shrinking the live range back to one normal tab hides the rest.
    ws.tab_status[0] = .normal;
    ws.tab_count = 1;
    try testing.expectEqual(TabStatus.normal, ws.aggregateStatus());
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

test "unit: workspace hasAttention ignores slots past tab_count" {
    var ws: Workspace = .{};
    // Empty workspace: no attention even with a dirty slot.
    ws.tab_attention[0] = true;
    try testing.expect(!ws.hasAttention());
    // Becomes visible once the live range covers the set slot.
    ws.tab_count = 1;
    try testing.expect(ws.hasAttention());
    // A set slot beyond the live range stays hidden.
    ws.tab_attention[0] = false;
    ws.tab_count = 2;
    ws.tab_attention[5] = true;
    try testing.expect(!ws.hasAttention());
    ws.tab_attention[1] = true;
    try testing.expect(ws.hasAttention());
}

test "unit: workspace attention is orthogonal to bell/exited status" {
    // A tab can be both exited and waiting; the two aggregates are
    // independent so the sidebar can surface both.
    var ws: Workspace = .{};
    ws.tab_count = 3;
    ws.tab_status[0] = .exited;
    ws.tab_attention[2] = true;
    try testing.expectEqual(TabStatus.exited, ws.aggregateStatus());
    try testing.expect(ws.hasAttention());
    // Clearing attention leaves the status untouched.
    ws.tab_attention[2] = false;
    try testing.expectEqual(TabStatus.exited, ws.aggregateStatus());
    try testing.expect(!ws.hasAttention());
}

test "unit: workspace status/progress/log setters store and clear per tab" {
    var ws: Workspace = .{};
    ws.tab_count = 2;

    // Defaults: empty status, no progress, empty log.
    try testing.expectEqualStrings("", ws.tabStatusText(0));
    try testing.expectEqual(@as(?u8, null), ws.tab_progress[0]);
    try testing.expect(ws.tab_log[0].latest() == null);

    ws.setTabStatusText(0, "running tests");
    try testing.expectEqualStrings("running tests", ws.tabStatusText(0));
    // Tab 1 is untouched.
    try testing.expectEqualStrings("", ws.tabStatusText(1));
    // Empty text clears.
    ws.setTabStatusText(0, "");
    try testing.expectEqualStrings("", ws.tabStatusText(0));

    // Progress clamps to 0..100; null clears.
    ws.setTabProgress(1, 42);
    try testing.expectEqual(@as(?u8, 42), ws.tab_progress[1]);
    ws.setTabProgress(1, 200);
    try testing.expectEqual(@as(?u8, 100), ws.tab_progress[1]);
    ws.setTabProgress(1, null);
    try testing.expectEqual(@as(?u8, null), ws.tab_progress[1]);

    // Log ring newest-first per tab.
    ws.pushTabLog(0, "line one");
    ws.pushTabLog(0, "line two");
    try testing.expectEqualStrings("line two", ws.tab_log[0].latest().?);
    try testing.expectEqualStrings("line one", ws.tab_log[0].at(1).?);
    // Tab 1's log is independent.
    try testing.expect(ws.tab_log[1].latest() == null);
}

test "unit: workspace metadata setters store and report hasMetadata" {
    var ws: Workspace = .{};

    // Fresh workspace has no metadata.
    try testing.expect(!ws.hasMetadata());
    try testing.expectEqualStrings("", ws.gitBranch());
    try testing.expectEqual(@as(usize, 0), ws.portsSlice().len);
    try testing.expectEqual(PrState.none, ws.pr_state);

    // Branch round-trips and flips hasMetadata.
    ws.setGitBranch("feat/x");
    try testing.expectEqualStrings("feat/x", ws.gitBranch());
    try testing.expect(ws.hasMetadata());

    // Ports store sorted-as-given and dedup is the caller's job (setter
    // copies verbatim, capped at MAX_PORTS).
    ws.setPorts(&.{ 3000, 8080 });
    try testing.expectEqualSlices(u16, &.{ 3000, 8080 }, ws.portsSlice());

    // Over-cap input is truncated to MAX_PORTS.
    var many: [MAX_PORTS + 3]u16 = undefined;
    for (&many, 0..) |*p, i| p.* = @intCast(i);
    ws.setPorts(&many);
    try testing.expectEqual(MAX_PORTS, ws.portsSlice().len);

    // PR status.
    ws.setPrStatus(.draft, 42);
    try testing.expectEqual(PrState.draft, ws.pr_state);
    try testing.expectEqual(@as(u32, 42), ws.pr_number);

    // resetMetadata clears the lot back to unknown.
    ws.resetMetadata();
    try testing.expectEqualStrings("", ws.gitBranch());
    try testing.expectEqual(@as(usize, 0), ws.portsSlice().len);
    try testing.expectEqual(PrState.none, ws.pr_state);
    try testing.expect(!ws.hasMetadata());

    // A per-tab status alone also counts as metadata (the second-line
    // status segment).
    ws.tab_count = 1;
    ws.setTabStatusText(0, "waiting");
    try testing.expect(ws.hasMetadata());
}

test "unit: branch over-long byte truncation never overruns the buffer" {
    var ws: Workspace = .{};
    var long: [MAX_BRANCH_BYTES + 10]u8 = undefined;
    @memset(&long, 'a');
    ws.setGitBranch(&long);
    try testing.expectEqual(MAX_BRANCH_BYTES, ws.gitBranch().len);
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
    tabArraysRemove(arrays, count, 0);
    count -= 1; // 63 live: 1..63
    try testing.expectEqual(@as(u16, 1), ids[0]);
    try testing.expectEqual(@as(u16, 63), ids[count - 1]);

    // Remove the last tab (idx == count - 1): pure count decrement.
    tabArraysRemove(arrays, count, count - 1);
    count -= 1; // 62 live: 1..62
    try testing.expectEqual(@as(u16, 62), ids[count - 1]);

    // Re-insert at the front (gap at 0).
    tabArraysInsertGap(arrays, count, 0);
    ids[0] = 0;
    tags[0] = 1000;
    count += 1; // 63 live: 0..62

    // Front-to-back then back-to-front across the whole span: a full
    // round trip must be the identity permutation.
    tabArraysMove(arrays, 0, count - 1);
    tabArraysMove(arrays, count - 1, 0);
    for (0..count) |i| {
        try testing.expectEqual(@as(u16, @intCast(i)), ids[i]);
    }

    // Swap the two ends, then verify every parallel slot still
    // describes the same logical tab.
    tabArraysSwap(arrays, 0, count - 1);
    try testing.expectEqual(@as(u16, 62), ids[0]);
    try testing.expectEqual(@as(u16, 0), ids[count - 1]);
    for (ids[0..count], tags[0..count]) |id, tag| {
        try testing.expectEqual(@as(u32, id) + 1000, tag);
    }
}

test "unit: window title cap=1 boundary" {
    // cap=1 ASCII keeps a single byte (the fast path's smallest cut).
    try testing.expectEqualStrings("a", capUtf8("abc", 1));
    // cap=1 inside a 2-byte sequence backs up to empty.
    try testing.expectEqualStrings("", capUtf8("\xC3\xA9x", 1));
    // cap=1 after the lead byte of a 4-byte emoji backs up to empty.
    try testing.expectEqualStrings("", capUtf8("\xF0\x9F\x98\x80", 1));
}

test "unit: picker boundary ids 9319 and 9320 resolve by raw value" {
    // 9319 is the last distro slot and 9320 the browser entry; raw
    // numeric IDs so a constant edit that shifts the boundary fails
    // here even if the registry test is updated to match.
    try testing.expectEqual(PickerSelection{ .distro = 9 }, pickerSelection(9319, 10));
    try testing.expectEqual(PickerSelection.browser, pickerSelection(9320, 10));
    // One short of a full menu: 9319 is then a stale ID.
    try testing.expectEqual(PickerSelection.none, pickerSelection(9319, 9));
}

test "unit: default-shell distro ids at the reserved cap boundary" {
    var buf: [512]u8 = undefined;
    // The call site appends at most CAP - BASE distros, so the largest
    // menu ID ever generated is DISTRO_CAP - 1. With a list filled to
    // exactly that cap, the last in-range ID resolves and the cap ID
    // (and anything above) does not.
    const cap = DEFAULT_SHELL_DISTRO_CAP - DEFAULT_SHELL_DISTRO_BASE;
    var distros: [cap]internal_os.wsl.Distro = undefined;
    for (&distros) |*d| d.* = .{
        .name = "Edge",
        .guid = "{g}",
        .is_default = false,
        .version = 2,
    };
    try testing.expectEqualStrings(
        "wsl.exe --cd ~ -d Edge",
        defaultShellValue(DEFAULT_SHELL_DISTRO_CAP - 1, &distros, &buf).?,
    );
    try testing.expectEqual(
        @as(?[]const u8, null),
        defaultShellValue(DEFAULT_SHELL_DISTRO_CAP, &distros, &buf),
    );
}

test "unit: inherit title maps the picker backends" {
    try testing.expectEqualStrings("PowerShell", titleForCommand(&.{"pwsh.exe"}).?);
    try testing.expectEqualStrings("PowerShell", titleForCommand(&.{"powershell.exe"}).?);
    try testing.expectEqualStrings("cmd", titleForCommand(&.{"cmd.exe"}).?);
    // The exact argv the backend picker stores for a distro tab.
    try testing.expectEqualStrings(
        "Ubuntu-24.04",
        titleForCommand(&.{ "wsl.exe", "--cd", "~", "-d", "Ubuntu-24.04" }).?,
    );
}

test "unit: inherit title handles paths, case, and missing extension" {
    try testing.expectEqualStrings(
        "PowerShell",
        titleForCommand(&.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"}).?,
    );
    try testing.expectEqualStrings("cmd", titleForCommand(&.{"CMD.EXE"}).?);
    try testing.expectEqualStrings("Debian", titleForCommand(&.{ "wsl", "-d", "Debian" }).?);
    try testing.expectEqualStrings(
        "Debian",
        titleForCommand(&.{ "wsl.exe", "--distribution", "Debian" }).?,
    );
}

test "unit: inherit title unknown or degenerate argv keeps the default" {
    try testing.expectEqual(@as(?[]const u8, null), titleForCommand(&.{}));
    try testing.expectEqual(@as(?[]const u8, null), titleForCommand(&.{"nu.exe"}));
    // wsl without an explicit distro: nothing to derive a name from.
    try testing.expectEqual(@as(?[]const u8, null), titleForCommand(&.{"wsl.exe"}));
    // Trailing -d with no value must not read past the argv.
    try testing.expectEqual(@as(?[]const u8, null), titleForCommand(&.{ "wsl.exe", "-d" }));
}

test "unit: inherit title resolves full paths and mixed-case exe names" {
    // basename strips the directory; the exe name and the .exe
    // extension both match case-insensitively.
    try testing.expectEqualStrings(
        "Ubuntu",
        titleForCommand(&.{ "C:\\Windows\\System32\\wsl.exe", "-d", "Ubuntu" }).?,
    );
    try testing.expectEqualStrings(
        "Ubuntu",
        titleForCommand(&.{ "WsL.ExE", "-d", "Ubuntu" }).?,
    );
    try testing.expectEqualStrings("PowerShell", titleForCommand(&.{"PoWeRsHeLl.ExE"}).?);
    try testing.expectEqualStrings("PowerShell", titleForCommand(&.{"Pwsh.EXE"}).?);
    // Single-element argv without an extension still resolves.
    try testing.expectEqualStrings("PowerShell", titleForCommand(&.{"powershell"}).?);
}

test "unit: inherit title keeps a distro name containing spaces" {
    // The name is a single argv element; spaces inside it belong to
    // the distro name, not to argument splitting.
    try testing.expectEqualStrings(
        "openSUSE Leap 15.6",
        titleForCommand(&.{ "wsl.exe", "--cd", "~", "-d", "openSUSE Leap 15.6" }).?,
    );
    try testing.expectEqualStrings(
        "Ubuntu 24.04 LTS",
        titleForCommand(&.{ "wsl.exe", "--distribution", "Ubuntu 24.04 LTS" }).?,
    );
}

test "unit: inherit title only recognizes the exact two-token distro flag" {
    // Only the exact "-d <name>" / "--distribution <name>" forms the
    // picker writes are recognized; near misses fall back to the
    // default title (a harmless fallback, never a wrong distro name).
    try testing.expectEqual(
        @as(?[]const u8, null),
        titleForCommand(&.{ "wsl.exe", "-D", "Ubuntu" }),
    );
    try testing.expectEqual(
        @as(?[]const u8, null),
        titleForCommand(&.{ "wsl.exe", "-d=Ubuntu" }),
    );
    // --distribution as the LAST token has no value to take.
    try testing.expectEqual(
        @as(?[]const u8, null),
        titleForCommand(&.{ "wsl.exe", "--distribution" }),
    );
}

test "unit: backend dispatch maps every selection and target pair" {
    const selections = [_]PickerSelection{
        .none, .default, .pwsh, .cmd, .{ .distro = 0 }, .browser,
    };
    const targets = [_]BackendTarget{
        .new_tab, .new_workspace, .{ .split = .right },
    };
    // Rows follow `selections`, columns follow `targets`.
    const expected = [_][3]BackendDispatch{
        .{ .dismiss, .dismiss, .dismiss },
        .{ .terminal_tab, .terminal_workspace, .terminal_split },
        .{ .terminal_tab, .terminal_workspace, .terminal_split },
        .{ .terminal_tab, .terminal_workspace, .terminal_split },
        .{ .terminal_tab, .terminal_workspace, .terminal_split },
        .{ .browser_tab, .browser_workspace, .browser_split },
    };
    for (selections, expected) |sel, row| {
        for (targets, row) |tgt, want| {
            try testing.expectEqual(want, backendDispatch(sel, tgt));
        }
    }
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

test "unit: backend dispatch ignores split direction and distro index" {
    // The split payload picks WHERE the split goes, never WHAT class
    // of operation runs; same for which distro index was picked.
    const dirs = [_]SplitTree(Pane).Split.Direction{ .left, .right, .down, .up };
    for (dirs) |dir| {
        try testing.expectEqual(
            BackendDispatch.terminal_split,
            backendDispatch(.default, .{ .split = dir }),
        );
        try testing.expectEqual(
            BackendDispatch.browser_split,
            backendDispatch(.browser, .{ .split = dir }),
        );
    }
    try testing.expectEqual(
        BackendDispatch.terminal_workspace,
        backendDispatch(.{ .distro = 63 }, .new_workspace),
    );
}

test "unit: workspace aggregate status slot visibility at the count boundaries" {
    var ws: Workspace = .{};

    // tab_count = 0: all 64 slots dirty, none live.
    for (&ws.tab_status) |*s| s.* = .exited;
    ws.tab_count = 0;
    try testing.expectEqual(TabStatus.normal, ws.aggregateStatus());

    // tab_count = MAX_TABS: no slot is beyond the count, so dirt in
    // the very last slot must be seen.
    for (&ws.tab_status) |*s| s.* = .normal;
    ws.tab_status[MAX_TABS - 1] = .exited;
    ws.tab_count = MAX_TABS;
    try testing.expectEqual(TabStatus.exited, ws.aggregateStatus());

    // One below capacity: the same slot is beyond the count again.
    ws.tab_count = MAX_TABS - 1;
    try testing.expectEqual(TabStatus.normal, ws.aggregateStatus());

    // Bell behaves the same at both boundaries.
    ws.tab_status[MAX_TABS - 1] = .bell;
    ws.tab_count = MAX_TABS;
    try testing.expectEqual(TabStatus.bell, ws.aggregateStatus());
    ws.tab_count = 0;
    try testing.expectEqual(TabStatus.normal, ws.aggregateStatus());
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
