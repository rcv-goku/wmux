//! Public API of the `env_identity` feature (ARCHITECTURE.md ADR-3.9): the
//! terminal environment that identifies a surface to the CLI and agents
//! (CMUX_*/WMUX_* ids, socket path and capability, bundled CLI path,
//! PATH and WSLENV additions) and the per-tab job objects. The apprt
//! surface calls these while its terminal spawns.
//!
//! Stubs written by W0-A3 (pre-wiring); W1-3 implements them and owns
//! this feature. `Surface.spawn_identity` carries the window, workspace,
//! pane, tab and lifecycle UUIDs of the spawn (model/ids.zig).

const std = @import("std");

const Surface = @import("../../Surface.zig");
const termio = @import("../../../../termio.zig");

/// Adjust the base environment of a new terminal (from the process
/// environment), before the core adds its own variables: e.g. remove the
/// inherited agent credentials ADR-3.9 lists. Nothing yet.
pub fn adjustDefaultEnv(surface: *const Surface, env: *std.process.EnvMap) !void {
    _ = surface;
    _ = env;
}

/// What the terminal spawn of `surface` adds: the protected environment
/// (applied after the user's `env` configuration) and the job object the
/// child is created in. Nothing yet.
pub fn spawnHooks(surface: *Surface) !termio.Exec.SpawnHooks {
    _ = surface;
    return .{};
}
