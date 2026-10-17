//! The KeyRouter entry API (ARCHITECTURE.md ADR-8.2, ADR-6.8). Two inputs
//! reach the router: `app/message_loop.zig` `preTranslate` for
//! `WM_KEYDOWN`/`WM_SYSKEYDOWN` on wmux HWNDs (before `TranslateMessage`)
//! and every WebView2 `AcceleratorKeyPressed` of browser panes and web
//! panels. A consumed key is not translated or dispatched (WebView2:
//! `put_Handled(TRUE)`); an unclaimed key continues to the focused HWND.
//!
//! Stub written by the W1 kickoff interface commit (W1-IF) with the final
//! signatures so W1-6c (web panels, same plan sub-wave) can call
//! `onWebViewAccelerator` before W1-5a lands; W1-5a fills the bodies
//! (contexts, AltGr, chords, bindings) and wires `preTranslate` into the
//! message loop; W1-5b extends the matching (mac translation, hints).
//! Until then nothing is consumed, so every key behaves as before.

const App = @import("../App.zig");
const w32 = @import("../platform/win32.zig");
const wv2 = @import("../platform/webview2.zig");

/// A WebView2 `AcceleratorKeyPressed` event as the router sees it.
pub const WebViewKey = struct {
    /// The host HWND of the browser pane or web panel whose controller
    /// raised the event (identifies the window, tab and panel kind).
    host: w32.HWND,
    /// `ICoreWebView2AcceleratorKeyPressedEventArgs::get_KeyEventKind`.
    kind: wv2.COREWEBVIEW2_KEY_EVENT_KIND,
    /// `get_VirtualKey`.
    vk: u32,
    /// `get_KeyEventLParam` (repeat count, scan code, extended and
    /// previous-state bits, as in `WM_KEYDOWN`).
    lparam: i32,
};

/// Route a keyboard message of the message loop. Returns true when the
/// router consumed it (the caller then skips `TranslateMessage` and
/// `DispatchMessage`). Stub: never consumes (W1-5a).
pub fn preTranslate(app: *App, msg: *const w32.MSG) bool {
    _ = app;
    _ = msg;
    return false;
}

/// Route a WebView2 accelerator key. Returns true when the router
/// consumed it (the caller then sets `put_Handled(TRUE)`). Stub: never
/// consumes, so the page and the existing BrowserPane handling see every
/// key (W1-5a).
pub fn onWebViewAccelerator(app: *App, key: WebViewKey) bool {
    _ = app;
    _ = key;
    return false;
}

test "unit: keys: router stub consumes nothing until W1-5a" {
    const std = @import("std");
    var msg = std.mem.zeroes(w32.MSG);
    msg.message = w32.WM_KEYDOWN;
    // The stubs never dereference the app.
    const app: *App = @ptrFromInt(@alignOf(App));
    try std.testing.expect(!preTranslate(app, &msg));
    try std.testing.expect(!onWebViewAccelerator(app, .{
        .host = @ptrFromInt(0x10),
        .kind = @enumFromInt(0),
        .vk = 0x50,
        .lparam = 0,
    }));
}
