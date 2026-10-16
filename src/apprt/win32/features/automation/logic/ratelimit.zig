//! Per-rule firing rate limits (cli-automations-config `rate_limit`).
//!
//! Every rule has a limit `{interval_seconds, maximum}`: at most `maximum`
//! firings in any sliding window of `interval_seconds`. An omitted limit is
//! one firing per second. `Limiter` keeps the timestamps of the last
//! `maximum` firings in a ring, so a check is O(1) and memory is bounded by
//! `max_maximum`. Times are monotonic milliseconds supplied by the caller;
//! a clock that steps backwards is treated as standing still, so it can never
//! release extra firings. `wouldAllow` never mutates (dry-run `test`).

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Limit = struct {
    interval_ms: u64 = default_interval_ms,
    maximum: u32 = default_maximum,

    pub fn eql(a: Limit, b: Limit) bool {
        return a.interval_ms == b.interval_ms and a.maximum == b.maximum;
    }
};

/// Limit of a rule without `rate_limit`: one firing per second.
pub const default_interval_ms: u64 = 1000;
pub const default_maximum: u32 = 1;
pub const default: Limit = .{};

/// Bounds accepted by the rules validator.
pub const min_interval_ms: u64 = 1;
/// One week.
pub const max_interval_ms: u64 = 7 * 24 * 60 * 60 * 1000;
pub const max_maximum: u32 = 10_000;

pub const Limiter = struct {
    limit: Limit = default,
    /// Ring of the last `limit.maximum` firing times (ms), oldest at `head`.
    stamps: []i64 = &.{},
    head: usize = 0,
    len: usize = 0,
    /// Latest time seen; earlier `now` values are raised to it.
    last_now: i64 = std.math.minInt(i64),

    pub fn init(limit: Limit) Limiter {
        return .{ .limit = limit };
    }

    pub fn deinit(self: *Limiter, gpa: Allocator) void {
        gpa.free(self.stamps);
        self.* = undefined;
    }

    fn clampNow(self: *const Limiter, now_ms: i64) i64 {
        return @max(now_ms, self.last_now);
    }

    fn oldest(self: *const Limiter) i64 {
        return self.stamps[self.head];
    }

    /// Firings counted in the window ending at `now_ms`.
    pub fn inWindow(self: *const Limiter, now_ms: i64) usize {
        const now = self.clampNow(now_ms);
        const cap = @min(self.len, self.stamps.len);
        var n: usize = 0;
        for (0..cap) |i| {
            const t = self.stamps[(self.head + i) % self.stamps.len];
            if (within(t, now, self.limit.interval_ms)) n += 1;
        }
        return n;
    }

    /// True when a firing at `now_ms` would be allowed. Does not change state.
    pub fn wouldAllow(self: *const Limiter, now_ms: i64) bool {
        if (self.limit.maximum == 0) return false;
        if (self.len < self.limit.maximum) return true;
        // Ring is full: the oldest of the last `maximum` firings must have left the window.
        return !within(self.oldest(), self.clampNow(now_ms), self.limit.interval_ms);
    }

    /// Records a firing at `now_ms` when allowed and returns whether it was.
    pub fn tryAcquire(self: *Limiter, gpa: Allocator, now_ms: i64) Allocator.Error!bool {
        if (!self.wouldAllow(now_ms)) {
            self.last_now = self.clampNow(now_ms);
            return false;
        }
        const now = self.clampNow(now_ms);
        if (self.stamps.len != self.limit.maximum) {
            self.stamps = try gpa.realloc(self.stamps, self.limit.maximum);
            self.head = 0;
            self.len = 0;
        }
        if (self.len < self.stamps.len) {
            self.stamps[(self.head + self.len) % self.stamps.len] = now;
            self.len += 1;
        } else {
            self.stamps[self.head] = now;
            self.head = (self.head + 1) % self.stamps.len;
        }
        self.last_now = now;
        return true;
    }

    /// Milliseconds from `now_ms` until a firing would be allowed (0 when allowed now).
    pub fn retryAfterMs(self: *const Limiter, now_ms: i64) u64 {
        if (self.wouldAllow(now_ms)) return 0;
        if (self.limit.maximum == 0) return std.math.maxInt(u64);
        const now = self.clampNow(now_ms);
        const until = satAdd(self.oldest(), self.limit.interval_ms);
        return if (until > now) @intCast(until - now) else 0;
    }
};

fn satAdd(t: i64, ms: u64) i64 {
    const add: i64 = if (ms > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(ms);
    return std.math.add(i64, t, add) catch std.math.maxInt(i64);
}

/// A firing at `t` still counts at `now` when `now < t + interval`.
fn within(t: i64, now: i64, interval_ms: u64) bool {
    return @as(i128, now) < @as(i128, t) + interval_ms;
}

/// Limiters keyed by rule id. `sync` after a (re)load keeps the state of
/// rules whose id and limit are unchanged, resets changed limits and drops
/// removed rules, so `automation reload` neither forgets recent firings nor
/// leaks.
pub const Table = struct {
    map: std.StringHashMapUnmanaged(Limiter) = .empty,

    pub fn deinit(self: *Table, gpa: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        self.map.deinit(gpa);
        self.* = undefined;
    }

    pub const RuleLimit = struct { id: []const u8, limit: Limit };

    pub fn sync(self: *Table, gpa: Allocator, rules: []const RuleLimit) Allocator.Error!void {
        // Drop removed rules.
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(gpa);
        var it = self.map.iterator();
        outer: while (it.next()) |e| {
            for (rules) |r| {
                if (std.mem.eql(u8, r.id, e.key_ptr.*)) continue :outer;
            }
            try stale.append(gpa, e.key_ptr.*);
        }
        for (stale.items) |key| {
            const kv = self.map.fetchRemove(key).?;
            var lim = kv.value;
            lim.deinit(gpa);
            gpa.free(kv.key);
        }
        // Add new rules; reset changed limits.
        for (rules) |r| {
            if (self.map.getPtr(r.id)) |lim| {
                if (!lim.limit.eql(r.limit)) {
                    lim.deinit(gpa);
                    lim.* = .init(r.limit);
                }
                continue;
            }
            const key = try gpa.dupe(u8, r.id);
            errdefer gpa.free(key);
            try self.map.put(gpa, key, .init(r.limit));
        }
    }

    pub fn get(self: *Table, id: []const u8) ?*Limiter {
        return self.map.getPtr(id);
    }

    /// Dry-run check for `id`; an unknown id uses a fresh default limiter.
    pub fn wouldAllow(self: *const Table, id: []const u8, now_ms: i64) bool {
        const lim = self.map.getPtr(id) orelse return true;
        return lim.wouldAllow(now_ms);
    }

    /// Records a firing of `id` when allowed. Unknown ids are rejected (sync first).
    pub fn tryAcquire(self: *Table, gpa: Allocator, id: []const u8, now_ms: i64) Allocator.Error!bool {
        const lim = self.map.getPtr(id) orelse return false;
        return lim.tryAcquire(gpa, now_ms);
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "unit: automation: rate limit defaults to one firing per second" {
    var lim: Limiter = .init(default);
    defer lim.deinit(testing.allocator);
    try testing.expect(try lim.tryAcquire(testing.allocator, 10_000));
    try testing.expect(!try lim.tryAcquire(testing.allocator, 10_999));
    try testing.expectEqual(@as(u64, 1), lim.retryAfterMs(10_999));
    try testing.expect(try lim.tryAcquire(testing.allocator, 11_000));
}

test "unit: automation: rate limit maximum 1 per 30 s rejects a second event within 30 s" {
    var lim: Limiter = .init(.{ .interval_ms = 30_000, .maximum = 1 });
    defer lim.deinit(testing.allocator);
    try testing.expect(try lim.tryAcquire(testing.allocator, 0));
    try testing.expect(!try lim.tryAcquire(testing.allocator, 1));
    try testing.expect(!try lim.tryAcquire(testing.allocator, 29_999));
    try testing.expectEqual(@as(u64, 1), lim.retryAfterMs(29_999));
    try testing.expect(try lim.tryAcquire(testing.allocator, 30_000));
}

test "unit: automation: rate limit is a sliding window over the last maximum firings" {
    var lim: Limiter = .init(.{ .interval_ms = 1000, .maximum = 3 });
    defer lim.deinit(testing.allocator);
    const gpa = testing.allocator;
    try testing.expect(try lim.tryAcquire(gpa, 0));
    try testing.expect(try lim.tryAcquire(gpa, 100));
    try testing.expect(try lim.tryAcquire(gpa, 200));
    try testing.expectEqual(@as(usize, 3), lim.inWindow(200));
    try testing.expect(!try lim.tryAcquire(gpa, 999));
    try testing.expect(try lim.tryAcquire(gpa, 1000)); // the firing at 0 left
    try testing.expect(!try lim.tryAcquire(gpa, 1099));
    try testing.expect(try lim.tryAcquire(gpa, 1100));
    try testing.expectEqual(@as(usize, 3), lim.inWindow(1100));
    try testing.expectEqual(@as(usize, 0), lim.inWindow(1_000_000));
}

test "unit: automation: rate limit dry run does not change state" {
    var lim: Limiter = .init(.{ .interval_ms = 1000, .maximum = 1 });
    defer lim.deinit(testing.allocator);
    for (0..10) |_| try testing.expect(lim.wouldAllow(5));
    try testing.expect(try lim.tryAcquire(testing.allocator, 5));
    try testing.expect(!lim.wouldAllow(6));
    try testing.expect(!lim.wouldAllow(6));
    try testing.expect(lim.wouldAllow(1005));
}

test "unit: automation: rate limit ignores a clock stepping backwards and extreme times" {
    const gpa = testing.allocator;
    var lim: Limiter = .init(.{ .interval_ms = 1000, .maximum = 1 });
    defer lim.deinit(gpa);
    try testing.expect(try lim.tryAcquire(gpa, 50_000));
    try testing.expect(!try lim.tryAcquire(gpa, 0)); // clock went back: still limited
    try testing.expect(!try lim.tryAcquire(gpa, 50_999));
    try testing.expect(try lim.tryAcquire(gpa, 51_000));

    var edge: Limiter = .init(.{ .interval_ms = max_interval_ms, .maximum = 1 });
    defer edge.deinit(gpa);
    try testing.expect(try edge.tryAcquire(gpa, std.math.maxInt(i64) - 5));
    try testing.expect(!try edge.tryAcquire(gpa, std.math.maxInt(i64)));
    var low: Limiter = .init(.{ .interval_ms = 1, .maximum = 1 });
    defer low.deinit(gpa);
    try testing.expect(try low.tryAcquire(gpa, std.math.minInt(i64)));
    try testing.expect(try low.tryAcquire(gpa, std.math.minInt(i64) + 1));
}

test "unit: automation: rate limit with a huge maximum stays bounded" {
    const gpa = testing.allocator;
    var lim: Limiter = .init(.{ .interval_ms = 60_000, .maximum = max_maximum });
    defer lim.deinit(gpa);
    for (0..max_maximum) |i| try testing.expect(try lim.tryAcquire(gpa, @intCast(i)));
    try testing.expect(!try lim.tryAcquire(gpa, max_maximum));
    try testing.expectEqual(@as(usize, max_maximum), lim.stamps.len);
    try testing.expect(try lim.tryAcquire(gpa, 60_000));
}

test "unit: automation: rate limit table frees everything on allocation failure" {
    const S = struct {
        fn run(gpa: Allocator) !void {
            var t: Table = .{};
            defer t.deinit(gpa);
            const three: Limit = .{ .interval_ms = 1000, .maximum = 3 };
            try t.sync(gpa, &.{ .{ .id = "a", .limit = three }, .{ .id = "b", .limit = default } });
            _ = try t.tryAcquire(gpa, "a", 0);
            _ = try t.tryAcquire(gpa, "b", 0);
            // Reload: a changes limit, b goes, c arrives.
            try t.sync(gpa, &.{ .{ .id = "a", .limit = default }, .{ .id = "c-✓", .limit = three } });
            _ = try t.tryAcquire(gpa, "c-✓", 1);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
}

test "unit: automation: rate limit table survives reload and drops removed rules" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    const slow: Limit = .{ .interval_ms = 30_000, .maximum = 1 };
    try t.sync(gpa, &.{ .{ .id = "a", .limit = slow }, .{ .id = "b", .limit = default } });
    try testing.expect(try t.tryAcquire(gpa, "a", 0));
    try testing.expect(try t.tryAcquire(gpa, "b", 0));
    try testing.expect(!try t.tryAcquire(gpa, "unknown", 0));
    try testing.expect(t.wouldAllow("unknown", 0));

    // Reload: a unchanged keeps its state, b removed, c (unicode id) added.
    try t.sync(gpa, &.{ .{ .id = "a", .limit = slow }, .{ .id = "c-✓", .limit = default } });
    try testing.expect(!t.wouldAllow("a", 10));
    try testing.expect(t.get("b") == null);
    try testing.expect(try t.tryAcquire(gpa, "c-✓", 10));

    // A changed limit resets the state.
    try t.sync(gpa, &.{.{ .id = "a", .limit = default }});
    try testing.expect(try t.tryAcquire(gpa, "a", 10));
    try testing.expectEqual(@as(u32, 1), t.map.count());

    // Empty config clears everything.
    try t.sync(gpa, &.{});
    try testing.expectEqual(@as(u32, 0), t.map.count());
}
