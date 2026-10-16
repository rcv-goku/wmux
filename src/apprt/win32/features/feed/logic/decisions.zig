//! Pending-decision lifecycle (pure state). A blocking `feed.push` parks its
//! hook on a request id for up to 120 s; a reply from Feed, a banner or the
//! socket resolves it exactly once; the deadline, the agent's exit or a later
//! hook event from the same agent context close it without a decision. The
//! caller owns the real waiters (deferred RPC replies) and identifies them by
//! an opaque `Waiter` token; every transition that must answer a waiter
//! returns that token exactly once (G5). Time is passed in, never read.

const std = @import("std");
const proto = @import("wmux_proto");
const model = @import("model.zig");
const Uuid = proto.uuid.Uuid;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Opaque handle of a parked hook (e.g. connection generation + request id).
pub const Waiter = u64;

pub const max_wait_timeout_s: u32 = 120;
pub const wait_timeout_message = "feed.push wait_timeout_seconds must be between 0 and 120";

/// Parses `feed.push` `wait_timeout_seconds` into milliseconds. Absent or
/// null means 0 (non-blocking). Any JSON number in [0, 120] is accepted;
/// anything else is `error.InvalidWaitTimeout` (`wait_timeout_message`).
pub fn parseWaitTimeoutMs(v: ?Value) error{InvalidWaitTimeout}!u32 {
    const val = v orelse return 0;
    const secs: f64 = switch (val) {
        .null => return 0,
        .integer => |n| blk: {
            if (n < 0 or n > max_wait_timeout_s) return error.InvalidWaitTimeout;
            break :blk @floatFromInt(n);
        },
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidWaitTimeout,
        else => return error.InvalidWaitTimeout,
    };
    if (!std.math.isFinite(secs) or secs < 0 or secs > @as(f64, @floatFromInt(max_wait_timeout_s))) return error.InvalidWaitTimeout;
    return @intFromFloat(@round(secs * 1000.0));
}

pub const State = enum {
    waiting,
    resolved,
    timed_out,
    /// Agent exited, or the request was decided outside wmux.
    expired,

    pub fn itemStatus(s: State) model.Status {
        return switch (s) {
            .waiting => .pending,
            .resolved => .resolved,
            .timed_out => .timed_out,
            .expired => .expired,
        };
    }
};

pub const Pending = struct {
    arena: std.heap.ArenaAllocator,
    request_id: []const u8,
    item_id: Uuid,
    source: []const u8,
    session_id: ?[]const u8,
    pid: ?u32,
    created_at_ms: i64,
    /// Null when nobody waits with a timeout (wait 0).
    deadline_ms: ?i64,
    waiter: ?Waiter,
    state: State = .waiting,
    resolution: ?model.Resolution = null,
    settled_at_ms: ?i64 = null,
};

pub const Register = struct {
    request_id: []const u8,
    item_id: Uuid,
    source: []const u8 = "",
    session_id: ?[]const u8 = null,
    pid: ?u32 = null,
    now_ms: i64,
    /// From `parseWaitTimeoutMs`; 0 = do not park `waiter`.
    timeout_ms: u32 = 0,
    waiter: ?Waiter = null,
};

pub const RegisterResult = union(enum) {
    /// New request (or a re-push of a waiting one). `parked` tells whether
    /// the waiter was parked; when false, reply now with no decision.
    /// `replaced` is an earlier waiter of the same request id that the
    /// caller must now answer with no decision.
    registered: struct { parked: bool, deadline_ms: ?i64, replaced: ?Waiter = null },
    /// Re-push of an answered request: reply with this decision at once.
    already_resolved: model.Resolution,
    /// Re-push of a timed-out or expired request: reply with no decision.
    already_closed: State,
};

pub const ResolveResult = union(enum) {
    /// First resolution. Wake `waiter` (if any) with the decision.
    delivered: struct { item_id: Uuid, waiter: ?Waiter },
    /// Already resolved: nothing to wake. `same` when the decision repeats.
    duplicate: struct { item_id: Uuid, same: bool, previous: model.Resolution },
    /// Timed out or expired first; the hook is gone.
    closed: struct { item_id: Uuid, state: State },
    unknown,
};

/// A request closed without a decision: answer `waiter` (if any) with `{}`
/// and set the item status to `state.itemStatus()`. `request_id` borrows
/// from the table and stays valid until the next `pruneSettled`.
pub const Closed = struct {
    request_id: []const u8,
    item_id: Uuid,
    waiter: ?Waiter,
    state: State,
};

pub const Decisions = struct {
    gpa: Allocator,
    map: std.StringHashMapUnmanaged(*Pending) = .empty,
    /// Settled entries are kept this long so late replies stay idempotent.
    retain_settled_ms: i64 = 10 * std.time.ms_per_min,

    pub fn init(gpa: Allocator) Decisions {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Decisions) void {
        var it = self.map.valueIterator();
        while (it.next()) |p| destroyPending(self.gpa, p.*);
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    fn destroyPending(gpa: Allocator, p: *Pending) void {
        p.arena.deinit();
        gpa.destroy(p);
    }

    pub fn get(self: *const Decisions, request_id: []const u8) ?*const Pending {
        return self.map.get(request_id);
    }

    pub fn count(self: *const Decisions) usize {
        return self.map.count();
    }

    pub fn waitingCount(self: *const Decisions) usize {
        var n: usize = 0;
        var it = self.map.valueIterator();
        while (it.next()) |p| {
            if (p.*.state == .waiting) n += 1;
        }
        return n;
    }

    pub fn register(self: *Decisions, r: Register) Allocator.Error!RegisterResult {
        const park = r.timeout_ms > 0 and r.waiter != null;
        const deadline: ?i64 = if (park) r.now_ms + r.timeout_ms else null;
        if (self.map.get(r.request_id)) |p| switch (p.state) {
            .waiting => {
                // Copied before the overwrite (a conditional-expression
                // initializer aliased the field under ReleaseSafe).
                var replaced: ?Waiter = null;
                if (park) {
                    replaced = p.waiter;
                    p.waiter = r.waiter;
                    p.deadline_ms = deadline;
                }
                return .{ .registered = .{ .parked = park, .deadline_ms = p.deadline_ms, .replaced = replaced } };
            },
            .resolved => return .{ .already_resolved = p.resolution.? },
            .timed_out, .expired => return .{ .already_closed = p.state },
        };

        const p = try self.gpa.create(Pending);
        errdefer self.gpa.destroy(p);
        p.* = .{
            .arena = .init(self.gpa),
            .request_id = undefined,
            .item_id = r.item_id,
            .source = undefined,
            .session_id = null,
            .pid = r.pid,
            .created_at_ms = r.now_ms,
            .deadline_ms = deadline,
            .waiter = if (park) r.waiter else null,
        };
        errdefer p.arena.deinit();
        const a = p.arena.allocator();
        p.request_id = try a.dupe(u8, r.request_id);
        p.source = try a.dupe(u8, r.source);
        p.session_id = if (r.session_id) |s| try a.dupe(u8, s) else null;
        try self.map.put(self.gpa, p.request_id, p);
        return .{ .registered = .{ .parked = park, .deadline_ms = deadline } };
    }

    /// Applies a user decision. Idempotent: only the first call returns
    /// `.delivered` (and the waiter); later calls report `.duplicate`.
    pub fn resolve(self: *Decisions, request_id: []const u8, r: model.Resolution, now_ms: i64) Allocator.Error!ResolveResult {
        const p = self.map.get(request_id) orelse return .unknown;
        switch (p.state) {
            .waiting => {},
            .resolved => return .{ .duplicate = .{ .item_id = p.item_id, .same = p.resolution.?.eql(r), .previous = p.resolution.? } },
            .timed_out, .expired => return .{ .closed = .{ .item_id = p.item_id, .state = p.state } },
        }
        p.resolution = try r.dupe(p.arena.allocator());
        p.state = .resolved;
        p.settled_at_ms = now_ms;
        const w = p.waiter;
        p.waiter = null;
        return .{ .delivered = .{ .item_id = p.item_id, .waiter = w } };
    }

    fn settle(p: *Pending, state: State, now_ms: i64, out: *std.ArrayList(Closed), gpa: Allocator) Allocator.Error!void {
        try out.ensureUnusedCapacity(gpa, 1);
        p.state = state;
        p.settled_at_ms = now_ms;
        out.appendAssumeCapacity(.{ .request_id = p.request_id, .item_id = p.item_id, .waiter = p.waiter, .state = state });
        p.waiter = null;
    }

    /// Times out every waiting request whose deadline is at or before `now_ms`.
    pub fn timeoutDue(self: *Decisions, now_ms: i64, out: *std.ArrayList(Closed)) Allocator.Error!void {
        var it = self.map.valueIterator();
        while (it.next()) |pp| {
            const p = pp.*;
            if (p.state != .waiting) continue;
            const d = p.deadline_ms orelse continue;
            if (d <= now_ms) try settle(p, .timed_out, now_ms, out, self.gpa);
        }
    }

    /// Earliest deadline of a waiting request (for the timer).
    pub fn nextDeadline(self: *const Decisions) ?i64 {
        var best: ?i64 = null;
        var it = self.map.valueIterator();
        while (it.next()) |pp| {
            const p = pp.*;
            if (p.state != .waiting) continue;
            const d = p.deadline_ms orelse continue;
            if (best == null or d < best.?) best = d;
        }
        return best;
    }

    /// The agent process `pid` exited: expire its waiting requests.
    pub fn expirePid(self: *Decisions, pid: u32, now_ms: i64, out: *std.ArrayList(Closed)) Allocator.Error!void {
        var it = self.map.valueIterator();
        while (it.next()) |pp| {
            const p = pp.*;
            if (p.state == .waiting and p.pid == pid) try settle(p, .expired, now_ms, out, self.gpa);
        }
    }

    /// A later hook event arrived from the same agent context (source +
    /// session): earlier waiting requests were decided outside wmux. Requests
    /// created at or after `event_at_ms`, and `keep_request_id`, are kept.
    /// A null `session_id` matches nothing (no context to prove anything).
    pub fn retireContext(self: *Decisions, source: []const u8, session_id: ?[]const u8, event_at_ms: i64, keep_request_id: ?[]const u8, out: *std.ArrayList(Closed)) Allocator.Error!void {
        const sid = session_id orelse return;
        var it = self.map.valueIterator();
        while (it.next()) |pp| {
            const p = pp.*;
            if (p.state != .waiting) continue;
            if (p.created_at_ms >= event_at_ms) continue;
            if (!std.mem.eql(u8, p.source, source)) continue;
            const psid = p.session_id orelse continue;
            if (!std.mem.eql(u8, psid, sid)) continue;
            if (keep_request_id) |k| if (std.mem.eql(u8, k, p.request_id)) continue;
            try settle(p, .expired, event_at_ms, out, self.gpa);
        }
    }

    /// The parked client went away (pipe closed). The request stays open so
    /// the user can still answer, but nothing is woken; returns how many
    /// requests referenced `waiter`.
    pub fn detachWaiter(self: *Decisions, waiter: Waiter) usize {
        var n: usize = 0;
        var it = self.map.valueIterator();
        while (it.next()) |pp| {
            const p = pp.*;
            if (p.waiter == waiter) {
                p.waiter = null;
                n += 1;
            }
        }
        return n;
    }

    /// Drops settled entries older than `retain_settled_ms`. Invalidates
    /// `Closed.request_id` slices handed out earlier.
    pub fn pruneSettled(self: *Decisions, now_ms: i64) void {
        while (true) {
            var victim: ?*Pending = null;
            var it = self.map.valueIterator();
            while (it.next()) |pp| {
                const p = pp.*;
                const at = p.settled_at_ms orelse continue;
                if (now_ms - at >= self.retain_settled_ms) {
                    victim = p;
                    break;
                }
            }
            const p = victim orelse return;
            _ = self.map.remove(p.request_id);
            destroyPending(self.gpa, p);
        }
    }
};
