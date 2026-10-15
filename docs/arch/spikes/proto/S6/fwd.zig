//! wmux spike S6: minimal CLI forwarder (prototype, MIT, clean-room).
//!
//! Dropped into a directory that is already on PATH (default
//! %LOCALAPPDATA%\Microsoft\WindowsApps). It finds the real CLI through
//! HKCU\Software\wmuxspikefwd\InstallDir (production: HKCU\Software\wmux\InstallDir)
//! and relays to <InstallDir>\cli\wmuxspikefwd-target.exe (production: cli\cmux.exe):
//!
//!   - lpApplicationName = target, lpCommandLine = our own command line unchanged
//!     (no re-quoting, so argv bytes are identical, and argv[0] keeps the name the
//!     user typed, which is what the CLI uses for cmux/wmux branding),
//!   - bInheritHandles = TRUE and no STARTF_USESTDHANDLES: the console and any
//!     redirected std handles reach the target directly (no copy loop),
//!   - Ctrl+C / Ctrl+Break: a handler routine returns TRUE in the forwarder only.
//!     Never SetConsoleCtrlHandler(NULL, TRUE): that "ignore" flag is inherited,
//!   - kill-on-close job with silent breakaway: the target dies with the
//!     forwarder, but processes the target starts (e.g. the GUI) are not in it,
//!   - the exit code is propagated verbatim (all 32 bits).
//!
//!   - no console of its own (started DETACHED_PROCESS): start the target detached too,
//!     passing our std handles explicitly (STARTF_USESTDHANDLES).
//!
//! Spike switches, env WMUXSPIKEFWD_MODE: "nojob", "nullhandler", "nohandler", "nodetach".
//! Build: zig build-exe fwd.zig -O ReleaseSmall -fstrip -target x86_64-windows-gnu
const std = @import("std");
const w = std.os.windows;

const BOOL = w.BOOL;
const DWORD = u32;
const HANDLE = w.HANDLE;
const WCHAR = u16;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]WCHAR;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const WCHAR, buf: ?[*]WCHAR, size: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetFileAttributesW(path: [*:0]const WCHAR) callconv(.winapi) DWORD;
extern "kernel32" fn CreateProcessW(
    app: ?[*:0]const WCHAR,
    cmd: ?[*:0]WCHAR,
    pa: ?*anyopaque,
    ta: ?*anyopaque,
    inherit: BOOL,
    flags: DWORD,
    env: ?*anyopaque,
    cwd: ?[*:0]const WCHAR,
    si: *w.STARTUPINFOW,
    pi: *w.PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ExitProcess(code: DWORD) callconv(.winapi) noreturn;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ResumeThread(h: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn CreateJobObjectW(sa: ?*anyopaque, name: ?[*:0]const WCHAR) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *anyopaque, len: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "advapi32" fn RegGetValueW(
    key: w.HKEY,
    sub_key: ?[*:0]const WCHAR,
    value: ?[*:0]const WCHAR,
    flags: DWORD,
    value_type: ?*DWORD,
    data: ?*anyopaque,
    data_len: ?*DWORD,
) callconv(.winapi) i32;

const CREATE_SUSPENDED: DWORD = 0x4;
const DETACHED_PROCESS: DWORD = 0x8;
const INFINITE: DWORD = 0xFFFF_FFFF;
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFF_FFFF;
const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
const RRF_RT_REG_SZ: DWORD = 0x2;
const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
const STARTF_USESTDHANDLES: DWORD = 0x100;
const HANDLE_FLAG_INHERIT: DWORD = 0x1;
const JobObjectExtendedLimitInformation: c_int = 9;
const JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK: DWORD = 0x1000;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x2000;

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: DWORD,
    Affinity: usize,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};
const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};
const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};
comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) == 144);
}

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const reg_sub_key = L("Software\\wmuxspikefwd");
const reg_value = L("InstallDir");
const target_suffix = L("\\cli\\wmuxspikefwd-target.exe");

/// Exit code for the forwarder's own failures (target missing, CreateProcess
/// failed). ADR-4.7: 1 = runtime error.
const fail_code: DWORD = 1;

// Large buffers live in .bss so they cost nothing in the file.
var path_buf: [32768]WCHAR = undefined;
var cmd_buf: [32768]WCHAR = undefined;
var msg_buf: [4096]u8 = undefined;
var g_child = std.atomic.Value(usize).init(0);

fn ctrlHandler(ctrl: DWORD) callconv(.winapi) BOOL {
    switch (ctrl) {
        // CTRL_C_EVENT, CTRL_BREAK_EVENT: the target receives the same event
        // from the console and decides; the forwarder keeps waiting for it.
        0, 1 => return 1,
        // CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT: the system
        // ends this process after the handler returns. Give the target time to
        // run its own close handler first (the job would otherwise kill it).
        else => {
            const h = g_child.load(.acquire);
            if (h != 0) _ = WaitForSingleObject(@ptrFromInt(h), 4000);
            return 0;
        },
    }
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    const msg = std.fmt.bufPrint(&msg_buf, "wmuxspikefwd: " ++ fmt ++ "\r\n", args) catch "wmuxspikefwd: error\r\n";
    if (GetStdHandle(STD_ERROR_HANDLE)) |h| _ = WriteFile(h, msg.ptr, @intCast(msg.len), null, null);
    ExitProcess(fail_code);
}

/// Our std handle, made inheritable, or null.
fn inheritableStd(which: DWORD) ?HANDLE {
    const h = GetStdHandle(which) orelse return null;
    if (@intFromPtr(h) == std.math.maxInt(usize)) return null;
    _ = SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    return h;
}

fn modeIs(comptime name: []const u8) bool {
    var buf: [32]WCHAR = undefined;
    const n = GetEnvironmentVariableW(L("WMUXSPIKEFWD_MODE"), &buf, buf.len);
    if (n == 0 or n >= buf.len) return false;
    const want = L(name);
    return std.mem.eql(WCHAR, buf[0..n], want);
}

pub fn main() void {
    // 1. Locate the real CLI: InstallDir from HKCU, then <dir>\cli\<target>.
    var cb: DWORD = @intCast(path_buf.len * 2);
    const rc = RegGetValueW(w.HKEY_CURRENT_USER, reg_sub_key, reg_value, RRF_RT_REG_SZ, null, &path_buf, &cb);
    if (rc != 0) die("wmux is not installed for this user (HKCU\\Software\\wmuxspikefwd\\InstallDir: error {d}); reinstall wmux or run 'cmux install-cli' again", .{rc});
    var n: usize = cb / 2;
    while (n > 0 and path_buf[n - 1] == 0) n -= 1;
    while (n > 0 and (path_buf[n - 1] == '\\' or path_buf[n - 1] == '/')) n -= 1;
    if (n == 0 or n + target_suffix.len + 1 > path_buf.len) die("invalid InstallDir value", .{});
    @memcpy(path_buf[n .. n + target_suffix.len], target_suffix);
    path_buf[n + target_suffix.len] = 0;
    const target: [*:0]const WCHAR = path_buf[0 .. n + target_suffix.len :0];
    const attrs = GetFileAttributesW(target);
    if (attrs == INVALID_FILE_ATTRIBUTES or (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0)
        die("wmux CLI not found under InstallDir (error {d}); reinstall wmux or run 'cmux install-cli' again", .{GetLastError()});

    // 2. Our own command line, verbatim (CreateProcessW needs a writable copy).
    const cl = GetCommandLineW();
    const cl_len = std.mem.len(cl);
    if (cl_len + 1 > cmd_buf.len) die("command line too long", .{});
    @memcpy(cmd_buf[0..cl_len], cl[0..cl_len]);
    cmd_buf[cl_len] = 0;

    // 3. Console control: survive Ctrl+C so the target's exit code comes back.
    if (modeIs("nullhandler")) {
        _ = SetConsoleCtrlHandler(null, 1); // anti-pattern under test: inherited
    } else if (!modeIs("nohandler")) {
        _ = SetConsoleCtrlHandler(ctrlHandler, 1);
    }

    // 4. Kill-on-close job (best effort; nested jobs are fine on Windows 8+).
    var job: ?HANDLE = null;
    if (!modeIs("nojob")) {
        if (CreateJobObjectW(null, null)) |j| {
            var info = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
            if (SetInformationJobObject(j, JobObjectExtendedLimitInformation, &info, @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) != 0) {
                job = j;
            } else {
                _ = CloseHandle(j);
            }
        }
    }

    // 5. Relay.
    var si = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    var pi: w.PROCESS_INFORMATION = undefined;
    var flags: DWORD = if (job != null) CREATE_SUSPENDED else 0;
    // Started without any console (DETACHED_PROCESS parent, e.g. a GUI or a service):
    // keep the target console-less too, otherwise Windows gives it a new visible
    // console. A detached child does not get our std handles implicitly, so pass them.
    if (GetConsoleCP() == 0 and !modeIs("nodetach")) {
        flags |= DETACHED_PROCESS;
        si.dwFlags |= STARTF_USESTDHANDLES;
        si.hStdInput = inheritableStd(STD_INPUT_HANDLE);
        si.hStdOutput = inheritableStd(STD_OUTPUT_HANDLE);
        si.hStdError = inheritableStd(STD_ERROR_HANDLE);
    }
    if (CreateProcessW(target, cmd_buf[0..cl_len :0], null, null, 1, flags, null, null, &si, &pi) == 0)
        die("cannot start the wmux CLI (CreateProcess error {d})", .{GetLastError()});
    if (job) |j| {
        if (AssignProcessToJobObject(j, pi.hProcess) == 0) {
            _ = CloseHandle(j); // run unjobbed rather than fail
            job = null;
        }
    }
    if (flags & CREATE_SUSPENDED != 0) _ = ResumeThread(pi.hThread);
    _ = CloseHandle(pi.hThread);
    g_child.store(@intFromPtr(pi.hProcess), .release);

    _ = WaitForSingleObject(pi.hProcess, INFINITE);
    var code: DWORD = fail_code;
    if (GetExitCodeProcess(pi.hProcess, &code) == 0) code = fail_code;
    ExitProcess(code); // job handle closes here; the target has already exited
}
