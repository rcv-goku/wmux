//! Win32 application runtime. Manages the Win32 window class, message loop,
//! and surface (window) lifecycle.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");

const agent_session = @import("agent_session.zig");
const BrowserPane = @import("BrowserPane.zig");
const ipc = @import("ipc.zig");
const Pane = @import("Pane.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const SessionState = @import("SessionState.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const taskbar = @import("taskbar.zig");
const w32 = @import("win32.zig");
const ws_meta = @import("ws_meta.zig");
const wv2 = @import("webview2.zig");

const build_config = @import("../../build_config.zig");
const input = @import("../../input.zig");

const log = std.log.scoped(.win32);

/// OpenGL draws happen on the renderer thread, not the app thread.
pub const must_draw_from_app_thread = false;

/// Custom window message used to wake up the message loop so that
/// core_app.tick() is called.
const WM_APP_WAKEUP: u32 = w32.WM_APP + 1;

/// Posted by the IPC server's pipe thread (callback ipcCallback) to hand
/// a parsed *ipc.Request to the GUI thread, which owns all HWND/WebView2
/// access. lparam carries the request pointer. WM_APP+2/+3 are the
/// update/tray callbacks (see below); this is the next free slot.
const WM_APP_IPC_REQUEST: u32 = w32.WM_APP + 4;

/// Posted by a sidebar-metadata worker thread to hand a completed
/// *ws_meta.Result to the GUI thread, which owns all Window/Workspace
/// state. lparam carries the result pointer (ownership transferred). The
/// worker only reads its own owned Job, never live Window/App state.
const WM_APP_WS_META: u32 = w32.WM_APP + 5;

/// Timer ID for the quit-after-last-window-closed delay.
const QUIT_TIMER_ID: usize = 1;

/// Window class for the top-level container (GDI painting, no CS_OWNDC).
pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");

/// Window class for terminal surfaces (OpenGL via WGL, needs CS_OWNDC).
pub const TERMINAL_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTerminal");

/// Window class for the message-only HWND (WM_APP_WAKEUP, WM_TIMER).
pub const MSG_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMsg");

/// Window class for browser pane host HWNDs (WebView2 + address bar).
/// Must NOT be the terminal class: App.run skips TranslateMessage for
/// the terminal class atom, which would break the address-bar Edit.
pub const BROWSER_HOST_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyBrowserHost");

/// The core application.
core_app: *CoreApp,

/// The configuration for the application. Loaded during init and
/// updated in response to config_change actions.
config: Config,

/// A message-only window used to receive WM_APP_WAKEUP.
/// This is not a visible window; it just participates in the message loop.
msg_hwnd: ?w32.HWND = null,

/// The HINSTANCE for this module.
hinstance: w32.HINSTANCE,

/// Window class atoms from RegisterClassExW.
class_atom: u16 = 0,
terminal_class_atom: u16 = 0,
msg_class_atom: u16 = 0,
browser_host_class_atom: u16 = 0,

/// List of active Window containers (tabbed windows).
windows: std.ArrayList(*Window) = .empty,

/// Background brush created from the configured background color.
/// Used by WM_ERASEBKGND to fill exposed areas during resize,
/// matching the terminal background so the flash is invisible.
bg_brush: ?w32.HBRUSH = null,

/// Quit timer state, mirroring GTK's three-state approach:
/// - off: no quit pending
/// - active: timer is running (waiting for delay to expire)
/// - expired: delay has elapsed, quit on next tick
quit_timer_state: enum { off, active, expired } = .off,

/// Whether quit has been requested.
quit_requested: bool = false,

/// The quick terminal instance (if active).
quick_terminal: ?*QuickTerminal = null,

/// Whether a global hotkey has been registered.
global_hotkey_registered: bool = false,

/// In-flight desktop-notification click targets, indexed by slot. A
/// balloon click jumps to its slot's surface after validation. Entries
/// are nulled on timer expiry, on click, and when the referenced
/// window is destroyed.
desktop_notifs: [NOTIF_DESKTOP_SLOTS]?DesktopNotif = @splat(null),

/// Next desktop-notification slot to use (rotates through the range).
desktop_notif_next: usize = 0,

/// Ring buffer of recent notifications listed in the sidebar's
/// notifications panel (newest first). Slots are nulled when their
/// window is destroyed or the log is cleared; the unread counter is
/// drawn as the badge on the sidebar footer's bell icon.
notif_log: NotifRing(NotifEntry, NOTIF_LOG_CAP) = .{},

/// ITaskbarList3 COM object used to draw the unread-count overlay badge
/// on each window's taskbar button (the Windows analog of cmux's dock
/// badge). Created lazily on the first badge refresh (CoCreateInstance
/// needs COM, initialized in init()); null when COM is unavailable, in
/// which case badges are a silent no-op. Released in terminate().
taskbar_list: ?taskbar.TaskbarList = null,
/// Set once we've attempted to create `taskbar_list`, so a failed create
/// is not retried on every notification.
taskbar_tried: bool = false,

/// Monotonic counter of sidebar-metadata refresh ticks. Drives the
/// slow-cadence gh PR probe (every WS_META_PR_EVERY ticks) without a
/// second timer.
ws_meta_tick: u64 = 0,

/// Monotonic token source for sidebar-metadata refresh jobs. Each
/// dispatched job stamps the target workspace with the next value and
/// echoes it back; a result is applied only if the workspace still bears
/// that token (guards a recycled slot). 0 is reserved for "never
/// dispatched" so a default-init workspace cannot accidentally match.
ws_meta_token: u64 = 0,

/// Shared WebView2 environment singleton. Created lazily by the first
/// browser pane; all panes get controllers from the same environment.
webview2_env: ?*wv2.ICoreWebView2Environment = null,
webview2_env_state: enum { none, creating, ready, failed } = .none,

/// Browser panes waiting on async environment creation. Each entry
/// holds the in-flight pane ref taken in BrowserPane.startCreation;
/// flushWebView2Pending hands it off via onEnvironment.
webview2_pending: std.ArrayList(*BrowserPane) = .empty,

/// Whether init()'s CoInitializeEx succeeded (S_OK or S_FALSE). Both
/// must be balanced by CoUninitialize in terminate(); a failure (e.g.
/// RPC_E_CHANGED_MODE) must NOT be.
com_initialized: bool = false,

/// Named-pipe IPC server for agent control (`ghostty +browser ...`).
/// Started after msg_hwnd exists; its pipe thread parses requests and
/// PostMessageW's each *ipc.Request to msg_hwnd (WM_APP_IPC_REQUEST),
/// so all browser driving happens on this UI thread. Stopped before
/// msg_hwnd is destroyed in terminate(). Null if startup failed (e.g.
/// a stale pipe of the same name): IPC is then simply unavailable.
ipc_server: ?*ipc.Server = null,

/// Monotonic source of stable browser-pane ids handed back over IPC so
/// later navigate/eval commands can target a specific pane. Assigned in
/// BrowserPane.create; never reused within a process run.
next_browser_id: u32 = 1,

/// Per-surface agent session store: maps a terminal surface (by its
/// stable core Surface.id — the same value exported to shells as
/// GHOSTTY_SURFACE_ID) to the agent running in it and that agent's native
/// session id, for `+session capture`/`resume`. Initialized in init()
/// with the core allocator; deinit'd in terminate(). Pure logic +
/// (de)serialization live in agent_session.zig.
session_store: agent_session.Store = undefined,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const hinstance = w32.GetModuleHandleW(null) orelse
        return error.Win32Error;

    // WebView2 requires COM in a single-threaded apartment on the UI
    // thread. S_FALSE (1, already initialized) is fine; a hard failure
    // only disables browser panes, so don't fail app startup.
    const hr_coinit = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
    if (hr_coinit != 0 and hr_coinit != 1) {
        log.warn("CoInitializeEx failed: 0x{x:0>8}", .{@as(u32, @bitCast(hr_coinit))});
    }

    // Load the configuration for this application.
    const alloc = core_app.alloc;
    var config = Config.load(alloc) catch |err| err: {
        log.err("failed to load config: {}", .{err});
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.addDiagnosticFmt(
            "error loading user configuration: {}",
            .{err},
        );
        break :err def;
    };
    errdefer config.deinit();

    // Create a brush matching the configured background color so that
    // any exposed window area during resize matches the terminal
    // background, making the flash invisible.
    const bg = config.background;
    const bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .bg_brush = bg_brush,
        .com_initialized = hr_coinit == 0 or hr_coinit == 1,
        .session_store = agent_session.Store.init(alloc),
    };

    // Register the window container class (GDI painting, no CS_OWNDC).
    // CS_DBLCLKS is required to receive WM_LBUTTONDBLCLK for divider equalize.
    // Application icon, loaded from the embedded resource. Falls back
    // to the default app icon if missing (only happens with unusual
    // build configs that strip the .rc file).
    const app_icon = w32.LoadIconW(hinstance, w32.IDI_GHOSTTY) orelse
        w32.LoadIconW(null, w32.IDI_APPLICATION);

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_DBLCLKS,
        .lpfnWndProc = &Window.windowWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = app_icon,
    };

    self.class_atom = w32.RegisterClassExW(&wc);
    if (self.class_atom == 0) return error.Win32Error;
    errdefer if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
    };

    // Register the terminal surface class (OpenGL via WGL, needs CS_OWNDC).
    const tc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_OWNDC,
        .lpfnWndProc = &surfaceWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = TERMINAL_CLASS_NAME,
        .hIconSm = app_icon,
    };

    self.terminal_class_atom = w32.RegisterClassExW(&tc);
    if (self.terminal_class_atom == 0) return error.Win32Error;
    errdefer if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
    };

    // Register the message-only window class (WM_APP_WAKEUP, WM_TIMER).
    const mc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &msgWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = MSG_CLASS_NAME,
        .hIconSm = null,
    };

    self.msg_class_atom = w32.RegisterClassExW(&mc);
    if (self.msg_class_atom == 0) return error.Win32Error;
    errdefer if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
    };

    // Register the browser pane host class (WebView2 + address bar).
    const bc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &BrowserPane.hostWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = BROWSER_HOST_CLASS_NAME,
        .hIconSm = null,
    };

    self.browser_host_class_atom = w32.RegisterClassExW(&bc);
    if (self.browser_host_class_atom == 0) return error.Win32Error;
    errdefer if (self.browser_host_class_atom != 0) {
        _ = w32.UnregisterClassW(BROWSER_HOST_CLASS_NAME, self.hinstance);
    };

    // Create a message-only window for receiving WM_APP_WAKEUP.
    // HWND_MESSAGE makes it a message-only window (invisible, no rendering).
    self.msg_hwnd = w32.CreateWindowExW(
        0,
        MSG_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMsg"),
        0, // no style needed
        0,
        0,
        0,
        0,
        w32.HWND_MESSAGE,
        null,
        hinstance,
        null,
    );
    if (self.msg_hwnd == null) return error.Win32Error;

    // Store self pointer in msg_hwnd's GWLP_USERDATA for msgWndProc access
    _ = w32.SetWindowLongPtrW(self.msg_hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Start the agent IPC server now that msg_hwnd exists (the pipe
    // thread posts requests to it). A failure here only disables the
    // `ghostty +browser` CLI, so log and continue.
    self.startIpcServer();

    // Start the periodic sidebar-metadata refresh (git branch / ports /
    // PR). The timer fires on this msg_hwnd; each tick spawns a worker
    // thread for the actual git/gh/TCP-table work.
    _ = w32.SetTimer(self.msg_hwnd.?, WS_META_TIMER_ID, WS_META_INTERVAL_MS, null);

    // Register global hotkey for quick terminal (if configured).
    self.registerGlobalHotkey();

    // Check for updates in the background (non-blocking).
    self.startUpdateCheck();
}

pub fn run(self: *App) !void {
    // Create the initial Window container with one tab.
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(self, .{});
    try self.windows.append(alloc, window);
    _ = try window.addTab();

    // Enter the Win32 message loop
    var msg: w32.MSG = undefined;
    loop: while (true) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            // WM_QUIT received. Check if it's still wanted — stopQuitTimer()
            // resets quit_requested if a new surface opened after
            // PostQuitMessage was called (e.g. during startup).
            // GetMessageW consumes the quit flag, so the next call will
            // block normally for real messages.
            if (!self.quit_requested) continue;
            break;
        }
        if (result < 0) return error.Win32Error;
        if (self.quit_requested) break;

        // Handle global hotkey for quick terminal.
        if (msg.message == w32.WM_HOTKEY) {
            _ = self.performAction(
                .{ .app = {} },
                .toggle_quick_terminal,
                {},
            ) catch {};
            continue;
        }

        // Intercept keystrokes destined for popup edit controls so
        // Enter/Escape/Arrow keys can be handled by our code.
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null) {
            const vk: u16 = @intCast(msg.wParam & 0xFFFF);

            // Check if this edit is a tab rename edit
            if (vk == w32.VK_RETURN or vk == w32.VK_ESCAPE) {
                for (self.windows.items) |win| {
                    if (win.rename_edit != null and win.rename_edit.? == msg.hwnd) {
                        if (vk == w32.VK_RETURN) {
                            win.finishTabRename();
                        } else {
                            win.cancelTabRename();
                        }
                        continue :loop;
                    }
                }
            }

            // Find the parent of this edit control and route by class:
            // terminal-class parents (surface + search/palette popups)
            // carry a *Surface in GWLP_USERDATA, browser-host parents a
            // *BrowserPane. The atom check gates the casts — without it
            // a key typed in the browser address bar would reinterpret
            // a *BrowserPane as *Surface.
            const parent = w32.GetParent(msg.hwnd.?);
            if (parent) |p| {
                const atom: u16 = @truncate(w32.GetClassLongW(p, w32.GCW_ATOM));
                const userdata = w32.GetWindowLongPtrW(p, w32.GWLP_USERDATA);
                if (userdata != 0 and atom != 0 and atom == self.browser_host_class_atom) {
                    const browser: *BrowserPane = @ptrFromInt(@as(usize, @bitCast(userdata)));
                    if (browser.address_edit != null and browser.address_edit.? == msg.hwnd) {
                        if (vk == w32.VK_RETURN) {
                            browser.navigateFromAddressBar();
                            continue;
                        }
                        if (vk == w32.VK_ESCAPE) {
                            browser.focusWebView();
                            continue;
                        }
                    }
                }
                if (userdata != 0 and atom != 0 and atom == self.terminal_class_atom) {
                    const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
                    if (surface.search_active and surface.search_edit == msg.hwnd) {
                        if (surface.handleSearchKey(vk)) continue;
                    }
                    if (surface.palette_active and surface.palette_edit == msg.hwnd) {
                        if (surface.handlePaletteKey(vk)) continue;
                    }
                }
            }

            // Bubble global keybindings from popup edit controls (tab
            // rename, command palette, search) up to the surface so that
            // e.g. `Ctrl+Shift+P` while renaming actually toggles the
            // palette instead of being eaten by the Edit. Excludes
            // Ctrl-only A/C/V/X/Y/Z so standard text-edit shortcuts keep
            // working inside the popup.
            const ctrl_held = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
            const shift_held = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const route_key = ctrl_held and (shift_held or !isEditShortcutVk(vk));
            if (route_key) {
                const target_surface: ?*Surface = blk: {
                    // Tab rename edit lives on the Window, not a surface.
                    // Commit (not cancel) — matches standard Win32 inline
                    // rename convention (Explorer, Edge): any action that
                    // takes focus away saves the typed title.
                    for (self.windows.items) |win| {
                        if (win.rename_edit != null and win.rename_edit.? == msg.hwnd) {
                            win.finishTabRename();
                            break :blk win.getActiveSurface();
                        }
                    }
                    // Palette/search edits are children of a
                    // terminal-class popup HWND; only that class
                    // carries a *Surface in GWLP_USERDATA.
                    const pp = w32.GetParent(msg.hwnd.?) orelse break :blk null;
                    const pp_atom: u16 = @truncate(w32.GetClassLongW(pp, w32.GCW_ATOM));
                    if (pp_atom == 0 or pp_atom != self.terminal_class_atom) break :blk null;
                    const ud = w32.GetWindowLongPtrW(pp, w32.GWLP_USERDATA);
                    if (ud == 0) break :blk null;
                    const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(ud)));
                    if (surface.palette_active and surface.palette_edit == msg.hwnd) {
                        surface.setCommandPaletteActive(false);
                        break :blk surface;
                    }
                    if (surface.search_active and surface.search_edit == msg.hwnd) {
                        surface.setSearchActive(false, &[_:0]u8{});
                        break :blk surface;
                    }
                    break :blk null;
                };
                if (target_surface) |s| {
                    _ = s.handleKeyEvent(msg.wParam, msg.lParam, .press);
                    continue :loop;
                }
            }
        }

        // Skip TranslateMessage for keyboard events on terminal surface
        // windows: handleKeyEvent (and sendWin32InputEvent in Win32 input
        // mode) calls ToUnicode directly, and TranslateMessage's internal
        // ToUnicodeEx mutates the same per-queue dead-key state — racing
        // it broke dead-key composition on ABNT2 (`~`+`a` → `~a`). Edit
        // controls (search, palette, tab rename) still need it.
        const skip_translate = switch (msg.message) {
            w32.WM_KEYDOWN, w32.WM_KEYUP, w32.WM_SYSKEYDOWN, w32.WM_SYSKEYUP => blk: {
                const h = msg.hwnd orelse break :blk false;
                const atom: u16 = @truncate(w32.GetClassLongW(h, w32.GCW_ATOM));
                break :blk atom != 0 and atom == self.terminal_class_atom;
            },
            else => false,
        };
        if (!skip_translate) _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    self.stopQuitTimer();

    // Unregister global hotkey.
    if (self.global_hotkey_registered) {
        _ = w32.UnregisterHotKey(null, 1);
        self.global_hotkey_registered = false;
    }

    // Destroy quick terminal if active.
    if (self.quick_terminal) |qt| {
        qt.deinit();
        self.quick_terminal = null;
    }

    // Stop the IPC server BEFORE destroying msg_hwnd: the pipe thread's
    // callback PostMessageW's to msg_hwnd, and stop() joins that thread,
    // so no request can be posted to a dead window afterward. Any
    // request already queued is drained by the loop exiting; if one is
    // mid-flight in msgWndProc it completes before terminate() proceeds
    // (single-threaded UI). sendOk/sendError after stop() is impossible
    // because the GUI thread is here, not in msgWndProc.
    if (self.ipc_server) |server| {
        server.stop();
        self.ipc_server = null;
    }

    // Free the agent session store (owned session-id strings). Safe after
    // the IPC server stopped: no pipe-thread callback can still touch it.
    self.session_store.deinit();

    if (self.msg_hwnd) |hwnd| {
        // Clear GWLP_USERDATA before destroying so msgWndProc sees
        // userdata=0 and falls through to DefWindowProc for any
        // messages during destruction (e.g. WM_DESTROY).
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.msg_hwnd = null;
    }

    // Deinit and free all Window containers.
    const alloc = self.core_app.alloc;
    for (self.windows.items) |window| {
        window.deinit();
        alloc.destroy(window);
    }
    self.windows.deinit(alloc);

    // Browser panes still waiting on environment creation hold an
    // in-flight pane ref; the windows above already dropped the tree
    // refs, so handing these a null environment unrefs to zero and
    // frees them.
    for (self.webview2_pending.items) |browser| browser.onEnvironment(null);
    self.webview2_pending.deinit(alloc);
    if (self.webview2_env) |env| {
        env.release();
        self.webview2_env = null;
    }

    if (self.bg_brush) |brush| {
        _ = w32.DeleteObject(@ptrCast(brush));
        self.bg_brush = null;
    }

    if (self.browser_host_class_atom != 0) {
        _ = w32.UnregisterClassW(BROWSER_HOST_CLASS_NAME, self.hinstance);
        self.browser_host_class_atom = 0;
    }
    if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
        self.msg_class_atom = 0;
    }
    if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
        self.terminal_class_atom = 0;
    }
    if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
        self.class_atom = 0;
    }

    self.config.deinit();

    // Release the taskbar overlay COM object before CoUninitialize tears
    // down the apartment it lives in.
    if (self.taskbar_list) |*tl| {
        tl.deinit();
        self.taskbar_list = null;
    }

    // Balance CoInitializeEx only when it actually succeeded —
    // CoUninitialize after RPC_E_CHANGED_MODE would tear down an
    // apartment we don't own.
    if (self.com_initialized) {
        w32.CoUninitialize();
        self.com_initialized = false;
    }
}

/// Wake up the message loop from any thread by posting a message
/// to the message-only window.
pub fn wakeup(self: *App) void {
    if (self.msg_hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, WM_APP_WAKEUP, 0, 0);
    }
}

/// IPC from external processes. Not yet implemented for Win32.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            self.quit_requested = true;
            w32.PostQuitMessage(0);
            return true;
        },

        .new_window => {
            // Inherit opacity-toggle state from the parent window: if the
            // user toggled it to opaque via toggle_background_opacity, the
            // new window should start opaque too. Mirrors macOS behavior
            // from upstream e5c31e8b3 (#11583).
            const force_opaque: bool = switch (target) {
                .app => false,
                .surface => |cs| blk: {
                    if (self.config.@"background-opacity" >= 1.0) break :blk false;
                    const h = cs.rt_surface.parent_window.hwnd orelse break :blk false;
                    const ex = w32.GetWindowLongW(h, w32.GWL_EXSTYLE);
                    break :blk (ex & w32.WS_EX_LAYERED) == 0;
                },
            };

            const alloc = self.core_app.alloc;
            const window = alloc.create(Window) catch |err| {
                log.err("failed to allocate new window err={}", .{err});
                return true;
            };
            window.init(self, .{ .force_opaque = force_opaque }) catch |err| {
                log.err("failed to init new window err={}", .{err});
                alloc.destroy(window);
                return true;
            };
            self.windows.append(alloc, window) catch |err| {
                log.err("failed to track new window err={}", .{err});
                window.deinit();
                alloc.destroy(window);
                return true;
            };
            _ = window.addTab() catch |err| {
                log.err("failed to add tab to new window err={}", .{err});
                return true;
            };
            return true;
        },

        .set_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const rt_surface = core_surface.rt_surface;
                    rt_surface.setTitle(value.title);
                },
            }
            return true;
        },

        .ring_bell => {
            // Audio bell.
            _ = w32.MessageBeep(0xFFFFFFFF);
            // Visual bell: flash the taskbar button if the window owning
            // this surface isn't currently the foreground window. Without
            // this, BEL on a backgrounded terminal is invisible.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const rt_surface = core_surface.rt_surface;
                    const parent_window = rt_surface.parent_window;
                    var foreground = false;
                    if (parent_window.hwnd) |win_hwnd| {
                        foreground = w32.GetForegroundWindow() == win_hwnd;
                        if (!foreground) {
                            var fwi: w32.FLASHWINFO = .{
                                .cbSize = @sizeOf(w32.FLASHWINFO),
                                .hwnd = win_hwnd,
                                .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                                .uCount = 2,
                                .dwTimeout = 0,
                            };
                            _ = w32.FlashWindowEx(&fwi);
                        }
                    }
                    // Mark the tab in the sidebar unless the bell rang
                    // in the active tab of the foreground window, where
                    // the user already sees it.
                    const loc = parent_window.findLocOfSurface(rt_surface);
                    const active = if (loc) |l|
                        l.ws == parent_window.activeWorkspace() and l.tab == l.ws.active_tab
                    else
                        false;
                    if (!active or !foreground) {
                        parent_window.setTabStatusForSurface(rt_surface, .bell);
                        const title: []const u16 = if (loc) |l|
                            l.ws.tab_titles[l.tab][0..l.ws.tab_title_lens[l.tab]]
                        else
                            std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
                        self.pushNotif(
                            .bell,
                            parent_window,
                            rt_surface,
                            title,
                            std.unicode.utf8ToUtf16LeStringLiteral("Bell"),
                        );
                    }
                },
            }
            return true;
        },

        .quit_timer => {
            switch (value) {
                .start => self.startQuitTimer(),
                .stop => self.stopQuitTimer(),
            }
            return true;
        },

        .config_change => {
            // Update our stored config with the new one.
            if (value.config.clone(self.core_app.alloc)) |new_config| {
                self.config.deinit();
                self.config = new_config;

                // Recreate the background brush from the new config.
                if (self.bg_brush) |old_brush| {
                    _ = w32.DeleteObject(@ptrCast(old_brush));
                }
                const bg = new_config.background;
                self.bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));

                // Refresh DWM chrome (dark/light, caption color) on
                // every live window so a config reload that changes
                // the background color updates the title bar.
                for (self.windows.items) |w| w.onConfigChange();

                // Update quick terminal config.
                if (self.quick_terminal) |qt| {
                    qt.onConfigChange(&self.config);
                }
            } else |err| {
                log.err("error updating app config err={}", .{err});
            }
            return true;
        },

        .toggle_fullscreen => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleFullscreen();
                },
            }
            return true;
        },

        .toggle_maximize => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |hwnd| {
                        if (w32.IsZoomed(hwnd) != 0) {
                            _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                        } else {
                            _ = w32.ShowWindow(hwnd, w32.SW_MAXIMIZE);
                        }
                    }
                },
            }
            return true;
        },

        .close_window => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    // Close the entire window (all tabs), not just one tab.
                    core_surface.rt_surface.parent_window.close();
                },
            }
            return true;
        },

        .open_config => {
            self.openConfigFile();
            return true;
        },

        .scrollbar => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setScrollbar(value);
                },
            }
            return true;
        },

        .mouse_shape => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseShape(value);
                },
            }
            return true;
        },

        .open_url => {
            // Open a URL using ShellExecuteW — the native Windows way.
            // internal_os.open() uses std.process.Child which can hit
            // unreachable on Windows, so we use ShellExecuteW directly.
            var wbuf: [2048]u16 = undefined;
            const wlen = std.unicode.utf8ToUtf16Le(&wbuf, value.url) catch return true;
            if (wlen < wbuf.len) {
                wbuf[wlen] = 0;
                _ = w32.ShellExecuteW(
                    null,
                    std.unicode.utf8ToUtf16LeStringLiteral("open"),
                    @ptrCast(&wbuf),
                    null,
                    null,
                    w32.SW_SHOW,
                );
            }
            return true;
        },

        .mouse_over_link => {
            // Acknowledge the action. The cursor shape change is handled
            // separately by mouse_shape → IDC_HAND. We could show the
            // URL in a status bar or tooltip here in the future.
            return true;
        },

        .start_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchActive(true, value.needle);
                },
            }
            return true;
        },

        .end_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchActive(false, "");
                },
            }
            return true;
        },

        .search_total, .search_selected => {
            // Acknowledge — we could display match count in the search
            // bar in the future.
            return true;
        },

        .desktop_notification => {
            self.showDesktopNotification(target, value);
            return true;
        },

        .new_tab => {
            // Add a new tab to the parent window of the focused surface.
            // Inherits the active pane's backend (keybind, command
            // palette, and surface context menu all land here).
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const parent = core_surface.rt_surface.parent_window;
                    _ = parent.addTabInherit() catch |err| {
                        log.err("failed to add new tab err={}", .{err});
                    };
                },
            }
            return true;
        },

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

        .goto_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    _ = core_surface.rt_surface.parent_window.selectTab(value);
                },
            }
            return true;
        },

        .set_tab_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.onTabTitleChanged(
                        core_surface.rt_surface,
                        value.title,
                    );
                },
            }
            return true;
        },

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
            return true;
        },

        .toggle_sidebar => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.toggleSidebar();
                },
            }
            return true;
        },

        .save_session => {
            const alloc = self.core_app.alloc;
            if (self.windows.items.len > 0) {
                SessionState.save(alloc, self.windows.items[0]) catch |err| {
                    log.err("session save failed: {}", .{err});
                };
            }
            return true;
        },

        .edit_workspace_description => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const pw = core_surface.rt_surface.parent_window;
                    pw.editWorkspaceDescription(pw.active_workspace);
                },
            }
            return true;
        },

        .toggle_right_sidebar => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.toggleRightSidebar();
                },
            }
            return true;
        },

        .restore_session => {
            const alloc = self.core_app.alloc;
            SessionState.restore(alloc, self) catch |err| {
                log.err("session restore failed: {}", .{err});
            };
            return true;
        },

        .focus_right_sidebar => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.focusRightSidebar();
                },
            }
            return true;
        },

        .initial_size => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        // Convert client size to window size (accounts for
                        // title bar, borders, scrollbar).
                        var rect = w32.RECT{
                            .left = 0,
                            .top = 0,
                            .right = @intCast(value.width),
                            .bottom = @intCast(value.height),
                        };
                        _ = w32.AdjustWindowRectEx(&rect, w32.WS_OVERLAPPEDWINDOW, 0, 0);
                        _ = w32.SetWindowPos(
                            h,
                            null,
                            0,
                            0,
                            rect.right - rect.left,
                            rect.bottom - rect.top,
                            w32.SWP_NOZORDER | w32.SWP_NOMOVE,
                        );
                    }
                },
            }
            return true;
        },

        .reload_config => {
            // Reload config and push to the core, which triggers
            // config_change actions on all surfaces.
            const alloc = self.core_app.alloc;
            if (value.soft) {
                // Soft reload: re-apply existing config (for conditional state changes)
                self.core_app.updateConfig(self, &self.config) catch |err| {
                    log.err("soft config reload error: {}", .{err});
                };
            } else {
                // Hard reload: read config from disk
                var new_config = Config.load(alloc) catch |err| {
                    log.err("failed to reload config: {}", .{err});
                    return true;
                };
                defer new_config.deinit();
                self.core_app.updateConfig(self, &new_config) catch |err| {
                    log.err("config update error: {}", .{err});
                };
            }
            return true;
        },

        .show_child_exited => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const rt_surface = core_surface.rt_surface;
                    const parent_window = rt_surface.parent_window;
                    // Mark the tab in the sidebar even when it's the
                    // active tab; the user may be looking elsewhere
                    // when the shell exits.
                    parent_window.setTabStatusForSurface(rt_surface, .exited);
                    const title: []const u16 = if (parent_window.findLocOfSurface(rt_surface)) |l|
                        l.ws.tab_titles[l.tab][0..l.ws.tab_title_lens[l.tab]]
                    else
                        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
                    self.pushNotif(
                        .exited,
                        parent_window,
                        rt_surface,
                        title,
                        std.unicode.utf8ToUtf16LeStringLiteral("Process exited"),
                    );
                    const exit_code = value.exit_code;
                    if (exit_code != 0) {
                        // Show a message box including the actual exit code.
                        const hwnd_val = rt_surface.parent_window.hwnd;
                        var utf8_buf: [128]u8 = undefined;
                        const msg_utf8 = std.fmt.bufPrint(
                            &utf8_buf,
                            "The shell process exited with code {d}.",
                            .{exit_code},
                        ) catch "The shell process exited unexpectedly.";

                        var utf16_buf: [256]u16 = undefined;
                        const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, msg_utf8) catch {
                            _ = w32.MessageBoxW(
                                hwnd_val,
                                std.unicode.utf8ToUtf16LeStringLiteral("The shell process exited unexpectedly."),
                                std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
                                w32.MB_ICONWARNING,
                            );
                            return true;
                        };
                        utf16_buf[utf16_len] = 0;
                        _ = w32.MessageBoxW(
                            hwnd_val,
                            @ptrCast(&utf16_buf),
                            std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
                            w32.MB_ICONWARNING,
                        );
                    }
                },
            }
            return true;
        },

        .toggle_window_decorations => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleWindowDecorations();
                },
            }
            return true;
        },

        .close_all_windows => {
            // Close all surfaces by posting WM_CLOSE to each.
            // The core tracks surfaces; iterate via quit.
            self.quit_requested = true;
            w32.PostQuitMessage(0);
            return true;
        },

        .toggle_background_opacity => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        const current_ex = w32.GetWindowLongW(h, w32.GWL_EXSTYLE);
                        if (current_ex & w32.WS_EX_LAYERED != 0) {
                            // Remove layered style (restore full opacity)
                            _ = w32.SetWindowLongW(h, w32.GWL_EXSTYLE, current_ex & ~w32.WS_EX_LAYERED);
                        } else {
                            // Apply opacity from config
                            _ = w32.SetWindowLongW(h, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
                            const alpha: u8 = @intFromFloat(@round(self.config.@"background-opacity" * 255.0));
                            _ = w32.SetLayeredWindowAttributes(h, 0, alpha, w32.LWA_ALPHA);
                        }
                    }
                },
            }
            return true;
        },

        .goto_window => {
            // With no tab bar, each "tab" is a window — goto_window
            // and goto_tab behave the same. Just acknowledge.
            return true;
        },

        .reset_window_size => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        // Reset to default 800x600
                        var rect = w32.RECT{
                            .left = 0, .top = 0,
                            .right = 800, .bottom = 600,
                        };
                        _ = w32.AdjustWindowRectEx(&rect, w32.WS_OVERLAPPEDWINDOW, 0, 0);
                        _ = w32.SetWindowPos(
                            h, null, 0, 0,
                            rect.right - rect.left,
                            rect.bottom - rect.top,
                            w32.SWP_NOZORDER | w32.SWP_NOMOVE,
                        );
                    }
                },
            }
            return true;
        },

        .copy_title_to_clipboard => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        // Get the window title and put it on the clipboard
                        var wbuf: [512]u16 = undefined;
                        const wlen: usize = @intCast(w32.GetWindowTextW(h, &wbuf, @intCast(wbuf.len)));
                        if (wlen > 0) {
                            var utf8_buf: [1024]u8 = undefined;
                            const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;
                            if (utf8_len > 0) {
                                // Copy to clipboard via the core surface
                                const alloc = self.core_app.alloc;
                                const text = alloc.dupeZ(u8, utf8_buf[0..utf8_len]) catch return true;
                                defer alloc.free(text);
                                core_surface.rt_surface.setClipboard(
                                    .standard,
                                    &.{.{ .mime = "text/plain", .data = text }},
                                    false,
                                ) catch {};
                            }
                        }
                    }
                },
            }
            return true;
        },

        .render => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.core_surface_ready) {
                        core_surface.rt_surface.core_surface.renderer_thread.wakeup.notify() catch {};
                    }
                },
            }
            return true;
        },

        // Acknowledge actions that don't need Win32-specific handling.
        // The core handles the logic; we just confirm receipt.
        .renderer_health,
        .key_sequence,
        .key_table,
        .pwd,
        .cell_size,
        .progress_report,
        .readonly,
        .selection_changed, // No accessibility consumer on Win32 yet
        // Platform-specific actions that don't apply on Windows:
        .secure_input, // macOS EnableSecureEventInput
        .undo, // macOS NSUndoManager
        .redo, // macOS NSUndoManager
        .show_gtk_inspector, // GTK-only
        .show_on_screen_keyboard, // GTK/mobile
        .inspector, // Not yet implemented (debug overlay)
        .render_inspector, // Not yet implemented (debug overlay)
        => return true,

        .color_change => {
            // Track terminal background color changes (OSC 10/11) so the
            // class background brush matches. The renderer paints the
            // client area via OpenGL — the brush only affects the brief
            // flash on resize before the renderer catches up.
            if (value.kind != .background) return true;
            if (self.bg_brush) |old_brush| {
                _ = w32.DeleteObject(@ptrCast(old_brush));
            }
            self.bg_brush = w32.CreateSolidBrush(w32.RGB(value.r, value.g, value.b));
            // SetClassLongPtrW propagates the new brush to all existing
            // windows of the class, not just future ones.
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (self.bg_brush) |b| {
                        _ = w32.SetClassLongPtrW(
                            h,
                            w32.GCLP_HBRBACKGROUND,
                            @intCast(@intFromPtr(b)),
                        );
                    }
                }
            }
            return true;
        },

        .size_limit => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    win.min_track_w = @intCast(value.min_width);
                    win.min_track_h = @intCast(value.min_height);
                    win.max_track_w = @intCast(value.max_width);
                    win.max_track_h = @intCast(value.max_height);
                },
            }
            return true;
        },

        .toggle_visibility => {
            // Hide all visible top-level Ghostty windows; if any are
            // already hidden, show + restore them. Equivalent to macOS
            // NSApp hide / show.
            var any_visible = false;
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (w32.IsWindowVisible_(h) != 0) {
                        any_visible = true;
                        break;
                    }
                }
            }
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (any_visible) {
                        _ = w32.ShowWindow(h, w32.SW_HIDE);
                    } else {
                        _ = w32.ShowWindow(h, w32.SW_SHOWNOACTIVATE);
                    }
                }
            }
            // The quick terminal manages its own visibility separately.
            return true;
        },

        .float_window => {
            // Toggle WS_EX_TOPMOST so the window stays above non-topmost
            // windows. Equivalent to macOS NSWindow.level = .floating.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win_hwnd = core_surface.rt_surface.parent_window.hwnd orelse return true;
                    const ex = w32.GetWindowLongPtrW(win_hwnd, w32.GWL_EXSTYLE);
                    const is_topmost = (ex & @as(isize, w32.WS_EX_TOPMOST)) != 0;
                    const want: bool = switch (value) {
                        .on => true,
                        .off => false,
                        .toggle => !is_topmost,
                    };
                    if (want == is_topmost) return true;
                    const insert_after = if (want) w32.HWND_TOPMOST else w32.HWND_NOTOPMOST;
                    _ = w32.SetWindowPos(
                        win_hwnd,
                        insert_after,
                        0, 0, 0, 0,
                        w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE,
                    );
                },
            }
            return true;
        },

        .command_finished => {
            // Flash the taskbar button if the window isn't currently the
            // foreground window. macOS bounces the dock icon for the
            // same reason. We only flash on non-zero exit codes — a
            // successful command shouldn't pull the user back.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (value.exit_code orelse 0 == 0) return true;
                    const win_hwnd = core_surface.rt_surface.parent_window.hwnd orelse return true;
                    const fg = w32.GetForegroundWindow();
                    if (fg == win_hwnd) return true;
                    var fwi: w32.FLASHWINFO = .{
                        .cbSize = @sizeOf(w32.FLASHWINFO),
                        .hwnd = win_hwnd,
                        .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                        .uCount = 3,
                        .dwTimeout = 0,
                    };
                    _ = w32.FlashWindowEx(&fwi);
                },
            }
            return true;
        },

        .mouse_visibility => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const visible = value == .visible;
                    core_surface.rt_surface.mouse_visible = visible;
                    // Force the next WM_SETCURSOR to apply the new state
                    // by issuing SetCursor immediately if the cursor is
                    // currently in our client area.
                    if (!visible) {
                        _ = w32.SetCursor(null);
                    } else if (core_surface.rt_surface.current_cursor) |c| {
                        _ = w32.SetCursor(c);
                    }
                },
            }
            return true;
        },

        .present_terminal => {
            // Raise the window containing the target surface and select
            // its tab. Restores from minimized/iconic state if necessary.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    if (win.hwnd) |hwnd| {
                        // Only un-minimize: SW_RESTORE on a *maximized*
                        // window un-maximizes it to the restored rect, so a
                        // notification click would shrink/resize a maximized
                        // window. Gate on IsIconic so a maximized or normal
                        // window keeps its size/maximized state untouched.
                        if (w32.IsIconic(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                        // Only move OS foreground when we already own it;
                        // never yank the user out of another app (the
                        // critical OS-foreground gate, applied to every
                        // raise path).
                        forceForegroundWindow(hwnd);
                        // Make sure the workspace AND tab containing this
                        // surface are active: select the workspace first
                        // (it re-lays out for the new tab count), then the
                        // tab within it. Order matters.
                        if (win.findLocOfSurface(core_surface.rt_surface)) |loc| {
                            win.selectWorkspace(win.workspaceIndex(loc.ws));
                            if (loc.tab != loc.ws.active_tab) win.selectTabIndex(loc.tab);
                        }
                        // Focus the surface's child HWND.
                        if (core_surface.rt_surface.hwnd) |sh| {
                            _ = w32.SetFocus(sh);
                        }
                    }
                },
            }
            return true;
        },

        .new_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const dir: SplitTree(Pane).Split.Direction = switch (value) {
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

        .goto_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.gotoSplit(value);
                },
            }
            return true;
        },

        .swap_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.swapSplit(value);
                },
            }
            return true;
        },

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

        .select_layout => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.selectLayout(value);
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

        .toggle_synchronized_input => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.toggleSynchronizedInput();
                },
            }
            return true;
        },

        .break_pane => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const pane = core_surface.rt_surface.pane orelse return true;
                    core_surface.rt_surface.parent_window.breakPane(pane);
                },
            }
            return true;
        },

        .move_pane => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const pane = core_surface.rt_surface.pane orelse return true;
                    core_surface.rt_surface.parent_window.movePaneToTab(pane, value);
                },
            }
            return true;
        },

        .prompt_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    // Both .tab and .surface trigger inline rename on the
                    // current tab. On Win32 there's no separate surface title
                    // UI — the tab title IS the surface identity.
                    const pw = core_surface.rt_surface.parent_window;
                    pw.startTabRename(pw.activeWorkspace().active_tab);
                },
            }
            return true;
        },

        .check_for_updates => {
            self.startUpdateCheck();
            return true;
        },

        .toggle_command_palette => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const active = core_surface.rt_surface.palette_active;
                    core_surface.rt_surface.setCommandPaletteActive(!active);
                },
            }
            return true;
        },

        .toggle_quick_terminal => {
            if (self.quick_terminal) |qt| {
                qt.toggle();
            } else {
                const qt = QuickTerminal.init(self) catch |err| {
                    log.err("failed to create quick terminal: {}", .{err});
                    return true;
                };
                self.quick_terminal = qt;
                qt.toggle();
            }
            return true;
        },

        // All 67 apprt actions are now handled above.
        // All 68 apprt actions are now handled above.
        .flash_pane => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.flashFocusedPane();
                },
            }
            return true;
        },

        // All 67 apprt actions are now handled above.
        .toggle_notification_unread => {
            // Toggle the most recent notification's read state. Display
            // index 0 is the newest entry.
            _ = self.toggleNotifRead(0);
            return true;
        },

        .mark_oldest_unread_jump => {
            _ = self.markOldestUnreadAndJumpNext();
            return true;
        },

        // All apprt actions are now handled above.
        // All 68 apprt actions are now handled above.
    }
}

/// Template written when the config file is missing at open time so the
/// editor has something to show. Config.load writes a fuller template at
/// startup; this covers a file deleted while the app is running.
const CONFIG_TEMPLATE =
    "# Ghostty config — see https://ghostty.org/docs/config\n" ++
    "# window-show-sidebar = true\n" ++
    "# window-sidebar-width = 220\n";

/// Resolve the user config file path the same way config loading does
/// (XDG shim: %LOCALAPPDATA%\ghostty\config.ghostty unless overridden),
/// creating parent directories and a commented template when the file
/// is missing. The returned path is owned by the caller.
fn resolveConfigFile(self: *App) ?[]const u8 {
    const path = configpkg.preferredDefaultFilePath(
        self.core_app.alloc,
    ) catch |err| {
        log.err("failed to get config path: {}", .{err});
        return null;
    };
    if (std.fs.accessAbsolute(path, .{})) |_| {} else |_| {
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                log.warn("failed to create config dir={s} err={}", .{ dir, err });
            };
        }
        if (std.fs.createFileAbsolute(path, .{ .exclusive = true })) |file| {
            defer file.close();
            file.writeAll(CONFIG_TEMPLATE) catch |err| {
                log.warn("failed to write config template err={}", .{err});
            };
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => log.warn("failed to create config file={s} err={}", .{ path, err }),
        }
    }
    return path;
}

/// Produce config-file text with the `command` key set to `value`,
/// preserving every other line. If a non-comment `command = ...` line
/// already exists, the first one is replaced in place (later duplicates
/// are left untouched — the config parser uses the last occurrence, but
/// rewriting only the first keeps edits minimal and predictable); a
/// commented `# command = ...` line is NOT treated as a match. If no
/// active `command` line exists, `command = <value>` is appended on its
/// own line (with a preceding newline only when the source does not end
/// in one). The result is owned by the caller.
///
/// `value` is a raw config value (e.g. "pwsh.exe" or
/// "wsl.exe --cd ~ -d Ubuntu") and is written verbatim; callers pass a
/// program name or a space-joined argv that the config's Command parser
/// understands.
fn setCommandInConfigText(
    alloc: Allocator,
    source: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var replaced = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        // splitScalar yields a trailing empty segment when the source
        // ends in '\n'; preserve the structure by re-emitting newlines
        // between segments rather than after each.
        if (!first) try out.append(alloc, '\n');
        first = false;

        // A line is the `command` key if, after trimming, the text
        // before the first '=' equals "command" (case-sensitive, like
        // the config parser). Tolerate a trailing '\r' from CRLF files.
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (!replaced) {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const key = std.mem.trim(u8, trimmed[0..eq], " \t");
                if (std.mem.eql(u8, key, "command")) {
                    try out.appendSlice(alloc, "command = ");
                    try out.appendSlice(alloc, value);
                    replaced = true;
                    continue;
                }
            }
        }
        try out.appendSlice(alloc, raw_line);
    }

    if (!replaced) {
        // Append on its own line. Add a separating newline unless the
        // file is empty or already ends in one.
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(alloc, '\n');
        }
        try out.appendSlice(alloc, "command = ");
        try out.appendSlice(alloc, value);
        try out.append(alloc, '\n');
    }

    return out.toOwnedSlice(alloc);
}

/// Set the default shell by writing `command = <value>` into the user
/// config file (preserving all other content), then hard-reloading so
/// the change takes effect for subsequently created tabs/splits. This
/// is the GUI exposure of the `command` config option, which the
/// default-tab path already honors (see Exec.zig). `value` is written
/// verbatim as the config value (e.g. "pwsh.exe").
pub fn setDefaultShell(self: *App, value: []const u8) void {
    const alloc = self.core_app.alloc;

    // resolveConfigFile creates the file (with the template) when it is
    // missing, so the read below always sees a real file.
    const path = self.resolveConfigFile() orelse return;
    defer alloc.free(path);

    const source = std.fs.cwd().readFileAlloc(
        alloc,
        path,
        16 * 1024 * 1024,
    ) catch |err| {
        log.err("set default shell: failed to read config={s} err={}", .{ path, err });
        return;
    };
    defer alloc.free(source);

    const updated = setCommandInConfigText(alloc, source, value) catch |err| {
        log.err("set default shell: failed to build config text err={}", .{err});
        return;
    };
    defer alloc.free(updated);

    // Write atomically so a failure mid-write can't truncate the user's
    // config: write a sibling temp file, then rename over the original.
    writeFileAtomic(alloc, path, updated) catch |err| {
        log.err("set default shell: failed to write config={s} err={}", .{ path, err });
        return;
    };

    log.info("set default shell: wrote command={s} to {s}", .{ value, path });

    // Hard reload from disk so the new command applies. Same path as the
    // gear "Reload config" entry / reload_config keybind.
    self.core_app.performAction(self, .reload_config) catch |err| {
        log.err("set default shell: reload failed: {}", .{err});
    };
}

/// Write `data` to `path` atomically by writing to a temp file in the
/// same directory and renaming it over the destination. Falls back to a
/// direct write if a temp file cannot be created in that directory.
fn writeFileAtomic(alloc: Allocator, path: []const u8, data: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);

    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    const tmp_name = try std.fmt.allocPrint(alloc, "{s}.ghostty-tmp", .{base});
    defer alloc.free(tmp_name);

    {
        const file = dir.createFile(tmp_name, .{ .truncate = true }) catch {
            // Could not create a temp file (e.g. read-only dir quirk);
            // fall back to a direct overwrite.
            try dir.writeFile(.{ .sub_path = base, .data = data });
            return;
        };
        defer file.close();
        try file.writeAll(data);
    }
    errdefer dir.deleteFile(tmp_name) catch {};
    try dir.rename(tmp_name, base);
}

/// Open the user config file in its default editor, falling back to
/// notepad.exe when nothing is associated with the file (extensionless
/// legacy `config` paths commonly have no "open" verb).
pub fn openConfigFile(self: *App) void {
    const path = self.resolveConfigFile() orelse return;
    defer self.core_app.alloc.free(path);

    var wbuf: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return;
    if (wlen >= wbuf.len) return;
    wbuf[wlen] = 0;

    // ShellExecuteW returns > 32 on success; <= 32 is an SE_ERR_* code.
    const result = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        @ptrCast(&wbuf),
        null,
        null,
        w32.SW_SHOW,
    );
    if (result > 32) return;
    log.warn("ShellExecuteW open config failed code={d}, falling back to notepad", .{result});

    // CreateProcessW may modify the command line, so build it in a
    // mutable buffer. Quoting is safe: Windows paths cannot contain '"'.
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("notepad.exe \"");
    var cmd_buf: [prefix.len + wbuf.len + 2]u16 = undefined;
    @memcpy(cmd_buf[0..prefix.len], prefix);
    @memcpy(cmd_buf[prefix.len .. prefix.len + wlen], wbuf[0..wlen]);
    cmd_buf[prefix.len + wlen] = '"';
    cmd_buf[prefix.len + wlen + 1] = 0;

    var si = std.mem.zeroes(w32.STARTUPINFOW);
    si.cb = @sizeOf(w32.STARTUPINFOW);
    var pi = std.mem.zeroes(w32.PROCESS_INFORMATION);
    if (w32.CreateProcessW(
        null,
        @ptrCast(&cmd_buf),
        null,
        null,
        0,
        0,
        null,
        null,
        &si,
        &pi,
    ) != 0) {
        if (pi.hProcess) |h| _ = w32.CloseHandle(h);
        if (pi.hThread) |h| _ = w32.CloseHandle(h);
    } else {
        log.err("notepad fallback failed for config path={s}", .{path});
    }
}

/// Open the folder containing the user config file in Explorer.
/// resolveConfigFile created the directory, so the open cannot race a
/// missing folder.
pub fn openConfigFolder(self: *App) void {
    const path = self.resolveConfigFile() orelse return;
    defer self.core_app.alloc.free(path);
    const dir = std.fs.path.dirname(path) orelse return;

    var wbuf: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, dir) catch return;
    if (wlen >= wbuf.len) return;
    wbuf[wlen] = 0;
    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        @ptrCast(&wbuf),
        null,
        null,
        w32.SW_SHOW,
    );
}

/// Ctrl-modified VKs that should remain with the focused Edit control
/// rather than bubbling to the surface as a keybinding. Select-all,
/// copy, paste, cut, redo, undo.
fn isEditShortcutVk(vk: u16) bool {
    return switch (vk) {
        'A', 'C', 'V', 'X', 'Y', 'Z' => true,
        else => false,
    };
}

/// Register a system-wide hotkey for toggle_quick_terminal.
/// Scans keybinds for entries with the `global` flag.
fn registerGlobalHotkey(self: *App) void {
    var it = self.config.keybind.set.bindings.iterator();
    while (it.next()) |entry| {
        const leaf = switch (entry.value_ptr.*) {
            .leader => continue,
            .leaf => |l| l,
            .leaf_chained => continue,
        };
        if (!leaf.flags.global) continue;

        // Check if this binding is for toggle_quick_terminal.
        const is_quick_terminal = switch (leaf.action) {
            .toggle_quick_terminal => true,
            else => false,
        };
        if (!is_quick_terminal) continue;

        const trigger = entry.key_ptr.*;

        // Convert Ghostty mods to Win32 mods.
        var mods: u32 = w32.MOD_NOREPEAT;
        if (trigger.mods.ctrl) mods |= w32.MOD_CONTROL;
        if (trigger.mods.alt) mods |= w32.MOD_ALT;
        if (trigger.mods.shift) mods |= w32.MOD_SHIFT;
        if (trigger.mods.super) mods |= w32.MOD_WIN;

        // Convert Ghostty key to Win32 VK.
        const vk: ?u32 = switch (trigger.key) {
            .physical => |phys| keyToVk(phys),
            .unicode => |cp| blk: {
                // For ASCII characters, VK code = uppercase char.
                if (cp >= 'a' and cp <= 'z') break :blk @as(u32, cp - 'a' + 'A');
                if (cp >= '0' and cp <= '9') break :blk @as(u32, cp);
                break :blk null;
            },
            else => null,
        };

        if (vk) |vk_code| {
            if (w32.RegisterHotKey(null, 1, mods, vk_code) != 0) {
                self.global_hotkey_registered = true;
                log.info("registered global hotkey for quick terminal", .{});
            } else {
                log.warn("failed to register global hotkey (may be in use by another app)", .{});
            }
        } else {
            log.warn("unsupported key for global hotkey", .{});
        }
        break; // Only register the first matching binding.
    }
}

/// Map a Ghostty physical key to a Win32 virtual key code.
fn keyToVk(key: @import("../../input/key.zig").Key) ?u32 {
    return switch (key) {
        .key_a => 0x41, .key_b => 0x42, .key_c => 0x43, .key_d => 0x44,
        .key_e => 0x45, .key_f => 0x46, .key_g => 0x47, .key_h => 0x48,
        .key_i => 0x49, .key_j => 0x4A, .key_k => 0x4B, .key_l => 0x4C,
        .key_m => 0x4D, .key_n => 0x4E, .key_o => 0x4F, .key_p => 0x50,
        .key_q => 0x51, .key_r => 0x52, .key_s => 0x53, .key_t => 0x54,
        .key_u => 0x55, .key_v => 0x56, .key_w => 0x57, .key_x => 0x58,
        .key_y => 0x59, .key_z => 0x5A,
        .digit_0 => 0x30, .digit_1 => 0x31, .digit_2 => 0x32, .digit_3 => 0x33,
        .digit_4 => 0x34, .digit_5 => 0x35, .digit_6 => 0x36, .digit_7 => 0x37,
        .digit_8 => 0x38, .digit_9 => 0x39,
        .backquote => w32.VK_OEM_3,
        .minus => w32.VK_OEM_MINUS,
        .equal => w32.VK_OEM_PLUS,
        .bracket_left => w32.VK_OEM_4,
        .bracket_right => w32.VK_OEM_6,
        .backslash => w32.VK_OEM_5,
        .semicolon => w32.VK_OEM_1,
        .quote => w32.VK_OEM_7,
        .comma => w32.VK_OEM_COMMA,
        .period => w32.VK_OEM_PERIOD,
        .slash => w32.VK_OEM_2,
        .enter => w32.VK_RETURN,
        .tab => w32.VK_TAB,
        .space => w32.VK_SPACE,
        .backspace => w32.VK_BACK,
        .escape => w32.VK_ESCAPE,
        .f1 => w32.VK_F1, .f2 => w32.VK_F2, .f3 => w32.VK_F3,
        .f4 => w32.VK_F4, .f5 => w32.VK_F5, .f6 => w32.VK_F6,
        .f7 => w32.VK_F7, .f8 => w32.VK_F8, .f9 => w32.VK_F9,
        .f10 => w32.VK_F10, .f11 => w32.VK_F11, .f12 => w32.VK_F12,
        else => null,
    };
}

// -----------------------------------------------------------------------
// Update Checker
// -----------------------------------------------------------------------

/// GitHub releases API URL for this fork.
const UPDATE_URL = "https://api.github.com/repos/InsipidPoint/ghostty-windows/releases/latest";

/// Custom message posted from the update thread to the message loop.
const WM_APP_UPDATE_AVAILABLE: u32 = w32.WM_APP + 2;

/// Tray-icon notification callback (uCallbackMessage). The wparam is
/// the tray icon's uID; lparam carries NIN_* events.
const WM_APP_TRAY: u32 = w32.WM_APP + 3;

/// User-facing GitHub releases page that the update balloon links to.
const RELEASES_URL = "https://github.com/InsipidPoint/ghostty-windows/releases/latest";

/// Tray icon and timer IDs for notifications. Distinct IDs mean the
/// desktop and update balloons can coexist without one's auto-cleanup
/// removing the other's icon. Timer IDs share the msg_hwnd WM_TIMER
/// namespace with QUIT_TIMER_ID=1 and QuickTerminal.ANIM_TIMER_ID=3 and
/// must stay unique across all of them (the update timer was 3, which
/// the anim-timer check shadowed whenever a quick terminal existed,
/// leaving the update tray icon undeleted).
const NOTIF_UPDATE_UID: u32 = 2;
const NOTIF_UPDATE_TIMER_ID: usize = 4;

/// Periodic timer that refreshes the sidebar workspace metadata (git
/// branch, listening ports, PR status). Fires on the UI thread; the actual
/// git/gh/TCP-table work runs on a worker thread spawned per tick. Shares
/// the msg_hwnd WM_TIMER namespace, distinct from the IDs above.
const WS_META_TIMER_ID: usize = 5;

/// Refresh cadence for sidebar metadata, in milliseconds. The git/port
/// scan is cheap and runs every tick; the gh PR probe (network) runs only
/// once every WS_META_PR_EVERY ticks.
const WS_META_INTERVAL_MS: u32 = 4000;
const WS_META_PR_EVERY: u64 = 8; // ~32s with a 4s tick

/// Desktop notifications rotate through a small range of slots so that
/// several balloons can be in flight at once, each with its own tray
/// uID, cleanup timer, and recorded click target. Slot `i` uses uID
/// NOTIF_DESKTOP_UID_BASE+i and timer NOTIF_DESKTOP_TIMER_BASE+i.
const NOTIF_DESKTOP_SLOTS: usize = 8;
const NOTIF_DESKTOP_UID_BASE: u32 = 100;
const NOTIF_DESKTOP_TIMER_BASE: usize = 100;

/// Click target recorded for an in-flight desktop notification. The
/// pointers may dangle by the time the balloon is clicked (tab or
/// window closed since), so they are compared by address against the
/// live window/tab lists before being dereferenced.
const DesktopNotif = struct {
    window: *Window,
    surface: *Surface,
};

/// Capacity of the sidebar notification log ring buffer.
pub const NOTIF_LOG_CAP: usize = 64;

/// One sidebar notification log entry. Title/body are stored inline
/// (UTF-16, truncated) so painting never dereferences the window or
/// surface pointers; those are only used to jump and are validated by
/// address first (jumpToSurface), like DesktopNotif.
pub const NotifEntry = struct {
    pub const Kind = enum { osc, bell, exited };

    kind: Kind,
    window: *Window,
    surface: *Surface,
    title: [128]u16,
    title_len: usize,
    body: [128]u16,
    body_len: usize,
    /// Per-entry lifecycle: false = Unread (contributes to the badge and is
    /// a `+notify next` jump target), true = Read (the user viewed it, by
    /// opening the panel or jumping to it). Distinct from the ring's
    /// aggregate `unread` counter, which drives the bell badge: a freshly
    /// pushed entry is Unread; markRead/opening the panel marks all live
    /// entries Read; jumping to one marks just that one Read.
    read: bool = false,
};

/// Fixed-capacity ring of optional entries with newest-first display
/// indexing and an unread counter. Pure accounting (no Win32) so the
/// wrap/hole/unread rules are unit-testable; callers handle repaints.
pub fn NotifRing(comptime Entry: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        /// Slots, written round-robin at `next`. Holes (nulled slots)
        /// are skipped by count/at so display indices stay contiguous.
        slots: [cap]?Entry = @splat(null),

        /// Next slot to overwrite.
        next: usize = 0,

        /// Entries pushed since the last markRead. Counts pushes, not
        /// live slots, so it can exceed `cap` (the sidebar badge
        /// saturates its display at "9+" regardless).
        unread: usize = 0,

        pub fn push(self: *Self, entry: Entry) void {
            self.slots[self.next] = entry;
            self.next = (self.next + 1) % cap;
            self.unread += 1;
        }

        /// Reset the unread counter. Returns true when it was nonzero
        /// (the caller repaints only then).
        pub fn markRead(self: *Self) bool {
            if (self.unread == 0) return false;
            self.unread = 0;
            return true;
        }

        /// Drop every entry and the unread counter.
        pub fn clear(self: *Self) void {
            self.slots = @splat(null);
            self.next = 0;
            self.unread = 0;
        }

        /// Number of live entries.
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |slot| {
                if (slot != null) n += 1;
            }
            return n;
        }

        /// Count of live entries whose `read` field is false. Only valid
        /// when `Entry` has a `read: bool` field (the notification log);
        /// drives the taskbar unread-count badge. Pure so the read-flag
        /// accounting is unit-testable.
        pub fn unreadLive(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |slot| {
                if (slot) |entry| {
                    if (!entry.read) n += 1;
                }
            }
            return n;
        }

        /// Display index (0 = newest) of the most-recent live entry whose
        /// `read` field is false, or null when every live entry is read.
        /// Walks newest-first using the same hole-skipping mapping as `at`.
        pub fn firstUnread(self: *const Self) ?usize {
            var display_idx: usize = 0;
            for (0..cap) |offset| {
                const idx = (self.next + cap - 1 - offset) % cap;
                if (self.slots[idx]) |entry| {
                    if (!entry.read) return display_idx;
                    display_idx += 1;
                }
            }
            return null;
        }

        /// Display index (0 = newest) of the **oldest** live entry whose
        /// `read` field is false, or null when every live entry is read.
        /// Walks newest-first, tracking the last seen unread.
        pub fn lastUnread(self: *const Self) ?usize {
            var display_idx: usize = 0;
            var result: ?usize = null;
            for (0..cap) |offset| {
                const idx = (self.next + cap - 1 - offset) % cap;
                if (self.slots[idx]) |entry| {
                    if (!entry.read) result = display_idx;
                    display_idx += 1;
                }
            }
            return result;
        }

        /// The display_idx-th newest live entry (0 = newest), or null
        /// past the end.
        pub fn at(self: *const Self, display_idx: usize) ?*const Entry {
            var seen: usize = 0;
            for (0..cap) |offset| {
                const idx = (self.next + cap - 1 - offset) % cap;
                if (self.slots[idx]) |*entry| {
                    if (seen == display_idx) return entry;
                    seen += 1;
                }
            }
            return null;
        }
    };
}

/// Minimum interval between update checks, in seconds. The check
/// timestamp is persisted in %LOCALAPPDATA%/ghostty/update_check_at.
const UPDATE_CHECK_INTERVAL_SECS: i64 = 60 * 60; // 1 hour

/// Start a background thread to check for updates. Skips the actual
/// fetch if we checked within the last UPDATE_CHECK_INTERVAL_SECS.
/// Manual `.check_for_updates` actions force-refresh by setting
/// `force=true`.
fn startUpdateCheck(self: *App) void {
    if (!self.shouldRunUpdateCheck()) {
        log.debug("skipping update check (last run within {d}s)", .{UPDATE_CHECK_INTERVAL_SECS});
        return;
    }
    _ = std.Thread.spawn(.{}, updateCheckThread, .{self}) catch |err| {
        log.warn("failed to start update check thread: {}", .{err});
    };
}

/// Read the persisted "last checked at" timestamp; return true if
/// it's missing/stale. Updates the file with the current timestamp on
/// the way out so a successful return throttles the next call.
fn shouldRunUpdateCheck(self: *App) bool {
    const alloc = self.core_app.alloc;
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return true;
    defer alloc.free(dir);
    const path = std.fs.path.join(alloc, &.{ dir, "ghostty", "update_check_at" }) catch return true;
    defer alloc.free(path);

    const now = std.time.timestamp();
    if (std.fs.cwd().openFile(path, .{})) |f| {
        defer f.close();
        var buf: [32]u8 = undefined;
        const n = f.readAll(&buf) catch 0;
        const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (std.fmt.parseInt(i64, text, 10)) |last| {
            if (now - last < UPDATE_CHECK_INTERVAL_SECS) return false;
        } else |_| {}
    } else |_| {}

    // Write (or create) the file with the current timestamp.
    if (std.fs.cwd().makePath(std.fs.path.dirname(path) orelse return true)) |_| {} else |_| {}
    if (std.fs.cwd().createFile(path, .{ .truncate = true })) |f| {
        defer f.close();
        var ts_buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&ts_buf, "{d}", .{now}) catch return true;
        f.writeAll(s) catch {};
    } else |_| {}
    return true;
}

/// Background thread: fetch latest release tag from GitHub, compare
/// with current version, post a message if newer.
fn updateCheckThread(app: *App) void {
    const result = fetchLatestVersion() catch |err| {
        log.debug("update check failed: {}", .{err});
        return;
    };

    const latest = result.tag;
    const latest_len = result.len;
    if (latest_len == 0) return;

    // Strip "win-v" or "v" prefix from tag
    const latest_start: usize = if (std.mem.startsWith(u8, latest[0..latest_len], "win-v"))
        5
    else if (latest[0] == 'v')
        1
    else
        0;
    const latest_ver = latest[latest_start..latest_len];

    // Compare against the binary's own version (set by build.zig from
    // either build.zig.zon or the win-v git tag at build time).
    const current_sv = build_config.version;
    const latest_sv = std.SemanticVersion.parse(latest_ver) catch {
        log.debug("failed to parse remote version: {s}", .{latest_ver});
        return;
    };

    // Only notify if the remote version is strictly newer
    if (latest_sv.order(current_sv) != .gt) {
        log.debug("up to date: current={d}.{d}.{d} latest={s}", .{
            current_sv.major, current_sv.minor, current_sv.patch, latest_ver,
        });
        return;
    }
    log.info("update available: current={d}.{d}.{d} latest={s}", .{
        current_sv.major, current_sv.minor, current_sv.patch, latest_ver,
    });

    const hwnd = app.msg_hwnd orelse return;

    // Allocate a heap copy and hand ownership to the message handler via
    // wparam/lparam. This avoids a static-buffer race between this worker
    // thread writing the version and the message thread reading it.
    const alloc = app.core_app.alloc;
    const owned = alloc.dupe(u8, latest_ver) catch {
        log.warn("oom allocating update version", .{});
        return;
    };
    const wparam: usize = @intFromPtr(owned.ptr);
    const lparam: isize = @intCast(owned.len);
    if (w32.PostMessageW(hwnd, WM_APP_UPDATE_AVAILABLE, wparam, lparam) == 0) {
        // PostMessage failed (e.g., HWND already destroyed). Free the
        // buffer here since the handler will never run.
        alloc.free(owned);
    }
}

/// Show a notification balloon that an update is available. The handler
/// owns `ver` (heap-allocated by updateCheckThread) and is responsible
/// for freeing it.
fn showUpdateNotification(self: *App, ver: []const u8) void {
    const hwnd = self.msg_hwnd orelse return;
    if (ver.len == 0) return;
    const ver_len = ver.len;

    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_UPDATE_UID;
    // NIF_MESSAGE registers our callback so a click on the balloon
    // is delivered as WM_APP_TRAY → opens the GitHub releases page.
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
    nid.uCallbackMessage = WM_APP_TRAY;
    nid.hIcon = w32.LoadIconW(self.hinstance, w32.IDI_GHOSTTY) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 10000;

    // Title
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty Update Available");
    @memcpy(nid.szInfoTitle[0..title.len], title);
    nid.szInfoTitle[title.len] = 0;

    // Body: "Version X.Y.Z is available. Visit GitHub to download."
    var body_utf8: [256]u8 = undefined;
    const body_len = std.fmt.bufPrint(&body_utf8, "Version {s} is available.\nVisit GitHub releases to download.", .{ver[0..ver_len]}) catch return;
    var body_utf16: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&body_utf16, body_len) catch 0;
    @memcpy(nid.szInfo[0..wlen], body_utf16[0..wlen]);
    nid.szInfo[wlen] = 0;

    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;

    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);
    _ = w32.SetTimer(hwnd, NOTIF_UPDATE_TIMER_ID, 10000, null);
}

const VersionResult = struct { tag: [128]u8, len: usize };

/// Fetch the latest release tag from GitHub. Returns the tag string.
fn fetchLatestVersion() !VersionResult {
    const agent = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty-UpdateCheck/1.0");
    const inet = w32.InternetOpenW(agent, w32.INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0) orelse
        return error.InternetOpenFailed;
    defer _ = w32.InternetCloseHandle(inet);

    // Convert URL to UTF-16
    var url_buf: [256]u16 = undefined;
    const url_len = std.unicode.utf8ToUtf16Le(&url_buf, UPDATE_URL) catch return error.UrlTooLong;
    url_buf[url_len] = 0;

    const flags = w32.INTERNET_FLAG_SECURE | w32.INTERNET_FLAG_NO_CACHE_WRITE | w32.INTERNET_FLAG_RELOAD;
    const conn = w32.InternetOpenUrlW(inet, @ptrCast(&url_buf), null, 0, flags, 0) orelse
        return error.InternetOpenUrlFailed;
    defer _ = w32.InternetCloseHandle(conn);

    // Read response (we only need the first ~4KB for tag_name)
    var response: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < response.len) {
        var bytes_read: u32 = 0;
        if (w32.InternetReadFile(conn, response[total..].ptr, @intCast(response.len - total), &bytes_read) == 0) {
            return error.ReadFailed;
        }
        if (bytes_read == 0) break;
        total += bytes_read;
    }

    // Find "tag_name" in JSON response (simple string search, no JSON parser needed)
    const json = response[0..total];
    const needle = "\"tag_name\":\"";
    const start = std.mem.indexOf(u8, json, needle) orelse return error.TagNotFound;
    const tag_start = start + needle.len;
    const tag_end = std.mem.indexOfPos(u8, json, tag_start, "\"") orelse return error.TagNotFound;
    const tag = json[tag_start..tag_end];

    var result: VersionResult = .{ .tag = undefined, .len = tag.len };
    if (tag.len > 128) return error.TagTooLong;
    @memcpy(result.tag[0..tag.len], tag);
    return result;
}

/// Start the quit timer. Called when the last surface closes.
pub fn startQuitTimer(self: *App) void {
    // Cancel any existing timer first.
    self.stopQuitTimer();

    // Check if we should quit at all.
    if (!self.config.@"quit-after-last-window-closed") return;

    // If a delay is configured, start a Win32 timer.
    if (self.config.@"quit-after-last-window-closed-delay") |v| {
        const ms = v.asMilliseconds();
        if (self.msg_hwnd) |hwnd| {
            _ = w32.SetTimer(hwnd, QUIT_TIMER_ID, ms, null);
            self.quit_timer_state = .active;
        }
    } else {
        // No delay — quit immediately.
        self.quit_timer_state = .expired;
        self.quit_requested = true;
        w32.PostQuitMessage(0);
    }
}

/// Cancel the quit timer. Called when a new surface opens.
pub fn stopQuitTimer(self: *App) void {
    switch (self.quit_timer_state) {
        .off => {},
        .expired => {
            self.quit_timer_state = .off;
            // Reset quit_requested. The WM_QUIT posted by startQuitTimer's
            // no-delay path can't be removed from the queue (it's a flag,
            // not a real message). Instead, the message loop checks
            // quit_requested when GetMessageW returns 0 — if false, it
            // ignores the spurious WM_QUIT and continues. This handles
            // the normal startup sequence: main_ghostty calls
            // startQuitTimer() before any surfaces exist, then run()
            // creates the first surface which triggers stopQuitTimer().
            self.quit_requested = false;
        },
        .active => {
            if (self.msg_hwnd) |hwnd| {
                _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
            }
            self.quit_timer_state = .off;
        },
    }
}

/// Show a Windows balloon notification via Shell_NotifyIconW.
/// Creates a temporary tray icon, shows the balloon, then removes
/// the icon after a short delay.
/// Sentinel an agent emits via OSC 9 to toggle this pane's attention
/// ring without a desktop balloon. We piggyback on OSC 9 (the desktop
/// notification channel, which already routes a pane→apprt message on
/// every platform) rather than adding a private OSC to the shared
/// terminal parser, keeping the feature contained to the Win32 apprt.
///
///   set:   printf '\033]9;@ghostty-attention:ring\033\\'
///   clear: printf '\033]9;@ghostty-attention:clear\033\\'
///
/// (`\033\\` is ST; BEL `\a` works too.) PowerShell:
///   $e=[char]27; Write-Host "$e]9;@ghostty-attention:ring$e\" -NoNewline
const ATTENTION_OSC_PREFIX = "@ghostty-attention:";

/// Parse an OSC 9 notification body for the attention sentinel. Returns
/// true ("ring"), false ("clear"), or null when the body is an ordinary
/// notification (the caller then shows a normal balloon). Pure so the
/// wire format is unit-testable. Surrounding ASCII whitespace is trimmed
/// so a shell that pads the sequence still matches.
pub fn parseAttentionOsc(body: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, trimmed, ATTENTION_OSC_PREFIX)) return null;
    const verb = trimmed[ATTENTION_OSC_PREFIX.len..];
    if (std.mem.eql(u8, verb, "ring")) return true;
    if (std.mem.eql(u8, verb, "clear")) return false;
    return null;
}

/// Inputs to the smart desktop-toast suppression decision. Captured on the
/// UI thread immediately before the toast call so the decision is a pure
/// function of observable state (and thus unit-testable).
pub const ToastContext = struct {
    /// The Ghostty window owning the sending surface is the OS foreground
    /// window (GetForegroundWindow() == window.hwnd).
    window_foreground: bool,
    /// The sending surface's workspace is the active workspace in its
    /// window (the user is looking at that workspace's panes).
    workspace_active: bool,
    /// The notifications panel is open in the sending window (the user is
    /// actively watching the in-app notification log).
    panel_open: bool,
};

/// Decide whether to fire the Windows toast/balloon for a desktop
/// notification. The in-app attention ring + sidebar panel ALWAYS record
/// the event regardless; this governs only the OS-level interruption.
///
/// Suppress the toast only when the user is genuinely already looking at
/// the source: the window is in the foreground AND either the sending
/// workspace is the active one or the notifications panel is open. In every
/// other case (window backgrounded, or a different workspace is active and
/// the panel is closed) the toast fires so the user isn't left unaware.
///
/// Pure so the policy is unit-tested independent of any HWND/Win32 state.
pub fn shouldToast(ctx: ToastContext) bool {
    if (!ctx.window_foreground) return true;
    // Foregrounded: only suppress if the user is plausibly already watching
    // this notification's source.
    return !(ctx.workspace_active or ctx.panel_open);
}

fn showDesktopNotification(
    self: *App,
    target: apprt.Target,
    value: apprt.Action.Value(.desktop_notification),
) void {
    const hwnd = self.msg_hwnd orelse return;

    // Intercept the attention sentinel before doing any balloon work: an
    // agent's `OSC 9 ; @ghostty-attention:ring` sets/clears the ring on
    // its own pane and produces neither a balloon nor a log entry. Only a
    // surface target carries a pane to ring.
    if (parseAttentionOsc(value.body)) |on| {
        switch (target) {
            .app => {},
            .surface => |core_surface| {
                const rt = core_surface.rt_surface;
                rt.parent_window.setAttentionForSurface(rt, on);
            },
        }
        return;
    }

    // Convert title/body once (UTF-8 → UTF-16LE); reused by both the
    // in-app log entry and the balloon. Local buffers so the in-app path
    // works even when the balloon is suppressed.
    var title_buf: [64]u16 = undefined;
    var body_buf: [256]u16 = undefined;
    var title_len = std.unicode.utf8ToUtf16Le(&title_buf, value.title) catch 0;
    if (title_len >= title_buf.len) title_len = title_buf.len - 1;
    title_buf[title_len] = 0;
    var body_len = std.unicode.utf8ToUtf16Le(&body_buf, value.body) catch 0;
    if (body_len >= body_buf.len) body_len = body_buf.len - 1;
    body_buf[body_len] = 0;

    // The in-app side (attention ring + sidebar notification panel) ALWAYS
    // fires, regardless of the suppression decision below: a notification
    // is recorded and the pane is ringed even when we skip the OS toast.
    // Only a surface target carries a pane to ring / a window to address.
    const sender: ?DesktopNotif = switch (target) {
        .app => null,
        .surface => |core_surface| .{
            .window = core_surface.rt_surface.parent_window,
            .surface = core_surface.rt_surface,
        },
    };
    if (sender) |s| {
        // Ring the originating pane (the cmux-style attention ring). Skips
        // silently if the pane is the focused/visible one (you're already
        // looking at it) — setAttentionForSurface validates by address.
        s.window.setAttentionForSurface(s.surface, true);
        self.pushNotif(.osc, s.window, s.surface, title_buf[0..title_len], body_buf[0..body_len]);
    }

    // Smart suppression: skip the OS toast when the user is genuinely
    // already looking at the source. Decision captured from live UI state
    // here on the UI thread (see shouldToast). App targets (no window)
    // always toast.
    if (sender) |s| {
        const ctx: ToastContext = .{
            .window_foreground = if (s.window.hwnd) |wh| w32.GetForegroundWindow() == wh else false,
            .workspace_active = if (s.window.findLocOfSurface(s.surface)) |loc|
                s.window.workspaceIndex(loc.ws) == s.window.active_workspace
            else
                false,
            .panel_open = s.window.notif_panel_open,
        };
        if (!shouldToast(ctx)) {
            log.debug("suppressing desktop toast (user is looking at the source)", .{});
            // Keep the taskbar overlay in sync even when the toast is
            // suppressed (the badge reflects the in-app unread count).
            self.refreshTaskbarBadges();
            return;
        }
    }

    // Record which surface notified so a click on the balloon can jump
    // back to it. Slots rotate; if all are in flight the oldest balloon
    // is replaced (NIM_ADD fails silently, NIM_MODIFY updates in place,
    // SetTimer with the same id restarts the old timer).
    const slot = self.desktop_notif_next;
    self.desktop_notif_next = (slot + 1) % NOTIF_DESKTOP_SLOTS;
    self.desktop_notifs[slot] = sender;

    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_DESKTOP_UID_BASE + @as(u32, @intCast(slot));
    // NIF_MESSAGE registers our callback so a click on the balloon is
    // delivered as WM_APP_TRAY → jump to the notifying surface.
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
    nid.uCallbackMessage = WM_APP_TRAY;
    nid.hIcon = w32.LoadIconW(self.hinstance, w32.IDI_GHOSTTY) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 5000; // 5 second timeout

    const ti_len = @min(title_len, nid.szInfoTitle.len - 1);
    @memcpy(nid.szInfoTitle[0..ti_len], title_buf[0..ti_len]);
    nid.szInfoTitle[ti_len] = 0;
    const bo_len = @min(body_len, nid.szInfo.len - 1);
    @memcpy(nid.szInfo[0..bo_len], body_buf[0..bo_len]);
    nid.szInfo[bo_len] = 0;

    // Tooltip
    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;

    // Add the icon, show notification, then remove the icon.
    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);

    // Update the taskbar unread-count overlay to match the new entry.
    self.refreshTaskbarBadges();

    // Schedule icon removal via a timer (distinct from the update
    // notification's timer so the two don't trample each other).
    _ = w32.SetTimer(hwnd, NOTIF_DESKTOP_TIMER_BASE + slot, 6000, null);
}

/// A desktop-notification balloon was clicked: jump to the surface that
/// produced it, then tear down the balloon's icon, timer, and slot.
fn onDesktopNotifClick(self: *App, slot: usize) void {
    const notif = self.desktop_notifs[slot];
    self.clearDesktopNotif(slot);

    const target = notif orelse return;
    _ = self.jumpToSurface(target.window, target.surface);
}

/// Validate a captured (window, surface) pair by address against the
/// live window/tab lists, then raise the window, select the surface's
/// tab, and focus it. Returns false when either has closed since the
/// pointers were recorded. Shared by desktop-notification balloon
/// clicks and sidebar notification panel entries.
pub fn jumpToSurface(self: *App, window: *Window, surface: *Surface) bool {
    // Re-find both by address before dereferencing (mirrors
    // .present_terminal): the pointers may dangle.
    const win = for (self.windows.items) |w| {
        if (w == window) break w;
    } else return false;
    if (win.closing) return false;
    const loc = win.findLocOfSurface(surface) orelse return false;

    const win_hwnd = win.hwnd orelse return false;
    // Only un-minimize: SW_RESTORE on a *maximized* window un-maximizes it
    // to the restored rect, so a notification-jump click would shrink/resize
    // a maximized window. Gate on IsIconic so a maximized or normal window
    // keeps its size/maximized state untouched.
    if (w32.IsIconic(win_hwnd) != 0) _ = w32.ShowWindow(win_hwnd, w32.SW_RESTORE);
    // The click may land outside the target window (shell tray, another
    // window's sidebar), where Windows treats us as a background
    // process; a plain SetForegroundWindow would only flash the
    // taskbar button.
    forceForegroundWindow(win_hwnd);
    // Select the workspace containing the surface first (re-lays out for
    // its tab count), then the tab within it. Order matters.
    win.selectWorkspace(win.workspaceIndex(loc.ws));
    if (loc.tab != loc.ws.active_tab) win.selectTabIndex(loc.tab);
    if (surface.hwnd) |sh| _ = w32.SetFocus(sh);
    return true;
}

// ---------------------------------------------------------------------------
// Agent IPC (`ghostty +browser ...`)
// ---------------------------------------------------------------------------

/// Start the named-pipe IPC server on pipe ghostty-ipc-<pid>. The pipe
/// thread parses requests and posts each to msg_hwnd; this UI thread
/// drives the browser/workspace/tab/send commands in msgWndProc. Failure
/// (e.g. a stale pipe) leaves ipc_server null — the CLI is then
/// unavailable but the app runs.
fn startIpcServer(self: *App) void {
    // `socket-control = off` disables the agent-control IPC entirely; the
    // CLI verbs then report no running instance. `on`/`read-only` both
    // start the server (read-only is enforced per-verb in
    // handleIpcRequest, not by withholding the pipe).
    if (self.config.@"socket-control" == .off) {
        log.info("socket-control=off: agent IPC server not started", .{});
        return;
    }
    const alloc = self.core_app.alloc;
    var name_buf: [64]u8 = undefined;
    const name = ipc.defaultPipeName(&name_buf) catch return;
    self.ipc_server = ipc.Server.start(alloc, name, ipcCallback, self) catch |err| {
        log.warn("failed to start browser IPC server: {}", .{err});
        return;
    };
}

/// Pipe-thread callback: hand the parsed request to the UI thread. On a
/// PostMessageW failure (msg_hwnd gone, queue full) the request would
/// otherwise leak, so destroy it here. ctx is the *App.
///
/// `workspace-new --worktree` is the one verb that does real work HERE,
/// on the pipe thread, before the UI ever sees it: it shells out to `git
/// worktree add`, which touches the filesystem (and can block on a large
/// repo). Running it on the message loop would freeze the UI, so we do it
/// off-loop, stash the resolved path on the request, and only then
/// PostMessage. A git failure is answered straight from here (the
/// server's senders are thread-safe) and the request is dropped without
/// reaching the UI, so no empty workspace is ever created.
fn ipcCallback(ctx: ?*anyopaque, req: *ipc.Request) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));

    if (req.cmd == .@"workspace-new") {
        if (ipc.argString(req, "worktree")) |branch| {
            if (!self.ipcPrepareWorktree(req, branch)) {
                // ipcPrepareWorktree already answered the client with the
                // git error (or a validation error); drop the request.
                req.destroy();
                return;
            }
        }
    }

    const hwnd = self.msg_hwnd orelse {
        req.destroy();
        return;
    };
    if (w32.PostMessageW(hwnd, WM_APP_IPC_REQUEST, 0, @bitCast(@intFromPtr(req))) == 0) {
        req.destroy();
    }
}

/// Pipe-thread helper for `workspace-new --worktree <branch> [--repo P]`.
/// Validates the branch, resolves the repo (the request's "repo" arg, or
/// the client's "cwd" arg — the app's own cwd is meaningless to the
/// agent), runs `git -C <repo> worktree add <repo>/.worktrees/<branch>
/// [-b <branch>]`, and on success stashes the resolved worktree path on
/// `req.worktree_path` for the UI handler. Returns true to proceed to the
/// UI, false after having sent the client an error (no workspace is
/// created). Runs entirely on the pipe thread.
fn ipcPrepareWorktree(self: *App, req: *ipc.Request, branch: []const u8) bool {
    const server = self.ipc_server orelse return false;
    const alloc = self.core_app.alloc;

    const validated = ipc.validateBranch(branch) catch |err| {
        server.sendError(req.id, @errorName(err)) catch {};
        return false;
    };

    // Resolve the repo root: explicit --repo wins, else the client's cwd
    // (sent in the request because the app's cwd is its own, not the
    // agent's). Without either we cannot locate a repository.
    const repo = ipc.argString(req, "repo") orelse
        ipc.argString(req, "cwd") orelse {
        server.sendError(req.id, "no repository: pass --repo or run from inside a git repo") catch {};
        return false;
    };

    const path = ipc.worktreePath(alloc, repo, validated) catch {
        server.sendError(req.id, "out of memory") catch {};
        return false;
    };
    // From here `path` is owned locally; on every early return free it,
    // and on success transfer ownership to req.worktree_path.
    var path_owned = true;
    defer if (path_owned) alloc.free(path);

    self.runGitWorktreeAdd(req.id, repo, path, validated) catch |err| switch (err) {
        // The git child ran and reported a usable stderr message;
        // runGitWorktreeAdd already answered the client.
        error.GitFailed => return false,
        // Couldn't even launch git, or some local failure.
        else => {
            server.sendError(req.id, @errorName(err)) catch {};
            return false;
        },
    };

    req.worktree_path = path;
    path_owned = false; // ownership moved to the request
    return true;
}

/// Run `git -C <repo> worktree add <path> -b <branch>`, falling back to
/// no `-b` (attach an existing branch) when git reports the branch
/// already exists. On a git error other than that, answer client request
/// `id` with git's own stderr (trimmed) and return error.GitFailed.
/// Returns normally only when a worktree now exists at `path`. Pipe-thread
/// only.
fn runGitWorktreeAdd(
    self: *App,
    id: u64,
    repo: []const u8,
    path: []const u8,
    branch: []const u8,
) !void {
    const server = self.ipc_server orelse return error.GitFailed;
    const alloc = self.core_app.alloc;

    // First attempt: create a new branch (-b). The common case.
    const first = try self.runGit(
        alloc,
        &.{ "git", "-C", repo, "worktree", "add", path, "-b", branch },
    );
    defer {
        alloc.free(first.stdout);
        alloc.free(first.stderr);
    }
    if (first.ok) return;

    // If the branch already exists, git refuses -b; retry attaching the
    // existing branch (no -b). git phrases this as "a branch named '...'
    // already exists" (newer) or "...already exists" (older).
    if (std.mem.indexOf(u8, first.stderr, "already exists") != null) {
        const second = try self.runGit(
            alloc,
            &.{ "git", "-C", repo, "worktree", "add", path, branch },
        );
        defer {
            alloc.free(second.stdout);
            alloc.free(second.stderr);
        }
        if (second.ok) return;
        server.sendError(id, gitMessage(second.stderr)) catch {};
        return error.GitFailed;
    }

    server.sendError(id, gitMessage(first.stderr)) catch {};
    return error.GitFailed;
}

/// One git child invocation. Captures stdout+stderr, returns whether it
/// exited 0 along with the owned output buffers (caller frees both).
const GitResult = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,
};

fn runGit(self: *App, alloc: Allocator, argv: []const []const u8) !GitResult {
    _ = self;
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(alloc);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(alloc);

    try child.spawn();
    // collectOutput reads both pipes to EOF (8 MiB cap is far beyond any
    // git worktree message) before wait, so a chatty child can't deadlock.
    try child.collectOutput(alloc, &stdout, &stderr, 8 * 1024 * 1024);
    const term = try child.wait();

    const ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    return .{
        .ok = ok,
        .stdout = try stdout.toOwnedSlice(alloc),
        .stderr = try stderr.toOwnedSlice(alloc),
    };
}

/// Distill git's stderr into a single-line client error message. git
/// often prints a progress line ("Preparing worktree ...") before the
/// actual failure, so prefer the first line tagged "fatal:" or "error:"
/// (the useful reason); fall back to the first non-empty line, then a
/// generic message when stderr is empty. Trimmed and capped.
fn gitMessage(stderr: []const u8) []const u8 {
    var first_nonempty: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0) continue;
        if (first_nonempty == null) first_nonempty = line;
        if (std.mem.startsWith(u8, line, "fatal:") or
            std.mem.startsWith(u8, line, "error:"))
        {
            return line[0..@min(line.len, 512)];
        }
    }
    if (first_nonempty) |line| return line[0..@min(line.len, 512)];
    return "git worktree add failed";
}

// ---------------------------------------------------------------------------
// Sidebar workspace metadata (Stage 2): off-thread git branch / ports / PR.
//
// refreshWorkspaceMetadata runs on the UI thread (WS_META_TIMER_ID). It
// snapshots each visible workspace into a self-contained ws_meta.Job (an
// owned working_dir copy + the tabs' child PIDs read lock-free), stamps the
// workspace with a fresh token, and spawns ONE detached worker thread for
// the batch. The worker runs git/gh/the TCP table (never touching live
// Window/App state) and PostMessageW's a *ws_meta.Result per workspace back
// to msg_hwnd, where applyWorkspaceMetadata revalidates + stores it.
// ---------------------------------------------------------------------------

/// UI-thread timer tick: build refresh jobs for the active workspace of
/// every live, non-quick window and dispatch them to a worker thread. Only
/// the visible workspace per window is refreshed each tick (background
/// workspaces refresh lazily when they become active — see selectWorkspace).
fn refreshWorkspaceMetadata(self: *App) void {
    if (!self.config.@"sidebar-metadata") return;
    self.ws_meta_tick +%= 1;
    const want_pr = (self.ws_meta_tick % WS_META_PR_EVERY) == 0;

    var jobs: std.ArrayList(ws_meta.Job) = .empty;
    defer jobs.deinit(self.core_app.alloc);

    for (self.windows.items) |w| {
        if (w.closing or w.is_quick_terminal) continue;
        if (w.workspace_count == 0) continue;
        const ws_idx = w.active_workspace;
        if (ws_idx >= w.workspace_count) continue;
        if (self.buildMetaJob(w, ws_idx, want_pr)) |job| {
            jobs.append(self.core_app.alloc, job) catch |err| {
                log.warn("ws-meta: failed to queue job: {}", .{err});
                var j = job;
                j.deinit(self.core_app.alloc);
            };
        }
    }

    if (jobs.items.len == 0) return;
    self.dispatchMetaJobs(jobs.toOwnedSlice(self.core_app.alloc) catch return);
}

/// Refresh one workspace's metadata immediately (on focus / worktree bind),
/// outside the periodic tick. Best-effort: a dispatch failure is silent.
pub fn refreshWorkspaceMetadataNow(self: *App, w: *Window, ws_idx: usize) void {
    if (!self.config.@"sidebar-metadata") return;
    if (w.closing or w.is_quick_terminal) return;
    if (ws_idx >= w.workspace_count) return;
    const job = self.buildMetaJob(w, ws_idx, false) orelse return;
    const jobs = self.core_app.alloc.alloc(ws_meta.Job, 1) catch {
        var j = job;
        j.deinit(self.core_app.alloc);
        return;
    };
    jobs[0] = job;
    self.dispatchMetaJobs(jobs);
}

/// Build a self-contained refresh job for workspace `ws_idx` of `w`, or
/// null when there is nothing to scan (no working_dir AND no child PIDs).
/// Stamps the workspace with a fresh token. Runs on the UI thread; all
/// reads (working_dir, child PIDs) are lock-free/stable.
fn buildMetaJob(self: *App, w: *Window, ws_idx: usize, want_pr: bool) ?ws_meta.Job {
    const alloc = self.core_app.alloc;
    const ws = &w.workspaces[ws_idx];

    // Collect the per-tab ConPTY child PIDs (terminals only).
    var pids: std.ArrayList(u32) = .empty;
    errdefer pids.deinit(alloc);
    for (0..ws.tab_count) |t| {
        var it = ws.tab_trees[t].iterator();
        while (it.next()) |entry| {
            const surface = switch (entry.view.content) {
                .terminal => |s| s,
                .browser => continue,
            };
            if (surface.childPid()) |pid| pids.append(alloc, pid) catch {};
        }
    }

    const has_dir = ws.working_dir != null;
    if (!has_dir and pids.items.len == 0) {
        pids.deinit(alloc);
        return null;
    }

    const dir_copy: ?[]u8 = if (ws.working_dir) |d| (alloc.dupe(u8, d) catch null) else null;
    const pid_slice = pids.toOwnedSlice(alloc) catch {
        pids.deinit(alloc);
        if (dir_copy) |d| alloc.free(d);
        return null;
    };

    self.ws_meta_token +%= 1;
    if (self.ws_meta_token == 0) self.ws_meta_token = 1; // 0 reserved
    ws.meta_token = self.ws_meta_token;

    return .{
        .window = @ptrCast(w),
        .ws_idx = ws_idx,
        .token = self.ws_meta_token,
        .working_dir = dir_copy,
        .root_pids = pid_slice,
        .want_pr = want_pr and has_dir,
    };
}

/// Spawn the detached worker thread that processes `jobs` (ownership
/// transferred). On a spawn failure the jobs are freed here so nothing
/// leaks (the UI simply keeps the previous metadata).
fn dispatchMetaJobs(self: *App, jobs: []ws_meta.Job) void {
    const ctx = self.core_app.alloc.create(MetaWorkerCtx) catch {
        freeMetaJobs(self.core_app.alloc, jobs);
        return;
    };
    ctx.* = .{ .app = self, .jobs = jobs };
    const thread = std.Thread.spawn(.{}, metaWorkerMain, .{ctx}) catch {
        self.core_app.alloc.destroy(ctx);
        freeMetaJobs(self.core_app.alloc, jobs);
        return;
    };
    thread.detach();
}

const MetaWorkerCtx = struct {
    app: *App,
    jobs: []ws_meta.Job,
};

fn freeMetaJobs(alloc: Allocator, jobs: []ws_meta.Job) void {
    for (jobs) |*j| j.deinit(alloc);
    alloc.free(jobs);
}

/// Worker-thread entry: run every job and post each result back to the UI
/// thread. Touches only `ctx` (its own owned jobs) and the allocator —
/// NEVER live Window/App state. msg_hwnd is read once; it is stable for the
/// app's lifetime. On a PostMessageW failure the result is freed here.
fn metaWorkerMain(ctx: *MetaWorkerCtx) void {
    const self = ctx.app;
    const alloc = self.core_app.alloc;
    defer {
        freeMetaJobs(alloc, ctx.jobs);
        alloc.destroy(ctx);
    }

    const hwnd = self.msg_hwnd orelse return;
    for (ctx.jobs) |*job| {
        const result = ws_meta.run(alloc, job) catch continue;
        if (w32.PostMessageW(hwnd, WM_APP_WS_META, 0, @bitCast(@intFromPtr(result))) == 0) {
            alloc.destroy(result);
        }
    }
}

/// UI-thread: apply a worker result to its workspace after revalidating the
/// window still lives and the workspace still bears the job's token (so a
/// result for a since-recycled slot is dropped). Frees the result.
fn applyWorkspaceMetadata(self: *App, result: *ws_meta.Result) void {
    defer self.core_app.alloc.destroy(result);

    const target: *Window = @ptrCast(@alignCast(result.window));
    // Validate the window pointer is still live (not freed since dispatch).
    var alive = false;
    for (self.windows.items) |w| {
        if (w == target) {
            alive = true;
            break;
        }
    }
    if (!alive or target.closing) return;
    if (result.ws_idx >= target.workspace_count) return;

    const ws = &target.workspaces[result.ws_idx];
    // Token mismatch ⇒ the slot was recycled (closeWorkspace shift) since
    // dispatch; drop rather than mis-apply.
    if (ws.meta_token != result.token) return;

    ws.setGitBranch(result.branch[0..result.branch_len]);
    ws.setPorts(result.ports[0..result.port_count]);
    // The gh probe runs on a slow cadence; only overwrite the PR cache on a
    // tick that actually probed, so fast (git/port) ticks don't blank it.
    if (result.pr_probed) ws.setPrStatus(result.pr_state, result.pr_number);

    target.invalidateSidebar();
}

/// Handle one IPC request on the UI thread (from WM_APP_IPC_REQUEST).
/// Drives the browser and answers via the server, then destroys the
/// request. `eval` answers asynchronously (the ExecuteScript completion
/// replies), so it must NOT also answer here.
fn handleIpcRequest(self: *App, req: *ipc.Request) void {
    defer req.destroy();
    const server = self.ipc_server orelse return;

    // read-only mode: refuse any verb that would change state, spawn a
    // process, or inject input. The server still answers (with an error)
    // so the client gets a clear signal rather than a hang.
    if (self.config.@"socket-control" == .@"read-only" and
        !commandIsReadOnly(req.cmd))
    {
        server.sendError(req.id, "socket-control=read-only: command refused") catch {};
        return;
    }

    switch (req.cmd) {
        .open => self.ipcOpen(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .navigate => self.ipcNavigate(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .eval => self.ipcEval(req) catch |err| {
            // ipcEval only returns before dispatching the async script;
            // once dispatched the completion owns the reply.
            server.sendError(req.id, @errorName(err)) catch {};
        },
        // snapshot/click/fill all answer asynchronously via the CDP
        // completion chain (BrowserPane); these handlers only reply here
        // on a synchronous setup error.
        .snapshot => self.ipcSnapshot(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .click => self.ipcClick(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .fill => self.ipcFill(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        // Workspace / tab / keystroke scripting. These all complete
        // synchronously on this UI thread and send their own ok reply;
        // a returned error is named to the client here.
        .@"workspace-list" => self.ipcWorkspaceList(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"workspace-new" => self.ipcWorkspaceNew(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"workspace-select" => self.ipcWorkspaceSelect(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"workspace-close" => self.ipcWorkspaceClose(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"tab-list" => self.ipcTabList(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"tab-new" => self.ipcTabNew(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"tab-select" => self.ipcTabSelect(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"tab-close" => self.ipcTabClose(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .send => self.ipcSend(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .notify => self.ipcNotify(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },

        // Orchestration scripting. read-only mode refuses the mutating
        // ones up front (see commandIsReadOnly); the read verbs always run.
        .@"surface-list" => self.ipcSurfaceList(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"surface-focus" => self.ipcSurfaceFocus(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"new-split" => self.ipcNewSplit(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"set-status" => self.ipcSetStatus(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"set-progress" => self.ipcSetProgress(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .log => self.ipcLog(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"read-screen" => self.ipcReadScreen(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"capture-pane" => self.ipcCapturePaneCmd(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"session-capture" => self.ipcSessionCapture(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"session-resume" => self.ipcSessionResume(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"session-list" => self.ipcSessionList(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"swap-split" => {
            if (self.ipcTargetWindow()) |win| {
                win.swapSplit(.previous);
            }
            server.sendOk(req.id, null) catch {};
        },
        .@"select-layout" => self.ipcSelectLayout(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"sync-input" => self.ipcSyncInput(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"break-pane" => self.ipcBreakPane(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"move-pane" => self.ipcMovePaneToTab(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"session-save" => {
            const alloc = self.core_app.alloc;
            if (self.windows.items.len > 0) {
                SessionState.save(alloc, self.windows.items[0]) catch |err| {
                    server.sendError(req.id, @errorName(err)) catch {};
                    return;
                };
            }
            server.sendOk(req.id, null) catch {};
        },
        .@"session-restore" => {
            const alloc = self.core_app.alloc;
            SessionState.restore(alloc, self) catch |err| {
                server.sendError(req.id, @errorName(err)) catch {};
                return;
            };
            server.sendOk(req.id, null) catch {};
        },
        .@"flash-pane" => {
            // Flash the focused pane of the target window.
            if (self.ipcTargetWindow()) |win| {
                win.flashFocusedPane();
            }
            server.sendOk(req.id, null) catch {};
        },
        .@"workspace-set-description" => self.ipcWorkspaceSetDescription(req) catch |err| {
            server.sendError(req.id, @errorName(err)) catch {};
        },
        .@"toggle-right-sidebar" => {
            // Toggle the right sidebar on the first window (or the window
            // owning the active surface). A simple toggle: no args needed.
            if (self.windows.items.len > 0) {
                self.windows.items[0].toggleRightSidebar();
            }
            server.sendOk(req.id, null) catch {};
        },
    }
}

/// Whether a command only reads state (never mutates the model, spawns a
/// process, or sends input). Under `socket-control = read-only` only these
/// are honored; everything else is refused before dispatch. The browser
/// CDP verbs (snapshot/eval) read a page but eval can run arbitrary JS, so
/// only snapshot is treated as read-only; navigate/click/fill/open mutate.
fn commandIsReadOnly(cmd: ipc.Command) bool {
    return switch (cmd) {
        .@"workspace-list",
        .@"tab-list",
        .snapshot,
        .@"surface-list",
        .@"read-screen",
        .@"capture-pane",
        .@"session-list",
        => true,
        else => false,
    };
}

/// Request-level failures surfaced to the client as the error response
/// message (via @errorName). Window/pane operations can also fail with
/// allocation/Win32/SplitTree errors, so the ipc* handlers return
/// anyerror and the dispatcher names whatever propagates.
const IpcError = error{
    NoWindow,
    MissingUrl,
    MissingScript,
    MissingRef,
    MissingText,
    UnknownId,
    UrlTooLong,
    MissingIndex,
    UnknownWorkspace,
    UnknownTab,
    NotATerminal,
    QuickTerminal,
    MissingAction,
    BadAction,
    // Orchestration verbs.
    UnknownPane,
    UnknownSurface,
    MissingDirection,
    BadDirection,
    MissingAgent,
    MissingSession,
    NoSession,
    NoResumeRecipe,
    BadProgress,
    CoreNotReady,
};

/// Resolve the IPC target window: the foreground Ghostty window if one
/// is, else the first live window. Null only when no windows exist.
fn ipcTargetWindow(self: *App) ?*Window {
    const fg = w32.GetForegroundWindow();
    for (self.windows.items) |w| {
        if (!w.closing and w.hwnd == fg) return w;
    }
    for (self.windows.items) |w| {
        if (!w.closing) return w;
    }
    return null;
}

/// Find a browser pane by its IPC id across all live windows, or the
/// most-recently-created browser pane (highest id) when `id` is null.
fn ipcFindBrowser(self: *App, id: ?u32) ?*BrowserPane {
    var best: ?*BrowserPane = null;
    for (self.windows.items) |w| {
        if (w.closing) continue;
        for (w.workspaces[0..w.workspace_count]) |*ws| {
            for (0..ws.tab_count) |t| {
                var it = ws.tab_trees[t].iterator();
                while (it.next()) |entry| {
                    const browser = switch (entry.view.content) {
                        .browser => |b| b,
                        .terminal => continue,
                    };
                    if (id) |want| {
                        if (browser.ipc_id == want) return browser;
                    } else if (best == null or browser.ipc_id > best.?.ipc_id) {
                        best = browser;
                    }
                }
            }
        }
    }
    return best;
}

/// Read an optional u32 "id" field from the request args.
/// (Pure logic lives in ipc.zig so the protocol tests cover it.)
const ipcArgId = ipc.argId;

/// Read a required string field from the request args.
const ipcArgString = ipc.argString;

/// Read an i64 field (the CDP backendNodeId `ref`) from the request args.
const ipcArgI64 = ipc.argI64;

/// open {url, [target: "split"|"tab"]} → create a browser pane in the
/// target window, navigate to url, reply with its assigned id.
fn ipcOpen(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const url = ipcArgString(req, "url") orelse return IpcError.MissingUrl;
    const window = self.ipcTargetWindow() orelse return IpcError.NoWindow;

    const as_tab = if (ipcArgString(req, "target")) |t|
        std.mem.eql(u8, t, "tab")
    else
        false;

    if (as_tab) {
        try window.addBrowserTab();
    } else {
        try window.newBrowserSplit(.right);
    }

    // The just-created pane is the window's active pane.
    const pane = window.getActivePane() orelse return IpcError.NoWindow;
    const browser = switch (pane.content) {
        .browser => |b| b,
        .terminal => return IpcError.NoWindow,
    };

    var url_w: [2049]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(url_w[0 .. url_w.len - 1], url) catch
        return IpcError.UrlTooLong;
    url_w[wlen] = 0;
    browser.navigateUrl(url_w[0..wlen :0]) catch {};

    var data_buf: [32]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "{{\"id\":{d}}}", .{browser.ipc_id}) catch
        return error.NoSpaceLeft;
    server.sendOk(req.id, data) catch {};
}

/// navigate {[id], url} → navigate the addressed (or most-recent)
/// browser pane.
fn ipcNavigate(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const url = ipcArgString(req, "url") orelse return IpcError.MissingUrl;
    const browser = self.ipcFindBrowser(ipcArgId(req)) orelse return IpcError.UnknownId;

    var url_w: [2049]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(url_w[0 .. url_w.len - 1], url) catch
        return IpcError.UrlTooLong;
    url_w[wlen] = 0;
    browser.navigateUrl(url_w[0..wlen :0]) catch {};
    server.sendOk(req.id, null) catch {};
}

/// eval {[id], js} → run js in the addressed (or most-recent) browser
/// pane. The reply is sent asynchronously by the ExecuteScript
/// completion (BrowserPane.evalForIpc), so this returns without sending.
fn ipcEval(self: *App, req: *ipc.Request) anyerror!void {
    const js = ipcArgString(req, "js") orelse return IpcError.MissingScript;
    const browser = self.ipcFindBrowser(ipcArgId(req)) orelse return IpcError.UnknownId;

    const alloc = self.core_app.alloc;
    const js_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, js) catch
        return error.OutOfMemory;
    defer alloc.free(js_w);
    browser.evalForIpc(req.id, js_w);
}

/// snapshot {[id]} → walk the addressed (or most-recent) browser pane's
/// accessibility tree over CDP and reply with a compact [{ref,role,name}]
/// array. Answered asynchronously by the CDP completion chain.
fn ipcSnapshot(self: *App, req: *ipc.Request) anyerror!void {
    const browser = self.ipcFindBrowser(ipcArgId(req)) orelse return IpcError.UnknownId;
    browser.snapshotForIpc(req.id);
}

/// click {[id], ref} → click the element with backendNodeId `ref` in the
/// addressed (or most-recent) browser pane. Answered asynchronously.
fn ipcClick(self: *App, req: *ipc.Request) anyerror!void {
    const ref = ipcArgI64(req, "ref") orelse return IpcError.MissingRef;
    const browser = self.ipcFindBrowser(ipcArgId(req)) orelse return IpcError.UnknownId;
    browser.clickForIpc(req.id, ref);
}

/// fill {[id], ref, text} → focus the element with backendNodeId `ref`
/// and insert `text` in the addressed (or most-recent) browser pane.
/// Answered asynchronously.
fn ipcFill(self: *App, req: *ipc.Request) anyerror!void {
    const ref = ipcArgI64(req, "ref") orelse return IpcError.MissingRef;
    const text = ipcArgString(req, "text") orelse return IpcError.MissingText;
    const browser = self.ipcFindBrowser(ipcArgId(req)) orelse return IpcError.UnknownId;
    browser.fillForIpc(req.id, ref, text);
}

// ---------------------------------------------------------------------------
// Agent IPC: workspace / tab / keystroke scripting
// ---------------------------------------------------------------------------
//
// These mutate the same single-UI-thread model the browser verbs do (they
// run on the GUI thread via WM_APP_IPC_REQUEST) and reply synchronously.
// Workspace/tab indices are window-local: every handler operates on the
// IPC target window (foreground Ghostty window, else the first live one).
// The Window mutators (addTab/selectTabIndex/closeWorkspace/...) all act on
// the *active* workspace, so handlers that target a non-active workspace
// select it first (selectWorkspace is a no-op when already active).

/// Read an optional u32 index field ("index"/"workspace"/"tab").
const ipcArgU32 = ipc.argU32;

/// Read an optional bool field (send's "enter").
const ipcArgBool = ipc.argBool;

/// Resolve the workspace addressed by an optional "workspace" arg in the
/// target window, defaulting to the active workspace when absent. Returns
/// the window, the workspace pointer, and its index. UnknownWorkspace if
/// an explicit index is out of range; NoWindow if no window exists.
const IpcWorkspaceTarget = struct {
    window: *Window,
    ws: *Window.Workspace,
    ws_idx: usize,
};

fn ipcResolveWorkspace(self: *App, req: *ipc.Request) IpcError!IpcWorkspaceTarget {
    const window = self.ipcTargetWindow() orelse return IpcError.NoWindow;
    const ws_idx: usize = if (ipcArgU32(req, "workspace")) |w| w else window.active_workspace;
    if (ws_idx >= window.workspace_count) return IpcError.UnknownWorkspace;
    return .{
        .window = window,
        .ws = &window.workspaces[ws_idx],
        .ws_idx = ws_idx,
    };
}

/// Append a JSON string for a UTF-16 slice (a workspace name or tab
/// title), escaping via std.json so embedded quotes/control chars are
/// safe. Lossy on invalid UTF-16 (each bad unit becomes U+FFFD), which
/// only affects display text, never protocol framing.
fn ipcWriteJsonUtf16(
    self: *App,
    w: *std.ArrayList(u8),
    utf16: []const u16,
) !void {
    const alloc = self.core_app.alloc;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, utf16) catch
        try alloc.dupe(u8, "");
    defer alloc.free(utf8);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.value(utf8, .{}, &aw.writer);
    try w.appendSlice(alloc, aw.written());
}

/// workspace-list → [{index, name, active, tab_count}] for the target
/// window's workspaces.
fn ipcWorkspaceList(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const window = self.ipcTargetWindow() orelse return IpcError.NoWindow;
    const alloc = self.core_app.alloc;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (window.workspaces[0..window.workspace_count], 0..) |*ws, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.writer(alloc).print("{{\"index\":{d},\"name\":", .{i});
        try self.ipcWriteJsonUtf16(&buf, ws.name[0..ws.name_len]);
        try buf.writer(alloc).print(
            ",\"active\":{},\"tab_count\":{d}}}",
            .{ i == window.active_workspace, ws.tab_count },
        );
    }
    try buf.append(alloc, ']');
    server.sendOk(req.id, buf.items) catch {};
}

/// workspace-new {[name], [worktree], [repo], [cwd]} → create a workspace
/// (a sidebar row with one tab), optionally renaming it, and reply with
/// its index.
///
/// When the request carried a `worktree` branch, the pipe thread already
/// ran `git worktree add` and stashed the resolved path on
/// `req.worktree_path` (see ipcCallback/ipcPrepareWorktree). Here we just
/// bind that path to the new workspace so its tabs spawn inside the
/// worktree, and default the workspace name to the branch when no
/// explicit --name was given. A plain workspace-new (no worktree) keeps
/// the current behavior.
fn ipcWorkspaceNew(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const window = self.ipcTargetWindow() orelse return IpcError.NoWindow;
    if (window.is_quick_terminal) return IpcError.QuickTerminal;

    // Parse an optional explicit command (split on whitespace) once; an
    // empty/whitespace-only command falls through to the default shell.
    // Used by `+ssh --workspace` to run `ssh user@host` in the first tab.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.core_app.alloc);
    if (ipcArgString(req, "command")) |command_str| {
        var it = std.mem.tokenizeAny(u8, command_str, &std.ascii.whitespace);
        while (it.next()) |tok| try argv.append(self.core_app.alloc, tok);
    }
    const command: ?[]const []const u8 = if (argv.items.len > 0) argv.items else null;

    // Programmatic creation defaults to NON-FOCUS: the workspace is created
    // in the background and the user stays in whatever workspace (and
    // whatever app) they were in. `--focus` (focus:true over IPC) opts in
    // to switching the in-app active workspace to the new one. Matches
    // cmux #3215: "workspace creation is not a focus-intent operation."
    const focus = ipcArgBool(req, "focus") orelse false;

    const idx: usize = if (focus) blk: {
        // Focus path: create AND select the new workspace (the historical
        // behavior), but never steal OS foreground from another app — the
        // selectWorkspace/SetFocus only affects keyboard focus when this
        // window is already foreground.
        if (req.worktree_path) |path| {
            break :blk window.newWorkspaceWithDir(path) orelse return IpcError.NoWindow;
        }
        if (command) |c| {
            // Command-bearing workspace: create-and-select, add the
            // first tab with the explicit command.
            const ws_idx = window.createAndSelectWorkspace() orelse return IpcError.NoWindow;
            _ = window.addTabWithCommand(c, null) catch |err| {
                log.err("failed to create first tab with command for new workspace: {}", .{err});
                window.closeWorkspace(ws_idx);
                return IpcError.NoWindow;
            };
            break :blk ws_idx;
        }
        const before = window.workspace_count;
        window.newWorkspace();
        // newWorkspace collapses the slot if its first tab fails to spawn,
        // so confirm a workspace was actually added before reporting one.
        if (window.workspace_count <= before) return IpcError.NoWindow;
        break :blk window.workspace_count - 1;
    } else blk: {
        // Background path (default): create without changing the active
        // workspace. newWorkspaceBackground collapses the slot on failure.
        break :blk window.newWorkspaceBackground(req.worktree_path, command) orelse
            return IpcError.NoWindow;
    };

    // Name precedence: explicit --name wins; otherwise a worktree
    // workspace is named after its branch (the agent-friendly default).
    if (ipcArgString(req, "name")) |name| {
        if (name.len > 0) window.setWorkspaceName(idx, name);
    } else if (ipcArgString(req, "worktree")) |branch| {
        if (branch.len > 0) window.setWorkspaceName(idx, branch);
    }

    var data_buf: [32]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "{{\"index\":{d}}}", .{idx}) catch
        return error.NoSpaceLeft;
    server.sendOk(req.id, data) catch {};
}

/// workspace-select {index} → switch the target window to workspace
/// `index`.
fn ipcWorkspaceSelect(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const window = self.ipcTargetWindow() orelse return IpcError.NoWindow;
    const idx = ipcArgU32(req, "index") orelse return IpcError.MissingIndex;
    if (idx >= window.workspace_count) return IpcError.UnknownWorkspace;
    window.selectWorkspace(idx);
    server.sendOk(req.id, null) catch {};
}

/// workspace-close {index} → close workspace `index` in the target
/// window. Closing the last workspace closes the window.
fn ipcWorkspaceClose(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const window = self.ipcTargetWindow() orelse return IpcError.NoWindow;
    const idx = ipcArgU32(req, "index") orelse return IpcError.MissingIndex;
    if (idx >= window.workspace_count) return IpcError.UnknownWorkspace;
    window.closeWorkspace(idx);
    server.sendOk(req.id, null) catch {};
}

/// workspace-set-description {workspace, text} → set (or clear) the
/// user-facing description text for workspace `workspace` in the target
/// window. An empty or absent `text` clears the description.
fn ipcWorkspaceSetDescription(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const window = self.ipcTargetWindow() orelse return IpcError.NoWindow;
    const idx = ipcArgU32(req, "workspace") orelse return IpcError.MissingIndex;
    if (idx >= window.workspace_count) return IpcError.UnknownWorkspace;
    const text = ipc.argString(req, "text") orelse "";
    window.setWorkspaceDescription(idx, text);
    server.sendOk(req.id, null) catch {};
}

/// tab-list {[workspace]} → [{index, title, active}] for the addressed
/// (or active) workspace of the target window.
fn ipcTabList(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveWorkspace(req);
    const ws = target.ws;
    const alloc = self.core_app.alloc;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (0..ws.tab_count) |i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.writer(alloc).print("{{\"index\":{d},\"title\":", .{i});
        try self.ipcWriteJsonUtf16(&buf, ws.tab_titles[i][0..ws.tab_title_lens[i]]);
        try buf.writer(alloc).print(
            ",\"active\":{}}}",
            .{i == ws.active_tab},
        );
    }
    try buf.append(alloc, ']');
    server.sendOk(req.id, buf.items) catch {};
}

/// tab-new {[workspace], [command]} → add a tab to the addressed (or
/// active) workspace and reply with its index. With `command` the tab
/// runs that shell (split on spaces); without it the tab inherits the
/// active pane's backend (matching the "+" new-tab UX). The Window tab
/// mutators act on the active workspace, so a non-active target workspace
/// is selected first.
fn ipcTabNew(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveWorkspace(req);
    const window = target.window;
    const ws_idx = target.ws_idx;
    if (window.is_quick_terminal) return IpcError.QuickTerminal;

    // Programmatic creation defaults to NON-FOCUS: the tab is added to the
    // target workspace in the background; the active workspace/tab does not
    // change. `--focus` (focus:true) switches to the target workspace and
    // selects the new tab. Matches cmux #3215 (applied to all create verbs)
    // and the "create != focus" policy.
    //
    // The returned index is the new tab's index WITHIN THE TARGET
    // WORKSPACE, the same index `+tab list --workspace <ws>` shows and
    // `+tab close --workspace <ws>` accepts (BUG 2: previously this read
    // the window's active-workspace active_tab, which could disagree with
    // the workspace tab-list/close query when they targeted different
    // workspaces).
    const focus = ipcArgBool(req, "focus") orelse false;

    if (focus and ws_idx != window.active_workspace)
        window.selectWorkspace(ws_idx);

    // Parse an optional explicit command (split on whitespace) once; an
    // empty/whitespace-only command falls through to the inherit path.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.core_app.alloc);
    if (ipcArgString(req, "command")) |command_str| {
        var it = std.mem.tokenizeAny(u8, command_str, &std.ascii.whitespace);
        while (it.next()) |tok| try argv.append(self.core_app.alloc, tok);
    }
    const command: ?[]const []const u8 = if (argv.items.len > 0) argv.items else null;

    const idx: usize = if (focus) blk: {
        // After the (optional) selectWorkspace above, ws_idx is the active
        // workspace; the interactive add-tab paths switch to and focus the
        // new tab, and return its index.
        if (command) |c| {
            _ = try window.addTabWithCommand(c, null);
        } else {
            _ = try window.addTabInherit();
        }
        break :blk window.activeWorkspace().active_tab;
    } else if (command) |c|
        try window.addTabBackground(ws_idx, c, null)
    else
        try window.addTabInheritBackground(ws_idx);

    var data_buf: [32]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "{{\"index\":{d}}}", .{idx}) catch
        return error.NoSpaceLeft;
    server.sendOk(req.id, data) catch {};
}

/// tab-select {index, [workspace]} → make tab `index` active in the
/// addressed (or active) workspace. selectTabIndex acts on the active
/// workspace, so a non-active target is selected first.
fn ipcTabSelect(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveWorkspace(req);
    const idx = ipcArgU32(req, "index") orelse return IpcError.MissingIndex;
    if (idx >= target.ws.tab_count) return IpcError.UnknownTab;

    if (target.ws_idx != target.window.active_workspace)
        target.window.selectWorkspace(target.ws_idx);
    target.window.selectTabIndex(idx);
    server.sendOk(req.id, null) catch {};
}

/// tab-close {index, [workspace]} → close tab `index` in the addressed
/// (or active) workspace. closeTabInWorkspace handles non-active
/// workspaces and the last-tab/last-workspace collapse paths.
fn ipcTabClose(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveWorkspace(req);
    const idx = ipcArgU32(req, "index") orelse return IpcError.MissingIndex;
    if (idx >= target.ws.tab_count) return IpcError.UnknownTab;
    target.window.closeTabInWorkspaceForIpc(target.ws_idx, idx);
    server.sendOk(req.id, null) catch {};
}

/// send {text, [workspace], [tab], [enter]} → write `text` to the child
/// PTY of the active pane of the addressed (or active) workspace's
/// addressed (or active) tab, exactly as typed input would, optionally
/// appending a carriage return (`enter`). Browser panes have no PTY and
/// answer NotATerminal.
fn ipcSend(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const text = ipcArgString(req, "text") orelse return IpcError.MissingText;
    const target = try self.ipcResolveWorkspace(req);
    const ws = target.ws;

    const tab_idx: usize = if (ipcArgU32(req, "tab")) |t| t else ws.active_tab;
    if (tab_idx >= ws.tab_count) return IpcError.UnknownTab;

    const pane = ws.tab_active_pane[tab_idx];
    const surface = pane.surface() orelse return IpcError.NotATerminal;

    const enter = ipcArgBool(req, "enter") orelse false;
    try surface.ipcSendText(text, enter);
    server.sendOk(req.id, null) catch {};
}

/// notify {action: "ring"|"clear"|"next", [workspace], [tab]} →
///   * "ring"/"clear": set or clear the notification-ring attention flag on
///     the active pane of the addressed (or active) workspace's addressed
///     (or active) tab. The explicit, reliable counterpart to the attention
///     OSC: an agent that can't emit an escape (or a wrapper script) rings
///     the pane it runs in via `ghostty +notify ring`. Browser panes have
///     no terminal surface and answer NotATerminal. Targeting the currently
///     visible+focused pane is accepted but the ring overlay won't draw on
///     it (you'd be ringed around what you're looking at); the cross-level
///     sidebar/tab dots still update.
///   * "next": jump to the most-recent UNREAD notification's surface
///     (cross-workspace, via jumpToSurface), mark that one Read, and reply
///     {jumped:true, surface:<id>}. With no unread entries, replies
///     {jumped:false}. Ignores workspace/tab (the target is the notifying
///     pane, wherever it lives).
fn ipcNotify(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const action = ipcArgString(req, "action") orelse return IpcError.MissingAction;

    if (std.mem.eql(u8, action, "next")) {
        try self.ipcNotifyNext(req);
        return;
    }

    if (std.mem.eql(u8, action, "toggle-read")) {
        try self.ipcNotifyToggleRead(req);
        return;
    }

    if (std.mem.eql(u8, action, "mark-oldest-next")) {
        try self.ipcNotifyMarkOldestNext(req);
        return;
    }

    const on = if (std.mem.eql(u8, action, "ring"))
        true
    else if (std.mem.eql(u8, action, "clear"))
        false
    else
        return IpcError.BadAction;

    const target = try self.ipcResolveWorkspace(req);
    const ws = target.ws;
    const tab_idx: usize = if (ipcArgU32(req, "tab")) |t| t else ws.active_tab;
    if (tab_idx >= ws.tab_count) return IpcError.UnknownTab;

    const pane = ws.tab_active_pane[tab_idx];
    const surface = pane.surface() orelse return IpcError.NotATerminal;
    target.window.setAttentionForSurface(surface, on);
    server.sendOk(req.id, null) catch {};
}

/// `+notify next`: jump to the most-recent unread notification's surface.
/// Resolves the freshest Unread entry, validates its (window, surface) by
/// address via jumpToSurface (the entry pointers may dangle), marks it Read
/// (Unread→Read lifecycle, which also lowers the taskbar badge), and replies
/// {jumped, surface}. The display index is recomputed against
/// firstUnreadNotif so markNotifEntryRead targets the same entry we jumped to.
fn ipcNotifyNext(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;

    const display_idx = self.firstUnreadNotif() orelse {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    };
    const entry = self.notifAt(display_idx) orelse {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    };
    const window = entry.window;
    const surface = entry.surface;

    // The entry's (window, surface) pointers may dangle: dropDesktopNotifsForWindow
    // scrubs entries only when their whole *window* is destroyed, NOT when an
    // individual pane/tab closes inside a surviving window. So validate the
    // surface by address BEFORE dereferencing it (mirrors jumpToSurface's own
    // re-find). A stale entry is a clean no-op, never a use-after-free.
    const live = blk: {
        for (self.windows.items) |w| {
            if (w == window) {
                if (w.closing) break :blk false;
                break :blk w.findLocOfSurface(surface) != null;
            }
        }
        break :blk false;
    };
    if (!live) {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    }

    // Now safe to read: snapshot the surface id before jumping (jumpToSurface
    // may re-layout the pane tree, but the Surface object itself is stable).
    const surface_id: u64 = if (surface.core_surface_initialized)
        surface.core_surface.id
    else
        0;

    const jumped = self.jumpToSurface(window, surface);
    if (jumped) _ = self.markNotifEntryRead(display_idx);

    var buf: [64]u8 = undefined;
    const reply = std.fmt.bufPrint(
        &buf,
        "{{\"jumped\":{s},\"surface\":{d}}}",
        .{ if (jumped) "true" else "false", surface_id },
    ) catch "{\"jumped\":false}";
    server.sendOk(req.id, reply) catch {};
}

/// `+notify toggle-read`: toggle the most recent notification's read state.
/// Replies {toggled:true, read:<new_state>} or {toggled:false}.
fn ipcNotifyToggleRead(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const toggled = self.toggleNotifRead(0);
    if (toggled) {
        const entry = self.notifAt(0);
        const is_read = if (entry) |e| e.read else true;
        var buf: [48]u8 = undefined;
        const reply = std.fmt.bufPrint(
            &buf,
            "{{\"toggled\":true,\"read\":{s}}}",
            .{if (is_read) "true" else "false"},
        ) catch "{\"toggled\":false}";
        server.sendOk(req.id, reply) catch {};
    } else {
        server.sendOk(req.id, "{\"toggled\":false}") catch {};
    }
}

/// `+notify mark-oldest-next`: mark the oldest unread notification as read
/// and jump to the next unread entry's source pane. Replies
/// {jumped:true, surface:<id>} or {jumped:false}.
fn ipcNotifyMarkOldestNext(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;

    // Find the oldest unread entry and mark it read.
    const oldest_idx = self.notif_log.lastUnread() orelse {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    };
    _ = self.markNotifEntryRead(oldest_idx);

    // Now find the next unread (newest first, like ipcNotifyNext).
    const next_idx = self.firstUnreadNotif() orelse {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    };
    const entry = self.notifAt(next_idx) orelse {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    };
    const window = entry.window;
    const surface = entry.surface;

    // Validate liveness (mirrors ipcNotifyNext).
    const live = blk: {
        for (self.windows.items) |w| {
            if (w == window) {
                if (w.closing) break :blk false;
                break :blk w.findLocOfSurface(surface) != null;
            }
        }
        break :blk false;
    };
    if (!live) {
        server.sendOk(req.id, "{\"jumped\":false}") catch {};
        return;
    }

    const surface_id: u64 = if (surface.core_surface_initialized)
        surface.core_surface.id
    else
        0;

    const jumped = self.jumpToSurface(window, surface);
    if (jumped) _ = self.markNotifEntryRead(next_idx);

    var buf: [64]u8 = undefined;
    const reply = std.fmt.bufPrint(
        &buf,
        "{{\"jumped\":{s},\"surface\":{d}}}",
        .{ if (jumped) "true" else "false", surface_id },
    ) catch "{\"jumped\":false}";
    server.sendOk(req.id, reply) catch {};
}

// ---------------------------------------------------------------------------
// Agent IPC: orchestration scripting (surface/split/status/log/read-screen/
// session). The agent-supervises-agent substrate. All run on the GUI thread
// and reply synchronously (they touch the live model / core terminal).
// ---------------------------------------------------------------------------

/// Read the optional u64 "surface" arg: a stable surface id
/// (GHOSTTY_SURFACE_ID). Pure logic in ipc.zig so the protocol tests cover it.
const ipcArgU64 = ipc.argU64;

/// A resolved (workspace, tab) target within the IPC target window. tab
/// defaults to the workspace's active tab when "tab" is absent, and is
/// range-validated. Workspace resolution reuses ipcResolveWorkspace.
const IpcTabTarget = struct {
    window: *Window,
    ws: *Window.Workspace,
    ws_idx: usize,
    tab_idx: usize,
};

fn ipcResolveTab(self: *App, req: *ipc.Request) IpcError!IpcTabTarget {
    const t = try self.ipcResolveWorkspace(req);
    const tab_idx: usize = if (ipcArgU32(req, "tab")) |tab| tab else t.ws.active_tab;
    if (tab_idx >= t.ws.tab_count) return IpcError.UnknownTab;
    return .{ .window = t.window, .ws = t.ws, .ws_idx = t.ws_idx, .tab_idx = tab_idx };
}

/// A pane located across every live window, with the coordinates that
/// address it. Returned by ipcFindSurfaceById.
const SurfaceLoc = struct {
    window: *Window,
    ws_idx: usize,
    tab_idx: usize,
    surface: *Surface,
};

/// Find a terminal surface by its stable core id (GHOSTTY_SURFACE_ID)
/// across all live windows. Only surfaces whose core is initialized have
/// a valid id; the id is read WITHOUT touching unready cores. Returns the
/// owning window + workspace/tab indices so callers can focus or address it.
fn ipcFindSurfaceById(self: *App, want: u64) ?SurfaceLoc {
    for (self.windows.items) |w| {
        if (w.closing) continue;
        for (w.workspaces[0..w.workspace_count], 0..) |*ws, wi| {
            for (0..ws.tab_count) |t| {
                var it = ws.tab_trees[t].iterator();
                while (it.next()) |entry| {
                    const surface = switch (entry.view.content) {
                        .terminal => |s| s,
                        .browser => continue,
                    };
                    if (!surface.core_surface_initialized) continue;
                    if (surface.core_surface.id == want) {
                        return .{ .window = w, .ws_idx = wi, .tab_idx = t, .surface = surface };
                    }
                }
            }
        }
    }
    return null;
}

/// The stable surface id of a terminal pane, or null if it is a browser
/// or its core is not yet initialized (no id assigned).
fn ipcSurfaceId(pane: *Pane) ?u64 {
    const surface = pane.surface() orelse return null;
    if (!surface.core_surface_initialized) return null;
    return surface.core_surface.id;
}

/// surface-list {[workspace],[tab]} → [{id, kind, focused, title}] for
/// every pane in the addressed (or active) tab. `id` is the stable surface
/// id for terminals (GHOSTTY_SURFACE_ID) and the ipc_id for browsers
/// (disjoint spaces, but kind disambiguates); a terminal whose core isn't
/// ready yet reports id 0. `focused` marks the tab's active pane.
fn ipcSurfaceList(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveTab(req);
    const ws = target.ws;
    const alloc = self.core_app.alloc;
    const active = ws.tab_active_pane[target.tab_idx];

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    var first = true;
    var it = ws.tab_trees[target.tab_idx].iterator();
    while (it.next()) |entry| {
        const pane = entry.view;
        if (!first) try buf.append(alloc, ',');
        first = false;
        switch (pane.content) {
            .terminal => |surface| {
                const sid: u64 = if (surface.core_surface_initialized) surface.core_surface.id else 0;
                try buf.writer(alloc).print(
                    "{{\"id\":{d},\"kind\":\"terminal\",\"focused\":{},\"title\":",
                    .{ sid, pane == active },
                );
                // The window-level title buffer reflects the active pane;
                // per-pane terminals don't carry an independent title here,
                // so report the tab title (best-effort display text).
                try self.ipcWriteJsonUtf16(&buf, ws.tab_titles[target.tab_idx][0..ws.tab_title_lens[target.tab_idx]]);
                try buf.append(alloc, '}');
            },
            .browser => |browser| {
                try buf.writer(alloc).print(
                    "{{\"id\":{d},\"kind\":\"browser\",\"focused\":{},\"title\":",
                    .{ browser.ipc_id, pane == active },
                );
                try self.ipcWriteJsonUtf16(&buf, ws.tab_titles[target.tab_idx][0..ws.tab_title_lens[target.tab_idx]]);
                try buf.append(alloc, '}');
            },
        }
    }
    try buf.append(alloc, ']');
    server.sendOk(req.id, buf.items) catch {};
}

/// surface-focus {surface} | {workspace, tab, pane} → focus a pane. With a
/// `surface` id the owning window/workspace/tab is selected and the pane
/// focused; otherwise the pane is addressed by (workspace, tab, pane-index
/// within the tab tree, in iteration order).
fn ipcSurfaceFocus(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;

    if (ipcArgU64(req, "surface")) |sid| {
        const loc = self.ipcFindSurfaceById(sid) orelse return IpcError.UnknownSurface;
        loc.window.selectWorkspace(loc.ws_idx);
        loc.window.selectTabIndex(loc.tab_idx);
        // Focus the specific pane within the tab.
        if (loc.ws_idx < loc.window.workspace_count) {
            const ws = &loc.window.workspaces[loc.ws_idx];
            if (ws.findHandle(loc.tab_idx, loc.surface.pane orelse return IpcError.UnknownSurface)) |_| {
                ws.tab_active_pane[loc.tab_idx] = loc.surface.pane.?;
            }
        }
        loc.surface.pane.?.focus();
        server.sendOk(req.id, null) catch {};
        return;
    }

    // Address by (workspace, tab, pane index in tree iteration order).
    const target = try self.ipcResolveTab(req);
    const pane_idx = ipcArgU32(req, "pane") orelse return IpcError.MissingIndex;
    var i: usize = 0;
    var found: ?*Pane = null;
    var it = target.ws.tab_trees[target.tab_idx].iterator();
    while (it.next()) |entry| : (i += 1) {
        if (i == pane_idx) {
            found = entry.view;
            break;
        }
    }
    const pane = found orelse return IpcError.UnknownPane;
    target.window.selectWorkspace(target.ws_idx);
    target.window.selectTabIndex(target.tab_idx);
    target.ws.tab_active_pane[target.tab_idx] = pane;
    pane.focus();
    server.sendOk(req.id, null) catch {};
}

/// new-split {dir:"right"|"down", [workspace],[tab],[command]} → split the
/// addressed (or active) tab's active pane and reply with the new pane's
/// surface id. Selects the target workspace/tab first (newSplit* act on the
/// active workspace), then splits. With `command`, the split runs that
/// shell (split on whitespace); without it, it inherits the source pane's
/// backend (matching the UI split UX).
fn ipcNewSplit(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const dir_str = ipcArgString(req, "dir") orelse
        ipcArgString(req, "direction") orelse return IpcError.MissingDirection;
    const direction: SplitTree(Pane).Split.Direction = if (std.mem.eql(u8, dir_str, "right"))
        .right
    else if (std.mem.eql(u8, dir_str, "down"))
        .down
    else
        return IpcError.BadDirection;

    const target = try self.ipcResolveTab(req);
    const window = target.window;
    if (window.is_quick_terminal) return IpcError.QuickTerminal;

    // Programmatic split defaults to NON-FOCUS: the split is created in the
    // target tab's pane tree but the active workspace/tab/pane and OS
    // foreground are NOT changed (a background pane, hidden until its tab is
    // shown). `--focus` (focus:true) selects the target workspace+tab and
    // focuses the new pane, the interactive split UX. Matches the
    // "create != focus" policy applied to every create verb.
    const focus = ipcArgBool(req, "focus") orelse false;
    if (focus) {
        if (target.ws_idx != window.active_workspace) window.selectWorkspace(target.ws_idx);
        if (target.tab_idx != target.ws.active_tab) window.selectTabIndex(target.tab_idx);
    }

    // Parse an optional explicit command once (split on whitespace); an
    // empty/whitespace-only command inherits the source pane's backend.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.core_app.alloc);
    if (ipcArgString(req, "command")) |command_str| {
        var it = std.mem.tokenizeAny(u8, command_str, &std.ascii.whitespace);
        while (it.next()) |tok| try argv.append(self.core_app.alloc, tok);
    }
    const explicit: ?[]const []const u8 = if (argv.items.len > 0) argv.items else null;
    // Inherit the source pane's backend when no explicit command (matching
    // newSplit's inherit-from-active-pane behavior), read from the TARGET
    // tab's active pane so a background split follows its own tab's shell.
    const command: ?[]const []const u8 = explicit orelse blk: {
        const src = target.ws.tab_active_pane[target.tab_idx].surface() orelse break :blk null;
        break :blk src.spawn_command;
    };

    const new_pane = try window.newSplitInWorkspace(
        target.ws_idx,
        target.tab_idx,
        direction,
        command,
        focus,
    );

    const sid: u64 = ipcSurfaceId(new_pane) orelse 0;
    var data_buf: [32]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "{{\"id\":{d}}}", .{sid}) catch
        return error.NoSpaceLeft;
    server.sendOk(req.id, data) catch {};
}

/// set-status {[workspace],[tab],[text]} → set (or clear, when text is
/// empty/absent) the addressed tab's orchestration status string. Stored on
/// the workspace; the sidebar renders it (Stage 2). Repaints the sidebar.
fn ipcSetStatus(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveTab(req);
    const text = ipcArgString(req, "text") orelse "";
    target.ws.setTabStatusText(target.tab_idx, text);
    target.window.invalidateSidebar();
    server.sendOk(req.id, null) catch {};
}

/// set-progress {[workspace],[tab], value} → set the addressed tab's
/// progress percent (0..100), or clear it with value -1 (or absent).
fn ipcSetProgress(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveTab(req);
    const value = ipc.argI64Named(req, "value") orelse -1;
    if (value < 0) {
        target.ws.setTabProgress(target.tab_idx, null);
    } else if (value <= 100) {
        target.ws.setTabProgress(target.tab_idx, @intCast(value));
    } else {
        return IpcError.BadProgress;
    }
    target.window.invalidateSidebar();
    server.sendOk(req.id, null) catch {};
}

/// log {[workspace],[tab], text} → append a line to the addressed tab's
/// ring log buffer (and the global notification panel). Repaints the
/// sidebar. The line is truncated to the ring's per-line cap.
fn ipcLog(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const text = ipcArgString(req, "text") orelse return IpcError.MissingText;
    const target = try self.ipcResolveTab(req);
    target.ws.pushTabLog(target.tab_idx, text);

    // Also surface it in the global notif panel (reuses pushNotif), tied
    // to the addressed tab's active pane when it is a terminal.
    const pane = target.ws.tab_active_pane[target.tab_idx];
    if (pane.surface()) |surface| {
        const alloc = self.core_app.alloc;
        const body_w = std.unicode.utf8ToUtf16LeAlloc(alloc, text[0..@min(text.len, 128)]) catch null;
        defer if (body_w) |bw| alloc.free(bw);
        const title_w = std.unicode.utf8ToUtf16LeStringLiteral("log");
        self.pushNotif(.osc, target.window, surface, title_w, if (body_w) |bw| bw else &.{});
    } else {
        target.window.invalidateSidebar();
    }
    server.sendOk(req.id, null) catch {};
}

/// read-screen {[workspace],[tab],[lines],[scrollback]} → the addressed
/// (or active) pane terminal's screen text as UTF-8. By default the visible
/// active screen; with `scrollback:true` the full screen including
/// scrollback history. The terminal screen is locked under the renderer
/// mutex while it is dumped. The framer's 1 MiB cap bounds very long
/// scrollback (truncated by the wire layer). This is the agent-reads-agent
/// verb. `lines` (when given) keeps only the last N non-empty-trimmed
/// physical lines of the dump (a cheap tail; v1 limitation noted in the
/// CLI help).
fn ipcReadScreen(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveTab(req);
    const pane = target.ws.tab_active_pane[target.tab_idx];
    const surface = pane.surface() orelse return IpcError.NotATerminal;
    if (!surface.core_surface_ready) return IpcError.CoreNotReady;

    const alloc = self.core_app.alloc;
    const scrollback = ipcArgBool(req, "scrollback") orelse false;

    // Dump under the renderer mutex: the screen is shared with the
    // renderer/IO threads. dumpStringAlloc walks the active screen
    // (visible) or the full screen (scrollback) as plain UTF-8.
    const dump: []const u8 = dump: {
        const cs = &surface.core_surface;
        cs.renderer_state.mutex.lock();
        defer cs.renderer_state.mutex.unlock();
        // ScreenSet.active is already a *Screen.
        const screen = cs.io.terminal.screens.active;
        const point: @import("../../terminal/main.zig").point.Point =
            if (scrollback) .{ .screen = .{ .x = 0, .y = 0 } } else .{ .active = .{ .x = 0, .y = 0 } };
        break :dump try screen.dumpStringAlloc(alloc, point);
    };
    defer alloc.free(dump);

    // Optional tail: keep only the last N lines.
    const text: []const u8 = if (ipcArgU32(req, "lines")) |n| blk: {
        if (n == 0) break :blk dump;
        var count: usize = 0;
        var i: usize = dump.len;
        // Walk back over up to N newline-separated lines.
        while (i > 0) {
            const nl = std.mem.lastIndexOfScalar(u8, dump[0..i], '\n') orelse {
                break;
            };
            count += 1;
            if (count >= n) {
                break :blk dump[nl + 1 ..];
            }
            i = nl;
        }
        break :blk dump;
    } else dump;

    // Reply as a JSON string (escaped). The dump can be large; cap it
    // generously below the framer's 1 MiB so the response (with escaping
    // overhead) still fits.
    const max_payload: usize = 768 * 1024;
    const clipped = if (text.len > max_payload) text[text.len - max_payload ..] else text;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.value(clipped, .{}, &aw.writer);
    server.sendOk(req.id, aw.written()) catch {};
}

/// capture-pane {[workspace],[tab],[scrollback:bool],[file:path]} — the
/// tmux `capture-pane` equivalent. Dumps the addressed (or active) pane's
/// screen text, optionally including the scrollback buffer. When `file` is
/// given the dump is written there instead of returned as the IPC response.
/// The dump is plain UTF-8 text (no ANSI escapes) — matching read-screen's
/// format — so it can be piped back into a terminal for session restore.
fn ipcCapturePaneCmd(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveTab(req);
    const pane = target.ws.tab_active_pane[target.tab_idx];
    const surface = pane.surface() orelse return IpcError.NotATerminal;
    if (!surface.core_surface_ready) return IpcError.CoreNotReady;

    const alloc = self.core_app.alloc;
    const scrollback = ipcArgBool(req, "scrollback") orelse false;

    // Dump under the renderer mutex: the screen is shared with the
    // renderer/IO threads.
    const dump: []const u8 = dump: {
        const cs = &surface.core_surface;
        cs.renderer_state.mutex.lock();
        defer cs.renderer_state.mutex.unlock();
        const screen = cs.io.terminal.screens.active;
        const point: @import("../../terminal/main.zig").point.Point =
            if (scrollback) .{ .screen = .{ .x = 0, .y = 0 } } else .{ .active = .{ .x = 0, .y = 0 } };
        break :dump try screen.dumpStringAlloc(alloc, point);
    };
    defer alloc.free(dump);

    // If a file path was given, write the dump there and reply with the
    // path; otherwise return the text as the IPC data (JSON-escaped, same
    // as read-screen).
    if (ipcArgString(req, "file")) |file_path| {
        // Ensure parent directory exists.
        if (std.fs.path.dirname(file_path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }
        const file = std.fs.cwd().createFile(file_path, .{ .truncate = true }) catch
            return error.CreateFileFailed;
        defer file.close();
        file.writeAll(dump) catch return error.WriteFileFailed;

        // Reply with the path we wrote.
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try std.json.Stringify.value(file_path, .{}, &aw.writer);
        server.sendOk(req.id, aw.written()) catch {};
    } else {
        const max_payload: usize = 768 * 1024;
        const clipped = if (dump.len > max_payload) dump[dump.len - max_payload ..] else dump;

        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try std.json.Stringify.value(clipped, .{}, &aw.writer);
        server.sendOk(req.id, aw.written()) catch {};
    }
}

/// Capture the scrollback + visible screen of every terminal pane and save
/// each to `%LOCALAPPDATA%\ghostty\scrollback\<surface_id>.txt`. Called
/// during session save so that session restore can repopulate the panes.
/// Best-effort: errors on individual panes are swallowed.
pub fn saveAllScrollback(self: *App) void {
    const alloc = self.core_app.alloc;
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return;
    defer alloc.free(dir);
    const scrollback_dir = std.fs.path.join(alloc, &.{ dir, "ghostty", "scrollback" }) catch return;
    defer alloc.free(scrollback_dir);

    std.fs.cwd().makePath(scrollback_dir) catch return;

    for (self.windows.items) |w| {
        if (w.closing) continue;
        for (w.workspaces[0..w.workspace_count]) |*ws| {
            for (0..ws.tab_count) |t| {
                var it = ws.tab_trees[t].iterator();
                while (it.next()) |entry| {
                    const surface = switch (entry.view.content) {
                        .terminal => |s| s,
                        .browser => continue,
                    };
                    if (!surface.core_surface_ready) continue;
                    self.saveOnePaneScrollback(alloc, scrollback_dir, surface) catch continue;
                }
            }
        }
    }
}

/// Save one pane's screen (scrollback + visible) to a file.
fn saveOnePaneScrollback(
    self: *App,
    alloc: Allocator,
    scrollback_dir: []const u8,
    surface: *Surface,
) !void {
    _ = self;
    const cs = &surface.core_surface;
    const sid = cs.id;

    // Dump the full screen (scrollback + visible) under the renderer mutex.
    const dump: []const u8 = dump: {
        cs.renderer_state.mutex.lock();
        defer cs.renderer_state.mutex.unlock();
        const screen = cs.io.terminal.screens.active;
        break :dump try screen.dumpStringAlloc(alloc, .{ .screen = .{ .x = 0, .y = 0 } });
    };
    defer alloc.free(dump);

    // Build filename: <scrollback_dir>/<surface_id>.txt
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.txt", .{sid}) catch return;
    const path = try std.fs.path.join(alloc, &.{ scrollback_dir, name });
    defer alloc.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(dump);
}

/// Restore saved scrollback into a pane by writing the text to the
/// terminal's PTY as if it were program output, which naturally populates
/// the scrollback buffer. The file is
/// `%LOCALAPPDATA%\ghostty\scrollback\<surface_id>.txt`.
pub fn restoreScrollback(self: *App, surface: *Surface) void {
    const alloc = self.core_app.alloc;
    if (!surface.core_surface_ready) return;

    const sid = surface.core_surface.id;

    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return;
    defer alloc.free(dir);

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.txt", .{sid}) catch return;
    const path = std.fs.path.join(alloc, &.{ dir, "ghostty", "scrollback", name }) catch return;
    defer alloc.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    // Read the saved scrollback (cap at 1 MiB to avoid unbounded allocs).
    const max_restore: usize = 1024 * 1024;
    const content = file.readToEndAlloc(alloc, max_restore) catch return;
    defer alloc.free(content);

    if (content.len == 0) return;

    // Write the content to the terminal's PTY input as if it were program
    // output. This populates the scrollback naturally.
    const termio_mod = @import("../../termio.zig");
    const msg = termio_mod.Message.writeReq(alloc, content) catch return;
    surface.core_surface.io.queueMessage(msg, .unlocked);
}

/// Resolve the surface a session verb targets: an explicit `surface` id, or
/// the addressed (or active) tab's active terminal pane. Returns the surface
/// id and a pointer to the surface (for relaunch). The id is the core
/// Surface.id (stable, == GHOSTTY_SURFACE_ID).
const SessionTarget = struct { id: u64, surface: *Surface };

fn ipcResolveSessionTarget(self: *App, req: *ipc.Request) IpcError!SessionTarget {
    if (ipcArgU64(req, "surface")) |sid| {
        const loc = self.ipcFindSurfaceById(sid) orelse return IpcError.UnknownSurface;
        return .{ .id = sid, .surface = loc.surface };
    }
    const target = try self.ipcResolveTab(req);
    const pane = target.ws.tab_active_pane[target.tab_idx];
    const surface = pane.surface() orelse return IpcError.NotATerminal;
    if (!surface.core_surface_initialized) return IpcError.CoreNotReady;
    return .{ .id = surface.core_surface.id, .surface = surface };
}

/// session-capture {agent, session, [surface]|[workspace,tab]} → record the
/// (surface → agent + native session id) association in the store. Default
/// target is the calling pane (the pane whose shell ran the hook); an
/// explicit `surface` (GHOSTTY_SURFACE_ID, the hook's own pane) wins and
/// removes the active-pane race.
fn ipcSessionCapture(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const agent_name = ipcArgString(req, "agent") orelse return IpcError.MissingAgent;
    const session = ipcArgString(req, "session") orelse return IpcError.MissingSession;
    const target = try self.ipcResolveSessionTarget(req);

    const kind = agent_session.AgentKind.parse(agent_name);
    // put returns SessionIdTooLong for an oversized (hostile/garbled) id;
    // surface it verbatim to the client rather than masking it as OOM.
    try self.session_store.put(target.id, kind, session);
    // Repaint so a sidebar "resumable" affordance (Stage 2) can reflect it.
    if (self.ipcFindSurfaceById(target.id)) |loc| loc.window.invalidateSidebar();

    // 20 (u64 max digits) + agent tag + JSON scaffold; 96 is ample.
    var data_buf: [96]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "{{\"surface\":{d},\"agent\":\"{s}\"}}", .{ target.id, @tagName(kind) }) catch
        return error.NoSpaceLeft;
    server.sendOk(req.id, data) catch {};
}

/// session-resume {[surface]|[workspace,tab]} → look up the target surface's
/// captured agent + id and replay the agent's resume argv into that pane via
/// the keystroke path (ipcSendText, +CR), so the agent relaunches in place.
/// NoSession if nothing was captured for the surface; NoResumeRecipe if the
/// captured agent has no resume command (`.unknown`).
fn ipcSessionResume(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveSessionTarget(req);
    const entry = self.session_store.get(target.id) orelse return IpcError.NoSession;

    var argv_buf: [agent_session.max_resume_argv][]const u8 = undefined;
    const n = entry.agent.resumeArgv(entry.session_id, &argv_buf) catch
        return IpcError.NoResumeRecipe;

    // Join argv into a single shell command line. The pieces are an exe
    // name + flags + a session id (UUID/token), none of which contain
    // spaces in the supported agents, so a plain space join is safe.
    const alloc = self.core_app.alloc;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    for (argv_buf[0..n], 0..) |part, i| {
        if (i > 0) try line.append(alloc, ' ');
        try line.appendSlice(alloc, part);
    }
    try target.surface.ipcSendText(line.items, true);
    server.sendOk(req.id, null) catch {};
}

/// session-list → dump the whole agent-session store as JSON
/// `[{surface, agent, session}]`.
fn ipcSessionList(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const alloc = self.core_app.alloc;
    const json = try self.session_store.serialize(alloc);
    defer alloc.free(json);
    server.sendOk(req.id, json) catch {};
}

/// select-layout {layout} → rearrange splits into a predefined layout.
fn ipcSelectLayout(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const name = ipc.argString(req, "layout") orelse
        return server.sendError(req.id, "missing \"layout\" argument") catch {};
    const layout = std.meta.stringToEnum(apprt.action.SelectLayout, name) orelse
        return server.sendError(req.id, "unknown layout") catch {};
    const window = self.ipcTargetWindow() orelse return;
    window.selectLayout(layout);
    server.sendOk(req.id, null) catch {};
}

/// sync-input {action:"toggle"|"on"|"off", [workspace], [tab]} → toggle or
/// set synchronized input for the addressed tab. Defaults to active
/// workspace/tab.
fn ipcSyncInput(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const action_str = ipcArgString(req, "action") orelse "toggle";
    const target = try self.ipcResolveWorkspace(req);
    const ws = target.ws;
    const tab_idx: usize = if (ipcArgU32(req, "tab")) |t| t else ws.active_tab;
    if (tab_idx >= ws.tab_count) return IpcError.UnknownTab;

    if (std.mem.eql(u8, action_str, "toggle")) {
        ws.tab_synchronized[tab_idx] = !ws.tab_synchronized[tab_idx];
    } else if (std.mem.eql(u8, action_str, "on")) {
        ws.tab_synchronized[tab_idx] = true;
    } else if (std.mem.eql(u8, action_str, "off")) {
        ws.tab_synchronized[tab_idx] = false;
    } else {
        return IpcError.BadAction;
    }
    target.window.invalidateTabBar();
    server.sendOk(req.id, null) catch {};
}

/// break-pane: break the active pane of the addressed (or active) tab
/// out of its split into a new tab.
fn ipcBreakPane(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveTab(req);
    const pane = target.ws.tab_active_pane[target.tab_idx];
    target.window.breakPane(pane);
    server.sendOk(req.id, null) catch {};
}

/// move-pane: move the active pane of the addressed (or active) tab to
/// an adjacent tab. Args: {direction:"next"|"prev"|"new", [workspace],
/// [tab]}.
fn ipcMovePaneToTab(self: *App, req: *ipc.Request) anyerror!void {
    const server = self.ipc_server orelse return;
    const target = try self.ipcResolveTab(req);
    const pane = target.ws.tab_active_pane[target.tab_idx];

    const dir_str: ?[]const u8 = if (req.args == .object)
        if (req.args.object.get("direction")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null
    else
        null;
    const move_target: apprt.action.MovePaneTarget = if (dir_str) |d| blk: {
        if (std.mem.eql(u8, d, "next")) break :blk .next_tab;
        if (std.mem.eql(u8, d, "prev")) break :blk .prev_tab;
        if (std.mem.eql(u8, d, "new")) break :blk .new_tab;
        return IpcError.BadDirection;
    } else .next_tab;

    target.window.movePaneToTab(pane, move_target);
    server.sendOk(req.id, null) catch {};
}

/// Append an entry to the sidebar notification log, bump the unread
/// badge, and repaint every sidebar. Title/body are UTF-16 and
/// truncated to the entry's inline buffers.
pub fn pushNotif(
    self: *App,
    kind: NotifEntry.Kind,
    window: *Window,
    surface: *Surface,
    title: []const u16,
    body: []const u16,
) void {
    var entry: NotifEntry = .{
        .kind = kind,
        .window = window,
        .surface = surface,
        .title = undefined,
        .title_len = @min(title.len, 128),
        .body = undefined,
        .body_len = @min(body.len, 128),
    };
    @memcpy(entry.title[0..entry.title_len], title[0..entry.title_len]);
    @memcpy(entry.body[0..entry.body_len], body[0..entry.body_len]);
    self.notif_log.push(entry);
    for (self.windows.items) |w| w.invalidateSidebar();
    // Received → Unread: the new entry bumps the taskbar overlay count.
    // (showDesktopNotification also refreshes after a balloon, but pushes
    // from the bell/exit paths land here only, so refresh unconditionally.)
    self.refreshTaskbarBadges();
}

/// Reset the unread badge and mark every live entry Read (the user opened
/// the notifications panel / clicked the bell — they have now "viewed" the
/// log). Repaints only when something actually changed. This is the
/// Unread→Read lifecycle transition for the whole log.
pub fn markNotifsRead(self: *App) void {
    var changed = self.notif_log.markRead();
    for (&self.notif_log.slots) |*slot| {
        if (slot.*) |*entry| {
            if (!entry.read) {
                entry.read = true;
                changed = true;
            }
        }
    }
    if (!changed) return;
    for (self.windows.items) |w| w.invalidateSidebar();
    // Unread → Read for the whole log: clear/lower the taskbar badge.
    self.refreshTaskbarBadges();
}

/// Count of live notification-log entries still marked Unread. This is the
/// number drawn on the taskbar overlay badge (cmux's dock-badge analog) and
/// is distinct from `notif_log.unread`, which counts *pushes* since the
/// last markRead and drives the sidebar bell badge. Counting live Unread
/// entries means the taskbar badge clears correctly once the panel is
/// opened (markNotifsRead flips every entry to Read) or each entry is
/// jumped to.
pub fn unreadNotifCount(self: *const App) usize {
    return self.notif_log.unreadLive();
}

/// Update every window's taskbar-button overlay to reflect the current
/// unread-notification count (0 clears the badge). Lazily creates the
/// process-wide ITaskbarList3 on first use; a creation failure (no COM)
/// makes this a silent no-op forever after. Called whenever the unread
/// count can change: a push, a markRead, a jump, or a clear.
pub fn refreshTaskbarBadges(self: *App) void {
    if (self.taskbar_list == null) {
        if (self.taskbar_tried) return;
        self.taskbar_tried = true;
        self.taskbar_list = taskbar.TaskbarList.create();
        if (self.taskbar_list == null) return;
    }
    const tl = &self.taskbar_list.?;
    const count = self.unreadNotifCount();
    for (self.windows.items) |w| {
        if (w.closing) continue;
        if (w.hwnd) |hwnd| tl.setOverlayCount(hwnd, count);
    }
}

/// Display index (0 = newest) of the most-recent Unread notification, or
/// null when every live entry has been Read. Walks newest-first so the
/// "jump to most recent unread" verb lands on the freshest pending entry.
/// Uses the same hole-skipping display mapping as `notifAt`.
pub fn firstUnreadNotif(self: *const App) ?usize {
    return self.notif_log.firstUnread();
}

/// Mark a single entry (by display index) Read and adjust the unread badge
/// down by one (saturating at 0) so the badge tracks the per-entry state.
/// Used when the user jumps to one entry rather than viewing the whole
/// panel. Returns true when the entry existed and flipped Unread→Read.
pub fn markNotifEntryRead(self: *App, display_idx: usize) bool {
    var seen: usize = 0;
    const cap = NOTIF_LOG_CAP;
    var offset: usize = 0;
    while (offset < cap) : (offset += 1) {
        const idx = (self.notif_log.next + cap - 1 - offset) % cap;
        if (self.notif_log.slots[idx]) |*entry| {
            if (seen == display_idx) {
                if (entry.read) return false;
                entry.read = true;
                if (self.notif_log.unread > 0) self.notif_log.unread -= 1;
                // Unread → Read for one entry: lower the taskbar badge.
                self.refreshTaskbarBadges();
                return true;
            }
            seen += 1;
        }
    }
    return false;
}

/// Toggle the read/unread state of a single entry (by display index).
/// If the entry is Unread, mark it Read (decrement badge); if Read,
/// mark it Unread (increment badge). Repaints the sidebar and taskbar
/// badge. Returns true when the entry existed and was toggled.
pub fn toggleNotifRead(self: *App, display_idx: usize) bool {
    var seen: usize = 0;
    const cap = NOTIF_LOG_CAP;
    var offset: usize = 0;
    while (offset < cap) : (offset += 1) {
        const idx = (self.notif_log.next + cap - 1 - offset) % cap;
        if (self.notif_log.slots[idx]) |*entry| {
            if (seen == display_idx) {
                if (entry.read) {
                    // Read → Unread: re-flag as unread.
                    entry.read = false;
                    self.notif_log.unread += 1;
                } else {
                    // Unread → Read.
                    entry.read = true;
                    if (self.notif_log.unread > 0) self.notif_log.unread -= 1;
                }
                for (self.windows.items) |w| w.invalidateSidebar();
                self.refreshTaskbarBadges();
                return true;
            }
            seen += 1;
        }
    }
    return false;
}

/// Find the oldest unread notification, mark it as read, and jump to the
/// NEXT unread entry's source pane. If there are no unread entries, this
/// is a no-op. Returns true when a jump was performed.
pub fn markOldestUnreadAndJumpNext(self: *App) bool {
    // Find the oldest unread entry.
    const oldest_idx = self.notif_log.lastUnread() orelse return false;

    // Mark it read.
    _ = self.markNotifEntryRead(oldest_idx);

    // Now find the new first (newest) unread — this is the "next" unread
    // to jump to. We use firstUnread for consistency with ipcNotifyNext.
    const next_idx = self.firstUnreadNotif() orelse return false;
    const entry = self.notifAt(next_idx) orelse return false;
    const window = entry.window;
    const surface = entry.surface;

    // Validate the entry's pointers are still live (mirrors ipcNotifyNext).
    const live = blk: {
        for (self.windows.items) |w| {
            if (w == window) {
                if (w.closing) break :blk false;
                break :blk w.findLocOfSurface(surface) != null;
            }
        }
        break :blk false;
    };
    if (!live) return false;

    const jumped = self.jumpToSurface(window, surface);
    if (jumped) _ = self.markNotifEntryRead(next_idx);
    return jumped;
}

/// Drop every notification log entry and the unread badge.
pub fn clearNotifs(self: *App) void {
    self.notif_log.clear();
    for (self.windows.items) |w| w.invalidateSidebar();
    // Cleared: remove the taskbar badge entirely.
    self.refreshTaskbarBadges();
}

/// Number of live entries in the notification log.
pub fn notifCount(self: *const App) usize {
    return self.notif_log.count();
}

/// The display_idx-th newest live notification (0 = newest), or null
/// past the end. Nulled slots are skipped so display indices stay
/// contiguous; paint and hit-test resolve entries through this same
/// mapping.
pub fn notifAt(self: *const App, display_idx: usize) ?*const NotifEntry {
    return self.notif_log.at(display_idx);
}

/// Remove a desktop notification's tray icon, kill its cleanup timer,
/// and free the slot.
fn clearDesktopNotif(self: *App, slot: usize) void {
    self.desktop_notifs[slot] = null;
    const hwnd = self.msg_hwnd orelse return;
    _ = w32.KillTimer(hwnd, NOTIF_DESKTOP_TIMER_BASE + slot);
    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_DESKTOP_UID_BASE + @as(u32, @intCast(slot));
    _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
}

/// Null any desktop-notification slots that reference a window being
/// destroyed so a later balloon click can't touch freed memory (or a
/// recycled allocation at the same address). The icon and timer are
/// left for the normal timeout path; a click on the orphaned balloon
/// is a validated no-op.
pub fn dropDesktopNotifsForWindow(self: *App, window: *Window) void {
    for (&self.desktop_notifs) |*slot| {
        if (slot.*) |n| {
            if (n.window == window) slot.* = null;
        }
    }
    // Same invalidation for the sidebar notification log. Slots are
    // nulled in place (not compacted) — notifAt skips holes.
    for (&self.notif_log.slots) |*slot| {
        if (slot.*) |*entry| {
            if (entry.window == window) slot.* = null;
        }
    }
}

/// Whether the current foreground window belongs to THIS process. The
/// guard for every OS-foreground raise (forceForegroundWindow and the
/// present_terminal raise): we only ever steal/move OS foreground when we
/// already own it — switching between our own windows is fine, but we
/// must NEVER yank the user out of another app (VS Code, Slack, the app
/// an agent orchestrator is driving). Returns false when there is no
/// foreground window (treat as "not ours" — don't grab it).
pub fn foregroundIsOurs() bool {
    const fg = w32.GetForegroundWindow() orelse return false;
    var fg_pid: u32 = 0;
    _ = w32.GetWindowThreadProcessId(fg, &fg_pid);
    return fg_pid == w32.GetCurrentProcessId();
}

/// Raise a window of THIS process to the foreground, but ONLY when the
/// current foreground window already belongs to us. When another
/// application is foreground this is a no-op: the caller may still have
/// restored/shown the window (it will flash its taskbar button) but we
/// never steal OS foreground from another app. See foregroundIsOurs.
/// This is the gate for every PROGRAMMATIC/notification raise
/// (present_terminal, jumpToSurface, +notify next, --focus). The
/// interactive QuickTerminal summon uses the ungated raiseForegroundWindow
/// (user-pressed hotkey == explicit intent to come forward over any app).
pub fn forceForegroundWindow(hwnd: w32.HWND) void {
    if (!foregroundIsOurs()) return;
    raiseForegroundWindow(hwnd);
}

/// Unconditionally raise `hwnd` to the OS foreground. Uses
/// AttachThreadInput to work around the Win32 SetForegroundWindow
/// restriction when the current foreground window belongs to another
/// thread/process. The UNGATED primitive: only the interactive
/// QuickTerminal summon (an explicit user hotkey) calls this directly;
/// every programmatic/notification path goes through forceForegroundWindow
/// so it can never yank the user out of another app.
pub fn raiseForegroundWindow(hwnd: w32.HWND) void {
    const fg = w32.GetForegroundWindow();
    if (fg) |fg_hwnd| {
        const fg_tid = w32.GetWindowThreadProcessId(fg_hwnd, null);
        const our_tid = w32.GetCurrentThreadId();
        if (fg_tid != our_tid) {
            _ = w32.AttachThreadInput(our_tid, fg_tid, 1);
            _ = w32.SetForegroundWindow(hwnd);
            _ = w32.AttachThreadInput(our_tid, fg_tid, 0);
        } else {
            _ = w32.SetForegroundWindow(hwnd);
        }
    } else {
        _ = w32.SetForegroundWindow(hwnd);
    }
}

// -----------------------------------------------------------------------
// WebView2 environment singleton (browser panes)
// -----------------------------------------------------------------------

/// Hand a browser pane the shared WebView2 environment, creating it on
/// first use. The pane already holds its in-flight ref (startCreation);
/// onEnvironment consumes it on failure or carries it into controller
/// creation. Must be called on the UI thread.
pub fn requestWebView2Env(self: *App, browser: *BrowserPane) void {
    const alloc = self.core_app.alloc;
    switch (self.webview2_env_state) {
        .ready, .failed => browser.onEnvironment(self.webview2_env),
        .creating => self.webview2_pending.append(alloc, browser) catch {
            browser.onEnvironment(null);
        },
        .none => {
            self.webview2_pending.append(alloc, browser) catch {
                browser.onEnvironment(null);
                return;
            };
            self.createWebView2Env();
        },
    }
}

/// Kick off async creation of the shared WebView2 environment. Any
/// failure (loader missing, user-data folder, OOM) marks the singleton
/// failed and flushes the pending panes with a null environment.
fn createWebView2Env(self: *App) void {
    self.webview2_env_state = .creating;
    const alloc = self.core_app.alloc;

    const loader = wv2.loadLoader() catch |err| {
        log.warn("WebView2Loader.dll unavailable, browser panes disabled: {}", .{err});
        self.failWebView2Env();
        return;
    };

    // User data folder: %LOCALAPPDATA%\ghostty\webview2. Must exist
    // before environment creation.
    const local = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch {
        self.failWebView2Env();
        return;
    };
    defer alloc.free(local);
    const dir = std.fs.path.join(alloc, &.{ local, "ghostty", "webview2" }) catch {
        self.failWebView2Env();
        return;
    };
    defer alloc.free(dir);
    std.fs.cwd().makePath(dir) catch |err| {
        log.warn("failed to create WebView2 user data dir={s} err={}", .{ dir, err });
        self.failWebView2Env();
        return;
    };
    const dir_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, dir) catch {
        self.failWebView2Env();
        return;
    };
    defer alloc.free(dir_w);

    const handler = wv2.EnvironmentCompletedHandler(App).create(
        alloc,
        self,
        onWebView2EnvCreated,
    ) catch {
        self.failWebView2Env();
        return;
    };
    loader.createEnvironment(null, dir_w.ptr, handler) catch {
        handler.unref();
        log.warn("CreateCoreWebView2EnvironmentWithOptions failed", .{});
        self.failWebView2Env();
        return;
    };
    handler.unref();
}

fn onWebView2EnvCreated(self: *App, error_code: wv2.HRESULT, env_opt: ?*wv2.ICoreWebView2Environment) void {
    if (env_opt) |env| {
        env.addRef();
        self.webview2_env = env;
        self.webview2_env_state = .ready;
    } else {
        log.warn("WebView2 environment creation failed hr=0x{x:0>8}", .{
            @as(u32, @bitCast(error_code)),
        });
        self.webview2_env_state = .failed;
    }
    self.flushWebView2Pending();
}

fn failWebView2Env(self: *App) void {
    self.webview2_env_state = .failed;
    self.flushWebView2Pending();
}

/// Deliver the (possibly null) environment to every waiting pane. The
/// list is detached first: onEnvironment can re-enter the allocator
/// and, in principle, request paths that append again.
fn flushWebView2Pending(self: *App) void {
    const alloc = self.core_app.alloc;
    var pending = self.webview2_pending;
    self.webview2_pending = .empty;
    defer pending.deinit(alloc);
    for (pending.items) |browser| browser.onEnvironment(self.webview2_env);
}

/// Notify the core app of a tick.
fn tick(self: *App) void {
    self.core_app.tick(self) catch |err| {
        log.err("core app tick error: {}", .{err});
    };
}

/// Broadcast a key event (WM_KEYDOWN/WM_KEYUP) from the focused surface
/// to all other terminal panes in the same tab when synchronized input is
/// active. Skipped when the surface is already receiving a broadcast (the
/// sync_broadcast guard prevents infinite loops).
fn broadcastKeyEvent(source: *Surface, wparam: usize, lparam: isize, action: input.Action) void {
    const pw = source.parent_window;
    const ws = pw.activeWorkspace();
    if (ws.tab_count == 0) return;
    const tab = ws.active_tab;
    if (!ws.tab_synchronized[tab]) return;

    var it = ws.tab_trees[tab].iterator();
    while (it.next()) |entry| {
        const sibling = entry.view.surface() orelse continue;
        if (sibling == source) continue;
        sibling.sync_broadcast = true;
        _ = sibling.handleKeyEvent(wparam, lparam, action);
        sibling.sync_broadcast = false;
    }
}

/// Broadcast a WM_CHAR event to synchronized sibling panes.
fn broadcastCharEvent(source: *Surface, wparam: usize) void {
    const pw = source.parent_window;
    const ws = pw.activeWorkspace();
    if (ws.tab_count == 0) return;
    const tab = ws.active_tab;
    if (!ws.tab_synchronized[tab]) return;

    var it = ws.tab_trees[tab].iterator();
    while (it.next()) |entry| {
        const sibling = entry.view.surface() orelse continue;
        if (sibling == source) continue;
        sibling.sync_broadcast = true;
        sibling.handleCharEvent(wparam);
        sibling.sync_broadcast = false;
    }
}

/// Window procedure for terminal surface child HWNDs (GhosttyTerminal class).
/// GWLP_USERDATA stores a *Surface pointer.
fn surfaceWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const surface: *Surface = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Guard: verify this is a surface window or one of its popups.
    const is_surface_window = surface.hwnd != null and surface.hwnd.? == hwnd;
    const is_search_popup = surface.search_hwnd != null and surface.search_hwnd.? == hwnd;
    const is_palette_popup = surface.palette_hwnd != null and surface.palette_hwnd.? == hwnd;
    if (!is_surface_window and !is_search_popup and !is_palette_popup)
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_ENTERSIZEMOVE => {
            surface.in_live_resize = true;
            return 0;
        },

        w32.WM_EXITSIZEMOVE => {
            surface.in_live_resize = false;
            return 0;
        },

        w32.WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            surface.handleResize(width, height);
            return 0;
        },

        w32.WM_MOVE => {
            if (surface.scrollbar) |sb| _ = sb.repositionAndResize();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SHOWWINDOW => {
            if (surface.scrollbar) |sb| sb.setOwnerVisible(wparam != 0);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SETTINGCHANGE => {
            if (surface.scrollbar) |sb| {
                if (sb.onSettingsChange()) {
                    // Re-flow the grid to accommodate a mode change.
                    const width: u32 = surface.width;
                    const height: u32 = surface.height;
                    const lp_size: isize = @intCast((@as(usize, height) << 16) | @as(usize, width));
                    _ = w32.PostMessageW(hwnd, w32.WM_SIZE, 0, lp_size);
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CLOSE => {
            // Posted by Surface.close() to defer destruction to the
            // message loop. This is the safe place to call closeSplitSurface
            // (outside of core_surface callbacks).
            surface.parent_window.closeSplitSurface(surface);
            return 0;
        },

        w32.WM_DESTROY => {
            // The child HWND is being destroyed (by Surface.deinit or
            // parent Window destruction). Clear state so deinit()
            // doesn't double-destroy. Lifecycle is managed by Window.
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            surface.hwnd = null;
            surface.core_surface_ready = false;
            return 0;
        },

        w32.WM_ERASEBKGND => {
            // Fill with the configured background color to prevent
            // a visible flash during resize. The OpenGL renderer will
            // overwrite the entire client area on the next frame.
            if (surface.app.bg_brush) |brush| {
                const hdc_erase: w32.HDC = @ptrFromInt(wparam);
                var rect: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &rect) != 0) {
                    _ = w32.FillRect(hdc_erase, &rect, brush);
                }
            }
            return 1;
        },

        w32.WM_PAINT => {
            if (is_palette_popup) {
                surface.paintPalette(hwnd);
                return 0;
            }
            // Validate the paint region to stop Windows from
            // sending more WM_PAINT messages, then wake the
            // renderer thread to redraw.
            _ = w32.ValidateRect(hwnd, null);
            if (surface.core_surface_ready) {
                surface.core_surface.renderer_thread.wakeup.notify() catch {};
            }
            return 0;
        },

        w32.WM_DPICHANGED => {
            surface.handleDpiChange();
            return 0;
        },

        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            const consumed = surface.handleKeyEvent(wparam, lparam, .press);
            if (!consumed and !surface.sync_broadcast)
                broadcastKeyEvent(surface, wparam, lparam, .press);
            return 0;
        },

        w32.WM_KEYUP, w32.WM_SYSKEYUP => {
            const consumed = surface.handleKeyEvent(wparam, lparam, .release);
            if (!consumed and !surface.sync_broadcast)
                broadcastKeyEvent(surface, wparam, lparam, .release);
            return 0;
        },

        w32.WM_SYSCHAR => {
            // TranslateMessage is skipped for terminal surface windows
            // (see App.run), so WM_SYSCHAR is never posted by it for our
            // windows. This handler guards against WM_SYSCHAR arriving via
            // SendInput, PostMessage, or other injection paths: forwarding
            // it to DefWindowProc would treat it as an unmatched menu
            // accelerator and ring MessageBeep. Consume it unconditionally.
            return 0;
        },

        w32.WM_DEADCHAR, w32.WM_SYSDEADCHAR => {
            // The message loop skips TranslateMessage for surface windows,
            // so WM_DEADCHAR is normally never posted for them. If one
            // arrives via another path (e.g. SendInput), drop it — dead
            // keys are composed via ToUnicode in handleKeyEvent.
            return 0;
        },

        w32.WM_CHAR => {
            // In Win32 Input Mode, the Unicode character is already
            // included in the WM_KEYDOWN event (Uc parameter). WM_CHAR
            // from TranslateMessage would duplicate it. IME text arrives
            // via WM_IME_COMPOSITION (handled separately), so suppress
            // all WM_CHAR in this mode.
            if (surface.isWin32InputMode()) return 0;

            // If handleKeyEvent already produced text via ToUnicode for
            // the preceding WM_KEYDOWN, suppress this WM_CHAR to avoid
            // double input. Otherwise, process it — the character came
            // from IME, SendInput Unicode (VK_PACKET), PostMessage, or
            // another source that didn't go through handleKeyEvent.
            if (surface.key_event_produced_text) {
                surface.key_event_produced_text = false;
                return 0;
            }
            surface.handleCharEvent(wparam);
            if (!surface.sync_broadcast)
                broadcastCharEvent(surface, wparam);
            return 0;
        },

        w32.WM_GETOBJECT => {
            // Opt out of MSAA accessibility for OBJID_CLIENT. Without this,
            // DefWindowProc creates an oleacc AccWrap proxy for each surface
            // HWND. When focus moves between split panes (which are sibling
            // child HWNDs in our layout), oleacc destroys the outgoing
            // surface's AccWrap synchronously inside DefWindowProc; the
            // destructor re-enters our WindowProc via SetFocus, which fires
            // ImeSystemHandler -> oleacc!CreateClient -> COM marshaling that
            // waits for a reply this thread cannot pump (deep WindowProc
            // stack). Result: SleepConditionVariableSRW forever — the
            // ghost-hang dumps all bottom out exactly there.
            //
            // wezterm avoids this by being single-HWND (no cross-window
            // focus dance), so AccWraps that exist there are never
            // destroyed in this re-entrant pattern. Returning 0 here for
            // OBJID_CLIENT prevents AccWrap creation for our surface
            // windows, breaking the chain at the source. We don't expose
            // terminal-cell-level accessibility today anyway, so the only
            // thing this disables is the generic window-frame proxy that
            // screen readers would otherwise see.
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },


        w32.WM_IME_STARTCOMPOSITION => {
            surface.handleImeStartComposition();
            // Let DefWindowProc show the default composition window.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_IME_COMPOSITION => {
            if (surface.handleImeComposition(lparam)) {
                // We extracted the result string — suppress further
                // processing so WM_IME_CHAR/WM_CHAR are not generated.
                return 0;
            }
            // No result string yet (intermediate composition) — let
            // DefWindowProc update the default composition window.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_IME_ENDCOMPOSITION => {
            surface.handleImeEndComposition();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_LBUTTONDOWN => {
            if (is_palette_popup) {
                const y: i32 = @intCast(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
                const sc = surface.scale;
                const list_top: i32 = @intFromFloat(@round(Surface.PALETTE_LIST_TOP * sc));
                const item_height: i32 = @intFromFloat(@round(Surface.PALETTE_ITEM_HEIGHT * sc));
                if (y >= list_top) {
                    const clicked = @divTrunc(y - list_top, item_height);
                    if (clicked >= 0 and clicked < surface.palette_count) {
                        surface.palette_selected = @intCast(clicked);
                        surface.executePaletteSelection();
                    }
                }
                return 0;
            }
            // Take keyboard focus on click. WS_CHILD windows don't
            // auto-focus the way top-level windows do, so without this
            // an active sibling popup edit (tab rename, search, palette)
            // keeps focus and the click never commits/dismisses it.
            _ = w32.SetFocus(hwnd);
            surface.handleMouseButton(.left, .press, lparam);
            return 0;
        },
        w32.WM_LBUTTONUP => { surface.handleMouseButton(.left, .release, lparam); return 0; },
        w32.WM_RBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            // Only the terminal surface forwards right-clicks to the
            // core: popup-local coords would corrupt the core mouse
            // state and could open the terminal context menu from a
            // search/palette popup.
            if (is_surface_window) surface.handleMouseButton(.right, .press, lparam);
            return 0;
        },
        w32.WM_RBUTTONUP => {
            if (is_surface_window) surface.handleMouseButton(.right, .release, lparam);
            return 0;
        },
        w32.WM_MBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            surface.handleMouseButton(.middle, .press, lparam);
            return 0;
        },
        w32.WM_MBUTTONUP => { surface.handleMouseButton(.middle, .release, lparam); return 0; },

        w32.WM_MOUSEMOVE => {
            surface.handleMouseMove(lparam);
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            surface.handleMouseWheel(wparam, .vertical);
            return 0;
        },

        w32.WM_MOUSEHWHEEL => {
            surface.handleMouseWheel(wparam, .horizontal);
            return 0;
        },

        w32.WM_DROPFILES => {
            surface.handleDropFiles(wparam);
            return 0;
        },

        w32.WM_SETCURSOR => {
            // Only override the cursor in the client area. For non-client
            // areas (resize borders, title bar), let DefWindowProc handle it.
            const hit_test: u16 = @intCast(lparam & 0xFFFF);
            if (hit_test == w32.HTCLIENT and surface.handleSetCursor()) {
                return 1; // TRUE = we set the cursor
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (control_id == Surface.SEARCH_EDIT_ID and notification == w32.EN_CHANGE) {
                surface.handleSearchChange();
                return 0;
            }
            if (control_id == Surface.PALETTE_EDIT_ID and notification == w32.EN_CHANGE) {
                surface.handlePaletteChange();
                return 0;
            }
            // Auto-dismiss popups when the Edit loses focus (click outside,
            // Alt+Tab away). Matches standard popup UX (VS Code palette,
            // macOS Spotlight). The dismiss helpers clear *_active first,
            // so any re-entrant EN_KILLFOCUS during ShowWindow(SW_HIDE) /
            // SetFocus falls through these guards as a no-op.
            if (notification == w32.EN_KILLFOCUS) {
                if (control_id == Surface.PALETTE_EDIT_ID and surface.palette_active) {
                    surface.setCommandPaletteActive(false);
                    return 0;
                }
                if (control_id == Surface.SEARCH_EDIT_ID and surface.search_active) {
                    surface.setSearchActive(false, &[_:0]u8{});
                    return 0;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CTLCOLOREDIT => {
            // Dark mode colors for search/palette edit controls
            const hdc_edit: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_edit, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_edit, if (is_palette_popup) w32.RGB(30, 30, 30) else w32.RGB(45, 45, 45));
            if (is_palette_popup) {
                if (surface.palette_brush) |brush| {
                    return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
                }
            }
            if (surface.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_ACTIVATE => {
            // Dismiss command palette when it loses focus
            if (is_palette_popup) {
                const activate = @as(u16, @intCast(wparam & 0xFFFF));
                if (activate == 0) { // WA_INACTIVE
                    surface.setCommandPaletteActive(false);
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SETFOCUS => {
            // Update the active pane for the tab that owns this pane
            // when a split pane gains focus. Guarded: the pane back-
            // pointer is null during Surface.init, the window may be
            // mid-teardown, and a stale focus event must never plant
            // a pane in a tab slot that doesn't own it.
            const win = surface.parent_window;
            if (!win.closing) {
                if (surface.pane) |pane| {
                    if (win.findLoc(pane)) |loc| {
                        loc.ws.tab_active_pane[loc.tab] = pane;
                    }
                }
            }
            surface.handleFocus(true);
            return 0;
        },
        w32.WM_KILLFOCUS => { surface.handleFocus(false); return 0; },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Window procedure for the message-only HWND (GhosttyMsg class).
/// GWLP_USERDATA stores an *App pointer.
fn msgWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));

    if (msg == WM_APP_WAKEUP) {
        app.tick();
        return 0;
    }

    if (msg == WM_APP_IPC_REQUEST) {
        // lparam is the *ipc.Request handed over by the pipe thread; we
        // own it now and handleIpcRequest destroys it.
        const req: *ipc.Request = @ptrFromInt(@as(usize, @bitCast(lparam)));
        app.handleIpcRequest(req);
        return 0;
    }

    if (msg == WM_APP_WS_META) {
        // lparam is the *ws_meta.Result handed over by a worker thread; we
        // own it now and applyWorkspaceMetadata frees it.
        const result: *ws_meta.Result = @ptrFromInt(@as(usize, @bitCast(lparam)));
        app.applyWorkspaceMetadata(result);
        return 0;
    }

    if (msg == WM_APP_UPDATE_AVAILABLE) {
        // wparam = heap pointer to the version string, lparam = length.
        // We own the buffer and must free it after use.
        if (wparam != 0 and lparam > 0) {
            const ptr: [*]u8 = @ptrFromInt(wparam);
            const len: usize = @intCast(lparam);
            const ver = ptr[0..len];
            defer app.core_app.alloc.free(ver);
            app.showUpdateNotification(ver);
        }
        return 0;
    }

    if (msg == WM_APP_TRAY) {
        // wparam = uID, lparam = NIN_* event. A click on the update
        // notification opens the GitHub releases page; a click on a
        // desktop notification jumps to the surface that produced it.
        const event: u32 = @intCast(lparam & 0xFFFF);
        if (event != w32.NIN_BALLOONUSERCLICK) return 0;
        if (wparam == NOTIF_UPDATE_UID) {
            var url_buf: [256]u16 = undefined;
            const url_len = std.unicode.utf8ToUtf16Le(&url_buf, RELEASES_URL) catch return 0;
            url_buf[url_len] = 0;
            _ = w32.ShellExecuteW(
                null,
                std.unicode.utf8ToUtf16LeStringLiteral("open"),
                @ptrCast(&url_buf),
                null,
                null,
                w32.SW_SHOW,
            );
        } else if (wparam >= NOTIF_DESKTOP_UID_BASE and
            wparam < NOTIF_DESKTOP_UID_BASE + NOTIF_DESKTOP_SLOTS)
        {
            app.onDesktopNotifClick(wparam - NOTIF_DESKTOP_UID_BASE);
        }
        return 0;
    }

    if (msg == w32.WM_TIMER and wparam == QUIT_TIMER_ID) {
        _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
        app.quit_timer_state = .expired;
        app.quit_requested = true;
        w32.PostQuitMessage(0);
        return 0;
    }

    // Timer ID 3: quick terminal animation tick.
    if (msg == w32.WM_TIMER and wparam == QuickTerminal.ANIM_TIMER_ID) {
        if (app.quick_terminal) |qt| qt.onAnimationTick();
        return 0;
    }

    // Sidebar metadata refresh tick: kick off the off-thread git/port/PR
    // scan for the visible workspaces.
    if (msg == w32.WM_TIMER and wparam == WS_META_TIMER_ID) {
        app.refreshWorkspaceMetadata();
        return 0;
    }

    // Notification icon cleanup timers. Each notification kind has its
    // own (uID, timer-id) pair so an in-flight balloon isn't removed by
    // an unrelated timeout.
    if (msg == w32.WM_TIMER and wparam == NOTIF_UPDATE_TIMER_ID) {
        _ = w32.KillTimer(hwnd, wparam);
        var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = NOTIF_UPDATE_UID;
        _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
        return 0;
    }

    if (msg == w32.WM_TIMER and
        wparam >= NOTIF_DESKTOP_TIMER_BASE and
        wparam < NOTIF_DESKTOP_TIMER_BASE + NOTIF_DESKTOP_SLOTS)
    {
        app.clearDesktopNotif(wparam - NOTIF_DESKTOP_TIMER_BASE);
        return 0;
    }

    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    // Pull in the tests of modules App owns but only references by
    // specific decls (so their `test` blocks would otherwise not be
    // collected by the unit-test root). Mirrors Window.zig's
    // `_ = WindowState`.
    _ = ws_meta;
    _ = agent_session;
}

test "unit: parseAttentionOsc recognizes the ring/clear sentinel" {
    // ring → true, clear → false.
    try testing.expectEqual(@as(?bool, true), parseAttentionOsc("@ghostty-attention:ring"));
    try testing.expectEqual(@as(?bool, false), parseAttentionOsc("@ghostty-attention:clear"));
    // Surrounding ASCII whitespace (a padded shell sequence) is trimmed.
    try testing.expectEqual(@as(?bool, true), parseAttentionOsc("  @ghostty-attention:ring\n"));
    try testing.expectEqual(@as(?bool, false), parseAttentionOsc("\t@ghostty-attention:clear "));
}

test "unit: parseAttentionOsc ignores ordinary notifications and bad verbs" {
    // An ordinary OSC 9 notification body is not the sentinel → null
    // (the caller shows a normal balloon).
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc("Build finished"));
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc(""));
    // Right prefix, unknown verb → null (don't toggle on garbage).
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc("@ghostty-attention:"));
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc("@ghostty-attention:blink"));
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc("@ghostty-attention:ring extra"));
    // A body that merely contains the prefix mid-string is not a match
    // (must be at the start after trimming).
    try testing.expectEqual(@as(?bool, null), parseAttentionOsc("see @ghostty-attention:ring"));
}

test "unit: notif ring push and newest-first indexing" {
    var ring: NotifRing(u32, 4) = .{};
    try testing.expectEqual(@as(usize, 0), ring.count());
    try testing.expectEqual(@as(?*const u32, null), ring.at(0));

    ring.push(1);
    ring.push(2);
    ring.push(3);
    try testing.expectEqual(@as(usize, 3), ring.count());
    try testing.expectEqual(@as(u32, 3), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 2), ring.at(1).?.*);
    try testing.expectEqual(@as(u32, 1), ring.at(2).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(3));
}

test "unit: notif ring wraps at capacity dropping the oldest" {
    // The real log capacity: 70 pushes into 64 slots leave 7..70 live.
    var ring: NotifRing(u32, NOTIF_LOG_CAP) = .{};
    var i: u32 = 1;
    while (i <= 70) : (i += 1) ring.push(i);
    try testing.expectEqual(@as(usize, 64), ring.count());
    try testing.expectEqual(@as(u32, 70), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 7), ring.at(63).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(64));
    // Unread counts pushes, not live slots: it may exceed the capacity
    // (the sidebar badge saturates its display at "9+" regardless).
    try testing.expectEqual(@as(usize, 70), ring.unread);
}

test "unit: notif ring unread and markRead" {
    var ring: NotifRing(u32, 4) = .{};
    try testing.expect(!ring.markRead());
    ring.push(1);
    ring.push(2);
    try testing.expectEqual(@as(usize, 2), ring.unread);
    try testing.expect(ring.markRead());
    try testing.expectEqual(@as(usize, 0), ring.unread);
    try testing.expect(!ring.markRead());
    // Entries survive a read; only the badge resets.
    try testing.expectEqual(@as(usize, 2), ring.count());
}

test "unit: notif ring clear drops entries and unread" {
    var ring: NotifRing(u32, 4) = .{};
    ring.push(1);
    ring.push(2);
    ring.clear();
    try testing.expectEqual(@as(usize, 0), ring.count());
    try testing.expectEqual(@as(usize, 0), ring.unread);
    try testing.expectEqual(@as(?*const u32, null), ring.at(0));
    // The ring is fully reusable after a clear.
    ring.push(9);
    try testing.expectEqual(@as(u32, 9), ring.at(0).?.*);
    try testing.expectEqual(@as(usize, 1), ring.unread);
}

test "unit: notif ring skips holes keeping display indices contiguous" {
    var ring: NotifRing(u32, 4) = .{};
    ring.push(1);
    ring.push(2);
    ring.push(3);
    // Null the middle entry in place (the window-destroyed
    // invalidation in dropDesktopNotifsForWindow does this).
    ring.slots[1] = null;
    try testing.expectEqual(@as(usize, 2), ring.count());
    try testing.expectEqual(@as(u32, 3), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 1), ring.at(1).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(2));
}

test "unit: set command appends when absent" {
    const alloc = testing.allocator;
    const src = "# Ghostty config\nwindow-show-sidebar = true\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "# Ghostty config\nwindow-show-sidebar = true\ncommand = pwsh.exe\n",
        out,
    );
}

test "unit: set command appends a newline when file lacks a trailing one" {
    const alloc = testing.allocator;
    const src = "theme = dark"; // no trailing newline
    const out = try setCommandInConfigText(alloc, src, "cmd.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("theme = dark\ncommand = cmd.exe\n", out);
}

test "unit: set command appends into an empty file" {
    const alloc = testing.allocator;
    const out = try setCommandInConfigText(alloc, "", "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("command = pwsh.exe\n", out);
}

test "unit: set command replaces an existing active line in place" {
    const alloc = testing.allocator;
    const src = "theme = dark\ncommand = cmd.exe\nfont-size = 12\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    // Replaced in place; surrounding lines untouched; no extra append.
    try testing.expectEqualStrings(
        "theme = dark\ncommand = pwsh.exe\nfont-size = 12\n",
        out,
    );
}

test "unit: set command tolerates whitespace around the key and equals" {
    const alloc = testing.allocator;
    const src = "  command   =   cmd.exe  \nfont-size = 12\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("command = pwsh.exe\nfont-size = 12\n", out);
}

test "unit: set command ignores commented and lookalike keys" {
    const alloc = testing.allocator;
    // A commented command line and a different key that contains the
    // substring must NOT be treated as the active command; the value is
    // appended instead.
    const src = "# command = cmd.exe\ninitial-command = top\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "# command = cmd.exe\ninitial-command = top\ncommand = pwsh.exe\n",
        out,
    );
}

test "unit: set command replaces only the first active line" {
    const alloc = testing.allocator;
    const src = "command = cmd.exe\ncommand = bash\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    // Only the first is rewritten; the duplicate is preserved verbatim
    // (the parser uses the last, but minimal edits are the contract).
    try testing.expectEqualStrings("command = pwsh.exe\ncommand = bash\n", out);
}

test "unit: set command preserves CRLF on untouched lines" {
    const alloc = testing.allocator;
    const src = "theme = dark\r\ncommand = cmd.exe\r\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    // The replaced line is normalized to "command = pwsh.exe" (LF); the
    // other line keeps its CRLF. The match tolerates the trailing \r.
    try testing.expectEqualStrings("theme = dark\r\ncommand = pwsh.exe\n", out);
}

test "unit: set command accepts an argv value verbatim" {
    const alloc = testing.allocator;
    const out = try setCommandInConfigText(
        alloc,
        "theme = dark\n",
        "wsl.exe --cd ~ -d Ubuntu",
    );
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "theme = dark\ncommand = wsl.exe --cd ~ -d Ubuntu\n",
        out,
    );
}

test "unit: notif ring filled exactly to capacity keeps every entry" {
    var ring: NotifRing(u32, 4) = .{};
    ring.push(1);
    ring.push(2);
    ring.push(3);
    ring.push(4);
    // next has wrapped back to slot 0 but nothing is lost yet.
    try testing.expectEqual(@as(usize, 0), ring.next);
    try testing.expectEqual(@as(usize, 4), ring.count());
    try testing.expectEqual(@as(u32, 4), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 1), ring.at(3).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(4));
    // The very next push is the first to drop the oldest entry.
    ring.push(5);
    try testing.expectEqual(@as(usize, 4), ring.count());
    try testing.expectEqual(@as(u32, 5), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 2), ring.at(3).?.*);
}

test "unit: notif ring cap=1 degenerate keeps only the newest" {
    var ring: NotifRing(u32, 1) = .{};
    try testing.expectEqual(@as(usize, 0), ring.count());
    ring.push(1);
    try testing.expectEqual(@as(usize, 1), ring.count());
    try testing.expectEqual(@as(u32, 1), ring.at(0).?.*);
    ring.push(2);
    try testing.expectEqual(@as(usize, 1), ring.count());
    try testing.expectEqual(@as(u32, 2), ring.at(0).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(1));
    // Unread counts pushes (2), not live slots (1), and resets once.
    try testing.expectEqual(@as(usize, 2), ring.unread);
    try testing.expect(ring.markRead());
    try testing.expect(!ring.markRead());
}

test "unit: notif ring push after clear restarts from a wrapped state" {
    var ring: NotifRing(u32, 4) = .{};
    var i: u32 = 1;
    while (i <= 6) : (i += 1) ring.push(i); // leaves next mid-ring (2)
    ring.clear();
    try testing.expectEqual(@as(usize, 0), ring.next);
    ring.push(7);
    ring.push(8);
    try testing.expectEqual(@as(usize, 2), ring.count());
    try testing.expectEqual(@as(u32, 8), ring.at(0).?.*);
    try testing.expectEqual(@as(u32, 7), ring.at(1).?.*);
    try testing.expectEqual(@as(?*const u32, null), ring.at(2));
    try testing.expectEqual(@as(usize, 2), ring.unread);
}

test "unit: shouldToast suppresses only when the user is looking at the source" {
    // Backgrounded window: always toast regardless of workspace/panel.
    try testing.expect(shouldToast(.{ .window_foreground = false, .workspace_active = false, .panel_open = false }));
    try testing.expect(shouldToast(.{ .window_foreground = false, .workspace_active = true, .panel_open = false }));
    try testing.expect(shouldToast(.{ .window_foreground = false, .workspace_active = true, .panel_open = true }));

    // Foreground + sending workspace is the active one: suppress (the user
    // is staring right at the source pane's workspace).
    try testing.expect(!shouldToast(.{ .window_foreground = true, .workspace_active = true, .panel_open = false }));

    // Foreground + a DIFFERENT workspace active + panel closed: toast (the
    // user can't see the notifying pane and isn't watching the log).
    try testing.expect(shouldToast(.{ .window_foreground = true, .workspace_active = false, .panel_open = false }));

    // Foreground + different workspace + panel OPEN: suppress (the user is
    // actively watching the in-app notification log).
    try testing.expect(!shouldToast(.{ .window_foreground = true, .workspace_active = false, .panel_open = true }));

    // Foreground + both true: suppress.
    try testing.expect(!shouldToast(.{ .window_foreground = true, .workspace_active = true, .panel_open = true }));
}

test "unit: notif ring unreadLive and firstUnread track per-entry read state" {
    const E = struct { v: u32, read: bool = false };
    var ring: NotifRing(E, 4) = .{};

    // Empty: nothing unread.
    try testing.expectEqual(@as(usize, 0), ring.unreadLive());
    try testing.expectEqual(@as(?usize, null), ring.firstUnread());

    ring.push(.{ .v = 1 });
    ring.push(.{ .v = 2 });
    ring.push(.{ .v = 3 });
    // All three Unread; newest (display 0) is the first unread.
    try testing.expectEqual(@as(usize, 3), ring.unreadLive());
    try testing.expectEqual(@as(?usize, 0), ring.firstUnread());

    // Mark the newest (display 0 → v=3) Read: count drops, firstUnread
    // advances to the next-newest still-unread entry (display 1 → v=2).
    // Flip the slot holding v=3 (the newest, written last at next-1).
    for (&ring.slots) |*slot| {
        if (slot.*) |*e| if (e.v == 3) {
            e.read = true;
        };
    }
    try testing.expectEqual(@as(usize, 2), ring.unreadLive());
    try testing.expectEqual(@as(?usize, 1), ring.firstUnread());

    // Mark the rest Read: nothing unread, entries still live.
    for (&ring.slots) |*slot| {
        if (slot.*) |*e| e.read = true;
    }
    try testing.expectEqual(@as(usize, 0), ring.unreadLive());
    try testing.expectEqual(@as(?usize, null), ring.firstUnread());
    try testing.expectEqual(@as(usize, 3), ring.count());
}

test "unit: set command replaces the key on a final line without a newline" {
    const alloc = testing.allocator;
    const src = "theme = dark\ncommand = cmd.exe"; // EOF right after the value
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    // Replaced in place — no duplicate appended, and the file's missing
    // trailing newline is preserved as-is.
    try testing.expectEqualStrings("theme = dark\ncommand = pwsh.exe", out);
}

test "unit: set command CRLF key at EOF without a final LF" {
    const alloc = testing.allocator;
    // The last line ends in a bare \r (no \n); the \r must not defeat
    // the key match.
    const src = "theme = dark\r\ncommand = cmd.exe\r";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("theme = dark\r\ncommand = pwsh.exe", out);
}

test "unit: set command commented key followed by real key replaces the real one" {
    const alloc = testing.allocator;
    const src = "# command = old.exe\ncommand = cmd.exe\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("# command = old.exe\ncommand = pwsh.exe\n", out);
}

test "unit: set command matches when the old value contains equals" {
    const alloc = testing.allocator;
    // The key is the text before the FIRST '='; later '=' belong to the
    // value and must not break the match.
    const src = "command = env FOO=bar bash\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("command = pwsh.exe\n", out);
}

test "unit: set command writes a new value containing equals verbatim" {
    const alloc = testing.allocator;
    const out = try setCommandInConfigText(alloc, "theme = dark\n", "cmd.exe /c set X=1");
    defer alloc.free(out);
    try testing.expectEqualStrings("theme = dark\ncommand = cmd.exe /c set X=1\n", out);
}

test "unit: set command appends to an only-comments file" {
    const alloc = testing.allocator;
    const src = "# one\n# command = nope\n# three\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "# one\n# command = nope\n# three\ncommand = pwsh.exe\n",
        out,
    );
}

test "unit: set command ignores a command line without equals" {
    const alloc = testing.allocator;
    // No '=' means no key: the line is preserved and a real entry is
    // appended instead.
    const src = "command\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("command\ncommand = pwsh.exe\n", out);
}

test "unit: set command preserves very long lines byte for byte" {
    const alloc = testing.allocator;
    // A line far beyond any fixed buffer (16 KiB) must survive
    // unmodified, both before and after the replaced key.
    const long_len = 16 * 1024;
    const long = try alloc.alloc(u8, long_len);
    defer alloc.free(long);
    @memset(long, 'x');
    long[0] = '#';
    long[1] = ' ';
    const src = try std.fmt.allocPrint(
        alloc,
        "{s}\ncommand = cmd.exe\n{s}\n",
        .{ long, long },
    );
    defer alloc.free(src);
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    const expected = try std.fmt.allocPrint(
        alloc,
        "{s}\ncommand = pwsh.exe\n{s}\n",
        .{ long, long },
    );
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, out);
}

test "unit: set command preserves leading and trailing value spaces verbatim" {
    const alloc = testing.allocator;
    // The value is written verbatim after "command = "; surrounding
    // spaces are part of it, on both the replace and append paths.
    {
        const out = try setCommandInConfigText(alloc, "command = cmd.exe\n", " pwsh.exe ");
        defer alloc.free(out);
        try testing.expectEqualStrings("command =  pwsh.exe \n", out);
    }
    {
        const out = try setCommandInConfigText(alloc, "theme = dark\n", " pwsh.exe ");
        defer alloc.free(out);
        try testing.expectEqualStrings("theme = dark\ncommand =  pwsh.exe \n", out);
    }
}

test "unit: set command appends after a BOM-only file" {
    const alloc = testing.allocator;
    // A UTF-8 BOM is opaque content, not whitespace: it is preserved
    // byte for byte and the appended entry starts on its own line.
    const out = try setCommandInConfigText(alloc, "\xEF\xBB\xBF", "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("\xEF\xBB\xBF\ncommand = pwsh.exe\n", out);
}

test "unit: set command appends after a CRLF-only file" {
    const alloc = testing.allocator;
    // A file holding a single blank CRLF line: the bare \r line is no
    // key match, the existing line ending is reused as the separator,
    // and nothing is duplicated.
    const out = try setCommandInConfigText(alloc, "\r\n", "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("\r\ncommand = pwsh.exe\n", out);
}
