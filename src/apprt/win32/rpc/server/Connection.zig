//! One accepted client of the v2 pipe server and its connection thread
//! (ADR-3.2), plus the Win32 named-pipe bindings and overlapped I/O helpers
//! shared by PipeServer.zig and launch_pipe.zig.
//!
//! The thread first waits for an admission slot (pending connections),
//! then reads newline-delimited lines and handles one request at a time:
//! it hands the line to the dispatcher, then waits for the reply, the
//! request deadline, server shutdown or the client going away (a lookahead
//! read stays pending while it waits, so a vanished client is noticed: its
//! reply is discarded and the slot freed). Replies are therefore in request
//! order by construction.
//! Only this thread writes replies; `writeLine` serializes other writers
//! (event streams) through `write_mutex`.

const Connection = @This();

const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;
const Allocator = std.mem.Allocator;

const PipeServer = @import("PipeServer.zig");
const admission = @import("admission.zig");
const ratelimit = @import("ratelimit.zig");
const framer_mod = @import("../logic/framer.zig");
const request_state = @import("../logic/request_state.zig");

const log = std.log.scoped(.rpc_server);

// ---------------------------------------------------------------------------
// Win32 bindings (local: platform/win32.zig is not ours to edit)
// ---------------------------------------------------------------------------

pub const w32 = struct {
    pub const HANDLE = windows.HANDLE;
    pub const DWORD = windows.DWORD;
    pub const BOOL = windows.BOOL;
    pub const OVERLAPPED = windows.OVERLAPPED;

    pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
    pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
    pub const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
    pub const PIPE_TYPE_BYTE: DWORD = 0x00000000;
    pub const PIPE_READMODE_BYTE: DWORD = 0x00000000;
    pub const PIPE_WAIT: DWORD = 0x00000000;
    pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x00000008;
    pub const GENERIC_READ: DWORD = 0x80000000;
    pub const GENERIC_WRITE: DWORD = 0x40000000;
    pub const OPEN_EXISTING: DWORD = 3;
    pub const WAIT_OBJECT_0: DWORD = 0x00000000;
    pub const WAIT_TIMEOUT: DWORD = 0x00000102;
    pub const INFINITE: DWORD = 0xFFFFFFFF;
    pub const TOKEN_QUERY: DWORD = 0x0008;
    pub const TOKEN_USER_CLASS: c_int = 1;
    pub const SDDL_REVISION_1: DWORD = 1;
    pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

    pub const SID_AND_ATTRIBUTES = extern struct { Sid: ?*anyopaque, Attributes: DWORD };
    pub const TOKEN_USER = extern struct { User: SID_AND_ATTRIBUTES };

    pub extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
    pub extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetOverlappedResult(hFile: HANDLE, lpOverlapped: *OVERLAPPED, lpNumberOfBytesTransferred: *DWORD, bWait: BOOL) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CreateEventW(lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES, bManualReset: BOOL, bInitialState: BOOL, lpName: ?windows.LPCWSTR) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn WaitForMultipleObjects(nCount: DWORD, lpHandles: [*]const HANDLE, bWaitAll: BOOL, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    pub extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: windows.LPCWSTR, nTimeOut: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetNamedPipeClientProcessId(Pipe: HANDLE, ClientProcessId: *windows.ULONG) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetNamedPipeServerProcessId(Pipe: HANDLE, ServerProcessId: *windows.ULONG) callconv(.winapi) BOOL;
    pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    pub extern "advapi32" fn OpenProcessToken(ProcessHandle: HANDLE, DesiredAccess: DWORD, TokenHandle: *HANDLE) callconv(.winapi) BOOL;
    pub extern "advapi32" fn GetTokenInformation(TokenHandle: HANDLE, TokenInformationClass: c_int, TokenInformation: ?*anyopaque, TokenInformationLength: DWORD, ReturnLength: *DWORD) callconv(.winapi) BOOL;
    pub extern "advapi32" fn ConvertSidToStringSidW(Sid: *anyopaque, StringSid: *?windows.LPWSTR) callconv(.winapi) BOOL;
    pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(StringSecurityDescriptor: windows.LPCWSTR, StringSDRevision: DWORD, SecurityDescriptor: *?*anyopaque, SecurityDescriptorSize: ?*windows.ULONG) callconv(.winapi) BOOL;
    pub extern "advapi32" fn EqualSid(pSid1: *anyopaque, pSid2: *anyopaque) callconv(.winapi) BOOL;

    /// A manual-reset (or auto-reset) unnamed event, non-inheritable.
    pub fn event(manual: bool) error{CreateEventFailed}!HANDLE {
        return CreateEventW(null, @intFromBool(manual), windows.FALSE, null) orelse error.CreateEventFailed;
    }
};

pub const IoResult = union(enum) {
    /// Completed; bytes transferred.
    done: u32,
    /// Failed (BROKEN_PIPE, NO_DATA, ...): the peer is gone.
    failed,
    timeout,
    /// `stop` was signaled.
    stopped,
};

/// Waits for an overlapped operation started on `handle` with `ov` (whose
/// hEvent is set). Wakes on completion, `stop` or `timeout_ms`; on the
/// latter two the operation is cancelled and drained, so the kernel is done
/// with `ov` and its buffer when this returns.
pub fn awaitIo(handle: w32.HANDLE, ov: *w32.OVERLAPPED, stop: ?w32.HANDLE, timeout_ms: u32) IoResult {
    var handles: [2]w32.HANDLE = .{ ov.hEvent.?, undefined };
    var count: w32.DWORD = 1;
    if (stop) |s| {
        handles[1] = s;
        count = 2;
    }
    const which = w32.WaitForMultipleObjects(count, &handles, windows.FALSE, timeout_ms);
    var n: w32.DWORD = 0;
    if (which == w32.WAIT_OBJECT_0) {
        if (w32.GetOverlappedResult(handle, ov, &n, windows.TRUE) == 0) return .failed;
        return .{ .done = n };
    }
    _ = kernel32.CancelIoEx(handle, ov);
    const finished = w32.GetOverlappedResult(handle, ov, &n, windows.TRUE) != 0;
    // The operation may have completed while we were cancelling it.
    if (finished and which == w32.WAIT_TIMEOUT) return .{ .done = n };
    return if (which == w32.WAIT_TIMEOUT) .timeout else .stopped;
}

/// Starts an overlapped ReadFile. False when it failed synchronously (the
/// peer is gone); otherwise wait with `awaitIo` or the event.
pub fn startRead(handle: w32.HANDLE, ov: *w32.OVERLAPPED, buf: []u8) bool {
    const event = ov.hEvent;
    ov.* = std.mem.zeroes(w32.OVERLAPPED);
    ov.hEvent = event;
    _ = w32.ResetEvent(event.?);
    const len: w32.DWORD = @intCast(@min(buf.len, std.math.maxInt(w32.DWORD)));
    if (kernel32.ReadFile(handle, buf.ptr, len, null, ov) != 0) return true;
    return windows.GetLastError() == .IO_PENDING;
}

/// Writes all of `bytes` with overlapped WriteFile calls, giving up after
/// `timeout_ms` per call or when `stop` is signaled.
pub fn writeAllTimeout(handle: w32.HANDLE, event: w32.HANDLE, stop: ?w32.HANDLE, bytes: []const u8, timeout_ms: u32) bool {
    var rest = bytes;
    while (rest.len > 0) {
        var ov = std.mem.zeroes(w32.OVERLAPPED);
        ov.hEvent = event;
        _ = w32.ResetEvent(event);
        const len: w32.DWORD = @intCast(@min(rest.len, 1 << 30));
        if (kernel32.WriteFile(handle, rest.ptr, len, null, &ov) == 0 and windows.GetLastError() != .IO_PENDING) return false;
        switch (awaitIo(handle, &ov, stop, timeout_ms)) {
            .done => |n| {
                if (n == 0) return false;
                rest = rest[n..];
            },
            .failed, .timeout, .stopped => return false,
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

/// One request handed to the dispatcher. Lives on the connection thread's
/// stack until the reply is written or expired; other threads refer to it
/// only through its `token` (PipeServer.begin/markDeferred/complete).
pub const Request = struct {
    token: request_state.Token,
    /// The raw line without terminator (may carry the capability prefix).
    /// Valid only during `Handler.dispatch`: copy what outlives the call.
    line: []const u8,
    /// Set by `dispatch` (synchronously) to the method's deadline; 0 = none
    /// (streaming and long-poll methods). Defaults to Config.default_deadline_ms.
    deadline_ms: u32,
    /// Named in the timeout reply (`main_actor` for the UI lane).
    stage: []const u8 = request_state.stage_main_actor,
    lifecycle: request_state.Lifecycle = .{},
};

/// What `Handler.on_connect` decides for a new connection.
pub const ConnectAction = enum {
    /// Serve with the normal line cap.
    authorized,
    /// Serve under the pre-authorization caps (one of 16 slots, 4 MiB
    /// lines, 2 s per line) until `authorize` is called.
    needs_auth,
    /// Close without reading.
    reject,
};

server: *PipeServer,
gpa: Allocator,
pipe: w32.HANDLE,
read_event: w32.HANDLE,
write_event: w32.HANDLE,
/// Auto-reset; signaled when a reply is stored.
reply_event: w32.HANDLE,
read_ov: w32.OVERLAPPED = std.mem.zeroes(w32.OVERLAPPED),
read_buf: []u8,
/// A lookahead read is in flight on `read_ov`/`read_buf`.
read_pending: bool = false,
/// A read failed: the client closed its end.
client_gone: bool = false,
/// Bytes in `read_buf` not yet fed to the framer.
ahead_len: usize = 0,
framer: framer_mod.LineFramer,
/// Accepted while the pool was full: wait for a slot first.
must_wait: bool,
/// Slot index and generation (valid once `run` claimed a slot).
conn_id: u64 = 0,
generation: u64 = 0,
client_pid: u32 = 0,
seq: u64 = 0,
authorized: std.atomic.Value(bool) = .init(false),
/// Holds one of the gate's pre-authorization slots.
preauth: bool = false,
preauth_timer: ?std.time.Timer = null,
limiter: ratelimit.Limiter,
/// Serializes writers of this pipe (replies and future event streams).
write_mutex: std.Thread.Mutex = .{},
thread: ?std.Thread = null,
/// Free for the dispatcher (auth state, stream subscriber, ...).
user_data: ?*anyopaque = null,

// Guarded by server.mutex:
current: ?*Request = null,
reply: ?[]u8 = null,

pub fn create(server: *PipeServer, pipe: w32.HANDLE, must_wait: bool) !*Connection {
    const gpa = server.gpa;
    const self = try gpa.create(Connection);
    errdefer gpa.destroy(self);
    const read_buf = try gpa.alloc(u8, server.config.buffer_size);
    errdefer gpa.free(read_buf);
    const read_event = try w32.event(true);
    errdefer windows.CloseHandle(read_event);
    const write_event = try w32.event(true);
    errdefer windows.CloseHandle(write_event);
    const reply_event = try w32.event(false);
    self.* = .{
        .server = server,
        .gpa = gpa,
        .pipe = pipe,
        .read_event = read_event,
        .write_event = write_event,
        .reply_event = reply_event,
        .read_buf = read_buf,
        .framer = .init(server.config.max_line_bytes),
        .must_wait = must_wait,
        .limiter = .init(server.config.rate),
    };
    self.read_ov.hEvent = read_event;
    return self;
}

/// Frees everything; the thread must have been joined. Cancels a pending
/// read before the buffer goes away.
pub fn destroy(self: *Connection) void {
    self.closePipe();
    if (self.reply) |r| self.gpa.free(r);
    self.framer.deinit(self.gpa);
    windows.CloseHandle(self.read_event);
    windows.CloseHandle(self.write_event);
    windows.CloseHandle(self.reply_event);
    self.gpa.free(self.read_buf);
    self.gpa.destroy(self);
}

fn closePipe(self: *Connection) void {
    if (self.read_pending) {
        var n: w32.DWORD = 0;
        _ = kernel32.CancelIoEx(self.pipe, &self.read_ov);
        _ = w32.GetOverlappedResult(self.pipe, &self.read_ov, &n, windows.TRUE);
        self.read_pending = false;
    }
    if (self.pipe != windows.INVALID_HANDLE_VALUE) {
        windows.CloseHandle(self.pipe);
        self.pipe = windows.INVALID_HANDLE_VALUE;
    }
}

/// The client's process id (0 if unknown).
pub fn clientPid(self: *const Connection) u32 {
    return self.client_pid;
}

/// Marks the connection authorized (any thread): it leaves its
/// pre-authorization slot and gets the normal line cap after the current
/// request.
pub fn authorize(self: *Connection) void {
    self.authorized.store(true, .release);
}

pub fn isAuthorized(self: *const Connection) bool {
    return self.authorized.load(.acquire);
}

/// For methods flagged `polling`: null when allowed, else the
/// `retry_after_ms` of a `rate_limited` reply (ratelimit.rateLimitedLineAlloc).
pub fn takePollingToken(self: *Connection) ?u32 {
    return self.limiter.take();
}

/// Writes `line` plus LF. Any thread, while the connection is alive.
pub fn writeLine(self: *Connection, line: []const u8) bool {
    return self.writeLineOpts(line, self.server.stop_event, self.server.config.write_timeout_ms);
}

fn writeLineOpts(self: *Connection, line: []const u8, stop: ?w32.HANDLE, timeout_ms: u32) bool {
    self.write_mutex.lock();
    defer self.write_mutex.unlock();
    if (self.pipe == windows.INVALID_HANDLE_VALUE) return false;
    if (!writeAllTimeout(self.pipe, self.write_event, stop, line, timeout_ms)) return false;
    return writeAllTimeout(self.pipe, self.write_event, stop, "\n", timeout_ms);
}

/// Last words when stopping or rejecting: ignores the stop event and
/// gives up quickly.
fn writeFinal(self: *Connection, line: []const u8) void {
    _ = self.writeLineOpts(line, null, final_write_timeout_ms);
}

pub const final_write_timeout_ms: u32 = 500;

// ---------------------------------------------------------------------------
// Connection thread
// ---------------------------------------------------------------------------

/// Thread entry. Always ends with `server.connectionFinished(self)`, after
/// which the accept thread (or `stop`) joins and destroys the connection.
pub fn run(self: *Connection) void {
    defer self.server.connectionFinished(self);
    defer self.closePipe();
    const server = self.server;
    if (self.must_wait) switch (server.gate.waitForSlot()) {
        .admitted => {},
        .rejected => |reason| return self.rejectOverloaded(reason),
    };
    defer server.gate.release();
    if (!server.claimSlot(self)) return self.rejectOverloaded(.pool_saturated);
    defer server.releaseSlot(self);

    var pid: windows.ULONG = 0;
    if (w32.GetNamedPipeClientProcessId(self.pipe, &pid) != 0) self.client_pid = pid;

    const action: ConnectAction = if (server.handler.on_connect) |f| f(server.handler.ctx, self) else .authorized;
    switch (action) {
        .authorized => self.authorized.store(true, .release),
        .needs_auth => {
            if (server.gate.beginPreauth()) |reason| return self.rejectOverloaded(reason);
            self.preauth = true;
            self.framer.setMaxLine(@min(server.config.preauth_max_line_bytes, server.config.max_line_bytes));
            self.preauth_timer = std.time.Timer.start() catch null;
        },
        .reject => return,
    }
    defer if (self.preauth) server.gate.endPreauth();
    defer if (server.handler.on_disconnect) |f| f(server.handler.ctx, self);
    self.serve();
}

fn rejectOverloaded(self: *Connection, reason: admission.Reason) void {
    const line = admission.overloadedLineAlloc(self.gpa, .null, reason) catch return;
    defer self.gpa.free(line);
    self.writeFinal(line);
}

/// Leaves pre-authorization once the dispatcher called `authorize`.
fn applyAuth(self: *Connection) void {
    if (!self.preauth or !self.isAuthorized()) return;
    self.server.gate.endPreauth();
    self.preauth = false;
    self.preauth_timer = null;
    self.framer.setMaxLine(self.server.config.max_line_bytes);
}

fn stopping(self: *const Connection) bool {
    return self.server.isStopping();
}

fn serve(self: *Connection) void {
    const config = &self.server.config;
    while (!self.stopping()) {
        self.applyAuth();
        while (self.framer.next()) |ev| {
            switch (ev) {
                .oversized => {
                    const line = request_state.oversizedLineAlloc(self.gpa, self.framer.max_line) catch return;
                    defer self.gpa.free(line);
                    if (!self.writeLine(line)) return;
                },
                .line => |line| if (!self.handleLine(line)) return,
            }
            if (self.preauth) {
                if (self.preauth_timer) |*t| t.reset();
            }
            self.applyAuth();
            if (self.stopping()) return;
        }
        if (self.ahead_len > 0) {
            const n = self.ahead_len;
            self.ahead_len = 0;
            self.framer.feed(self.gpa, self.read_buf[0..n]) catch return;
            continue;
        }
        var timeout: u32 = w32.INFINITE;
        if (self.preauth) {
            const spent_ms = if (self.preauth_timer) |*t| t.read() / std.time.ns_per_ms else 0;
            timeout = @intCast(@as(u64, config.preauth_read_ms) -| spent_ms);
        }
        if (!self.read_pending) {
            if (!startRead(self.pipe, &self.read_ov, self.read_buf)) return;
            self.read_pending = true;
        }
        const result = awaitIo(self.pipe, &self.read_ov, self.server.stop_event, timeout);
        self.read_pending = false;
        switch (result) {
            .done => |n| self.framer.feed(self.gpa, self.read_buf[0..n]) catch return,
            .failed, .stopped => return,
            .timeout => {
                const line = request_state.timeoutLineAlloc(self.gpa, .null, request_state.stage_preauthorization, config.preauth_read_ms, true) catch return;
                defer self.gpa.free(line);
                self.writeFinal(line);
                return;
            },
        }
    }
}

const Outcome = enum {
    /// A reply was stored: write it.
    reply,
    /// The deadline passed: the timeout reply was written (or failed).
    timed_out,
    /// The client went away or a write failed: close.
    gone,
    /// The server is stopping: the stopping reply was written; close.
    stopped,
};

/// Dispatches one line and writes its reply. False closes the connection.
fn handleLine(self: *Connection, line: []const u8) bool {
    const server = self.server;
    self.seq += 1;
    var req: Request = .{
        .token = .{ .conn_id = self.conn_id, .generation = self.generation, .request_seq = self.seq },
        .line = line,
        .deadline_ms = server.config.default_deadline_ms,
    };
    // Needed for transport-written replies; the dispatcher echoes ids itself.
    var id_arena = std.heap.ArenaAllocator.init(self.gpa);
    defer id_arena.deinit();
    const id = request_state.peekId(id_arena.allocator(), line);

    server.setCurrent(self, &req);
    server.handler.dispatch(server.handler.ctx, self, &req);
    const outcome = self.awaitReply(&req, id);
    const reply = server.takeCurrent(self);
    defer if (reply) |r| self.gpa.free(r);
    if (self.client_gone) return false;
    return switch (outcome) {
        .reply => if (reply) |r| self.writeLine(r) else true,
        .timed_out => true,
        .gone, .stopped => false,
    };
}

/// Waits for the reply of `req` while keeping a lookahead read pending, so
/// a client that vanishes mid-request is noticed (see `clientLeft`).
fn awaitReply(self: *Connection, req: *Request, id: std.json.Value) Outcome {
    const server = self.server;
    var timer = std.time.Timer.start() catch null;
    while (true) {
        if (server.hasReply(self)) return .reply;
        if (!self.read_pending and self.ahead_len == 0 and !self.client_gone) {
            if (startRead(self.pipe, &self.read_ov, self.read_buf)) {
                self.read_pending = true;
            } else if (self.clientLeft(req)) return .gone;
        }
        var handles: [3]w32.HANDLE = .{ self.reply_event, server.stop_event, self.read_event };
        const count: w32.DWORD = if (self.read_pending) 3 else 2;
        var timeout: u32 = w32.INFINITE;
        if (req.deadline_ms != 0) {
            const spent_ms: u64 = if (timer) |*t| t.read() / std.time.ns_per_ms else 0;
            timeout = @intCast(@as(u64, req.deadline_ms) -| spent_ms);
        }
        const which = w32.WaitForMultipleObjects(count, &handles, windows.FALSE, timeout);
        switch (which) {
            w32.WAIT_OBJECT_0 => continue,
            w32.WAIT_OBJECT_0 + 1 => return self.stopRequest(req, id),
            w32.WAIT_OBJECT_0 + 2 => {
                var n: w32.DWORD = 0;
                const ok = w32.GetOverlappedResult(self.pipe, &self.read_ov, &n, windows.TRUE) != 0;
                self.read_pending = false;
                if (!ok) {
                    if (self.clientLeft(req)) return .gone;
                } else self.ahead_len = n;
            },
            w32.WAIT_TIMEOUT => {
                const expiry = req.lifecycle.expire();
                const line = (request_state.expiryLineAlloc(self.gpa, id, expiry, req.stage, req.deadline_ms) catch return .gone) orelse continue;
                defer self.gpa.free(line);
                return if (self.writeLine(line)) .timed_out else .gone;
            },
            else => {
                log.warn("connection wait failed: {d}", .{which});
                _ = req.lifecycle.expire();
                return .gone;
            },
        }
    }
}

/// The client went away mid-request. A request with a deadline still runs
/// to completion or deadline (fire-and-forget clients close right after
/// writing); its reply is discarded when the write fails and the slot is
/// freed then. A request without a deadline (a stream) is abandoned now.
/// True when the connection should close immediately.
fn clientLeft(self: *Connection, req: *Request) bool {
    self.client_gone = true;
    if (req.deadline_ms != 0) return false;
    _ = req.lifecycle.expire();
    return true;
}

/// Shutdown with a request in flight: queued → `overloaded
/// server_stopping` (it never ran), running/deferred → `cancelled`.
fn stopRequest(self: *Connection, req: *Request, id: std.json.Value) Outcome {
    const line = switch (req.lifecycle.expire()) {
        .not_started => admission.overloadedLineAlloc(self.gpa, id, .server_stopping),
        .abandoned => request_state.cancelledLineAlloc(self.gpa, id),
        // Completed while we were stopping: deliver the real reply.
        .none => {
            if (self.server.takeReplyOnly(self)) |r| {
                defer self.gpa.free(r);
                self.writeFinal(r);
            }
            return .stopped;
        },
    } catch return .stopped;
    defer self.gpa.free(line);
    self.writeFinal(line);
    return .stopped;
}
