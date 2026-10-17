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
pub const WriteAtomicError = error{
    /// Another writer held `<file>.wmux-write.lock` for the whole wait.
    Locked,
    AccessDenied,
    WriteFailed,
    /// The platform has no atomic file writer (test fakes without one).
    Unsupported,
    OutOfMemory,
};

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

        // Optional entries (null in fakes that predate them; the wrappers
        // below fall back).

        /// stdin alone is a terminal: a console, or on Windows also an
        /// MSYS/Cygwin pty (cmux's "TTY stdin" test for commands that read
        /// stdin, such as `diff`, `todo set` and `paste`). Falls back to
        /// `isInteractive`.
        stdinIsTerminal: ?*const fn (ptr: *anyopaque) bool = null,
        /// Size in bytes of the regular file `path`; null when it is
        /// missing, not a regular file or cannot be inspected. Falls back
        /// to null.
        fileSize: ?*const fn (ptr: *anyopaque, path: []const u8) ?u64 = null,
        /// Creates parent directories and replaces `path` atomically under
        /// the sidecar lock `<file>.wmux-write.lock` (ADR-5.6), flushing the
        /// data first and keeping a symlink and the target's ACL/mode.
        /// Falls back to `error.Unsupported`.
        writeFileAtomic: ?*const fn (ptr: *anyopaque, gpa: Allocator, path: []const u8, bytes: []const u8) WriteAtomicError!void = null,
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
    pub fn stdinIsTerminal(p: Platform) bool {
        const f = p.vtable.stdinIsTerminal orelse return p.isInteractive();
        return f(p.ptr);
    }
    pub fn fileSize(p: Platform, path: []const u8) ?u64 {
        const f = p.vtable.fileSize orelse return null;
        return f(p.ptr, path);
    }
    pub fn writeFileAtomic(p: Platform, gpa: Allocator, path: []const u8, bytes: []const u8) WriteAtomicError!void {
        const f = p.vtable.writeFileAtomic orelse return error.Unsupported;
        return f(p.ptr, gpa, path, bytes);
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
    .stdinIsTerminal = nativeStdinIsTerminal,
    .fileSize = nativeFileSize,
    .writeFileAtomic = nativeWriteFileAtomic,
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

fn nativeStdinIsTerminal(_: *anyopaque) bool {
    // `File.isTty` accepts a console handle or, on Windows, a pipe named
    // like an MSYS/Cygwin pty (Git Bash in mintty); shell pipelines, files
    // and NUL are not terminals.
    return std.fs.File.stdin().isTty();
}

fn nativeFileSize(_: *anyopaque, path: []const u8) ?u64 {
    if (path.len == 0) return null;
    const st = std.fs.cwd().statFile(path) catch return null;
    if (st.kind != .file) return null;
    return st.size;
}

// ----- atomic file replacement (ADR-5.6) -----

/// Suffix of the sidecar lock next to the file being written.
pub const lock_suffix = ".wmux-write.lock";
/// How long a writer waits for another writer's sidecar lock.
pub const lock_timeout_ms: u32 = 5000;
const lock_retry_ms: u32 = 20;

pub fn lockPathAlloc(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ path, lock_suffix });
}

/// Temporary sibling of `path`: the same directory keeps the final rename
/// on one volume.
pub fn tempPathAlloc(gpa: Allocator, path: []const u8, nonce: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.wmux-tmp-{x:0>16}", .{ path, nonce });
}

fn nativeWriteFileAtomic(_: *anyopaque, gpa: Allocator, path: []const u8, bytes: []const u8) WriteAtomicError!void {
    return writeFileAtomicNative(gpa, path, bytes, lock_timeout_ms);
}

/// The native atomic writer with an explicit lock wait (tests shorten it):
/// resolve a symlink to its final target (the link survives), take the
/// sidecar lock of the target, write and flush a temporary sibling (POSIX:
/// with the old file's mode), then replace the target (Windows:
/// `ReplaceFileW`, which keeps the old file's ACL, owner and attributes;
/// `MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH)` for a new file or when the
/// volume cannot replace). The temporary file never outlives a failure.
pub fn writeFileAtomicNative(gpa: Allocator, path: []const u8, bytes: []const u8, timeout_ms: u32) WriteAtomicError!void {
    if (path.len == 0) return error.WriteFailed;
    const cwd = std.fs.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.makePath(d) catch |err| return mapFsError(err);
    const target = cwd.realpathAlloc(gpa, path) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, path),
        error.OutOfMemory => return error.OutOfMemory,
        error.AccessDenied => return error.AccessDenied,
        else => return error.WriteFailed,
    };
    defer gpa.free(target);
    const lock_path = try lockPathAlloc(gpa, target);
    defer gpa.free(lock_path);
    var lock = try SidecarLock.acquire(gpa, lock_path, timeout_ms);
    defer lock.release();

    const existing: ?std.fs.File.Stat = cwd.statFile(target) catch null;
    if (existing) |st| if (st.kind == .directory) return error.WriteFailed;
    var nonce: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&nonce));
    const tmp = try tempPathAlloc(gpa, target, nonce);
    defer gpa.free(tmp);
    writeTemp(tmp, bytes, existing) catch |err| {
        cwd.deleteFile(tmp) catch {};
        return err;
    };
    replaceWith(gpa, tmp, target, existing != null) catch |err| {
        cwd.deleteFile(tmp) catch {};
        return err;
    };
}

fn mapFsError(err: anyerror) WriteAtomicError {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.WriteFailed,
    };
}

fn writeTemp(tmp: []const u8, bytes: []const u8, existing: ?std.fs.File.Stat) WriteAtomicError!void {
    var f = std.fs.cwd().createFile(tmp, .{ .exclusive = true }) catch |err| return mapFsError(err);
    defer f.close();
    f.writeAll(bytes) catch |err| return mapFsError(err);
    if (!is_windows) {
        if (existing) |st| f.chmod(st.mode & 0o7777) catch {};
    }
    f.sync() catch |err| return mapFsError(err);
}

fn replaceWith(gpa: Allocator, tmp: []const u8, target: []const u8, existed: bool) WriteAtomicError!void {
    if (is_windows) return replaceWindows(gpa, tmp, target, existed);
    std.posix.rename(tmp, target) catch |err| return mapFsError(err);
    // Persist the rename itself (`iterate` opens a readable descriptor;
    // the default O_PATH one cannot be synced).
    const dir_path = std.fs.path.dirname(target) orelse ".";
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    std.posix.fsync(dir.fd) catch {};
}

const win_fs = if (is_windows) struct {
    const w = std.os.windows;
    const REPLACEFILE_WRITE_THROUGH: w.DWORD = 0x1;
    const REPLACEFILE_IGNORE_MERGE_ERRORS: w.DWORD = 0x2;
    extern "kernel32" fn ReplaceFileW(
        replaced: w.LPCWSTR,
        replacement: w.LPCWSTR,
        backup: ?w.LPCWSTR,
        flags: w.DWORD,
        exclude: ?*anyopaque,
        reserved: ?*anyopaque,
    ) callconv(.winapi) w.BOOL;
} else struct {};

fn wide(gpa: Allocator, path: []const u8) WriteAtomicError![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.WriteFailed,
    };
}

fn replaceWindows(gpa: Allocator, tmp: []const u8, target: []const u8, existed: bool) WriteAtomicError!void {
    const w = std.os.windows;
    const tmp_w = try wide(gpa, tmp);
    defer gpa.free(tmp_w);
    const target_w = try wide(gpa, target);
    defer gpa.free(target_w);
    if (existed) {
        const flags = win_fs.REPLACEFILE_WRITE_THROUGH | win_fs.REPLACEFILE_IGNORE_MERGE_ERRORS;
        if (win_fs.ReplaceFileW(target_w, tmp_w, null, flags, null, null) != 0) return;
    }
    if (w.kernel32.MoveFileExW(tmp_w, target_w, w.MOVEFILE_REPLACE_EXISTING | w.MOVEFILE_WRITE_THROUGH) == 0) {
        return switch (w.kernel32.GetLastError()) {
            .ACCESS_DENIED, .SHARING_VIOLATION => error.AccessDenied,
            else => error.WriteFailed,
        };
    }
}

/// `<file>.wmux-write.lock` (ADR-5.6). Windows: `CREATE_ALWAYS`, share 0,
/// `FILE_FLAG_DELETE_ON_CLOSE`, so the lock disappears with its holder even
/// after a crash. POSIX: an exclusive `flock` on a file that stays in place,
/// so every writer locks the same inode.
pub const SidecarLock = struct {
    handle: std.fs.File.Handle,

    pub fn acquire(gpa: Allocator, path: []const u8, timeout_ms: u32) WriteAtomicError!SidecarLock {
        var waited: u32 = 0;
        while (true) {
            if (try tryAcquire(gpa, path)) |l| return l;
            if (waited >= timeout_ms) return error.Locked;
            std.Thread.sleep(@as(u64, lock_retry_ms) * std.time.ns_per_ms);
            waited += lock_retry_ms;
        }
    }

    /// Null while another writer holds the lock.
    pub fn tryAcquire(gpa: Allocator, path: []const u8) WriteAtomicError!?SidecarLock {
        if (is_windows) {
            const w = std.os.windows;
            const path_w = try wide(gpa, path);
            defer gpa.free(path_w);
            const h = w.kernel32.CreateFileW(path_w, w.GENERIC_READ | w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL | w.FILE_FLAG_DELETE_ON_CLOSE, null);
            if (h != w.INVALID_HANDLE_VALUE) return .{ .handle = h };
            return switch (w.kernel32.GetLastError()) {
                .SHARING_VIOLATION => null,
                // A lock file whose deletion is pending (its holder just
                // closed it) also reports access denied.
                .ACCESS_DENIED => if (nativePathExists(&native_state, path)) null else error.AccessDenied,
                else => error.WriteFailed,
            };
        }
        const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |err| return mapFsError(err);
        const locked = f.tryLock(.exclusive) catch false;
        if (!locked) {
            f.close();
            return null;
        }
        return .{ .handle = f.handle };
    }

    pub fn release(self: *SidecarLock) void {
        const f: std.fs.File = .{ .handle = self.handle };
        f.close();
    }
};

const testing = std.testing;

fn tmpPath(gpa: Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const base = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, name });
}

fn readAll(gpa: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(gpa, path, 64 << 20);
}

fn expectOnly(tmp: *std.testing.TmpDir, sub: []const u8, want: []const []const u8) !void {
    var dir = try tmp.dir.openDir(sub, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next()) |e| {
        n += 1;
        if (std.mem.endsWith(u8, e.name, lock_suffix)) continue;
        var found = false;
        for (want) |x| found = found or std.mem.eql(u8, x, e.name);
        if (!found) {
            std.debug.print("unexpected file left behind: {s}\n", .{e.name});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(n >= want.len);
}

test "unit: cli-platform: lock and temp names sit next to the file" {
    const gpa = testing.allocator;
    const l = try lockPathAlloc(gpa, "C:\\cfg\\wmux.json");
    defer gpa.free(l);
    try testing.expectEqualStrings("C:\\cfg\\wmux.json.wmux-write.lock", l);
    const t = try tempPathAlloc(gpa, "/x/\u{65e5}.json", 0xab);
    defer gpa.free(t);
    try testing.expectEqualStrings("/x/\u{65e5}.json.wmux-tmp-00000000000000ab", t);
    const e = try lockPathAlloc(gpa, "");
    defer gpa.free(e);
    try testing.expectEqualStrings(lock_suffix, e);
}

test "unit: cli-platform: atomic write creates parents and replaces content" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(gpa, &tmp, "a/b/\u{65e5}\u{672c} \u{2713}.json");
    defer gpa.free(path);
    try writeFileAtomicNative(gpa, path, "{\"v\":1}", 1000);
    const one = try readAll(gpa, path);
    defer gpa.free(one);
    try testing.expectEqualStrings("{\"v\":1}", one);
    try writeFileAtomicNative(gpa, path, "", 1000);
    const two = try readAll(gpa, path);
    defer gpa.free(two);
    try testing.expectEqualStrings("", two);
    const big = try gpa.alloc(u8, 3 << 20);
    defer gpa.free(big);
    @memset(big, 'z');
    try writeFileAtomicNative(gpa, path, big, 1000);
    try testing.expectEqual(@as(?u64, big.len), nativeFileSize(&native_state, path));
    try expectOnly(&tmp, "a/b", &.{"\u{65e5}\u{672c} \u{2713}.json"});
}

test "unit: cli-platform: atomic write waits for the sidecar lock, then gives up" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(gpa, &tmp, "wmux.json");
    defer gpa.free(path);
    try writeFileAtomicNative(gpa, path, "old", 1000);
    const lock_path = try lockPathAlloc(gpa, path);
    defer gpa.free(lock_path);
    var held = (try SidecarLock.tryAcquire(gpa, lock_path)).?;
    try testing.expectEqual(@as(?SidecarLock, null), try SidecarLock.tryAcquire(gpa, lock_path));
    try testing.expectError(error.Locked, writeFileAtomicNative(gpa, path, "new", 60));
    held.release();
    const kept = try readAll(gpa, path);
    defer gpa.free(kept);
    try testing.expectEqualStrings("old", kept);
    try writeFileAtomicNative(gpa, path, "new", 60);
    const now = try readAll(gpa, path);
    defer gpa.free(now);
    try testing.expectEqualStrings("new", now);
    try expectOnly(&tmp, ".", &.{"wmux.json"});
}

test "unit: cli-platform: atomic write keeps a symlink and the file mode" {
    if (is_windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("real");
    try tmp.dir.writeFile(.{ .sub_path = "real/cmux.json", .data = "{}" });
    {
        var f = try tmp.dir.openFile("real/cmux.json", .{});
        defer f.close();
        try f.chmod(0o640);
    }
    try tmp.dir.symLink("real/cmux.json", "link.json", .{});
    const link = try tmpPath(gpa, &tmp, "link.json");
    defer gpa.free(link);
    try writeFileAtomicNative(gpa, link, "{\"a\":1}", 1000);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("real/cmux.json", try tmp.dir.readLink("link.json", &buf));
    const st = try tmp.dir.statFile("real/cmux.json");
    try testing.expectEqual(@as(std.fs.File.Mode, 0o640), st.mode & 0o777);
    const got = try tmp.dir.readFileAlloc(gpa, "real/cmux.json", 1024);
    defer gpa.free(got);
    try testing.expectEqualStrings("{\"a\":1}", got);
    try expectOnly(&tmp, "real", &.{"cmux.json"});
}

test "unit: cli-platform: atomic write refuses empty paths and directories" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("d");
    const dir_path = try tmpPath(gpa, &tmp, "d");
    defer gpa.free(dir_path);
    try testing.expectError(error.WriteFailed, writeFileAtomicNative(gpa, "", "x", 10));
    try testing.expectError(error.WriteFailed, writeFileAtomicNative(gpa, dir_path, "x", 10));
    try expectOnly(&tmp, "d", &.{});
}

test "unit: cli-platform: file size of files, directories and missing paths" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "f.bin", .data = "12345" });
    try tmp.dir.makePath("sub");
    const f = try tmpPath(gpa, &tmp, "f.bin");
    defer gpa.free(f);
    const d = try tmpPath(gpa, &tmp, "sub");
    defer gpa.free(d);
    const missing = try tmpPath(gpa, &tmp, "nope");
    defer gpa.free(missing);
    try testing.expectEqual(@as(?u64, 5), nativeFileSize(&native_state, f));
    try testing.expectEqual(@as(?u64, null), nativeFileSize(&native_state, d));
    try testing.expectEqual(@as(?u64, null), nativeFileSize(&native_state, missing));
    try testing.expectEqual(@as(?u64, null), nativeFileSize(&native_state, ""));
}

test "unit: cli-platform: optional entries fall back on platforms without them" {
    const fake = @import("fake.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fp = fake.Platform.init(arena_state.allocator());
    const p = fp.platform();
    try testing.expect(!p.stdinIsTerminal());
    fp.interactive = true;
    try testing.expect(p.stdinIsTerminal());
    try testing.expectEqual(@as(?u64, null), p.fileSize("C:\\x"));
    try testing.expectError(error.Unsupported, p.writeFileAtomic(testing.allocator, "C:\\x", "y"));
    // The native platform implements all of them.
    try testing.expect(native().vtable.stdinIsTerminal != null);
    try testing.expect(native().vtable.fileSize != null);
    try testing.expect(native().vtable.writeFileAtomic != null);
}
