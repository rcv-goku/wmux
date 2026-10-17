//! Public API of the `env_identity` feature (ARCHITECTURE.md ADR-3.9): the
//! terminal environment that identifies a surface to the CLI and agents
//! (CMUX_*/WMUX_* ids, socket path and capability, bundled CLI path,
//! PATH and WSLENV additions) and the per-tab job objects. The apprt
//! surface calls these while its terminal spawns.
//!
//! Stubs written by W0-A3 (pre-wiring); W1-3 implements them and owns
//! this feature. `Surface.spawn_identity` carries the window, workspace,
//! pane, tab and lifecycle UUIDs of the spawn (model/ids.zig). The job
//! queries (`inInstanceJob`, `surfaceForPid`, `processIds`) were added by
//! the W1 kickoff interface commit (W1-IF) with their final signatures:
//! W1-1a's `wmux.debug.layout` (same plan sub-wave) and W1-1b's caller
//! context and `cmuxOnly` check call them.

const std = @import("std");

const App = @import("../../App.zig");
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

/// Whether process `pid` runs inside this instance's job (directly or in
/// a nested per-tab job); survives reparenting and PID reuse (ADR-3.8
/// `inInstanceJob`). Stub: false, no instance job exists yet (W1-3).
pub fn inInstanceJob(app: *const App, pid: u32) bool {
    _ = app;
    _ = pid;
    return false;
}

/// The surface whose per-tab job contains process `pid` (the caller
/// context of a CLI client, ADR-3.9), or null. Stub: null (W1-3).
pub fn surfaceForPid(app: *App, pid: u32) ?*Surface {
    _ = app;
    _ = pid;
    return null;
}

/// The ids of the processes in `surface`'s per-tab job (the shell and its
/// descendants, `wmux.debug.layout` `surface.pids`), allocated with `gpa`
/// (the caller frees). Stub: an empty slice (W1-3).
pub fn processIds(gpa: std.mem.Allocator, surface: *const Surface) std.mem.Allocator.Error![]u32 {
    _ = surface;
    return gpa.alloc(u32, 0);
}

test "unit: env_identity: job query stubs answer nothing until W1-3" {
    const testing = std.testing;
    // The stubs never dereference their arguments.
    const app: *App = @ptrFromInt(@alignOf(App));
    const surface: *const Surface = @ptrFromInt(@alignOf(Surface));
    try testing.expect(!inInstanceJob(app, 4));
    try testing.expect(surfaceForPid(app, 4) == null);
    const pids = try processIds(testing.allocator, surface);
    defer testing.allocator.free(pids);
    try testing.expectEqual(@as(usize, 0), pids.len);
}
