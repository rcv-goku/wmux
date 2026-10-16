//! Minimal Win32 layer of the CLI (ADR-4.1: the CLI imports only std,
//! wmux_proto and these externs). Windows only; platform.zig imports it
//! behind `builtin.os.tag == .windows`. Declarations std already carries are
//! reused from `std.os.windows`; only the missing ones are declared here.
//!
//! - Named-pipe client: `CreateFileW` (overlapped, identification-level
//!   impersonation only) with `WaitNamedPipeW(250)` retries on
//!   `ERROR_PIPE_BUSY` up to the connect timeout, then a server-owner check
//!   (`GetNamedPipeServerProcessId` + token user SID compare) before any byte
//!   is sent. Reads and writes are overlapped with a wait timeout and
//!   `CancelIoEx` on expiry.
//! - SID string, logon session, console detection, VT mode, `WriteConsoleW`,
//!   detached process creation, pipe enumeration, policy registry reads.

const std = @import("std");
const w = std.os.windows;
const k32 = w.kernel32;
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const utf8 = proto.utf8;
const platform_mod = @import("platform.zig");

pub const STD_INPUT_HANDLE = w.STD_INPUT_HANDLE;
pub const STD_OUTPUT_HANDLE = w.STD_OUTPUT_HANDLE;
pub const STD_ERROR_HANDLE = w.STD_ERROR_HANDLE;

// ----- externs std does not declare -----
extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: w.LPCWSTR, nTimeOut: w.DWORD) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetNamedPipeServerProcessId(Pipe: w.HANDLE, ServerProcessId: *w.ULONG) callconv(.winapi) w.BOOL;
extern "kernel32" fn OpenProcess(dwDesiredAccess: w.DWORD, bInheritHandle: w.BOOL, dwProcessId: w.DWORD) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn ProcessIdToSessionId(dwProcessId: w.DWORD, pSessionId: *w.DWORD) callconv(.winapi) w.BOOL;
extern "kernel32" fn FindNextFileW(hFindFile: w.HANDLE, lpFindFileData: *w.WIN32_FIND_DATAW) callconv(.winapi) w.BOOL;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn OpenProcessToken(ProcessHandle: w.HANDLE, DesiredAccess: w.DWORD, TokenHandle: *w.HANDLE) callconv(.winapi) w.BOOL;
extern "advapi32" fn GetTokenInformation(TokenHandle: w.HANDLE, TokenInformationClass: c_int, TokenInformation: ?*anyopaque, TokenInformationLength: w.DWORD, ReturnLength: *w.DWORD) callconv(.winapi) w.BOOL;
extern "advapi32" fn EqualSid(pSid1: *anyopaque, pSid2: *anyopaque) callconv(.winapi) w.BOOL;
extern "advapi32" fn ConvertSidToStringSidW(Sid: *anyopaque, StringSid: *?w.LPWSTR) callconv(.winapi) w.BOOL;
extern "user32" fn AllowSetForegroundWindow(dwProcessId: w.DWORD) callconv(.winapi) w.BOOL;

const GENERIC_READ: w.DWORD = 0x80000000;
const GENERIC_WRITE: w.DWORD = 0x40000000;
const OPEN_EXISTING: w.DWORD = 3;
const FILE_FLAG_OVERLAPPED: w.DWORD = 0x40000000;
const SECURITY_SQOS_PRESENT: w.DWORD = 0x00100000;
const SECURITY_IDENTIFICATION: w.DWORD = 0x00010000;
const PROCESS_QUERY_LIMITED_INFORMATION: w.DWORD = 0x1000;
const TOKEN_QUERY: w.DWORD = 0x0008;
const TokenUser: c_int = 1;
const CREATE_EVENT_MANUAL_RESET: w.DWORD = 0x1;
const EVENT_ALL_ACCESS: w.DWORD = 0x1F0003;
const ENABLE_PROCESSED_OUTPUT: w.DWORD = 0x1;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: w.DWORD = 0x4;
const RRF_RT_REG_SZ: w.DWORD = 0x2;
const RRF_RT_REG_EXPAND_SZ: w.DWORD = 0x4;
const RRF_RT_REG_DWORD: w.DWORD = 0x10;
const RRF_RT_ANY: w.DWORD = 0xffff;
const RRF_NOEXPAND: w.DWORD = 0x10000000;
const REG_SZ: w.DWORD = 1;
const REG_EXPAND_SZ: w.DWORD = 2;
const pipe_busy_wait_ms: w.DWORD = 250;
/// Longest pipe path in UTF-16 units (`\\.\pipe\` + 256).
const max_path_units = 300;

fn lastError() w.Win32Error {
    return k32.GetLastError();
}

fn widen(gpa: Allocator, s: []const u8) error{ InvalidUtf8, TooLong, OutOfMemory }![:0]u16 {
    return utf8.utf8ToUtf16LeAllocZ(gpa, s, max_path_units);
}

// ----- SIDs -----

/// The token user SID of `process`, copied into `buf`.
fn tokenUserSid(process: w.HANDLE, buf: []align(8) u8) ?*anyopaque {
    var token: w.HANDLE = undefined;
    if (OpenProcessToken(process, TOKEN_QUERY, &token) == 0) return null;
    defer w.CloseHandle(token);
    var len: w.DWORD = 0;
    if (GetTokenInformation(token, TokenUser, buf.ptr, @intCast(buf.len), &len) == 0) return null;
    // TOKEN_USER { SID_AND_ATTRIBUTES { PSID Sid; DWORD Attributes } }
    const sid_ptr: *const ?*anyopaque = @ptrCast(buf.ptr);
    return sid_ptr.*;
}

/// `S-1-5-21-...` of the current user (caller frees).
pub fn currentUserSidString(gpa: Allocator) ?[]u8 {
    var buf: [256]u8 align(8) = undefined;
    const sid = tokenUserSid(k32.GetCurrentProcess(), &buf) orelse return null;
    var wide: ?w.LPWSTR = null;
    if (ConvertSidToStringSidW(sid, &wide) == 0) return null;
    defer _ = LocalFree(@ptrCast(wide));
    const span = utf8.spanUtf16Z(wide.?, 256) catch return null;
    return utf8.utf16LeToUtf8Alloc(gpa, span, 512) catch null;
}

pub fn currentSessionId() ?u32 {
    var s: w.DWORD = 0;
    if (ProcessIdToSessionId(w.GetCurrentProcessId(), &s) == 0) return null;
    return s;
}

/// True when the pipe's server process runs as the current user.
fn serverIsCurrentUser(pipe: w.HANDLE) bool {
    var pid: w.ULONG = 0;
    if (GetNamedPipeServerProcessId(pipe, &pid) == 0) return false;
    const proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
    defer w.CloseHandle(proc);
    var server_buf: [256]u8 align(8) = undefined;
    var own_buf: [256]u8 align(8) = undefined;
    const server_sid = tokenUserSid(proc, &server_buf) orelse return false;
    const own_sid = tokenUserSid(k32.GetCurrentProcess(), &own_buf) orelse return false;
    return EqualSid(server_sid, own_sid) != 0;
}

// ----- named-pipe transport -----

pub const PipeTransport = struct {
    gpa: Allocator,
    handle: w.HANDLE,
    event: w.HANDLE,

    pub fn connect(gpa: Allocator, path: []const u8, timeout_ms: u32) platform_mod.ConnectError!platform_mod.Transport {
        const name = widen(gpa, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotFound,
        };
        defer gpa.free(name);
        var timer = std.time.Timer.start() catch return error.Unexpected;
        const handle = while (true) {
            const h = k32.CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, null);
            if (h != w.INVALID_HANDLE_VALUE) break h;
            switch (lastError()) {
                .PIPE_BUSY => {
                    const elapsed: u64 = timer.read() / std.time.ns_per_ms;
                    if (elapsed >= timeout_ms) return error.Busy;
                    const left: w.DWORD = @intCast(@min(timeout_ms - elapsed, pipe_busy_wait_ms));
                    // Returns early when an instance frees up; a timeout just loops.
                    _ = WaitNamedPipeW(name, @max(left, 1));
                },
                .FILE_NOT_FOUND, .PATH_NOT_FOUND, .BAD_PATHNAME, .INVALID_NAME => return error.NotFound,
                .ACCESS_DENIED => return error.AccessDenied,
                .SEM_TIMEOUT => return error.Timeout,
                else => return error.Unexpected,
            }
        };
        errdefer w.CloseHandle(handle);
        if (!serverIsCurrentUser(handle)) return error.ForeignOwner;
        const event = k32.CreateEventExW(null, null, CREATE_EVENT_MANUAL_RESET, EVENT_ALL_ACCESS) orelse return error.Unexpected;
        errdefer w.CloseHandle(event);
        const self = gpa.create(PipeTransport) catch return error.OutOfMemory;
        self.* = .{ .gpa = gpa, .handle = handle, .event = event };
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: platform_mod.Transport.VTable = .{
        .write = write,
        .read = read,
        .serverPid = serverPid,
        .close = close,
    };

    fn from(ptr: *anyopaque) *PipeTransport {
        return @ptrCast(@alignCast(ptr));
    }

    /// Waits for an overlapped operation; null on timeout (cancelled).
    fn finish(self: *PipeTransport, ov: *w.OVERLAPPED, timeout_ms: u32) error{ Broken, Failed }!?w.DWORD {
        var n: w.DWORD = 0;
        if (k32.WaitForSingleObject(self.event, timeout_ms) == w.WAIT_TIMEOUT) {
            _ = k32.CancelIoEx(self.handle, ov);
            if (k32.GetOverlappedResult(self.handle, ov, &n, 1) != 0 and n > 0) return n;
            return null;
        }
        if (k32.GetOverlappedResult(self.handle, ov, &n, 0) == 0) {
            return switch (lastError()) {
                .BROKEN_PIPE, .PIPE_NOT_CONNECTED, .NO_DATA => error.Broken,
                .MORE_DATA => n,
                else => error.Failed,
            };
        }
        return n;
    }

    fn write(ptr: *anyopaque, bytes: []const u8, timeout_ms: u32) platform_mod.WriteError!void {
        const self = from(ptr);
        var off: usize = 0;
        while (off < bytes.len) {
            var ov = std.mem.zeroes(w.OVERLAPPED);
            ov.hEvent = self.event;
            const chunk: w.DWORD = @intCast(@min(bytes.len - off, 1 << 20));
            if (k32.WriteFile(self.handle, bytes[off..].ptr, chunk, null, &ov) == 0) {
                switch (lastError()) {
                    .IO_PENDING => {},
                    .BROKEN_PIPE, .NO_DATA, .PIPE_NOT_CONNECTED => return error.Closed,
                    else => return error.Unexpected,
                }
            }
            const n = (self.finish(&ov, timeout_ms) catch |err| switch (err) {
                error.Broken => return error.Closed,
                error.Failed => return error.Unexpected,
            }) orelse return error.Timeout;
            if (n == 0) return error.Closed;
            off += n;
        }
    }

    fn read(ptr: *anyopaque, buf: []u8, timeout_ms: u32) platform_mod.ReadError!usize {
        const self = from(ptr);
        var ov = std.mem.zeroes(w.OVERLAPPED);
        ov.hEvent = self.event;
        const len: w.DWORD = @intCast(@min(buf.len, 1 << 30));
        if (k32.ReadFile(self.handle, buf.ptr, len, null, &ov) == 0) {
            switch (lastError()) {
                .IO_PENDING, .MORE_DATA => {},
                .BROKEN_PIPE, .PIPE_NOT_CONNECTED => return 0,
                else => return error.Unexpected,
            }
        }
        const n = (self.finish(&ov, timeout_ms) catch |err| switch (err) {
            error.Broken => return 0,
            error.Failed => return error.Unexpected,
        }) orelse return error.Timeout;
        return n;
    }

    fn serverPid(ptr: *anyopaque) ?u32 {
        const self = from(ptr);
        var pid: w.ULONG = 0;
        if (GetNamedPipeServerProcessId(self.handle, &pid) == 0) return null;
        return pid;
    }

    fn close(ptr: *anyopaque) void {
        const self = from(ptr);
        w.CloseHandle(self.event);
        w.CloseHandle(self.handle);
        self.gpa.destroy(self);
    }
};

/// Observes a pipe name without connecting: `WaitNamedPipeW` with a 1 ms
/// timeout reports "no such pipe" immediately and "busy" as a timeout.
pub fn pipeState(gpa: Allocator, path: []const u8) platform_mod.PipeState {
    const name = widen(gpa, path) catch return .other;
    defer gpa.free(name);
    if (WaitNamedPipeW(name, 1) != 0) return .present;
    return switch (lastError()) {
        .SEM_TIMEOUT => .present,
        .FILE_NOT_FOUND => .absent,
        else => .other,
    };
}

/// Names under `\\.\pipe\` starting with `prefix` (ASCII case-insensitive).
pub fn enumeratePipes(gpa: Allocator, prefix: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    const pattern = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\*");
    var data: w.WIN32_FIND_DATAW = undefined;
    const h = k32.FindFirstFileW(pattern, &data);
    if (h == w.INVALID_HANDLE_VALUE) return out.toOwnedSlice(gpa);
    defer _ = k32.FindClose(h);
    while (true) {
        const len = std.mem.indexOfScalar(u16, &data.cFileName, 0) orelse data.cFileName.len;
        if (utf8.utf16LeToUtf8Alloc(gpa, data.cFileName[0..len], 1024)) |name| {
            if (name.len >= prefix.len and std.ascii.startsWithIgnoreCase(name, prefix)) {
                out.append(gpa, name) catch |err| {
                    gpa.free(name);
                    return err;
                };
            } else gpa.free(name);
        } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        if (FindNextFileW(h, &data) == 0) break;
    }
    return out.toOwnedSlice(gpa);
}

// ----- processes -----

/// Starts `argv` detached: no inherited handles (a GUI that kept the
/// caller's stdout pipe open would hang scripts), no console, a new process
/// group, the given environment.
pub fn spawnDetached(gpa: Allocator, argv: []const []const u8, env: *const std.process.EnvMap) platform_mod.SpawnError!void {
    if (argv.len == 0) return error.SpawnFailed;
    const cmdline = proto.win_argv.join(gpa, argv) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unrepresentable => return error.SpawnFailed,
    };
    defer gpa.free(cmdline);
    const cmd_w = utf8.utf8ToUtf16LeAllocZ(gpa, cmdline, 32766) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnFailed,
    };
    defer gpa.free(cmd_w);
    const app_w = utf8.utf8ToUtf16LeAllocZ(gpa, argv[0], 32766) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnFailed,
    };
    defer gpa.free(app_w);
    const env_block = std.process.createWindowsEnvBlock(gpa, env) catch return error.OutOfMemory;
    defer gpa.free(env_block);
    var si = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    var pi: w.PROCESS_INFORMATION = undefined;
    if (k32.CreateProcessW(app_w, cmd_w, null, null, 0, .{
        .detached_process = true,
        .create_new_process_group = true,
        .create_unicode_environment = true,
    }, env_block.ptr, null, &si, &pi) == 0) return error.SpawnFailed;
    w.CloseHandle(pi.hThread);
    w.CloseHandle(pi.hProcess);
}

pub fn allowSetForegroundWindow(pid: u32) void {
    _ = AllowSetForegroundWindow(pid);
}

// ----- console -----

fn stdHandle(which: w.DWORD) ?w.HANDLE {
    const h = k32.GetStdHandle(which) orelse return null;
    if (h == w.INVALID_HANDLE_VALUE) return null;
    return h;
}

pub fn isConsole(which: w.DWORD) bool {
    const h = stdHandle(which) orelse return false;
    var mode: w.DWORD = 0;
    return k32.GetConsoleMode(h, &mode) != 0;
}

/// The console handle behind `which`, with VT processing enabled; null when
/// redirected.
pub fn consoleHandle(which: w.DWORD) ?w.HANDLE {
    const h = stdHandle(which) orelse return null;
    var mode: w.DWORD = 0;
    if (k32.GetConsoleMode(h, &mode) == 0) return null;
    _ = k32.SetConsoleMode(h, mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    return h;
}

/// `Utf16Sink` emitter: writes all units with `WriteConsoleW`.
pub fn writeConsoleUnits(ctx: *anyopaque, units: []const u16) bool {
    const h: w.HANDLE = @ptrCast(ctx);
    var off: usize = 0;
    while (off < units.len) {
        var n: w.DWORD = 0;
        const chunk: w.DWORD = @intCast(@min(units.len - off, 8192));
        if (k32.WriteConsoleW(h, units[off..].ptr, chunk, &n, null) == 0 or n == 0) return false;
        off += n;
    }
    return true;
}

// ----- registry -----

pub fn appsUseLightTheme() bool {
    var value: w.DWORD = 0;
    var size: w.DWORD = @sizeOf(w.DWORD);
    const sub = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    const name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    if (w.advapi32.RegGetValueW(w.HKEY_CURRENT_USER, sub, name, RRF_RT_REG_DWORD, null, &value, &size) != 0) return false;
    return value == 1;
}

/// A REG_SZ policy value; `.malformed` for other types or bad data.
pub fn readPolicyString(gpa: Allocator, hklm: bool, comptime subkey: []const u8, comptime value: []const u8) platform_mod.PolicyValue {
    const hive = if (hklm) w.HKEY_LOCAL_MACHINE else w.HKEY_CURRENT_USER;
    const sub = std.unicode.utf8ToUtf16LeStringLiteral(subkey);
    const name = std.unicode.utf8ToUtf16LeStringLiteral(value);
    var kind: w.DWORD = 0;
    var size: w.DWORD = 0;
    const probe = w.advapi32.RegGetValueW(hive, sub, name, RRF_RT_ANY | RRF_NOEXPAND, &kind, null, &size);
    if (probe != 0) return if (probe == 2 or probe == 3) .absent else .malformed;
    if (kind != REG_SZ and kind != REG_EXPAND_SZ) return .malformed;
    if (size == 0 or size > 4096) return .malformed;
    const units = gpa.alloc(u16, size / 2 + 1) catch return .malformed;
    defer gpa.free(units);
    var got: w.DWORD = @intCast(units.len * 2);
    if (w.advapi32.RegGetValueW(hive, sub, name, RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND, null, units.ptr, &got) != 0) return .malformed;
    const n = std.mem.indexOfScalar(u16, units[0 .. got / 2], 0) orelse got / 2;
    const s = utf8.utf16LeToUtf8Alloc(gpa, units[0..n], 8192) catch return .malformed;
    return .{ .string = s };
}
