//! Byte-stream framing for the wmuxd-remote carrier (ADR-13).
//!
//! The stream carries two message forms:
//! - control: one JSON object per line, terminated by `\n` (an optional `\r`
//!   before it is stripped). Blank lines are ignored.
//! - data (only after a successful `hello` negotiated binary frames): a
//!   10-byte header `0x00 | kind u8 | channel u32 BE | length u32 BE`
//!   followed by `length` payload bytes. A NUL byte never starts a JSON line,
//!   so the first byte of a message tells the two forms apart.
//!
//! Every size is bounded; any violation is a fatal stream error (the peer is
//! out of sync and the connection must be closed).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// First byte of every binary frame.
pub const frame_marker: u8 = 0x00;
/// Bytes in a binary frame header.
pub const header_len = 10;
/// Default cap for one JSON control line (fs.put carries base64 file data).
pub const default_max_line_len: usize = 32 * 1024 * 1024;
/// Default cap for one binary frame payload.
pub const default_max_frame_len: u32 = 1024 * 1024;

pub const Kind = enum(u8) {
    /// PTY bytes. Daemon to client: output of the attachment's session.
    /// Client to daemon: input for the attachment's session.
    pty_data = 1,
    /// Reserved for proxy streams (not implemented in this package).
    proxy_data = 2,

    pub fn fromByte(b: u8) ?Kind {
        return switch (b) {
            1 => .pty_data,
            2 => .proxy_data,
            else => null,
        };
    }
};

pub const Frame = struct {
    kind: Kind,
    channel: u32,
    payload: []const u8,
};

pub const Message = union(enum) {
    /// A control line without its terminator.
    line: []const u8,
    frame: Frame,
};

pub const DecodeError = error{
    LineTooLong,
    FrameTooLarge,
    UnknownFrameKind,
    UnexpectedBinaryFrame,
    Truncated,
};

pub const Limits = struct {
    max_line_len: usize = default_max_line_len,
    max_frame_len: u32 = default_max_frame_len,
};

pub fn encodeHeader(buf: *[header_len]u8, kind: Kind, channel: u32, len: u32) void {
    buf[0] = frame_marker;
    buf[1] = @intFromEnum(kind);
    std.mem.writeInt(u32, buf[2..6], channel, .big);
    std.mem.writeInt(u32, buf[6..10], len, .big);
}

/// Writes one binary frame. Fails with FrameTooLarge above `max_len`.
pub fn writeFrame(w: *Writer, kind: Kind, channel: u32, payload: []const u8, max_len: u32) !void {
    if (payload.len > max_len) return error.FrameTooLarge;
    var hdr: [header_len]u8 = undefined;
    encodeHeader(&hdr, kind, channel, @intCast(payload.len));
    try w.writeAll(&hdr);
    try w.writeAll(payload);
}

/// Writes one control line plus `\n`. The line must not contain a newline
/// and must not start with the frame marker.
pub fn writeLine(w: *Writer, line: []const u8) !void {
    if (std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidLine;
    if (line.len > 0 and line[0] == frame_marker) return error.InvalidLine;
    try w.writeAll(line);
    try w.writeByte('\n');
}

/// Incremental decoder. `feed` appends received bytes; `next` returns the
/// next complete message or null when more bytes are needed. Slices in a
/// returned message stay valid until the next `feed` or `deinit`.
pub const Decoder = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Offset of the first unconsumed byte.
    start: usize = 0,
    /// Bytes after `start` already scanned for `\n` (avoids rescans).
    scanned: usize = 0,
    limits: Limits = .{},
    /// Binary frames are accepted only after hello negotiated them.
    binary_enabled: bool = false,
    /// Sticky: once a decode error happened the stream is unusable.
    failed: bool = false,

    pub fn init(limits: Limits) Decoder {
        return .{ .limits = limits };
    }

    pub fn deinit(self: *Decoder, gpa: Allocator) void {
        self.buf.deinit(gpa);
        self.* = undefined;
    }

    /// Bytes buffered but not yet returned as messages.
    pub fn pending(self: *const Decoder) usize {
        return self.buf.items.len - self.start;
    }

    pub fn feed(self: *Decoder, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        if (self.start > 0) {
            const rest = self.buf.items.len - self.start;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.start..]);
            self.buf.shrinkRetainingCapacity(rest);
            self.start = 0;
        }
        try self.buf.appendSlice(gpa, bytes);
    }

    pub fn next(self: *Decoder) DecodeError!?Message {
        if (self.failed) return error.Truncated;
        return self.nextInner() catch |err| {
            self.failed = true;
            return err;
        };
    }

    fn nextInner(self: *Decoder) DecodeError!?Message {
        while (true) {
            const avail = self.buf.items[self.start..];
            if (avail.len == 0) return null;
            if (avail[0] == frame_marker) {
                if (!self.binary_enabled) return error.UnexpectedBinaryFrame;
                if (avail.len >= 2 and Kind.fromByte(avail[1]) == null) return error.UnknownFrameKind;
                if (avail.len < header_len) return null;
                const kind = Kind.fromByte(avail[1]).?;
                const channel = std.mem.readInt(u32, avail[2..6], .big);
                const len = std.mem.readInt(u32, avail[6..10], .big);
                if (len > self.limits.max_frame_len) return error.FrameTooLarge;
                if (avail.len - header_len < len) return null;
                self.start += header_len + len;
                self.scanned = 0;
                return .{ .frame = .{ .kind = kind, .channel = channel, .payload = avail[header_len .. header_len + len] } };
            }
            const nl = std.mem.indexOfScalarPos(u8, avail, self.scanned, '\n') orelse {
                self.scanned = avail.len;
                if (avail.len > self.limits.max_line_len) return error.LineTooLong;
                return null;
            };
            var line = avail[0..nl];
            self.start += nl + 1;
            self.scanned = 0;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len > self.limits.max_line_len) return error.LineTooLong;
            if (isBlank(line)) continue;
            return .{ .line = line };
        }
    }

    /// Call at end of stream: leftover bytes mean a truncated message.
    pub fn finish(self: *const Decoder) DecodeError!void {
        if (self.failed) return error.Truncated;
        const rest = self.buf.items[self.start..];
        if (!isBlank(rest) or (rest.len > 0 and rest[0] == frame_marker)) return error.Truncated;
    }
};

fn isBlank(s: []const u8) bool {
    for (s) |c| if (c != ' ' and c != '\t' and c != '\r') return false;
    return true;
}

const testing = std.testing;

test "unit: remote-protocol: lines and frames round trip" {
    const gpa = testing.allocator;
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeLine(&aw.writer, "{\"id\":1,\"method\":\"ping\"}");
    try writeFrame(&aw.writer, .pty_data, 7, "héllo\x00\n\xff", default_max_frame_len);
    try writeFrame(&aw.writer, .pty_data, 0xffff_ffff, "", default_max_frame_len);
    try writeLine(&aw.writer, "{\"x\":\"\\u2603\"}");

    var d: Decoder = .init(.{});
    defer d.deinit(gpa);
    d.binary_enabled = true;
    try d.feed(gpa, aw.written());
    try testing.expectEqualStrings("{\"id\":1,\"method\":\"ping\"}", (try d.next()).?.line);
    const f = (try d.next()).?.frame;
    try testing.expectEqual(Kind.pty_data, f.kind);
    try testing.expectEqual(@as(u32, 7), f.channel);
    try testing.expectEqualStrings("héllo\x00\n\xff", f.payload);
    const e = (try d.next()).?.frame;
    try testing.expectEqual(@as(u32, 0xffff_ffff), e.channel);
    try testing.expectEqual(@as(usize, 0), e.payload.len);
    try testing.expectEqualStrings("{\"x\":\"\\u2603\"}", (try d.next()).?.line);
    try testing.expectEqual(@as(?Message, null), try d.next());
    try d.finish();
}

test "unit: remote-protocol: byte-at-a-time feeding yields the same messages" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        var aw: Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var payloads: [8][64]u8 = undefined;
        var lens: [8]usize = undefined;
        for (&payloads, &lens, 0..) |*p, *l, i| {
            l.* = rnd.uintLessThan(usize, 64);
            rnd.bytes(p[0..l.*]);
            if (i % 2 == 0) {
                // Control lines: printable, no newline.
                for (p[0..l.*]) |*c| c.* = 'a' + (c.* % 26);
                try writeLine(&aw.writer, p[0..l.*]);
            } else {
                try writeFrame(&aw.writer, .pty_data, @intCast(i), p[0..l.*], 64);
            }
        }
        var d: Decoder = .init(.{ .max_line_len = 64, .max_frame_len = 64 });
        defer d.deinit(gpa);
        d.binary_enabled = true;
        var got: usize = 0;
        var pos: usize = 0;
        const bytes = aw.written();
        while (pos < bytes.len) {
            const n = @min(bytes.len - pos, 1 + rnd.uintLessThan(usize, 9));
            try d.feed(gpa, bytes[pos .. pos + n]);
            pos += n;
            while (try d.next()) |m| : (got += 1) {
                // Blank control lines are skipped by design.
                while (got % 2 == 0 and lens[got] == 0) got += 1;
                switch (m) {
                    .line => |line| try testing.expectEqualStrings(payloads[got][0..lens[got]], line),
                    .frame => |fr| {
                        try testing.expectEqual(@as(u32, @intCast(got)), fr.channel);
                        try testing.expectEqualSlices(u8, payloads[got][0..lens[got]], fr.payload);
                    },
                }
            }
        }
        try d.finish();
    }
}

test "unit: remote-protocol: truncated frame and line are reported at end of stream" {
    const gpa = testing.allocator;
    var hdr: [header_len]u8 = undefined;
    encodeHeader(&hdr, .pty_data, 1, 5);
    var d: Decoder = .init(.{});
    defer d.deinit(gpa);
    d.binary_enabled = true;
    try d.feed(gpa, hdr[0..4]);
    try testing.expectEqual(@as(?Message, null), try d.next());
    try d.feed(gpa, hdr[4..]);
    try d.feed(gpa, "abc");
    try testing.expectEqual(@as(?Message, null), try d.next());
    try testing.expectError(error.Truncated, d.finish());

    var l: Decoder = .init(.{});
    defer l.deinit(gpa);
    try l.feed(gpa, "{\"id\":1");
    try testing.expectEqual(@as(?Message, null), try l.next());
    try testing.expectError(error.Truncated, l.finish());
}

test "unit: remote-protocol: oversized frames and lines are rejected" {
    const gpa = testing.allocator;
    var hdr: [header_len]u8 = undefined;
    encodeHeader(&hdr, .pty_data, 1, 17);
    var d: Decoder = .init(.{ .max_frame_len = 16, .max_line_len = 8 });
    defer d.deinit(gpa);
    d.binary_enabled = true;
    try d.feed(gpa, &hdr);
    try testing.expectError(error.FrameTooLarge, d.next());
    // Sticky failure.
    try testing.expectError(error.Truncated, d.next());

    var l: Decoder = .init(.{ .max_line_len = 8 });
    defer l.deinit(gpa);
    try l.feed(gpa, "123456789");
    try testing.expectError(error.LineTooLong, l.next());

    var ok: Decoder = .init(.{ .max_line_len = 8 });
    defer ok.deinit(gpa);
    try ok.feed(gpa, "12345678\r\n");
    try testing.expectEqualStrings("12345678", (try ok.next()).?.line);

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try testing.expectError(error.FrameTooLarge, writeFrame(&aw.writer, .pty_data, 0, "x" ** 17, 16));
    try testing.expectError(error.InvalidLine, writeLine(&aw.writer, "a\nb"));
    try testing.expectError(error.InvalidLine, writeLine(&aw.writer, "\x00a"));
}

test "unit: remote-protocol: binary before hello and unknown kinds are fatal" {
    const gpa = testing.allocator;
    var d: Decoder = .init(.{});
    defer d.deinit(gpa);
    try d.feed(gpa, "\x00\x01");
    try testing.expectError(error.UnexpectedBinaryFrame, d.next());

    var k: Decoder = .init(.{});
    defer k.deinit(gpa);
    k.binary_enabled = true;
    try k.feed(gpa, "\x00\x09");
    try testing.expectError(error.UnknownFrameKind, k.next());
}

test "unit: remote-protocol: blank lines are skipped and empty input is fine" {
    const gpa = testing.allocator;
    var d: Decoder = .init(.{});
    defer d.deinit(gpa);
    try testing.expectEqual(@as(?Message, null), try d.next());
    try d.finish();
    try d.feed(gpa, "\n\r\n  \t\n{}\n");
    try testing.expectEqualStrings("{}", (try d.next()).?.line);
    try testing.expectEqual(@as(?Message, null), try d.next());
    try testing.expectEqual(@as(usize, 0), d.pending());
}

test "unit: remote-protocol: random garbage never crashes the decoder" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buf: [256]u8 = undefined;
        const n = rnd.uintLessThan(usize, buf.len);
        rnd.bytes(buf[0..n]);
        var d: Decoder = .init(.{ .max_line_len = 64, .max_frame_len = 64 });
        defer d.deinit(gpa);
        d.binary_enabled = rnd.boolean();
        try d.feed(gpa, buf[0..n]);
        while (true) {
            const m = d.next() catch break;
            if (m == null) break;
        }
        _ = d.finish() catch {};
    }
}
