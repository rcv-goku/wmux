//! `app.timers`: one-shot and repeating UI-thread timers on msg_hwnd
//! (ARCHITECTURE.md ADR-1.6). Ids are handed out from 1000 upward, so the
//! hand-numbered msg_hwnd timer registry is gone: the quit delay (was id
//! 1), the quick-terminal animation (3), the update-balloon cleanup (4),
//! the workspace-metadata refresh (5) and the desktop-balloon cleanups
//! (100..107) were migrated in W0-A1. New code MUST NOT add hand-numbered
//! timer ids (G8).
//!
//! A one-shot timer is killed and forgotten before its callback runs, so
//! the callback may start a new timer (or the same work again) freely. A
//! stopped timer's already-queued WM_TIMER finds no entry and is ignored.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../App.zig");
const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.app_timers);

/// Identifies a running timer. 0 is never a valid id ("no timer").
pub const TimerId = usize;

/// Runs on the UI thread. `ctx` is the caller's opaque value (an index,
/// or a pointer passed through @intFromPtr).
pub const Callback = *const fn (app: *App, ctx: usize) void;

pub const Options = struct {
    /// Keep firing every `ms` until stopped (default: fire once).
    repeat: bool = false,
};

/// The first id handed out. Lower ids are left to nobody (the legacy
/// hand-numbered ids all lived below it).
pub const first_id: TimerId = 1000;

/// Pure id/entry bookkeeping behind `Timers` (unit-tested without Win32).
pub const Registry = struct {
    pub const Entry = struct {
        id: TimerId,
        repeat: bool,
        ctx: usize,
        cb: Callback,
    };

    entries: std.ArrayList(Entry) = .empty,
    next_id: TimerId = first_id,

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        self.entries.deinit(alloc);
        self.* = undefined;
    }

    /// Reserve the next id (never 0, never reused while live).
    pub fn nextId(self: *Registry) TimerId {
        while (true) {
            const id = self.next_id;
            self.next_id +%= 1;
            if (self.next_id < first_id) self.next_id = first_id;
            if (id != 0 and self.find(id) == null) return id;
        }
    }

    pub fn add(self: *Registry, alloc: Allocator, entry: Entry) Allocator.Error!void {
        try self.entries.append(alloc, entry);
    }

    pub fn find(self: *const Registry, id: TimerId) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.id == id) return i;
        }
        return null;
    }

    /// Forget `id`. Returns whether it was live.
    pub fn remove(self: *Registry, id: TimerId) bool {
        const idx = self.find(id) orelse return false;
        _ = self.entries.swapRemove(idx);
        return true;
    }

    /// The entry a WM_TIMER for `id` should run, or null when `id` is not
    /// ours (or was stopped). One-shot entries are removed here, before
    /// their callback runs.
    pub fn fire(self: *Registry, id: TimerId) ?Entry {
        const idx = self.find(id) orelse return null;
        const entry = self.entries.items[idx];
        if (!entry.repeat) _ = self.entries.swapRemove(idx);
        return entry;
    }
};

pub const Timers = struct {
    alloc: Allocator = undefined,
    /// The window WM_TIMER arrives on (App.msg_hwnd). Null until `init`
    /// and after `deinit`: `start` then fails (returns 0).
    hwnd: ?w32.HWND = null,
    registry: Registry = .{},

    /// Attach to msg_hwnd. Called once from App.init.
    pub fn init(self: *Timers, alloc: Allocator, hwnd: ?w32.HWND) void {
        self.* = .{ .alloc = alloc, .hwnd = hwnd };
    }

    /// Start a timer firing after `ms` (and every `ms` with
    /// `.repeat = true`). Returns its id, or 0 when it could not start.
    /// UI thread only.
    pub fn start(self: *Timers, ms: u32, opts: Options, ctx: usize, cb: Callback) TimerId {
        const hwnd = self.hwnd orelse return 0;
        const id = self.registry.nextId();
        self.registry.add(self.alloc, .{
            .id = id,
            .repeat = opts.repeat,
            .ctx = ctx,
            .cb = cb,
        }) catch {
            log.warn("out of memory starting a timer", .{});
            return 0;
        };
        if (w32.SetTimer(hwnd, id, ms, null) == 0) {
            log.warn("SetTimer failed for timer id={d}", .{id});
            _ = self.registry.remove(id);
            return 0;
        }
        return id;
    }

    /// Stop a timer. Unknown ids (including 0 and already-fired one-shot
    /// timers) are ignored. UI thread only.
    pub fn stop(self: *Timers, id: TimerId) void {
        if (id == 0) return;
        if (!self.registry.remove(id)) return;
        if (self.hwnd) |hwnd| _ = w32.KillTimer(hwnd, id);
    }

    /// WM_TIMER on msg_hwnd: run the callback for `id`. Returns false
    /// when the id is not an app timer (the caller falls through to
    /// DefWindowProc).
    pub fn dispatch(self: *Timers, app: *App, id: usize) bool {
        const entry = self.registry.fire(id) orelse return false;
        if (!entry.repeat) {
            if (self.hwnd) |hwnd| _ = w32.KillTimer(hwnd, id);
        }
        entry.cb(app, entry.ctx);
        return true;
    }

    /// Kill every running timer. UI thread, during App.terminate (before
    /// msg_hwnd is destroyed).
    pub fn deinit(self: *Timers) void {
        if (self.hwnd) |hwnd| {
            for (self.registry.entries.items) |e| _ = w32.KillTimer(hwnd, e.id);
        }
        self.registry.deinit(self.alloc);
        self.registry = .{};
        self.hwnd = null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testCallback(app: *App, ctx: usize) void {
    _ = app;
    _ = ctx;
}

test "unit: app: timers registry hands out unique ids from 1000" {
    var reg: Registry = .{};
    defer reg.deinit(testing.allocator);
    const a = reg.nextId();
    try reg.add(testing.allocator, .{ .id = a, .repeat = false, .ctx = 0, .cb = testCallback });
    const b = reg.nextId();
    try testing.expectEqual(first_id, a);
    try testing.expectEqual(first_id + 1, b);

    // Wrap-around skips 0, the low range, and live ids.
    reg.next_id = std.math.maxInt(TimerId);
    const c = reg.nextId();
    try testing.expectEqual(@as(TimerId, std.math.maxInt(TimerId)), c);
    const d = reg.nextId();
    try testing.expect(d >= first_id);
    try testing.expect(d != a); // `a` is still live
}

test "unit: app: timers registry fires one-shot once and repeating until removed" {
    var reg: Registry = .{};
    defer reg.deinit(testing.allocator);
    const once = reg.nextId();
    try reg.add(testing.allocator, .{ .id = once, .repeat = false, .ctx = 7, .cb = testCallback });
    const every = reg.nextId();
    try reg.add(testing.allocator, .{ .id = every, .repeat = true, .ctx = 9, .cb = testCallback });

    // One-shot: fires once, then is gone.
    try testing.expectEqual(@as(usize, 7), reg.fire(once).?.ctx);
    try testing.expect(reg.fire(once) == null);

    // Repeating: fires until removed.
    try testing.expectEqual(@as(usize, 9), reg.fire(every).?.ctx);
    try testing.expectEqual(@as(usize, 9), reg.fire(every).?.ctx);
    try testing.expect(reg.remove(every));
    try testing.expect(reg.fire(every) == null);
    try testing.expect(!reg.remove(every));

    // Unknown ids are not ours.
    try testing.expect(reg.fire(42) == null);
}
