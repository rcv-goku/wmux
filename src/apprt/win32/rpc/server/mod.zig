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
