//! OS boundary of the CLI (ADR-4.5, ADR-12.1): every effect the pure layers
//! need (pipe connections, files, clock, process spawning, console and
//! registry queries) goes through `Platform`, so discovery, the client, the
//! launch waiter and the commands are tested against `fake.zig`. `native()`
//! returns the real implementation: Win32 named pipes through `win.zig` on
//! Windows; elsewhere pipes report `error.Unsupported` and the rest maps to
//! std.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("wmux_proto");
const Allocator = std.mem.Allocator;

pub const ConnectError = error{
    /// No pipe with that name (ERROR_FILE_NOT_FOUND).
    NotFound,
    /// Every instance stayed busy for the whole connect timeout.
    Busy,
    AccessDenied,
    /// The pipe server process does not belong to the caller's user SID.
    ForeignOwner,
    Timeout,
    /// Named pipes do not exist on this OS.
    Unsupported,
    Unexpected,
    OutOfMemory,
};

pub const WriteError = error{ Timeout, Closed, Unexpected };
pub const ReadError = error{ Timeout, Unexpected };

/// One connected byte stream (a named-pipe client handle on Windows).
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, bytes: []const u8, timeout_ms: u32) WriteError!void,
        /// Reads at most `buf.len` bytes; 0 means the peer closed.
        read: *const fn (ptr: *anyopaque, buf: []u8, timeout_ms: u32) ReadError!usize,
        /// PID of the pipe server, when the OS reports it.
        serverPid: *const fn (ptr: *anyopaque) ?u32,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn write(t: Transport, bytes: []const u8, timeout_ms: u32) WriteError!void {
        return t.vtable.write(t.ptr, bytes, timeout_ms);
    }
    pub fn read(t: Transport, buf: []u8, timeout_ms: u32) ReadError!usize {
        return t.vtable.read(t.ptr, buf, timeout_ms);
    }
    pub fn serverPid(t: Transport) ?u32 {
        return t.vtable.serverPid(t.ptr);
    }
    pub fn close(t: Transport) void {
        t.vtable.close(t.ptr);
    }
};

/// Existence of a pipe name without connecting (socket-status).
pub const PipeState = enum { present, absent, other };

pub const PolicyHive = enum { hklm, hkcu };

/// A managed-policy registry value (`Software\Policies\wmux\SocketControlMode`).
pub const PolicyValue = union(enum) {
    absent,
    /// REG_SZ contents (caller frees).
    string: []u8,
    /// Present with a non-string type.
    malformed,
};

pub const SpawnError = error{ SpawnFailed, OutOfMemory };
pub const StdinError = error{ TooLarge, ReadFailed, OutOfMemory };

pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Opens `path` (a full `\\.\pipe\...` path), retrying while busy for
        /// up to `timeout_ms`, and verifies the server's owner before
        /// returning.
        connect: *const fn (ptr: *anyopaque, gpa: Allocator, path: []const u8, timeout_ms: u32) ConnectError!Transport,
        pipeState: *const fn (ptr: *anyopaque, gpa: Allocator, path: []const u8) PipeState,
        /// Names under `\\.\pipe\` (bare or full); caller frees each and the slice.
        enumeratePipes: *const fn (ptr: *anyopaque, gpa: Allocator) Allocator.Error![][]u8,
        /// Whole file, or null when missing, unreadable or larger than `max`.
        readFile: *const fn (ptr: *anyopaque, gpa: Allocator, path: []const u8, max: usize) ?[]u8,
        pathExists: *const fn (ptr: *anyopaque, path: []const u8) bool,
        readStdin: *const fn (ptr: *anyopaque, gpa: Allocator, max: usize) StdinError![]u8,
        /// Current user's SID string (`S-1-5-21-...`); null off Windows.
        userSid: *const fn (ptr: *anyopaque, gpa: Allocator) ?[]u8,
        sessionId: *const fn (ptr: *anyopaque) ?u32,
        selfExePath: *const fn (ptr: *anyopaque, gpa: Allocator) ?[]u8,
        cwd: *const fn (ptr: *anyopaque, gpa: Allocator) ?[]u8,
        /// Starts `argv` detached: no inherited handles, no console, not
        /// waited for.
        spawnDetached: *const fn (ptr: *anyopaque, gpa: Allocator, argv: []const []const u8, env: *const std.process.EnvMap) SpawnError!void,
        /// Runs `argv` with inherited std handles and returns its exit code.
        runInherit: *const fn (ptr: *anyopaque, gpa: Allocator, argv: []const []const u8, env: *const std.process.EnvMap) SpawnError!u8,
        sleepMs: *const fn (ptr: *anyopaque, ms: u64) void,
        /// Monotonic milliseconds.
        nowMs: *const fn (ptr: *anyopaque) i64,
        /// stdin and stdout are both a console/TTY (ADR-4.6).
        isInteractive: *const fn (ptr: *anyopaque) bool,
        /// stdout is a console/TTY (colors in `welcome`).
        stdoutIsTerminal: *const fn (ptr: *anyopaque) bool,
        prefersLightTheme: *const fn (ptr: *anyopaque) bool,
        policy: *const fn (ptr: *anyopaque, gpa: Allocator, hive: PolicyHive) PolicyValue,
        /// `AllowSetForegroundWindow(pid)` before a focus-granting request.
        allowForeground: *const fn (ptr: *anyopaque, pid: u32) void,
    };

    pub fn connect(p: Platform, gpa: Allocator, path: []const u8, timeout_ms: u32) ConnectError!Transport {
        return p.vtable.connect(p.ptr, gpa, path, timeout_ms);
    }
    pub fn pipeState(p: Platform, gpa: Allocator, path: []const u8) PipeState {
        return p.vtable.pipeState(p.ptr, gpa, path);
    }
    pub fn enumeratePipes(p: Platform, gpa: Allocator) Allocator.Error![][]u8 {
        return p.vtable.enumeratePipes(p.ptr, gpa);
    }
    pub fn readFile(p: Platform, gpa: Allocator, path: []const u8, max: usize) ?[]u8 {
        return p.vtable.readFile(p.ptr, gpa, path, max);
    }
    pub fn pathExists(p: Platform, path: []const u8) bool {
        return p.vtable.pathExists(p.ptr, path);
    }
    pub fn readStdin(p: Platform, gpa: Allocator, max: usize) StdinError![]u8 {
        return p.vtable.readStdin(p.ptr, gpa, max);
    }
    pub fn userSid(p: Platform, gpa: Allocator) ?[]u8 {
        return p.vtable.userSid(p.ptr, gpa);
    }
    pub fn sessionId(p: Platform) ?u32 {
        return p.vtable.sessionId(p.ptr);
    }
    pub fn selfExePath(p: Platform, gpa: Allocator) ?[]u8 {
        return p.vtable.selfExePath(p.ptr, gpa);
    }
    pub fn cwd(p: Platform, gpa: Allocator) ?[]u8 {
        return p.vtable.cwd(p.ptr, gpa);
    }
    pub fn spawnDetached(p: Platform, gpa: Allocator, argv: []const []const u8, env: *const std.process.EnvMap) SpawnError!void {
        return p.vtable.spawnDetached(p.ptr, gpa, argv, env);
    }
    pub fn runInherit(p: Platform, gpa: Allocator, argv: []const []const u8, env: *const std.process.EnvMap) SpawnError!u8 {
        return p.vtable.runInherit(p.ptr, gpa, argv, env);
    }
    pub fn sleepMs(p: Platform, ms: u64) void {
        p.vtable.sleepMs(p.ptr, ms);
    }
    pub fn nowMs(p: Platform) i64 {
        return p.vtable.nowMs(p.ptr);
    }
    pub fn isInteractive(p: Platform) bool {
        return p.vtable.isInteractive(p.ptr);
    }
    pub fn stdoutIsTerminal(p: Platform) bool {
        return p.vtable.stdoutIsTerminal(p.ptr);
    }
    pub fn prefersLightTheme(p: Platform) bool {
        return p.vtable.prefersLightTheme(p.ptr);
    }
    pub fn policy(p: Platform, gpa: Allocator, hive: PolicyHive) PolicyValue {
        return p.vtable.policy(p.ptr, gpa, hive);
    }
    pub fn allowForeground(p: Platform, pid: u32) void {
        p.vtable.allowForeground(p.ptr, pid);
    }
};

/// Reason text for a connect failure ("Tried:" lines, error messages).
pub fn connectErrorText(err: ConnectError) []const u8 {
    return switch (err) {
        error.NotFound => "not found",
        error.Busy => "busy (all pipe instances in use)",
        error.AccessDenied => "access denied",
        error.ForeignOwner => "server not owned by the current user",
        error.Timeout => "timed out",
        error.Unsupported => "named pipes are only available on Windows",
        error.Unexpected => "connect failed",
        error.OutOfMemory => "out of memory",
    };
}

// ----- native implementation -----

const win = if (builtin.os.tag == .windows) @import("win.zig") else struct {};
const is_windows = builtin.os.tag == .windows;

var native_state: u8 = 0;

/// The real OS implementation.
pub fn native() Platform {
    return .{ .ptr = &native_state, .vtable = &native_vtable };
}

const native_vtable: Platform.VTable = .{
    .connect = nativeConnect,
    .pipeState = nativePipeState,
    .enumeratePipes = nativeEnumeratePipes,
    .readFile = nativeReadFile,
    .pathExists = nativePathExists,
    .readStdin = nativeReadStdin,
    .userSid = nativeUserSid,
    .sessionId = nativeSessionId,
    .selfExePath = nativeSelfExePath,
    .cwd = nativeCwd,
    .spawnDetached = nativeSpawnDetached,
    .runInherit = nativeRunInherit,
    .sleepMs = nativeSleepMs,
    .nowMs = nativeNowMs,
    .isInteractive = nativeIsInteractive,
    .stdoutIsTerminal = nativeStdoutIsTerminal,
    .prefersLightTheme = nativePrefersLight,
    .policy = nativePolicy,
    .allowForeground = nativeAllowForeground,
};

fn nativeConnect(_: *anyopaque, gpa: Allocator, path: []const u8, timeout_ms: u32) ConnectError!Transport {
    if (!is_windows) return error.Unsupported;
    return win.PipeTransport.connect(gpa, path, timeout_ms);
}

fn nativePipeState(_: *anyopaque, gpa: Allocator, path: []const u8) PipeState {
    if (!is_windows) return .absent;
    return win.pipeState(gpa, path);
}

fn nativeEnumeratePipes(_: *anyopaque, gpa: Allocator) Allocator.Error![][]u8 {
    if (!is_windows) return gpa.alloc([]u8, 0);
    return win.enumeratePipes(gpa, proto.pipe_name.name_prefix);
}

fn nativeReadFile(_: *anyopaque, gpa: Allocator, path: []const u8, max: usize) ?[]u8 {
    return std.fs.cwd().readFileAlloc(gpa, path, max) catch null;
}

fn nativePathExists(_: *anyopaque, path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn nativeReadStdin(_: *anyopaque, gpa: Allocator, max: usize) StdinError![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = std.fs.File.stdin().reader(&buf);
    return reader.interface.allocRemaining(gpa, .limited(max)) catch |err| switch (err) {
        error.StreamTooLong => error.TooLarge,
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => error.ReadFailed,
    };
}

fn nativeUserSid(_: *anyopaque, gpa: Allocator) ?[]u8 {
    if (!is_windows) return null;
    return win.currentUserSidString(gpa);
}

fn nativeSessionId(_: *anyopaque) ?u32 {
    if (!is_windows) return null;
    return win.currentSessionId();
}

fn nativeSelfExePath(_: *anyopaque, gpa: Allocator) ?[]u8 {
    return std.fs.selfExePathAlloc(gpa) catch null;
}

fn nativeCwd(_: *anyopaque, gpa: Allocator) ?[]u8 {
    return std.process.getCwdAlloc(gpa) catch null;
}

fn nativeSpawnDetached(_: *anyopaque, gpa: Allocator, argv: []const []const u8, env: *const std.process.EnvMap) SpawnError!void {
    if (is_windows) return win.spawnDetached(gpa, argv, env);
    var child = std.process.Child.init(argv, gpa);
    child.env_map = env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.SpawnFailed;
}

fn nativeRunInherit(_: *anyopaque, gpa: Allocator, argv: []const []const u8, env: *const std.process.EnvMap) SpawnError!u8 {
    var child = std.process.Child.init(argv, gpa);
    child.env_map = env;
    const term = child.spawnAndWait() catch return error.SpawnFailed;
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn nativeSleepMs(_: *anyopaque, ms: u64) void {
    std.Thread.sleep(ms * std.time.ns_per_ms);
}

var native_timer: ?std.time.Timer = null;

fn nativeNowMs(_: *anyopaque) i64 {
    if (native_timer == null) native_timer = std.time.Timer.start() catch return std.time.milliTimestamp();
    return @intCast(native_timer.?.read() / std.time.ns_per_ms);
}

fn nativeIsInteractive(_: *anyopaque) bool {
    if (is_windows) return win.isConsole(win.STD_INPUT_HANDLE) and win.isConsole(win.STD_OUTPUT_HANDLE);
    return std.posix.isatty(std.posix.STDIN_FILENO) and std.posix.isatty(std.posix.STDOUT_FILENO);
}

fn nativeStdoutIsTerminal(_: *anyopaque) bool {
    if (is_windows) return win.isConsole(win.STD_OUTPUT_HANDLE);
    return std.posix.isatty(std.posix.STDOUT_FILENO);
}

fn nativePrefersLight(_: *anyopaque) bool {
    if (is_windows) return win.appsUseLightTheme();
    return false;
}

fn nativePolicy(_: *anyopaque, gpa: Allocator, hive: PolicyHive) PolicyValue {
    if (!is_windows) return .absent;
    return win.readPolicyString(gpa, hive == .hklm, "Software\\Policies\\wmux", "SocketControlMode");
}

fn nativeAllowForeground(_: *anyopaque, pid: u32) void {
    if (is_windows) win.allowSetForegroundWindow(pid);
}
