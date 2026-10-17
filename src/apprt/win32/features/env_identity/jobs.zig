//! Instance and per-tab job objects (ARCHITECTURE.md ADR-3.8, ADR-3.9).
//!
//! At startup the wmux process puts itself in an unnamed instance job
//! (`JOB_OBJECT_LIMIT_BREAKAWAY_OK` only). Every terminal spawn creates a
//! per-tab job (`BREAKAWAY_OK` only, never `KILL_ON_JOB_CLOSE`: GUI apps
//! started from a shell survive closing the tab) that `src/Command.zig`
//! lists in `PROC_THREAD_ATTRIBUTE_JOB_LIST`; Windows nests it below the
//! instance job, so `IsProcessInJob(instance)` holds for every descendant
//! and survives reparenting and PID reuse. The jobs answer the queries of
//! api.zig (caller identification, `surface.pids`).
//!
//! Ownership: the job of a spawn is created before its tab joins the model
//! (`Surface.init` runs before `Tab.create`), so it waits in
//! `App.features.env_identity.pending_jobs` (keyed by the tab UUID of the
//! spawn identity) until `adopt` moves it into `Tab.ext.env_identity.job`,
//! which closes it when the tab is destroyed. UI thread only.

const std = @import("std");

const App = @import("../../App.zig");
const Surface = @import("../../Surface.zig");
const Tab = @import("../../model/Tab.zig");
const registry = @import("../../model/registry.zig");
const job = @import("../../platform/job.zig");
const ids = @import("../../model/ids.zig");

const log = std.log.scoped(.env_identity);

/// Create the instance job and put this process in it. A failure is
/// logged and leaves no job (ADR-3.9: callers fall back to ancestry and
/// the capability).
pub fn initInstance(app: *App) void {
    const st = &app.features.env_identity;
    if (st.instance_job != null) return;
    var j = job.Job.create(job.Limits.instance) catch |err| {
        log.warn("instance job not created err={} win32={}", .{ err, job.last_error });
        return;
    };
    j.assignCurrentProcess() catch |err| {
        log.warn("instance job assignment failed err={} win32={}", .{ err, job.last_error });
        j.deinit();
        return;
    };
    st.instance_job = j;
    log.info("instance job created", .{});
}

/// A new per-tab job for the spawn of `surface`, kept open in the pending
/// table until its tab adopts it. Returns the handle for
/// `Command.job`, or null when no job could be made (the spawn then runs
/// without one).
pub fn createTabJob(surface: *Surface) ?job.HANDLE {
    const app = surface.app;
    const st = &app.features.env_identity;
    const key = surface.spawn_identity.surface;
    if (key.isNil()) return null;
    var j = job.Job.create(job.Limits.tab) catch |err| {
        log.warn("tab job not created err={} win32={}", .{ err, job.last_error });
        return null;
    };
    const gop = st.pending_jobs.getOrPut(app.core_app.alloc, key) catch {
        j.deinit();
        return null;
    };
    if (gop.found_existing) gop.value_ptr.deinit();
    gop.value_ptr.* = j;
    return j.handle;
}

/// Move the pending job of tab `surface_id` into its tab (`surface.created`
/// and the queries call this). No-op without a pending job or a tab.
pub fn adopt(app: *App, surface_id: ids.Uuid) void {
    const st = &app.features.env_identity;
    if (!st.pending_jobs.contains(surface_id)) return;
    const tab = registry.resolveSurface(app, .none, .{ .uuid = surface_id }) orelse return;
    adoptInto(st, tab, surface_id);
}

fn adoptInto(st: anytype, tab: *Tab, surface_id: ids.Uuid) void {
    const kv = st.pending_jobs.fetchRemove(surface_id) orelse return;
    const slot = &tab.ext.env_identity.job;
    if (slot.*) |*old| old.deinit();
    slot.* = kv.value;
}

/// The job of `surface`'s terminal, adopting a pending one when its tab
/// exists. Null without a job.
pub fn jobOf(surface: *const Surface) ?job.Job {
    const st = &surface.app.features.env_identity;
    const key = surface.spawn_identity.surface;
    if (surface.tab) |tab| {
        if (st.pending_jobs.contains(key)) adoptInto(st, tab, key);
        if (tab.ext.env_identity.job) |j| return j;
    }
    return st.pending_jobs.get(key);
}

/// Whether `pid` runs in this instance's job (directly or in a nested
/// per-tab job). False without an instance job or for a pid that exited.
pub fn inInstanceJob(app: *const App, pid: u32) bool {
    const j = app.features.env_identity.instance_job orelse return false;
    return j.containsPid(pid) catch false;
}

/// The surface whose per-tab job contains `pid`, searched over every
/// terminal tab of every window, or null.
pub fn surfaceForPid(app: *App, pid: u32) ?*Surface {
    for (app.windows.items) |w| {
        if (w.closing) continue;
        for (w.workspaces.items) |ws| {
            var i: usize = 0;
            while (registry.paneAtDepthFirst(ws, i)) |pane| : (i += 1) {
                for (pane.tabs.items) |tab| {
                    const surface = tab.surface() orelse continue;
                    const j = jobOf(surface) orelse continue;
                    if (j.containsPid(pid) catch false) return surface;
                }
            }
        }
    }
    return null;
}

/// The pids in `surface`'s per-tab job (empty without a job or when the
/// query fails), allocated with `gpa`.
pub fn processIds(gpa: std.mem.Allocator, surface: *const Surface) std.mem.Allocator.Error![]u32 {
    const j = jobOf(surface) orelse return gpa.alloc(u32, 0);
    return j.processIds(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.debug("tab job pid query failed err={} win32={}", .{ err, job.last_error });
            return gpa.alloc(u32, 0);
        },
    };
}
