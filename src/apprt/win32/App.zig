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
const ipc = @import("rpc/compat/legacy_json.zig");
const legacy_pipe = @import("rpc/server/legacy_pipe.zig");
const notifications = @import("features/notifications/api.zig");
const Pane = @import("Pane.zig");
const PaneContainer = @import("PaneContainer.zig");
const QuickTerminal = @import("features/quick_terminal/QuickTerminal.zig");
const SessionState = @import("SessionState.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const taskbar = @import("platform/taskbar.zig");
const w32 = @import("platform/win32.zig");
const web_env = @import("web/env.zig");
const meta = @import("features/meta/api.zig");
const wv2 = @import("platform/webview2.zig");

const build_config = @import("../../build_config.zig");
const input = @import("../../input.zig");

const log = std.log.scoped(.win32);

/// OpenGL draws happen on the renderer thread, not the app thread.
pub const must_draw_from_app_thread = false;

/// Custom window message used to wake up the message loop so that
/// core_app.tick() is called.
const WM_APP_WAKEUP: u32 = w32.WM_APP + 1;

/// Posted by the setDefaultShell worker thread after the config file has
/// been written successfully. Signals the UI thread to perform a
/// reload_config so the new command takes effect. No payload.
const WM_APP_SHELL_SET: u32 = w32.WM_APP + 6;

/// Timer ID for the quit-after-last-window-closed delay.
const QUIT_TIMER_ID: usize = 1;

/// Window class for the top-level container (GDI painting, no CS_OWNDC).
pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WmuxWindow");

/// Window class for terminal surfaces (OpenGL via WGL, needs CS_OWNDC).
pub const TERMINAL_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WmuxTerminal");

/// Window class for the message-only HWND (WM_APP_WAKEUP, WM_TIMER).
pub const MSG_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WmuxMsg");

/// Window class for browser pane host HWNDs (WebView2 + address bar).
/// Must NOT be the terminal class: App.run skips TranslateMessage for
/// the terminal class atom, which would break the address-bar Edit.
pub const BROWSER_HOST_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WmuxBrowserHost");

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
desktop_notifs: [notifications.NOTIF_DESKTOP_SLOTS]?notifications.DesktopNotif = @splat(null),

/// Next desktop-notification slot to use (rotates through the range).
desktop_notif_next: usize = 0,

/// Ring buffer of recent notifications listed in the sidebar's
/// notifications panel (newest first). Slots are nulled when their
/// window is destroyed or the log is cleared; the unread counter is
/// drawn as the badge on the sidebar footer's bell icon.
notif_log: notifications.NotifRing(notifications.NotifEntry, notifications.NOTIF_LOG_CAP) = .{},

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
/// PostMessageW's each *ipc.Request to msg_hwnd
/// (legacy_pipe.WM_APP_IPC_REQUEST),
/// so all browser driving happens on this UI thread. Stopped before
/// msg_hwnd is destroyed in terminate(). Null if startup failed (e.g.
/// a stale pipe of the same name): IPC is then simply unavailable.
ipc_server: ?*legacy_pipe.Server = null,

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

// ---------------------------------------------------------------------------
// W0 aliases (ARCHITECTURE.md §0.4): moved functions keep their existing
// `app.f(...)` call sites in Window.zig/Sidebar.zig compiling. New code
// MUST NOT add aliases; call the owning module directly.
// ---------------------------------------------------------------------------

pub const notifAt = notifications.notifAt;
pub const notifCount = notifications.notifCount;
pub const markNotifsRead = notifications.markNotifsRead;
pub const markNotifEntryRead = notifications.markNotifEntryRead;
pub const clearNotifs = notifications.clearNotifs;
pub const jumpToSurface = notifications.jumpToSurface;
pub const dropDesktopNotifsForWindow = notifications.dropDesktopNotifsForWindow;
pub const refreshWorkspaceMetadataNow = meta.refreshWorkspaceMetadataNow;
pub const requestWebView2Env = web_env.requestWebView2Env;

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
    legacy_pipe.start(self);

    // Start the periodic sidebar-metadata refresh (git branch / ports /
    // PR). The timer fires on this msg_hwnd; each tick spawns a worker
    // thread for the actual git/gh/TCP-table work.
    _ = w32.SetTimer(self.msg_hwnd.?, meta.WS_META_TIMER_ID, meta.WS_META_INTERVAL_MS, null);

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

            // Ctrl+W inside WebView2 content: the AcceleratorKeyPressed
            // COM callback is unreliable on some WebView2 versions, so
            // intercept the key here in the message loop. Walk up the
            // parent chain from the focused HWND; if any ancestor is a
            // browser host, post the deferred close message to it.
            if (vk == 0x57 and w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0 and
                !(w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0))
            {
                const found_host = self.findBrowserHostAncestor(msg.hwnd.?);
                if (found_host) |host| {
                    _ = w32.PostMessageW(host, BrowserPane.WM_BROWSER_CLOSE, 0, 0);
                    continue :loop;
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
        _ = w32.KillTimer(hwnd, meta.WS_META_TIMER_ID);
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
                        l.ws == parent_window.activeWorkspace() and l.container == l.ws.focused_container and l.tab == l.container.active_tab
                    else
                        false;
                    if (!active or !foreground) {
                        parent_window.setTabStatusForSurface(rt_surface, .bell);
                        const title: []const u16 = if (loc) |l|
                            l.container.tab_titles[l.tab][0..l.container.tab_title_lens[l.tab]]
                        else
                            std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
                        notifications.pushNotif(
                            self,
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
            notifications.showDesktopNotification(self, target, value);
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
                        l.container.tab_titles[l.tab][0..l.container.tab_title_lens[l.tab]]
                    else
                        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
                    notifications.pushNotif(
                        self,
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
                            loc.ws.focused_container = loc.container;
                            if (loc.tab != loc.container.active_tab) win.selectTabIndex(loc.tab);
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
                    const dir: SplitTree(PaneContainer).Split.Direction = switch (value) {
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
                    const rename_container = pw.activeWorkspace().focusedContainerOrFirst() orelse return true;
                    pw.startTabRename(rename_container.active_tab);
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
            _ = notifications.toggleNotifRead(self, 0);
            return true;
        },

        .mark_oldest_unread_jump => {
            _ = notifications.markOldestUnreadAndJumpNext(self);
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
///
/// The file I/O (read + transform + atomic write) is performed on a
/// detached worker thread so the UI thread is never blocked by slow
/// disks. On success the worker posts WM_APP_SHELL_SET back to
/// msg_hwnd, where the UI thread triggers a reload_config.
pub fn setDefaultShell(self: *App, value: []const u8) void {
    const alloc = self.core_app.alloc;

    // resolveConfigFile creates the file (with the template) when it is
    // missing, so the read below always sees a real file. This is a
    // quick stat + possible create of a small template — fast enough for
    // the UI thread and required before the worker can read the file.
    const path = self.resolveConfigFile() orelse return;

    const value_copy = alloc.dupe(u8, value) catch {
        alloc.free(path);
        return;
    };

    const ctx = alloc.create(ShellSetCtx) catch {
        alloc.free(path);
        alloc.free(value_copy);
        return;
    };
    ctx.* = .{
        .alloc = alloc,
        .path = path,
        .value = value_copy,
        .msg_hwnd = self.msg_hwnd,
    };

    const thread = std.Thread.spawn(.{}, shellSetWorker, .{ctx}) catch {
        alloc.free(path);
        alloc.free(value_copy);
        alloc.destroy(ctx);
        return;
    };
    thread.detach();
}

const ShellSetCtx = struct {
    alloc: Allocator,
    path: []const u8,
    value: []const u8,
    msg_hwnd: ?w32.HWND,
};

/// Worker-thread entry for setDefaultShell: reads the config, transforms
/// it, writes it back atomically, then signals the UI thread. Touches
/// only its owned ctx and the filesystem — never live App/Window state.
fn shellSetWorker(ctx: *ShellSetCtx) void {
    const alloc = ctx.alloc;
    defer {
        alloc.free(ctx.path);
        alloc.free(ctx.value);
        alloc.destroy(ctx);
    }

    const source = std.fs.cwd().readFileAlloc(
        alloc,
        ctx.path,
        16 * 1024 * 1024,
    ) catch |err| {
        log.err("set default shell: failed to read config={s} err={}", .{ ctx.path, err });
        return;
    };
    defer alloc.free(source);

    const updated = setCommandInConfigText(alloc, source, ctx.value) catch |err| {
        log.err("set default shell: failed to build config text err={}", .{err});
        return;
    };
    defer alloc.free(updated);

    writeFileAtomic(alloc, ctx.path, updated) catch |err| {
        log.err("set default shell: failed to write config={s} err={}", .{ ctx.path, err });
        return;
    };

    log.info("set default shell: wrote command={s} to {s}", .{ ctx.value, ctx.path });

    // Signal the UI thread to reload_config. No payload needed.
    if (ctx.msg_hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, WM_APP_SHELL_SET, 0, 0);
    }
}

/// UI-thread handler for WM_APP_SHELL_SET: the worker finished writing
/// the config file, so reload it.
fn handleShellSet(self: *App) void {
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

/// Walk up the parent chain from `hwnd` looking for a browser host
/// window (class atom == browser_host_class_atom). Returns the host
/// HWND if found, null otherwise. Stops after 16 levels to avoid
/// infinite loops on circular parent chains.
fn findBrowserHostAncestor(self: *const App, hwnd: w32.HWND) ?w32.HWND {
    if (self.browser_host_class_atom == 0) return null;
    var cur: ?w32.HWND = hwnd;
    var depth: u32 = 0;
    while (cur) |h| : (depth += 1) {
        if (depth > 16) break;
        const atom: u16 = @truncate(w32.GetClassLongW(h, w32.GCW_ATOM));
        if (atom != 0 and atom == self.browser_host_class_atom) return h;
        cur = w32.GetParent(h);
    }
    return null;
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
pub const WM_APP_TRAY: u32 = w32.WM_APP + 3;

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

/// Notify the core app of a tick.
fn tick(self: *App) void {
    self.core_app.tick(self) catch |err| {
        log.err("core app tick error: {}", .{err});
    };
}

/// Broadcast a key event (WM_KEYDOWN/WM_KEYUP) from the focused surface
/// to all other tabs in the same PaneContainer when synchronized input is
/// active. Skipped when the surface is already receiving a broadcast (the
/// sync_broadcast guard prevents infinite loops).
fn broadcastKeyEvent(source: *Surface, wparam: usize, lparam: isize, action: input.Action) void {
    const pw = source.parent_window;
    const ws = pw.activeWorkspace();
    const container = ws.focusedContainerOrFirst() orelse return;
    if (!container.tab_synchronized[container.active_tab]) return;

    // In the new model each tab is a single pane, so "synchronized"
    // broadcasts across all tabs of this container.
    for (container.tabs[0..container.tab_count]) |tab_pane| {
        const sibling = tab_pane.surface() orelse continue;
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
    const container = ws.focusedContainerOrFirst() orelse return;
    if (!container.tab_synchronized[container.active_tab]) return;

    for (container.tabs[0..container.tab_count]) |tab_pane| {
        const sibling = tab_pane.surface() orelse continue;
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
                        loc.ws.focused_container = loc.container;
                    }
                }
                win.repaintDividers();
                win.invalidateTabBar();
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

    if (msg == legacy_pipe.WM_APP_IPC_REQUEST) {
        // lparam is the *ipc.Request handed over by the pipe thread; we
        // own it now and legacy_pipe.handleRequest destroys it.
        const req: *ipc.Request = @ptrFromInt(@as(usize, @bitCast(lparam)));
        legacy_pipe.handleRequest(app, req);
        return 0;
    }

    if (msg == meta.WM_APP_WS_META) {
        // lparam is the *meta.Result handed over by a worker thread; we
        // own it now and applyWorkspaceMetadata frees it.
        const result: *meta.Result = @ptrFromInt(@as(usize, @bitCast(lparam)));
        meta.applyWorkspaceMetadata(app, result);
        return 0;
    }

    if (msg == WM_APP_SHELL_SET) {
        // The setDefaultShell worker finished writing the config file;
        // trigger a reload on the UI thread.
        app.handleShellSet();
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
        } else if (wparam >= notifications.NOTIF_DESKTOP_UID_BASE and
            wparam < notifications.NOTIF_DESKTOP_UID_BASE + notifications.NOTIF_DESKTOP_SLOTS)
        {
            notifications.onDesktopNotifClick(app, wparam - notifications.NOTIF_DESKTOP_UID_BASE);
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
    if (msg == w32.WM_TIMER and wparam == meta.WS_META_TIMER_ID) {
        meta.refreshWorkspaceMetadata(app);
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
        wparam >= notifications.NOTIF_DESKTOP_TIMER_BASE and
        wparam < notifications.NOTIF_DESKTOP_TIMER_BASE + notifications.NOTIF_DESKTOP_SLOTS)
    {
        notifications.clearDesktopNotif(app, wparam - notifications.NOTIF_DESKTOP_TIMER_BASE);
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
    _ = @import("features/meta/probes.zig");
    _ = agent_session;
    // The ipc.zig split (W0-A1): keep every moved test collected.
    _ = ipc;
    _ = legacy_pipe;
    _ = @import("features/workspaces/worktree.zig");
    _ = @import("features/status/log_ring.zig");
    _ = @import("features/notifications/legacy_ring.zig");
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
