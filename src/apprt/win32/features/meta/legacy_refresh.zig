//! Sidebar workspace metadata (Stage 2): off-thread git branch / ports / PR.
//!
//! refreshWorkspaceMetadata runs on the UI thread (a repeating app.timers
//! timer). It snapshots each visible workspace into a self-contained
//! ws_meta.Job (an owned working_dir copy + the tabs' child PIDs read
//! lock-free), stamps the workspace with a fresh token, and spawns ONE
//! detached worker thread for the batch. The worker runs git/gh/the TCP
//! table (never touching live Window/App state) and posts a *ws_meta.Result
//! per workspace back to the UI thread through app.tasks, where
//! applyWorkspaceMetadata revalidates + stores it.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W2-6
//! replaces the probes with watched `.git\HEAD` + job-based ports.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../../App.zig");
const Window = @import("../../ui/Window.zig");
const tasks = @import("../../app/tasks.zig");
const ws_meta = @import("probes.zig");

const log = std.log.scoped(.win32);

/// Hands a completed *ws_meta.Result from a sidebar-metadata worker
/// thread to the GUI thread, which owns all Window/Workspace state
/// (ownership of the result transfers with the task). The worker only
/// reads its own owned Job, never live Window/App state.
const ResultTask = struct {
    task: tasks.Task = .{ .run = run, .destroy = destroy },
    alloc: Allocator,
    /// Owned until `run` hands it to applyWorkspaceMetadata (which frees
    /// it).
    result: ?*ws_meta.Result,

    fn run(app: *App, task: *tasks.Task) void {
        const self: *ResultTask = @fieldParentPtr("task", task);
        const result = self.result orelse return;
        self.result = null;
        applyWorkspaceMetadata(app, result);
    }

    fn destroy(task: *tasks.Task) void {
        const self: *ResultTask = @fieldParentPtr("task", task);
        if (self.result) |result| self.alloc.destroy(result);
        self.alloc.destroy(self);
    }
};

/// Start the periodic sidebar-metadata refresh (git branch / ports / PR):
/// a repeating app.timers timer on the UI thread; each tick spawns a
/// worker thread for the actual git/gh/TCP-table work. Called once from
/// App.init.
pub fn startRefreshTimer(app: *App) void {
    _ = app.timers.start(WS_META_INTERVAL_MS, .{ .repeat = true }, 0, onRefreshTimer);
}

/// app.timers callback: one metadata refresh tick.
fn onRefreshTimer(app: *App, ctx: usize) void {
    _ = ctx;
    refreshWorkspaceMetadata(app);
}

/// Refresh cadence for sidebar metadata, in milliseconds. The git/port
/// scan is cheap and runs every tick; the gh PR probe (network) runs only
/// once every WS_META_PR_EVERY ticks.
pub const WS_META_INTERVAL_MS: u32 = 4000;
pub const WS_META_PR_EVERY: u64 = 8; // ~32s with a 4s tick

/// UI-thread timer tick: build refresh jobs for the active workspace of
/// every live, non-quick window and dispatch them to a worker thread. Only
/// the visible workspace per window is refreshed each tick (background
/// workspaces refresh lazily when they become active — see selectWorkspace).
pub fn refreshWorkspaceMetadata(self: *App) void {
    if (!self.config.@"sidebar-metadata") return;
    self.ws_meta_tick +%= 1;
    const want_pr = (self.ws_meta_tick % WS_META_PR_EVERY) == 0;

    var jobs: std.ArrayList(ws_meta.Job) = .empty;
    defer jobs.deinit(self.core_app.alloc);

    for (self.windows.items) |w| {
        if (w.closing or w.is_quick_terminal) continue;
        if (w.workspaces.items.len == 0) continue;
        const ws_idx = w.activeIndex();
        if (ws_idx >= w.workspaces.items.len) continue;
        if (buildMetaJob(self, w, ws_idx, want_pr)) |job| {
            jobs.append(self.core_app.alloc, job) catch |err| {
                log.warn("ws-meta: failed to queue job: {}", .{err});
                var j = job;
                j.deinit(self.core_app.alloc);
            };
        }
    }

    if (jobs.items.len == 0) return;
    dispatchMetaJobs(self, jobs.toOwnedSlice(self.core_app.alloc) catch return);
}

/// Refresh one workspace's metadata immediately (on focus / worktree bind),
/// outside the periodic tick. Best-effort: a dispatch failure is silent.
pub fn refreshWorkspaceMetadataNow(self: *App, w: *Window, ws_idx: usize) void {
    if (!self.config.@"sidebar-metadata") return;
    if (w.closing or w.is_quick_terminal) return;
    if (ws_idx >= w.workspaces.items.len) return;
    const job = buildMetaJob(self, w, ws_idx, false) orelse return;
    const jobs = self.core_app.alloc.alloc(ws_meta.Job, 1) catch {
        var j = job;
        j.deinit(self.core_app.alloc);
        return;
    };
    jobs[0] = job;
    dispatchMetaJobs(self, jobs);
}

/// Build a self-contained refresh job for workspace `ws_idx` of `w`, or
/// null when there is nothing to scan (no cwd AND no child PIDs).
/// Stamps the workspace with a fresh token. Runs on the UI thread; all
/// reads (cwd, child PIDs) are lock-free/stable.
fn buildMetaJob(self: *App, w: *Window, ws_idx: usize, want_pr: bool) ?ws_meta.Job {
    const alloc = self.core_app.alloc;
    const ws = w.workspaces.items[ws_idx];

    // Collect ConPTY child PIDs from all Panes (terminals only).
    var pids: std.ArrayList(u32) = .empty;
    errdefer pids.deinit(alloc);
    {
        var tree_it = ws.tree.iterator();
        while (tree_it.next()) |tree_entry| {
            const container = tree_entry.view;
            for (container.tabs.items) |tab| {
                const surface = tab.surface() orelse continue;
                if (surface.childPid()) |pid| pids.append(alloc, pid) catch {};
            }
        }
    }

    const has_dir = ws.cwd != null;
    if (!has_dir and pids.items.len == 0) {
        pids.deinit(alloc);
        return null;
    }

    const dir_copy: ?[]u8 = if (ws.cwd) |d| (alloc.dupe(u8, d) catch null) else null;
    const pid_slice = pids.toOwnedSlice(alloc) catch {
        pids.deinit(alloc);
        if (dir_copy) |d| alloc.free(d);
        return null;
    };

    self.ws_meta_token +%= 1;
    if (self.ws_meta_token == 0) self.ws_meta_token = 1; // 0 reserved
    ws.meta_token = self.ws_meta_token;

    return .{
        .window = @ptrCast(w),
        .ws_idx = ws_idx,
        .token = self.ws_meta_token,
        .working_dir = dir_copy,
        .root_pids = pid_slice,
        .want_pr = want_pr and has_dir,
    };
}

/// Spawn the detached worker thread that processes `jobs` (ownership
/// transferred). On a spawn failure the jobs are freed here so nothing
/// leaks (the UI simply keeps the previous metadata).
fn dispatchMetaJobs(self: *App, jobs: []ws_meta.Job) void {
    const ctx = self.core_app.alloc.create(MetaWorkerCtx) catch {
        freeMetaJobs(self.core_app.alloc, jobs);
        return;
    };
    ctx.* = .{ .app = self, .jobs = jobs };
    const thread = std.Thread.spawn(.{}, metaWorkerMain, .{ctx}) catch {
        self.core_app.alloc.destroy(ctx);
        freeMetaJobs(self.core_app.alloc, jobs);
        return;
    };
    thread.detach();
}

const MetaWorkerCtx = struct {
    app: *App,
    jobs: []ws_meta.Job,
};

fn freeMetaJobs(alloc: Allocator, jobs: []ws_meta.Job) void {
    for (jobs) |*j| j.deinit(alloc);
    alloc.free(jobs);
}

/// Worker-thread entry: run every job and post each result back to the UI
/// thread through app.tasks. Touches only `ctx` (its own owned jobs), the
/// allocator and the thread-safe task queue — NEVER live Window/App
/// state. If a task cannot be allocated the result is freed here.
fn metaWorkerMain(ctx: *MetaWorkerCtx) void {
    const self = ctx.app;
    const alloc = self.core_app.alloc;
    defer {
        freeMetaJobs(alloc, ctx.jobs);
        alloc.destroy(ctx);
    }

    for (ctx.jobs) |*job| {
        const result = ws_meta.run(alloc, job) catch continue;
        const task = alloc.create(ResultTask) catch {
            alloc.destroy(result);
            continue;
        };
        task.* = .{ .alloc = alloc, .result = result };
        self.tasks.post(&task.task);
    }
}

/// UI-thread: apply a worker result to its workspace after revalidating the
/// window still lives and the workspace still bears the job's token (so a
/// result for a since-recycled slot is dropped). Frees the result.
pub fn applyWorkspaceMetadata(self: *App, result: *ws_meta.Result) void {
    defer self.core_app.alloc.destroy(result);

    const target: *Window = @ptrCast(@alignCast(result.window));
    // Validate the window pointer is still live (not freed since dispatch).
    var alive = false;
    for (self.windows.items) |w| {
        if (w == target) {
            alive = true;
            break;
        }
    }
    if (!alive or target.closing) return;
    if (result.ws_idx >= target.workspaces.items.len) return;

    const ws = target.workspaces.items[result.ws_idx];
    // Token mismatch: a different workspace sits at the index now (a close
    // or a reorder since dispatch); drop rather than mis-apply.
    if (ws.meta_token != result.token) return;

    ws.setGitBranch(result.branch[0..result.branch_len]);
    ws.setPorts(result.ports[0..result.port_count]);
    // The gh probe runs on a slow cadence; only overwrite the PR cache on a
    // tick that actually probed, so fast (git/port) ticks don't blank it.
    if (result.pr_probed) ws.setPrStatus(result.pr_state, result.pr_number);

    target.invalidateSidebar();
}
