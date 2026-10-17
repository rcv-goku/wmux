//! Per-connection polling rate limit with cmux's numbers (ADR-3.3,
//! cli-socket-admission-deadlines): methods flagged `polling` share one
//! token bucket per connection, burst 9, one token per 100 ms. Excess →
//! `rate_limited {retry_after_ms}`. Pure: time is passed in (monotonic ms).

const std = @import("std");
const Allocator = std.mem.Allocator;
const request_state = @import("request_state.zig");

pub const Config = struct {
    burst: u32 = 9,
    refill_ms: u32 = 100,
};

pub const TokenBucket = struct {
    config: Config,
    tokens: u32,
    /// Time of the last whole-token refill (monotonic ms).
    last_ms: i64,

    /// A full bucket at `now_ms`.
    pub fn init(config: Config, now_ms: i64) TokenBucket {
        return .{ .config = config, .tokens = config.burst, .last_ms = now_ms };
    }

    fn refill(self: *TokenBucket, now_ms: i64) void {
        if (self.config.refill_ms == 0) {
            self.tokens = self.config.burst;
            self.last_ms = now_ms;
            return;
        }
        // A clock that steps backwards restarts the refill period.
        if (now_ms < self.last_ms) self.last_ms = now_ms;
        const elapsed: u64 = @intCast(now_ms - self.last_ms);
        const add = elapsed / self.config.refill_ms;
        if (add == 0) return;
        const room = self.config.burst -| self.tokens;
        if (add >= room) {
            self.tokens = self.config.burst;
            self.last_ms = now_ms;
        } else {
            self.tokens += @intCast(add);
            self.last_ms += @intCast(add * self.config.refill_ms);
        }
    }

    /// Takes one token. Null on success, else the ms until one is available.
    pub fn take(self: *TokenBucket, now_ms: i64) ?u32 {
        self.refill(now_ms);
        if (self.tokens > 0) {
            self.tokens -= 1;
            return null;
        }
        const since: u64 = @intCast(now_ms - self.last_ms);
        const wait = self.config.refill_ms -| @as(u32, @intCast(@min(since, self.config.refill_ms)));
        return @max(wait, 1);
    }

    /// Tokens available at `now_ms` (refills first).
    pub fn available(self: *TokenBucket, now_ms: i64) u32 {
        self.refill(now_ms);
        return self.tokens;
    }
};

/// v2 polling methods: the inventory list (ADR-3.3's list plus
/// `window.displays`). The registry's `Method.polling` flag is
/// authoritative for v2; this table serves adapters and tests.
pub const polling_v2 = [_][]const u8{
    "pane.list",              "pane.surfaces",     "surface.current", "surface.list",
    "surface.read_selection", "surface.read_text", "system.identify", "system.memory",
    "system.top",             "system.tree",       "window.current",  "window.displays",
    "window.list",            "workspace.current", "workspace.list",
};

/// cmux text-v1 polling verbs.
pub const polling_v1 = [_][]const u8{
    "current_window", "current_workspace", "list_surfaces", "list_windows", "list_workspaces", "read_screen",
};

const v2_map = std.StaticStringMap(void).initComptime(kvs(&polling_v2));
const v1_map = std.StaticStringMap(void).initComptime(kvs(&polling_v1));

fn kvs(comptime names: []const []const u8) [names.len]struct { []const u8 } {
    var out: [names.len]struct { []const u8 } = undefined;
    for (names, 0..) |n, i| out[i] = .{n};
    return out;
}

pub fn isPollingMethod(method: []const u8) bool {
    return v2_map.has(method);
}

/// Text-v1 verbs match case-insensitively (ADR-3.7).
pub fn isPollingVerb(verb: []const u8) bool {
    var buf: [32]u8 = undefined;
    if (verb.len > buf.len) return false;
    return v1_map.has(std.ascii.lowerString(&buf, verb));
}

/// `{"id":…,"ok":false,"error":{"code":"rate_limited",…,"data":{"retry_after_ms":N}}}`.
pub fn rateLimitedLineAlloc(gpa: Allocator, id: std.json.Value, retry_after_ms: u32) Allocator.Error![]u8 {
    return request_state.errorLineAlloc(gpa, id, .rate_limited, "Rate limited", .{ .retry_after_ms = retry_after_ms });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: rpc: ratelimit allows a burst of 9 then limits with retry_after_ms" {
    var b: TokenBucket = .init(.{}, 1_000);
    for (0..9) |_| try testing.expect(b.take(1_000) == null);
    try testing.expectEqual(@as(?u32, 100), b.take(1_000));
    try testing.expectEqual(@as(?u32, 60), b.take(1_040));
    try testing.expect(b.take(1_100) == null);
    try testing.expectEqual(@as(?u32, 100), b.take(1_100));
}

test "unit: rpc: ratelimit refills one token per 100 ms up to the burst" {
    var b: TokenBucket = .init(.{}, 0);
    for (0..9) |_| _ = b.take(0);
    try testing.expectEqual(@as(u32, 0), b.available(99));
    try testing.expectEqual(@as(u32, 1), b.available(100));
    try testing.expectEqual(@as(u32, 3), b.available(350));
    // Partial periods carry over: the 4th token arrives at 400, not 450.
    try testing.expectEqual(@as(u32, 4), b.available(400));
    try testing.expectEqual(@as(u32, 9), b.available(1_000_000));
}

test "unit: rpc: ratelimit 50 tight polls hit rate_limited (acceptance a)" {
    var b: TokenBucket = .init(.{}, 0);
    var limited: usize = 0;
    var t: i64 = 0;
    for (0..50) |_| {
        if (b.take(t) != null) limited += 1;
        t += 2; // a tight loop: 2 ms per call
    }
    try testing.expect(limited > 0);
    try testing.expect(limited <= 50 - 9);
}

test "unit: rpc: ratelimit survives a clock step backwards and huge gaps" {
    var b: TokenBucket = .init(.{}, 10_000);
    for (0..9) |_| _ = b.take(10_000);
    const r = b.take(5_000).?;
    try testing.expect(r >= 1 and r <= 100);
    try testing.expect(b.take(std.math.maxInt(i64) / 2) == null);
}

test "unit: rpc: ratelimit zero refill period never limits" {
    var b: TokenBucket = .init(.{ .burst = 1, .refill_ms = 0 }, 0);
    for (0..20) |_| try testing.expect(b.take(0) == null);
}

test "unit: rpc: ratelimit polling tables" {
    for (polling_v2) |m| try testing.expect(isPollingMethod(m));
    try testing.expect(isPollingMethod("workspace.list"));
    try testing.expect(!isPollingMethod("workspace.create"));
    try testing.expect(!isPollingMethod("Workspace.List"));
    try testing.expect(!isPollingMethod(""));
    try testing.expect(isPollingVerb("list_workspaces"));
    try testing.expect(isPollingVerb("READ_SCREEN"));
    try testing.expect(!isPollingVerb("send"));
    try testing.expect(!isPollingVerb("x" ** 100));
    // Tables are sorted and free of duplicates.
    for (polling_v2[1..], 1..) |m, i| try testing.expect(std.mem.order(u8, polling_v2[i - 1], m) == .lt);
    for (polling_v1[1..], 1..) |m, i| try testing.expect(std.mem.order(u8, polling_v1[i - 1], m) == .lt);
}

test "unit: rpc: rate_limited line" {
    const l = try rateLimitedLineAlloc(testing.allocator, .{ .string = "q" }, 40);
    defer testing.allocator.free(l);
    try testing.expectEqualStrings(
        "{\"id\":\"q\",\"ok\":false,\"error\":{\"code\":\"rate_limited\",\"message\":\"Rate limited\",\"data\":{\"retry_after_ms\":40}}}",
        l,
    );
}
