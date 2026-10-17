//! Newline-delimited request framing for the v2 pipe server (ADR-3.2,
//! ADR-3.4). Pure: std only.
//!
//! Lines end in LF or CRLF; the terminator is stripped and blank lines are
//! skipped. A line longer than the cap (terminator excluded) never reaches
//! the dispatcher: the framer drops its bytes up to the next LF and reports
//! one `.oversized` event in its place, so the connection stays usable and
//! replies stay in request order. Buffered bytes are bounded by the cap plus
//! the size of one fed chunk.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");

/// Line cap of the v2 transport (W1-1a-t; see out/REPORT.md for the 16 MiB
/// authorized / 4 MiB pre-authorization caps of ADR-3.2).
pub const default_max_line: usize = 1024 * 1024;
/// ADR-3.2 cap once a connection is authorized (a 15 MiB `terminal.paste`).
pub const authorized_max_line: usize = 16 * 1024 * 1024;
/// ADR-3.2 cap while a connection still has to authenticate.
pub const preauth_max_line: usize = 4 * 1024 * 1024;

pub const Event = union(enum) {
    /// One non-blank line without its terminator. Valid until the next
    /// `feed` or `deinit`.
    line: []const u8,
    /// A line exceeded the cap; `len` is the number of bytes seen before the
    /// framer gave up on it (at least `max_line + 1`).
    oversized: usize,
};

const Pending = union(enum) {
    /// `buf[start..end]` (terminator already stripped).
    line: struct { start: usize, end: usize },
    oversized: usize,
};

pub const LineFramer = struct {
    /// Complete lines not yet returned, followed by the partial tail.
    buf: std.ArrayList(u8) = .empty,
    /// Events not yet returned by `next`, oldest first.
    pending: std.ArrayList(Pending) = .empty,
    /// Index of the first unreturned event in `pending`.
    pending_head: usize = 0,
    /// Offset in `buf` where the current partial line starts.
    tail_start: usize = 0,
    /// Bytes of the current line seen so far while discarding it.
    discard_len: usize = 0,
    discarding: bool = false,
    max_line: usize = default_max_line,

    pub fn init(max_line: usize) LineFramer {
        return .{ .max_line = @max(max_line, 1) };
    }

    pub fn deinit(self: *LineFramer, gpa: Allocator) void {
        self.buf.deinit(gpa);
        self.pending.deinit(gpa);
        self.* = undefined;
    }

    /// Raises or lowers the cap for lines not yet complete (for example
    /// once a connection is authorized).
    pub fn setMaxLine(self: *LineFramer, max_line: usize) void {
        self.max_line = @max(max_line, 1);
    }

    /// Bytes buffered (complete lines not yet returned plus the tail).
    pub fn buffered(self: *const LineFramer) usize {
        return self.buf.items.len - self.keepFrom();
    }

    /// Offset of the first byte not yet returned by `next`.
    fn keepFrom(self: *const LineFramer) usize {
        for (self.pending.items[self.pending_head..]) |e| switch (e) {
            .line => |r| return r.start,
            .oversized => {},
        };
        return self.tail_start;
    }

    /// True when `next` would return an event without more input.
    pub fn hasEvent(self: *const LineFramer) bool {
        return self.pending_head < self.pending.items.len;
    }

    /// Appends one chunk of input. Slices returned by earlier `next` calls
    /// become invalid. On OutOfMemory the framer state is unchanged except
    /// for lines already completed from the chunk's prefix.
    pub fn feed(self: *LineFramer, gpa: Allocator, chunk: []const u8) Allocator.Error!void {
        self.compact();
        var rest = chunk;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const seg = rest[0 .. nl orelse rest.len];
            rest = if (nl) |i| rest[i + 1 ..] else rest[rest.len..];
            if (self.discarding) {
                self.discard_len +|= seg.len;
                if (nl != null) self.discarding = false;
                continue;
            }
            const tail_len = self.buf.items.len - self.tail_start;
            // CR of a CRLF terminator does not count against the cap.
            var seg_len = seg.len;
            if (nl != null and seg_len > 0 and seg[seg_len - 1] == '\r') seg_len -= 1;
            if (tail_len + seg_len > self.max_line) {
                try self.pending.append(gpa, .{ .oversized = tail_len + seg.len });
                self.buf.shrinkRetainingCapacity(self.tail_start);
                if (nl == null) {
                    self.discarding = true;
                    self.discard_len = tail_len + seg.len;
                }
                continue;
            }
            try self.buf.appendSlice(gpa, seg);
            if (nl == null) continue;
            var end = self.buf.items.len;
            if (end > self.tail_start and self.buf.items[end - 1] == '\r') end -= 1;
            const line = self.buf.items[self.tail_start..end];
            if (proto.envelope.isBlankLine(line)) {
                self.buf.shrinkRetainingCapacity(self.tail_start);
                continue;
            }
            try self.pending.append(gpa, .{ .line = .{ .start = self.tail_start, .end = end } });
            self.tail_start = self.buf.items.len;
        }
        // A tail already over the cap (possible after lowering it) is
        // reported now rather than buffered further.
        if (!self.discarding and self.buf.items.len - self.tail_start > self.max_line) {
            const len = self.buf.items.len - self.tail_start;
            try self.pending.append(gpa, .{ .oversized = len });
            self.buf.shrinkRetainingCapacity(self.tail_start);
            self.discarding = true;
            self.discard_len = len;
        }
    }

    /// The oldest unreturned event, or null when more input is needed.
    pub fn next(self: *LineFramer) ?Event {
        if (self.pending_head >= self.pending.items.len) return null;
        const p = self.pending.items[self.pending_head];
        self.pending_head += 1;
        return switch (p) {
            .line => |r| .{ .line = self.buf.items[r.start..r.end] },
            .oversized => |n| .{ .oversized = n },
        };
    }

    /// Drops returned lines from the front of `buf`, keeping unreturned
    /// lines (their offsets are rebased) and the partial tail.
    fn compact(self: *LineFramer) void {
        const events = self.pending.items[self.pending_head..];
        const keep_from = self.keepFrom();
        if (keep_from > 0) {
            const remaining = self.buf.items.len - keep_from;
            std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[keep_from..]);
            self.buf.shrinkRetainingCapacity(remaining);
            self.tail_start -= keep_from;
            for (events) |*e| switch (e.*) {
                .line => |*r| {
                    r.start -= keep_from;
                    r.end -= keep_from;
                },
                .oversized => {},
            };
        }
        if (self.pending_head > 0) {
            const n = self.pending.items.len - self.pending_head;
            std.mem.copyForwards(Pending, self.pending.items[0..n], self.pending.items[self.pending_head..]);
            self.pending.shrinkRetainingCapacity(n);
            self.pending_head = 0;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectLine(f: *LineFramer, want: []const u8) !void {
    const e = f.next() orelse return error.TestExpectedLine;
    try testing.expectEqualStrings(want, e.line);
}

test "unit: rpc: framer splits LF and CRLF lines and skips blank ones" {
    var f: LineFramer = .init(default_max_line);
    defer f.deinit(testing.allocator);
    try f.feed(testing.allocator, "{\"a\":1}\n\r\n  \t\n{\"b\":2}\r\n\n");
    try expectLine(&f, "{\"a\":1}");
    try expectLine(&f, "{\"b\":2}");
    try testing.expect(f.next() == null);
}

test "unit: rpc: framer joins a line split across many chunks" {
    var f: LineFramer = .init(default_max_line);
    defer f.deinit(testing.allocator);
    const line = "{\"id\":\"1\",\"method\":\"system.ping\",\"params\":{}}\r\n";
    for (line) |c| try f.feed(testing.allocator, &.{c});
    try expectLine(&f, "{\"id\":\"1\",\"method\":\"system.ping\",\"params\":{}}");
    try testing.expect(f.next() == null);
    try testing.expectEqual(@as(usize, 0), f.buffered());
}

test "unit: rpc: framer keeps an unterminated tail and empty input is a no-op" {
    var f: LineFramer = .init(default_max_line);
    defer f.deinit(testing.allocator);
    try f.feed(testing.allocator, "");
    try testing.expect(f.next() == null);
    try f.feed(testing.allocator, "partial");
    try testing.expect(f.next() == null);
    try testing.expect(!f.hasEvent());
    try f.feed(testing.allocator, " line\nnext");
    try expectLine(&f, "partial line");
    try testing.expect(f.next() == null);
    try testing.expectEqual(@as(usize, 4), f.buffered());
}

test "unit: rpc: framer lines stay valid until the next feed" {
    var f: LineFramer = .init(default_max_line);
    defer f.deinit(testing.allocator);
    try f.feed(testing.allocator, "one\ntwo\nthr");
    try expectLine(&f, "one");
    // Feeding with an unreturned line must rebase it, not lose it.
    try f.feed(testing.allocator, "ee\n");
    try expectLine(&f, "two");
    try expectLine(&f, "three");
    try testing.expect(f.next() == null);
}

test "unit: rpc: framer cap boundary: exactly max bytes passes, max+1 is oversized" {
    var f: LineFramer = .init(8);
    defer f.deinit(testing.allocator);
    try f.feed(testing.allocator, "12345678\r\n123456789\nok\n");
    try expectLine(&f, "12345678");
    const e = f.next().?;
    try testing.expectEqual(@as(usize, 9), e.oversized);
    try expectLine(&f, "ok");
    try testing.expect(f.next() == null);
}

test "unit: rpc: framer discards an oversized line across chunks and recovers" {
    var f: LineFramer = .init(16);
    defer f.deinit(testing.allocator);
    try f.feed(testing.allocator, "first\n0123456789");
    try f.feed(testing.allocator, "0123456789");
    try expectLine(&f, "first");
    try testing.expect(f.next().?.oversized >= 17);
    try testing.expect(f.next() == null);
    // Still discarding: no second oversized event and nothing buffered.
    try f.feed(testing.allocator, "x" ** 100);
    try testing.expect(f.next() == null);
    try testing.expectEqual(@as(usize, 0), f.buffered());
    try f.feed(testing.allocator, "tail\n{\"after\":true}\n");
    try expectLine(&f, "{\"after\":true}");
    try testing.expect(f.next() == null);
}

test "unit: rpc: framer handles a huge 1 MiB + 1 line and keeps memory bounded" {
    var f: LineFramer = .init(default_max_line);
    defer f.deinit(testing.allocator);
    const chunk = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(chunk);
    @memset(chunk, 'a');
    var sent: usize = 0;
    while (sent <= default_max_line) : (sent += chunk.len) {
        try f.feed(testing.allocator, chunk);
        try testing.expect(f.buffered() <= default_max_line);
    }
    try f.feed(testing.allocator, "\n{\"id\":2}\n");
    try testing.expect(f.next().? == .oversized);
    try expectLine(&f, "{\"id\":2}");
}

test "unit: rpc: framer passes unicode and invalid UTF-8 bytes through unchanged" {
    var f: LineFramer = .init(default_max_line);
    defer f.deinit(testing.allocator);
    try f.feed(testing.allocator, "{\"t\":\"h\xc3\xa9llo \xf0\x9f\x98\x80\"}\n\xff\xfe\n");
    try expectLine(&f, "{\"t\":\"h\xc3\xa9llo \xf0\x9f\x98\x80\"}");
    // UTF-8 validation is the envelope's job (`invalid_utf8`), not framing.
    try expectLine(&f, "\xff\xfe");
}

test "unit: rpc: framer setMaxLine raises the cap for the current line" {
    var f: LineFramer = .init(4);
    defer f.deinit(testing.allocator);
    try f.feed(testing.allocator, "abc");
    f.setMaxLine(16);
    try f.feed(testing.allocator, "defgh\n");
    try expectLine(&f, "abcdefgh");
    f.setMaxLine(2);
    try f.feed(testing.allocator, "abc");
    try testing.expect(f.next().? == .oversized);
    try f.feed(testing.allocator, "d\nok\n");
    try expectLine(&f, "ok");
}
