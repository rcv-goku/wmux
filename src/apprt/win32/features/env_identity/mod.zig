//! Feature `env_identity` (ADR-1.3); owning wave W1 (ADR-1.5), W1-3.
//! The protected CMUX_*/WMUX_* terminal environment, PATH and WSLENV,
//! the instance and per-tab job objects and the agent shims directory
//! (ARCHITECTURE.md ADR-3.9). The feature manifest imports only this file.

const App = @import("../../App.zig");
const events = @import("../../model/events.zig");
const jobs = @import("jobs.zig");
const ports = @import("ports.zig");
const spawn_env = @import("spawn_env.zig");

pub const id = "env_identity";

/// Before the first window: the instance job (so every later child is in
/// it) and the values every terminal shares. Failures only log.
pub fn init(app: *App) !void {
    jobs.initInstance(app);
    spawn_env.initInstance(app);
}

/// A new tab adopts the job its terminal was spawned in; a closed
/// workspace releases its port-block ordinal.
pub fn onEvent(app: *App, ev: *const events.Event) void {
    switch (ev.kind) {
        .@"surface.created" => if (ev.surface_id) |sid| jobs.adopt(app, sid),
        .@"workspace.closed" => if (ev.workspace_id) |wid| ports.forget(app, wid),
        else => {},
    }
}

test {
    _ = @import("logic/tests.zig");
    _ = @import("shims.zig");
}
