//! Minimal Win32 declarations shared by the S4 spike prototypes.
//! Spike reference code (docs/arch/spikes/S4-agent-shims.md); not part of the wmux build.
const std = @import("std");

pub const BOOL = c_int;
pub const DWORD = u32;
pub const WORD = u16;
pub const HANDLE = *anyopaque;
pub const HPCON = *anyopaque;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 0x102;
pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?LPWSTR = null,
    lpDesktop: ?LPWSTR = null,
    lpTitle: ?LPWSTR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: WORD = 0,
    cbReserved2: WORD = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const COORD = extern struct { X: i16, Y: i16 };

pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: u64 align(4),
    ftLastAccessTime: u64 align(4),
    ftLastWriteTime: u64 align(4),
    dwVolumeSerialNumber: DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    nNumberOfLinks: DWORD,
    nFileIndexHigh: DWORD,
    nFileIndexLow: DWORD,
};

pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;
pub const CREATE_SUSPENDED: DWORD = 0x00000004;
pub const DETACHED_PROCESS: DWORD = 0x00000008;
pub const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
pub const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x00020002;
pub const PROC_THREAD_ATTRIBUTE_JOB_LIST: usize = 0x0002000D;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
pub const DUPLICATE_SAME_ACCESS: DWORD = 0x2;

pub const SYNCHRONIZE: DWORD = 0x00100000;
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const PROCESS_TERMINATE: DWORD = 0x0001;
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x1;
pub const FILE_SHARE_WRITE: DWORD = 0x2;
pub const FILE_SHARE_DELETE: DWORD = 0x4;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;

pub const CTRL_C_EVENT: DWORD = 0;
pub const CTRL_BREAK_EVENT: DWORD = 1;
pub const CTRL_CLOSE_EVENT: DWORD = 2;
pub const CTRL_LOGOFF_EVENT: DWORD = 5;
pub const CTRL_SHUTDOWN_EVENT: DWORD = 6;

pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
pub const KEY_EVENT: WORD = 0x0001;

pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: WORD,
    wVirtualKeyCode: WORD,
    wVirtualScanCode: WORD,
    uChar: u16,
    dwControlKeyState: DWORD,
};

pub const INPUT_RECORD = extern struct {
    EventType: WORD,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        raw: [16]u8,
    },
};

pub const JobObjectBasicProcessIdList: c_int = 3;
pub const JobObjectExtendedLimitInformation: c_int = 9;
pub const JOB_OBJECT_LIMIT_BREAKAWAY_OK: DWORD = 0x00000800;
pub const JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK: DWORD = 0x00001000;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: DWORD = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: DWORD = 0,
    Affinity: usize = 0,
    PriorityClass: DWORD = 0,
    SchedulingClass: DWORD = 0,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

pub const HANDLER_ROUTINE = *const fn (DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetStdHandle(n: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, read: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetProcessId(h: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetModuleFileNameW(m: ?*anyopaque, buf: [*]u16, n: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPWSTR;
pub extern "kernel32" fn GetCurrentDirectoryW(n: DWORD, buf: ?[*]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetEnvironmentVariableW(name: LPCWSTR, buf: ?[*]u16, n: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn SetEnvironmentVariableW(name: LPCWSTR, value: ?LPCWSTR) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
pub extern "kernel32" fn CreateProcessW(
    app: ?LPCWSTR,
    cmd: ?LPWSTR,
    pa: ?*SECURITY_ATTRIBUTES,
    ta: ?*SECURITY_ATTRIBUTES,
    inherit: BOOL,
    flags: DWORD,
    env: ?*anyopaque,
    cwd: ?LPCWSTR,
    si: *STARTUPINFOW,
    pi: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResumeThread(h: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?HANDLER_ROUTINE, add: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(h: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadConsoleInputW(h: HANDLE, buf: [*]INPUT_RECORD, n: DWORD, read: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(
    name: LPCWSTR,
    access: DWORD,
    share: DWORD,
    sa: ?*SECURITY_ATTRIBUTES,
    disp: DWORD,
    flags: DWORD,
    tmpl: ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn DuplicateHandle(sp: HANDLE, src: HANDLE, dp: HANDLE, dst: *HANDLE, access: DWORD, inherit: BOOL, opts: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateJobObjectW(sa: ?*SECURITY_ATTRIBUTES, name: ?LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetInformationJobObject(job: HANDLE, cls: c_int, info: *anyopaque, len: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryInformationJobObject(job: ?HANDLE, cls: c_int, info: *anyopaque, len: DWORD, ret: ?*DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, proc: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateJobObject(job: HANDLE, code: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn IsProcessInJob(proc: HANDLE, job: ?HANDLE, result: *BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(list: ?*anyopaque, flags: DWORD, attr: usize, value: *const anyopaque, size: usize, prev: ?*anyopaque, retsize: ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(list: ?*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn CreatePipe(r: *HANDLE, w: *HANDLE, sa: ?*SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreatePseudoConsole(size: COORD, in: HANDLE, out: HANDLE, flags: DWORD, hpc: *HPCON) callconv(.winapi) c_long;
pub extern "kernel32" fn ClosePseudoConsole(hpc: HPCON) callconv(.winapi) void;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn GetFileAttributesW(name: LPCWSTR) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetFileInformationByHandle(h: HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFullPathNameW(name: LPCWSTR, n: DWORD, buf: [*]u16, filepart: ?*?[*:0]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn SearchPathW(path: ?LPCWSTR, file: LPCWSTR, ext: ?LPCWSTR, n: DWORD, buf: [*]u16, filepart: ?*?[*:0]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn QueryPerformanceCounter(c: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(f: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn AttachConsole(pid: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn FreeConsole() callconv(.winapi) BOOL;
pub extern "kernel32" fn GenerateConsoleCtrlEvent(ev: DWORD, group: DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
pub extern "user32" fn GetWindowThreadProcessId(hwnd: *anyopaque, pid: ?*DWORD) callconv(.winapi) DWORD;

// ---------------------------------------------------------------- helpers

/// Formats into a stack buffer and writes the bytes to stdout (or stderr) with WriteFile.
/// ASCII-only output keeps it readable through ConPTY regardless of the console code page.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    printTo(STD_OUTPUT_HANDLE, fmt, args);
}

pub fn eprint(comptime fmt: []const u8, args: anytype) void {
    printTo(STD_ERROR_HANDLE, fmt, args);
}

pub fn printTo(which: DWORD, comptime fmt: []const u8, args: anytype) void {
    var buf: [16384]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        const tail = "...<truncated>\r\n";
        @memcpy(buf[buf.len - tail.len ..], tail);
        break :blk buf[0..];
    };
    const h = GetStdHandle(which) orelse return;
    if (h == INVALID_HANDLE_VALUE) return;
    var written: DWORD = 0;
    _ = WriteFile(h, s.ptr, @intCast(s.len), &written, null);
}

/// UTF-16 (no terminator) -> UTF-8, lossy on unpaired surrogates.
pub fn toUtf8(a: std.mem.Allocator, w: []const u16) []u8 {
    return std.unicode.utf16LeToUtf8Alloc(a, w) catch a.dupe(u8, "<bad utf16>") catch unreachable;
}

pub fn toUtf16Z(a: std.mem.Allocator, s: []const u8) [:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s) catch unreachable;
}

/// Reads an environment variable as UTF-8 (null when unset).
pub fn getEnv(a: std.mem.Allocator, comptime name: []const u8) ?[]u8 {
    const wname = std.unicode.utf8ToUtf16LeStringLiteral(name);
    const n = GetEnvironmentVariableW(wname, null, 0);
    if (n == 0) return null;
    const buf = a.alloc(u16, n) catch return null;
    const m = GetEnvironmentVariableW(wname, buf.ptr, n);
    return toUtf8(a, buf[0..m]);
}

pub fn getEnvW(a: std.mem.Allocator, comptime name: []const u8) ?[]u16 {
    const wname = std.unicode.utf8ToUtf16LeStringLiteral(name);
    const n = GetEnvironmentVariableW(wname, null, 0);
    if (n == 0) return null;
    const buf = a.alloc(u16, n) catch return null;
    const m = GetEnvironmentVariableW(wname, buf.ptr, n);
    return buf[0..m];
}

pub fn modulePath(a: std.mem.Allocator) []u16 {
    var buf: [32768]u16 = undefined;
    const n = GetModuleFileNameW(null, &buf, buf.len);
    return a.dupe(u16, buf[0..n]) catch unreachable;
}

pub fn currentDir(a: std.mem.Allocator) []u8 {
    var buf: [32768]u16 = undefined;
    const n = GetCurrentDirectoryW(buf.len, &buf);
    return toUtf8(a, buf[0..n]);
}

/// Parses a decimal or 0x-prefixed hexadecimal u32 (negative decimals wrap, e.g. -1 -> 0xFFFFFFFF).
pub fn parseU32(s: []const u8) u32 {
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"))
        return std.fmt.parseInt(u32, s[2..], 16) catch 0;
    if (std.mem.startsWith(u8, s, "-"))
        return @bitCast(std.fmt.parseInt(i32, s, 10) catch 0);
    return std.fmt.parseInt(u32, s, 10) catch 0;
}
