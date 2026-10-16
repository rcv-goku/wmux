//! Bounded scrollback ring: keeps the most recent `capacity` bytes of PTY
//! output for replay on (re)attach.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Ring = struct {
    buf: []u8,
    /// Index of the oldest byte.
    head: usize = 0,
    len: usize = 0,
    /// Bytes ever appended (monotonic; a replay cursor for clients).
    total: u64 = 0,

    pub fn init(gpa: Allocator, cap: usize) Allocator.Error!Ring {
        return .{ .buf = try gpa.alloc(u8, cap) };
    }

    pub fn deinit(self: *Ring, gpa: Allocator) void {
        gpa.free(self.buf);
        self.* = undefined;
    }

    pub fn capacity(self: *const Ring) usize {
        return self.buf.len;
    }

    pub fn append(self: *Ring, bytes: []const u8) void {
        self.total += bytes.len;
        const cap = self.buf.len;
        if (cap == 0) return;
        var data = bytes;
        if (data.len >= cap) {
            data = data[data.len - cap ..];
            @memcpy(self.buf, data);
            self.head = 0;
            self.len = cap;
            return;
        }
        const tail = (self.head + self.len) % cap;
        const first = @min(data.len, cap - tail);
        @memcpy(self.buf[tail .. tail + first], data[0..first]);
        @memcpy(self.buf[0 .. data.len - first], data[first..]);
        const new_len = self.len + data.len;
        if (new_len > cap) {
            self.head = (self.head + (new_len - cap)) % cap;
            self.len = cap;
        } else self.len = new_len;
    }

    /// Contents oldest-first as at most two slices.
    pub fn slices(self: *const Ring) [2][]const u8 {
        const cap = self.buf.len;
        if (self.len == 0) return .{ &.{}, &.{} };
        const end = self.head + self.len;
        if (end <= cap) return .{ self.buf[self.head..end], &.{} };
        return .{ self.buf[self.head..cap], self.buf[0 .. end - cap] };
    }

    pub fn clear(self: *Ring) void {
        self.head = 0;
        self.len = 0;
    }
};

const testing = std.testing;

fn contents(r: *const Ring, out: []u8) []const u8 {
    const s = r.slices();
    @memcpy(out[0..s[0].len], s[0]);
    @memcpy(out[s[0].len .. s[0].len + s[1].len], s[1]);
    return out[0 .. s[0].len + s[1].len];
}

test "unit: remote-daemon: ring keeps the newest bytes" {
    var r = try Ring.init(testing.allocator, 8);
    defer r.deinit(testing.allocator);
    var out: [16]u8 = undefined;
    try testing.expectEqualStrings("", contents(&r, &out));
    r.append("abc");
    try testing.expectEqualStrings("abc", contents(&r, &out));
    r.append("defgh");
    try testing.expectEqualStrings("abcdefgh", contents(&r, &out));
    r.append("ij");
    try testing.expectEqualStrings("cdefghij", contents(&r, &out));
    r.append("0123456789xyz");
    try testing.expectEqualStrings("56789xyz", contents(&r, &out));
    try testing.expectEqual(@as(u64, 23), r.total);
    r.append("");
    try testing.expectEqualStrings("56789xyz", contents(&r, &out));
    r.clear();
    try testing.expectEqualStrings("", contents(&r, &out));
}

test "unit: remote-daemon: ring matches a naive model under random appends" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for ([_]usize{ 0, 1, 5, 64 }) |cap| {
        var r = try Ring.init(gpa, cap);
        defer r.deinit(gpa);
        var model: std.ArrayList(u8) = .empty;
        defer model.deinit(gpa);
        var i: usize = 0;
        while (i < 300) : (i += 1) {
            var chunk: [100]u8 = undefined;
            const n = rnd.uintLessThan(usize, chunk.len);
            rnd.bytes(chunk[0..n]);
            r.append(chunk[0..n]);
            try model.appendSlice(gpa, chunk[0..n]);
            const keep = @min(model.items.len, cap);
            var out: [64]u8 = undefined;
            try testing.expectEqualSlices(u8, model.items[model.items.len - keep ..], contents(&r, &out));
        }
    }
}
