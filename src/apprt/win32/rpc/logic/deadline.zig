//! Lane deadlines, the modal hold and the exactly-once reply rule of the
//! v2 dispatcher (ARCHITECTURE.md ADR-3.2, ground rule G5). Pure: std,
//! wmux_proto and the sibling request_state.zig.
//!
//! A UI-lane request is posted to the UI thread and its connection thread
//! waits `deadline_ms` (10 s by default) for the reply. The request state
//! machine (request_state.zig) makes the race between the UI thread
//! (`begin`, `complete`) and the deadline (`expire`) end in exactly one
//! reply line:
//!
//! - expired while queued (never begun): `timeout {stage:"main_actor",
//!   deadline_ms, retryable:true}`; the UI thread then skips it;
//! - expired while running or deferred: `timeout {…, retryable:false}`;
//!   the late reply of the handler is dropped;
//! - completed first: the handler's reply; a later expiry writes nothing.
//!
//! While a modal loop runs (`app.modal.depth > 0`), UI-lane requests whose
//! access is not `.read` stay queued (their deadline keeps running), so a
//! mutation never runs inside TrackPopupMenu or MessageBox loops.

const std = @import("std");
const request_state = @import("request_state.zig");

const Lifecycle = request_state.Lifecycle;

/// The UI lane's default budget (ADR-3.2).
pub const ui_deadline_ms: u32 = 10_000;

/// Budget of a legacy wmux JSON request on the v2 transport. The legacy
/// server had no deadline; async browser commands may take a while, so
/// they get a longer budget than v2 methods.
pub const legacy_deadline_ms: u32 = 60_000;

/// Stage names of the timeout reply per lane.
pub const stage_main_actor = request_state.stage_main_actor;
pub const stage_worker = "worker";
pub const stage_pipe = "pipe";

pub const Lane = enum { pipe, worker, ui };

/// The stage a timeout of `lane` names.
pub fn stageOf(lane: Lane) []const u8 {
    return switch (lane) {
        .pipe => stage_pipe,
        .worker => stage_worker,
        .ui => stage_main_actor,
    };
}

/// Milliseconds left of `deadline_ms` after `spent_ms`; null for no
/// deadline (0 = streaming / long-poll methods).
pub fn remainingMs(deadline_ms: u32, spent_ms: u64) ?u32 {
    if (deadline_ms == 0) return null;
    return @intCast(@as(u64, deadline_ms) -| spent_ms);
}

/// Whether a UI-lane request must wait for the modal loop to end.
pub fn holdForModal(read_only: bool, modal_depth: u32) bool {
    return modal_depth > 0 and !read_only;
}

/// G5 guard: the first `claim` wins, every later one loses. A handler's
/// reply, a deferred completion and the error path of the dispatcher all
/// claim before they encode, so a request is answered at most once by the
/// dispatcher (the transport's lifecycle then decides between that reply
/// and the deadline's).
pub const ReplyOnce = struct {
    done: std.atomic.Value(bool) = .init(false),

    pub fn claim(self: *ReplyOnce) bool {
        return self.done.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
    }

    pub fn claimed(self: *const ReplyOnce) bool {
        return self.done.load(.acquire);
    }
};

/// One UI-lane request seen from both sides, as the transport and the
/// dispatcher drive it: the UI thread runs `serve` (begin, handler,
/// complete) and the connection thread `expireAt` its deadline. Exactly one
/// of them produces the line that reaches the client.
pub const UiExchange = struct {
    lifecycle: Lifecycle = .{},
    once: ReplyOnce = .{},
    /// Lines delivered to the client (test bookkeeping).
    delivered: std.atomic.Value(u32) = .init(0),

    pub const Served = enum { replied, skipped, dropped };

    /// UI thread: run the handler unless the request expired, then try to
    /// deliver its reply.
    pub fn serve(self: *UiExchange) Served {
        if (!self.lifecycle.begin()) return .skipped;
        if (!self.once.claim()) return .dropped;
        if (!self.lifecycle.complete()) return .dropped;
        _ = self.delivered.fetchAdd(1, .acq_rel);
        return .replied;
    }

    /// Connection thread at the deadline: the expiry outcome; a timeout
    /// line is written for `.not_started` and `.abandoned` only.
    pub fn expireAt(self: *UiExchange) request_state.Expiry {
        const e = self.lifecycle.expire();
        if (e != .none) _ = self.delivered.fetchAdd(1, .acq_rel);
        return e;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn timeoutData(gpa: std.mem.Allocator, line: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, line, .{});
}

test "unit: rpc: ui-lane request replies exactly once" {
    // Completed before the deadline: one reply, a later expiry writes nothing.
    var a: UiExchange = .{};
    try testing.expectEqual(UiExchange.Served.replied, a.serve());
    try testing.expectEqual(request_state.Expiry.none, a.expireAt());
    try testing.expectEqual(@as(u32, 1), a.delivered.load(.acquire));
    // A second completion attempt (a buggy double reply) is dropped.
    try testing.expect(!a.once.claim());

    // Racing the UI thread against the deadline many times: always one line.
    for (0..500) |_| {
        var x: UiExchange = .{};
        const T = struct {
            fn run(e: *UiExchange) void {
                _ = e.serve();
            }
        };
        const th = try std.Thread.spawn(.{}, T.run, .{&x});
        _ = x.expireAt();
        th.join();
        try testing.expectEqual(@as(u32, 1), x.delivered.load(.acquire));
    }
}

test "unit: rpc: a queued ui-lane request expires with timeout main_actor retryable true" {
    var x: UiExchange = .{};
    const e = x.expireAt();
    try testing.expectEqual(request_state.Expiry.not_started, e);
    // The UI thread then skips it: the command never runs.
    try testing.expectEqual(UiExchange.Served.skipped, x.serve());
    const line = (try request_state.expiryLineAlloc(testing.allocator, .{ .string = "q1" }, e, stageOf(.ui), ui_deadline_ms)).?;
    defer testing.allocator.free(line);
    var parsed = try timeoutData(testing.allocator, line);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("timeout", err.get("code").?.string);
    const data = err.get("data").?.object;
    try testing.expectEqualStrings("main_actor", data.get("stage").?.string);
    try testing.expectEqual(@as(i64, 10_000), data.get("deadline_ms").?.integer);
    try testing.expect(data.get("retryable").?.bool);
    try testing.expectEqualStrings("q1", parsed.value.object.get("id").?.string);
}

test "unit: rpc: a running ui-lane request expires with retryable false and its late reply is dropped" {
    var x: UiExchange = .{};
    try testing.expect(x.lifecycle.begin()); // the handler started
    const e = x.expireAt();
    try testing.expectEqual(request_state.Expiry.abandoned, e);
    // The handler finishes after the deadline: nothing more reaches the client.
    try testing.expect(x.once.claim());
    try testing.expect(!x.lifecycle.complete());
    try testing.expectEqual(@as(u32, 1), x.delivered.load(.acquire));
    const line = (try request_state.expiryLineAlloc(testing.allocator, .{ .integer = 7 }, e, stageOf(.ui), 250)).?;
    defer testing.allocator.free(line);
    var parsed = try timeoutData(testing.allocator, line);
    defer parsed.deinit();
    const data = parsed.value.object.get("error").?.object.get("data").?.object;
    try testing.expect(!data.get("retryable").?.bool);
    try testing.expectEqualStrings("main_actor", data.get("stage").?.string);

    // Deferred requests count as running.
    var d: UiExchange = .{};
    try testing.expect(d.lifecycle.begin());
    try testing.expect(d.lifecycle.markDeferred());
    try testing.expectEqual(request_state.Expiry.abandoned, d.expireAt());
}

test "unit: rpc: modal hold keeps only non-read ui requests queued" {
    try testing.expect(!holdForModal(true, 0));
    try testing.expect(!holdForModal(false, 0));
    try testing.expect(!holdForModal(true, 2));
    try testing.expect(holdForModal(false, 1));
}

test "unit: rpc: deadlines per lane" {
    try testing.expectEqualStrings("main_actor", stageOf(.ui));
    try testing.expectEqualStrings("worker", stageOf(.worker));
    try testing.expectEqual(@as(?u32, null), remainingMs(0, 5));
    try testing.expectEqual(@as(?u32, 9_000), remainingMs(10_000, 1_000));
    try testing.expectEqual(@as(?u32, 0), remainingMs(10, 50));
}
