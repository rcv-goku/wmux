//! Where v2 methods run (ARCHITECTURE.md ADR-3.2 "Lanes"):
//!
//! - `pipe`: on the connection thread, inline (no model access);
//! - `worker`: on a pool of 4 threads (files and processes, no model);
//! - `ui`: on the UI thread through `app.tasks`, with the modal hold: while
//!   `app.modal.depth > 0` a request that is not read-only stays queued
//!   (its deadline keeps running) and is posted again when the last modal
//!   loop ends (`app.modal` idle hook).
//!
//! The lanes only move work between threads; the dispatcher (dispatch.zig)
//! begins, runs and completes each request.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../App.zig");
const deadline = @import("logic/deadline.zig");
const tasks = @import("../app/tasks.zig");

const log = std.log.scoped(.rpc);

/// The number of worker-lane threads (ADR-3.2).
pub const worker_count = 4;

/// One unit of worker-lane work. Embed it and recover the payload with
/// `@fieldParentPtr`.
pub const Job = struct {
    /// Runs on a worker thread.
    run: *const fn (*Job) void,
    /// Frees the payload; called exactly once, after `run` or instead of
    /// it when the pool stops.
    destroy: *const fn (*Job) void,
};

pub const WorkerPool = struct {
    gpa: Allocator = undefined,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayList(*Job) = .empty,
    head: usize = 0,
    threads: [worker_count]?std.Thread = @splat(null),
    stopping: bool = false,
    started: bool = false,

    /// Spawns the workers. A worker that cannot start is logged; the pool
    /// runs with the ones that did (none: `submit` refuses).
    pub fn start(self: *WorkerPool, gpa: Allocator) void {
        self.* = .{ .gpa = gpa, .started = true };
        for (&self.threads) |*t| {
            t.* = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, workerMain, .{self}) catch |err| blk: {
                log.warn("worker lane thread failed to start: {}", .{err});
                break :blk null;
            };
        }
    }

    fn anyThread(self: *const WorkerPool) bool {
        for (self.threads) |t| if (t != null) return true;
        return false;
    }

    /// Queues `job` (FIFO). False when the pool is stopping or has no
    /// thread; the caller then still owns the job.
    pub fn submit(self: *WorkerPool, job: *Job) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping or !self.started or !self.anyThread()) return false;
        self.queue.append(self.gpa, job) catch return false;
        self.cond.signal();
        return true;
    }

    /// Stops the workers (running jobs finish first), joins them and
    /// destroys the jobs still queued. Idempotent.
    pub fn stop(self: *WorkerPool) void {
        if (!self.started) return;
        self.mutex.lock();
        self.stopping = true;
        self.cond.broadcast();
        self.mutex.unlock();
        for (&self.threads) |*t| {
            if (t.*) |th| th.join();
            t.* = null;
        }
        for (self.queue.items[self.head..]) |job| job.destroy(job);
        self.queue.deinit(self.gpa);
        self.queue = .empty;
        self.head = 0;
        self.started = false;
    }

    fn workerMain(self: *WorkerPool) void {
        while (true) {
            self.mutex.lock();
            while (!self.stopping and self.head >= self.queue.items.len) self.cond.wait(&self.mutex);
            if (self.stopping) {
                self.mutex.unlock();
                return;
            }
            const job = self.queue.items[self.head];
            self.head += 1;
            if (self.head == self.queue.items.len) {
                self.queue.clearRetainingCapacity();
                self.head = 0;
            }
            self.mutex.unlock();
            job.run(job);
            job.destroy(job);
        }
    }
};

/// One unit of UI-lane work.
pub const UiItem = struct {
    /// Runs on the UI thread (not while held by a modal loop).
    run: *const fn (*UiItem, *App) void,
    /// Frees the payload; called exactly once.
    destroy: *const fn (*UiItem) void,
    /// `.read` access (and read-only legacy commands): never held.
    read_only: bool,
};

/// The UI lane: posts items through `app.tasks` and applies the modal hold.
/// `post` may run on any thread; everything else on the UI thread.
pub const UiLane = struct {
    app: *App = undefined,
    gpa: Allocator = undefined,
    /// Items waiting for the modal loop to end (UI thread only).
    held: std.ArrayList(*UiItem) = .empty,
    closed: std.atomic.Value(bool) = .init(false),

    const Wrapper = struct {
        task: tasks.Task = .{ .run = taskRun, .destroy = taskDestroy },
        /// Valid while the lane runs (`run` only happens then).
        lane: *UiLane,
        /// Kept here: a wrapper destroyed after the lane closed must not
        /// touch the lane.
        gpa: Allocator,
        item: ?*UiItem,
    };

    pub fn init(self: *UiLane, app: *App, gpa: Allocator) void {
        self.* = .{ .app = app, .gpa = gpa };
    }

    /// Hands `item` to the UI thread. Ownership moves to the lane (the
    /// item is destroyed if it cannot be posted).
    pub fn post(self: *UiLane, item: *UiItem) void {
        if (self.closed.load(.acquire)) return item.destroy(item);
        const w = self.gpa.create(Wrapper) catch return item.destroy(item);
        w.* = .{ .lane = self, .gpa = self.gpa, .item = item };
        self.app.tasks.post(&w.task);
    }

    fn taskRun(app: *App, task: *tasks.Task) void {
        const w: *Wrapper = @fieldParentPtr("task", task);
        const item = w.item orelse return;
        const lane = w.lane;
        if (lane.closed.load(.acquire)) return;
        if (deadline.holdForModal(item.read_only, app.modal.depth)) {
            lane.held.append(lane.gpa, item) catch {
                // Cannot hold it: run it rather than leak or drop it.
                w.item = null;
                item.run(item, app);
                item.destroy(item);
                return;
            };
            w.item = null;
            return;
        }
        w.item = null;
        item.run(item, app);
        item.destroy(item);
    }

    fn taskDestroy(task: *tasks.Task) void {
        const w: *Wrapper = @fieldParentPtr("task", task);
        if (w.item) |item| item.destroy(item);
        w.gpa.destroy(w);
    }

    /// The last modal loop ended (app.modal idle hook, UI thread): post
    /// every held item again, in order.
    pub fn releaseHeld(self: *UiLane) void {
        if (self.held.items.len == 0) return;
        var items = self.held;
        self.held = .empty;
        defer items.deinit(self.gpa);
        for (items.items) |item| self.post(item);
    }

    /// Stops accepting and destroys the held items (UI thread, at stop).
    /// Items still in `app.tasks` are destroyed by the task queue.
    pub fn close(self: *UiLane) void {
        self.closed.store(true, .release);
        for (self.held.items) |item| item.destroy(item);
        self.held.deinit(self.gpa);
        self.held = .empty;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: rpc: worker lane runs jobs in order on its threads and destroys the rest at stop" {
    const TestJob = struct {
        job: Job = .{ .run = run, .destroy = destroy },
        counter: *std.atomic.Value(u32),
        destroyed: *std.atomic.Value(u32),
        fn run(j: *Job) void {
            const self: *@This() = @fieldParentPtr("job", j);
            _ = self.counter.fetchAdd(1, .acq_rel);
        }
        fn destroy(j: *Job) void {
            const self: *@This() = @fieldParentPtr("job", j);
            _ = self.destroyed.fetchAdd(1, .acq_rel);
        }
    };
    var pool: WorkerPool = .{};
    pool.start(testing.allocator);
    var counter: std.atomic.Value(u32) = .init(0);
    var destroyed: std.atomic.Value(u32) = .init(0);
    var jobs: [32]TestJob = undefined;
    for (&jobs) |*j| {
        j.* = .{ .counter = &counter, .destroyed = &destroyed };
        try testing.expect(pool.submit(&j.job));
    }
    var waited: u32 = 0;
    while (counter.load(.acquire) < jobs.len and waited < 5000) : (waited += 1) std.Thread.sleep(std.time.ns_per_ms);
    pool.stop();
    try testing.expectEqual(@as(u32, jobs.len), counter.load(.acquire));
    try testing.expectEqual(@as(u32, jobs.len), destroyed.load(.acquire));
    var late: TestJob = .{ .counter = &counter, .destroyed = &destroyed };
    try testing.expect(!pool.submit(&late.job));
}
