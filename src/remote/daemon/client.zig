//! Minimal blocking client of the wmuxd-remote protocol over a pair of fds.
//! Used by `wmuxd-remote status` and by the integration tests; the Windows
//! carrier has its own client on top of the same wmux_proto types.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const remote = @import("wmux_proto").remote;
const frame = remote.frame;
const rpc = remote.rpc;
const msgs = remote.messages;

pub const Reply = @FieldType(rpc.Incoming, "reply");

pub const Event = struct {
    name: []const u8,
    params: std.json.Value,
};

pub const Error = error{ Timeout, EndOfStream, ProtocolError, UnexpectedReply } ||
    posix.ReadError || posix.WriteError || posix.PollError || frame.DecodeError || Allocator.Error;

pub const Client = struct {
    gpa: Allocator,
    rfd: posix.fd_t,
    wfd: posix.fd_t,
    owns_fds: bool,
    dec: frame.Decoder = .init(.{}),
    /// Holds parsed replies and events for the client's lifetime.
    arena: std.heap.ArenaAllocator,
    next_id: i64 = 1,
    events: std.ArrayList(Event) = .empty,
    /// PTY output per channel (binary frames and decoded pty.data events).
    data: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(u8)) = .empty,
    /// Replies not taken yet, oldest first (one read can carry several).
    replies: std.ArrayList(Reply) = .empty,
    eof: bool = false,

    pub fn init(gpa: Allocator, rfd: posix.fd_t, wfd: posix.fd_t, owns_fds: bool) Client {
        return .{ .gpa = gpa, .rfd = rfd, .wfd = wfd, .owns_fds = owns_fds, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Client) void {
        if (self.owns_fds) {
            posix.close(self.rfd);
            if (self.wfd != self.rfd) posix.close(self.wfd);
        }
        self.dec.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.replies.deinit(self.gpa);
        for (self.data.values()) |*v| v.deinit(self.gpa);
        self.data.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn writeAll(self: *Client, bytes: []const u8) Error!void {
        var off: usize = 0;
        while (off < bytes.len) off += try posix.write(self.wfd, bytes[off..]);
    }

    /// Sends a request and waits for its reply (events and data that arrive
    /// meanwhile are buffered).
    pub fn request(self: *Client, method: rpc.Method, params: anytype, timeout_ms: i64) Error!Reply {
        const id = self.next_id;
        self.next_id += 1;
        var aw: Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        rpc.writeRequest(&aw.writer, .{ .int = id }, method, params) catch return error.OutOfMemory;
        try self.writeAll(aw.written());
        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (true) {
            if (self.replies.items.len > 0) {
                const r = self.replies.orderedRemove(0);
                if (r.id == null or r.id.? != .int or r.id.?.int != id) {
                    // Errors for unparseable requests carry a null id.
                    if (r.id == null and !r.ok) return r;
                    return error.UnexpectedReply;
                }
                return r;
            }
            try self.pump(deadline);
        }
    }

    /// Waits for the next reply of any id (after a raw `writeAll`).
    pub fn nextReply(self: *Client, timeout_ms: i64) Error!Reply {
        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (self.replies.items.len == 0) try self.pump(deadline);
        return self.replies.orderedRemove(0);
    }

    /// `hello` with protocol version 1; `binary` asks for binary frames.
    pub fn hello(self: *Client, binary: bool, timeout_ms: i64) Error!Reply {
        const caps: []const []const u8 = if (binary) &.{rpc.cap_binary_frames} else &.{};
        const r = try self.request(.hello, msgs.HelloParams{ .protocol_version = rpc.protocol_version, .client = "wmuxd-remote-client", .capabilities = caps }, timeout_ms);
        if (r.ok) self.dec.binary_enabled = binary;
        return r;
    }

    /// Sends PTY input as a binary frame on `channel`.
    pub fn writeFrame(self: *Client, channel: u32, payload: []const u8) Error!void {
        var hdr: [frame.header_len]u8 = undefined;
        frame.encodeHeader(&hdr, .pty_data, channel, @intCast(payload.len));
        try self.writeAll(&hdr);
        try self.writeAll(payload);
    }

    pub fn channelData(self: *Client, channel: u32) []const u8 {
        return if (self.data.get(channel)) |v| v.items else "";
    }

    /// Waits until the channel's buffered output contains `needle`.
    pub fn waitData(self: *Client, channel: u32, needle: []const u8, timeout_ms: i64) Error!void {
        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (std.mem.indexOf(u8, self.channelData(channel), needle) == null) try self.pump(deadline);
    }

    /// Waits for (and consumes) the first buffered event named `name`.
    pub fn waitEvent(self: *Client, name: []const u8, timeout_ms: i64) Error!Event {
        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (true) {
            for (self.events.items, 0..) |e, i| if (std.mem.eql(u8, e.name, name)) {
                return self.events.orderedRemove(i);
            };
            try self.pump(deadline);
        }
    }

    /// Reads once (bounded by `deadline`) and processes complete messages.
    pub fn pump(self: *Client, deadline: i64) Error!void {
        if (self.eof) return error.EndOfStream;
        const left = deadline - std.time.milliTimestamp();
        if (left <= 0) return error.Timeout;
        var fds = [_]posix.pollfd{.{ .fd = self.rfd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, @intCast(@min(left, 1000))) == 0) return;
        var buf: [64 * 1024]u8 = undefined;
        const n = posix.read(self.rfd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) {
            self.eof = true;
            return error.EndOfStream;
        }
        try self.dec.feed(self.gpa, buf[0..n]);
        while (try self.dec.next()) |m| switch (m) {
            .frame => |f| try self.appendData(f.channel, f.payload),
            .line => |line| try self.handleLine(line),
        };
    }

    fn appendData(self: *Client, channel: u32, bytes: []const u8) Allocator.Error!void {
        const gop = try self.data.getOrPut(self.gpa, channel);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.appendSlice(self.gpa, bytes);
    }

    fn handleLine(self: *Client, line: []const u8) Error!void {
        const a = self.arena.allocator();
        const in = rpc.parseIncoming(a, try a.dupe(u8, line)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ProtocolError,
        };
        switch (in) {
            .reply => |r| try self.replies.append(self.gpa, r),
            .event => |e| {
                if (std.mem.eql(u8, e.name, msgs.event_pty_data)) {
                    const p = std.json.parseFromValueLeaky(msgs.PtyDataEvent, a, e.params, .{ .ignore_unknown_fields = true }) catch return error.ProtocolError;
                    const dec = std.base64.standard.Decoder;
                    const out = try a.alloc(u8, dec.calcSizeForSlice(p.data) catch return error.ProtocolError);
                    dec.decode(out, p.data) catch return error.ProtocolError;
                    try self.appendData(p.channel, out);
                }
                try self.events.append(self.gpa, .{ .name = e.name, .params = e.params });
            },
        }
    }
};
