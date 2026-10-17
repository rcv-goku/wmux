//! The control server facade (ARCHITECTURE.md ADR-3.2, ADR-14.3
//! pre-wiring): App.init calls `start` once msg_hwnd exists and
//! App.terminate calls `stop` before msg_hwnd is destroyed. Until W1-1
//! adds the v2 pipe server (PipeServer.zig, the launch pipe, admission,
//! lanes) behind this facade, it runs only the legacy wmux-v1 JSON server
//! on `\.\pipe\wmux-ipc-<pid>` (legacy_pipe.zig).

const App = @import("../../App.zig");
const legacy_pipe = @import("legacy_pipe.zig");

/// Start serving. A failure only disables the pipe (logged by the
/// server); the app runs without it.
pub fn start(app: *App) void {
    legacy_pipe.start(app);
}

/// Stop serving and join the server threads. Requests still queued for
/// the UI thread are destroyed unanswered by app.tasks afterwards.
pub fn stop(app: *App) void {
    if (app.ipc_server) |server| {
        server.stop();
        app.ipc_server = null;
    }
}

/// The full name of the v2 control pipe this instance serves
/// (`\.\pipe\wmux-<channel>-<sidhash8>-s<session>`, or its
/// `-alt-<8hex>` fallback, ADR-3.1), UTF-8, borrowed until `stop`; null
/// while no v2 server runs. The terminal environment exports it as
/// `CMUX_SOCKET_PATH`/`WMUX_SOCKET_PATH` (W1-3, ADR-3.9).
///
/// Stub written by the W1 kickoff interface commit (W1-IF) so W1-3 can
/// call it in the same plan sub-wave as W1-1a, which implements it: null
/// (only the legacy pipe runs today).
pub fn controlPipeName(app: *const App) ?[]const u8 {
    _ = app;
    return null;
}

test {
    _ = &controlPipeName;
}
