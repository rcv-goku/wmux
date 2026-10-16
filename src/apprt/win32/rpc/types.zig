//! RPC types [frozen] (ARCHITECTURE.md ADR-3.6, written in W0-A3; W1-1
//! owns the bodies). A feature registers v2 methods, legacy wmux-v1 JSON
//! commands and cmux text-v1 verbs by declaring tables of these types in
//! its `features/<id>/mod.zig`:
//!
//!     pub const rpc_methods = @import("rpc.zig").methods;          // []const Method
//!     pub const legacy_commands = @import("legacy.zig").commands;  // []const LegacyCommand
//!     pub const text_verbs = @import("text_verbs.zig").verbs;      // []const TextVerb
//!
//! rpc/registry.zig aggregates them at comptime. Names, codes and
//! messages are cmux's (Appendix B); wmux-only methods are
//! `wmux.<domain>.<verb>` (G2).
//!
//! Until the v2 server exists (W1-1a) a `Ctx` records its single reply in
//! `reply` (G5: exactly one `ok`, `okRaw`, `fail` or `deferReply`); the
//! dispatcher then encodes it into the cmux envelope. The resolve helpers
//! resolve explicit selectors through the model's handle registry; W1-1
//! adds the caller context and active-window fallback of ADR-2.6
//! (`rpc/router.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");

const App = @import("../App.zig");
const Pane = @import("../model/Pane.zig");
const Tab = @import("../model/Tab.zig");
const Window = @import("../ui/Window.zig");
const Workspace = @import("../model/Workspace.zig");
const legacy_json = @import("compat/legacy_json.zig");
const model_registry = @import("../model/registry.zig");

pub const ErrorCode = proto.errors.Code;
pub const Selectors = proto.selectors.Selectors;
pub const Caller = proto.selectors.Caller;
pub const HandleText = proto.handles.HandleText;
pub const Uuid = proto.uuid.Uuid;

/// Which thread runs a method (ADR-3.2): the connection thread (no model
/// access), the worker pool (files and processes, no model) or the UI
/// thread (through app.tasks).
pub const Lane = enum { pipe, worker, ui };

/// What a method may do; `readOnly` access mode admits only `.read`
/// (ADR-3.8).
pub const Access = enum { read, mutate, focus, input, exec, admin };

/// Handlers return this after `ctx.fail(...)`. Any other Zig error that
/// escapes a handler is mapped by `proto.errors.fromZig` (ADR-3.5).
pub const Error = error{RpcFailed};

/// One v2 method (ADR-3.6).
pub const Method = struct {
    /// cmux name (Appendix B.1), or `wmux.<domain>.<verb>` (B.3).
    name: [:0]const u8,
    handler: *const fn (ctx: *Ctx) Error!void,
    lane: Lane = .ui,
    access: Access = .mutate,
    /// Shares the per-connection polling token bucket (ADR-3.3).
    polling: bool = false,
    /// May change in-app selection (only cmux's allowlist, ADR-3.11).
    focus_intent: bool = false,
    /// 0 = streaming / long-poll.
    deadline_ms: u32 = 10_000,
    /// Allowed over the remote relay (ADR-13); default deny.
    relay: bool = false,
    /// Omitted from `system.capabilities`.
    hidden: bool = false,
    /// `wmux.debug.*`: Debug builds or WMUX_TEST_MODE only.
    test_only: bool = false,
};

/// Where a request came from (ADR-3.6).
pub const Origin = union(enum) {
    /// A pipe client.
    socket: struct { conn: u64, pid: u32 },
    /// The app itself.
    in_process: InProcess,
    /// The remote relay, on behalf of a remote workspace (ADR-13).
    relay: struct { workspace: Uuid },

    pub const InProcess = enum { web_panel, palette, automation, @"test" };
};

/// A reply owed later by a `deferReply` handler (ADR-3.2). A completion
/// whose connection is gone, whose generation changed or whose request
/// expired is dropped.
pub const Deferred = struct {
    conn_id: u64,
    generation: u64,
    request_seq: u64,
};

/// The reply a handler produced. Strings live in the request arena.
pub const Reply = union(enum) {
    /// No reply yet (a handler that returns without replying is a bug).
    none,
    /// `{"ok":true,"result":<json>}`.
    ok: []const u8,
    /// `{"ok":false,"error":{code,message,data?}}`; `data` is JSON or null.
    err: struct { code: ErrorCode, message: []const u8, data: ?[]const u8 },
    /// Completed later through `Deferred`.
    deferred,
};

/// One request being handled (ADR-3.6).
pub const Ctx = struct {
    app: *App,
    /// Request arena: everything a handler allocates for its reply.
    arena: Allocator,
    /// The request id (string, number or null), echoed in the reply.
    id: std.json.Value,
    method: *const Method,
    /// The request's `params` object (non-object params arrive as `{}`).
    /// ADR-3.6 names both this field and the `params(T)` method `params`,
    /// which Zig cannot express; the method keeps the name.
    raw_params: std.json.ObjectMap,
    caller: ?Caller = null,
    origin: Origin,
    /// Connection identity for `deferReply` (filled by the server).
    deferred_id: Deferred = .{ .conn_id = 0, .generation = 0, .request_seq = 0 },
    reply: Reply = .none,

    /// The value of `key`, parsed as `T`; null when absent or JSON null. A
    /// value of the wrong type fails with `invalid_params` (never
    /// "absent").
    pub fn param(self: *Ctx, comptime T: type, key: []const u8) Error!?T {
        const v = self.raw_params.get(key) orelse return null;
        if (v == .null) return null;
        return std.json.parseFromValueLeaky(T, self.arena, v, .{}) catch {
            const message = std.fmt.allocPrint(self.arena, "Invalid {s}", .{key}) catch "Invalid parameters";
            return self.fail(.invalid_params, message, .{ .param = key });
        };
    }

    /// All params parsed as `T` (unknown keys ignored), after rejecting
    /// non-canonical selector spellings with cmux's
    /// `Unsupported parameter '<x>'; use '<canonical>'`.
    pub fn params(self: *Ctx, comptime T: type) Error!T {
        if (proto.selectors.findNonCanonical(&self.raw_params)) |u| {
            const message = proto.selectors.unsupportedMessage(self.arena, u) catch "Invalid parameters";
            return self.fail(.invalid_params, message, .{ .param = u.given });
        }
        return std.json.parseFromValueLeaky(
            T,
            self.arena,
            .{ .object = self.raw_params },
            .{ .ignore_unknown_fields = true },
        ) catch self.fail(.invalid_params, ErrorCode.invalid_params.defaultMessage(), null);
    }

    /// The window an explicit selector names (window_id, or the window of
    /// the workspace/pane/surface selected). Fails closed with `not_found`.
    pub fn resolveWindow(self: *Ctx, sel: Selectors) Error!*Window {
        const ws = self.selectedWorkspace(sel) catch |err| return err;
        if (ws) |w| return w.window;
        if (sel.window) |h| {
            if (model_registry.resolveWindow(self.app, h)) |w| return w;
            return self.notFound(.window, "window_id");
        }
        return self.noSelector();
    }

    /// The workspace an explicit selector names (workspace_id, or the
    /// workspace of the pane/surface selected; an index counts in the
    /// selected window).
    pub fn resolveWorkspace(self: *Ctx, sel: Selectors) Error!*Workspace {
        if (try self.selectedWorkspace(sel)) |ws| return ws;
        return self.noSelector();
    }

    /// The pane an explicit selector names (pane_id, or the pane of the
    /// surface selected; an index counts in the selected workspace).
    pub fn resolvePane(self: *Ctx, sel: Selectors) Error!*Pane {
        if (sel.surface) |_| {
            const tab = try self.resolveTab(sel);
            return tab.pane orelse self.notFound(.surface, "surface_id");
        }
        const h = sel.pane orelse return self.noSelector();
        const ws: ?*Workspace = if (sel.workspace != null or sel.window != null) try self.resolveWorkspace(sel) else null;
        if (model_registry.resolvePane(self.app, ws, h)) |p| return p;
        return self.notFound(.pane, "pane_id");
    }

    /// The surface (tab) an explicit selector names (surface_id; an index
    /// counts in the selected pane, else the selected workspace).
    pub fn resolveTab(self: *Ctx, sel: Selectors) Error!*Tab {
        const h = sel.surface orelse return self.noSelector();
        var scope: model_registry.SurfaceScope = .none;
        if (sel.pane != null) {
            scope = .{ .pane = try self.resolvePane(.{ .window = sel.window, .workspace = sel.workspace, .pane = sel.pane }) };
        } else if (sel.workspace != null or sel.window != null) {
            scope = .{ .workspace = try self.resolveWorkspace(.{ .window = sel.window, .workspace = sel.workspace }) };
        }
        if (model_registry.resolveSurface(self.app, scope, h)) |t| return t;
        return self.notFound(.surface, "surface_id");
    }

    /// Reply `{"ok":true,"result":<value>}`.
    pub fn ok(self: *Ctx, value: anytype) void {
        std.debug.assert(self.reply == .none);
        var aw: std.Io.Writer.Allocating = .init(self.arena);
        std.json.Stringify.value(value, .{}, &aw.writer) catch {
            self.reply = .{ .err = .{ .code = .encode_error, .message = ErrorCode.encode_error.defaultMessage(), .data = null } };
            return;
        };
        self.reply = .{ .ok = aw.written() };
    }

    /// Reply with an already encoded JSON result.
    pub fn okRaw(self: *Ctx, json: []const u8) void {
        std.debug.assert(self.reply == .none);
        self.reply = .{ .ok = json };
    }

    /// Reply with an error and return `error.RpcFailed` for the handler to
    /// propagate. `data` is any JSON-encodable value, or null.
    pub fn fail(self: *Ctx, code: ErrorCode, msg: []const u8, data: anytype) Error {
        std.debug.assert(self.reply == .none);
        const encoded: ?[]const u8 = if (@TypeOf(data) == @TypeOf(null)) null else blk: {
            var aw: std.Io.Writer.Allocating = .init(self.arena);
            std.json.Stringify.value(data, .{}, &aw.writer) catch break :blk null;
            break :blk aw.written();
        };
        self.reply = .{ .err = .{ .code = code, .message = msg, .data = encoded } };
        return error.RpcFailed;
    }

    /// Promise exactly one later completion through the returned token.
    pub fn deferReply(self: *Ctx) Deferred {
        std.debug.assert(self.reply == .none);
        self.reply = .deferred;
        return self.deferred_id;
    }

    /// The workspace selected by workspace_id, or by pane_id/surface_id
    /// (their workspace); null when none of them is present.
    fn selectedWorkspace(self: *Ctx, sel: Selectors) Error!?*Workspace {
        if (sel.workspace) |h| {
            const window: ?*Window = if (sel.window) |wh|
                model_registry.resolveWindow(self.app, wh) orelse return self.notFound(.window, "window_id")
            else
                null;
            if (model_registry.resolveWorkspace(self.app, window, h)) |ws| return ws;
            return self.notFound(.workspace, "workspace_id");
        }
        if (sel.surface) |_| {
            const tab = try self.resolveTab(.{ .surface = sel.surface });
            const pane = tab.pane orelse return self.notFound(.surface, "surface_id");
            return pane.workspace orelse self.notFound(.surface, "surface_id");
        }
        if (sel.pane) |h| {
            const pane = model_registry.resolvePane(self.app, null, h) orelse return self.notFound(.pane, "pane_id");
            return pane.workspace orelse self.notFound(.pane, "pane_id");
        }
        return null;
    }

    fn notFound(self: *Ctx, kind: proto.handles.Kind, key: []const u8) Error {
        return self.fail(.not_found, proto.errors.notFoundMessage(kind), .{ .selector = key });
    }

    fn noSelector(self: *Ctx) Error {
        return self.fail(.not_found, proto.errors.msg.no_focused_surface, null);
    }
};

/// The request type of the legacy wmux-v1 JSON protocol.
pub const LegacyRequest = legacy_json.Request;

/// One legacy wmux-v1 JSON command (ADR-3.6, ADR-3.7), declared in the
/// owning feature's `legacy.zig` (Appendix B.4). The legacy protocol is
/// served until wmux 2.0; G8 forbids new commands.
pub const LegacyCommand = struct {
    /// Wire name: a `legacy_json.Command` tag name.
    cmd: []const u8,

    /// Runs on the UI thread. Replies exactly once through
    /// `app.ipc_server` (synchronously, or later from an async completion)
    /// or returns an error, which the dispatcher names to the client via
    /// `@errorName`.
    handler: *const fn (*App, *LegacyRequest) anyerror!void,

    /// Whether the command only reads state (never mutates the model,
    /// spawns a process, or sends input). Under `socket-control =
    /// read-only` only these are honored; everything else is refused
    /// before dispatch. The browser CDP verbs (snapshot/eval) read a page
    /// but eval can run arbitrary JS, so only snapshot is read-only;
    /// navigate/click/fill/open mutate.
    read_only: bool = false,

    /// Optional pipe-thread stage, run before the request is handed to
    /// the UI thread (only `workspace-new --worktree`, which shells out to
    /// git off the message loop). Returns false after it has answered the
    /// client itself; the request is then dropped.
    prepare: ?*const fn (*App, *LegacyRequest) bool = null,
};

/// One cmux text-v1 verb (ADR-3.7): `<verb> <args>` parsed into the params
/// of a v2/`wmux.*` method, whose result is formatted back as text.
pub const TextVerb = struct {
    /// Verb name, matched case-insensitively.
    name: []const u8,
    /// The method the verb runs.
    method: []const u8,
    parse: *const fn (args: []const u8, arena: Allocator) anyerror!std.json.Value,
    format: *const fn (result: std.json.Value, w: *std.Io.Writer) anyerror!void,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testHandler(ctx: *Ctx) Error!void {
    _ = ctx;
}

const test_method: Method = .{ .name = "system.ping", .handler = testHandler };

/// A Ctx that never touches the app (the reply helpers and param parsing
/// only use the arena and params).
fn testCtx(arena: Allocator, params_map: std.json.ObjectMap) Ctx {
    return .{
        .app = undefined,
        .arena = arena,
        .id = .{ .integer = 1 },
        .method = &test_method,
        .raw_params = params_map,
        .origin = .{ .in_process = .@"test" },
    };
}

fn parseParams(arena: Allocator, json: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    return v.object;
}

test "unit: rpc: method defaults follow ADR-3.6" {
    try testing.expectEqual(Lane.ui, test_method.lane);
    try testing.expectEqual(Access.mutate, test_method.access);
    try testing.expectEqual(@as(u32, 10_000), test_method.deadline_ms);
    try testing.expect(!test_method.polling and !test_method.focus_intent and !test_method.relay);
    try testing.expect(!test_method.hidden and !test_method.test_only);
}

test "unit: rpc: ctx ok encodes the result once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, try parseParams(arena, "{}"));
    ctx.ok(.{ .pong = true, .n = 3 });
    try testing.expectEqualStrings("{\"pong\":true,\"n\":3}", ctx.reply.ok);
}

test "unit: rpc: ctx fail records code, message and data" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, try parseParams(arena, "{}"));
    try testing.expectError(error.RpcFailed, @as(Error!void, ctx.fail(.not_found, "Workspace not found", .{ .selector = "workspace_id" })));
    try testing.expectEqual(ErrorCode.not_found, ctx.reply.err.code);
    try testing.expectEqualStrings("Workspace not found", ctx.reply.err.message);
    try testing.expectEqualStrings("{\"selector\":\"workspace_id\"}", ctx.reply.err.data.?);

    var ctx2 = testCtx(arena, try parseParams(arena, "{}"));
    try testing.expectEqual(error.RpcFailed, ctx2.fail(.busy, "Busy", null));
    try testing.expectEqual(@as(?[]const u8, null), ctx2.reply.err.data);
}

test "unit: rpc: ctx param reads present values and rejects wrong types" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, try parseParams(arena, "{\"title\":\"api\",\"focus\":false,\"n\":null}"));
    try testing.expectEqualStrings("api", (try ctx.param([]const u8, "title")).?);
    try testing.expectEqual(@as(?bool, false), try ctx.param(bool, "focus"));
    try testing.expectEqual(@as(?bool, null), try ctx.param(bool, "missing"));
    try testing.expectEqual(@as(?u32, null), try ctx.param(u32, "n"));
    try testing.expectError(error.RpcFailed, ctx.param(u32, "title"));
    try testing.expectEqual(ErrorCode.invalid_params, ctx.reply.err.code);
}

test "unit: rpc: ctx params rejects non-canonical selector keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, try parseParams(arena, "{\"workspaceId\":\"workspace:1\"}"));
    try testing.expectError(error.RpcFailed, ctx.params(struct { title: ?[]const u8 = null }));
    try testing.expectEqualStrings("Unsupported parameter 'workspaceId'; use 'workspace_id'", ctx.reply.err.message);

    var ctx2 = testCtx(arena, try parseParams(arena, "{\"title\":\"x\",\"extra\":1}"));
    const p = try ctx2.params(struct { title: ?[]const u8 = null });
    try testing.expectEqualStrings("x", p.title.?);
}

test "unit: rpc: ctx deferReply hands out the connection token" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, try parseParams(arena, "{}"));
    ctx.deferred_id = .{ .conn_id = 4, .generation = 2, .request_seq = 9 };
    const d = ctx.deferReply();
    try testing.expectEqual(@as(u64, 4), d.conn_id);
    try testing.expectEqual(@as(u64, 9), d.request_seq);
    try testing.expect(ctx.reply == .deferred);
}
