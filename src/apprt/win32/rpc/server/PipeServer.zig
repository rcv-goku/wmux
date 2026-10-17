//! The v2 named-pipe server (ARCHITECTURE.md ADR-3.1–3.5): thread per
//! connection over overlapped I/O, App-agnostic.
//!
//! - One accept thread keeps one spare instance in ConnectNamedPipe. The
//!   first instance is created in `start` with FILE_FLAG_FIRST_PIPE_INSTANCE
//!   (squatting defense: `error.PipeNameInUse` when the name exists); every
//!   instance has a current-user-only DACL, PIPE_REJECT_REMOTE_CLIENTS and a
//!   non-inheritable handle. The instance count is explicit:
//!   max_live + max_pending + 2 (the spare and one being rejected).
//! - Admission (admission.zig, cmux numbers): 64 live, 64 pending for at
//!   most 15 s, 16 pre-authorization readers; overflow is accepted,
//!   answered `overloaded {retryable, retry_after_ms, reason}` and closed.
//! - Each connection thread (Connection.zig) frames lines (1 MiB cap),
//!   hands each line to `Handler.dispatch` and writes the reply before it
//!   handles the next line, so replies are in request order.
//! - Replies come back through `complete(token, line)` from any thread.
//!   Tokens carry the slot, the connection generation and the request
//!   number: a completion for a client that left, for an expired request or
//!   for an earlier client of a reused slot is dropped.
//! - Deadlines: each request has `deadline_ms` (dispatch sets the method's;
//!   default 10 s). On expiry a queued request (never `begin`-ed) gets
//!   `timeout {retryable:true}`, a running one `timeout {retryable:false}`.
//! - `stop` rejects new clients, answers in-flight requests
//!   (`overloaded server_stopping` if queued, `cancelled` if running),
//!   cancels all I/O and joins every thread. `deinit` then frees.
//!
//! Wiring for W1-1a: rpc/server/mod.zig starts one PipeServer on the
//! control pipe with a Handler whose dispatch runs the registry dispatcher.

const PipeServer = @This();

const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");

pub const Connection = @import("Connection.zig");
pub const admission = @import("admission.zig");
pub const ratelimit = @import("ratelimit.zig");
pub const framer = @import("../logic/framer.zig");
pub const request_state = @import("../logic/request_state.zig");

const w32 = Connection.w32;
const log = std.log.scoped(.rpc_server);

pub const Token = request_state.Token;
pub const Request = Connection.Request;
pub const ConnectAction = Connection.ConnectAction;

pub const Config = struct {
    /// `\\.\pipe\<name>` or the bare `<name>` (pipe_name.zig builds it).
    name: []const u8,
    /// Create the first instance with FILE_FLAG_FIRST_PIPE_INSTANCE.
    first_instance: bool = true,
    /// Add `(A;;GRGW;;;WD)` to the DACL (`allowAll` access mode, ADR-3.8).
    allow_all: bool = false,
    limits: admission.Limits = .{},
    rate: ratelimit.Config = .{},
    max_line_bytes: usize = framer.default_max_line,
    preauth_max_line_bytes: usize = framer.preauth_max_line,
    preauth_read_ms: u32 = 2_000,
    default_deadline_ms: u32 = 10_000,
    /// Per WriteFile call; a client that stops reading is dropped.
    write_timeout_ms: u32 = 10_000,
    /// Pipe in/out buffer size and read chunk size.
    buffer_size: u32 = 64 * 1024,
};

/// The dispatcher interface. Callbacks run on connection threads.
pub const Handler = struct {
    ctx: ?*anyopaque = null,
    /// Called once per non-blank line within the cap. Must arrange exactly
    /// one `server.complete(req.token, reply_line)` (inline, or later from
    /// any thread), or let the deadline answer. May set `req.deadline_ms`
    /// and `req.stage` before returning. Lanes that hop threads call
    /// `server.begin(token)` before running the method and skip it when
    /// that returns false (the request expired).
    dispatch: *const fn (ctx: ?*anyopaque, conn: *Connection, req: *Request) void,
    /// Decides how a new connection is served (default: authorized).
    on_connect: ?*const fn (ctx: ?*anyopaque, conn: *Connection) ConnectAction = null,
    /// Called before the connection's slot is freed.
    on_disconnect: ?*const fn (ctx: ?*anyopaque, conn: *Connection) void = null,
};

pub const Completion = enum { delivered, dropped };

/// Initial stack of the accept and connection threads. On Windows,
/// std.Thread hands `stack_size` to CreateThread as the size to *commit*
/// up front, so the 16 MiB default would commit 16 MiB per connection
/// (about 2 GiB at 64 live + 64 pending). The stack still grows on demand
/// up to the executable's reserve (16 MiB for Zig-built exes).
pub const thread_stack_size: usize = 256 * 1024;

pub const StartError = error{
    /// FIRST_PIPE_INSTANCE failed: another server (maybe not ours) owns the name.
    PipeNameInUse,
    InvalidName,
    CreatePipeFailed,
    SecurityDescriptorFailed,
    CreateEventFailed,
    ThreadSpawnFailed,
    OutOfMemory,
};

pub const Counts = admission.Counts;

gpa: Allocator,
config: Config,
handler: Handler,
/// Canonical `\\.\pipe\<name>` (owned).
path: []u8,
path_w: [:0]u16,
security: PipeSecurity,
/// Manual-reset; set once by `stop`.
stop_event: w32.HANDLE,
/// Auto-reset; a connection finished (reap it) or an instance freed up.
reap_event: w32.HANDLE,
connect_event: w32.HANDLE,
gate: admission.Gate,
/// The instance waiting in ConnectNamedPipe (accept thread only).
spare: w32.HANDLE,
stopping: std.atomic.Value(bool) = .init(false),
accept_thread: ?std.Thread = null,
stopped: bool = false,

/// Guards slots, conns, finished and every Connection.current/reply.
mutex: std.Thread.Mutex = .{},
slots: request_state.Slots(*Connection),
/// Every connection whose thread was spawned and not yet joined.
conns: std.ArrayList(*Connection) = .empty,
/// Connections whose thread returned (join, then destroy).
finished: std.ArrayList(*Connection) = .empty,

/// Creates the first instance (so clients can connect as soon as this
/// returns) and starts the accept thread.
pub fn start(gpa: Allocator, config: Config, handler: Handler) StartError!*PipeServer {
    const path = proto.pipe_name.normalize(gpa, config.name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidName,
    };
    errdefer gpa.free(path);
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidName,
    };
    errdefer gpa.free(path_w);
    var security = PipeSecurity.init(gpa, config.allow_all) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SecurityDescriptorFailed,
    };
    errdefer security.deinit();

    const self = try gpa.create(PipeServer);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .config = config,
        .handler = handler,
        .path = path,
        .path_w = path_w,
        .security = security,
        .stop_event = undefined,
        .reap_event = undefined,
        .connect_event = undefined,
        .gate = .init(config.limits),
        .spare = windows.INVALID_HANDLE_VALUE,
        .slots = try .init(gpa, config.limits.max_live),
    };
    self.config.name = path;
    errdefer self.slots.deinit(gpa);

    self.stop_event = try w32.event(true);
    errdefer windows.CloseHandle(self.stop_event);
    self.reap_event = try w32.event(false);
    errdefer windows.CloseHandle(self.reap_event);
    self.connect_event = try w32.event(true);
    errdefer windows.CloseHandle(self.connect_event);

    self.spare = try self.createInstance(config.first_instance);
    errdefer windows.CloseHandle(self.spare);
    self.accept_thread = std.Thread.spawn(.{ .stack_size = thread_stack_size }, acceptLoop, .{self}) catch return error.ThreadSpawnFailed;
    return self;
}

/// Stops accepting, answers in-flight requests, cancels all I/O and joins
/// every thread. Idempotent. Afterwards `complete`/`begin` are no-ops that
/// report `dropped`/false; call them no more once `deinit` runs.
pub fn stop(self: *PipeServer) void {
    if (self.stopped) return;
    self.stopped = true;
    self.stopping.store(true, .release);
    self.gate.stop();
    _ = w32.SetEvent(self.stop_event);
    if (self.accept_thread) |t| t.join();
    self.accept_thread = null;
    // Connection threads wake on stop_event (or the gate) and finish.
    while (true) {
        self.mutex.lock();
        const conn = self.conns.pop();
        self.mutex.unlock();
        const c = conn orelse break;
        if (c.thread) |t| t.join();
        c.destroy();
    }
    self.mutex.lock();
    self.finished.clearRetainingCapacity();
    self.mutex.unlock();
}

/// `stop`, then frees the server.
pub fn deinit(self: *PipeServer) void {
    self.stop();
    const gpa = self.gpa;
    self.conns.deinit(gpa);
    self.finished.deinit(gpa);
    self.slots.deinit(gpa);
    windows.CloseHandle(self.stop_event);
    windows.CloseHandle(self.reap_event);
    windows.CloseHandle(self.connect_event);
    self.security.deinit();
    gpa.free(self.path_w);
    gpa.free(self.path);
    gpa.destroy(self);
}

pub fn isStopping(self: *const PipeServer) bool {
    return self.stopping.load(.acquire);
}

/// Live, pending and pre-authorization connection counts.
pub fn counts(self: *PipeServer) Counts {
    return self.gate.counts();
}

fn instanceLimit(self: *const PipeServer) w32.DWORD {
    const n = @as(u64, self.config.limits.max_live) + self.config.limits.max_pending + 2;
    // 255 is PIPE_UNLIMITED_INSTANCES; stay one below it to keep the cap explicit.
    return @intCast(@min(n, 254));
}

fn createInstance(self: *PipeServer, first: bool) StartError!w32.HANDLE {
    var sa: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = self.security.descriptor,
        .bInheritHandle = windows.FALSE,
    };
    const open_mode = w32.PIPE_ACCESS_DUPLEX | w32.FILE_FLAG_OVERLAPPED |
        (if (first) w32.FILE_FLAG_FIRST_PIPE_INSTANCE else 0);
    const pipe_mode = w32.PIPE_TYPE_BYTE | w32.PIPE_READMODE_BYTE | w32.PIPE_WAIT | w32.PIPE_REJECT_REMOTE_CLIENTS;
    const h = kernel32.CreateNamedPipeW(
        self.path_w.ptr,
        open_mode,
        pipe_mode,
        self.instanceLimit(),
        self.config.buffer_size,
        self.config.buffer_size,
        0,
        &sa,
    );
    if (h == windows.INVALID_HANDLE_VALUE) {
        const err = windows.GetLastError();
        if (first and (err == .ACCESS_DENIED or err == .PIPE_BUSY)) return error.PipeNameInUse;
        log.warn("CreateNamedPipeW failed: {d}", .{@intFromEnum(err)});
        return error.CreatePipeFailed;
    }
    return h;
}

// ---------------------------------------------------------------------------
// Accept thread
// ---------------------------------------------------------------------------

fn acceptLoop(self: *PipeServer) void {
    defer {
        if (self.spare != windows.INVALID_HANDLE_VALUE) windows.CloseHandle(self.spare);
        self.spare = windows.INVALID_HANDLE_VALUE;
    }
    while (!self.isStopping()) {
        if (self.spare == windows.INVALID_HANDLE_VALUE) {
            // All instances busy (or a transient failure): wait for a
            // connection to finish, then retry.
            self.spare = self.createInstance(false) catch windows.INVALID_HANDLE_VALUE;
            if (self.spare == windows.INVALID_HANDLE_VALUE) {
                if (!self.waitReapOrStop(250)) return;
                continue;
            }
        }
        var ov = std.mem.zeroes(w32.OVERLAPPED);
        ov.hEvent = self.connect_event;
        _ = w32.ResetEvent(self.connect_event);
        var connected = false;
        if (w32.ConnectNamedPipe(self.spare, &ov) != 0) {
            connected = true;
        } else switch (windows.GetLastError()) {
            .PIPE_CONNECTED => connected = true,
            .IO_PENDING => {},
            // The client connected and left before we accepted.
            .NO_DATA => {
                self.recycleSpare();
                continue;
            },
            else => |err| {
                log.warn("ConnectNamedPipe failed: {d}", .{@intFromEnum(err)});
                self.recycleSpare();
                if (!self.waitReapOrStop(250)) return;
                continue;
            },
        }
        if (!connected) switch (self.waitConnect(&ov)) {
            .connected => {},
            .retry => {
                self.recycleSpare();
                continue;
            },
            .stop => return,
        };
        const pipe = self.spare;
        self.spare = windows.INVALID_HANDLE_VALUE;
        self.admit(pipe);
        self.reapFinished();
    }
}

const ConnectWait = enum { connected, retry, stop };

/// Waits for the pending connect on the spare, reaping finished
/// connections meanwhile. On stop the connect is cancelled and drained.
fn waitConnect(self: *PipeServer, ov: *w32.OVERLAPPED) ConnectWait {
    while (true) {
        const handles = [_]w32.HANDLE{ self.connect_event, self.stop_event, self.reap_event };
        const which = w32.WaitForMultipleObjects(handles.len, &handles, windows.FALSE, w32.INFINITE);
        var n: w32.DWORD = 0;
        switch (which) {
            w32.WAIT_OBJECT_0 => {
                if (w32.GetOverlappedResult(self.spare, ov, &n, windows.FALSE) != 0) return .connected;
                // The client vanished during the connect.
                return .retry;
            },
            w32.WAIT_OBJECT_0 + 2 => self.reapFinished(),
            else => {
                _ = kernel32.CancelIoEx(self.spare, ov);
                _ = w32.GetOverlappedResult(self.spare, ov, &n, windows.TRUE);
                return .stop;
            },
        }
    }
}

fn recycleSpare(self: *PipeServer) void {
    if (self.spare != windows.INVALID_HANDLE_VALUE) windows.CloseHandle(self.spare);
    self.spare = windows.INVALID_HANDLE_VALUE;
}

/// Waits up to `ms` for a finished connection (reaping it) or stop.
/// False on stop.
fn waitReapOrStop(self: *PipeServer, ms: u32) bool {
    const handles = [_]w32.HANDLE{ self.stop_event, self.reap_event };
    const which = w32.WaitForMultipleObjects(handles.len, &handles, windows.FALSE, ms);
    if (which == w32.WAIT_OBJECT_0) return false;
    self.reapFinished();
    return !self.isStopping();
}

/// Classifies a connected instance and hands it to a connection thread,
/// or answers `overloaded` inline and closes it.
fn admit(self: *PipeServer, pipe: w32.HANDLE) void {
    const verdict = self.gate.accept();
    const must_wait = switch (verdict) {
        .admit => false,
        .wait => true,
        .reject => |reason| return self.rejectInline(pipe, reason),
    };
    const conn = Connection.create(self, pipe, must_wait) catch {
        self.undoAccept(must_wait);
        return self.rejectInline(pipe, .accept_buffer_full);
    };
    self.mutex.lock();
    self.conns.append(self.gpa, conn) catch {
        self.mutex.unlock();
        conn.pipe = windows.INVALID_HANDLE_VALUE;
        conn.destroy();
        self.undoAccept(must_wait);
        return self.rejectInline(pipe, .accept_buffer_full);
    };
    // Spawn under the mutex so `conn.thread` is set before anyone joins.
    conn.thread = std.Thread.spawn(.{ .stack_size = thread_stack_size }, Connection.run, .{conn}) catch null;
    if (conn.thread == null) {
        _ = self.conns.pop();
        self.mutex.unlock();
        conn.pipe = windows.INVALID_HANDLE_VALUE;
        conn.destroy();
        self.undoAccept(must_wait);
        return self.rejectInline(pipe, .accept_buffer_full);
    }
    self.mutex.unlock();
}

fn undoAccept(self: *PipeServer, was_pending: bool) void {
    if (was_pending) {
        self.gate.mutex.lock();
        _ = self.gate.state.abandonPending();
        self.gate.mutex.unlock();
    } else {
        self.gate.release();
    }
}

fn rejectInline(self: *PipeServer, pipe: w32.HANDLE, reason: admission.Reason) void {
    defer windows.CloseHandle(pipe);
    const line = admission.overloadedLineAlloc(self.gpa, .null, reason) catch return;
    defer self.gpa.free(line);
    const event = w32.event(true) catch return;
    defer windows.CloseHandle(event);
    if (Connection.writeAllTimeout(pipe, event, null, line, Connection.final_write_timeout_ms))
        _ = Connection.writeAllTimeout(pipe, event, null, "\n", Connection.final_write_timeout_ms);
}

/// Joins and destroys connections whose thread returned.
fn reapFinished(self: *PipeServer) void {
    while (true) {
        self.mutex.lock();
        const conn = self.finished.pop() orelse {
            self.mutex.unlock();
            return;
        };
        for (self.conns.items, 0..) |c, i| if (c == conn) {
            _ = self.conns.swapRemove(i);
            break;
        };
        self.mutex.unlock();
        if (conn.thread) |t| t.join();
        conn.destroy();
    }
}

// ---------------------------------------------------------------------------
// Slots and replies (called by connection threads)
// ---------------------------------------------------------------------------

pub fn claimSlot(self: *PipeServer, conn: *Connection) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    const claimed = self.slots.claim(conn) orelse return false;
    conn.conn_id = claimed.conn_id;
    conn.generation = claimed.generation;
    return true;
}

pub fn releaseSlot(self: *PipeServer, conn: *Connection) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.slots.release(conn.conn_id, conn.generation);
}

pub fn setCurrent(self: *PipeServer, conn: *Connection, req: *Request) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.slots.entryFor(conn.conn_id, conn.generation)) |e| e.current_seq = req.token.request_seq;
    conn.current = req;
}

/// Clears the current request and returns its stored reply, if any.
pub fn takeCurrent(self: *PipeServer, conn: *Connection) ?[]u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.slots.entryFor(conn.conn_id, conn.generation)) |e| e.current_seq = 0;
    conn.current = null;
    const r = conn.reply;
    conn.reply = null;
    return r;
}

pub fn takeReplyOnly(self: *PipeServer, conn: *Connection) ?[]u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const r = conn.reply;
    conn.reply = null;
    return r;
}

pub fn hasReply(self: *PipeServer, conn: *Connection) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return conn.reply != null;
}

pub fn connectionFinished(self: *PipeServer, conn: *Connection) void {
    self.mutex.lock();
    self.finished.append(self.gpa, conn) catch {};
    self.mutex.unlock();
    _ = w32.SetEvent(self.reap_event);
}

/// The request `t` names, if its connection is still the one that sent it.
fn resolveRequest(self: *PipeServer, t: Token) ?*Request {
    const conn = self.slots.resolve(t) orelse return null;
    const req = conn.current orelse return null;
    return if (req.token.eql(t)) req else null;
}

// ---------------------------------------------------------------------------
// Completion API (any thread)
// ---------------------------------------------------------------------------

/// queued → running. Lanes that hop threads call this right before running
/// the method; false means skip it (expired, client gone or stopped).
pub fn begin(self: *PipeServer, t: Token) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    const req = self.resolveRequest(t) orelse return false;
    return req.lifecycle.begin();
}

/// running → deferred (`ctx.deferReply()`): a later timeout says
/// `retryable:false` like for a running request.
pub fn markDeferred(self: *PipeServer, t: Token) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    const req = self.resolveRequest(t) orelse return false;
    return req.lifecycle.markDeferred();
}

/// Delivers the one reply line (no terminator; one line, as produced by
/// wmux_proto.envelope) of request `t`. The line is copied. Dropped when
/// the connection is gone, its generation changed, the request expired or
/// was already completed, or on OutOfMemory (the deadline then answers).
pub fn complete(self: *PipeServer, t: Token, line: []const u8) Completion {
    const copy = self.gpa.dupe(u8, line) catch return .dropped;
    self.mutex.lock();
    const req = self.resolveRequest(t);
    if (req == null or !req.?.lifecycle.complete()) {
        self.mutex.unlock();
        self.gpa.free(copy);
        return .dropped;
    }
    const conn = self.slots.resolve(t).?;
    std.debug.assert(conn.reply == null);
    conn.reply = copy;
    // Under the mutex: the connection cannot finish and close the event.
    _ = w32.SetEvent(conn.reply_event);
    self.mutex.unlock();
    return .delivered;
}

// ---------------------------------------------------------------------------
// Security
// ---------------------------------------------------------------------------

/// The current process's user SID (TOKEN_USER), copied into `buf`.
pub const UserSid = struct {
    buf: [256]u8 align(@alignOf(w32.TOKEN_USER)) = undefined,

    pub fn sid(self: *UserSid) *anyopaque {
        const user: *const w32.TOKEN_USER = @ptrCast(&self.buf);
        return user.User.Sid.?;
    }

    /// Reads the user SID of `process` (a handle with query rights).
    pub fn ofProcess(self: *UserSid, process: w32.HANDLE) error{TokenQueryFailed}!void {
        var token: w32.HANDLE = undefined;
        if (w32.OpenProcessToken(process, w32.TOKEN_QUERY, &token) == 0) return error.TokenQueryFailed;
        defer windows.CloseHandle(token);
        var needed: w32.DWORD = 0;
        if (w32.GetTokenInformation(token, w32.TOKEN_USER_CLASS, &self.buf, self.buf.len, &needed) == 0)
            return error.TokenQueryFailed;
        const user: *const w32.TOKEN_USER = @ptrCast(&self.buf);
        if (user.User.Sid == null) return error.TokenQueryFailed;
    }

    /// `S-1-5-21-…` (heap, UTF-8).
    pub fn toStringAlloc(self: *UserSid, gpa: Allocator) error{ ConvertSidFailed, OutOfMemory }![]u8 {
        var sid_w: ?windows.LPWSTR = null;
        if (w32.ConvertSidToStringSidW(self.sid(), &sid_w) == 0) return error.ConvertSidFailed;
        defer _ = w32.LocalFree(sid_w);
        return proto.utf8.utf16LeToUtf8Alloc(gpa, std.mem.span(sid_w.?), 256) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ConvertSidFailed,
        };
    }
};

/// Owner and DACL of every instance (ADR-3.1): `O:<user>D:P(A;;GA;;;<user>)`,
/// plus `(A;;GRGW;;;WD)` for `allowAll`. The default medium mandatory label
/// applies (low-integrity clients are denied).
const PipeSecurity = struct {
    descriptor: *anyopaque,

    fn init(gpa: Allocator, allow_all: bool) !PipeSecurity {
        var user: UserSid = .{};
        try user.ofProcess(windows.GetCurrentProcess());
        const sid = try user.toStringAlloc(gpa);
        defer gpa.free(sid);
        const sddl = try std.fmt.allocPrint(gpa, "O:{s}D:P(A;;GA;;;{s}){s}", .{ sid, sid, if (allow_all) "(A;;GRGW;;;WD)" else "" });
        defer gpa.free(sddl);
        const sddl_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, sddl);
        defer gpa.free(sddl_w);
        var sd: ?*anyopaque = null;
        if (w32.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl_w.ptr, w32.SDDL_REVISION_1, &sd, null) == 0)
            return error.ConvertSddlFailed;
        return .{ .descriptor = sd.? };
    }

    fn deinit(self: *PipeSecurity) void {
        _ = w32.LocalFree(self.descriptor);
        self.* = undefined;
    }
};
