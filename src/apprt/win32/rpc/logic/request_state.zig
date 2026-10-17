//! Request lifecycle, connection generations and the reply lines the
//! transport itself owes (ADR-3.2). Pure: std and wmux_proto only.
//!
//! State machine of one request (ADR-3.2 "Request lifecycle"):
//!
//!     queued ──begin──▶ running ──complete──▶ done
//!       │                  │ └──markDeferred──▶ deferred ──complete──▶ done
//!       │                  └──expire──▶ abandoned        └──expire──▶ abandoned
//!       ├──complete──▶ done          (pipe-lane handlers reply inline)
//!       └──expire──▶ expired         (never ran: retryable)
//!
//! Every transition is a compare-and-swap, so the connection thread (which
//! expires requests on their deadline) and the UI thread or worker (which
//! begin and complete them) agree on exactly one outcome.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const envelope = proto.envelope;
const errors = proto.errors;

pub const State = enum(u8) { queued, running, deferred, done, expired, abandoned };

/// What `expire` found, which decides the timeout reply.
pub const Expiry = enum {
    /// queued → expired: the command never ran (`retryable:true`).
    not_started,
    /// running/deferred → abandoned: result unknown (`retryable:false`).
    abandoned,
    /// Already done (its reply is ready) or already expired: no timeout.
    none,
};

pub const Lifecycle = struct {
    state: std.atomic.Value(State) = .init(.queued),

    fn cas(self: *Lifecycle, from: State, to: State) bool {
        return self.state.cmpxchgStrong(from, to, .acq_rel, .acquire) == null;
    }

    pub fn get(self: *const Lifecycle) State {
        return self.state.load(.acquire);
    }

    /// queued → running. False means the request expired (or already
    /// finished) and the handler must not run.
    pub fn begin(self: *Lifecycle) bool {
        return self.cas(.queued, .running);
    }

    /// running → deferred (the handler promised a later completion).
    pub fn markDeferred(self: *Lifecycle) bool {
        return self.cas(.running, .deferred);
    }

    /// queued/running/deferred → done. False means the reply must be
    /// dropped (expired, abandoned or already completed).
    pub fn complete(self: *Lifecycle) bool {
        var cur = self.get();
        while (true) switch (cur) {
            .queued, .running, .deferred => {
                cur = self.state.cmpxchgWeak(cur, .done, .acq_rel, .acquire) orelse return true;
            },
            .done, .expired, .abandoned => return false,
        };
    }

    /// Deadline or shutdown: queued → expired, running/deferred → abandoned.
    pub fn expire(self: *Lifecycle) Expiry {
        var cur = self.get();
        while (true) switch (cur) {
            .queued => cur = self.state.cmpxchgWeak(cur, .expired, .acq_rel, .acquire) orelse return .not_started,
            .running, .deferred => cur = self.state.cmpxchgWeak(cur, .abandoned, .acq_rel, .acquire) orelse return .abandoned,
            .done, .expired, .abandoned => return .none,
        };
    }
};

/// Identifies one request on one connection; the same three fields as
/// `rpc/types.zig: Deferred` (the dispatcher converts field by field).
pub const Token = struct {
    /// Slot index of the connection (reused after the client leaves).
    conn_id: u64,
    /// Unique per accepted connection, never reused (starts at 1).
    generation: u64,
    /// Per-connection request number (starts at 1).
    request_seq: u64,

    pub fn eql(a: Token, b: Token) bool {
        return a.conn_id == b.conn_id and a.generation == b.generation and a.request_seq == b.request_seq;
    }
};

/// Connection slots with generations (ADR-3.2 "Deferred replies"). Not
/// thread-safe: the server guards it with its mutex. `T` is the per-slot
/// payload pointer (the server's `*Connection`).
pub fn Slots(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            generation: u64,
            value: T,
            /// The request currently owed a reply, if any.
            current_seq: u64 = 0,
        };

        entries: []?Entry,
        next_generation: u64 = 1,
        live: usize = 0,

        pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!Self {
            const entries = try gpa.alloc(?Entry, capacity);
            @memset(entries, null);
            return .{ .entries = entries };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.entries);
            self.* = undefined;
        }

        pub const Claimed = struct { conn_id: u64, generation: u64 };

        /// Takes the lowest free slot with a fresh generation; null when full.
        pub fn claim(self: *Self, value: T) ?Claimed {
            for (self.entries, 0..) |*e, i| {
                if (e.* != null) continue;
                const g = self.next_generation;
                self.next_generation += 1;
                e.* = .{ .generation = g, .value = value };
                self.live += 1;
                return .{ .conn_id = i, .generation = g };
            }
            return null;
        }

        /// Frees the slot if it still holds `generation`.
        pub fn release(self: *Self, conn_id: u64, generation: u64) void {
            if (self.entryFor(conn_id, generation) == null) return;
            self.entries[@intCast(conn_id)] = null;
            self.live -= 1;
        }

        /// The live entry for (conn_id, generation), or null when the slot is
        /// free or holds a later connection.
        pub fn entryFor(self: *Self, conn_id: u64, generation: u64) ?*Entry {
            if (conn_id >= self.entries.len) return null;
            const slot = &self.entries[@intCast(conn_id)];
            if (slot.* == null) return null;
            const p = &slot.*.?;
            return if (p.generation == generation) p else null;
        }

        /// The connection a completion for `t` may be delivered to: same
        /// slot, same generation and `t` is the request currently owed.
        pub fn resolve(self: *Self, t: Token) ?T {
            const e = self.entryFor(t.conn_id, t.generation) orelse return null;
            if (e.current_seq != t.request_seq) return null;
            return e.value;
        }
    };
}

// ---------------------------------------------------------------------------
// Reply lines owed by the transport (never by a handler)
// ---------------------------------------------------------------------------

/// ADR-3.2: the stage named by a UI-lane timeout.
pub const stage_main_actor = "main_actor";
/// The stage named when a connection that must authenticate does not send
/// a complete line within the pre-authorization read window.
pub const stage_preauthorization = "preauthorization";

pub const too_large_message = "Request too large";
pub const stopping_message = "Server stopping";

/// One failure reply line (no terminator) with `data` encoded from any
/// value std.json.Stringify accepts (or null). Falls back to the fixed
/// encode_error line like `envelope.encodeErrorAlloc`.
pub fn errorLineAlloc(gpa: Allocator, id: std.json.Value, code: errors.Code, message: []const u8, data: anytype) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data_value: ?std.json.Value = if (@TypeOf(data) == @TypeOf(null)) null else blk: {
        const text = std.json.Stringify.valueAlloc(arena, data, .{}) catch return error.OutOfMemory;
        break :blk std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return gpa.dupe(u8, envelope.encode_error_line),
        };
    };
    return envelope.encodeErrorAlloc(gpa, id, .{ .code = code, .message = message, .data = data_value });
}

/// `timeout {stage, deadline_ms, retryable}` (cli-socket-admission-deadlines).
pub fn timeoutLineAlloc(gpa: Allocator, id: std.json.Value, stage: []const u8, deadline_ms: u32, retryable: bool) Allocator.Error![]u8 {
    return errorLineAlloc(gpa, id, .timeout, errors.Code.timeout.defaultMessage(), .{
        .stage = stage,
        .deadline_ms = deadline_ms,
        .retryable = retryable,
    });
}

/// The timeout reply for an `expire` outcome; null for `.none`.
pub fn expiryLineAlloc(gpa: Allocator, id: std.json.Value, e: Expiry, stage: []const u8, deadline_ms: u32) Allocator.Error!?[]u8 {
    return switch (e) {
        .not_started => try timeoutLineAlloc(gpa, id, stage, deadline_ms, true),
        .abandoned => try timeoutLineAlloc(gpa, id, stage, deadline_ms, false),
        .none => null,
    };
}

/// Reply to a line over the cap. The line was never parsed, so `id` is null.
pub fn oversizedLineAlloc(gpa: Allocator, max_bytes: usize) Allocator.Error![]u8 {
    return errorLineAlloc(gpa, .null, .invalid_request, too_large_message, .{ .max_bytes = max_bytes });
}

/// Reply to a request that was already running when the server stopped
/// (queued ones get `overloaded server_stopping`, see admission.zig).
pub fn cancelledLineAlloc(gpa: Allocator, id: std.json.Value) Allocator.Error![]u8 {
    return errorLineAlloc(gpa, id, .cancelled, stopping_message, .{ .reason = "server_stopping", .retryable = false });
}

/// Best-effort request id of a raw line (after an optional
/// `_cmux_capability_v1 <token> ` prefix), for replies the transport writes
/// without dispatching: a top-level string or number `id`, else null.
/// Strings are copied into `arena`. Never fails on malformed input.
pub fn peekId(arena: Allocator, line: []const u8) std.json.Value {
    const cap = envelope.splitCapability(line) catch return .null;
    const t = std.mem.trimLeft(u8, cap.payload, " \t");
    if (t.len == 0 or t[0] != '{') return .null;
    var scanner: std.json.Scanner = .initCompleteInput(arena, t);
    defer scanner.deinit();
    if ((scanner.next() catch return .null) != .object_begin) return .null;
    while (true) {
        const key = scanner.nextAlloc(arena, .alloc_if_needed) catch return .null;
        const k = switch (key) {
            .string, .allocated_string => |s| s,
            else => return .null,
        };
        if (!std.mem.eql(u8, k, "id")) {
            scanner.skipValue() catch return .null;
            continue;
        }
        const v = scanner.nextAlloc(arena, .alloc_always) catch return .null;
        return switch (v) {
            .allocated_string => |s| .{ .string = s },
            .allocated_number => |s| if (std.fmt.parseInt(i64, s, 10)) |n| .{ .integer = n } else |_| .{ .number_string = s },
            else => .null,
        };
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: rpc: request state: begin then complete is done" {
    var l: Lifecycle = .{};
    try testing.expect(l.begin());
    try testing.expect(!l.begin());
    try testing.expect(l.complete());
    try testing.expectEqual(State.done, l.get());
    try testing.expect(!l.complete());
    try testing.expectEqual(Expiry.none, l.expire());
}

test "unit: rpc: request state: expiring a queued request makes it retryable and blocks begin" {
    var l: Lifecycle = .{};
    try testing.expectEqual(Expiry.not_started, l.expire());
    try testing.expectEqual(State.expired, l.get());
    try testing.expect(!l.begin());
    try testing.expect(!l.complete());
    try testing.expectEqual(Expiry.none, l.expire());
}

test "unit: rpc: request state: expiring a running or deferred request abandons it" {
    var l: Lifecycle = .{};
    try testing.expect(l.begin());
    try testing.expectEqual(Expiry.abandoned, l.expire());
    try testing.expect(!l.complete());

    var d: Lifecycle = .{};
    try testing.expect(!d.markDeferred()); // only from running
    try testing.expect(d.begin());
    try testing.expect(d.markDeferred());
    try testing.expectEqual(State.deferred, d.get());
    try testing.expectEqual(Expiry.abandoned, d.expire());
    try testing.expect(!d.complete());
}

test "unit: rpc: request state: inline completion from queued wins over a later expiry" {
    var l: Lifecycle = .{};
    try testing.expect(l.complete());
    try testing.expectEqual(Expiry.none, l.expire());
    try testing.expect(!l.begin());
}

test "unit: rpc: request state: racing complete and expire agree on one outcome" {
    for (0..200) |_| {
        var l: Lifecycle = .{};
        _ = l.begin();
        var completed = std.atomic.Value(bool).init(false);
        const T = struct {
            fn run(lc: *Lifecycle, out: *std.atomic.Value(bool)) void {
                out.store(lc.complete(), .release);
            }
        };
        const th = try std.Thread.spawn(.{}, T.run, .{ &l, &completed });
        const e = l.expire();
        th.join();
        // Exactly one side wins.
        try testing.expect(completed.load(.acquire) != (e == .abandoned));
    }
}

const TestSlots = Slots(u32);

test "unit: rpc: slots: generations are unique and a reused slot rejects old tokens" {
    var s = try TestSlots.init(testing.allocator, 2);
    defer s.deinit(testing.allocator);
    const a = s.claim(10).?;
    const b = s.claim(20).?;
    try testing.expect(s.claim(30) == null);
    try testing.expectEqual(@as(u64, 0), a.conn_id);
    try testing.expectEqual(@as(u64, 1), b.conn_id);
    try testing.expect(a.generation != b.generation);
    try testing.expectEqual(@as(usize, 2), s.live);

    s.entryFor(a.conn_id, a.generation).?.current_seq = 1;
    const old: Token = .{ .conn_id = a.conn_id, .generation = a.generation, .request_seq = 1 };
    try testing.expectEqual(@as(?u32, 10), s.resolve(old));

    s.release(a.conn_id, a.generation);
    try testing.expect(s.resolve(old) == null);
    const c = s.claim(30).?;
    try testing.expectEqual(a.conn_id, c.conn_id); // slot reused
    try testing.expect(c.generation > b.generation);
    s.entryFor(c.conn_id, c.generation).?.current_seq = 1;
    // Same slot and seq, older generation: never delivered to the new client.
    try testing.expect(s.resolve(old) == null);
    try testing.expectEqual(@as(?u32, 30), s.resolve(.{ .conn_id = c.conn_id, .generation = c.generation, .request_seq = 1 }));
}

test "unit: rpc: slots: stale seq, out-of-range ids and double release are ignored" {
    var s = try TestSlots.init(testing.allocator, 1);
    defer s.deinit(testing.allocator);
    const a = s.claim(1).?;
    s.entryFor(a.conn_id, a.generation).?.current_seq = 2;
    try testing.expect(s.resolve(.{ .conn_id = a.conn_id, .generation = a.generation, .request_seq = 1 }) == null);
    try testing.expect(s.resolve(.{ .conn_id = 99, .generation = a.generation, .request_seq = 2 }) == null);
    try testing.expect(s.resolve(.{ .conn_id = std.math.maxInt(u64), .generation = 0, .request_seq = 0 }) == null);
    s.release(a.conn_id, a.generation + 1); // wrong generation: no-op
    try testing.expectEqual(@as(usize, 1), s.live);
    s.release(a.conn_id, a.generation);
    s.release(a.conn_id, a.generation);
    try testing.expectEqual(@as(usize, 0), s.live);
}

test "unit: rpc: slots: zero capacity never admits" {
    var s = try TestSlots.init(testing.allocator, 0);
    defer s.deinit(testing.allocator);
    try testing.expect(s.claim(1) == null);
}

test "unit: rpc: timeout lines carry stage, deadline and retryable" {
    const a = try timeoutLineAlloc(testing.allocator, .{ .string = "r1" }, stage_main_actor, 10_000, true);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(
        "{\"id\":\"r1\",\"ok\":false,\"error\":{\"code\":\"timeout\",\"message\":\"Timed out\",\"data\":{\"stage\":\"main_actor\",\"deadline_ms\":10000,\"retryable\":true}}}",
        a,
    );
    const b = (try expiryLineAlloc(testing.allocator, .{ .integer = 7 }, .abandoned, stage_main_actor, 250)).?;
    defer testing.allocator.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "\"id\":7") != null);
    try testing.expect(std.mem.indexOf(u8, b, "\"retryable\":false") != null);
    try testing.expect((try expiryLineAlloc(testing.allocator, .null, .none, stage_main_actor, 1)) == null);
}

test "unit: rpc: oversized and cancelled lines are single-line v2 errors" {
    const o = try oversizedLineAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(o);
    try testing.expectEqualStrings(
        "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"invalid_request\",\"message\":\"Request too large\",\"data\":{\"max_bytes\":1048576}}}",
        o,
    );
    const c = try cancelledLineAlloc(testing.allocator, .{ .string = "x\ny" });
    defer testing.allocator.free(c);
    try testing.expect(std.mem.indexOfScalar(u8, c, '\n') == null);
    try testing.expect(std.mem.indexOf(u8, c, "\"code\":\"cancelled\"") != null);
    try testing.expect(std.mem.indexOf(u8, c, "\"reason\":\"server_stopping\"") != null);
}

test "unit: rpc: errorLineAlloc without data omits the data key" {
    const l = try errorLineAlloc(testing.allocator, .null, .busy, "Busy", null);
    defer testing.allocator.free(l);
    try testing.expectEqualStrings("{\"id\":null,\"ok\":false,\"error\":{\"code\":\"busy\",\"message\":\"Busy\"}}", l);
}

test "unit: rpc: peekId finds string, integer and float ids and tolerates garbage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("a\"b", peekId(arena, "{\"method\":\"x\",\"params\":{\"id\":1},\"id\":\"a\\\"b\"}").string);
    try testing.expectEqual(@as(i64, 42), peekId(arena, "  {\"id\":42}").integer);
    try testing.expectEqualStrings("1.5", peekId(arena, "{\"id\":1.5}").number_string);
    try testing.expectEqual(@as(i64, 3), peekId(arena, "_cmux_capability_v1 tok {\"id\":3}").integer);
    const garbage = [_][]const u8{ "", "ping", "{", "{\"id\":", "{\"id\":true}", "{\"id\":null}", "[1]", "{\"id\":[1]}", "\xff{\"id\":1}", "_cmux_capability_v1" };
    for (garbage) |g| try testing.expect(peekId(arena, g) == .null);
}
