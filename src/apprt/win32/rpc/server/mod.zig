//! The control plane facade (ARCHITECTURE.md ADR-3.1, ADR-3.2; W1-1a):
//! App.init calls `start` once msg_hwnd exists and App.terminate calls
//! `stop` before msg_hwnd is destroyed.
//!
//! `start`:
//! 1. computes the names: channel (compiled default, `WMUX_CHANNEL`,
//!    `WMUX_TAG`), sidhash8 of the user SID, logon session →
//!    `\\.\pipe\wmux-<channel>-<sidhash8>-s<session>` and `-launch`;
//! 2. single instance (app/single_instance.zig): claims the launch pipe, or
//!    hands the launch to the running instance and exits;
//! 3. sets `app.ipc_server` (the legacy reply hub) and starts the v2
//!    control pipe (rpc/dispatch.zig; 64 live + 64 pending connections,
//!    16 MiB lines, the worker pool and the UI lane). When the name is
//!    taken (FILE_FLAG_FIRST_PIPE_INSTANCE fails: a squatter, or an
//!    instance we could not hand off to) it serves `<name>-alt-<8hex>`;
//! 4. starts the legacy `\\.\pipe\wmux-ipc-<pid>` pipe (legacy JSON only,
//!    one release), after the control pipe so a client that finds it also
//!    finds the control pipe;
//! 5. writes `STATE\run\instance.json` (server/marker.zig).
//!
//! `socket-control = off` (the Ghostty key until W1-1b's access modes)
//! starts neither the control nor the legacy pipe; the launch pipe stays.
//! `read-only` refuses methods that are not `.read` and legacy commands
//! that are not read-only, before any side effect. Every failure only
//! disables the pipe concerned (logged); the app runs without it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const build_options = @import("wmux_build_options");

const App = @import("../../App.zig");
const PipeServer = @import("PipeServer.zig");
const dialogs = @import("../../app/dialogs.zig");
const dispatch = @import("../dispatch.zig");
const framer = @import("../logic/framer.zig");
const lanes = @import("../lanes.zig");
const launch_pipe = @import("launch_pipe.zig");
const legacy_pipe = @import("legacy_pipe.zig");
const marker = @import("marker.zig");
const reply = @import("../reply.zig");
const single_instance = @import("../../app/single_instance.zig");

const w32c = PipeServer.Connection.w32;
const log = std.log.scoped(.rpc_server);

/// Everything the control plane owns while the app runs.
pub const Plane = struct {
    gpa: Allocator,
    app: *App,
    /// Sanitized channel (owned).
    channel: []u8,
    /// Full control pipe path (owned), also when the control pipe is off.
    control_name: []u8,
    /// Full launch pipe path (owned).
    launch_name: []u8,
    /// The control pipe serves (`controlPipeName` is non-null).
    control_running: bool = false,
    /// The names carry the `-alt-<8hex>` squatting suffix.
    alt: bool = false,
    /// The access mode `system.capabilities` reports (W1-1b replaces this
    /// with `automation.socketControlMode`).
    access_mode: []const u8 = "automation",
    test_methods: bool,
    boot_id: [proto.uuid.Uuid.text_len]u8,

    workers: lanes.WorkerPool = .{},
    ui: lanes.UiLane = .{},
    hub: legacy_pipe.Server,
    dispatcher: dispatch.Dispatcher,
    control: ?*PipeServer = null,
    launch: ?*launch_pipe.LaunchPipe = null,
    marker_path: ?[]u8 = null,

    fn onModalIdle(ctx: *anyopaque) void {
        const self: *Plane = @ptrCast(@alignCast(ctx));
        self.ui.releaseHeld();
    }
};

/// The running control plane (one App per process). Set by `start` on the
/// UI thread before any server thread exists; cleared by `stop` after
/// every server thread joined.
var plane: ?*Plane = null;

/// What `system.capabilities` and the debug hooks report.
pub const Info = struct {
    channel: []const u8,
    socket_path: ?[]const u8,
    launch_pipe: []const u8,
    access_mode: []const u8,
    test_methods: bool,
    version: []const u8,
};

/// The running control plane's description, or null when it is stopped.
pub fn info() ?Info {
    const p = plane orelse return null;
    return .{
        .channel = p.channel,
        .socket_path = if (p.control_running) p.control_name else null,
        .launch_pipe = p.launch_name,
        .access_mode = p.access_mode,
        .test_methods = p.test_methods,
        .version = build_options.version,
    };
}

/// The current user's SID as a string (heap).
fn userSidAlloc(gpa: Allocator) ![]u8 {
    var sid: PipeServer.UserSid = .{};
    try sid.ofProcess(std.os.windows.GetCurrentProcess());
    return sid.toStringAlloc(gpa);
}

fn sessionId() u32 {
    var s: u32 = 0;
    if (w32c.ProcessIdToSessionId(std.os.windows.GetCurrentProcessId(), &s) == 0) return 0;
    return s;
}

fn resolveChannel(gpa: Allocator) ![]u8 {
    var map = try std.process.getEnvMap(gpa);
    defer map.deinit();
    return proto.channel.resolveFromEnv(gpa, build_options.channel, proto.env_names.Env.fromEnvMap(&map));
}

/// Start serving. A failure only disables the pipe concerned (logged).
/// May exit the process (0) when another instance of this channel takes
/// the launch over (single instance, ADR-3.1).
pub fn start(app: *App) void {
    startPlane(app) catch |err| log.err("control plane not started: {}", .{err});
}

fn startPlane(app: *App) !void {
    std.debug.assert(plane == null);
    const gpa = app.core_app.alloc;

    const channel = try resolveChannel(gpa);
    errdefer gpa.free(channel);
    const sid = try userSidAlloc(gpa);
    defer gpa.free(sid);
    const hash = proto.pipe_name.sidHash8(sid);
    var control_name = try proto.pipe_name.controlName(gpa, channel, &hash, sessionId());
    errdefer gpa.free(control_name);
    var launch_name = try proto.pipe_name.launchName(gpa, control_name);
    errdefer gpa.free(launch_name);

    const p = try gpa.create(Plane);
    errdefer gpa.destroy(p);
    p.* = .{
        .gpa = gpa,
        .app = app,
        .channel = channel,
        .control_name = control_name,
        .launch_name = launch_name,
        .test_methods = app.runtime_env.test_mode,
        .boot_id = proto.uuid.Uuid.v4().toText(),
        .hub = undefined,
        .dispatcher = undefined,
    };

    // 2. Single instance (may exit the process).
    switch (single_instance.claimOrHandoff(app, gpa, launch_name)) {
        .serving => |lp| p.launch = lp,
        .standalone => {
            try useAltNames(p);
            control_name = p.control_name;
            launch_name = p.launch_name;
            p.launch = switch (launch_pipe.LaunchPipe.claim(gpa, p.launch_name, launchRefused, app, .{}) catch |err| blk: {
                log.warn("alt launch pipe unavailable: {}", .{err});
                break :blk .exists;
            }) {
                .serving => |lp| lp,
                .exists => null,
            };
        },
    }

    const mode = app.config.@"socket-control";
    const read_only = mode == .@"read-only";
    p.access_mode = if (read_only) "readOnly" else "automation";
    p.workers.start(gpa);
    p.ui.init(app, gpa);
    p.hub = legacy_pipe.Server.init(gpa, app, &p.ui, read_only);
    p.dispatcher = .{
        .gpa = gpa,
        .app = app,
        .hub = &p.hub,
        .ui = &p.ui,
        .workers = &p.workers,
        .test_methods = p.test_methods,
        .read_only = read_only,
    };
    app.modal.idle_hook = .{ .ctx = p, .f = Plane.onModalIdle };
    plane = p;

    if (mode == .off) {
        log.info("socket-control=off: control and legacy pipes not started (launch pipe on)", .{});
        return;
    }

    // Handlers reply through app.ipc_server: set before any pipe serves.
    app.ipc_server = &p.hub;

    // 3. The v2 control pipe, first: a client that finds the legacy pipe
    // also finds the control pipe (the e2e harness prefers v2 that way).
    p.control = startControl(p) catch |err| blk: {
        log.warn("control pipe {s} not started: {}", .{ p.control_name, err });
        break :blk null;
    };
    if (p.control) |c| {
        p.control_running = true;
        reply.bind(gpa, c);
        log.info("control pipe {s} (protocol 2)", .{p.control_name});
    }

    // 4. The legacy pipe.
    legacy_pipe.startPipe(&p.hub) catch |err| log.warn("legacy pipe wmux-ipc-{d} not started: {}", .{ std.os.windows.GetCurrentProcessId(), err });

    // 5. The marker.
    if (p.control_running) writeMarker(p);
}

/// Switches to the `-alt-<8hex>` names (ADR-3.1 squatting rule).
fn useAltNames(p: *Plane) !void {
    if (p.alt) return;
    var random: [4]u8 = undefined;
    std.crypto.random.bytes(&random);
    const base = p.control_name;
    const alt = try proto.pipe_name.altName(p.gpa, base, random);
    errdefer p.gpa.free(alt);
    const launch = try proto.pipe_name.launchName(p.gpa, alt);
    p.gpa.free(p.launch_name);
    p.gpa.free(base);
    p.control_name = alt;
    p.launch_name = launch;
    p.alt = true;
}

fn startControl(p: *Plane) !*PipeServer {
    const config = struct {
        fn of(name: []const u8) PipeServer.Config {
            return .{
                .name = name,
                .first_instance = true,
                .max_line_bytes = framer.authorized_max_line,
            };
        }
    };
    return PipeServer.start(p.gpa, config.of(p.control_name), p.dispatcher.handler()) catch |err| switch (err) {
        error.PipeNameInUse => {
            log.warn("control pipe {s} is taken{s}; using an -alt- name", .{ p.control_name, if (ownedBySomeoneElse(p.gpa, p.control_name)) " by another user" else "" });
            if (p.alt) return err;
            try useAltNames(p);
            // Keep the launch pipe at its claimed name; the marker records both.
            return PipeServer.start(p.gpa, config.of(p.control_name), p.dispatcher.handler());
        },
        else => err,
    };
}

/// Whether the server of pipe `name` runs as another user (a squatter).
fn ownedBySomeoneElse(gpa: Allocator, name: []const u8) bool {
    var client = launch_pipe.PipeClient.connect(gpa, name, 200) catch return false;
    defer client.close();
    return !client.serverIsSameUser();
}

/// The alt launch pipe of a standalone instance answers `accepted:false`
/// (no handoff into an instance that could not claim its channel).
fn launchRefused(ctx: ?*anyopaque, req: *const launch_pipe.LaunchRequest, client_pid: u32) bool {
    _ = ctx;
    _ = req;
    _ = client_pid;
    return false;
}

fn writeMarker(p: *Plane) void {
    const gpa = p.gpa;
    const path = (marker.pathAlloc(gpa, p.app.runtime_env.state_dir, p.channel) catch null) orelse {
        log.warn("instance marker not written: no STATE directory", .{});
        return;
    };
    const exe = std.fs.selfExePathAlloc(gpa) catch null;
    defer if (exe) |e| gpa.free(e);
    var ts: [20]u8 = undefined;
    marker.write(gpa, path, .{
        .pipe = p.control_name,
        .launch_pipe = if (p.launch != null) p.launch_name else null,
        .pid = std.os.windows.GetCurrentProcessId(),
        .exe = exe orelse "",
        .version = build_options.version,
        .channel = p.channel,
        .boot_id = &p.boot_id,
        .started_at = marker.rfc3339(&ts, std.time.milliTimestamp()),
    }) catch |err| {
        log.warn("instance marker {s} not written: {}", .{ path, err });
        gpa.free(path);
        return;
    };
    p.marker_path = path;
}

/// Stop serving and join every server thread (UI thread, App.terminate,
/// before msg_hwnd is destroyed). UI-lane requests still queued in
/// app.tasks are destroyed unanswered afterwards (their clients already got
/// `overloaded server_stopping` or `cancelled`).
pub fn stop(app: *App) void {
    const p = plane orelse return;
    const gpa = p.gpa;
    app.modal.idle_hook = null;
    if (p.marker_path) |path| {
        marker.remove(gpa, path, std.os.windows.GetCurrentProcessId());
        gpa.free(path);
        p.marker_path = null;
    }
    if (p.control) |c| c.stop();
    // Worker-lane jobs hold the control server (`Call.server`): join them
    // after the server stopped (their begin/complete are then no-ops) and
    // before it is freed.
    p.workers.stop();
    if (p.control) |c| {
        reply.unbind();
        p.hub.forgetServer(c);
        c.deinit();
        p.control = null;
    }
    legacy_pipe.stopPipe(&p.hub);
    p.ui.close();
    if (p.launch) |lp| lp.deinit();
    p.launch = null;
    app.ipc_server = null;
    p.hub.deinit();
    dialogs.resetTestRecords();
    plane = null;
    gpa.free(p.channel);
    gpa.free(p.control_name);
    gpa.free(p.launch_name);
    gpa.destroy(p);
}

/// The full name of the v2 control pipe this instance serves
/// (`\\.\pipe\wmux-<channel>-<sidhash8>-s<session>`, or its
/// `-alt-<8hex>` fallback, ADR-3.1), UTF-8, borrowed until `stop`; null
/// while no v2 server runs. The terminal environment exports it as
/// `CMUX_SOCKET_PATH`/`WMUX_SOCKET_PATH` (W1-3, ADR-3.9).
pub fn controlPipeName(app: *const App) ?[]const u8 {
    _ = app;
    const p = plane orelse return null;
    return if (p.control_running) p.control_name else null;
}

test {
    _ = &controlPipeName;
    _ = @import("marker.zig");
    _ = @import("legacy_pipe.zig");
    _ = @import("live_tests.zig");
    _ = @import("../dispatch.zig");
    _ = @import("../lanes.zig");
    _ = @import("../reply.zig");
    _ = @import("../../app/single_instance.zig");
}

test "unit: rpc: entry points other WPs call compile" {
    // Referenced so they are compiled before their first caller lands
    // (event streams, W2-4; deferred handlers, W2-8).
    _ = &PipeServer.pushLine;
    _ = &reply.completeRaw;
}
