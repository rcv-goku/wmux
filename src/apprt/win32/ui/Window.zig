//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs. The Window manages the tab
//! bar, tab switching, and window-level state (fullscreen, DPI scale).
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../../apprt.zig");
const internal_os = @import("../../../os/main.zig");

const App = @import("../App.zig");
const AttentionRing = @import("overlays/AttentionRing.zig").AttentionRing;
const FlashOverlay = @import("overlays/FlashOverlay.zig").FlashOverlay;
const BrowserPane = @import("../web/BrowserPane.zig");
const Group = @import("../model/Group.zig");
const PaneButtonsMod = @import("overlays/PaneButtons.zig");
const PaneButtons = PaneButtonsMod.PaneButtons;
const Tab = @import("../model/Tab.zig");
const Pane = @import("../model/Pane.zig");
const ids = @import("../model/ids.zig");
const model_registry = @import("../model/registry.zig");
const RightSidebar = @import("right_sidebar/legacy_strip.zig");
const Sidebar = @import("sidebar/legacy_gdi.zig");
const right_sidebar = @import("right_sidebar/mod.zig");
const sidebar = @import("sidebar/mod.zig");
const Surface = @import("../Surface.zig");
const SessionState = @import("../features/session/legacy_v2.zig");
const WindowState = @import("placement_state.zig");
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const app_foreground = @import("../app/foreground.zig");
const app_logger = @import("../app/logger.zig");
const app_paths = @import("../app/paths.zig");
const contrib = @import("contrib.zig");
const hooks = @import("../app/hooks.zig");
const w32 = @import("../platform/win32.zig");

// The files W0-A2 split out of this one (see the W0 aliases below).
const chrome = @import("chrome.zig");
const menus = @import("menus.zig");
const overlay_pools = @import("overlays/pools.zig");
const placement = @import("placement.zig");
const rename = @import("rename.zig");
const sidebar_input = @import("sidebar/legacy_input.zig");
const tabbar_input = @import("tabbar/input.zig");
const tabbar_paint = @import("tabbar/paint.zig");
const ops_move = @import("../model/ops/move.zig");
const ops_pane = @import("../model/ops/pane.zig");
const ops_surface = @import("../model/ops/surface.zig");
const ops_window = @import("../model/ops/window.zig");
const ops_workspace = @import("../model/ops/workspace.zig");

const log = std.log.scoped(.win32);

/// The workspace type (moved to model/Workspace.zig in W0-A2).
pub const Workspace = @import("../model/Workspace.zig");
pub const RenameTarget = rename.RenameTarget;

// Constants that moved to their model owners in W0-A2, aliased for the
// existing callers (W0 aliases, ARCHITECTURE.md §0.4).
pub const MAX_BRANCH_BYTES = Workspace.MAX_BRANCH_BYTES;
pub const MAX_PORTS = Workspace.MAX_PORTS;
pub const PrState = Workspace.PrState;
pub const TabStatus = Tab.TabStatus;
const applyChromeTheme = chrome.applyChromeTheme;
const features_ext = @import("../features/ext.zig");

// ---------------------------------------------------------------------------
// W0 aliases (ARCHITECTURE.md §0.4): the functions W0-A2 moved out of this
// file keep their `window.f(...)` call sites compiling. New code MUST NOT
// add aliases; call the owning module directly.
// ---------------------------------------------------------------------------

pub const endDividerDrag = chrome.endDividerDrag;
pub const focusRightSidebar = chrome.focusRightSidebar;
pub const handleResize = chrome.handleResize;
pub const hitTestDivider = chrome.hitTestDivider;
pub const hitTestReshowStrip = chrome.hitTestReshowStrip;
pub const invalidateRightSidebar = chrome.invalidateRightSidebar;
pub const invalidateSidebar = chrome.invalidateSidebar;
pub const invalidateTabBar = chrome.invalidateTabBar;
pub const layoutSplits = chrome.layoutSplits;
pub const onConfigChange = chrome.onConfigChange;
pub const paintChrome = chrome.paintChrome;
pub const paintDividers = chrome.paintDividers;
pub const paintFocusBorder = chrome.paintFocusBorder;
pub const paintReshowStrip = chrome.paintReshowStrip;
pub const repaintDividers = chrome.repaintDividers;
pub const rightSidebarWidth = chrome.rightSidebarWidth;
pub const sidebarItemHeight = chrome.sidebarItemHeight;
pub const sidebarReshowStripVisible = chrome.sidebarReshowStripVisible;
pub const sidebarReshowStripWidth = chrome.sidebarReshowStripWidth;
pub const sidebarShowMetadata = chrome.sidebarShowMetadata;
pub const sidebarWidth = chrome.sidebarWidth;
pub const startDividerDrag = chrome.startDividerDrag;
pub const surfaceRect = chrome.surfaceRect;
pub const tabBarHeight = chrome.tabBarHeight;
pub const toggleFullscreen = chrome.toggleFullscreen;
pub const toggleRightSidebar = chrome.toggleRightSidebar;
pub const toggleSidebar = chrome.toggleSidebar;
pub const toggleWindowDecorations = chrome.toggleWindowDecorations;
pub const updateDividerDrag = chrome.updateDividerDrag;
pub const updateTabBarVisibility = chrome.updateTabBarVisibility;
pub const updateWindowTitle = chrome.updateWindowTitle;

pub const showBackendMenu = menus.showBackendMenu;
pub const showDefaultShellMenu = menus.showDefaultShellMenu;
pub const showGearContextMenu = menus.showGearContextMenu;
pub const showTabContextMenu = menus.showTabContextMenu;
pub const showWorkspaceContextMenu = menus.showWorkspaceContextMenu;

pub const restorePlacement = placement.restorePlacement;
pub const savePlacement = placement.savePlacement;

pub const cancelTabRename = rename.cancelTabRename;
pub const editWorkspaceDescription = rename.editWorkspaceDescription;
pub const finishTabRename = rename.finishTabRename;
pub const renameWorkspace = rename.renameWorkspace;
pub const startRename = rename.startRename;
pub const startTabRename = rename.startTabRename;

pub const flashFocusedPane = overlay_pools.flashFocusedPane;
pub const hideAllPaneButtons = overlay_pools.hideAllPaneButtons;
pub const hideAllRings = overlay_pools.hideAllRings;
pub const onPaneButtonClick = overlay_pools.onPaneButtonClick;
pub const paneButtonsAt = overlay_pools.paneButtonsAt;
pub const placePaneButton = overlay_pools.placePaneButton;
pub const ringAt = overlay_pools.ringAt;
pub const updateAttentionRings = overlay_pools.updateAttentionRings;
pub const updatePaneButtons = overlay_pools.updatePaneButtons;

pub const handleTabBarClick = tabbar_input.handleTabBarClick;
pub const handleTabBarMiddleClick = tabbar_input.handleTabBarMiddleClick;
pub const handleTabBarMouseLeave = tabbar_input.handleTabBarMouseLeave;
pub const handleTabBarMouseMove = tabbar_input.handleTabBarMouseMove;
pub const handleTabBarRightClick = tabbar_input.handleTabBarRightClick;
pub const hitTestSplitTabBar = tabbar_input.hitTestSplitTabBar;

pub const paintTabBar = tabbar_paint.paintTabBar;

pub const clearSidebarHover = sidebar_input.clearSidebarHover;
pub const endSidebarDrag = sidebar_input.endSidebarDrag;
pub const endSidebarRowDrag = sidebar_input.endSidebarRowDrag;
pub const handleSidebarClick = sidebar_input.handleSidebarClick;
pub const handleSidebarMiddleClick = sidebar_input.handleSidebarMiddleClick;
pub const handleSidebarMouseMove = sidebar_input.handleSidebarMouseMove;
pub const handleSidebarRightClick = sidebar_input.handleSidebarRightClick;
pub const hitTestSidebarEdge = sidebar_input.hitTestSidebarEdge;
pub const sidebarDragTarget = sidebar_input.sidebarDragTarget;
pub const sidebarHitTest = sidebar_input.sidebarHitTest;
pub const startSidebarDrag = sidebar_input.startSidebarDrag;
pub const updateSidebarDrag = sidebar_input.updateSidebarDrag;

pub const addBrowserTab = ops_surface.addBrowserTab;
pub const addFirstTabBackground = ops_surface.addFirstTabBackground;
pub const addTab = ops_surface.addTab;
pub const addTabBackground = ops_surface.addTabBackground;
pub const addTabInherit = ops_surface.addTabInherit;
pub const addTabInheritBackground = ops_surface.addTabInheritBackground;
pub const addTabWithCommand = ops_surface.addTabWithCommand;
pub const clearAttentionForSurface = ops_surface.clearAttentionForSurface;
pub const clearTabAttention = ops_surface.clearTabAttention;
pub const closeSplitPane = ops_surface.closeSplitPane;
pub const closeSplitSurface = ops_surface.closeSplitSurface;
pub const closeTabByIndex = ops_surface.closeTabByIndex;
pub const closeTabMode = ops_surface.closeTabMode;
pub const moveTab = ops_surface.moveTab;
pub const moveTabTo = ops_surface.moveTabTo;
pub const onPaneTitleChanged = ops_surface.onPaneTitleChanged;
pub const onTabTitleChanged = ops_surface.onTabTitleChanged;
pub const recomputeTabAttention = ops_surface.recomputeTabAttention;
pub const selectTab = ops_surface.selectTab;
pub const selectTabIndex = ops_surface.selectTabIndex;
pub const setAttentionForSurface = ops_surface.setAttentionForSurface;
pub const setTabStatusForSurface = ops_surface.setTabStatusForSurface;
pub const toggleSynchronizedInput = ops_surface.toggleSynchronizedInput;

pub const breakPane = ops_move.breakPane;
pub const movePaneToTab = ops_move.movePaneToTab;

pub const equalizeSplits = ops_pane.equalizeSplits;
pub const gotoSplit = ops_pane.gotoSplit;
pub const newBrowserSplit = ops_pane.newBrowserSplit;
pub const newSplit = ops_pane.newSplit;
pub const newSplitInWorkspace = ops_pane.newSplitInWorkspace;
pub const newSplitWithCommand = ops_pane.newSplitWithCommand;
pub const resizeSplit = ops_pane.resizeSplit;
pub const selectLayout = ops_pane.selectLayout;
pub const swapSplit = ops_pane.swapSplit;
pub const toggleSplitZoom = ops_pane.toggleSplitZoom;

pub const closeWorkspace = ops_window.closeWorkspace;
pub const collapseEmptyWorkspaceSlot = ops_window.collapseEmptyWorkspaceSlot;
pub const createAndSelectWorkspace = ops_window.createAndSelectWorkspace;
pub const createWorkspaceSlot = ops_window.createWorkspaceSlot;
pub const moveWorkspaceTo = ops_window.moveWorkspaceTo;
pub const newWorkspace = ops_window.newWorkspace;
pub const newWorkspaceBackground = ops_window.newWorkspaceBackground;
pub const newWorkspaceWithDir = ops_window.newWorkspaceWithDir;
pub const selectWorkspace = ops_window.selectWorkspace;

pub const setWorkspaceDescription = ops_workspace.setWorkspaceDescription;
pub const setWorkspaceName = ops_workspace.setWorkspaceName;

/// A located tab (moved to model/Workspace.zig in W0-A2).
pub const Loc = Workspace.Loc;

/// The parent App.
app: *App,

/// Identity (`window_id`, `window:N`; ADR-2), minted in init and retired
/// with the model when the window is freed.
handle: ids.Handle = ids.no_handle,

/// The registry `handle` is minted in (null while unregistered).
registry: ?*model_registry.HandleRegistry = null,

/// The top-level window handle.
hwnd: ?w32.HWND = null,

/// Workspaces owned by this window (sidebar rows), in sidebar order.
/// Heap objects (ARCHITECTURE.md ADR-2.3): a live window always has at
/// least one; they are destroyed with the window.
workspaces: std.ArrayList(*Workspace) = .empty,

/// Workspace groups of this window (W4-5 creates them; ADR-2.3). Heap
/// objects destroyed with the window.
groups: std.ArrayList(*Group) = .empty,

/// The currently active (visible) workspace; always one of `workspaces`
/// on a live window.
selected: ?*Workspace = null,

/// Per-window feature state (ADR-1.3).
ext: features_ext.WindowExt = .{},

/// Whether the tab bar is visible (shown when >1 tab).
tab_bar_visible: bool = false,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

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

/// Inside the modal size/move loop (WM_ENTERSIZEMOVE..WM_EXITSIZEMOVE),
/// which holds an app.modal level (ADR-1.6).
in_size_move: bool = false,

/// Whether this window is a quick terminal (borderless popup, no tabs).
is_quick_terminal: bool = false,

/// Set during init() when restoring persisted state asked for a
/// maximized window. Consumed (reset to false) the first time a tab
/// shows the window so the maximize is a true one-shot at initial
/// bring-up: ShowWindow uses SW_SHOWMAXIMIZED that one time, then
/// SW_SHOW thereafter. This matters because creating/selecting a
/// workspace re-enters the first-tab show path on a fresh
/// (one-tab) workspace; without consuming the flag every new
/// workspace would re-maximize the window. Always false for quick
/// terminals and non-first windows. Only the main window
/// persists/restores geometry.
restore_maximized: bool = false,

/// True once this window has persisted at least one good (non-degenerate)
/// placement during the session. Guards against a teardown-time
/// GetWindowPlacement returning a minimized/zero rect overwriting the
/// last good save. See savePlacement.
saved_placement_ok: bool = false,

/// Split divider drag state. `drag_split_rect` is the dragged split's own
/// node rect (model/layout.zig), which the cursor is measured against.
dragging_split: bool = false,
drag_split_handle: SplitTree(Pane).Node.Handle = .root,
drag_split_layout: SplitTree(Pane).Split.Layout = .horizontal,
drag_split_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

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

    // STATE\logs\wmux.log (app/logger.zig; idempotent, so only the first
    // window opens it). TODO(W1-1): start it from App.init, before the
    // config loads, once the App.zig owner wires it.
    app_logger.start(app.core_app.alloc, &app.runtime_env);

    // Mint the window's handle and create its first workspace before any
    // addTab(). Every init site (App.run, new_window, QuickTerminal.init)
    // flows through here before its first addTab().
    try ops_window.initWindowModel(self);
    errdefer ops_window.freeWindowModel(self, false);

    const style: u32 = if (options.is_quick_terminal) w32.WS_POPUP else w32.WS_OVERLAPPEDWINDOW | w32.WS_CLIPCHILDREN;
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

    // WMUX_TEST_HIDDEN replaces the geometry and adds
    // WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE (app/foreground.zig).
    const create = app_foreground.topLevelCreateParams(app, .{
        .ex_style = ex_style,
        .style = style,
        .x = cx,
        .y = cy,
        .width = cw,
        .height = ch,
    });

    // Create the top-level container window using the GhosttyWindow class.
    const hwnd = w32.CreateWindowExW(
        create.ex_style,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        create.style,
        create.x,
        create.y,
        create.width,
        create.height,
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
    app_foreground.finishTopLevelCreate(app, hwnd, create, &self.max_track_w, &self.max_track_h);

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

    // The sidebar facades (filled by W1-8) attach to the new HWND.
    sidebar.attach(self);
    right_sidebar.attach(self);

    // window.created, workspace.created (model/events.zig).
    ops_window.windowCreated(self);

    // Don't show the window yet — addTab() will show the child
    // surface which triggers ShowWindow on the parent as needed.
    // Showing the parent before the terminal is ready can cause
    // timing issues with ConPTY.
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

    // The (already emptied) workspace objects go last.
    self.leaveSizeMove();
    self.detachSidebars();
    ops_window.freeWindowModel(self, true);
}

/// The currently active workspace. Always valid on a live window: init
/// creates the first workspace and every close selects a survivor.
pub fn activeWorkspace(self: *const Window) *Workspace {
    return self.selected.?;
}

/// The sidebar position of the active workspace (the index the legacy
/// IPC and the session file use).
pub fn activeIndex(self: *const Window) usize {
    const ws = self.selected orelse return 0;
    return std.mem.indexOfScalar(*Workspace, self.workspaces.items, ws) orelse 0;
}

/// The sidebar position of a workspace of this window (as returned by
/// findLoc/findLocOfSurface), or `workspaces.items.len` (an index every
/// index-based operation rejects) when it is not one of them.
pub fn workspaceIndex(self: *const Window, ws: *const Workspace) usize {
    for (self.workspaces.items, 0..) |w, i| {
        if (w == ws) return i;
    }
    return self.workspaces.items.len;
}

/// Returns the currently active Tab, or null if there are no tabs.
pub fn getActiveTab(self: *Window) ?*Tab {
    const ws = self.activeWorkspace();
    const pane = ws.focusedPaneOrFirst() orelse return null;
    return pane.selectedTab();
}

/// Returns the currently active terminal Surface, or null if there are
/// no tabs or the active pane has no terminal.
pub fn getActiveSurface(self: *Window) ?*Surface {
    const pane = self.getActiveTab() orelse return null;
    return pane.surface();
}

/// Find the workspace, pane and index of a given tab, scanning every
/// workspace's panes.
pub fn findLoc(self: *const Window, tab: *const Tab) ?Loc {
    return Workspace.locate(self.workspaces.items, tab);
}

/// Find the workspace, pane and index of the tab holding a given terminal
/// surface, scanning every workspace's panes. Compares by address
/// against live tabs WITHOUT dereferencing `surface`, so callers
/// validating possibly-dangling pointers (jumpToSurface) can use it safely.
pub fn findLocOfSurface(self: *const Window, surface: *const Surface) ?Loc {
    return Workspace.locateSurface(self.workspaces.items, surface);
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

/// Deinit and free all split trees (which unrefs and frees panes, tabs
/// and surfaces) across every workspace. The workspace objects stay (with
/// empty trees) until ops/window.freeWindowModel, so late messages during
/// DestroyWindow still find a selected workspace.
fn cleanupAllSurfaces(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    for (self.workspaces.items) |ws| {
        // Empty the workspace before tearing its tree down: destroying
        // the surfaces moves focus, and the window procedures that run
        // meanwhile must not find the dying panes.
        var tree = ws.tree;
        ws.tree = .empty;
        ws.syncZoomed();
        ws.focused_pane = null;
        tree.deinit();
        ws.freeCwd(alloc);
    }
}

/// Detach the sidebar facades (final teardown; the deinit and WM_DESTROY
/// paths are mutually exclusive, so this runs once).
fn detachSidebars(self: *Window) void {
    right_sidebar.detach(self);
    sidebar.detach(self);
}

/// Release the app.modal level of an unfinished size/move loop.
fn leaveSizeMove(self: *Window) void {
    if (!self.in_size_move) return;
    self.in_size_move = false;
    self.app.modal.leave();
}

/// Handle WM_DESTROY: remove this window from the App's list,
/// free resources, and start the quit timer if no windows remain.
/// Surfaces are already cleaned up by close() before DestroyWindow.
fn onDestroy(self: *Window) void {
    const app = self.app;

    // Invalidate any in-flight desktop-notification click targets that
    // point at this window before its memory is freed.
    app.dropDesktopNotifsForWindow(self);

    // Surfaces were cleaned up by close(); free the workspace objects.
    self.leaveSizeMove();
    self.detachSidebars();
    ops_window.freeWindowModel(self, true);

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

    // Feature window hooks (ui/contrib.zig, ADR-1.6) see the message
    // first; the first non-null result answers it.
    if (hooks.dispatchWindow(contrib.window_hooks, window, msg, wparam, lparam)) |result| return result;

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
            for (window.workspaces.items) |ws| {
                var tree_it = ws.tree.iterator();
                while (tree_it.next()) |entry| {
                    for (entry.view.tabs.items) |tab| switch (tab.content) {
                        .terminal => |s| if (s.scrollbar) |sb| {
                            _ = sb.repositionAndResize();
                        },
                        .browser => |b| b.onParentWindowMoved(),
                        .web => |p| p.onParentWindowMoved(),
                        .placeholder => {},
                    };
                }
            }
            // Reposition corner button overlays — they are screen-positioned
            // layered popups and must follow the window on move.
            window.updatePaneButtons();
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
            // The size/move loop is modal (ADR-1.6): bracket it.
            if (!window.in_size_move) {
                window.in_size_move = true;
                window.app.modal.enter();
            }
            const ws = window.activeWorkspace();
            var it = ws.tree.iterator();
            while (it.next()) |entry| {
                const tab = entry.view.selectedTab() orelse continue;
                if (tab.surface()) |s| s.in_live_resize = true;
            }
            return 0;
        },
        w32.WM_EXITSIZEMOVE => {
            window.leaveSizeMove();
            const ws = window.activeWorkspace();
            var it = ws.tree.iterator();
            while (it.next()) |entry| {
                const tab = entry.view.selectedTab() orelse continue;
                if (tab.surface()) |s| s.in_live_resize = false;
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
            // A test instance leaves no session state behind unless
            // WMUX_TEST_SESSION_RESTORE asks for it (ADR-12.3).
            if (window.app.runtime_env.sessionSaveOnCloseAllowed()) {
                SessionState.save(window.app.core_app.alloc, window) catch {};
            }
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
            if (control_id == rename.RENAME_EDIT_ID and notification == w32.EN_KILLFOCUS) {
                window.finishTabRename();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETFOCUS => {
            // Forward keyboard focus to the active child pane.
            // Without this, keyboard input stays on the parent and
            // is never delivered to the content.
            if (window.getActiveTab()) |p| p.focus();
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
                window.startDividerDrag(hit);
                return 0;
            }
            if (window.hitTestSplitTabBar(x, y) != null) {
                window.handleTabBarClick(@truncate(x), @truncate(y));
            } else if (y < window.tabBarHeight()) {
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
            // Double-click on a tab bar (split pane bar or window-top bar)
            // starts an inline tab rename.
            if (tabbar_input.handleTabBarDoubleClick(window, x, y)) return 0;
            if (window.hitTestDivider(x, y)) |hit| {
                const ws = window.activeWorkspace();
                ws.tree.resizeInPlace(hit.handle, @as(f16, 0.5));
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
            if (window.hitTestSplitTabBar(x, y) != null) {
                window.handleTabBarRightClick(x, y);
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
            if (window.hitTestSplitTabBar(x, y) != null) {
                window.handleTabBarMiddleClick(@truncate(x), @truncate(y));
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
                tabbar_input.updateTabDrag(window, x);
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
                if (window.sidebar_drag_active and window.workspaces.items.len > 1) {
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
            if (window.hitTestSplitTabBar(x, y) != null) {
                window.handleTabBarMouseMove(@truncate(x), @truncate(y));
            } else if (y < window.tabBarHeight()) {
                window.handleTabBarMouseMove(@truncate(x), @truncate(y));
            } else if (window.activeWorkspace().tree.isSplit()) {
                // Mouse left all container tab bars — clear per-container hover.
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

// Pull the persisted window-state module's unit tests (serialize/parse
// round-trip, corrupt-input tolerance, off-screen clamp) into the test
// binary. Window.zig uses WindowState's decls, but Zig only auto-includes
// a referenced file's `test` blocks when the file itself is referenced
// for testing — hence this explicit reference.
test {
    _ = WindowState;
    // The files W0-A2 split out of Window.zig: keep their tests collected.
    // The std-only logic goes through its logic/tests.zig index (also the
    // test-fast entry, CCR W0-A2-1).
    _ = @import("../model/logic/tests.zig");
    _ = Workspace;
    _ = Pane;
    _ = Tab;
    _ = @import("../model/Title.zig");
    _ = @import("../model/TabContent.zig");
    _ = @import("../model/Group.zig");
    _ = @import("../model/events.zig");
    _ = ids;
    _ = model_registry;
    _ = chrome;
    _ = contrib;
    _ = menus;
    _ = @import("backend_picker.zig");
    _ = @import("tabbar/menu.zig");
    _ = @import("sidebar/menu.zig");
    _ = @import("../settings/menu.zig");
    _ = overlay_pools;
    _ = placement;
    _ = rename;
    _ = sidebar_input;
    _ = tabbar_input;
    _ = tabbar_paint;
    _ = @import("tabbar/logic/tests.zig");
    _ = @import("../model/layout.zig");
    // Not std-only (it builds real model objects), so not in the logic
    // index: the full suite collects it here.
    _ = @import("../model/logic/fake.zig");
    _ = @import("../model/ops/group.zig");
    _ = ops_move;
    _ = ops_pane;
    _ = ops_surface;
    _ = ops_window;
    _ = ops_workspace;
}
