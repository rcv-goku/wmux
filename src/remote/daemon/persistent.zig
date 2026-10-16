//! Persistent mode (ADR-13): one long-lived server per slot listening on a
//! Unix socket in the slot directory (see paths.zig), and a thin stdio
//! bridge (`serve --stdio --persistent`) that the carrier's ssh runs. The
//! bridge starts the server when none is running and then only copies
//! bytes, so sessions survive the bridge (and the ssh connection) going away.
//!
//! Access control: the slot directory is 0700 and the socket 0600, so only
//! the owning user can connect. Clients connect only after checking that
//! the socket's directory is a private directory of their own: the
//! /tmp/wmuxd-remote-<uid> fallback could otherwise be planted by another
//! user, who would then receive the terminal traffic. The server holds an
//! exclusive flock on daemon.lock for its whole life; that lock (not the
//! pid file) decides whether a server is running.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const remote = @import("wmux_proto").remote;
const paths = @import("paths.zig");
const pty = @import("pty.zig");
const server = @import("server.zig");

const log = std.log.scoped(.remote_daemon);

pub const Slot = struct {
    name: []const u8,
    dir: []u8,
    sock: []u8,
    lock: []u8,
    pid: []u8,
    log: []u8,

    pub fn init(gpa: Allocator, home: []const u8, name: []const u8) Allocator.Error!Slot {
        const dir = try paths.slotDir(gpa, home, name);
        errdefer gpa.free(dir);
        const sock = try paths.socketPath(gpa, dir, pty.currentUid());
        errdefer gpa.free(sock);
        const lock = try paths.fileIn(gpa, dir, paths.lock_name);
        errdefer gpa.free(lock);
        const pid = try paths.fileIn(gpa, dir, paths.pid_name);
        errdefer gpa.free(pid);
        const lg = try paths.fileIn(gpa, dir, paths.log_name);
        return .{ .name = name, .dir = dir, .sock = sock, .lock = lock, .pid = pid, .log = lg };
    }

    pub fn deinit(self: *Slot, gpa: Allocator) void {
        for ([_][]u8{ self.dir, self.sock, self.lock, self.pid, self.log }) |p| gpa.free(p);
        self.* = undefined;
    }
};

/// Creates `path` (and parents) and restricts it to the user (0700). A
/// symlink or a directory owned by someone else is refused, never chmod-ed.
pub fn ensurePrivateDir(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
    const st = try posix.fstatat(posix.AT.FDCWD, path, posix.AT.SYMLINK_NOFOLLOW);
    if (!posix.S.ISDIR(st.mode) or st.uid != pty.currentUid()) return error.AccessDenied;
    try posix.fchmodat(posix.AT.FDCWD, path, 0o700, 0);
}

/// Fails with AccessDenied unless `path` is a real directory (not a
/// symlink) owned by the user with no group or other access: then nobody
/// else can have planted or swapped anything inside it.
pub fn checkPrivateDir(path: []const u8) !void {
    const st = try posix.fstatat(posix.AT.FDCWD, path, posix.AT.SYMLINK_NOFOLLOW);
    if (!posix.S.ISDIR(st.mode) or st.uid != pty.currentUid() or (st.mode & 0o077) != 0)
        return error.AccessDenied;
}

pub fn listen(path: []const u8) !posix.fd_t {
    const addr = try std.net.Address.initUnix(path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer posix.close(fd);
    posix.unlink(path) catch {};
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.fchmodat(posix.AT.FDCWD, path, 0o600, 0);
    try posix.listen(fd, 16);
    return fd;
}

/// Connects to a slot socket, but only inside a private directory (see
/// `checkPrivateDir`; the socket may be in the shared /tmp fallback).
pub fn connect(path: []const u8) !posix.fd_t {
    try checkPrivateDir(std.fs.path.dirname(path) orelse return error.AccessDenied);
    const addr = try std.net.Address.initUnix(path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

/// True when a server holds the slot lock.
pub fn lockHeld(lock_path: []const u8) bool {
    const f = std.fs.cwd().openFile(lock_path, .{ .mode = .read_write }) catch return false;
    defer f.close();
    posix.flock(f.handle, posix.LOCK.EX | posix.LOCK.NB) catch return true;
    posix.flock(f.handle, posix.LOCK.UN) catch {};
    return false;
}

pub const ServerOptions = struct {
    session_ttl_ms: i64 = 0,
    idle_exit_ms: i64 = 30 * 60 * 1000,
    stop_flag: ?*const std.atomic.Value(bool) = null,
    kill_grace_ms: i64 = 2000,
};

/// `serve --persistent-server`: runs the slot's server until stopped.
/// Returns error.AlreadyRunning when another server holds the slot.
pub fn runServer(gpa: Allocator, home: []const u8, name: []const u8, opts: ServerOptions) !void {
    var slot = try Slot.init(gpa, home, name);
    defer slot.deinit(gpa);
    try ensurePrivateDir(slot.dir);
    const sock_dir = std.fs.path.dirname(slot.sock).?;
    if (!std.mem.eql(u8, sock_dir, slot.dir)) try ensurePrivateDir(sock_dir);

    const lock = try std.fs.cwd().createFile(slot.lock, .{ .truncate = false, .mode = 0o600 });
    defer lock.close();
    try lockSlot(lock);
    {
        var buf: [32]u8 = undefined;
        const pid_text = try std.fmt.bufPrint(&buf, "{d}\n", .{std.c.getpid()});
        try std.fs.cwd().writeFile(.{ .sub_path = slot.pid, .data = pid_text, .flags = .{ .mode = 0o600 } });
    }
    defer std.fs.cwd().deleteFile(slot.pid) catch {};
    const lfd = try listen(slot.sock);
    defer posix.unlink(slot.sock) catch {};

    var srv = server.Server.init(gpa, .{
        .persistent = true,
        .slot = name,
        .home = home,
        .session_ttl_ms = opts.session_ttl_ms,
        .idle_exit_ms = opts.idle_exit_ms,
        .exit_when_no_clients = false,
        .stop_flag = opts.stop_flag,
        .kill_grace_ms = opts.kill_grace_ms,
    });
    srv.listener = lfd; // closed by deinit
    defer srv.deinit();
    log.info("slot {s} serving on {s}", .{ name, slot.sock });
    try srv.run();
}

/// Takes the slot lock for the server's lifetime. `lockHeld` (status,
/// --persistent-stop) takes the lock for an instant to probe it, so a
/// starting server retries for a moment before it concludes that another
/// server owns the slot.
fn lockSlot(lock: std.fs.File) !void {
    var tries: usize = 0;
    while (true) : (tries += 1) {
        if (posix.flock(lock.handle, posix.LOCK.EX | posix.LOCK.NB)) |_| return else |err| switch (err) {
            error.WouldBlock => if (tries >= 25) return error.AlreadyRunning,
            else => return err,
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

/// Starts the slot server detached from the caller (double fork, new
/// session, stdin /dev/null, stdout/stderr to daemon.log).
pub fn spawnServer(gpa: Allocator, exe: []const u8, slot: *const Slot, session_ttl_s: u64) !void {
    try ensurePrivateDir(slot.dir);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ttl = try std.fmt.allocPrintSentinel(a, "{d}", .{session_ttl_s}, 0);
    const argv = [_:null]?[*:0]const u8{ try a.dupeZ(u8, exe), "serve", "--persistent-server", "--slot", try a.dupeZ(u8, slot.name), "--session-ttl", ttl };
    const exe_z = try a.dupeZ(u8, exe);
    const log_file = try std.fs.cwd().createFile(slot.log, .{ .truncate = false, .mode = 0o600 });
    defer log_file.close();
    try log_file.seekFromEnd(0);
    const devnull = try std.fs.cwd().openFile("/dev/null", .{ .mode = .read_write });
    defer devnull.close();
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);

    const pid = try posix.fork();
    if (pid == 0) {
        _ = std.c.setsid();
        const pid2 = std.c.fork();
        if (pid2 != 0) std.c._exit(if (pid2 < 0) 1 else 0);
        _ = std.c.dup2(devnull.handle, 0);
        _ = std.c.dup2(log_file.handle, 1);
        _ = std.c.dup2(log_file.handle, 2);
        _ = std.c.execve(exe_z, &argv, envp);
        std.c._exit(127);
    }
    _ = std.c.waitpid(pid, null, 0);
}

/// Connects to the slot server, starting it if needed (bounded wait). The
/// start is repeated every second while waiting: a server that was still
/// shutting down when we spawned holds the lock, and the one we spawned
/// then exits as AlreadyRunning, leaving nobody to listen.
pub fn connectOrSpawn(gpa: Allocator, exe: []const u8, slot: *const Slot, session_ttl_s: u64, wait_ms: i64) !posix.fd_t {
    if (connect(slot.sock)) |fd| return fd else |_| {}
    const start = std.time.milliTimestamp();
    var next_spawn = start;
    while (true) {
        const now = std.time.milliTimestamp();
        if (now >= next_spawn) {
            try spawnServer(gpa, exe, slot, session_ttl_s);
            next_spawn = now + 1000;
        }
        if (connect(slot.sock)) |fd| return fd else |err| {
            if (now - start >= wait_ms) return err;
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        off += posix.write(fd, bytes[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                var p = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                _ = try posix.poll(&p, 1000);
                continue;
            },
            else => return err,
        };
    }
}

/// Copies bytes both ways between (in_fd, out_fd) and `sock` until either
/// side reaches end of stream (or `stop` is set).
pub fn pump(in_fd: posix.fd_t, out_fd: posix.fd_t, sock: posix.fd_t, stop: ?*const std.atomic.Value(bool)) !void {
    var buf: [64 * 1024]u8 = undefined;
    while (stop == null or !stop.?.load(.acquire)) {
        var fds = [_]posix.pollfd{
            .{ .fd = in_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 250) == 0) continue;
        if (fds[0].revents != 0) {
            const n = posix.read(in_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => null,
                else => return,
            };
            if (n) |len| {
                if (len == 0) return; // end of stream
                writeAllFd(sock, buf[0..len]) catch return;
            }
        }
        if (fds[1].revents != 0) {
            const n = posix.read(sock, &buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return,
            };
            if (n == 0) return;
            writeAllFd(out_fd, buf[0..n]) catch return;
        }
    }
}

/// `serve --stdio --persistent`: bridge stdio to the slot server.
pub fn runBridge(gpa: Allocator, home: []const u8, name: []const u8, session_ttl_s: u64, stop: ?*const std.atomic.Value(bool)) !void {
    var slot = try Slot.init(gpa, home, name);
    defer slot.deinit(gpa);
    const exe = try std.fs.selfExePathAlloc(gpa);
    defer gpa.free(exe);
    const sock = try connectOrSpawn(gpa, exe, &slot, session_ttl_s, 5000);
    defer posix.close(sock);
    try pump(posix.STDIN_FILENO, posix.STDOUT_FILENO, sock, stop);
}

pub const StopResult = enum { not_running, stopped, killed };

/// `serve --persistent-stop`: SIGTERM the slot server (it closes its
/// sessions), SIGKILL after `wait_ms`. A stale pid file is never signalled,
/// and neither is a successor that a reconnecting bridge started meanwhile.
pub fn stopSlot(gpa: Allocator, home: []const u8, name: []const u8, wait_ms: i64) !StopResult {
    var slot = try Slot.init(gpa, home, name);
    defer slot.deinit(gpa);
    if (!lockHeld(slot.lock)) return .not_running;
    const pid = readPid(slot.pid) orelse return .not_running;
    _ = std.c.kill(pid, posix.SIG.TERM);
    const deadline = std.time.milliTimestamp() + wait_ms;
    while (std.time.milliTimestamp() < deadline) {
        if (!stillOwns(&slot, pid)) return .stopped;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    // Only while the pid file still names the server we signalled: never a
    // successor, and never a pid that already exited (it may be reused).
    if (!lockHeld(slot.lock) or readPid(slot.pid) != pid) return .stopped;
    _ = std.c.kill(pid, posix.SIG.KILL);
    return .killed;
}

/// True while the server `pid` may still own the slot: the lock is held and
/// the pid file does not name another server. The old server deletes the
/// file before it drops the lock, and a successor writes its own pid after
/// taking it, so a missing file means "in between": keep waiting.
fn stillOwns(slot: *const Slot, pid: posix.pid_t) bool {
    if (!lockHeld(slot.lock)) return false;
    const current = readPid(slot.pid) orelse return true;
    return current == pid;
}

pub fn readPid(path: []const u8) ?posix.pid_t {
    var buf: [32]u8 = undefined;
    const text = std.fs.cwd().readFile(path, &buf) catch return null;
    const v = std.fmt.parseInt(posix.pid_t, std.mem.trim(u8, text, " \r\n"), 10) catch return null;
    return if (v > 0) v else null;
}

pub const SlotStatus = struct {
    slot: []const u8,
    running: bool,
    pid: ?i64 = null,
    socket: []const u8,
    sessions: ?u64 = null,
    attachments: ?u64 = null,
};

/// Probes one slot: lock state, pid, and (when running) session counts
/// from a `pty.list` over the socket. Strings are allocated in `a`.
pub fn probeSlot(a: Allocator, home: []const u8, name: []const u8) !SlotStatus {
    const slot = try Slot.init(a, home, name);
    var st: SlotStatus = .{ .slot = try a.dupe(u8, name), .running = lockHeld(slot.lock), .socket = slot.sock };
    if (!st.running) return st;
    if (readPid(slot.pid)) |p| st.pid = p;
    const fd = connect(slot.sock) catch return st;
    var c = Client.init(a, fd, fd, true);
    defer c.deinit();
    const h = c.hello(false, 3000) catch return st;
    if (!h.ok) return st;
    const r = c.request(.pty_list, .{}, 3000) catch return st;
    if (!r.ok or r.result != .object) return st;
    const sessions = r.result.object.get("sessions") orelse return st;
    if (sessions != .array) return st;
    var att: u64 = 0;
    for (sessions.array.items) |s| {
        if (s == .object) if (s.object.get("attachments")) |n| if (n == .integer) {
            att +|= @intCast(@max(n.integer, 0));
        };
    }
    st.sessions = sessions.array.items.len;
    st.attachments = att;
    return st;
}

/// Slots of this daemon version that exist on disk (sorted), or just `only`.
pub fn listSlots(a: Allocator, home: []const u8, only: ?[]const u8) ![]const []const u8 {
    if (only) |o| {
        const one = try a.alloc([]const u8, 1);
        one[0] = o;
        return one;
    }
    var out: std.ArrayList([]const u8) = .empty;
    const vdir = try paths.versionDir(a, home);
    var dir = std.fs.cwd().openDir(vdir, .{ .iterate = true }) catch return out.items;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory and remote.messages.isValidName(e.name)) try out.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

/// `wmuxd-remote status [--slot <slot>] [--json]`.
pub fn writeStatus(gpa: Allocator, w: *std.Io.Writer, home: []const u8, only: ?[]const u8, json: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const names = try listSlots(a, home, only);
    const list = try a.alloc(SlotStatus, names.len);
    for (list, names) |*st, n| st.* = try probeSlot(a, home, n);
    if (json) {
        try std.json.Stringify.value(.{
            .name = "wmuxd-remote",
            .version = remote.rpc.daemon_version,
            .protocol_version = remote.rpc.protocol_version,
            .slots = list,
        }, .{ .emit_null_optional_fields = false }, w);
        try w.writeByte('\n');
        return;
    }
    try w.print("wmuxd-remote {s} (protocol {d})\n", .{ remote.rpc.daemon_version, remote.rpc.protocol_version });
    if (list.len == 0) try w.writeAll("No wmuxd-remote slots\n");
    for (list) |st| {
        if (!st.running) {
            try w.print("{s} stopped\n", .{st.slot});
            continue;
        }
        try w.print("{s} running pid={d} sessions={d} attachments={d} socket={s}\n", .{ st.slot, st.pid orelse 0, st.sessions orelse 0, st.attachments orelse 0, st.socket });
    }
}

const Client = @import("client.zig").Client;

const testing = std.testing;

test "unit: remote-daemon: slot sockets are only reached through a private directory" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const dir = try std.fs.path.join(gpa, &.{ root, "d" });
    defer gpa.free(dir);
    const sock = try std.fs.path.join(gpa, &.{ dir, "s.sock" });
    defer gpa.free(sock);
    try ensurePrivateDir(dir);
    const lfd = try listen(sock);
    defer posix.close(lfd);
    posix.close(try connect(sock));

    // Others can enter the directory (as with a /tmp fallback directory
    // planted by another user): no connecting.
    try posix.fchmodat(posix.AT.FDCWD, dir, 0o755, 0);
    try testing.expectError(error.AccessDenied, connect(sock));

    // A symlink to a private directory is refused by client and server.
    try posix.fchmodat(posix.AT.FDCWD, dir, 0o700, 0);
    const link = try std.fs.path.join(gpa, &.{ root, "l" });
    defer gpa.free(link);
    try posix.symlink(dir, link);
    const via_link = try std.fs.path.join(gpa, &.{ link, "s.sock" });
    defer gpa.free(via_link);
    try testing.expectError(error.AccessDenied, connect(via_link));
    try testing.expectError(error.AccessDenied, ensurePrivateDir(link));
    try testing.expectError(error.AccessDenied, checkPrivateDir(link));

    // The server tightens a directory of its own again.
    try posix.fchmodat(posix.AT.FDCWD, dir, 0o755, 0);
    try ensurePrivateDir(dir);
    try checkPrivateDir(dir);
    posix.close(try connect(sock));
}

test "unit: remote-daemon: stop waits only for the server it signalled" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    var slot = try Slot.init(gpa, home, "stop");
    defer slot.deinit(gpa);
    try ensurePrivateDir(slot.dir);
    try testing.expect(!stillOwns(&slot, 4242));

    // A server holds the lock and the pid file names it.
    const lock = try std.fs.cwd().createFile(slot.lock, .{ .truncate = false, .mode = 0o600 });
    try posix.flock(lock.handle, posix.LOCK.EX | posix.LOCK.NB);
    try std.fs.cwd().writeFile(.{ .sub_path = slot.pid, .data = "4242\n" });
    try testing.expect(stillOwns(&slot, 4242));
    // Between the old server's exit and its successor's pid file: wait on.
    try std.fs.cwd().deleteFile(slot.pid);
    try testing.expect(stillOwns(&slot, 4242));
    // A successor (a reconnecting bridge started it) owns the slot now:
    // the signalled server is gone and must not be waited for or killed.
    try std.fs.cwd().writeFile(.{ .sub_path = slot.pid, .data = "4343\n" });
    try testing.expect(!stillOwns(&slot, 4242));
    lock.close();
    try testing.expect(!stillOwns(&slot, 4343));
}
