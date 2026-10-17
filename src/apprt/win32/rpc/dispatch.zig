//! The v2 dispatcher of the control pipe (ARCHITECTURE.md ADR-3.2, ADR-3.4,
//! ADR-3.5, ADR-3.6; W1-1a). It is the `PipeServer.Handler` of the
//! control pipe and runs on connection threads:
//!
//! 1. strips an optional `_cmux_capability_v1 <token> ` prefix (verified
//!    by W1-1b's `cmuxOnly` mode; ignored here);
//! 2. sniffs the line: v2 JSON goes on below; legacy wmux JSON goes to the
//!    legacy adapter (server/legacy_pipe.zig). Until the text-v1 framework
//!    lands (W1-1b) a line that is neither JSON form is answered by the
//!    legacy parser too (legacy `parse_error`/`invalid_request` replies);
//! 3. checks the envelope (UTF-8, JSON, object, method), the method
//!    (registry; `wmux.debug.*` and other `test_only` methods exist only in
//!    test mode), the canonical selector keys and `params.caller`, the
//!    read-only mode and the polling rate limit, answering `invalid_utf8`,
//!    `parse_error`, `invalid_request`, `method_not_found`,
//!    `invalid_params`, `forbidden` or `rate_limited` at once;
//! 4. routes by lane: `pipe` inline, `worker` to the pool, `ui` through
//!    the UI lane (`app.tasks`, modal hold). Hopping lanes `begin` the
//!    request first and skip it when it expired meanwhile (the transport
//!    already answered `timeout {stage, deadline_ms, retryable:true}`);
//! 5. encodes the handler's single `Ctx` reply (rpc/reply.zig) and hands
//!    it to the transport, which drops it when the request expired, its
//!    client left or the connection generation changed. `deferReply`
//!    handlers complete later through `reply.complete*`.
//!
//! The deadline is the method's `deadline_ms` (10 s by default; 0 = none),
//! enforced by the connection thread with the queued→expired CAS.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const envelope = proto.envelope;
const errors = proto.errors;

const App = @import("../App.zig");
const PipeServer = @import("server/PipeServer.zig");
const deadline = @import("logic/deadline.zig");
const lanes = @import("lanes.zig");
const legacy_json = @import("compat/legacy_json.zig");
const legacy_pipe = @import("server/legacy_pipe.zig");
const ratelimit = @import("logic/ratelimit.zig");
const registry = @import("registry.zig");
const reply = @import("reply.zig");
const router = @import("router.zig");
const types = @import("types.zig");

const Connection = PipeServer.Connection;
const Token = PipeServer.Token;
const Method = types.Method;
const Ctx = types.Ctx;

const log = std.log.scoped(.rpc);

/// The error message of a method refused by the read-only mode (the
/// `socket-control = read-only` Ghostty key until W1-1b's access modes).
pub const read_only_message = "socket-control=read-only: method refused";

pub const Dispatcher = struct {
    gpa: Allocator,
    app: *App,
    hub: *legacy_pipe.Server,
    ui: *lanes.UiLane,
    workers: *lanes.WorkerPool,
    /// `test_only` methods (`wmux.debug.*`) are served and listed
    /// (WMUX_TEST_MODE).
    test_methods: bool,
    /// Only `.read` methods run (`socket-control = read-only`).
    read_only: bool = false,

    pub fn handler(self: *Dispatcher) PipeServer.Handler {
        return .{ .ctx = self, .dispatch = dispatchFn };
    }

    /// The method `name` names for this instance: the registry's (minus
    /// `test_only` methods outside test mode), else a transitional bridge.
    pub fn lookup(self: *const Dispatcher, name: []const u8) ?*const Method {
        if (registry.method(name)) |m| {
            if (m.test_only and !self.test_methods) return null;
            return m;
        }
        return bridgeFor(name);
    }
};

/// Whether `m` appears in `system.capabilities` (ADR-3.6): not hidden, and
/// `test_only` methods only in test mode.
pub fn listed(m: *const Method, test_methods: bool) bool {
    return !m.hidden and (!m.test_only or test_methods);
}

/// The sorted names of the listed methods of `methods`, in `arena`.
pub fn listedNames(arena: Allocator, methods: []const Method, test_methods: bool) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (methods) |*m| {
        if (listed(m, test_methods)) try names.append(arena, m.name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return names.items;
}

/// The listed method names of this instance (system.capabilities).
pub fn capabilityNames(arena: Allocator, test_methods: bool) Allocator.Error![]const []const u8 {
    return listedNames(arena, registry.all_methods, test_methods);
}

fn dispatchFn(ctx: ?*anyopaque, conn: *Connection, req: *PipeServer.Request) void {
    const d: *Dispatcher = @ptrCast(@alignCast(ctx.?));
    const cap = envelope.splitCapability(req.line) catch {
        return completeError(d.gpa, conn.server, req.token, .null, .invalid_request, "Malformed capability envelope", null);
    };
    switch (envelope.sniff(cap.payload)) {
        .v2 => dispatchV2(d, conn, req, cap.payload),
        // Text-v1 (`ping`, `auth`, ...) is W1-1b's framework; until then
        // the legacy parser answers non-JSON lines.
        .legacy_json, .text_v1 => d.hub.dispatchLine(conn, req, cap.payload),
    }
}

fn completeLine(server: *PipeServer, token: Token, line: []const u8) void {
    _ = server.complete(token, line);
}

fn completeError(gpa: Allocator, server: *PipeServer, token: Token, id: std.json.Value, code: errors.Code, message: []const u8, data_json: ?[]const u8) void {
    const line = reply.errorLineAlloc(gpa, id, code, message, data_json) catch return;
    defer gpa.free(line);
    completeLine(server, token, line);
}

/// One v2 request between the connection thread and its lane. Owns the
/// request arena (the parsed request, the Ctx and its reply live there).
const Call = struct {
    d: *Dispatcher,
    /// Kept here: a call destroyed after the control plane stopped (still
    /// queued in app.tasks) must not touch the dispatcher.
    gpa: Allocator,
    server: *PipeServer,
    token: Token,
    arena_state: std.heap.ArenaAllocator,
    ctx: Ctx = undefined,
    job: lanes.Job = .{ .run = jobRun, .destroy = jobDestroy },
    item: lanes.UiItem = .{ .run = uiRun, .destroy = uiDestroy, .read_only = false },

    fn create(d: *Dispatcher, server: *PipeServer, token: Token) Allocator.Error!*Call {
        const self = try d.gpa.create(Call);
        self.* = .{ .d = d, .gpa = d.gpa, .server = server, .token = token, .arena_state = .init(d.gpa) };
        return self;
    }

    fn destroy(self: *Call) void {
        const gpa = self.gpa;
        self.arena_state.deinit();
        gpa.destroy(self);
    }

    fn arena(self: *Call) Allocator {
        return self.arena_state.allocator();
    }

    /// Runs the handler and hands its reply to the transport.
    fn execute(self: *Call) void {
        const ctx = &self.ctx;
        ctx.method.handler(ctx) catch |err| switch (err) {
            // The reply was recorded by `ctx.fail`.
            error.RpcFailed => {},
        };
        if (ctx.reply == .deferred) return; // reply.complete* finishes it
        const line = reply.ctxLineAlloc(self.gpa, ctx.id, ctx.reply) catch return;
        defer self.gpa.free(line);
        completeLine(self.server, self.token, line);
    }

    /// Lanes that hop threads: skip a request that expired while queued.
    fn executeIfCurrent(self: *Call) void {
        if (!self.server.begin(self.token)) return;
        self.execute();
    }

    fn jobRun(job: *lanes.Job) void {
        const self: *Call = @fieldParentPtr("job", job);
        self.executeIfCurrent();
    }

    fn jobDestroy(job: *lanes.Job) void {
        const self: *Call = @fieldParentPtr("job", job);
        self.destroy();
    }

    fn uiRun(item: *lanes.UiItem, app: *App) void {
        _ = app;
        const self: *Call = @fieldParentPtr("item", item);
        self.executeIfCurrent();
    }

    fn uiDestroy(item: *lanes.UiItem) void {
        const self: *Call = @fieldParentPtr("item", item);
        self.destroy();
    }
};

fn dispatchV2(d: *Dispatcher, conn: *Connection, req: *PipeServer.Request, payload: []const u8) void {
    const server = conn.server;
    const gpa = d.gpa;
    const call = Call.create(d, server, req.token) catch {
        return completeError(gpa, server, req.token, .null, .internal_error, "Out of memory", null);
    };
    var handed_off = false;
    defer if (!handed_off) call.destroy();
    const arena = call.arena();

    // The line is valid only during this call; the arena copy outlives it.
    const text = arena.dupe(u8, payload) catch {
        return completeError(gpa, server, req.token, .null, .internal_error, "Out of memory", null);
    };
    const parsed = envelope.parseRequest(arena, text) catch {
        return completeError(gpa, server, req.token, .null, .internal_error, "Out of memory", null);
    };
    const request = switch (parsed) {
        .rejected => |r| {
            const line = envelope.encodeRejectionAlloc(gpa, r) catch return;
            defer gpa.free(line);
            return completeLine(server, req.token, line);
        },
        .request => |r| r,
    };
    const id = request.id;

    const m = d.lookup(request.method) orelse {
        return completeError(gpa, server, req.token, id, .method_not_found, errors.msg.unknown_method, null);
    };

    // A mistyped selector key must never fall back to the focused object
    // (ADR-2.6): rejected for every method.
    if (proto.selectors.findNonCanonical(&request.params)) |u| {
        const message = proto.selectors.unsupportedMessage(arena, u) catch errors.Code.invalid_params.defaultMessage();
        const data = std.json.Stringify.valueAlloc(arena, .{ .param = u.given }, .{}) catch null;
        return completeError(gpa, server, req.token, id, .invalid_params, message, data);
    }
    var failure: proto.selectors.Failure = undefined;
    const caller = proto.selectors.parseCaller(arena, &request.params, &failure) catch |err| switch (err) {
        error.OutOfMemory => return completeError(gpa, server, req.token, id, .internal_error, "Out of memory", null),
        error.Rejected => {
            const data = std.json.Stringify.valueAlloc(arena, .{ .selector = failure.key }, .{}) catch null;
            return completeError(gpa, server, req.token, id, failure.code, failure.message, data);
        },
    };

    if (d.read_only and m.access != .read) {
        return completeError(gpa, server, req.token, id, .forbidden, read_only_message, null);
    }
    if (m.polling) {
        if (conn.takePollingToken()) |retry_ms| {
            const line = ratelimit.rateLimitedLineAlloc(gpa, id, retry_ms) catch return;
            defer gpa.free(line);
            return completeLine(server, req.token, line);
        }
    }

    req.deadline_ms = m.deadline_ms;
    req.stage = deadline.stageOf(switch (m.lane) {
        .pipe => .pipe,
        .worker => .worker,
        .ui => .ui,
    });
    call.ctx = .{
        .app = d.app,
        .arena = arena,
        .id = id,
        .method = m,
        .raw_params = request.params,
        .caller = caller,
        .origin = .{ .socket = .{ .conn = conn.generation, .pid = conn.clientPid() } },
        .deferred_id = .{ .conn_id = req.token.conn_id, .generation = req.token.generation, .request_seq = req.token.request_seq },
    };

    switch (m.lane) {
        .pipe => {
            _ = server.begin(req.token);
            call.execute();
        },
        .worker => {
            if (d.workers.submit(&call.job)) {
                handed_off = true;
            } else {
                completeError(gpa, server, req.token, id, .unavailable, "Worker lane unavailable", null);
            }
        },
        .ui => {
            call.item.read_only = m.access == .read;
            handed_off = true;
            d.ui.post(&call.item);
        },
    }
}

// ---------------------------------------------------------------------------
// Transitional bridges
//
// Methods the e2e harness (test/e2e/WmuxTest.psm1) calls on every v2
// instance before their owners register them. A bridge is consulted only
// while the registry has no method of that name, so the owner's
// registration supersedes it without touching this file; it is hidden from
// system.capabilities. Delete a bridge once its owner merged.
// ---------------------------------------------------------------------------

/// `surface.read_text` until W2-3 registers it: the harness's
/// `Wait-WmuxScreen` polls it. Runs the legacy `read-screen` command: the
/// legacy keys (`workspace`, `pane`, `tab`, `lines`, `scrollback`) keep
/// their legacy meaning; a v2 surface selector is located first. Result
/// `{text}`.
const read_text_bridge: Method = .{
    .name = "surface.read_text",
    .handler = bridgeReadText,
    .lane = .ui,
    .access = .read,
    .polling = true,
    .hidden = true,
};

/// The names served by a bridge while unregistered (pure, for tests:
/// referencing a bridge `Method` from a test would pull its handler, and
/// through it the app registries, into the test binary).
pub const bridge_names = [_][]const u8{"surface.read_text"};

fn bridgeFor(name: []const u8) ?*const Method {
    if (std.mem.eql(u8, name, read_text_bridge.name)) return &read_text_bridge;
    return null;
}

fn bridgeReadText(ctx: *Ctx) types.Error!void {
    const app = ctx.app;
    const hub = app.ipc_server orelse return ctx.fail(.unavailable, "Control server stopped", null);
    const gpa = hub.gpa;
    const lreq = gpa.create(legacy_json.Request) catch return ctx.fail(.internal_error, "Out of memory", null);
    lreq.* = .{ .gpa = gpa, .arena = .init(gpa), .id = 0, .cmd = .@"read-screen", .args = .null };
    var owned = true;
    defer if (owned) lreq.destroy();
    const la = lreq.arena.allocator();
    var args = std.json.ObjectMap.init(la);
    const oom = error.OutOfMemory;
    for ([_][]const u8{ "lines", "scrollback", "workspace", "pane", "tab" }) |key| {
        if (ctx.raw_params.get(key)) |v| args.put(key, v) catch return ctx.fail(.internal_error, @errorName(oom), null);
    }
    const sel = try ctx.selectors();
    if (!sel.isEmpty() or ctx.caller != null) {
        // Locate the v2 target as legacy indexes of the legacy target window.
        const tab = try ctx.resolveTab(sel);
        const pane = tab.pane orelse return ctx.fail(.not_found, errors.msg.surface_not_found_for_id, null);
        const ws = pane.workspace orelse return ctx.fail(.not_found, errors.msg.surface_not_found_for_id, null);
        const target = @import("compat/legacy_targets.zig").ipcTargetWindow(app) orelse return ctx.fail(.not_found, "Window not found", null);
        if (ws.window != target) return ctx.fail(.not_supported, "surface.read_text: surface is not in the legacy target window", null);
        var pane_index: ?usize = null;
        var i: usize = 0;
        while (ws.paneAt(i)) |p| : (i += 1) if (p == pane) {
            pane_index = i;
            break;
        };
        const tab_index = pane.indexOf(tab) orelse return ctx.fail(.not_found, errors.msg.surface_not_found_for_id, null);
        args.put("workspace", .{ .integer = @intCast(target.workspaceIndex(ws)) }) catch return ctx.fail(.internal_error, @errorName(oom), null);
        if (pane_index) |pi| args.put("pane", .{ .integer = @intCast(pi) }) catch return ctx.fail(.internal_error, @errorName(oom), null);
        args.put("tab", .{ .integer = @intCast(tab_index) }) catch return ctx.fail(.internal_error, @errorName(oom), null);
    }
    lreq.args = .{ .object = args };
    owned = false;
    var cap = hub.runCaptured(lreq);
    defer cap.deinit(gpa);
    switch (cap) {
        .none => return ctx.fail(.internal_error, reply.no_reply_message, null),
        .err => |name| {
            const m = errors.fromName(name);
            const message = ctx.arena.dupe(u8, name) catch name;
            return ctx.fail(m.code, message, null);
        },
        .ok => |data| {
            const json = std.fmt.allocPrint(ctx.arena, "{{\"text\":{s}}}", .{data}) catch return ctx.fail(.internal_error, @errorName(oom), null);
            ctx.okRaw(json);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testHandler(ctx: *Ctx) types.Error!void {
    _ = ctx;
}

test "unit: rpc: capabilities list sorted methods, wmux.debug.* only in test mode" {
    const methods = [_]Method{
        .{ .name = "system.ping", .handler = testHandler, .lane = .pipe, .access = .read },
        .{ .name = "wmux.debug.ready", .handler = testHandler, .test_only = true },
        .{ .name = "app.hidden", .handler = testHandler, .hidden = true },
        .{ .name = "system.capabilities", .handler = testHandler, .lane = .pipe, .access = .read },
        .{ .name = "surface.list", .handler = testHandler },
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plain = try listedNames(arena, &methods, false);
    try testing.expectEqual(@as(usize, 3), plain.len);
    try testing.expectEqualStrings("surface.list", plain[0]);
    try testing.expectEqualStrings("system.capabilities", plain[1]);
    try testing.expectEqualStrings("system.ping", plain[2]);
    const test_mode = try listedNames(arena, &methods, true);
    try testing.expectEqual(@as(usize, 4), test_mode.len);
    try testing.expectEqualStrings("wmux.debug.ready", test_mode[3]);
}

test "unit: rpc: transitional bridges are hidden and only stand in for unregistered methods" {
    // A hidden method is never listed, even in test mode.
    const hidden: Method = .{ .name = "surface.read_text", .handler = testHandler, .access = .read, .hidden = true };
    try testing.expect(!listed(&hidden, true));
    try testing.expectEqual(@as(usize, 1), bridge_names.len);
    try testing.expectEqualStrings("surface.read_text", bridge_names[0]);
}
