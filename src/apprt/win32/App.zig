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
const updater = @import("features/updater/legacy_check.zig");
const config_files = @import("settings/legacy_config_files.zig");
const app_tasks = @import("app/tasks.zig");
const app_clipboard = @import("app/clipboard.zig");
const app_modal = @import("app/modal.zig");
const broadcast_window = @import("app/broadcast_window.zig");
const hooks = @import("app/hooks.zig");
const app_timers = @import("app/timers.zig");
const message_loop = @import("app/message_loop.zig");
const RuntimeEnv = @import("app/runtime_env.zig").RuntimeEnv;
const perform_action = @import("app/perform_action.zig");
const wv2 = @import("platform/webview2.zig");

const build_config = @import("../../build_config.zig");
const input = @import("../../input.zig");

const log = std.log.scoped(.win32);

/// OpenGL draws happen on the renderer thread, not the app thread.
pub const must_draw_from_app_thread = false;

/// Custom window message used to wake up the message loop so that
/// core_app.tick() is called.
const WM_APP_WAKEUP: u32 = w32.WM_APP + 1;

/// Window class for the top-level container (GDI painting, no CS_OWNDC).
pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WmuxWindow");

/// Window class for terminal surfaces (OpenGL via WGL, needs CS_OWNDC).
pub const TERMINAL_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WmuxTerminal");

/// Window class for the message-only HWND (WM_APP_WAKEUP, WM_APP_TASK,
/// WM_TIMER for app.timers, WM_APP_TRAY).
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

/// Every WMUX_* app input (test mode, path overrides), parsed once in
/// init (app/runtime_env.zig, ARCHITECTURE.md ADR-12.3 / Appendix G).
runtime_env: RuntimeEnv = .{},

/// A message-only window used to receive WM_APP_WAKEUP, app.tasks
/// wakeups and app.timers ticks. This is not a visible window; it just
/// participates in the message loop.
msg_hwnd: ?w32.HWND = null,

/// UI-thread work posted from other threads (ARCHITECTURE.md ADR-1.6).
tasks: app_tasks.Tasks = .{},

/// UI-thread timers on msg_hwnd (ARCHITECTURE.md ADR-1.6).
timers: app_timers.Timers = .{},

/// Hidden top-level window that receives the broadcasts msg_hwnd cannot
/// (logoff/shutdown, power, settings, display changes) and offers them to
/// the app hooks (ARCHITECTURE.md ADR-1.6).
broadcast: broadcast_window.BroadcastWindow = .{},

/// The only clipboard access point (system clipboard, or an in-process
/// fake in WMUX_TEST_MODE).
clipboard: app_clipboard.Clipboard = .{},

/// Modal-loop depth (app/modal.zig).
modal: app_modal.Modal = .{},

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

/// The app.timers timer behind quit_timer_state == .active (0 = none).
quit_timer: app_timers.TimerId = 0,

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

/// Per-slot app.timers cleanup timer of each in-flight desktop balloon
/// (0 = none).
desktop_notif_timers: [notifications.NOTIF_DESKTOP_SLOTS]app_timers.TimerId = @splat(0),

/// The update balloon's app.timers cleanup timer (0 = none).
update_balloon_timer: app_timers.TimerId = 0,

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
/// posts each *ipc.Request to this UI thread through app.tasks, so all
/// browser driving happens on this UI thread. Stopped before msg_hwnd
/// is destroyed in terminate(). Null if startup failed (e.g. a stale
/// pipe of the same name): IPC is then simply unavailable.
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
pub const openConfigFile = config_files.openConfigFile;
pub const openConfigFolder = config_files.openConfigFolder;
pub const setDefaultShell = config_files.setDefaultShell;

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
        .runtime_env = RuntimeEnv.load(alloc),
    };
    errdefer self.runtime_env.deinit(alloc);
    self.clipboard.init(alloc, self.runtime_env.test_mode);
    errdefer self.clipboard.deinit();

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

    // app.tasks and app.timers deliver to msg_hwnd from here on.
    self.tasks.init(alloc, self.msg_hwnd);
    self.timers.init(alloc, self.msg_hwnd);

    // The hidden broadcast window (never shown) for broadcast-only
    // messages; failure only disables those hooks.
    self.broadcast.create(self, hinstance);

    // Start the agent IPC server now that msg_hwnd exists (the pipe
    // thread posts requests to it). A failure here only disables the
    // `ghostty +browser` CLI, so log and continue.
    legacy_pipe.start(self);

    // Start the periodic sidebar-metadata refresh (git branch / ports /
    // PR). The timer fires on this msg_hwnd; each tick spawns a worker
    // thread for the actual git/gh/TCP-table work.
    meta.startRefreshTimer(self);

    // Register global hotkey for quick terminal (if configured).
    self.registerGlobalHotkey();

    // Check for updates in the background (non-blocking).
    updater.startUpdateCheck(self);
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
    while (true) {
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

        if (message_loop.preTranslate(self, &msg)) continue;
        if (!message_loop.skipTranslate(self, &msg)) _ = w32.TranslateMessage(&msg);
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
    // callback posts app.tasks to msg_hwnd, and stop() joins that thread,
    // so no request can be posted afterward. Any request still queued is
    // destroyed (unanswered) by tasks.deinit below; if one is mid-flight
    // in msgWndProc it completes before terminate() proceeds
    // (single-threaded UI). sendOk/sendError after stop() is impossible
    // because the GUI thread is here, not in msgWndProc.
    if (self.ipc_server) |server| {
        server.stop();
        self.ipc_server = null;
    }

    // Free the agent session store (owned session-id strings). Safe after
    // the IPC server stopped: no pipe-thread callback can still touch it.
    self.session_store.deinit();

    // Kill every app timer and destroy every task still queued (without
    // running it) while msg_hwnd is alive. A detached worker posting
    // after this point has its task destroyed on arrival.
    self.timers.deinit();
    self.tasks.deinit();

    if (self.msg_hwnd) |hwnd| {
        // Clear GWLP_USERDATA before destroying so msgWndProc sees
        // userdata=0 and falls through to DefWindowProc for any
        // messages during destruction (e.g. WM_DESTROY).
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.msg_hwnd = null;
    }

    // The broadcast window dispatches app hooks; tear it down with the
    // other app-level windows, before any state they touch.
    self.broadcast.destroy(self.hinstance);

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
    self.runtime_env.deinit(alloc);
    self.clipboard.deinit();

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
    return perform_action.perform(self, target, action, value);
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

/// Start the quit timer. Called when the last surface closes.
pub fn startQuitTimer(self: *App) void {
    // Cancel any existing timer first.
    self.stopQuitTimer();

    // Check if we should quit at all.
    if (!self.config.@"quit-after-last-window-closed") return;

    // If a delay is configured, start a one-shot app timer.
    if (self.config.@"quit-after-last-window-closed-delay") |v| {
        const ms = v.asMilliseconds();
        self.quit_timer = self.timers.start(ms, .{}, 0, onQuitTimer);
        if (self.quit_timer != 0) self.quit_timer_state = .active;
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
            self.timers.stop(self.quit_timer);
            self.quit_timer = 0;
            self.quit_timer_state = .off;
        },
    }
}

/// app.timers callback: the quit-after-last-window-closed delay elapsed.
fn onQuitTimer(self: *App, ctx: usize) void {
    _ = ctx;
    self.quit_timer = 0;
    self.quit_timer_state = .expired;
    self.quit_requested = true;
    w32.PostQuitMessage(0);
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

    // Work posted by other threads (IPC requests, metadata results, the
    // update check, the default-shell writer): drain the whole batch.
    if (msg == app_tasks.WM_APP_TASK) {
        app.tasks.drain(app);
        return 0;
    }

    // Every msg_hwnd timer is an app.timers timer (quit delay, quick
    // terminal animation, metadata refresh, balloon cleanups).
    if (msg == w32.WM_TIMER and app.timers.dispatch(app, wparam)) return 0;

    // Everything else is offered to the app hooks (e.g. the tray-balloon
    // callback hooks.WM_APP_TRAY: a click on the update notification
    // opens the GitHub releases page, a click on a desktop notification
    // jumps to the surface that produced it).
    if (hooks.dispatchApp(&hooks.app_hooks, app, msg, wparam, lparam)) |result| return result;

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
    _ = config_files;
    _ = app_tasks;
    _ = app_timers;
    _ = hooks;
    _ = @import("app/runtime_env.zig");
    _ = @import("app/paths.zig");
    _ = app_clipboard;
    _ = app_modal;
}
