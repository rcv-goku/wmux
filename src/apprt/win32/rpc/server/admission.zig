//! Thread-safe admission gate of the v2 pipe server (ADR-3.3): the pure
//! counters of logic/admission.zig behind a mutex, plus the bounded wait of
//! pending connections for a live slot. std only (no Win32), so it is
//! unit-tested natively.

const std = @import("std");
const logic = @import("../logic/admission.zig");

pub const Limits = logic.Limits;
pub const Reason = logic.Reason;
pub const overloadedLineAlloc = logic.overloadedLineAlloc;

pub const Verdict = union(enum) {
    admit,
    wait,
    reject: Reason,
};

pub const WaitResult = union(enum) {
    admitted,
    rejected: Reason,
};

pub const Counts = struct { live: u32, pending: u32, preauth: u32 };

pub const Gate = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    state: logic.Admission,

    pub fn init(limits: Limits) Gate {
        return .{ .state = .init(limits) };
    }

    pub fn getLimits(self: *const Gate) Limits {
        return self.state.limits;
    }

    /// Classifies a newly accepted connection.
    pub fn accept(self: *Gate) Verdict {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (self.state.accept()) {
            .admit => .admit,
            .wait => .wait,
            .reject => .{ .reject = self.state.reject_reason },
        };
    }

    /// After `accept` returned `.wait`: blocks until a live slot frees, the
    /// pending wait cap passes or the gate stops.
    pub fn waitForSlot(self: *Gate) WaitResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        const budget_ns: u64 = @as(u64, self.state.limits.pending_wait_ms) * std.time.ns_per_ms;
        var timer = std.time.Timer.start() catch return .{ .rejected = self.state.expirePending() };
        while (true) {
            if (self.state.stopping) return .{ .rejected = self.state.abandonPending() };
            if (self.state.promote()) return .admitted;
            const spent = timer.read();
            if (spent >= budget_ns) return .{ .rejected = self.state.expirePending() };
            self.cond.timedWait(&self.mutex, budget_ns - spent) catch {};
        }
    }

    /// A live connection closed; wakes one pending waiter.
    pub fn release(self: *Gate) void {
        self.mutex.lock();
        const wake = self.state.release();
        self.mutex.unlock();
        if (wake) self.cond.signal();
    }

    /// A live connection that must authenticate starts being read. Null on
    /// success, else the rejection reason (`preauthorization_saturated`).
    pub fn beginPreauth(self: *Gate) ?Reason {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.state.beginPreauth()) null else self.state.reject_reason;
    }

    pub fn endPreauth(self: *Gate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.state.endPreauth();
    }

    /// Rejects later arrivals with `server_stopping` and wakes every waiter.
    pub fn stop(self: *Gate) void {
        self.mutex.lock();
        self.state.stop();
        self.mutex.unlock();
        self.cond.broadcast();
    }

    pub fn counts(self: *Gate) Counts {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .live = self.state.live, .pending = self.state.pending, .preauth = self.state.preauth };
    }
};

// ---------------------------------------------------------------------------
// Tests (native; std only)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: rpc: gate waiter is admitted when a live slot frees" {
    var g: Gate = .init(.{ .max_live = 1, .max_pending = 1, .pending_wait_ms = 5_000 });
    try testing.expect(g.accept() == .admit);
    try testing.expect(g.accept() == .wait);
    try testing.expectEqual(Reason.pool_saturated, g.accept().reject);
    var result: WaitResult = undefined;
    const T = struct {
        fn run(gate: *Gate, out: *WaitResult) void {
            out.* = gate.waitForSlot();
        }
    };
    const th = try std.Thread.spawn(.{}, T.run, .{ &g, &result });
    g.release();
    th.join();
    try testing.expect(result == .admitted);
    try testing.expectEqual(Counts{ .live = 1, .pending = 0, .preauth = 0 }, g.counts());
}

test "unit: rpc: gate waiter expires after the pending cap" {
    var g: Gate = .init(.{ .max_live = 1, .max_pending = 1, .pending_wait_ms = 30 });
    _ = g.accept();
    try testing.expect(g.accept() == .wait);
    var timer = try std.time.Timer.start();
    try testing.expectEqual(Reason.pending_expired, g.waitForSlot().rejected);
    try testing.expect(timer.read() >= 30 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 0), g.counts().pending);
}

test "unit: rpc: gate stop wakes waiters with server_stopping" {
    var g: Gate = .init(.{ .max_live = 1, .max_pending = 4, .pending_wait_ms = 60_000 });
    _ = g.accept();
    var results: [3]WaitResult = undefined;
    var threads: [3]std.Thread = undefined;
    const T = struct {
        fn run(gate: *Gate, out: *WaitResult) void {
            out.* = gate.waitForSlot();
        }
    };
    for (&threads, &results) |*th, *r| {
        try testing.expect(g.accept() == .wait);
        th.* = try std.Thread.spawn(.{}, T.run, .{ &g, r });
    }
    g.stop();
    for (threads) |th| th.join();
    for (results) |r| try testing.expectEqual(Reason.server_stopping, r.rejected);
    try testing.expectEqual(Reason.server_stopping, g.accept().reject);
    g.release();
    try testing.expectEqual(Counts{ .live = 0, .pending = 0, .preauth = 0 }, g.counts());
}

test "unit: rpc: gate preauth slots" {
    var g: Gate = .init(.{ .max_preauth = 1 });
    try testing.expect(g.beginPreauth() == null);
    try testing.expectEqual(Reason.preauthorization_saturated, g.beginPreauth().?);
    g.endPreauth();
    try testing.expect(g.beginPreauth() == null);
}
