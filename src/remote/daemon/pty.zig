//! PTY processes: openpty + fork + exec with the slave as controlling
//! terminal, window size updates, and non-blocking reaping. POSIX only
//! (Linux and macOS); everything the child needs is prepared before fork so
//! the child only makes async-signal-safe calls.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Size = @import("sizing.zig").Size;

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const posix.winsize) c_int;
extern "c" fn getpwuid(uid: posix.uid_t) ?*const Passwd;
extern "c" fn getuid() posix.uid_t;

/// Leading fields of `struct passwd`; only pw_shell is read and its offset
/// differs per OS.
const Passwd = switch (builtin.os.tag) {
    .linux => extern struct {
        pw_name: ?[*:0]const u8,
        pw_passwd: ?[*:0]const u8,
        pw_uid: posix.uid_t,
        pw_gid: posix.gid_t,
        pw_gecos: ?[*:0]const u8,
        pw_dir: ?[*:0]const u8,
        pw_shell: ?[*:0]const u8,
    },
    else => extern struct {
        pw_name: ?[*:0]const u8,
        pw_passwd: ?[*:0]const u8,
        pw_uid: posix.uid_t,
        pw_gid: posix.gid_t,
        pw_change: isize,
        pw_class: ?[*:0]const u8,
        pw_gecos: ?[*:0]const u8,
        pw_dir: ?[*:0]const u8,
        pw_shell: ?[*:0]const u8,
        pw_expire: isize,
    },
};

pub fn currentUid() u32 {
    return @intCast(getuid());
}

/// The user's login shell: $SHELL when absolute, else the passwd entry,
/// else /bin/sh. Returned slice is static or environment-owned.
pub fn loginShell() []const u8 {
    if (posix.getenv("SHELL")) |s| if (pickShell(s)) |v| return v;
    if (getpwuid(getuid())) |pw| if (pw.pw_shell) |s| if (pickShell(std.mem.span(s))) |v| return v;
    return "/bin/sh";
}

/// $HOME, else the passwd home directory.
pub fn homeDir() ?[]const u8 {
    if (posix.getenv("HOME")) |h| if (h.len > 0) return h;
    if (getpwuid(getuid())) |pw| if (pw.pw_dir) |d| return std.mem.span(d);
    return null;
}

/// Accepts absolute shell paths only (pure; exposed for tests).
pub fn pickShell(s: []const u8) ?[]const u8 {
    if (s.len == 0 or s[0] != '/') return null;
    return s;
}

/// `-<basename>`: argv[0] that makes a shell behave as a login shell.
pub fn loginArgv0(gpa: Allocator, shell: []const u8) Allocator.Error![:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "-{s}", .{std.fs.path.basename(shell)}, 0);
}

/// Finds `name` on PATH (or returns it when it contains a slash).
pub fn resolveExecutable(gpa: Allocator, name: []const u8, path_env: ?[]const u8) error{ FileNotFound, OutOfMemory }![:0]u8 {
    if (name.len == 0) return error.FileNotFound;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const z = try gpa.dupeZ(u8, name);
        posix.accessZ(z, posix.X_OK) catch {
            gpa.free(z);
            return error.FileNotFound;
        };
        return z;
    }
    var it = std.mem.tokenizeScalar(u8, path_env orelse "/usr/local/bin:/usr/bin:/bin", ':');
    while (it.next()) |dir| {
        const full = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0);
        if (posix.accessZ(full, posix.X_OK)) |_| return full else |_| gpa.free(full);
    }
    return error.FileNotFound;
}

pub const SpawnOptions = struct {
    /// argv; null runs the login shell as a login shell.
    argv: ?[]const []const u8 = null,
    /// Extra `NAME=value` entries (override inherited ones).
    env: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    size: Size = .{ .cols = 80, .rows = 24 },
};

pub const Spawned = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
};

pub const SpawnError = error{ OpenPtyFailed, FileNotFound, InvalidArgv } || posix.ForkError || Allocator.Error;

pub fn spawn(gpa: Allocator, opts: SpawnOptions) SpawnError!Spawned {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // argv and the executable path.
    var exe: [:0]const u8 = undefined;
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    if (opts.argv) |a| {
        if (a.len == 0) return error.InvalidArgv;
        exe = try resolveExecutable(arena, a[0], posix.getenv("PATH"));
        for (a) |s| {
            if (std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidArgv;
            try argv.append(arena, try arena.dupeZ(u8, s));
        }
    } else {
        const shell = loginShell();
        exe = try arena.dupeZ(u8, shell);
        try argv.append(arena, try loginArgv0(arena, shell));
    }
    try argv.append(arena, null);

    const envp = try buildEnv(arena, opts.env);
    const cwd: ?[:0]const u8 = if (opts.cwd) |c| try arena.dupeZ(u8, c) else if (posix.getenv("HOME")) |h| try arena.dupeZ(u8, h) else null;

    var master: c_int = -1;
    var slave: c_int = -1;
    var ws: posix.winsize = .{ .col = opts.size.cols, .row = opts.size.rows, .xpixel = 0, .ypixel = 0 };
    if (openpty(&master, &slave, null, null, &ws) != 0) return error.OpenPtyFailed;
    setCloexec(master);
    setCloexec(slave);

    const pid = posix.fork() catch |err| {
        posix.close(master);
        posix.close(slave);
        return err;
    };
    if (pid == 0) childExec(master, slave, exe, argv.items[0 .. argv.items.len - 1 :null], envp, if (cwd) |c| c.ptr else null);
    posix.close(slave);
    setNonblock(master);
    return .{ .master = master, .pid = pid };
}

fn buildEnv(arena: Allocator, extra: []const []const u8) Allocator.Error![:null]const ?[*:0]const u8 {
    var map = std.process.getEnvMap(arena) catch return error.OutOfMemory;
    if (map.get("TERM") == null or std.mem.eql(u8, map.get("TERM").?, "dumb")) try map.put("TERM", "xterm-256color");
    for (extra) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (eq == 0 or std.mem.indexOfScalar(u8, kv, 0) != null) continue;
        try map.put(kv[0..eq], kv[eq + 1 ..]);
    }
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var it = map.iterator();
    while (it.next()) |e| {
        try list.append(arena, try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }, 0));
    }
    try list.append(arena, null);
    return list.items[0 .. list.items.len - 1 :null];
}

// glibc and macOS declare the request as unsigned long (musl: int; passing
// a zero-extended value is correct for all three).
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

// std lacks the tty ioctls for Darwin; values from <sys/ttycom.h>:
// _IO('t', 97), _IOW('t', 103, struct winsize), _IOR('t', 104, struct winsize).
const tiocsctty: c_ulong = if (builtin.os.tag == .linux) posix.T.IOCSCTTY else 0x20007461;
const tiocswinsz: c_ulong = if (builtin.os.tag == .linux) posix.T.IOCSWINSZ else 0x80087467;
const tiocgwinsz: c_ulong = if (builtin.os.tag == .linux) posix.T.IOCGWINSZ else 0x40087468;

fn setCloexec(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFD, 0) catch return;
    _ = posix.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC) catch {};
}

pub fn setNonblock(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return;
    const nb: usize = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    _ = posix.fcntl(fd, posix.F.SETFL, flags | nb) catch {};
}

fn childExec(
    master: posix.fd_t,
    slave: posix.fd_t,
    exe: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
) noreturn {
    _ = std.c.setsid();
    _ = ioctl(slave, tiocsctty, @as(c_int, 0));
    _ = std.c.dup2(slave, 0);
    _ = std.c.dup2(slave, 1);
    _ = std.c.dup2(slave, 2);
    if (slave > 2) _ = std.c.close(slave);
    _ = std.c.close(master);
    // The daemon ignores SIGPIPE; ignored dispositions survive exec.
    const dfl: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    for ([_]u8{ posix.SIG.PIPE, posix.SIG.CHLD, posix.SIG.INT, posix.SIG.QUIT, posix.SIG.TERM, posix.SIG.HUP, posix.SIG.TSTP, posix.SIG.TTIN, posix.SIG.TTOU }) |sig|
        posix.sigaction(sig, &dfl, null);
    const empty = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
    if (cwd) |c| _ = std.c.chdir(c);
    _ = std.c.execve(exe, argv, envp);
    const msg = "wmuxd-remote: exec failed\r\n";
    _ = std.c.write(2, msg, msg.len);
    std.c._exit(127);
}

pub fn setSize(master: posix.fd_t, size: Size) void {
    var ws: posix.winsize = .{ .col = size.cols, .row = size.rows, .xpixel = 0, .ypixel = 0 };
    _ = ioctl(master, tiocswinsz, &ws);
}

pub fn getSize(fd: posix.fd_t) ?Size {
    var ws: posix.winsize = undefined;
    if (ioctl(fd, tiocgwinsz, &ws) != 0) return null;
    return .{ .cols = ws.col, .rows = ws.row };
}

pub const Exit = struct {
    code: ?i64 = null,
    signal: ?i64 = null,
};

/// Non-blocking reap. Null while the child is still running; a child that
/// is already gone (ECHILD) reports an unknown exit.
pub fn tryReap(pid: posix.pid_t) ?Exit {
    var status: c_int = 0;
    const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (r == 0) return null;
    if (r < 0) return .{};
    return decodeStatus(@bitCast(status));
}

pub fn decodeStatus(status: u32) Exit {
    if (posix.W.IFEXITED(status)) return .{ .code = posix.W.EXITSTATUS(status) };
    if (posix.W.IFSIGNALED(status)) return .{ .signal = posix.W.TERMSIG(status) };
    return .{};
}

/// Signals the session's process group (the child is a session leader).
pub fn killGroup(pid: posix.pid_t, sig: u8) void {
    if (pid <= 0) return;
    if (std.c.kill(-pid, sig) != 0) _ = std.c.kill(pid, sig);
}

const testing = std.testing;

test "unit: remote-daemon: login shell helpers" {
    try testing.expect(pickShell("") == null);
    try testing.expect(pickShell("bash") == null);
    try testing.expectEqualStrings("/bin/zsh", pickShell("/bin/zsh").?);
    const a0 = try loginArgv0(testing.allocator, "/usr/local/bin/fish");
    defer testing.allocator.free(a0);
    try testing.expectEqualStrings("-fish", a0);
    try testing.expect(loginShell()[0] == '/');
}

test "unit: remote-daemon: executables resolve on PATH" {
    const gpa = testing.allocator;
    const sh = try resolveExecutable(gpa, "sh", "/nonexistent:/bin:/usr/bin");
    defer gpa.free(sh);
    try testing.expect(std.mem.endsWith(u8, sh, "/sh"));
    const abs = try resolveExecutable(gpa, "/bin/sh", null);
    defer gpa.free(abs);
    try testing.expectEqualStrings("/bin/sh", abs);
    try testing.expectError(error.FileNotFound, resolveExecutable(gpa, "./definitely-not-here-wmux", null));
    try testing.expectError(error.FileNotFound, resolveExecutable(gpa, "definitely-not-here-wmux", "/nonexistent"));
    try testing.expectError(error.FileNotFound, resolveExecutable(gpa, "", null));
}

test "unit: remote-daemon: spawn runs a command on a PTY with the requested size" {
    const gpa = testing.allocator;
    const sp = try spawn(gpa, .{
        .argv = &.{ "/bin/sh", "-c", "stty size; echo \"v=$WMUX_T\"; exit 3" },
        .env = &.{"WMUX_T=☃"},
        .size = .{ .cols = 91, .rows = 33 },
    });
    defer posix.close(sp.master);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var exit: ?Exit = null;
    var tries: usize = 0;
    while (tries < 500) : (tries += 1) {
        var fds = [_]posix.pollfd{.{ .fd = sp.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 20);
        var buf: [4096]u8 = undefined;
        const n = posix.read(sp.master, &buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => break, // EIO: slave closed
        };
        try out.appendSlice(gpa, buf[0..n]);
        if (exit == null) exit = tryReap(sp.pid);
        if (exit != null and n == 0) break;
    }
    if (exit == null) {
        while (exit == null) : (std.Thread.sleep(5 * std.time.ns_per_ms)) exit = tryReap(sp.pid);
    }
    try testing.expectEqual(@as(?i64, 3), exit.?.code);
    try testing.expect(std.mem.indexOf(u8, out.items, "33 91") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "v=☃") != null);
}
