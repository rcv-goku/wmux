//! The daemon core: a single-threaded poll(2) loop over client connections,
//! PTY masters and (persistent mode) a listening socket. All session state
//! is owned by this loop, so nothing is locked. Writes to clients and PTYs
//! are non-blocking with bounded queues.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const remote = @import("wmux_proto").remote;
const frame = remote.frame;
const rpc = remote.rpc;
const msgs = remote.messages;
const Session = @import("session.zig").Session;
const pty = @import("pty.zig");
const handlers = @import("handlers.zig");

const log = std.log.scoped(.remote_daemon);

pub const Config = struct {
    /// Persistent daemons keep sessions when clients leave.
    persistent: bool = false,
    slot: ?[]const u8 = null,
    /// Base for `~` in fs paths and the default cwd of shells.
    home: []const u8,
    /// Detached sessions idle this long are closed (0 disables).
    session_ttl_ms: i64 = 0,
    /// Persistent server exits after this long with no sessions and no
    /// clients (0 disables).
    idle_exit_ms: i64 = 0,
    /// A client whose unsent output exceeds this is disconnected.
    max_outbound: usize = default_max_outbound,
    /// Flow control: while a client streaming a session has this much
    /// unsent output, the session's PTY is not read, so a fast producer
    /// blocks on its terminal instead of the client hitting `max_outbound`.
    pty_high_water: usize = default_pty_high_water,
    /// A client with `pty_high_water` or more unsent bytes that has not
    /// taken a single byte for this long is dropped (0 disables): it holds
    /// its sessions back, and it is most likely gone (a half-open bridge
    /// can linger until TCP keepalive, hours). Only its attachments end.
    /// A closing client with any unsent bytes gets the same timeout.
    stall_timeout_ms: i64 = 30_000,
    /// Stop when the last client leaves (`serve --stdio`).
    exit_when_no_clients: bool = true,
    /// Polled each tick; set from a signal handler to stop the loop.
    stop_flag: ?*const std.atomic.Value(bool) = null,
    /// Grace period between SIGHUP and SIGKILL for closed sessions.
    kill_grace_ms: i64 = 2000,
};

/// Bytes read from a PTY per read call (and the max data frame we send).
pub const read_chunk = 64 * 1024;

/// Default `Config.max_outbound`. Replies are queued without a check, so
/// the cap must stay well above the largest one: an fs.get of
/// `max_fs_bytes` is a single ~22.4 MiB base64 line, and with a smaller
/// cap the first PTY data or event queued behind it disconnected the
/// client (on the carrier, every terminal of the route at once).
pub const default_max_outbound: usize = 64 * 1024 * 1024;

/// Default `Config.pty_high_water`. PTY output past it waits in the kernel
/// (the producer blocks), so a slow link no longer costs the connection.
pub const default_pty_high_water: usize = 1024 * 1024;

comptime {
    const max_reply = std.base64.standard.Encoder.calcSize(msgs.max_fs_bytes) + 64 * 1024;
    // Room for the largest reply plus 16 MiB of output queued behind it.
    if (default_max_outbound < max_reply + 16 * 1024 * 1024)
        @compileError("default_max_outbound must exceed the largest reply plus headroom");
    if (default_pty_high_water * 16 > default_max_outbound)
        @compileError("default_pty_high_water must stay far below default_max_outbound");
}

pub const Conn = struct {
    id: u64,
    in_fd: posix.fd_t,
    out_fd: posix.fd_t,
    owns_fds: bool,
    decoder: frame.Decoder,
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    hello_done: bool = false,
    binary: bool = false,
    /// Stop reading and queue no more PTY output; close once the output
    /// already queued is flushed.
    closing: bool = false,
    /// Remove at the end of the tick.
    dead: bool = false,
    next_channel: u32 = 1,
    /// Last time the output queue was empty or a write took bytes.
    drained_ms: i64,

    pub fn pendingOut(self: *const Conn) usize {
        return self.out.items.len - self.out_off;
    }
};

const Reaping = struct {
    pid: posix.pid_t,
    kill_at_ms: i64,
};

pub const Server = struct {
    gpa: Allocator,
    cfg: Config,
    sessions: std.StringArrayHashMapUnmanaged(*Session) = .empty,
    conns: std.ArrayList(*Conn) = .empty,
    /// Sessions removed this tick, destroyed at its end.
    graveyard: std.ArrayList(*Session) = .empty,
    /// Closed sessions whose process has not been reaped yet.
    reaping: std.ArrayList(Reaping) = .empty,
    listener: ?posix.fd_t = null,
    next_conn_id: u64 = 1,
    next_attach_id: u64 = 1,
    stopped: bool = false,
    /// Last time the server had a session or a client (idle exit).
    busy_ms: i64,

    pub fn init(gpa: Allocator, cfg: Config) Server {
        return .{ .gpa = gpa, .cfg = cfg, .busy_ms = std.time.milliTimestamp() };
    }

    /// Kills remaining sessions (with the grace period), closes everything.
    pub fn deinit(self: *Server) void {
        // Stop accepting first: during the reap below, a connecting bridge
        // is refused (and starts the next server) instead of being queued
        // in a backlog that the close would reset.
        if (self.listener) |l| posix.close(l);
        self.listener = null;
        self.shutdownSessions();
        for (self.conns.items) |c| self.destroyConn(c);
        self.conns.deinit(self.gpa);
        for (self.graveyard.items) |s| s.destroy(self.gpa);
        self.graveyard.deinit(self.gpa);
        self.sessions.deinit(self.gpa);
        self.reaping.deinit(self.gpa);
        self.* = undefined;
    }

    /// Adds a client. With `owns_fds` the server closes them when done.
    pub fn addConn(self: *Server, in_fd: posix.fd_t, out_fd: posix.fd_t, owns_fds: bool) !*Conn {
        pty.setNonblock(in_fd);
        if (out_fd != in_fd) pty.setNonblock(out_fd);
        const c = try self.gpa.create(Conn);
        errdefer self.gpa.destroy(c);
        c.* = .{
            .id = self.next_conn_id,
            .in_fd = in_fd,
            .out_fd = out_fd,
            .owns_fds = owns_fds,
            .decoder = .init(.{}),
            .drained_ms = std.time.milliTimestamp(),
        };
        try self.conns.append(self.gpa, c);
        self.next_conn_id += 1;
        return c;
    }

    pub fn findConn(self: *Server, id: u64) ?*Conn {
        for (self.conns.items) |c| if (c.id == id and !c.dead) return c;
        return null;
    }

    fn destroyConn(self: *Server, c: *Conn) void {
        if (c.owns_fds) {
            posix.close(c.in_fd);
            if (c.out_fd != c.in_fd) posix.close(c.out_fd);
        }
        c.decoder.deinit(self.gpa);
        c.out.deinit(self.gpa);
        self.gpa.destroy(c);
    }

    /// Runs until stopped (stop flag, last stdio client gone, idle exit).
    pub fn run(self: *Server) !void {
        while (!self.stopped) try self.tick(250);
    }

    const Tag = union(enum) {
        listener,
        conn_in: *Conn,
        conn_out: *Conn,
        conn_io: *Conn,
        session: *Session,
    };

    /// One loop iteration: housekeeping, poll, dispatch, flush, sweep.
    pub fn tick(self: *Server, timeout_ms: i32) !void {
        self.housekeeping(std.time.milliTimestamp());
        if (self.stopped) return;
        var fds: std.ArrayList(posix.pollfd) = .empty;
        defer fds.deinit(self.gpa);
        var tags: std.ArrayList(Tag) = .empty;
        defer tags.deinit(self.gpa);
        const IN = posix.POLL.IN;
        const OUT = posix.POLL.OUT;
        if (self.listener) |l| {
            try fds.append(self.gpa, .{ .fd = l, .events = IN, .revents = 0 });
            try tags.append(self.gpa, .listener);
        }
        for (self.conns.items) |c| {
            if (c.dead) continue;
            const want_in: i16 = if (c.closing) 0 else IN;
            const want_out: i16 = if (c.pendingOut() > 0) OUT else 0;
            if (c.in_fd == c.out_fd) {
                try fds.append(self.gpa, .{ .fd = c.in_fd, .events = want_in | want_out, .revents = 0 });
                try tags.append(self.gpa, .{ .conn_io = c });
            } else {
                if (want_in != 0) {
                    try fds.append(self.gpa, .{ .fd = c.in_fd, .events = want_in, .revents = 0 });
                    try tags.append(self.gpa, .{ .conn_in = c });
                }
                // Always watch the output side so a vanished peer is noticed.
                try fds.append(self.gpa, .{ .fd = c.out_fd, .events = want_out, .revents = 0 });
                try tags.append(self.gpa, .{ .conn_out = c });
            }
        }
        for (self.sessions.values()) |s| {
            if (s.master < 0) continue;
            // A backed-up client resumes the PTY via POLLOUT on its own fd.
            const want_in: i16 = if (s.master_eof or self.outputBlocked(s)) 0 else IN;
            const want_out: i16 = if (s.input.items.len > 0) OUT else 0;
            if (want_in | want_out == 0) continue;
            try fds.append(self.gpa, .{ .fd = s.master, .events = want_in | want_out, .revents = 0 });
            try tags.append(self.gpa, .{ .session = s });
        }
        const timeout = if (self.sessions.count() > 0 or self.reaping.items.len > 0) @min(timeout_ms, 100) else timeout_ms;
        _ = try posix.poll(fds.items, timeout);

        const ERRS = posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;
        for (fds.items, tags.items) |pfd, tag| {
            const r = pfd.revents;
            if (r == 0) continue;
            switch (tag) {
                .listener => self.acceptOne(),
                .conn_in => |c| if (r & (IN | ERRS) != 0) self.readConn(c),
                .conn_out => |c| {
                    if (r & OUT != 0) self.flushConn(c);
                    if (r & ERRS != 0) c.dead = true;
                },
                .conn_io => |c| {
                    if (r & OUT != 0) self.flushConn(c);
                    if (r & (IN | ERRS) != 0) self.readConn(c);
                },
                .session => |s| {
                    if (r & OUT != 0) s.flushInput();
                    if (r & (IN | ERRS) != 0) self.pumpSession(s, true);
                },
            }
        }
        const now = std.time.milliTimestamp();
        for (self.conns.items) |c| {
            if (!c.dead and c.pendingOut() > 0) self.flushConn(c);
            if (c.pendingOut() == 0) c.drained_ms = now else self.checkStall(c, now);
            if (c.closing and c.pendingOut() == 0) c.dead = true;
        }
        self.sweep();
    }

    /// Drops a client that has not taken a byte for `stall_timeout_ms`
    /// while it holds sessions back (see `outputBlocked`; its sessions
    /// resume), or while it is closing: its input ended, so it is only owed
    /// what is queued, and with nothing queued behind that (`sendData`) no
    /// other limit would ever end it.
    fn checkStall(self: *Server, c: *Conn, now: i64) void {
        if (c.dead or self.cfg.stall_timeout_ms <= 0) return;
        if (!c.closing and c.pendingOut() < self.cfg.pty_high_water) return;
        if (now - c.drained_ms < self.cfg.stall_timeout_ms) return;
        log.info("client {d} took no output for {d} ms; disconnecting", .{ c.id, now - c.drained_ms });
        c.dead = true;
    }

    fn acceptOne(self: *Server) void {
        const l = self.listener orelse return;
        const fd = posix.accept(l, null, null, posix.SOCK.CLOEXEC) catch |err| {
            if (err != error.WouldBlock) log.info("accept failed: {s}", .{@errorName(err)});
            return;
        };
        _ = self.addConn(fd, fd, true) catch {
            posix.close(fd);
            return;
        };
    }

    fn readConn(self: *Server, c: *Conn) void {
        if (c.dead or c.closing) return;
        var buf: [read_chunk]u8 = undefined;
        var rounds: usize = 0;
        while (rounds < 16 and !c.dead and !c.closing) : (rounds += 1) {
            const n = posix.read(c.in_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    c.dead = true;
                    return;
                },
            };
            if (n == 0) {
                c.decoder.finish() catch log.info("client {d} sent a truncated message", .{c.id});
                c.closing = true;
                return;
            }
            c.decoder.feed(self.gpa, buf[0..n]) catch {
                c.dead = true;
                return;
            };
            self.drainDecoder(c);
        }
    }

    fn drainDecoder(self: *Server, c: *Conn) void {
        while (!c.dead and !c.closing) {
            const m = c.decoder.next() catch |err| {
                const msg = switch (err) {
                    error.LineTooLong => "control line too long",
                    error.FrameTooLarge => "frame too large",
                    error.UnknownFrameKind => "unknown frame kind",
                    error.UnexpectedBinaryFrame => "binary frame before hello",
                    error.Truncated => "stream out of sync",
                };
                self.sendError(c, null, if (err == error.LineTooLong or err == error.FrameTooLarge) .too_large else .parse_error, msg);
                c.closing = true;
                return;
            } orelse return;
            switch (m) {
                .line => |line| handlers.handleLine(self, c, line),
                .frame => |f| handlers.handleFrame(self, c, f),
            }
        }
    }

    fn flushConn(self: *Server, c: *Conn) void {
        _ = self;
        while (!c.dead and c.pendingOut() > 0) {
            const n = posix.write(c.out_fd, c.out.items[c.out_off..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    c.dead = true;
                    return;
                },
            };
            c.out_off += n;
            if (n > 0) c.drained_ms = std.time.milliTimestamp();
        }
        if (c.out_off == c.out.items.len) {
            c.out.clearRetainingCapacity();
            c.out_off = 0;
        } else if (c.out_off > 1024 * 1024) {
            const rest = c.out.items.len - c.out_off;
            std.mem.copyForwards(u8, c.out.items[0..rest], c.out.items[c.out_off..]);
            c.out.shrinkRetainingCapacity(rest);
            c.out_off = 0;
        }
    }

    fn checkOutbound(self: *Server, c: *Conn) void {
        if (c.pendingOut() > self.cfg.max_outbound) {
            log.info("client {d} is not reading; disconnecting", .{c.id});
            c.dead = true;
        }
    }

    pub fn sendOk(self: *Server, c: *Conn, id: ?rpc.Id, result: anytype) void {
        var aw: Writer.Allocating = .fromArrayList(self.gpa, &c.out);
        defer c.out = aw.toArrayList();
        rpc.writeOk(&aw.writer, id, result) catch {
            c.dead = true;
        };
    }

    pub fn sendError(self: *Server, c: *Conn, id: ?rpc.Id, code: rpc.ErrorCode, message: []const u8) void {
        var aw: Writer.Allocating = .fromArrayList(self.gpa, &c.out);
        defer c.out = aw.toArrayList();
        rpc.writeError(&aw.writer, id, code, message) catch {
            c.dead = true;
        };
    }

    pub fn sendEvent(self: *Server, c: *Conn, name: []const u8, params: anytype) void {
        if (c.dead or !c.hello_done) return;
        {
            var aw: Writer.Allocating = .fromArrayList(self.gpa, &c.out);
            defer c.out = aw.toArrayList();
            rpc.writeEvent(&aw.writer, name, params) catch {
                c.dead = true;
            };
        }
        self.checkOutbound(c);
    }

    /// PTY output for one attachment: a binary frame, or a `pty.data` event
    /// with base64 when the client did not negotiate binary frames.
    pub fn sendData(self: *Server, c: *Conn, channel: u32, session_id: []const u8, bytes: []const u8) void {
        // A closing client (its input ended) is owed its replies and events,
        // not more terminal output. That output would keep the connection
        // open for as long as the session prints, and since a closing client
        // does not throttle the PTY (`outputBlocked`), it could also push
        // the queue past max_outbound and drop the replies with it.
        if (c.dead or c.closing) return;
        var rest = bytes;
        while (rest.len > 0 and !c.dead) {
            const chunk = rest[0..@min(rest.len, read_chunk)];
            rest = rest[chunk.len..];
            if (c.binary) {
                var hdr: [frame.header_len]u8 = undefined;
                frame.encodeHeader(&hdr, .pty_data, channel, @intCast(chunk.len));
                c.out.appendSlice(self.gpa, &hdr) catch {
                    c.dead = true;
                    return;
                };
                c.out.appendSlice(self.gpa, chunk) catch {
                    c.dead = true;
                    return;
                };
            } else {
                var b64: [std.base64.standard.Encoder.calcSize(read_chunk)]u8 = undefined;
                const enc = std.base64.standard.Encoder.encode(&b64, chunk);
                self.sendEvent(c, msgs.event_pty_data, msgs.PtyDataEvent{ .channel = channel, .session_id = session_id, .data = enc });
            }
            self.checkOutbound(c);
        }
    }

    /// True while a client streaming `s` has `pty_high_water` or more bytes
    /// unsent. Dead and closing connections do not hold the session back.
    fn outputBlocked(self: *Server, s: *const Session) bool {
        for (s.attachments.items) |a| {
            if (a.channel == null) continue;
            const c = self.findConn(a.conn_id) orelse continue;
            if (!c.closing and c.pendingOut() >= self.cfg.pty_high_water) return true;
        }
        return false;
    }

    /// Reads PTY output into the ring and to streaming clients. With
    /// `throttle`, stops while `outputBlocked` (the final drain of an
    /// exited session does not throttle; it is bounded by its rounds).
    fn pumpSession(self: *Server, s: *Session, throttle: bool) void {
        var buf: [read_chunk]u8 = undefined;
        var rounds: usize = 0;
        while (rounds < 4 and s.master >= 0 and !s.master_eof) : (rounds += 1) {
            if (throttle and self.outputBlocked(s)) return;
            const n = posix.read(s.master, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => 0, // EIO: every slave fd is closed
            };
            if (n == 0) {
                s.master_eof = true;
                return;
            }
            s.ring.append(buf[0..n]);
            for (s.attachments.items) |a| {
                const ch = a.channel orelse continue;
                const c = self.findConn(a.conn_id) orelse continue;
                self.sendData(c, ch, s.id, buf[0..n]);
            }
        }
    }

    fn removeSession(self: *Server, s: *Session) void {
        _ = self.sessions.orderedRemove(s.id);
        self.graveyard.append(self.gpa, s) catch {
            // Out of memory: leak the session rather than free it mid-tick.
            log.info("leaking session {s}", .{s.id});
        };
    }

    /// The child exited: flush its last output, tell attached clients, drop it.
    fn finishSession(self: *Server, s: *Session) void {
        var rounds: usize = 0;
        while (!s.master_eof and s.master >= 0 and rounds < 64) : (rounds += 1) self.pumpSession(s, false);
        const ev: msgs.PtyExitEvent = .{ .session_id = s.id, .exit_code = s.exit.?.code, .signal = s.exit.?.signal };
        self.notifyAttached(s, msgs.event_pty_exit, ev);
        self.removeSession(s);
    }

    fn notifyAttached(self: *Server, s: *Session, name: []const u8, params: anytype) void {
        for (self.conns.items) |c| {
            if (c.dead) continue;
            for (s.attachments.items) |a| if (a.conn_id == c.id) {
                self.sendEvent(c, name, params);
                break;
            };
        }
    }

    /// Kills a session's process group (SIGHUP, SIGKILL after the grace
    /// period) and drops the session. Other attachments get `pty.detached`.
    pub fn closeSession(self: *Server, s: *Session, reason: []const u8, except_conn: ?u64) void {
        for (s.attachments.items) |a| {
            if (except_conn != null and a.conn_id == except_conn.?) continue;
            const c = self.findConn(a.conn_id) orelse continue;
            self.sendEvent(c, msgs.event_pty_detached, msgs.PtyDetachedEvent{ .session_id = s.id, .attachment_id = a.id, .reason = reason });
        }
        if (s.alive()) {
            pty.killGroup(s.pid, posix.SIG.HUP);
            self.reaping.append(self.gpa, .{ .pid = s.pid, .kill_at_ms = std.time.milliTimestamp() + self.cfg.kill_grace_ms }) catch {
                pty.killGroup(s.pid, posix.SIG.KILL);
                _ = std.c.waitpid(s.pid, null, 0);
            };
        }
        if (s.master >= 0) posix.close(s.master);
        s.master = -1;
        self.removeSession(s);
    }

    fn housekeeping(self: *Server, now: i64) void {
        if (self.cfg.stop_flag) |f| if (f.load(.acquire)) {
            self.stopped = true;
        };
        // Reap exited shells.
        var i: usize = 0;
        while (i < self.sessions.count()) {
            const s = self.sessions.values()[i];
            if (s.exit == null) s.exit = pty.tryReap(s.pid);
            if (s.exit != null) {
                self.finishSession(s);
                continue;
            }
            if (self.cfg.session_ttl_ms > 0 and s.attachments.items.len == 0 and now - s.detached_since_ms >= self.cfg.session_ttl_ms) {
                log.info("session {s} idle past ttl; closing", .{s.id});
                self.closeSession(s, "idle_ttl", null);
                continue;
            }
            i += 1;
        }
        // Closed sessions: escalate to SIGKILL after the grace period.
        var j: usize = 0;
        while (j < self.reaping.items.len) {
            const r = &self.reaping.items[j];
            if (pty.tryReap(r.pid) != null) {
                _ = self.reaping.swapRemove(j);
                continue;
            }
            if (now >= r.kill_at_ms) {
                pty.killGroup(r.pid, posix.SIG.KILL);
                r.kill_at_ms = std.math.maxInt(i64);
            }
            j += 1;
        }
        var live_conns: usize = 0;
        for (self.conns.items) |c| live_conns += @intFromBool(!c.dead);
        if (self.cfg.exit_when_no_clients and live_conns == 0) self.stopped = true;
        if (self.sessions.count() > 0 or live_conns > 0) self.busy_ms = now;
        if (self.cfg.idle_exit_ms > 0 and now - self.busy_ms >= self.cfg.idle_exit_ms) {
            log.info("idle; exiting", .{});
            self.stopped = true;
        }
    }

    /// Closes every session and waits (bounded) for the processes to exit.
    pub fn shutdownSessions(self: *Server) void {
        while (self.sessions.count() > 0) self.closeSession(self.sessions.values()[0], "shutdown", null);
        const deadline = std.time.milliTimestamp() + self.cfg.kill_grace_ms;
        while (self.reaping.items.len > 0 and std.time.milliTimestamp() < deadline) {
            var j: usize = 0;
            while (j < self.reaping.items.len) {
                if (pty.tryReap(self.reaping.items[j].pid) != null) _ = self.reaping.swapRemove(j) else j += 1;
            }
            if (self.reaping.items.len > 0) std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        for (self.reaping.items) |r| {
            pty.killGroup(r.pid, posix.SIG.KILL);
            _ = std.c.waitpid(r.pid, null, 0);
        }
        self.reaping.clearRetainingCapacity();
    }

    /// Destroys sessions removed this tick and connections marked dead
    /// (their attachments end; the sessions stay).
    fn sweep(self: *Server) void {
        for (self.graveyard.items) |s| s.destroy(self.gpa);
        self.graveyard.clearRetainingCapacity();
        const now = std.time.milliTimestamp();
        var i: usize = 0;
        while (i < self.conns.items.len) {
            const c = self.conns.items[i];
            if (!c.dead) {
                i += 1;
                continue;
            }
            for (self.sessions.values()) |s| {
                var k: usize = s.attachments.items.len;
                while (k > 0) {
                    k -= 1;
                    if (s.attachments.items[k].conn_id == c.id) s.removeAttachmentAt(self.gpa, k, now);
                }
            }
            _ = self.conns.orderedRemove(i);
            self.destroyConn(c);
        }
    }

    pub fn newAttachmentId(self: *Server, buf: []u8) []const u8 {
        const id = std.fmt.bufPrint(buf, "a-{d}", .{self.next_attach_id}) catch unreachable;
        self.next_attach_id += 1;
        return id;
    }

    /// Kills and frees a session that never made it into the table.
    pub fn discardSession(self: *Server, s: *Session) void {
        pty.killGroup(s.pid, posix.SIG.KILL);
        _ = std.c.waitpid(s.pid, null, 0);
        s.destroy(self.gpa);
    }
};
