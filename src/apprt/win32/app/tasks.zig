//! `app.tasks`: the one way other threads hand work to the UI thread
//! (ARCHITECTURE.md ADR-1.6, ground rule G3).
//!
//! `post` may be called from any thread. Tasks go into a mutex-protected
//! FIFO; only the empty→non-empty transition posts a WM_APP_TASK to
//! msg_hwnd, and the UI thread drains the whole batch on that message. If
//! the post fails the queue keeps the task and the next `post` retries the
//! wakeup. On shutdown (`deinit`) queued tasks are destroyed without
//! running, and later posts destroy their task immediately.
//!
//! This replaces the per-purpose WM_APP+N messages: WM_APP+2 (update
//! available), +4 (IPC request), +5 (workspace metadata result) and +6
//! (default shell written) were migrated in W0-A1. New code MUST NOT add
//! WM_APP ids (G8).

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../App.zig");
const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.app_tasks);

/// The msg_hwnd message that drains the queue. (WM_APP+1 is the core
/// wakeup and WM_APP+3 the tray-balloon callback; +2/+4/+5/+6 were
/// retired into tasks in W0-A1.)
pub const WM_APP_TASK: u32 = w32.WM_APP + 7;

/// One unit of UI-thread work. Embed it in a heap payload and recover the
/// payload with `@fieldParentPtr("task", task)` in the callbacks.
pub const Task = struct {
    /// Runs on the UI thread.
    run: *const fn (*App, *Task) void,
    /// Frees the task and its payload. Called exactly once per posted
    /// task: right after `run`, or instead of it when the queue is shut
    /// down or cannot accept the task.
    destroy: *const fn (*Task) void,
};

pub const Tasks = struct {
    alloc: Allocator = undefined,
    mutex: std.Thread.Mutex = .{},
    queue: std.ArrayList(*Task) = .empty,

    /// Where WM_APP_TASK goes (App.msg_hwnd). Null until `init`.
    hwnd: ?w32.HWND = null,

    /// A WM_APP_TASK was posted and the queue has not been drained since.
    wake_pending: bool = false,

    /// Set by `deinit`: the queue no longer accepts tasks.
    closed: bool = false,

    /// Attach the queue to msg_hwnd. Called once from App.init, before
    /// any producer thread exists.
    pub fn init(self: *Tasks, alloc: Allocator, hwnd: ?w32.HWND) void {
        self.* = .{ .alloc = alloc, .hwnd = hwnd };
    }

    /// Queue `task` for the UI thread. Any thread. Ownership moves to the
    /// queue: the caller must not touch `task` afterwards (it is destroyed
    /// here when the queue is closed or out of memory).
    pub fn post(self: *Tasks, task: *Task) void {
        var hwnd: ?w32.HWND = null;
        const outcome: enum { queued, wake, closed, oom } = outcome: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) break :outcome .closed;
            self.queue.append(self.alloc, task) catch break :outcome .oom;
            // Only the empty→non-empty transition wakes the UI thread.
            // Without a window there is nobody to wake yet; leave
            // wake_pending clear so a later post retries.
            if (self.wake_pending or self.hwnd == null) break :outcome .queued;
            self.wake_pending = true;
            hwnd = self.hwnd;
            break :outcome .wake;
        };

        switch (outcome) {
            .queued => {},
            .closed => task.destroy(task),
            .oom => {
                log.warn("task queue out of memory; dropping task", .{});
                task.destroy(task);
            },
            .wake => if (w32.PostMessageW(hwnd.?, WM_APP_TASK, 0, 0) == 0) {
                // The task stays queued; the next post retries the wakeup.
                self.mutex.lock();
                defer self.mutex.unlock();
                self.wake_pending = false;
            },
        }
    }

    /// Run and destroy every queued task, in posting order. UI thread
    /// only (WM_APP_TASK). Tasks posted while the batch runs (from any
    /// thread, including the tasks themselves) post a fresh WM_APP_TASK
    /// and run on the next drain, so a busy producer cannot starve the
    /// message loop.
    pub fn drain(self: *Tasks, app: *App) void {
        var batch: std.ArrayList(*Task) = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const items = self.queue;
            self.queue = .empty;
            self.wake_pending = false;
            break :blk items;
        };
        defer batch.deinit(self.alloc);
        for (batch.items) |task| {
            task.run(app, task);
            task.destroy(task);
        }
    }

    /// Close the queue and destroy every task still in it (without
    /// running them). UI thread, during App.terminate.
    pub fn deinit(self: *Tasks) void {
        var pending: std.ArrayList(*Task) = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.hwnd = null;
            const items = self.queue;
            self.queue = .empty;
            break :blk items;
        };
        defer pending.deinit(self.alloc);
        for (pending.items) |task| task.destroy(task);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestTask = struct {
    task: Task = .{ .run = run, .destroy = destroy },
    order: *std.ArrayList(u8),
    tag: u8,
    destroyed: *usize,

    fn run(app: *App, task: *Task) void {
        _ = app;
        const self: *TestTask = @fieldParentPtr("task", task);
        self.order.append(testing.allocator, self.tag) catch unreachable;
    }

    fn destroy(task: *Task) void {
        const self: *TestTask = @fieldParentPtr("task", task);
        self.destroyed.* += 1;
    }
};

test "unit: app: tasks drain runs queued tasks in posting order then destroys them" {
    var tasks: Tasks = .{};
    // No window: posts queue without a wakeup (exercises the retry path).
    tasks.init(testing.allocator, null);
    defer tasks.deinit();

    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(testing.allocator);
    var destroyed: usize = 0;
    var a: TestTask = .{ .order = &order, .tag = 'a', .destroyed = &destroyed };
    var b: TestTask = .{ .order = &order, .tag = 'b', .destroyed = &destroyed };
    var c: TestTask = .{ .order = &order, .tag = 'c', .destroyed = &destroyed };
    tasks.post(&a.task);
    tasks.post(&b.task);
    tasks.post(&c.task);
    try testing.expect(!tasks.wake_pending);
    try testing.expectEqual(@as(usize, 3), tasks.queue.items.len);

    tasks.drain(undefined);
    try testing.expectEqualStrings("abc", order.items);
    try testing.expectEqual(@as(usize, 3), destroyed);
    try testing.expectEqual(@as(usize, 0), tasks.queue.items.len);

    // An empty drain is a no-op.
    tasks.drain(undefined);
    try testing.expectEqualStrings("abc", order.items);
}

test "unit: app: tasks deinit destroys pending tasks without running them" {
    var tasks: Tasks = .{};
    tasks.init(testing.allocator, null);

    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(testing.allocator);
    var destroyed: usize = 0;
    var a: TestTask = .{ .order = &order, .tag = 'a', .destroyed = &destroyed };
    var b: TestTask = .{ .order = &order, .tag = 'b', .destroyed = &destroyed };
    tasks.post(&a.task);
    tasks.post(&b.task);
    tasks.deinit();
    try testing.expectEqual(@as(usize, 2), destroyed);
    try testing.expectEqual(@as(usize, 0), order.items.len);

    // After shutdown a post destroys its task immediately.
    var c: TestTask = .{ .order = &order, .tag = 'c', .destroyed = &destroyed };
    tasks.post(&c.task);
    try testing.expectEqual(@as(usize, 3), destroyed);
    try testing.expectEqual(@as(usize, 0), order.items.len);
}
