//! Connection admission control with cmux's numbers (ADR-3.3,
//! cli-socket-admission-deadlines). Pure counters: the caller serializes
//! access (server/admission.zig wraps this in a mutex and a condition).
//!
//! An accepted connection is admitted to one of 64 live slots, or waits as
//! one of 64 pending connections for at most 15 s, or is rejected. Every
//! rejected connection is still answered: `overloaded {retryable:true,
//! retry_after_ms, reason}` and closed; its command never ran.

const std = @import("std");
const Allocator = std.mem.Allocator;
const request_state = @import("request_state.zig");

pub const Limits = struct {
    max_live: u32 = 64,
    max_pending: u32 = 64,
    pending_wait_ms: u32 = 15_000,
    /// Unauthenticated peers whose lines are being read.
    max_preauth: u32 = 16,
};

pub const Reason = enum {
    pool_saturated,
    pending_expired,
    preauthorization_saturated,
    accept_buffer_full,
    server_stopping,

    /// Client back-off hint. cmux does not document values; these are wmux
    /// choices (see out/REPORT.md).
    pub fn retryAfterMs(r: Reason) u32 {
        return switch (r) {
            .pool_saturated, .preauthorization_saturated, .accept_buffer_full => 250,
            .pending_expired => 1_000,
            .server_stopping => 2_000,
        };
    }
};

pub const Decision = enum {
    /// A live slot was taken.
    admit,
    /// A pending place was taken; call `promote` when a slot frees, or
    /// `expirePending` after `pending_wait_ms`.
    wait,
    /// Answer `overloaded` with `reject_reason` and close.
    reject,
};

pub const Admission = struct {
    limits: Limits = .{},
    live: u32 = 0,
    pending: u32 = 0,
    preauth: u32 = 0,
    stopping: bool = false,
    /// Reason of the last `.reject` from `accept`.
    reject_reason: Reason = .pool_saturated,

    pub fn init(limits: Limits) Admission {
        return .{ .limits = limits };
    }

    /// A new connection arrived.
    pub fn accept(self: *Admission) Decision {
        if (self.stopping) return self.reject(.server_stopping);
        if (self.live < self.limits.max_live) {
            self.live += 1;
            return .admit;
        }
        if (self.pending < self.limits.max_pending) {
            self.pending += 1;
            return .wait;
        }
        return self.reject(.pool_saturated);
    }

    fn reject(self: *Admission, r: Reason) Decision {
        self.reject_reason = r;
        return .reject;
    }

    /// A pending connection takes a freed live slot. False while the pool is
    /// still full (keep waiting) or when stopping (see `abandonPending`).
    pub fn promote(self: *Admission) bool {
        std.debug.assert(self.pending > 0);
        if (self.stopping or self.live >= self.limits.max_live) return false;
        self.pending -= 1;
        self.live += 1;
        return true;
    }

    /// A pending connection gave up after `pending_wait_ms`.
    pub fn expirePending(self: *Admission) Reason {
        std.debug.assert(self.pending > 0);
        self.pending -= 1;
        return .pending_expired;
    }

    /// A pending connection is dropped because the server is stopping (or
    /// its client left).
    pub fn abandonPending(self: *Admission) Reason {
        std.debug.assert(self.pending > 0);
        self.pending -= 1;
        return .server_stopping;
    }

    /// A live connection closed. True when a pending connection could now
    /// be promoted (wake one waiter).
    pub fn release(self: *Admission) bool {
        std.debug.assert(self.live > 0);
        self.live -= 1;
        return self.pending > 0 and !self.stopping;
    }

    /// A live connection that must authenticate starts being read.
    pub fn beginPreauth(self: *Admission) bool {
        if (self.preauth >= self.limits.max_preauth) {
            self.reject_reason = .preauthorization_saturated;
            return false;
        }
        self.preauth += 1;
        return true;
    }

    /// The connection authenticated or closed.
    pub fn endPreauth(self: *Admission) void {
        std.debug.assert(self.preauth > 0);
        self.preauth -= 1;
    }

    /// Stop admitting; later `accept`s are rejected with `server_stopping`.
    pub fn stop(self: *Admission) void {
        self.stopping = true;
    }
};

/// The reply for a rejected connection or request. The request id is
/// usually unknown (nothing was read), hence `id`.
pub fn overloadedLineAlloc(gpa: Allocator, id: std.json.Value, reason: Reason) Allocator.Error![]u8 {
    return request_state.errorLineAlloc(gpa, id, .overloaded, "Server overloaded", .{
        .retryable = true,
        .retry_after_ms = reason.retryAfterMs(),
        .reason = @tagName(reason),
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: rpc: admission defaults are cmux's numbers" {
    const l: Limits = .{};
    try testing.expectEqual(@as(u32, 64), l.max_live);
    try testing.expectEqual(@as(u32, 64), l.max_pending);
    try testing.expectEqual(@as(u32, 15_000), l.pending_wait_ms);
    try testing.expectEqual(@as(u32, 16), l.max_preauth);
}

test "unit: rpc: admission fills 64 live, then 64 pending, then rejects pool_saturated" {
    var a: Admission = .{};
    for (0..64) |_| try testing.expectEqual(Decision.admit, a.accept());
    for (0..64) |_| try testing.expectEqual(Decision.wait, a.accept());
    try testing.expectEqual(Decision.reject, a.accept());
    try testing.expectEqual(Reason.pool_saturated, a.reject_reason);
    try testing.expectEqual(@as(u32, 64), a.live);
    try testing.expectEqual(@as(u32, 64), a.pending);
}

test "unit: rpc: admission promotes a waiter only after a release" {
    var a: Admission = .init(.{ .max_live = 1, .max_pending = 1 });
    try testing.expectEqual(Decision.admit, a.accept());
    try testing.expectEqual(Decision.wait, a.accept());
    try testing.expect(!a.promote());
    try testing.expect(a.release());
    try testing.expect(a.promote());
    try testing.expectEqual(@as(u32, 1), a.live);
    try testing.expectEqual(@as(u32, 0), a.pending);
    try testing.expect(!a.release()); // nobody waiting
}

test "unit: rpc: admission pending expiry frees the pending place" {
    var a: Admission = .init(.{ .max_live = 1, .max_pending = 1 });
    _ = a.accept();
    _ = a.accept();
    try testing.expectEqual(Decision.reject, a.accept());
    try testing.expectEqual(Reason.pending_expired, a.expirePending());
    try testing.expectEqual(Decision.wait, a.accept());
}

test "unit: rpc: admission stopping rejects new and stops promotion" {
    var a: Admission = .init(.{ .max_live = 1, .max_pending = 2 });
    _ = a.accept();
    _ = a.accept();
    a.stop();
    try testing.expectEqual(Decision.reject, a.accept());
    try testing.expectEqual(Reason.server_stopping, a.reject_reason);
    try testing.expect(!a.release());
    try testing.expect(!a.promote());
    try testing.expectEqual(Reason.server_stopping, a.abandonPending());
    try testing.expectEqual(@as(u32, 0), a.pending);
}

test "unit: rpc: admission zero limits reject immediately" {
    var a: Admission = .init(.{ .max_live = 0, .max_pending = 0, .max_preauth = 0 });
    try testing.expectEqual(Decision.reject, a.accept());
    try testing.expect(!a.beginPreauth());
    try testing.expectEqual(Reason.preauthorization_saturated, a.reject_reason);
}

test "unit: rpc: admission caps unauthenticated readers at 16" {
    var a: Admission = .{};
    for (0..16) |_| try testing.expect(a.beginPreauth());
    try testing.expect(!a.beginPreauth());
    try testing.expectEqual(Reason.preauthorization_saturated, a.reject_reason);
    a.endPreauth();
    try testing.expect(a.beginPreauth());
}

test "unit: rpc: overloaded line has retryable, retry_after_ms and reason" {
    inline for (@typeInfo(Reason).@"enum".fields) |f| {
        const r: Reason = @enumFromInt(f.value);
        const line = try overloadedLineAlloc(testing.allocator, .null, r);
        defer testing.allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        const err = parsed.value.object.get("error").?.object;
        try testing.expectEqualStrings("overloaded", err.get("code").?.string);
        const data = err.get("data").?.object;
        try testing.expect(data.get("retryable").?.bool);
        try testing.expectEqual(@as(i64, r.retryAfterMs()), data.get("retry_after_ms").?.integer);
        try testing.expectEqualStrings(f.name, data.get("reason").?.string);
        try testing.expect(parsed.value.object.get("ok").?.bool == false);
    }
}
