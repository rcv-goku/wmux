//! The legacy wmux-v1 JSON protocol over the v2 transport (ARCHITECTURE.md
//! ADR-3.1 "legacy pipe", ADR-3.7; W1-1a). Legacy requests
//! (`{"id":N,"cmd":"...","args":{...}}`) arrive on two pipes, both served
//! by the thread-per-connection `PipeServer`:
//!
//! - the control pipe, when a line sniffs as legacy JSON (rpc/dispatch.zig);
//! - `\\.\pipe\wmux-ipc-<pid>`, legacy only, for one release (removed at
//!   M3 by W3-1c, AF-18).
//!
//! Every command runs over the registry (`rpc/registry.zig`
//! `legacyCommand`): authorization (the read-only mode) and admission come
//! first, then the command's optional pipe-thread `prepare` stage, then the
//! handler on the UI thread through the UI lane (modal hold for commands
//! that are not read-only).
//!
//! Handlers reply through `app.ipc_server` (`Server.sendOk`/`sendError`,
//! any thread, possibly long after the handler returned for the async
//! browser commands). `Server` is the reply hub: before a request reaches
//! its handler its `id` is replaced with a hub token, and the reply is
//! routed back to the connection and request that sent it (with the
//! client's original id), or captured for an in-process caller. A reply
//! whose client left or whose request expired is dropped by the transport.
//! Replies keep the legacy shapes `{"id":N,"ok":true,"data":...}` and
//! `{"id":N,"ok":false,"error":"..."}` byte for byte.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");

const App = @import("../../App.zig");
const PipeServer = @import("PipeServer.zig");
const deadline = @import("../logic/deadline.zig");
const lanes = @import("../lanes.zig");
const legacy_json = @import("../compat/legacy_json.zig");
const rpc_registry = @import("../registry.zig");

const Connection = PipeServer.Connection;
const Request = legacy_json.Request;
const Token = PipeServer.Token;

const log = std.log.scoped(.win32_ipc);

/// The error text of a command refused by the read-only mode (unchanged
/// from the pre-W1-1a server).
pub const read_only_message = "socket-control=read-only: command refused";

/// What a captured reply holds (in-process callers, see `Server.runCaptured`).
pub const Captured = union(enum) {
    /// No reply (the handler went async or never answered).
    none,
    /// `data` JSON text (`null` when the handler sent none), owned.
    ok: []u8,
    /// The error string, owned.
    err: []u8,

    pub fn deinit(self: *Captured, gpa: Allocator) void {
        switch (self.*) {
            .none => {},
            .ok, .err => |s| gpa.free(s),
        }
        self.* = .none;
    }
};

/// The legacy reply hub (`app.ipc_server`). Thread-safe.
pub const Server = struct {
    gpa: Allocator,
    app: *App,
    /// The UI lane shared with the v2 dispatcher.
    ui: *lanes.UiLane,
    /// `socket-control = read-only`: only read-only commands run.
    read_only: bool = false,
    /// The `wmux-ipc-<pid>` pipe, while it runs.
    pipe: ?*PipeServer = null,

    mutex: std.Thread.Mutex = .{},
    next_token: u64 = 1,
    pending: std.AutoHashMapUnmanaged(u64, Pending) = .empty,

    pub const Sink = union(enum) {
        /// Write the reply to request `token` of `server`, echoing the
        /// client's id.
        conn: struct { server: *PipeServer, token: Token, client_id: u64 },
        /// Store the reply for an in-process caller.
        capture: *Captured,
    };

    const Pending = struct { sink: Sink, since_ms: i64 };

    /// Entries older than this are dropped on the next `register` (their
    /// request expired long ago: legacy requests have 60 s).
    const stale_after_ms: i64 = 10 * 60 * 1000;

    pub fn init(gpa: Allocator, app: *App, ui: *lanes.UiLane, read_only: bool) Server {
        return .{ .gpa = gpa, .app = app, .ui = ui, .read_only = read_only };
    }

    /// Frees the pending table (after every pipe server stopped).
    pub fn deinit(self: *Server) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending.deinit(self.gpa);
    }

    /// Hands out a token for `sink`; the request's `id` becomes this token.
    pub fn register(self: *Server, sink: Sink) Allocator.Error!u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.milliTimestamp();
        self.pruneLocked(now);
        const t = self.next_token;
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        try self.pending.put(self.gpa, t, .{ .sink = sink, .since_ms = now });
        return t;
    }

    fn pruneLocked(self: *Server, now: i64) void {
        if (self.pending.count() < 1024) return;
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.gpa);
        var it = self.pending.iterator();
        while (it.next()) |e| {
            if (now - e.value_ptr.since_ms > stale_after_ms) stale.append(self.gpa, e.key_ptr.*) catch return;
        }
        for (stale.items) |t| _ = self.pending.remove(t);
    }

    /// Forgets a token whose request will never reply (it expired before
    /// its handler ran).
    pub fn cancel(self: *Server, token: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.pending.remove(token);
    }

    /// Drops every pending reply bound to `server` (before it is freed).
    pub fn forgetServer(self: *Server, server: *PipeServer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var doomed: std.ArrayList(u64) = .empty;
        defer doomed.deinit(self.gpa);
        var it = self.pending.iterator();
        while (it.next()) |e| switch (e.value_ptr.sink) {
            .conn => |c| if (c.server == server) doomed.append(self.gpa, e.key_ptr.*) catch {},
            .capture => {},
        };
        for (doomed.items) |t| _ = self.pending.remove(t);
    }

    /// Send a success response for request `id` (a hub token). Thread-safe.
    /// `data_json` must already be valid serialized JSON; null sends
    /// `"data":null`.
    pub fn sendOk(self: *Server, id: u64, data_json: ?[]const u8) error{ NotConnected, OutOfMemory }!void {
        return self.deliver(id, .{ .ok = data_json });
    }

    /// Send an error response for request `id`. Thread-safe. `msg` is
    /// JSON-escaped.
    pub fn sendError(self: *Server, id: u64, msg: []const u8) error{ NotConnected, OutOfMemory }!void {
        return self.deliver(id, .{ .err = msg });
    }

    const Outcome = union(enum) { ok: ?[]const u8, err: []const u8 };

    fn deliver(self: *Server, id: u64, outcome: Outcome) error{ NotConnected, OutOfMemory }!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const kv = self.pending.fetchRemove(id) orelse return error.NotConnected;
        switch (kv.value.sink) {
            .conn => |c| {
                const line = switch (outcome) {
                    .ok => |data| try legacy_json.serializeOk(self.gpa, c.client_id, data),
                    .err => |msg| try legacy_json.serializeError(self.gpa, c.client_id, msg),
                };
                defer self.gpa.free(line);
                // Under the hub mutex: `forgetServer` runs before a server
                // is freed, so `c.server` is alive here.
                if (c.server.complete(c.token, trimNewline(line)) == .dropped) return error.NotConnected;
            },
            .capture => |cap| {
                cap.deinit(self.gpa);
                cap.* = switch (outcome) {
                    .ok => |data| .{ .ok = try self.gpa.dupe(u8, data orelse "null") },
                    .err => |msg| .{ .err = try self.gpa.dupe(u8, msg) },
                };
            },
        }
    }

    /// Handles one legacy line received by `conn` (any connection thread):
    /// the control pipe after sniffing, or the legacy pipe. Replies are
    /// legacy JSON; parse failures answer at once.
    pub fn dispatchLine(self: *Server, conn: *Connection, req: *PipeServer.Request, payload: []const u8) void {
        const server = conn.server;
        req.deadline_ms = deadline.legacy_deadline_ms;
        req.stage = deadline.stage_main_actor;
        const parsed = legacy_json.parseLine(self.gpa, payload) catch {
            req.legacy_id = 0;
            return completeError(self.gpa, server, req.token, 0, "out of memory");
        };
        const lreq = switch (parsed) {
            .err => |f| {
                req.legacy_id = f.id;
                return completeError(self.gpa, server, req.token, f.id, f.code.message());
            },
            .ok => |r| r,
        };
        req.legacy_id = lreq.id;
        const command = rpc_registry.legacyCommand(lreq.cmd);

        // Authorization before any side effect: a refused command never
        // reaches `prepare` (W1-1a carried follow-up).
        if (self.read_only and !command.read_only) {
            completeError(self.gpa, server, req.token, lreq.id, read_only_message);
            return lreq.destroy();
        }

        const client_id = lreq.id;
        lreq.id = self.register(.{ .conn = .{ .server = server, .token = req.token, .client_id = client_id } }) catch {
            completeError(self.gpa, server, req.token, client_id, "out of memory");
            return lreq.destroy();
        };

        // The optional pipe-thread stage (only `workspace-new --worktree`,
        // which runs `git worktree add` off the UI thread). When it fails it
        // has already answered through the hub.
        if (command.prepare) |prepare| {
            if (!prepare(self.app, lreq)) return lreq.destroy();
        }

        const call = self.gpa.create(Call) catch {
            self.sendError(lreq.id, "out of memory") catch {};
            return lreq.destroy();
        };
        call.* = .{
            .hub = self,
            .gpa = self.gpa,
            .server = server,
            .token = req.token,
            .req = lreq,
            .item = .{ .run = Call.run, .destroy = Call.destroy, .read_only = command.read_only },
        };
        self.ui.post(&call.item);
    }

    /// Runs legacy request `lreq` on the UI thread now and returns its
    /// reply, if the handler answered synchronously (UI thread; takes
    /// ownership of `lreq`). Used by in-process bridges.
    pub fn runCaptured(self: *Server, lreq: *Request) Captured {
        defer lreq.destroy();
        var cap: Captured = .none;
        lreq.id = self.register(.{ .capture = &cap }) catch return .{ .err = self.gpa.dupe(u8, "OutOfMemory") catch return .none };
        const token = lreq.id;
        rpc_registry.legacyCommand(lreq.cmd).handler(self.app, lreq) catch |err| {
            self.sendError(token, @errorName(err)) catch {};
        };
        // An async handler keeps the token; its late reply must not write
        // into this stack slot.
        self.cancel(token);
        return cap;
    }
};

/// A legacy request on its way to the UI thread.
const Call = struct {
    hub: *Server,
    /// Kept here: a call destroyed after the hub was freed (still queued in
    /// app.tasks at shutdown) must not touch the hub.
    gpa: Allocator,
    server: *PipeServer,
    token: Token,
    req: ?*Request,
    item: lanes.UiItem,

    fn run(item: *lanes.UiItem, app: *App) void {
        const self: *Call = @fieldParentPtr("item", item);
        const req = self.req orelse return;
        const hub_token = req.id;
        // Skipped when the request expired (or its client left) while
        // queued: the command never runs.
        if (!self.server.begin(self.token)) {
            self.hub.cancel(hub_token);
            return;
        }
        rpc_registry.legacyCommand(req.cmd).handler(app, req) catch |err| {
            self.hub.sendError(hub_token, @errorName(err)) catch {};
        };
    }

    fn destroy(item: *lanes.UiItem) void {
        const self: *Call = @fieldParentPtr("item", item);
        if (self.req) |r| r.destroy();
        self.gpa.destroy(self);
    }
};

fn trimNewline(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r\n");
}

fn completeError(gpa: Allocator, server: *PipeServer, token: Token, id: u64, msg: []const u8) void {
    const line = legacy_json.serializeError(gpa, id, msg) catch return;
    defer gpa.free(line);
    _ = server.complete(token, trimNewline(line));
}

/// `PipeServer.Handler` of the `wmux-ipc-<pid>` pipe: every line is legacy.
pub fn handler(hub: *Server) PipeServer.Handler {
    return .{ .ctx = hub, .dispatch = legacyPipeDispatch };
}

fn legacyPipeDispatch(ctx: ?*anyopaque, conn: *Connection, req: *PipeServer.Request) void {
    const hub: *Server = @ptrCast(@alignCast(ctx.?));
    hub.dispatchLine(conn, req, req.line);
}

/// The legacy pipe name `\\.\pipe\wmux-ipc-<pid>` of this process (heap).
pub fn legacyPipeName(gpa: Allocator) Allocator.Error![]u8 {
    return proto.pipe_name.legacyName(gpa, std.os.windows.GetCurrentProcessId());
}

/// Starts the `wmux-ipc-<pid>` server for `hub`. Legacy framing: 1 MiB
/// lines, legacy-shaped transport replies.
pub fn startPipe(hub: *Server) !void {
    const name = try legacyPipeName(hub.gpa);
    defer hub.gpa.free(name);
    hub.pipe = try PipeServer.start(hub.gpa, .{
        .name = name,
        .first_instance = true,
        .max_line_bytes = legacy_json.max_line_bytes,
        .default_deadline_ms = deadline.legacy_deadline_ms,
        .legacy_replies = true,
    }, handler(hub));
}

/// Stops and frees the legacy pipe server (joins its threads).
pub fn stopPipe(hub: *Server) void {
    const p = hub.pipe orelse return;
    p.stop();
    hub.forgetServer(p);
    hub.pipe = null;
    p.deinit();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: rpc: legacy hub routes a reply by token once and keeps the legacy shapes" {
    var ui: lanes.UiLane = .{};
    var hub = Server.init(testing.allocator, undefined, &ui, false);
    defer hub.deinit();

    var cap: Captured = .none;
    const t = try hub.register(.{ .capture = &cap });
    try hub.sendOk(t, "{\"x\":1}");
    defer cap.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"x\":1}", cap.ok);
    // A second reply for the same token is not delivered.
    try testing.expectError(error.NotConnected, hub.sendError(t, "late"));
    // Unknown tokens are dropped.
    try testing.expectError(error.NotConnected, hub.sendOk(9999, null));

    var cap2: Captured = .none;
    const t2 = try hub.register(.{ .capture = &cap2 });
    try testing.expect(t2 != t);
    try hub.sendError(t2, "UnknownWorkspace");
    defer cap2.deinit(testing.allocator);
    try testing.expectEqualStrings("UnknownWorkspace", cap2.err);

    var cap3: Captured = .none;
    const t3 = try hub.register(.{ .capture = &cap3 });
    hub.cancel(t3);
    try testing.expectError(error.NotConnected, hub.sendOk(t3, null));
    try testing.expect(cap3 == .none);
}

test "unit: rpc: legacy reply lines are byte-identical to the pre-W1-1a server" {
    const ok = try legacy_json.serializeOk(testing.allocator, 12, null);
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("{\"id\":12,\"ok\":true,\"data\":null}", trimNewline(ok));
    const too_long = try Connection.legacyLineAlloc(testing.allocator, 0, Connection.legacy_too_long_message);
    defer testing.allocator.free(too_long);
    try testing.expectEqualStrings("{\"id\":0,\"ok\":false,\"error\":\"request exceeds maximum length\"}", too_long);
}
