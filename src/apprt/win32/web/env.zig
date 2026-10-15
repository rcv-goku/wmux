//! WebView2 environment singleton (browser panes): one shared
//! `ICoreWebView2Environment`, created lazily on first use, with the
//! panes that asked for it while creation was in flight.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). The
//! state stays on App (`webview2_env`, `webview2_env_state`,
//! `webview2_pending`); W1-6 grows this into the environment/profile
//! owner of the web panel framework (ADR-6.3).

const std = @import("std");

const App = @import("../App.zig");
const BrowserPane = @import("../BrowserPane.zig");
const paths = @import("../app/paths.zig");
const wv2 = @import("../platform/webview2.zig");

const log = std.log.scoped(.win32);

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
            createWebView2Env(self);
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
        failWebView2Env(self);
        return;
    };

    // User data folder: %LOCALAPPDATA%\ghostty\webview2, or
    // <WMUX_STATE_DIR>\webview2 (app/paths.zig). Must exist before
    // environment creation.
    const dir = paths.webview2UserDataPath(alloc, &self.runtime_env) catch {
        failWebView2Env(self);
        return;
    };
    defer alloc.free(dir);
    std.fs.cwd().makePath(dir) catch |err| {
        log.warn("failed to create WebView2 user data dir={s} err={}", .{ dir, err });
        failWebView2Env(self);
        return;
    };
    const dir_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, dir) catch {
        failWebView2Env(self);
        return;
    };
    defer alloc.free(dir_w);

    const handler = wv2.EnvironmentCompletedHandler(App).create(
        alloc,
        self,
        onWebView2EnvCreated,
    ) catch {
        failWebView2Env(self);
        return;
    };
    loader.createEnvironment(null, dir_w.ptr, handler) catch {
        handler.unref();
        log.warn("CreateCoreWebView2EnvironmentWithOptions failed", .{});
        failWebView2Env(self);
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
    flushWebView2Pending(self);
}

fn failWebView2Env(self: *App) void {
    self.webview2_env_state = .failed;
    flushWebView2Pending(self);
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
