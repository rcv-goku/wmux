//! Per-connection polling limiter of the v2 pipe server (ADR-3.3): the
//! pure token bucket of logic/ratelimit.zig bound to a monotonic clock and
//! a mutex (the dispatcher may consult it from the connection thread or a
//! lane thread). std only, unit-tested natively.

const std = @import("std");
const logic = @import("../logic/ratelimit.zig");

pub const Config = logic.Config;
pub const isPollingMethod = logic.isPollingMethod;
pub const isPollingVerb = logic.isPollingVerb;
pub const rateLimitedLineAlloc = logic.rateLimitedLineAlloc;

pub const Limiter = struct {
    mutex: std.Thread.Mutex = .{},
    /// Monotonic origin; null when the platform has no monotonic clock
    /// (then the limiter never limits rather than failing requests).
    base: ?std.time.Instant,
    bucket: logic.TokenBucket,

    pub fn init(config: Config) Limiter {
        return .{ .base = std.time.Instant.now() catch null, .bucket = .init(config, 0) };
    }

    fn nowMs(self: *const Limiter) ?i64 {
        const base = self.base orelse return null;
        const now = std.time.Instant.now() catch return null;
        return @intCast(now.since(base) / std.time.ns_per_ms);
    }

    /// Takes one polling token: null when allowed, else `retry_after_ms`.
    pub fn take(self: *Limiter) ?u32 {
        const now = self.nowMs() orelse return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.bucket.take(now);
    }
};

const testing = std.testing;

test "unit: rpc: limiter limits the tenth immediate poll" {
    var l: Limiter = .init(.{});
    var limited: ?u32 = null;
    for (0..10) |_| limited = l.take();
    // Ten calls inside one refill period on any sane machine; if the clock
    // is unavailable the limiter allows everything.
    if (l.base != null) try testing.expect(limited != null and limited.? <= 100);
}
