//! Firing records and the concurrency cap (cli-automations-config,
//! cli-automation-cli `logs`).
//!
//! `Log` is a ring of the last `capacity` (256) firing records; a new record
//! evicts the oldest. At most `max_concurrent` firings run at once, and a
//! firing that would exceed that is recorded as
//! `dropped_busy` and does not run. Records own their strings; messages are
//! capped on a code-point boundary (G6). `automation logs [--limit <n>]`
//! returns the newest `n` records (default `default_logs_limit`) oldest
//! first.

const std = @import("std");
const wmux_proto = @import("wmux_proto");

const Allocator = std.mem.Allocator;

pub const capacity: usize = 256;
pub const max_concurrent: usize = 8;
pub const default_logs_limit: usize = 50;
pub const max_message_bytes: usize = 1024;

pub const Outcome = enum {
    /// Actions still running.
    running,
    /// Every action succeeded.
    ok,
    /// An action failed (`message` says which).
    failed,
    /// An action exceeded its timeout.
    timed_out,
    /// Not run: `max_concurrent` firings were already running.
    dropped_busy,

    pub fn text(self: Outcome) []const u8 {
        return @tagName(self);
    }
};

pub const Record = struct {
    seq: u64,
    rule_id: []const u8,
    event_name: []const u8,
    started_ms: i64,
    finished_ms: ?i64 = null,
    outcome: Outcome = .running,
    message: ?[]const u8 = null,

    fn deinit(self: *Record, gpa: Allocator) void {
        gpa.free(self.rule_id);
        gpa.free(self.event_name);
        if (self.message) |m| gpa.free(m);
        self.* = undefined;
    }

    pub fn write(self: *const Record, jw: *std.json.Stringify) std.Io.Writer.Error!void {
        try jw.beginObject();
        try jw.objectField("seq");
        try jw.write(self.seq);
        try jw.objectField("rule_id");
        try jw.write(self.rule_id);
        try jw.objectField("event");
        try jw.write(self.event_name);
        try jw.objectField("started_ms");
        try jw.write(self.started_ms);
        try jw.objectField("finished_ms");
        try jw.write(self.finished_ms);
        try jw.objectField("outcome");
        try jw.write(self.outcome.text());
        try jw.objectField("message");
        try jw.write(self.message);
        try jw.endObject();
    }
};

pub const Log = struct {
    ring: [capacity]Record = undefined,
    head: usize = 0,
    len: usize = 0,
    next_seq: u64 = 1,
    /// Sequence numbers of running firings (slots are held until `finish`,
    /// even when the record was evicted meanwhile).
    inflight: [max_concurrent]u64 = undefined,
    running: usize = 0,

    pub fn deinit(self: *Log, gpa: Allocator) void {
        for (0..self.len) |i| self.ring[(self.head + i) % capacity].deinit(gpa);
        self.* = undefined;
    }

    fn push(self: *Log, gpa: Allocator, rec: Record) void {
        if (self.len == capacity) {
            self.ring[self.head].deinit(gpa);
            self.ring[self.head] = rec;
            self.head = (self.head + 1) % capacity;
        } else {
            self.ring[(self.head + self.len) % capacity] = rec;
            self.len += 1;
        }
    }

    fn findPtr(self: *Log, seq: u64) ?*Record {
        if (self.len == 0) return null;
        const first = self.ring[self.head].seq;
        if (seq < first or seq >= first + self.len) return null;
        return &self.ring[(self.head + @as(usize, @intCast(seq - first))) % capacity];
    }

    pub fn find(self: *const Log, seq: u64) ?*const Record {
        return @constCast(self).findPtr(seq);
    }

    /// Starts a firing. Returns its sequence number, or null when the
    /// concurrency cap is reached (a `dropped_busy` record is kept).
    pub fn begin(self: *Log, gpa: Allocator, rule_id: []const u8, event_name: []const u8, now_ms: i64) Allocator.Error!?u64 {
        const busy = self.running >= max_concurrent;
        const id = try gpa.dupe(u8, rule_id);
        errdefer gpa.free(id);
        const ev = try gpa.dupe(u8, wmux_proto.utf8.truncateUtf8(event_name, max_message_bytes));
        const seq = self.next_seq;
        self.next_seq += 1;
        self.push(gpa, .{
            .seq = seq,
            .rule_id = id,
            .event_name = ev,
            .started_ms = now_ms,
            .finished_ms = if (busy) now_ms else null,
            .outcome = if (busy) .dropped_busy else .running,
        });
        if (busy) return null;
        self.inflight[self.running] = seq;
        self.running += 1;
        return seq;
    }

    /// Completes firing `seq`: releases its slot and updates its record
    /// when still kept. Unknown or already finished sequence numbers are ignored.
    pub fn finish(self: *Log, gpa: Allocator, seq: u64, outcome: Outcome, message: ?[]const u8, now_ms: i64) Allocator.Error!void {
        std.debug.assert(outcome != .running and outcome != .dropped_busy);
        const slot = std.mem.indexOfScalar(u64, self.inflight[0..self.running], seq) orelse return;
        if (self.findPtr(seq)) |rec| {
            rec.message = if (message) |m| try gpa.dupe(u8, wmux_proto.utf8.truncateUtf8(m, max_message_bytes)) else null;
            rec.outcome = outcome;
            rec.finished_ms = now_ms;
        }
        self.inflight[slot] = self.inflight[self.running - 1];
        self.running -= 1;
    }

    /// The newest `limit` records, oldest first (borrowed until the next mutation).
    pub fn recent(self: *const Log, limit: usize, out: *[capacity]*const Record) []*const Record {
        const n = @min(limit, self.len);
        const start = self.len - n;
        for (0..n) |i| out[i] = &self.ring[(self.head + start + i) % capacity];
        return out[0..n];
    }

    /// Writes `{"records":[...],"capacity":256,"running":n}` for `automation logs`.
    pub fn writeLogs(self: *const Log, limit: ?usize, jw: *std.json.Stringify) std.Io.Writer.Error!void {
        var buf: [capacity]*const Record = undefined;
        const recs = self.recent(limit orelse default_logs_limit, &buf);
        try jw.beginObject();
        try jw.objectField("records");
        try jw.beginArray();
        for (recs) |r| try r.write(jw);
        try jw.endArray();
        try jw.objectField("capacity");
        try jw.write(capacity);
        try jw.objectField("running");
        try jw.write(self.running);
        try jw.endObject();
    }
};

const testing = std.testing;

test "unit: automation: firing log ring evicts the oldest record past 256" {
    const gpa = testing.allocator;
    var log: Log = .{};
    defer log.deinit(gpa);
    var buf: [16]u8 = undefined;
    for (0..capacity + 44) |i| {
        const id = try std.fmt.bufPrint(&buf, "r{d}", .{i});
        const seq = (try log.begin(gpa, id, "workspace.created", @intCast(i))).?;
        try log.finish(gpa, seq, .ok, null, @intCast(i));
    }
    try testing.expectEqual(capacity, log.len);
    try testing.expectEqual(@as(usize, 0), log.running);
    var out: [capacity]*const Record = undefined;
    const all = log.recent(1000, &out);
    try testing.expectEqual(capacity, all.len);
    try testing.expectEqualStrings("r44", all[0].rule_id);
    try testing.expectEqualStrings("r299", all[all.len - 1].rule_id);
    const three = log.recent(3, &out);
    try testing.expectEqualStrings("r297", three[0].rule_id);
    try testing.expectEqual(@as(usize, 0), log.recent(0, &out).len);
    try testing.expect(log.find(1) == null);
    try testing.expectEqual(@as(u64, 300), log.find(300).?.seq);
}

test "unit: automation: firing log caps concurrent firings" {
    const gpa = testing.allocator;
    var log: Log = .{};
    defer log.deinit(gpa);
    var seqs: [max_concurrent]u64 = undefined;
    for (&seqs) |*s| s.* = (try log.begin(gpa, "r", "e", 0)).?;
    try testing.expect((try log.begin(gpa, "r", "e", 1)) == null);
    try testing.expectEqual(Outcome.dropped_busy, log.find(max_concurrent + 1).?.outcome);
    try log.finish(gpa, seqs[0], .failed, "rpc workspace.select: not_found", 2);
    try log.finish(gpa, seqs[0], .ok, null, 3); // second finish is ignored
    try testing.expectEqual(Outcome.failed, log.find(seqs[0]).?.outcome);
    try testing.expectEqual(max_concurrent - 1, log.running);
    try testing.expect((try log.begin(gpa, "r", "e", 4)) != null);
    try log.finish(gpa, 999_999, .ok, null, 5); // unknown seq: no effect
    try testing.expectEqual(max_concurrent, log.running);
}

test "unit: automation: firing log holds the slot of an evicted running firing until it finishes" {
    const gpa = testing.allocator;
    var log: Log = .{};
    defer log.deinit(gpa);
    const stuck = (try log.begin(gpa, "slow", "e", 0)).?;
    for (0..capacity) |_| {
        const s = (try log.begin(gpa, "fast", "e", 1)).?;
        try log.finish(gpa, s, .ok, null, 1);
    }
    try testing.expect(log.find(stuck) == null);
    try testing.expectEqual(@as(usize, 1), log.running);
    try log.finish(gpa, stuck, .timed_out, null, 2);
    try testing.expectEqual(@as(usize, 0), log.running);
    try log.finish(gpa, stuck, .timed_out, null, 3);
    try testing.expectEqual(@as(usize, 0), log.running);
}

test "unit: automation: firing log JSON and message caps" {
    const gpa = testing.allocator;
    var log: Log = .{};
    defer log.deinit(gpa);
    const big = try gpa.alloc(u8, max_message_bytes * 2);
    defer gpa.free(big);
    for (0..big.len / 2) |k| @memcpy(big[k * 2 ..][0..2], "é");
    const s = (try log.begin(gpa, "règle", big, 10)).?;
    try log.finish(gpa, s, .failed, big, 20);
    const r = log.find(s).?;
    try testing.expect(r.message.?.len <= max_message_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(r.message.?));
    try testing.expect(r.event_name.len <= max_message_bytes);

    var log2: Log = .{};
    defer log2.deinit(gpa);
    const a = (try log2.begin(gpa, "a", "workspace.created", 1)).?;
    try log2.finish(gpa, a, .ok, null, 2);
    _ = try log2.begin(gpa, "b", "agent.needs_input", 3);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try log2.writeLogs(null, &jw);
    try testing.expectEqualStrings(
        \\{"records":[{"seq":1,"rule_id":"a","event":"workspace.created","started_ms":1,"finished_ms":2,"outcome":"ok","message":null},{"seq":2,"rule_id":"b","event":"agent.needs_input","started_ms":3,"finished_ms":null,"outcome":"running","message":null}],"capacity":256,"running":1}
    , aw.written());
    var aw2: std.Io.Writer.Allocating = .init(gpa);
    defer aw2.deinit();
    var jw2: std.json.Stringify = .{ .writer = &aw2.writer };
    try log2.writeLogs(1, &jw2);
    try testing.expect(std.mem.indexOf(u8, aw2.written(), "\"seq\":1") == null);
}
