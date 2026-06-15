//! A browser pane: WebView2 content hosted in a split-tree leaf next
//! to terminal surfaces. The pane owns a WS_CHILD host HWND (class
//! GhosttyBrowserHost — deliberately NOT the terminal class, whose
//! atom makes App.run skip TranslateMessage) containing an address-bar
//! Edit strip on top and the WebView2 controller below it.
//!
//! WebView2 creation is asynchronous (environment singleton on App,
//! then per-pane controller). The pane holds one in-flight ref on its
//! wrapping Pane from startCreation() until the creation chain ends,
//! so completion callbacks never touch freed memory; completions check
//! `state == .closing` and Close+drop the controller immediately when
//! the pane was torn down mid-flight.
const BrowserPane = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Pane = @import("Pane.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const wv2 = @import("webview2.zig");

const log = std.log.scoped(.win32);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Child window ID for the address-bar edit control (search=100,
/// palette=200, rename=300).
pub const ADDRESS_EDIT_ID: u16 = 400;

/// Address-bar strip height in unscaled pixels.
const ADDRESS_BAR_BASE: f32 = 28.0;

/// Width (unscaled px) of the close-'x' button sitting at the right edge
/// of the address-bar strip. Mirrors the sidebar row close band so the
/// affordance feels identical across chrome surfaces.
const CLOSE_BASE: f32 = 24.0;

/// Max URL length in UTF-16 code units.
const URL_MAX: usize = 2048;

const ControllerHandler = wv2.ControllerCompletedHandler(BrowserPane);
const NavHandler = wv2.NavigationCompletedEventHandler(BrowserPane);
const TitleHandler = wv2.DocumentTitleChangedEventHandler(BrowserPane);
const FocusHandler = wv2.FocusChangedEventHandler(BrowserPane);

/// The parent App.
app: *App,

/// The Window containing this pane's tab.
parent_window: *Window,

/// Stable id handed out over the agent IPC (`ghostty +browser`) so
/// later navigate/eval commands can target this exact pane. Assigned
/// from App.next_browser_id in create(); 0 only in the impossible
/// window before create() finishes initializing the struct.
ipc_id: u32 = 0,

/// The Pane wrapping this browser in its tab's SplitTree. Set by
/// Pane.createBrowser immediately after create(); valid until the
/// pane unrefs to zero (which destroys us). Null in the window
/// between create() (which publishes us in the host HWND's
/// GWLP_USERDATA) and Pane.createBrowser — messages arriving in that
/// gap must not dereference it.
pane: ?*Pane = null,

/// The WS_CHILD host window (GhosttyBrowserHost class).
host_hwnd: ?w32.HWND = null,

/// The address-bar Edit control (child of host_hwnd).
address_edit: ?w32.HWND = null,

/// Font for the address-bar Edit (deleted on destroy).
address_font: ?*anyopaque = null,

/// True while the cursor is over the address-bar close-'x' button, so
/// it paints red (the tab/sidebar close-hover color) instead of gray.
close_hovered: bool = false,

/// True between a left-press and left-release that both land on the
/// close-'x': the actual close fires on release only when the press
/// started on the button (Win32 button convention), so a press-drag-off
/// doesn't close the pane.
close_pressed: bool = false,

/// Async-creation lifecycle. `closing` is set by destroy() and by the
/// host's WM_DESTROY (parent died while creation was in flight).
state: enum { creating, ready, failed, closing } = .creating,

controller: ?*wv2.ICoreWebView2Controller = null,
webview: ?*wv2.ICoreWebView2 = null,

/// Event registration tokens (removed in destroy()).
nav_token: wv2.EventRegistrationToken = .{},
title_token: wv2.EventRegistrationToken = .{},
focus_token: wv2.EventRegistrationToken = .{},

/// URL to navigate to once the webview is ready (UTF-16, not
/// NUL-terminated; navigatePending appends the NUL).
pending_url: [URL_MAX + 1]u16 = undefined,
pending_url_len: usize = 0,

/// UTF-8 document title reported to the Window (kept so the slice
/// passed to onPaneTitleChanged has stable backing during the call).
title_buf: [512]u8 = undefined,

/// Create the host window and address bar. Does NOT start WebView2
/// creation: call startCreation() after the pane back-pointer exists
/// and a SplitTree owns it (the async race guard refs the pane).
pub fn create(alloc: Allocator, app: *App, parent: *Window) !*BrowserPane {
    const parent_hwnd = parent.hwnd orelse return error.Win32Error;

    const self = try alloc.create(BrowserPane);
    errdefer alloc.destroy(self);
    self.* = .{
        .app = app,
        .parent_window = parent,
        .ipc_id = app.next_browser_id,
    };
    app.next_browser_id += 1;

    const blank = L("about:blank");
    @memcpy(self.pending_url[0..blank.len], blank);
    self.pending_url_len = blank.len;

    const sr = parent.surfaceRect();
    const host = w32.CreateWindowExW(
        0,
        App.BROWSER_HOST_CLASS_NAME,
        L(""),
        w32.WS_CHILD,
        sr.left,
        sr.top,
        @intCast(@max(sr.right - sr.left, 1)),
        @intCast(@max(sr.bottom - sr.top, 1)),
        parent_hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.host_hwnd = host;
    // Children (the Edit) are destroyed along with the host.
    errdefer {
        _ = w32.SetWindowLongPtrW(host, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(host);
        self.host_hwnd = null;
    }
    _ = w32.SetWindowLongPtrW(host, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Address-bar Edit. Real geometry is applied by layoutChildren on
    // the first WM_SIZE from layoutSplits. Its width reserves the
    // close-'x' column at the right edge (cw + a pad gap).
    const bar_h = self.addressBarHeight();
    const pad = self.addressBarPad();
    const edit = w32.CreateWindowExW(
        0,
        L("EDIT"),
        L(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        pad,
        pad,
        editWidthAt(sr.right - sr.left, parent.scale),
        @max(bar_h - pad * 2, 1),
        host,
        @ptrFromInt(@as(usize, ADDRESS_EDIT_ID)),
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.address_edit = edit;

    _ = w32.SetWindowTheme(edit, L("DarkMode_Explorer"), null);
    self.address_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(15.0 * parent.scale))),
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
        L("Segoe UI"),
    );
    if (self.address_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    return self;
}

/// Begin async WebView2 creation. The wrapping pane must be owned by a
/// SplitTree by now; one pane ref is held for the whole creation chain
/// and dropped when the chain ends (env failure, controller failure,
/// or controller completion).
pub fn startCreation(self: *BrowserPane) void {
    const alloc = self.app.core_app.alloc;
    const pane = self.pane orelse return;
    // Pane.ref never fails (the allocator parameter is unused).
    _ = pane.ref(alloc) catch unreachable;
    self.app.requestWebView2Env(self);
}

/// Full teardown, called from Pane.unref at refcount zero. Mirrors the
/// WGL ordering rule: the controller is Closed and the host HWND
/// destroyed before the parent Window's teardown destroys the parent.
pub fn destroy(self: *BrowserPane, alloc: Allocator) void {
    self.state = .closing;
    if (self.webview) |webview| {
        webview.removeNavigationCompleted(self.nav_token) catch {};
        webview.removeDocumentTitleChanged(self.title_token) catch {};
        webview.release();
        self.webview = null;
    }
    if (self.controller) |controller| {
        controller.removeGotFocus(self.focus_token) catch {};
        controller.close() catch {};
        controller.release();
        self.controller = null;
    }
    if (self.address_font) |f| {
        _ = w32.DeleteObject(f);
        self.address_font = null;
    }
    if (self.host_hwnd) |host| {
        _ = w32.SetWindowLongPtrW(host, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(host);
        self.host_hwnd = null;
        self.address_edit = null;
    }
    alloc.destroy(self);
}

/// Environment-creation completion (called by App, possibly
/// synchronously when the singleton already exists). Consumes the
/// in-flight pane ref on every path except the controller-creation
/// continuation, which carries it to onControllerCreated.
pub fn onEnvironment(self: *BrowserPane, env_opt: ?*wv2.ICoreWebView2Environment) void {
    const alloc = self.app.core_app.alloc;
    const pane = self.pane orelse return;
    if (self.state == .closing) {
        pane.unref(alloc);
        return;
    }
    // The pane was closed out of every tab while environment creation
    // was pending: the in-flight ref is the only thing keeping it
    // alive. Drop it (freeing the pane and this BrowserPane) instead
    // of building a controller for a zombie host. parent_window is
    // valid whenever state != .closing (the host's WM_DESTROY flags
    // closing before the window can go away).
    if (self.parent_window.findLoc(pane) == null) {
        pane.unref(alloc);
        return;
    }
    const env = env_opt orelse {
        log.warn("browser pane: WebView2 environment unavailable", .{});
        self.setFailed();
        pane.unref(alloc);
        return;
    };
    const host = self.host_hwnd orelse {
        pane.unref(alloc);
        return;
    };
    const handler = ControllerHandler.create(alloc, self, onControllerCreated) catch {
        log.warn("browser pane: oom creating controller handler", .{});
        self.setFailed();
        pane.unref(alloc);
        return;
    };
    env.createController(host, handler) catch {
        handler.unref();
        log.warn("browser pane: CreateCoreWebView2Controller failed", .{});
        self.setFailed();
        pane.unref(alloc);
        return;
    };
    handler.unref();
}

fn onControllerCreated(
    self: *BrowserPane,
    error_code: wv2.HRESULT,
    controller_opt: ?*wv2.ICoreWebView2Controller,
) void {
    const alloc = self.app.core_app.alloc;
    const pane = self.pane orelse {
        if (controller_opt) |c| c.close() catch {};
        return;
    };
    // End of the creation chain: drop the in-flight ref. This may free
    // self (and the pane) when the pane closed during creation, so it
    // must be the very last thing that runs.
    defer pane.unref(alloc);

    const controller = controller_opt orelse {
        log.warn("browser pane: controller creation failed hr=0x{x:0>8}", .{
            @as(u32, @bitCast(error_code)),
        });
        if (self.state != .closing) self.setFailed();
        return;
    };
    if (self.state == .closing) {
        // Pane was torn down while creation was in flight: shut the
        // browser process down now; the callee-owned reference is
        // released by WebView2 after Invoke returns.
        controller.close() catch {};
        return;
    }
    if (self.parent_window.findLoc(pane) == null) {
        // The tab closed while controller creation was in flight; the
        // host HWND survived (the in-flight ref kept the pane alive)
        // so state is still .creating. Don't wire up a zombie: shut
        // the browser process down and let the deferred unref free
        // the pane and this BrowserPane.
        controller.close() catch {};
        return;
    }

    controller.addRef();
    self.controller = controller;

    const webview = controller.getCoreWebView2() catch {
        controller.close() catch {};
        controller.release();
        self.controller = null;
        log.warn("browser pane: get_CoreWebView2 failed", .{});
        self.setFailed();
        return;
    };
    self.webview = webview;

    // GotFocus is the authoritative active-pane signal: clicks inside
    // the webview never reach the host HWND.
    if (FocusHandler.create(alloc, self, onGotFocus)) |h| {
        defer h.unref();
        self.focus_token = controller.addGotFocus(h) catch .{};
    } else |_| {}
    if (NavHandler.create(alloc, self, onNavigationCompleted)) |h| {
        defer h.unref();
        self.nav_token = webview.addNavigationCompleted(h) catch .{};
    } else |_| {}
    if (TitleHandler.create(alloc, self, onDocumentTitleChanged)) |h| {
        defer h.unref();
        self.title_token = webview.addDocumentTitleChanged(h) catch .{};
    } else |_| {}

    self.state = .ready;
    self.updateBounds();
    if (self.host_hwnd) |host| {
        controller.putIsVisible(w32.IsWindowVisible_(host) != 0) catch {};
    }
    self.navigatePending();
}

fn onGotFocus(self: *BrowserPane, sender: ?*wv2.ICoreWebView2Controller, args: ?*wv2.IUnknown) void {
    _ = sender;
    _ = args;
    if (self.state == .closing) return;
    const pane = self.pane orelse return;
    const win = self.parent_window;
    if (win.closing) return;
    // Only record the pane as active for the tab that actually owns
    // it; a stale focus event must never plant a dangling pointer in
    // another tab's slot.
    const loc = win.findLoc(pane) orelse return;
    loc.ws.tab_active_pane[loc.tab] = pane;
}

fn onNavigationCompleted(
    self: *BrowserPane,
    sender: ?*wv2.ICoreWebView2,
    args_opt: ?*wv2.ICoreWebView2NavigationCompletedEventArgs,
) void {
    if (self.state == .closing) return;
    if (args_opt) |args| {
        const success = args.getIsSuccess() catch false;
        if (!success) {
            const status = args.getWebErrorStatus() catch -1;
            log.warn("browser navigation failed web_error_status={}", .{status});
        }
    }
    // Reflect the final URI in the address bar — unless the user is
    // typing in it (don't clobber a half-entered URL).
    const webview = sender orelse (self.webview orelse return);
    const uri = webview.getSource() catch return;
    defer wv2.CoTaskMemFree(uri);
    if (self.address_edit) |edit| {
        if (w32.GetFocus() != edit) {
            _ = w32.SetWindowTextW(edit, uri);
        }
    }
}

fn onDocumentTitleChanged(self: *BrowserPane, sender: ?*wv2.ICoreWebView2, args: ?*wv2.IUnknown) void {
    _ = args; // Always null per the IDL.
    if (self.state == .closing) return;
    const pane = self.pane orelse return;
    const webview = sender orelse (self.webview orelse return);
    const title16 = webview.getDocumentTitle() catch return;
    defer wv2.CoTaskMemFree(title16);
    // The title is website-controlled and unbounded; utf16LeToUtf8
    // ASSERTS the destination is large enough (no DestTooSmall error
    // in std 0.15), so cap the input before converting. One UTF-16
    // code unit expands to at most 3 UTF-8 bytes (surrogate pairs are
    // 2 units -> 4 bytes, which is smaller per unit).
    const span = capUtf16(std.mem.span(title16), (self.title_buf.len - 1) / 3);
    const len = std.unicode.utf16LeToUtf8(self.title_buf[0 .. self.title_buf.len - 1], span) catch return;
    self.title_buf[len] = 0;
    self.parent_window.onPaneTitleChanged(pane, self.title_buf[0..len :0]);
}

/// Cap a UTF-16 string at `max_units` code units without leaving a
/// malformed surrogate at the cut: a dangling high surrogate (its low
/// half was cut off) or an unpaired low surrogate at the boundary
/// would make the whole utf16LeToUtf8 conversion fail (and the title
/// be dropped). A low surrogate that completes a pair is kept.
fn capUtf16(span: []const u16, max_units: usize) []const u16 {
    if (span.len <= max_units) return span;
    var capped = span[0..max_units];
    if (capped.len > 0) {
        const last = capped[capped.len - 1];
        if (last >= 0xD800 and last <= 0xDBFF) {
            // High surrogate at the cut: its low half was cut off.
            capped = capped[0 .. capped.len - 1];
        } else if (last >= 0xDC00 and last <= 0xDFFF) {
            // Low surrogate at the cut: keep it only when the unit
            // before it is the high half of its pair; a lone low
            // surrogate is just as malformed as a dangling high one.
            const paired = capped.len >= 2 and
                capped[capped.len - 2] >= 0xD800 and capped[capped.len - 2] <= 0xDBFF;
            if (!paired) capped = capped[0 .. capped.len - 1];
        }
    }
    return capped;
}

/// Navigate to the address bar's text. Prepends https:// when the
/// text has no scheme. Stashes the URL when the webview isn't ready.
pub fn navigateFromAddressBar(self: *BrowserPane) void {
    const edit = self.address_edit orelse return;
    var wbuf: [URL_MAX]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, @intCast(wbuf.len)));
    if (wlen == 0) return;

    const scheme = L("https://");
    const has_scheme = std.mem.indexOf(u16, wbuf[0..wlen], L("://")) != null;
    var url_buf: [URL_MAX + scheme.len + 1]u16 = undefined;
    var url_len: usize = 0;
    if (!has_scheme) {
        @memcpy(url_buf[0..scheme.len], scheme);
        url_len = scheme.len;
    }
    @memcpy(url_buf[url_len .. url_len + wlen], wbuf[0..wlen]);
    url_len += wlen;
    url_buf[url_len] = 0;

    if (self.state == .ready) {
        if (self.webview) |webview| {
            webview.navigate(@ptrCast(&url_buf)) catch |err| {
                log.warn("browser navigate failed: {}", .{err});
                return;
            };
            self.focusWebView();
            return;
        }
    }
    // Not ready yet: replace the pending URL.
    const n = @min(url_len, URL_MAX);
    @memcpy(self.pending_url[0..n], url_buf[0..n]);
    self.pending_url_len = n;
}

/// Heap context carried through one async ExecuteScript so its
/// completion can answer the originating IPC request. WebView2 delivers
/// the completion on this same UI thread, so no locking is needed; the
/// struct is freed in the completion (the one and only callback).
const IpcEval = struct {
    app: *App,
    ipc_id: u64,
};

const IpcEvalHandler = wv2.ExecuteScriptCompletedHandler(IpcEval);

/// Run `js` for an agent IPC `eval` request and answer that request
/// (id `ipc_id`) when the async result arrives. The webview's
/// ExecuteScript result is already JSON, so it's forwarded verbatim as
/// the response `data`. Errors (no webview, OOM, ExecuteScript refusal)
/// are answered synchronously here. `js_w` must be NUL-terminated.
pub fn evalForIpc(self: *BrowserPane, ipc_id: u64, js_w: [*:0]const u16) void {
    const server = self.app.ipc_server orelse return;
    const alloc = self.app.core_app.alloc;

    if (self.state != .ready or self.webview == null) {
        server.sendError(ipc_id, "browser pane is not ready") catch {};
        return;
    }
    const webview = self.webview.?;

    const ctx = alloc.create(IpcEval) catch {
        server.sendError(ipc_id, "out of memory") catch {};
        return;
    };
    ctx.* = .{ .app = self.app, .ipc_id = ipc_id };

    const handler = IpcEvalHandler.create(alloc, ctx, onIpcEvalCompleted) catch {
        alloc.destroy(ctx);
        server.sendError(ipc_id, "out of memory") catch {};
        return;
    };
    defer handler.unref();

    webview.executeScript(js_w, handler) catch {
        alloc.destroy(ctx);
        server.sendError(ipc_id, "ExecuteScript failed") catch {};
    };
}

fn onIpcEvalCompleted(ctx: *IpcEval, error_code: wv2.HRESULT, result: ?wv2.LPCWSTR) void {
    const app = ctx.app;
    const ipc_id = ctx.ipc_id;
    const alloc = app.core_app.alloc;
    defer alloc.destroy(ctx);

    // The server may already be torn down (app quitting) — drop silently.
    const server = app.ipc_server orelse return;

    if (error_code != wv2.S_OK or result == null) {
        server.sendError(ipc_id, "script evaluation failed") catch {};
        return;
    }

    // result is already JSON (the script's return value JSON-encoded).
    // Convert UTF-16 → UTF-8 and forward it as the response data.
    const span = std.mem.span(result.?);
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, span) catch {
        server.sendError(ipc_id, "out of memory") catch {};
        return;
    };
    defer alloc.free(utf8);
    server.sendOk(ipc_id, utf8) catch {};
}

// ---------------------------------------------------------------------------
// Agent IPC: Chrome DevTools Protocol verbs (snapshot / click / fill)
// ---------------------------------------------------------------------------
//
// Each verb chains several CallDevToolsProtocolMethod calls. WebView2
// delivers every completion on this UI thread, so the chain is a simple
// state machine driven from a single completion handler: each step
// issues the next CDP call carrying the same heap context, and the last
// step answers the IPC request and frees the context. Errors at any step
// answer the request (sendError) and free.

/// One in-flight CDP verb. Allocated by startCdp, freed exactly once in
/// finishOk/finishErr. The webview pointer is captured up front; if the
/// pane is torn down mid-flight the app's ipc_server goes null first
/// (App stops IPC before destroying panes), so completions drop quietly.
const IpcCdp = struct {
    app: *App,
    ipc_id: u64,
    webview: *wv2.ICoreWebView2,
    verb: enum { snapshot, click, fill },
    step: u8 = 0,
    /// backendNodeId target for click/fill. Unused by snapshot.
    ref: i64 = 0,
    /// Owned UTF-8 text for fill (escaped into the CDP params later).
    text: ?[]u8 = null,
    /// Computed click point (DOM.getBoxModel center), px in CSS coords.
    click_x: f64 = 0,
    click_y: f64 = 0,
};

const IpcCdpHandler = wv2.CallDevToolsProtocolMethodCompletedHandler(IpcCdp);

/// Begin a `snapshot` verb: Accessibility.enable, then getFullAXTree,
/// then transform the tree into a compact [{ref,role,name}] array.
pub fn snapshotForIpc(self: *BrowserPane, ipc_id: u64) void {
    const ctx = self.startCdp(ipc_id, .snapshot) orelse return;
    cdpCallCtx(ctx, "Accessibility.enable", "{}");
}

/// Begin a `click` verb on backend node `ref`: scrollIntoViewIfNeeded,
/// getBoxModel (→ center), then a mousePressed/mouseReleased pair.
pub fn clickForIpc(self: *BrowserPane, ipc_id: u64, ref: i64) void {
    const ctx = self.startCdp(ipc_id, .click) orelse return;
    ctx.ref = ref;
    var buf: [128]u8 = undefined;
    const params = std.fmt.bufPrint(
        &buf,
        "{{\"backendNodeId\":{d}}}",
        .{ref},
    ) catch {
        finishErrStatic(ctx, "ref out of range");
        return;
    };
    cdpCallCtx(ctx, "DOM.scrollIntoViewIfNeeded", params);
}

/// Begin a `fill` verb on backend node `ref`: DOM.focus then
/// Input.insertText. `text` is copied; the caller keeps ownership of its
/// slice.
pub fn fillForIpc(self: *BrowserPane, ipc_id: u64, ref: i64, text: []const u8) void {
    const ctx = self.startCdp(ipc_id, .fill) orelse return;
    ctx.ref = ref;
    const alloc = self.app.core_app.alloc;
    ctx.text = alloc.dupe(u8, text) catch {
        finishErrStatic(ctx, "out of memory");
        return;
    };
    var buf: [128]u8 = undefined;
    const params = std.fmt.bufPrint(
        &buf,
        "{{\"backendNodeId\":{d}}}",
        .{ref},
    ) catch {
        finishErrStatic(ctx, "ref out of range");
        return;
    };
    cdpCallCtx(ctx, "DOM.focus", params);
}

/// Allocate and initialize a verb context, or answer the request with an
/// error (and return null) when the pane is not ready or OOM.
fn startCdp(self: *BrowserPane, ipc_id: u64, verb: anytype) ?*IpcCdp {
    const server = self.app.ipc_server orelse return null;
    const alloc = self.app.core_app.alloc;
    if (self.state != .ready or self.webview == null) {
        server.sendError(ipc_id, "browser pane is not ready") catch {};
        return null;
    }
    const ctx = alloc.create(IpcCdp) catch {
        server.sendError(ipc_id, "out of memory") catch {};
        return null;
    };
    ctx.* = .{
        .app = self.app,
        .ipc_id = ipc_id,
        .webview = self.webview.?,
        .verb = verb,
    };
    return ctx;
}

/// CDP completion: advance the verb's state machine. `result` is the CDP
/// method's returnObject as JSON (UTF-16) on success, null on error.
fn onCdpCompleted(ctx: *IpcCdp, error_code: wv2.HRESULT, result: ?wv2.LPCWSTR) void {
    // The pane may have been torn down; App nulls ipc_server before that,
    // so finishOk/finishErr no-op on the send but still free the context.
    if (error_code != wv2.S_OK) {
        finishErrStatic(ctx, "CDP step failed");
        return;
    }
    const alloc = ctx.app.core_app.alloc;

    switch (ctx.verb) {
        .snapshot => switch (ctx.step) {
            // 0: Accessibility.enable done → request the full AX tree.
            0 => {
                ctx.step = 1;
                cdpCallCtx(ctx, "Accessibility.getFullAXTree", "{}");
            },
            // 1: getFullAXTree returned → transform and answer.
            else => {
                const json16 = result orelse {
                    finishErrStatic(ctx, "empty AX tree");
                    return;
                };
                const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(json16)) catch {
                    finishErrStatic(ctx, "out of memory");
                    return;
                };
                defer alloc.free(utf8);
                const compact = transformAxTree(alloc, utf8) catch {
                    finishErrStatic(ctx, "failed to parse AX tree");
                    return;
                };
                defer alloc.free(compact);
                finishOk(ctx, compact);
            },
        },

        .click => switch (ctx.step) {
            // 0: scrollIntoViewIfNeeded done → get the box model.
            0 => {
                ctx.step = 1;
                var buf: [128]u8 = undefined;
                const params = std.fmt.bufPrint(
                    &buf,
                    "{{\"backendNodeId\":{d}}}",
                    .{ctx.ref},
                ) catch {
                    finishErrStatic(ctx, "ref out of range");
                    return;
                };
                cdpCallCtx(ctx, "DOM.getBoxModel", params);
            },
            // 1: box model returned → compute center, dispatch mousePressed.
            1 => {
                const json16 = result orelse {
                    finishErrStatic(ctx, "no box model");
                    return;
                };
                computeBoxCenter(ctx, alloc, std.mem.span(json16)) catch {
                    finishErrStatic(ctx, "element has no box (not visible?)");
                    return;
                };
                ctx.step = 2;
                var buf: [256]u8 = undefined;
                const params = mouseEventParams(&buf, "mousePressed", ctx.click_x, ctx.click_y) catch {
                    finishErrStatic(ctx, "format error");
                    return;
                };
                cdpCallCtx(ctx, "Input.dispatchMouseEvent", params);
            },
            // 2: mousePressed done → mouseReleased.
            2 => {
                ctx.step = 3;
                var buf: [256]u8 = undefined;
                const params = mouseEventParams(&buf, "mouseReleased", ctx.click_x, ctx.click_y) catch {
                    finishErrStatic(ctx, "format error");
                    return;
                };
                cdpCallCtx(ctx, "Input.dispatchMouseEvent", params);
            },
            // 3: mouseReleased done → answer ok.
            else => finishOk(ctx, "\"ok\""),
        },

        .fill => switch (ctx.step) {
            // 0: DOM.focus done → insert the text.
            0 => {
                ctx.step = 1;
                const text = ctx.text orelse "";
                // Build {"text":<json-escaped>} with std.json escaping.
                const params = std.fmt.allocPrint(
                    alloc,
                    "{{\"text\":{f}}}",
                    .{std.json.fmt(text, .{})},
                ) catch {
                    finishErrStatic(ctx, "out of memory");
                    return;
                };
                defer alloc.free(params);
                cdpCallCtx(ctx, "Input.insertText", params);
            },
            // 1: insertText done → answer ok.
            else => finishOk(ctx, "\"ok\""),
        },
    }
}

/// Issue the next CDP call in a chain, from a completion (no BrowserPane
/// in hand). Mirrors cdpCall but reads alloc/webview off ctx.
fn cdpCallCtx(ctx: *IpcCdp, method: []const u8, params_json: []const u8) void {
    const alloc = ctx.app.core_app.alloc;
    const method_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, method) catch {
        finishErrStatic(ctx, "out of memory");
        return;
    };
    defer alloc.free(method_w);
    const params_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, params_json) catch {
        finishErrStatic(ctx, "out of memory");
        return;
    };
    defer alloc.free(params_w);

    const handler = IpcCdpHandler.create(alloc, ctx, onCdpCompleted) catch {
        finishErrStatic(ctx, "out of memory");
        return;
    };
    defer handler.unref();

    ctx.webview.callDevToolsProtocolMethod(method_w, params_w, handler) catch {
        finishErrStatic(ctx, "CDP call failed");
    };
}

/// Format Input.dispatchMouseEvent params for a left-button single click.
fn mouseEventParams(buf: []u8, kind: []const u8, x: f64, y: f64) ![]u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"type\":\"{s}\",\"x\":{d:.2},\"y\":{d:.2},\"button\":\"left\",\"buttons\":1,\"clickCount\":1}}",
        .{ kind, x, y },
    );
}

/// Parse DOM.getBoxModel's returnObject and store the content-quad center
/// on ctx. The quad is [x1,y1,x2,y2,x3,y3,x4,y4]; the center is the mean
/// of the first and third corner (opposite corners of the rectangle).
fn computeBoxCenter(ctx: *IpcCdp, alloc: Allocator, json16: []const u16) !void {
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, json16);
    defer alloc.free(utf8);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, utf8, .{});
    defer parsed.deinit();
    const model = parsed.value.object.get("model") orelse return error.NoModel;
    const content = model.object.get("content") orelse return error.NoContent;
    const quad = content.array;
    if (quad.items.len < 8) return error.BadQuad;
    const x1 = try jsonNumber(quad.items[0]);
    const y1 = try jsonNumber(quad.items[1]);
    const x3 = try jsonNumber(quad.items[4]);
    const y3 = try jsonNumber(quad.items[5]);
    ctx.click_x = (x1 + x3) / 2.0;
    ctx.click_y = (y1 + y3) / 2.0;
}

fn jsonNumber(v: std.json.Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.NotANumber,
    };
}

/// Transform Accessibility.getFullAXTree's returnObject into a compact
/// JSON array of {ref, role, name} for nodes that carry a backendDOMNodeId
/// and a non-ignored role. `ref` is the backendDOMNodeId an agent feeds to
/// click/fill. Caller owns the returned slice.
fn transformAxTree(alloc: Allocator, tree_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, tree_json, .{});
    defer parsed.deinit();

    const nodes = (parsed.value.object.get("nodes") orelse return error.NoNodes).array;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var w = out.writer(alloc);
    try w.writeByte('[');
    var first = true;

    for (nodes.items) |node| {
        const obj = switch (node) {
            .object => |o| o,
            else => continue,
        };
        // Skip nodes the platform marks ignored (not useful to an agent).
        if (obj.get("ignored")) |ig| {
            if (ig == .bool and ig.bool) continue;
        }
        const backend = obj.get("backendDOMNodeId") orelse continue;
        const ref: i64 = switch (backend) {
            .integer => |i| i,
            else => continue,
        };
        const role = axValueString(obj.get("role"));
        const name = axValueString(obj.get("name"));
        // Drop generic structural nodes with no name to keep the list
        // focused on interactive/labeled elements.
        if (name.len == 0 and (role.len == 0 or
            std.mem.eql(u8, role, "generic") or
            std.mem.eql(u8, role, "none") or
            std.mem.eql(u8, role, "InlineTextBox") or
            std.mem.eql(u8, role, "StaticText"))) continue;

        if (!first) try w.writeByte(',');
        first = false;
        try w.print(
            "{{\"ref\":{d},\"role\":{f},\"name\":{f}}}",
            .{ ref, std.json.fmt(role, .{}), std.json.fmt(name, .{}) },
        );
    }
    try w.writeByte(']');
    return out.toOwnedSlice(alloc);
}

/// An AX node property is `{"type":..,"value":<string>}`. Pull the inner
/// string value, or "" when absent/non-string.
fn axValueString(v: ?std.json.Value) []const u8 {
    const obj = switch (v orelse return "") {
        .object => |o| o,
        else => return "",
    };
    const inner = obj.get("value") orelse return "";
    return switch (inner) {
        .string => |s| s,
        else => "",
    };
}

/// Terminal step: answer ok with `data_json` (already valid JSON) and
/// free the context.
fn finishOk(ctx: *IpcCdp, data_json: []const u8) void {
    if (ctx.app.ipc_server) |server| {
        server.sendOk(ctx.ipc_id, data_json) catch {};
    }
    freeCdp(ctx);
}

/// Terminal error step from a completion: answer error and free.
fn finishErrStatic(ctx: *IpcCdp, msg: []const u8) void {
    if (ctx.app.ipc_server) |server| {
        server.sendError(ctx.ipc_id, msg) catch {};
    }
    freeCdp(ctx);
}

fn freeCdp(ctx: *IpcCdp) void {
    const alloc = ctx.app.core_app.alloc;
    if (ctx.text) |t| alloc.free(t);
    alloc.destroy(ctx);
}

/// Navigate to `url_w` (NUL-terminated UTF-16). If the webview is ready
/// it navigates immediately; otherwise the URL is stashed and applied
/// when creation completes (navigatePending). Returns an error only if
/// the live webview rejects the Navigate call. Used by the agent IPC
/// `navigate`/`open` commands (the address-bar path is
/// navigateFromAddressBar).
pub fn navigateUrl(self: *BrowserPane, url_w: [*:0]const u16) !void {
    if (self.state == .ready) {
        if (self.webview) |webview| {
            try webview.navigate(url_w);
            return;
        }
    }
    // Not ready yet: stash as the pending URL, capped to the buffer.
    const span = std.mem.span(url_w);
    const n = @min(span.len, URL_MAX);
    @memcpy(self.pending_url[0..n], span[0..n]);
    self.pending_url_len = n;
}

fn navigatePending(self: *BrowserPane) void {
    if (self.pending_url_len == 0) return;
    const webview = self.webview orelse return;
    self.pending_url[self.pending_url_len] = 0;
    webview.navigate(@ptrCast(&self.pending_url)) catch |err| {
        log.warn("browser pending navigate failed: {}", .{err});
    };
    self.pending_url_len = 0;
}

/// Move keyboard focus into the webview (via the host's WM_SETFOCUS,
/// which calls MoveFocus). Used when Escape leaves the address bar.
pub fn focusWebView(self: *BrowserPane) void {
    if (self.host_hwnd) |host| _ = w32.SetFocus(host);
}

/// Window-level WM_MOVE: WebView2 needs to be told its screen position
/// changed even though the child HWND didn't move client-relative.
pub fn onParentWindowMoved(self: *BrowserPane) void {
    if (self.state != .ready) return;
    if (self.controller) |controller| {
        controller.notifyParentWindowPositionChanged() catch {};
    }
}

fn addressBarHeight(self: *const BrowserPane) i32 {
    return barHeightAt(self.parent_window.scale);
}

fn addressBarPad(self: *const BrowserPane) i32 {
    return barPadAt(self.parent_window.scale);
}

fn barHeightAt(scale: f32) i32 {
    return @intFromFloat(@round(ADDRESS_BAR_BASE * scale));
}

fn barPadAt(scale: f32) i32 {
    return @intFromFloat(@round(3.0 * scale));
}

fn closeWidthAt(scale: f32) i32 {
    return @intFromFloat(@round(CLOSE_BASE * scale));
}

/// Pure geometry for the close-'x' button rect given the host client
/// width and DPI scale. Shared by paint, hit-test, and the edit-width
/// reservation so they can never disagree. Unit-tested directly.
fn closeRectAt(width: i32, scale: f32) w32.RECT {
    const bar_h = barHeightAt(scale);
    const pad = barPadAt(scale);
    const cw = closeWidthAt(scale);
    return .{
        .left = @max(width - pad - cw, 0),
        .top = pad,
        .right = @max(width - pad, 0),
        .bottom = @max(bar_h - pad, pad),
    };
}

/// Pure address-bar EDIT width: the bar minus left pad, the close
/// column, and a pad gap before it. Floored at 1. The EDIT's right edge
/// (pad + this) must stay left of closeRectAt().left at every scale.
fn editWidthAt(width: i32, scale: f32) i32 {
    const pad = barPadAt(scale);
    const cw = closeWidthAt(scale);
    return @max(width - pad * 3 - cw, 1);
}

/// Screen-relative rect of the address-bar close-'x' button given the
/// host's client width. Shared by paint and hit-testing so the glyph and
/// its click target stay identical at every scale. The button occupies
/// the full bar height on the right edge, inset by the bar pad.
fn closeRect(self: *const BrowserPane, width: i32) w32.RECT {
    return closeRectAt(width, self.parent_window.scale);
}

/// True when client point (x,y) is inside the close-'x' button.
fn pointInClose(self: *const BrowserPane, x: i32, y: i32) bool {
    const host = self.host_hwnd orelse return false;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(host, &rect) == 0) return false;
    const r = self.closeRect(rect.right - rect.left);
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

/// Re-layout the address bar and webview bounds from the host's
/// current client rect.
fn updateBounds(self: *BrowserPane) void {
    const host = self.host_hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(host, &rect) == 0) return;
    self.layoutChildren(rect.right - rect.left, rect.bottom - rect.top);
}

fn layoutChildren(self: *BrowserPane, width: i32, height: i32) void {
    const bar_h = self.addressBarHeight();
    const pad = self.addressBarPad();
    if (self.address_edit) |edit| {
        // Reserve the close-'x' column plus a pad gap on the right.
        _ = w32.MoveWindow(
            edit,
            pad,
            pad,
            editWidthAt(width, self.parent_window.scale),
            @max(bar_h - pad * 2, 1),
            1,
        );
    }
    if (self.state != .ready) return;
    const controller = self.controller orelse return;
    // put_Bounds takes physical pixels relative to the host.
    controller.putBounds(.{
        .left = 0,
        .top = bar_h,
        .right = @max(width, 0),
        .bottom = @max(height, bar_h),
    }) catch {};
}

fn setFailed(self: *BrowserPane) void {
    self.state = .failed;
    if (self.host_hwnd) |host| {
        _ = w32.InvalidateRect(host, null, 1);
    }
}

fn paintHost(self: *BrowserPane, hwnd: w32.HWND) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return;
    if (self.app.bg_brush) |brush| {
        _ = w32.FillRect(hdc, &rect, brush);
    }
    if (self.state == .failed) {
        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
        _ = w32.SetTextColor(hdc, w32.RGB(200, 200, 200));
        var old_font: ?*anyopaque = null;
        if (self.parent_window.tab_font) |font| {
            old_font = w32.SelectObject(hdc, font);
        }
        defer if (old_font) |f| {
            _ = w32.SelectObject(hdc, f);
        };
        const text = L("WebView2 runtime unavailable");
        var text_rect = rect;
        _ = w32.DrawTextW(
            hdc,
            text,
            text.len,
            &text_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    self.paintCloseButton(hdc, rect.right - rect.left);
}

/// Paint the close-'x' glyph at the right of the address-bar strip.
/// Gray normally, red (the shared close-hover color) while hovered.
/// Uses only SetTextColor + DrawTextW on the address font, so it adds
/// no GDI objects to delete.
fn paintCloseButton(self: *BrowserPane, hdc: w32.HDC, width: i32) void {
    var r = self.closeRect(width);
    if (r.right <= r.left) return;
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    _ = w32.SetTextColor(hdc, if (self.close_hovered)
        w32.RGB(232, 65, 65)
    else
        w32.RGB(150, 150, 150));
    var old_font: ?*anyopaque = null;
    if (self.address_font) |font| {
        old_font = w32.SelectObject(hdc, font);
    }
    defer if (old_font) |f| {
        _ = w32.SelectObject(hdc, f);
    };
    const glyph = L("\u{00D7}"); // multiplication sign (same as tab/sidebar close)
    _ = w32.DrawTextW(
        hdc,
        glyph,
        glyph.len,
        &r,
        w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
    );
}

/// Repaint only the close-'x' column (cheap; avoids flickering the EDIT).
fn invalidateCloseButton(self: *BrowserPane) void {
    const host = self.host_hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(host, &rect) == 0) return;
    var r = self.closeRect(rect.right - rect.left);
    _ = w32.InvalidateRect(host, &r, 1);
}

/// Window procedure for browser host HWNDs (GhosttyBrowserHost class).
/// GWLP_USERDATA stores a *BrowserPane pointer.
pub fn hostWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self: *BrowserPane = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_SIZE => {
            const width: i32 = @intCast(lparam & 0xFFFF);
            const height: i32 = @intCast((lparam >> 16) & 0xFFFF);
            self.layoutChildren(width, height);
            return 0;
        },

        w32.WM_SHOWWINDOW => {
            if (self.state == .ready) {
                if (self.controller) |controller| {
                    controller.putIsVisible(wparam != 0) catch {};
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SETFOCUS => {
            const win = self.parent_window;
            if (!win.closing) {
                // Same guard as onGotFocus: only write the slot of the
                // tab that owns this pane (a zombie host or a pane not
                // yet in a tree must not be recorded anywhere).
                if (self.pane) |pane| {
                    if (win.findLoc(pane)) |loc| {
                        loc.ws.tab_active_pane[loc.tab] = pane;
                    }
                }
            }
            if (self.state == .ready) {
                if (self.controller) |controller| {
                    controller.moveFocus(.programmatic) catch {};
                }
            } else if (self.address_edit) |edit| {
                _ = w32.SetFocus(edit);
            }
            return 0;
        },

        w32.WM_ERASEBKGND => {
            if (self.app.bg_brush) |brush| {
                const hdc_erase: w32.HDC = @ptrFromInt(wparam);
                var rect: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &rect) != 0) {
                    _ = w32.FillRect(hdc_erase, &rect, brush);
                }
            }
            return 1;
        },

        w32.WM_PAINT => {
            self.paintHost(hwnd);
            return 0;
        },

        w32.WM_MOUSEMOVE => {
            const x: i32 = @intCast(@as(i16, @truncate(lparam & 0xFFFF)));
            const y: i32 = @intCast(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
            const over = self.pointInClose(x, y);
            if (over != self.close_hovered) {
                self.close_hovered = over;
                self.invalidateCloseButton();
            }
            if (over) {
                // Ask for WM_MOUSELEAVE so the red hover clears when the
                // cursor leaves the host (mirrors the tab-bar tracking).
                var tme = w32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = w32.TrackMouseEvent(&tme);
            }
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            if (self.close_hovered) {
                self.close_hovered = false;
                self.invalidateCloseButton();
            }
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const x: i32 = @intCast(@as(i16, @truncate(lparam & 0xFFFF)));
            const y: i32 = @intCast(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
            self.close_pressed = self.pointInClose(x, y);
            return 0;
        },

        w32.WM_LBUTTONUP => {
            const x: i32 = @intCast(@as(i16, @truncate(lparam & 0xFFFF)));
            const y: i32 = @intCast(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
            const pressed = self.close_pressed;
            self.close_pressed = false;
            // Close only when both the press and the release landed on
            // the button, and the window isn't already tearing down.
            if (pressed and self.pointInClose(x, y) and !self.parent_window.closing) {
                if (self.pane) |pane| {
                    // closeSplitPane synchronously destroys this host
                    // HWND and frees `self` (via Pane.unref ->
                    // BrowserPane.destroy). Nothing below may touch
                    // `self` or `hwnd` after this call.
                    self.parent_window.closeSplitPane(pane);
                    return 0;
                }
            }
            return 0;
        },

        w32.WM_CTLCOLOREDIT => {
            // Dark mode colors for the address-bar Edit (same scheme as
            // the search edit in App.surfaceWndProc).
            const hdc_edit: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_edit, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_edit, w32.RGB(45, 45, 45));
            if (self.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_DESTROY => {
            // Destroyed by the parent window while async creation was
            // still in flight (destroy() zeroes GWLP_USERDATA before
            // its own DestroyWindow, so it never reaches here). Flag
            // closing so the completion callback Closes+drops the
            // controller instead of touching a dead HWND.
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            self.state = .closing;
            self.host_hwnd = null;
            self.address_edit = null;
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: browser close button sits at the right edge, inside the bar" {
    const width: i32 = 800;
    const r = closeRectAt(width, 1.0);
    const pad = barPadAt(1.0);
    const cw = closeWidthAt(1.0);
    // Right edge inset by pad; width is exactly the close column.
    try testing.expectEqual(width - pad, r.right);
    try testing.expectEqual(width - pad - cw, r.left);
    try testing.expectEqual(cw, r.right - r.left);
    // Vertically within the bar strip (top..bottom inside 0..bar_h).
    try testing.expectEqual(pad, r.top);
    try testing.expect(r.bottom <= barHeightAt(1.0));
    try testing.expect(r.bottom > r.top);
}

test "unit: browser edit never overlaps the close button at any scale" {
    // The EDIT's right edge (left pad + edit width) must stay strictly
    // left of the close button's left edge so the URL field and the
    // close 'x' never collide, at every DPI scale and a range of widths.
    const scales = [_]f32{ 1.0, 1.25, 1.5, 1.75, 2.0 };
    const widths = [_]i32{ 120, 300, 640, 800, 1920 };
    for (scales) |scale| {
        for (widths) |width| {
            const pad = barPadAt(scale);
            const edit_right = pad + editWidthAt(width, scale);
            const close_left = closeRectAt(width, scale).left;
            try testing.expect(edit_right <= close_left);
        }
    }
}

test "unit: browser close geometry scales with DPI" {
    // The column widens proportionally; the right inset is the bar pad.
    try testing.expectEqual(closeWidthAt(2.0), closeRectAt(800, 2.0).right - closeRectAt(800, 2.0).left);
    try testing.expect(closeWidthAt(2.0) > closeWidthAt(1.0));
    try testing.expectEqual(800 - barPadAt(1.5), closeRectAt(800, 1.5).right);
}

test "unit: browser tiny widths keep the close rect non-negative" {
    // Degenerate narrow panes must not produce a negative-origin rect
    // (the @max clamps guard against it). The rect collapses but stays
    // well-formed; pointInClose then never matches inside it.
    const r = closeRectAt(4, 1.0);
    try testing.expect(r.left >= 0);
    try testing.expect(r.right >= 0);
    try testing.expect(r.right >= r.left);
}

test "unit: browser title cap ascii passes through" {
    const input = [_]u16{ 'h', 'e', 'l', 'l', 'o' };
    try testing.expectEqualSlices(u16, &input, capUtf16(&input, 170));
}

test "unit: browser title cap exact boundary is unchanged" {
    const input = [_]u16{ 'a', 'b', 'c', 'd' };
    try testing.expectEqualSlices(u16, &input, capUtf16(&input, 4));
}

test "unit: browser title cap truncates past the boundary" {
    const input = [_]u16{ 'a', 'b', 'c', 'd', 'e' };
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, capUtf16(&input, 3));
}

test "unit: browser title cap drops a surrogate pair split by the cut" {
    // U+1F600 as the pair (0xD83D, 0xDE00) straddling max_units=4: the
    // dangling high surrogate must go with it.
    const input = [_]u16{ 'a', 'b', 'c', 0xD83D, 0xDE00 };
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, capUtf16(&input, 4));
}

test "unit: browser title cap keeps a surrogate pair ending at the cut" {
    const input = [_]u16{ 'a', 'b', 0xD83D, 0xDE00, 'c' };
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 0xD83D, 0xDE00 }, capUtf16(&input, 4));
}

test "unit: browser title cap empty and zero-unit inputs" {
    try testing.expectEqualSlices(u16, &.{}, capUtf16(&.{}, 170));
    const input = [_]u16{ 'a', 'b' };
    try testing.expectEqualSlices(u16, &.{}, capUtf16(&input, 0));
}

test "unit: browser title cap worst-case expansion fits title_buf" {
    // Mirror onDocumentTitleChanged's buffer math: a capped input must
    // always convert into title_buf.len - 1 bytes, even when every code
    // unit expands to 3 UTF-8 bytes (U+FFFF).
    const buf_len = @typeInfo(@FieldType(BrowserPane, "title_buf")).array.len;
    const max_units = (buf_len - 1) / 3;
    var input: [max_units + 50]u16 = @splat(0xFFFF);
    const capped = capUtf16(&input, max_units);
    try testing.expectEqual(max_units, capped.len);
    var buf: [buf_len]u8 = undefined;
    const len = try std.unicode.utf16LeToUtf8(buf[0 .. buf_len - 1], capped);
    try testing.expectEqual(max_units * 3, len);
}

test "unit: browser title cap=1 keeps one ascii unit" {
    const input = [_]u16{ 'a', 'b' };
    try testing.expectEqualSlices(u16, &.{'a'}, capUtf16(&input, 1));
}

test "unit: browser title cap=1 with a leading surrogate pair collapses to empty" {
    // U+1F600 first: a cut at one unit would strand the high surrogate,
    // so the result backs up to nothing rather than emit a malformed
    // title.
    const input = [_]u16{ 0xD83D, 0xDE00, 'a' };
    try testing.expectEqualSlices(u16, &.{}, capUtf16(&input, 1));
}

test "unit: browser title exact fit including a trailing surrogate pair" {
    // span.len == max_units takes the no-op path even when the final
    // unit is the low half of a pair.
    const input = [_]u16{ 'a', 0xD83D, 0xDE00 };
    try testing.expectEqualSlices(u16, &input, capUtf16(&input, 3));
}

test "unit: browser title cap drops an unpaired low surrogate at the cut" {
    // A lone low surrogate (no preceding high half) landing exactly at
    // the boundary is just as malformed as a dangling high surrogate:
    // it must be backed over, not passed through.
    const input = [_]u16{ 'a', 'b', 0xDE00, 'c', 'd' };
    try testing.expectEqualSlices(u16, &.{ 'a', 'b' }, capUtf16(&input, 3));
}

test "unit: browser title cap drops a lone high surrogate at the cut" {
    // A lone high surrogate (the next unit is NOT its low half) at the
    // boundary is dropped — same path as the split-pair case.
    const input = [_]u16{ 'a', 0xD800, 'b', 'c' };
    try testing.expectEqualSlices(u16, &.{'a'}, capUtf16(&input, 2));
}

test "unit: browser title cap=1 with a leading lone low surrogate collapses to empty" {
    // A lone low surrogate first: backing over it leaves nothing, which
    // beats emitting one malformed unit.
    const input = [_]u16{ 0xDE00, 'a', 'b' };
    try testing.expectEqualSlices(u16, &.{}, capUtf16(&input, 1));
}

test "unit: browser title exact fit with a trailing lone low surrogate is unchanged" {
    // span.len <= max_units takes the no-op path: the cap only repairs
    // damage the CUT would cause; pre-existing malformation in a string
    // that fits is passed through untouched (utf16LeToUtf8 still
    // rejects it, exactly as it would have without any cap).
    const input = [_]u16{ 'a', 0xDE00 };
    try testing.expectEqualSlices(u16, &input, capUtf16(&input, 2));
}
