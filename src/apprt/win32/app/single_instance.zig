//! Single instance per channel (ARCHITECTURE.md ADR-3.1; W1-1a).
//!
//! At startup (rpc/server/mod.zig `start`, from App.init once msg_hwnd
//! exists and before the first window) the app tries to create the launch
//! pipe `<control pipe>-launch` with FILE_FLAG_FIRST_PIPE_INSTANCE:
//!
//! - created: this process is the instance of its channel; the pipe stays
//!   on (even with the control pipe off) and accepts only `app.launch`;
//! - it exists and its server runs as our user: this process forwards
//!   `app.launch {intent, argv, cwd, paths, uri}` (intent `open` when the
//!   command line names files or folders, `uri` for a `wmux:`/`cmux:` URI,
//!   else `new_window`), calls AllowSetForegroundWindow(server pid) so the
//!   instance may come forward, and exits 0;
//! - the handoff fails (a foreign or hung server): this process runs on
//!   its own under the `-alt-<8hex>` names (ADR-3.1 squatting rule).
//!
//! `LaunchPipe.claim` may invoke `onLaunch` on a connection thread before
//! it returns (a client can connect as soon as the pipe exists), so
//! `onLaunch` only copies the request and posts it to the UI thread through
//! `app.tasks`, which exists before the claim. The UI thread then opens a
//! workspace per folder in the active window (`open`), opens a window
//! (`new_window`) or raises the active window (`activate`; never in
//! WMUX_TEST_HIDDEN). The launch reply is read with a 64 KiB line cap.
//!
//! Test instances never collide: their channel is unique (`test-<8hex>`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const envelope = proto.envelope;

const App = @import("../App.zig");
const PipeServer = @import("../rpc/server/PipeServer.zig");
const app_foreground = @import("foreground.zig");
const app_logger = @import("logger.zig");
const launch_pipe = @import("../rpc/server/launch_pipe.zig");
const ops_window = @import("../model/ops/window.zig");
const router = @import("../rpc/router.zig");
const tasks = @import("tasks.zig");

const Connection = PipeServer.Connection;
const w32c = Connection.w32;
const LaunchRequest = launch_pipe.LaunchRequest;

const log = std.log.scoped(.single_instance);

extern "user32" fn AllowSetForegroundWindow(dwProcessId: u32) callconv(.winapi) std.os.windows.BOOL;

/// The reply line cap of the launch client (FOLLOWUPS: `PipeClient.readLine`
/// is unbounded).
pub const max_reply_bytes: usize = 64 * 1024;

/// How long the second process waits for the instance to answer.
pub const handoff_timeout_ms: u32 = 5_000;

pub const Claim = union(enum) {
    /// We are the instance; the launch pipe serves until `deinit`.
    serving: *launch_pipe.LaunchPipe,
    /// The handoff failed: run standalone under alt names.
    standalone,
};

/// Claims `launch_name` for this process, or hands this launch to the
/// running instance and exits the process (0). See the file comment.
pub fn claimOrHandoff(app: *App, gpa: Allocator, launch_name: []const u8) Claim {
    const result = launch_pipe.LaunchPipe.claim(gpa, launch_name, onLaunch, app, .{}) catch |err| {
        log.warn("launch pipe {s} unavailable: {}", .{ launch_name, err });
        return .standalone;
    };
    switch (result) {
        .serving => |lp| return .{ .serving = lp },
        .exists => {},
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const req = requestFromCommandLine(arena_state.allocator()) catch LaunchRequest{ .intent = .new_window };
    const reply = sendLaunch(gpa, launch_name, req, handoff_timeout_ms) catch |err| {
        log.warn("another instance holds {s} but the handoff failed ({}); running standalone", .{ launch_name, err });
        return .standalone;
    };
    if (!reply.accepted) {
        log.warn("the running instance refused the launch; running standalone", .{});
        return .standalone;
    }
    // Let the instance come forward (it is the user's launch).
    _ = AllowSetForegroundWindow(reply.pid);
    log.info("handed the launch to instance pid={d} (intent {s}); exiting", .{ reply.pid, @tagName(req.intent) });
    app_logger.stop();
    std.process.exit(0);
}

/// The `app.launch` request for this process's command line.
pub fn requestFromCommandLine(arena: Allocator) !LaunchRequest {
    const argv = try std.process.argsAlloc(arena);
    const cwd = std.process.getCwdAlloc(arena) catch null;
    return classify(arena, argv, cwd, isExistingPath);
}

fn isExistingPath(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Builds the request from `argv` (argv[0] is the executable): arguments
/// starting with `-` or `+` are options (Ghostty config flags, actions)
/// and are ignored; `wmux:`/`cmux:` arguments are URIs; existing paths
/// (made absolute against `cwd`) are paths. Pure apart from `exists`
/// (unit-tested).
pub fn classify(arena: Allocator, argv: []const []const u8, cwd: ?[]const u8, exists: *const fn ([]const u8) bool) !LaunchRequest {
    var paths: std.ArrayList([]const u8) = .empty;
    var uri: ?[]const u8 = null;
    for (argv[@min(argv.len, 1)..]) |a| {
        if (a.len == 0 or a[0] == '-' or a[0] == '+') continue;
        if (std.ascii.startsWithIgnoreCase(a, "wmux:") or std.ascii.startsWithIgnoreCase(a, "cmux:")) {
            if (uri == null) uri = a;
            continue;
        }
        const abs = if (std.fs.path.isAbsolute(a) or cwd == null) a else try std.fs.path.join(arena, &.{ cwd.?, a });
        if (exists(abs)) try paths.append(arena, abs);
    }
    const intent: launch_pipe.Intent = if (uri != null) .uri else if (paths.items.len > 0) .open else .new_window;
    return .{ .intent = intent, .argv = argv, .cwd = cwd, .paths = paths.items, .uri = uri };
}

pub const SendError = launch_pipe.PipeClient.Error || launch_pipe.ReplyError || error{ ForeignServer, TooLong };

/// `launch_pipe.sendLaunch` with the reply line capped at
/// `max_reply_bytes`.
pub fn sendLaunch(gpa: Allocator, launch_path: []const u8, req: LaunchRequest, timeout_ms: u32) SendError!launch_pipe.LaunchReply {
    var client = try launch_pipe.PipeClient.connect(gpa, launch_path, timeout_ms);
    defer client.close();
    if (!client.serverIsSameUser()) return error.ForeignServer;
    const id = envelope.newRequestId();
    const line = try launch_pipe.encodeRequestAlloc(gpa, &id, req);
    defer gpa.free(line);
    try client.writeLine(line, timeout_ms);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const reply_line = try readLineCapped(&client, &buf, timeout_ms, max_reply_bytes);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    return launch_pipe.parseReply(arena_state.allocator(), &id, reply_line);
}

/// One reply line of at most `cap` bytes (terminator excluded).
fn readLineCapped(client: *launch_pipe.PipeClient, buf: *std.ArrayList(u8), timeout_ms: u32, cap: usize) SendError![]const u8 {
    var timer = std.time.Timer.start() catch null;
    var chunk: [4096]u8 = undefined;
    var ov = std.mem.zeroes(w32c.OVERLAPPED);
    ov.hEvent = client.read_event;
    while (true) {
        if (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| return envelope.trimLineEnd(buf.items[0..nl]);
        if (buf.items.len > cap) return error.TooLong;
        const spent: u64 = if (timer) |*t| t.read() / std.time.ns_per_ms else 0;
        if (spent >= timeout_ms) return error.Timeout;
        if (!Connection.startRead(client.handle, &ov, &chunk)) return error.Closed;
        switch (Connection.awaitIo(client.handle, &ov, null, @intCast(timeout_ms - spent))) {
            .done => |n| try buf.appendSlice(client.gpa, chunk[0..n]),
            .failed => return error.Closed,
            .timeout, .stopped => return error.Timeout,
        }
    }
}

// ---------------------------------------------------------------------------
// Instance side
// ---------------------------------------------------------------------------

/// One received launch, copied for the UI thread.
const LaunchTask = struct {
    task: tasks.Task = .{ .run = run, .destroy = destroy },
    arena: std.heap.ArenaAllocator,
    intent: launch_pipe.Intent,
    paths: []const []const u8,
    uri: ?[]const u8,

    fn run(app: *App, task: *tasks.Task) void {
        const self: *LaunchTask = @fieldParentPtr("task", task);
        remember(self);
        handle(app, self.intent, self.paths, self.uri);
    }

    fn destroy(task: *tasks.Task) void {
        const self: *LaunchTask = @fieldParentPtr("task", task);
        var arena = self.arena;
        arena.deinit();
    }
};

/// Connection thread of the launch pipe: copy and post. Runs possibly
/// before `claim` returned (see the file comment).
fn onLaunch(ctx: ?*anyopaque, req: *const LaunchRequest, client_pid: u32) bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    _ = client_pid;
    const gpa = app.core_app.alloc;
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const t = a.create(LaunchTask) catch {
        arena.deinit();
        return false;
    };
    const paths = a.alloc([]const u8, req.paths.len) catch {
        arena.deinit();
        return false;
    };
    for (req.paths, paths) |p, *d| d.* = a.dupe(u8, p) catch {
        arena.deinit();
        return false;
    };
    const uri: ?[]const u8 = if (req.uri) |u| (a.dupe(u8, u) catch null) else null;
    t.* = .{ .arena = undefined, .intent = req.intent, .paths = paths, .uri = uri };
    // The arena owns `t` itself: move it in last.
    t.arena = arena;
    app.tasks.post(&t.task);
    return true;
}

/// Applies one launch on the UI thread.
fn handle(app: *App, intent: launch_pipe.Intent, paths: []const []const u8, uri: ?[]const u8) void {
    switch (intent) {
        .open => {
            const window = router.activeWindow(app) orelse return newWindow(app);
            for (paths) |p| {
                const dir = if (isDirectory(p)) p else (std.fs.path.dirname(p) orelse continue);
                _ = ops_window.newWorkspaceWithDir(window, dir);
            }
            raise(app, window);
        },
        .new_window => newWindow(app),
        .activate => if (router.activeWindow(app)) |w| raise(app, w),
        .uri => log.info("app.launch uri not handled yet: {s}", .{uri orelse ""}),
    }
}

fn isDirectory(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

fn newWindow(app: *App) void {
    _ = app.performAction(.app, .new_window, {}) catch |err| log.err("app.launch new_window failed: {}", .{err});
}

fn raise(app: *App, window: anytype) void {
    const hwnd = window.hwnd orelse return;
    // The launching process granted us the foreground; never in hidden mode.
    app_foreground.raiseForegroundWindow(app, hwnd);
}

// ---------------------------------------------------------------------------
// Recent launches (wmux.debug.layout, UI thread)
// ---------------------------------------------------------------------------

pub const Recent = struct {
    intent: []const u8,
    paths: usize,
};

var recent_buf: [16]Recent = undefined;
var recent_len: usize = 0;
var recent_total: u64 = 0;

fn remember(t: *const LaunchTask) void {
    if (recent_len == recent_buf.len) {
        std.mem.copyForwards(Recent, recent_buf[0 .. recent_buf.len - 1], recent_buf[1..]);
        recent_len -= 1;
    }
    recent_buf[recent_len] = .{ .intent = @tagName(t.intent), .paths = t.paths.len };
    recent_len += 1;
    recent_total += 1;
}

/// The launches received so far (newest last, at most 16) and their total.
pub fn recentLaunches() struct { items: []const Recent, total: u64 } {
    return .{ .items = recent_buf[0..recent_len], .total = recent_total };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fakeExists(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "proj") or std.mem.endsWith(u8, path, "a.txt");
}

test "unit: app: single instance classifies the command line into an app.launch intent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const open = try classify(a, &.{ "wmux.exe", "--config-default-files=false", "C:\\work\\proj", "missing" }, "C:\\cwd", fakeExists);
    try testing.expectEqual(launch_pipe.Intent.open, open.intent);
    try testing.expectEqual(@as(usize, 1), open.paths.len);
    try testing.expectEqualStrings("C:\\work\\proj", open.paths[0]);
    try testing.expectEqualStrings("C:\\cwd", open.cwd.?);

    const rel = try classify(a, &.{ "wmux.exe", "a.txt" }, "C:\\cwd", fakeExists);
    try testing.expectEqual(launch_pipe.Intent.open, rel.intent);
    try testing.expect(std.mem.endsWith(u8, rel.paths[0], "a.txt"));

    const bare = try classify(a, &.{"wmux.exe"}, null, fakeExists);
    try testing.expectEqual(launch_pipe.Intent.new_window, bare.intent);
    try testing.expectEqual(@as(usize, 0), bare.paths.len);

    const u = try classify(a, &.{ "wmux.exe", "wmux://notification/open?id=1", "C:\\work\\proj" }, null, fakeExists);
    try testing.expectEqual(launch_pipe.Intent.uri, u.intent);
    try testing.expectEqualStrings("wmux://notification/open?id=1", u.uri.?);

    const plus = try classify(a, &.{ "wmux.exe", "+new-window" }, null, fakeExists);
    try testing.expectEqual(launch_pipe.Intent.new_window, plus.intent);
}
