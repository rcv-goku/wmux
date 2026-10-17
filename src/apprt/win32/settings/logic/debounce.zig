//! Pure timing and change-detection helpers of the settings watcher
//! (ARCHITECTURE.md ADR-5.4): the 300 ms quiet-period debounce, the 60 s
//! policy poll, content hashes that skip no-op saves and self-writes, and
//! the file-name matching of ReadDirectoryChangesW records. std only, so
//! `zig build test-fast` runs the tests.

const std = @import("std");

/// Quiet period after the last change record before a reload runs.
pub const quiet_ms: i64 = 300;

/// Policy re-read period (ADR-5.7).
pub const policy_poll_ms: i64 = 60_000;

/// Coalesces bursts of change records (editors write, rename and touch a
/// file several times per save) into one reload `quiet_ms` after the last
/// record. Times are milliseconds on any monotonic clock.
pub const Debouncer = struct {
    deadline: ?i64 = null,

    /// A change record arrived at `now`: (re)start the quiet period.
    pub fn touch(self: *Debouncer, now: i64) void {
        self.deadline = now + quiet_ms;
    }

    pub fn pending(self: *const Debouncer) bool {
        return self.deadline != null;
    }

    /// True once when the quiet period has elapsed (and clears it).
    pub fn fire(self: *Debouncer, now: i64) bool {
        const d = self.deadline orelse return false;
        if (now < d) return false;
        self.deadline = null;
        return true;
    }

    /// Milliseconds until the deadline (0 when due), or null when idle.
    pub fn remaining(self: *const Debouncer, now: i64) ?i64 {
        const d = self.deadline orelse return null;
        return @max(0, d - now);
    }
};

/// The next policy re-read: `policy_poll_ms` after the previous one.
pub const PollClock = struct {
    next: i64,

    pub fn init(now: i64) PollClock {
        return .{ .next = now + policy_poll_ms };
    }

    /// True once per period (and schedules the next one).
    pub fn due(self: *PollClock, now: i64) bool {
        if (now < self.next) return false;
        self.next = now + policy_poll_ms;
        return true;
    }

    pub fn remaining(self: *const PollClock, now: i64) i64 {
        return @max(0, self.next - now);
    }
};

/// How long the watcher may block: until the earliest of the debounce
/// deadline and the policy poll, as a Win32 wait timeout.
pub fn waitTimeoutMs(debounce: *const Debouncer, poll: *const PollClock, now: i64) u32 {
    var ms = poll.remaining(now);
    if (debounce.remaining(now)) |d| ms = @min(ms, d);
    return @intCast(std.math.clamp(ms, 0, std.math.maxInt(u31)));
}

/// Hash of a file's bytes; null stands for "missing".
pub fn contentHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x77_6d_75_78, bytes);
}

/// Last seen content hash per watched path (paths compare ASCII
/// case-insensitively, like NTFS names). A change is reported only when
/// the hash differs, so a save that rewrites the same bytes, or the
/// layer's own write of a file it just generated, never reloads.
pub const HashBook = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct { path: []u8, hash: ?u64 };

    pub fn deinit(self: *HashBook, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| gpa.free(e.path);
        self.entries.deinit(gpa);
        self.* = .{};
    }

    fn find(self: *HashBook, path: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.ascii.eqlIgnoreCase(e.path, path)) return e;
        }
        return null;
    }

    /// Record `hash` for `path`; true when it differs from the previous
    /// record (a path seen for the first time counts as changed unless it
    /// is missing).
    pub fn update(self: *HashBook, gpa: std.mem.Allocator, path: []const u8, hash: ?u64) std.mem.Allocator.Error!bool {
        if (self.find(path)) |e| {
            if (e.hash == hash) return false;
            e.hash = hash;
            return true;
        }
        const copy = try gpa.dupe(u8, path);
        errdefer gpa.free(copy);
        try self.entries.append(gpa, .{ .path = copy, .hash = hash });
        return hash != null;
    }

    pub fn get(self: *HashBook, path: []const u8) ??u64 {
        const e = self.find(path) orelse return null;
        return e.hash;
    }
};

/// Whether a ReadDirectoryChangesW record name (relative to the watched
/// directory, possibly `sub\name`) names the file `basename`.
pub fn recordNames(record: []const u8, basename: []const u8) bool {
    const tail = if (std.mem.lastIndexOfAny(u8, record, "\\/")) |i| record[i + 1 ..] else record;
    return std.ascii.eqlIgnoreCase(tail, basename);
}

/// Labels of the sources that triggered a reload, in precedence order,
/// joined by '+' ("wmux.json", "cmux.json+wmux.json", "policy").
pub const Triggers = struct {
    bits: u8 = 0,

    pub const Kind = enum(u3) { ghostty, cmux_json, wmux_json, pack, project, policy, manual };

    pub fn add(self: *Triggers, k: Kind) void {
        self.bits |= @as(u8, 1) << @intFromEnum(k);
    }

    pub fn has(self: Triggers, k: Kind) bool {
        return self.bits & (@as(u8, 1) << @intFromEnum(k)) != 0;
    }

    pub fn isEmpty(self: Triggers) bool {
        return self.bits == 0;
    }

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .ghostty => "ghostty",
            .cmux_json => "cmux.json",
            .wmux_json => "wmux.json",
            .pack => "pack",
            .project => "project",
            .policy => "policy",
            .manual => "manual",
        };
    }

    /// Writes the joined label into `buf` ("startup" when empty).
    pub fn format(self: Triggers, buf: []u8) []const u8 {
        if (self.isEmpty()) return "startup";
        var n: usize = 0;
        inline for (std.meta.fields(Kind)) |f| {
            const k: Kind = @enumFromInt(f.value);
            if (self.has(k)) {
                const l = label(k);
                const sep: usize = if (n > 0) 1 else 0;
                if (n + sep + l.len > buf.len) return buf[0..n];
                if (sep == 1) buf[n] = '+';
                @memcpy(buf[n + sep ..][0..l.len], l);
                n += sep + l.len;
            }
        }
        return buf[0..n];
    }
};

const testing = std.testing;

test "unit: settings: debounce waits 300 ms after the last change" {
    var d: Debouncer = .{};
    try testing.expect(!d.fire(0));
    try testing.expect(d.remaining(0) == null);
    d.touch(1000);
    try testing.expect(!d.fire(1100));
    d.touch(1200); // a burst restarts the quiet period
    try testing.expect(!d.fire(1450));
    try testing.expectEqual(@as(?i64, 50), d.remaining(1450));
    try testing.expect(d.fire(1500));
    try testing.expect(!d.fire(1600)); // fires once
    try testing.expect(!d.pending());
}

test "unit: settings: policy poll every 60 s and the wait timeout" {
    var p = PollClock.init(0);
    var d: Debouncer = .{};
    try testing.expect(!p.due(59_999));
    try testing.expectEqual(@as(u32, 60_000), waitTimeoutMs(&d, &p, 0));
    d.touch(100);
    try testing.expectEqual(@as(u32, 300), waitTimeoutMs(&d, &p, 100));
    try testing.expect(p.due(60_000));
    try testing.expect(!p.due(60_001));
    try testing.expectEqual(@as(u32, 0), waitTimeoutMs(&d, &p, 1_000_000));
}

test "unit: settings: content hashes skip no-op saves and self-writes" {
    const gpa = testing.allocator;
    var book: HashBook = .{};
    defer book.deinit(gpa);
    try testing.expect(!try book.update(gpa, "C:\\cfg\\wmux.json", null)); // missing at start
    try testing.expect(try book.update(gpa, "C:\\cfg\\wmux.json", contentHash("{}")));
    try testing.expect(!try book.update(gpa, "c:\\CFG\\WMUX.JSON", contentHash("{}"))); // same bytes
    try testing.expect(try book.update(gpa, "C:\\cfg\\wmux.json", contentHash("{\"a\":1}")));
    try testing.expect(try book.update(gpa, "C:\\cfg\\wmux.json", null)); // deleted
    try testing.expect(try book.update(gpa, "C:\\cfg\\cmux.json", contentHash("")));
    try testing.expectEqual(@as(??u64, null), book.get("C:\\nope"));
}

test "unit: settings: change records match watched names" {
    try testing.expect(recordNames("wmux.json", "wmux.json"));
    try testing.expect(recordNames("WMUX.JSON", "wmux.json"));
    try testing.expect(recordNames("sub\\wmux.json", "wmux.json"));
    try testing.expect(!recordNames("wmux.json.tmp", "wmux.json"));
    try testing.expect(!recordNames("xwmux.json", "wmux.json"));
}

test "unit: settings: reload triggers are labeled in precedence order" {
    var buf: [64]u8 = undefined;
    var t: Triggers = .{};
    try testing.expectEqualStrings("startup", t.format(&buf));
    t.add(.wmux_json);
    try testing.expectEqualStrings("wmux.json", t.format(&buf));
    t.add(.cmux_json);
    t.add(.policy);
    try testing.expectEqualStrings("cmux.json+wmux.json+policy", t.format(&buf));
    var small: [12]u8 = undefined;
    try testing.expectEqualStrings("cmux.json", t.format(&small));
}
