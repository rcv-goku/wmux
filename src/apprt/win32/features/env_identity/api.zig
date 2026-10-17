//! Public API of the `env_identity` feature (ARCHITECTURE.md ADR-3.9): the
//! terminal environment that identifies a surface to the CLI and agents
//! (CMUX_*/WMUX_* ids, socket path, bundled CLI path, PATH and WSLENV
//! additions) and the per-tab job objects. The apprt surface calls these
//! while its terminal spawns; W1-1a's `wmux.debug.layout` and W1-1b's
//! caller context and `cmuxOnly` check call the job queries.
//!
//! Implemented by W1-3 (facade by W0-A3, job query signatures by W1-IF).
//! `Surface.spawn_identity` carries the window, workspace, pane, tab and
//! lifecycle UUIDs of the spawn (model/ids.zig). UI thread only.

const std = @import("std");

const App = @import("../../App.zig");
const Surface = @import("../../Surface.zig");
const termio = @import("../../../../termio.zig");
const jobs = @import("jobs.zig");
const spawn_env = @import("spawn_env.zig");

const log = std.log.scoped(.env_identity);

/// Adjust the base environment of a new terminal (from the process
/// environment), before the core adds its own variables: remove the
/// inherited Anthropic credentials (unless `wmux.agents.preserveAuthEnv`),
/// put `INSTALL\cli` (and the agent shims directory while an agent
/// integration is enabled) first on PATH and name the identity variables
/// in WSLENV.
pub fn adjustDefaultEnv(surface: *const Surface, env: *std.process.EnvMap) !void {
    try spawn_env.adjustDefaultEnv(surface, env);
}

/// What the terminal spawn of `surface` adds: the protected environment
/// (applied after the user's `env` configuration and any workspace or
/// layout env) and the per-tab job the child is created in (null when no
/// job could be made; the spawn then runs without one).
pub fn spawnHooks(surface: *Surface) !termio.Exec.SpawnHooks {
    var env = try spawn_env.protectedEnv(surface);
    errdefer env.deinit();
    const job = jobs.createTabJob(surface);
    const id = surface.spawn_identity;
    log.info("spawn identity workspace={f} surface={f} pane={f} lifecycle={f} job={s}", .{
        id.workspace, id.surface, id.pane, id.lifecycle, if (job != null) "tab" else "none",
    });
    return .{ .protected_env = env, .job = job };
}

/// Whether process `pid` runs inside this instance's job (directly or in
/// a nested per-tab job); survives reparenting and PID reuse (ADR-3.8
/// `inInstanceJob`). False when the instance job could not be created.
pub fn inInstanceJob(app: *const App, pid: u32) bool {
    return jobs.inInstanceJob(app, pid);
}

/// The surface whose per-tab job contains process `pid` (the caller
/// context of a CLI client, ADR-3.9), or null.
pub fn surfaceForPid(app: *App, pid: u32) ?*Surface {
    return jobs.surfaceForPid(app, pid);
}

/// The ids of the processes in `surface`'s per-tab job (the shell and its
/// descendants, `wmux.debug.layout` `surface.pids`), allocated with `gpa`
/// (the caller frees). Empty without a job.
pub fn processIds(gpa: std.mem.Allocator, surface: *const Surface) std.mem.Allocator.Error![]u32 {
    return jobs.processIds(gpa, surface);
}

test "unit: env_identity: the facade keeps the signatures its callers use" {
    // W1-1a and W1-1b call these with exactly these types (W1-IF).
    const T = struct {
        f1: *const fn (*const App, u32) bool = &inInstanceJob,
        f2: *const fn (*App, u32) ?*Surface = &surfaceForPid,
        f3: *const fn (std.mem.Allocator, *const Surface) std.mem.Allocator.Error![]u32 = &processIds,
        f4: *const fn (*const Surface, *std.process.EnvMap) anyerror!void = &adjustDefaultEnvAny,
    };
    _ = T{};
}

fn adjustDefaultEnvAny(surface: *const Surface, env: *std.process.EnvMap) anyerror!void {
    return adjustDefaultEnv(surface, env);
}
