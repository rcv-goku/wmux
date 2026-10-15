//! S5 spike prototype (W0-D-S5): per-environment WebView2 proxies.
//!
//! In ONE process this creates several WebView2 environments with distinct
//! user-data folders and distinct `--proxy-server` arguments, each hosting a
//! controller in a hidden off-screen window, and runs tiny local servers:
//!
//!   origin4/origin6  test HTTP + WebSocket-echo origin on 127.0.0.1:T and [::1]:T
//!   socksA/B/D/H     SOCKS5 proxies with PID admission bound to env A/B/D/H
//!                    (socksH starts late, on a port H already points at)
//!   socksOpen        SOCKS5 proxy without admission (positive control for curl)
//!   httpE/E2/G       HTTP proxies (absolute-form + CONNECT) requiring Basic
//!                    Proxy-Authorization (fallback evaluation)
//!
//! Environments:
//!   A   socks5://socksA + <-loopback>        4 loopback URL forms + WebSocket
//!   B   socks5://socksB + <-loopback>        separation check against A
//!   C   socks5://socksA + <-loopback>        intruder: must be rejected by A's admission
//!   D   socks5://socksD (no bypass override) control: loopback must go direct
//!   E   http://httpE + <-loopback>           fallback: 407 + BasicAuthenticationRequested
//!   E2  http://httpE2 + <-loopback>          same, credentials supplied through a deferral
//!   G   http://user:pass@httpG + <-loopback> probe: are inline proxy credentials used?
//!   H   socks5://<no listener yet>           broker down, then started on the same port
//!   F   A's user-data folder, other proxy    probe: second environment on a busy folder
//!
//! Admission decision: owner PID of the accepted TCP connection via
//! GetExtendedTcpTable(TCP_TABLE_OWNER_PID_CONNECTIONS) must be the
//! environment's browser process or a descendant (Toolhelp parent walk with a
//! creation-time guard against PID reuse). Logged next to it for comparison:
//! the fast predicate the decision note recommends (owner == browser, or
//! parent(owner) == browser via NtQueryInformationProcess) and membership in
//! the environment's ICoreWebView2Environment8::GetProcessInfos list.
//!
//! Teardown under test: Controller::Close, keep the environment until
//! BrowserProcessExited, terminate leftovers after 60 s, delete the folders.
//!
//! Standalone, NOT part of the wmux build graph. Reuses wmux's WebView2 COM
//! bindings (src/apprt/win32/webview2.zig) as module "wv2" and reaches the few
//! extra slots it needs (EnvironmentOptions, BrowserProcessId, Environment5/8,
//! ICoreWebView2_10) through raw vtable indices verified against WebView2.idl
//! of SDK 1.0.4022.49. Build and run: see README.md next to this file.
const std = @import("std");
const wv2 = @import("wv2");

const W = std.os.windows;
const ws = W.ws2_32;
const HWND = W.HWND;
const WPARAM = W.WPARAM;
const LPARAM = W.LPARAM;
const LRESULT = W.LRESULT;
const BOOL = W.BOOL;
const DWORD = W.DWORD;
const HANDLE = W.HANDLE;
const GUID = W.GUID;
const HRESULT = W.HRESULT;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const gpa = std.heap.page_allocator;

// ─── Win32 / COM / IP Helper declarations not provided by std ───────────

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: WPARAM, lParam: LPARAM, time: u32, pt: W.POINT };
const PROCESSENTRY32W = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ProcessID: DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: DWORD,
    cntThreads: DWORD,
    th32ParentProcessID: DWORD,
    pcPriClassBase: i32,
    dwFlags: DWORD,
    szExeFile: [260]u16,
};
const MIB_TCPROW_OWNER_PID = extern struct { state: DWORD, local_addr: u32, local_port: DWORD, remote_addr: u32, remote_port: DWORD, pid: DWORD };
const MIB_TCP6ROW_OWNER_PID = extern struct { local_addr: [16]u8, local_scope: DWORD, local_port: DWORD, remote_addr: [16]u8, remote_scope: DWORD, remote_port: DWORD, state: DWORD, pid: DWORD };

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn SetTimer(?HWND, usize, u32, ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowThreadProcessId(HWND, ?*DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn OpenProcess(DWORD, BOOL, DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetProcessTimes(HANDLE, *W.FILETIME, *W.FILETIME, *W.FILETIME, *W.FILETIME) callconv(.winapi) BOOL;
extern "kernel32" fn Process32FirstW(HANDLE, *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn Process32NextW(HANDLE, *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoTaskMemAlloc(usize) callconv(.winapi) ?*anyopaque;
extern "iphlpapi" fn GetExtendedTcpTable(?*anyopaque, *DWORD, BOOL, u32, i32, u32) callconv(.winapi) DWORD;
extern "ntdll" fn NtQueryInformationProcess(HANDLE, u32, ?*anyopaque, u32, ?*u32) callconv(.winapi) i32;
const PROCESS_BASIC_INFORMATION = extern struct {
    ExitStatus: i32,
    PebBaseAddress: ?*anyopaque,
    AffinityMask: usize,
    BasePriority: i32,
    UniqueProcessId: usize,
    InheritedFromUniqueProcessId: usize,
};
const ProcessBasicInformation: u32 = 0;
const ProcessCommandLineInformation: u32 = 60;
const SYNCHRONIZE: DWORD = 0x0010_0000;
const WAIT_OBJECT_0: DWORD = 0;

const WS_POPUP: u32 = 0x8000_0000;
const WS_CLIPCHILDREN: u32 = 0x0200_0000;
const WS_EX_NOACTIVATE: u32 = 0x0800_0000;
const WS_EX_TOOLWINDOW: u32 = 0x0000_0080;
const SW_SHOWNOACTIVATE: i32 = 4;
const WM_TIMER: u32 = 0x0113;
const COINIT_APARTMENTTHREADED: u32 = 0x2;
const TH32CS_SNAPPROCESS: DWORD = 0x2;
const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
const AF_INET: u16 = 2;
const AF_INET6: u16 = 23;
const SOCK_STREAM: i32 = 1;
const IPPROTO_TCP: i32 = 6;
const SOL_SOCKET: i32 = 0xffff;
const SO_RCVTIMEO: i32 = 0x1006;
const SO_EXCLUSIVEADDRUSE: i32 = ~@as(i32, 4);
const SD_SEND: i32 = 1;
const TCP_TABLE_OWNER_PID_CONNECTIONS: i32 = 4;
const ERROR_INSUFFICIENT_BUFFER: DWORD = 122;
const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));

// ─── WebView2 interfaces beyond wmux's current bindings ─────────────────
// IIDs and vtable indices verified against WebView2.idl (SDK 1.0.4022.49).

const IID_EnvOptions = GUID.parse("{2fde08a8-1e9a-4766-8c05-95a9ceb9d1c5}");
const IID_Env5 = GUID.parse("{319e423d-e0d7-4b8d-9254-ae9475de9b17}");
const IID_Env8 = GUID.parse("{d6eb91dd-c3d2-45e5-bd29-6dc2bc4de9cf}");
const IID_WebView2_10 = GUID.parse("{b1690564-6f5a-4983-8e48-31d1143fecdb}");
const IID_BasicAuthHandler = GUID.parse("{58b4d6c2-18d4-497e-b39b-9a96533fa278}");
const IID_ProcessInfosChangedHandler = GUID.parse("{f4af0c39-44b9-40e9-8b11-0484cfb9e0a1}");
const IID_BrowserProcessExitedHandler = GUID.parse("{fa504257-a216-4911-a860-fe8825712861}");
const IID_NavStartingHandler = GUID.parse("{9adbe429-f36d-432b-9ddc-f8881fbd76e3}");

const slot = struct {
    const webview_add_NavigationStarting = 7; // ICoreWebView2 (3 + 4)
    const webview_get_BrowserProcessId = 37; // ICoreWebView2 (3 + 34)
    const navstart_get_Uri = 3; // ICoreWebView2NavigationStartingEventArgs
    const navstart_get_NavigationId = 9;
    const navdone_get_NavigationId = 5; // ICoreWebView2NavigationCompletedEventArgs
    const auth_GetDeferral = 8; // ICoreWebView2BasicAuthenticationRequestedEventArgs
    const deferral_Complete = 3; // ICoreWebView2Deferral
    const webview10_add_BasicAuthenticationRequested = 97; // ICoreWebView2_10
    const env5_add_BrowserProcessExited = 12; // ICoreWebView2Environment5
    const env8_add_ProcessInfosChanged = 16; // ICoreWebView2Environment8
    const env8_GetProcessInfos = 18;
    const coll_get_Count = 3; // ICoreWebView2ProcessInfoCollection
    const coll_GetValueAtIndex = 4;
    const info_get_ProcessId = 3; // ICoreWebView2ProcessInfo
    const info_get_Kind = 4;
    const exited_get_Kind = 3; // ICoreWebView2BrowserProcessExitedEventArgs
    const exited_get_BrowserProcessId = 4;
    const auth_get_Uri = 3; // ICoreWebView2BasicAuthenticationRequestedEventArgs
    const auth_get_Challenge = 4;
    const auth_get_Response = 5;
    const auth_put_Cancel = 7;
    const resp_put_UserName = 4; // ICoreWebView2BasicAuthenticationResponse
    const resp_put_Password = 6;
};

/// Untyped COM object: call any vtable slot by index.
const RawCom = extern struct {
    vtable: [*]const *const anyopaque,

    fn fnAt(self: *RawCom, comptime idx: usize, comptime Fn: type) Fn {
        return @ptrCast(@alignCast(self.vtable[idx]));
    }
    fn addRef(self: *RawCom) void {
        _ = self.fnAt(1, *const fn (*RawCom) callconv(.winapi) u32)(self);
    }
    fn release(self: *RawCom) void {
        _ = self.fnAt(2, *const fn (*RawCom) callconv(.winapi) u32)(self);
    }
    fn qi(self: *RawCom, iid: *const GUID) ?*RawCom {
        var out: ?*anyopaque = null;
        const hr = self.fnAt(0, *const fn (*RawCom, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT)(self, iid, &out);
        if (hr != 0) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }
};
fn raw(p: anytype) *RawCom {
    return @ptrCast(@alignCast(p));
}
const GetStrFn = *const fn (*RawCom, *?[*:0]u16) callconv(.winapi) HRESULT;
const PutStrFn = *const fn (*RawCom, [*:0]const u16) callconv(.winapi) HRESULT;
const GetObjFn = *const fn (*RawCom, *?*RawCom) callconv(.winapi) HRESULT;
const PutBoolFn = *const fn (*RawCom, BOOL) callconv(.winapi) HRESULT;
const GetU32Fn = *const fn (*RawCom, *u32) callconv(.winapi) HRESULT;
const GetI32Fn = *const fn (*RawCom, *i32) callconv(.winapi) HRESULT;
const GetAtFn = *const fn (*RawCom, u32, *?*RawCom) callconv(.winapi) HRESULT;
const GetU64Fn = *const fn (*RawCom, *u64) callconv(.winapi) HRESULT;
const NoArgFn = *const fn (*RawCom) callconv(.winapi) HRESULT;
const AddHandlerFn = *const fn (*RawCom, *anyopaque, *wv2.EventRegistrationToken) callconv(.winapi) HRESULT;

const EnvDone = wv2.EnvironmentCompletedHandler(Env);
const CtrlDone = wv2.ControllerCompletedHandler(Env);
const NavDone = wv2.NavigationCompletedEventHandler(Env);
const TitleChanged = wv2.DocumentTitleChangedEventHandler(Env);
const ScriptDone = wv2.ExecuteScriptCompletedHandler(Env);
const BasicAuthHandler = wv2.Handler(IID_BasicAuthHandler, Env, ?*wv2.ICoreWebView2, ?*RawCom);
const InfosChangedHandler = wv2.Handler(IID_ProcessInfosChangedHandler, Env, ?*wv2.ICoreWebView2Environment, ?*wv2.IUnknown);
const BrowserExitedHandler = wv2.Handler(IID_BrowserProcessExitedHandler, Env, ?*wv2.ICoreWebView2Environment, ?*RawCom);
const NavStartingHandler = wv2.Handler(IID_NavStartingHandler, Env, ?*wv2.ICoreWebView2, ?*RawCom);

/// Host-implemented ICoreWebView2EnvironmentOptions (the loader reads it).
const EnvOptions = extern struct {
    vtable: *const VTable = &vtable_impl,
    refs: u32 = 1,
    owner: *anyopaque,

    const GetStr = *const fn (*EnvOptions, *?[*:0]u16) callconv(.winapi) HRESULT;
    const PutStr = *const fn (*EnvOptions, ?[*:0]const u16) callconv(.winapi) HRESULT;
    const VTable = extern struct {
        QueryInterface: *const fn (*EnvOptions, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*EnvOptions) callconv(.winapi) u32,
        Release: *const fn (*EnvOptions) callconv(.winapi) u32,
        get_AdditionalBrowserArguments: GetStr,
        put_AdditionalBrowserArguments: PutStr,
        get_Language: GetStr,
        put_Language: PutStr,
        get_TargetCompatibleBrowserVersion: GetStr,
        put_TargetCompatibleBrowserVersion: PutStr,
        get_AllowSingleSignOnUsingOSPrimaryAccount: *const fn (*EnvOptions, *BOOL) callconv(.winapi) HRESULT,
        put_AllowSingleSignOnUsingOSPrimaryAccount: *const fn (*EnvOptions, BOOL) callconv(.winapi) HRESULT,
    };
    const vtable_impl: VTable = .{
        .QueryInterface = qiImpl,
        .AddRef = addRefImpl,
        .Release = releaseImpl,
        .get_AdditionalBrowserArguments = getArgs,
        .put_AdditionalBrowserArguments = putStr,
        .get_Language = getLanguage,
        .put_Language = putStr,
        .get_TargetCompatibleBrowserVersion = getTarget,
        .put_TargetCompatibleBrowserVersion = putStr,
        .get_AllowSingleSignOnUsingOSPrimaryAccount = getSso,
        .put_AllowSingleSignOnUsingOSPrimaryAccount = putBool,
    };
    fn env(self: *EnvOptions) *Env {
        return @ptrCast(@alignCast(self.owner));
    }
    fn qiImpl(self: *EnvOptions, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (wv2.guidEql(riid, &IID_EnvOptions) or wv2.guidEql(riid, &wv2.IID_IUnknown)) {
            _ = addRefImpl(self);
            out.* = self;
            return 0;
        }
        var b: [40]u8 = undefined;
        logf("env {s}: loader QI(options, {s}) -> E_NOINTERFACE", .{ self.env().name, fmtGuid(&b, riid) });
        out.* = null;
        return wv2.E_NOINTERFACE;
    }
    fn addRefImpl(self: *EnvOptions) callconv(.winapi) u32 {
        return @atomicRmw(u32, &self.refs, .Add, 1, .monotonic) + 1;
    }
    fn releaseImpl(self: *EnvOptions) callconv(.winapi) u32 {
        // Storage is owned by the Env record (static); nothing to free.
        return @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel) - 1;
    }
    fn getArgs(self: *EnvOptions, out: *?[*:0]u16) callconv(.winapi) HRESULT {
        logf("env {s}: loader read AdditionalBrowserArguments", .{self.env().name});
        out.* = coStr(self.env().args_w);
        return if (out.* == null) E_OUTOFMEMORY else 0;
    }
    fn getLanguage(_: *EnvOptions, out: *?[*:0]u16) callconv(.winapi) HRESULT {
        out.* = coStr(L(""));
        return if (out.* == null) E_OUTOFMEMORY else 0;
    }
    fn getTarget(_: *EnvOptions, out: *?[*:0]u16) callconv(.winapi) HRESULT {
        out.* = coStr(L("86.0.616.0"));
        return if (out.* == null) E_OUTOFMEMORY else 0;
    }
    fn getSso(_: *EnvOptions, out: *BOOL) callconv(.winapi) HRESULT {
        out.* = 0;
        return 0;
    }
    fn putStr(_: *EnvOptions, _: ?[*:0]const u16) callconv(.winapi) HRESULT {
        return 0;
    }
    fn putBool(_: *EnvOptions, _: BOOL) callconv(.winapi) HRESULT {
        return 0;
    }
};

fn coStr(s: []const u16) ?[*:0]u16 {
    const mem = CoTaskMemAlloc((s.len + 1) * 2) orelse return null;
    const p: [*]u16 = @ptrCast(@alignCast(mem));
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    return @ptrCast(p);
}

// ─── logging and small helpers ──────────────────────────────────────────

var log_mutex: std.Thread.Mutex = .{};
var log_file: ?std.fs.File = null;
var t0_ns: i128 = 0;
var self_pid: u32 = 0;

fn nowMs() i64 {
    return @intCast(@divTrunc(std.time.nanoTimestamp() - t0_ns, std.time.ns_per_ms));
}

fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d:>7}ms] " ++ fmt ++ "\n", .{nowMs()} ++ args) catch "[log line too long]\n";
    log_mutex.lock();
    defer log_mutex.unlock();
    if (log_file) |f| f.writeAll(line) catch {};
    std.fs.File.stdout().writeAll(line) catch {};
}

var sum_file: ?std.fs.File = null;
fn sumf(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch "[summary line too long]\n";
    if (sum_file) |f| f.writeAll(line) catch {};
    logf("{s}", .{line[0 .. line.len - 1]});
}

fn fmtGuid(buf: []u8, g: *const GUID) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        g.Data1, g.Data2, g.Data3, g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7],
    }) catch "?";
}

fn hx(hr: HRESULT) u32 {
    return @bitCast(hr);
}

fn copyTrunc(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn w2u(p: ?[*:0]const u16) []const u8 {
    const s = p orelse return "";
    return std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(s)) catch "";
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// ─── processes ──────────────────────────────────────────────────────────

const ProcSnap = struct {
    const max = 8192;
    n: usize,
    pid: [max]u32,
    ppid: [max]u32,
    name: [max][40]u8,
    name_len: [max]u8,

    fn create() ?*ProcSnap {
        const s = gpa.create(ProcSnap) catch return null;
        s.n = 0;
        const h = W.kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (h == W.INVALID_HANDLE_VALUE) {
            gpa.destroy(s);
            return null;
        }
        defer W.CloseHandle(h);
        var e = std.mem.zeroes(PROCESSENTRY32W);
        e.dwSize = @sizeOf(PROCESSENTRY32W);
        var ok = Process32FirstW(h, &e);
        while (ok != 0 and s.n < max) : (ok = Process32NextW(h, &e)) {
            s.pid[s.n] = e.th32ProcessID;
            s.ppid[s.n] = e.th32ParentProcessID;
            var k: usize = 0;
            while (k < 40 and e.szExeFile[k] != 0) : (k += 1)
                s.name[s.n][k] = if (e.szExeFile[k] < 128) @intCast(e.szExeFile[k]) else '?';
            s.name_len[s.n] = @intCast(k);
            s.n += 1;
        }
        return s;
    }
    fn destroy(s: *ProcSnap) void {
        gpa.destroy(s);
    }
    fn index(s: *const ProcSnap, pid: u32) ?usize {
        for (0..s.n) |i| if (s.pid[i] == pid) return i;
        return null;
    }
    fn parentOf(s: *const ProcSnap, pid: u32) ?u32 {
        return s.ppid[s.index(pid) orelse return null];
    }
    fn nameOf(s: *const ProcSnap, pid: u32) []const u8 {
        const i = s.index(pid) orelse return "?";
        return s.name[i][0..s.name_len[i]];
    }
};

fn creationTime(pid: u32) ?u64 {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer W.CloseHandle(h);
    var c: W.FILETIME = undefined;
    var e: W.FILETIME = undefined;
    var k: W.FILETIME = undefined;
    var u: W.FILETIME = undefined;
    if (GetProcessTimes(h, &c, &e, &k, &u) == 0) return null;
    return (@as(u64, c.dwHighDateTime) << 32) | c.dwLowDateTime;
}

/// Parent PID through NtQueryInformationProcess(ProcessBasicInformation):
/// one OpenProcess + one syscall, no system-wide snapshot.
fn parentPidFast(pid: u32) ?u32 {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer W.CloseHandle(h);
    var pbi: PROCESS_BASIC_INFORMATION = undefined;
    if (NtQueryInformationProcess(h, ProcessBasicInformation, &pbi, @sizeOf(PROCESS_BASIC_INFORMATION), null) != 0) return null;
    return @intCast(pbi.InheritedFromUniqueProcessId);
}

/// Fast admission predicate: the owner is the browser process or its
/// direct child (Chromium's network service), with a PID-reuse guard.
fn fastAdmit(owner: u32, browser: u32) bool {
    if (owner == 0 or browser == 0) return false;
    if (owner == browser) return true;
    const parent = parentPidFast(owner) orelse return false;
    if (parent != browser) return false;
    const pt = creationTime(browser) orelse return false;
    const ct = creationTime(owner) orelse return false;
    return pt <= ct;
}

/// Chromium process type from the command line (`--type=`), "browser"
/// when absent.
fn processType(pid: u32, out: []u8) []const u8 {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return "?";
    defer W.CloseHandle(h);
    var mem: [16384]u8 align(8) = undefined;
    var ret: u32 = 0;
    if (NtQueryInformationProcess(h, ProcessCommandLineInformation, &mem, mem.len, &ret) != 0) return "?";
    const Us = extern struct { len: u16, max: u16, buf: [*]const u16 };
    const us: *const Us = @ptrCast(&mem);
    const s = us.buf[0 .. us.len / 2];
    const key = L("--type=");
    const k = std.mem.indexOf(u16, s, key) orelse return "browser";
    var n: usize = 0;
    var j = k + key.len;
    while (j < s.len and s[j] != ' ' and s[j] != '"' and n < out.len) : (j += 1) {
        out[n] = if (s[j] < 128) @intCast(s[j]) else '?';
        n += 1;
    }
    return out[0..n];
}

/// True when `pid` is `root` or a descendant of it. A parent whose creation
/// time is later than its child's is a reused PID and ends the walk.
fn isInTree(s: *const ProcSnap, pid: u32, root: u32) bool {
    if (pid == 0 or root == 0) return false;
    var cur = pid;
    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        if (cur == root) return true;
        const parent = s.parentOf(cur) orelse return false;
        if (parent == 0 or parent == cur) return false;
        const pt = creationTime(parent);
        const ct = creationTime(cur);
        if (pt != null and ct != null and pt.? > ct.?) return false;
        cur = parent;
    }
    return false;
}

// ─── TCP owner lookup ───────────────────────────────────────────────────

const Owner = struct { pid: u32 = 0, rows: u32 = 0, us: u64 = 0 };
const loopback4_be: u32 = std.mem.nativeToBig(u32, 0x7F00_0001);
const loopback6: [16]u8 = [_]u8{0} ** 15 ++ [_]u8{1};

/// Owner PID of the TCP connection whose local endpoint is (laddr, lport)
/// and remote endpoint is (raddr, rport). Addresses and ports in network
/// byte order exactly as they appear in sockaddr_in.
fn tcpOwner4(laddr: u32, lport_be: u16, raddr: u32, rport_be: u16) Owner {
    var timer = std.time.Timer.start() catch return .{};
    var words: usize = 16 * 1024;
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        const buf = gpa.alloc(u32, words) catch return .{};
        defer gpa.free(buf);
        var size: DWORD = @intCast(words * 4);
        const rc = GetExtendedTcpTable(buf.ptr, &size, 0, AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS, 0);
        if (rc == ERROR_INSUFFICIENT_BUFFER) {
            words = size / 4 + 1024;
            continue;
        }
        if (rc != 0) return .{ .us = timer.read() / 1000 };
        const n = buf[0];
        const rows: [*]const MIB_TCPROW_OWNER_PID = @ptrCast(buf.ptr + 1);
        for (rows[0..n]) |r| {
            if (r.local_addr == laddr and @as(u16, @truncate(r.local_port)) == lport_be and
                r.remote_addr == raddr and @as(u16, @truncate(r.remote_port)) == rport_be)
                return .{ .pid = r.pid, .rows = n, .us = timer.read() / 1000 };
        }
        return .{ .rows = n, .us = timer.read() / 1000 };
    }
    return .{ .us = timer.read() / 1000 };
}

fn tcpOwner6(laddr: [16]u8, lport_be: u16, raddr: [16]u8, rport_be: u16) Owner {
    var timer = std.time.Timer.start() catch return .{};
    var words: usize = 32 * 1024;
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        const buf = gpa.alloc(u32, words) catch return .{};
        defer gpa.free(buf);
        var size: DWORD = @intCast(words * 4);
        const rc = GetExtendedTcpTable(buf.ptr, &size, 0, AF_INET6, TCP_TABLE_OWNER_PID_CONNECTIONS, 0);
        if (rc == ERROR_INSUFFICIENT_BUFFER) {
            words = size / 4 + 1024;
            continue;
        }
        if (rc != 0) return .{ .us = timer.read() / 1000 };
        const n = buf[0];
        const rows: [*]const MIB_TCP6ROW_OWNER_PID = @ptrCast(buf.ptr + 1);
        for (rows[0..n]) |r| {
            if (std.mem.eql(u8, &r.local_addr, &laddr) and @as(u16, @truncate(r.local_port)) == lport_be and
                std.mem.eql(u8, &r.remote_addr, &raddr) and @as(u16, @truncate(r.remote_port)) == rport_be)
                return .{ .pid = r.pid, .rows = n, .us = timer.read() / 1000 };
        }
        return .{ .rows = n, .us = timer.read() / 1000 };
    }
    return .{ .us = timer.read() / 1000 };
}

// ─── records (for the summary) ──────────────────────────────────────────

const ProxyRec = struct {
    proxy: []const u8 = "",
    conn: u32 = 0,
    t_ms: i64 = 0,
    peer_port: u16 = 0,
    owner_pid: u32 = 0,
    owner_name: [40]u8 = undefined,
    owner_name_len: usize = 0,
    owner_env: []const u8 = "?",
    owner_kind: i32 = -1,
    in_tree: bool = false,
    in_infos: bool = false,
    fast_ok: bool = false,
    fast_us: u64 = 0,
    admitted: bool = false,
    waited_ms: i64 = 0,
    lookup_us: u64 = 0,
    tree_us: u64 = 0,
    rows: u32 = 0,
    target: [96]u8 = undefined,
    target_len: usize = 0,
    reqline: [120]u8 = undefined,
    reqline_len: usize = 0,
    note: []const u8 = "",
    auth_407: u32 = 0,
    first_had_auth: bool = false,
    methods: [40]u8 = undefined,
    methods_len: usize = 0,
};

const OriginRec = struct {
    conn: u32 = 0,
    t_ms: i64 = 0,
    family: u16 = 0,
    path: [96]u8 = undefined,
    path_len: usize = 0,
    host: [64]u8 = undefined,
    host_len: usize = 0,
    via: []const u8 = "?",
    owner_pid: u32 = 0,
    absolute_form: bool = false,
    ws_echo: [64]u8 = undefined,
    ws_len: usize = 0,
};

var recs_mutex: std.Thread.Mutex = .{};
var proxy_recs: [1024]ProxyRec = undefined;
var n_proxy_recs: usize = 0;
var origin_recs: [1024]OriginRec = undefined;
var n_origin_recs: usize = 0;

fn pushProxyRec(r: ProxyRec) void {
    recs_mutex.lock();
    defer recs_mutex.unlock();
    if (n_proxy_recs < proxy_recs.len) {
        proxy_recs[n_proxy_recs] = r;
        n_proxy_recs += 1;
    }
    logf("{s}: conn {d} peer :{d} owner {d} ({s}) env={s} kind={d} in_tree={} in_infos={} fast={} admitted={} waited={d}ms lookup={d}us({d} rows) fast={d}us tree={d}us target={s} socks_methods={s} req=\"{s}\" note={s}", .{
        r.proxy,    r.conn,      r.peer_port, r.owner_pid, r.owner_name[0..r.owner_name_len], r.owner_env, r.owner_kind,              r.in_tree,                   r.in_infos,                  r.fast_ok,
        r.admitted, r.waited_ms, r.lookup_us, r.rows,      r.fast_us,                         r.tree_us,   r.target[0..r.target_len], r.methods[0..r.methods_len], r.reqline[0..r.reqline_len], r.note,
    });
}

fn pushOriginRec(r: OriginRec) void {
    recs_mutex.lock();
    defer recs_mutex.unlock();
    if (n_origin_recs < origin_recs.len) {
        origin_recs[n_origin_recs] = r;
        n_origin_recs += 1;
    }
    logf("origin{s}: conn {d} path={s} host={s} absolute_form={} via={s} owner={d} ws_echo={s}", .{
        if (r.family == AF_INET) "4" else "6", r.conn, r.path[0..r.path_len], r.host[0..r.host_len],
        r.absolute_form,                       r.via,  r.owner_pid,           r.ws_echo[0..r.ws_len],
    });
}

// ─── sockets and servers ────────────────────────────────────────────────

const ServerKind = enum { origin, socks5, http_proxy };
const Server = struct {
    name: []const u8,
    kind: ServerKind,
    family: u16 = AF_INET,
    sock: ws.SOCKET = ws.INVALID_SOCKET,
    port: u16 = 0,
    owner: ?*Env = null,
    enforce: bool = false,
    auth: ?[]const u8 = null,
    accepted: std.atomic.Value(u32) = .init(0),
    n407: std.atomic.Value(u32) = .init(0),
    nauth: std.atomic.Value(u32) = .init(0),
};
const Conn = struct {
    srv: *Server,
    sock: ws.SOCKET,
    id: u32,
    family: u16,
    peer4: ws.sockaddr.in = undefined,
    peer6: ws.sockaddr.in6 = undefined,
};

var stopping = std.atomic.Value(bool).init(false);
var next_conn = std.atomic.Value(u32).init(1);

fn beport(p: u16) u16 {
    return std.mem.nativeToBig(u16, p);
}

fn startServer(srv: *Server, port: u16) !void {
    const s = ws.socket(srv.family, SOCK_STREAM, IPPROTO_TCP);
    if (s == ws.INVALID_SOCKET) return error.Socket;
    errdefer _ = ws.closesocket(s);
    const one: i32 = 1;
    _ = ws.setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, @ptrCast(&one), 4);
    if (srv.family == AF_INET) {
        var sa: ws.sockaddr.in = .{ .port = beport(port), .addr = loopback4_be };
        if (ws.bind(s, @ptrCast(&sa), @sizeOf(ws.sockaddr.in)) != 0) return error.Bind;
    } else {
        var sa: ws.sockaddr.in6 = .{ .port = beport(port), .flowinfo = 0, .addr = loopback6, .scope_id = 0 };
        if (ws.bind(s, @ptrCast(&sa), @sizeOf(ws.sockaddr.in6)) != 0) return error.Bind;
    }
    if (ws.listen(s, 128) != 0) return error.Listen;
    var ss: ws.sockaddr.storage = undefined;
    var len: i32 = @sizeOf(ws.sockaddr.storage);
    _ = ws.getsockname(s, @ptrCast(&ss), &len);
    const sin: *const ws.sockaddr.in = @ptrCast(&ss);
    srv.port = std.mem.bigToNative(u16, sin.port);
    srv.sock = s;
    const t = try std.Thread.spawn(.{}, acceptLoop, .{srv});
    t.detach();
    logf("listening: {s} on {s}:{d}{s}{s}", .{
        srv.name,                                    if (srv.family == AF_INET) "127.0.0.1" else "[::1]", srv.port,
        if (srv.enforce) " (PID admission)" else "", if (srv.auth != null) " (Basic proxy auth)" else "",
    });
}

fn acceptLoop(srv: *Server) void {
    while (!stopping.load(.acquire)) {
        var ss: ws.sockaddr.storage = undefined;
        var len: i32 = @sizeOf(ws.sockaddr.storage);
        const cs = ws.accept(srv.sock, @ptrCast(&ss), &len);
        if (cs == ws.INVALID_SOCKET) {
            if (stopping.load(.acquire)) return;
            W.kernel32.Sleep(10);
            continue;
        }
        const c = gpa.create(Conn) catch {
            _ = ws.closesocket(cs);
            continue;
        };
        c.* = .{ .srv = srv, .sock = cs, .id = next_conn.fetchAdd(1, .monotonic), .family = srv.family };
        if (srv.family == AF_INET)
            c.peer4 = @as(*const ws.sockaddr.in, @ptrCast(&ss)).*
        else
            c.peer6 = @as(*const ws.sockaddr.in6, @ptrCast(&ss)).*;
        _ = srv.accepted.fetchAdd(1, .monotonic);
        const cfg: std.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 };
        const th = switch (srv.kind) {
            .origin => std.Thread.spawn(cfg, originConn, .{c}),
            .socks5 => std.Thread.spawn(cfg, socksConn, .{c}),
            .http_proxy => std.Thread.spawn(cfg, httpProxyConn, .{c}),
        } catch {
            _ = ws.closesocket(cs);
            gpa.destroy(c);
            continue;
        };
        th.detach();
    }
}

fn finishConn(c: *Conn) void {
    _ = ws.closesocket(c.sock);
    gpa.destroy(c);
}

fn sendAll(s: ws.SOCKET, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = ws.send(s, data.ptr + off, @intCast(data.len - off), 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn recvExact(s: ws.SOCKET, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = ws.recv(s, buf.ptr + off, @intCast(buf.len - off), 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn readAtLeast(s: ws.SOCKET, buf: []u8, have_in: usize, need: usize) ?usize {
    var have = have_in;
    while (have < need) {
        if (have == buf.len) return null;
        const n = ws.recv(s, buf.ptr + have, @intCast(buf.len - have), 0);
        if (n <= 0) return null;
        have += @intCast(n);
    }
    return have;
}

const Head = struct { head_len: usize, total: usize };
fn readHead(s: ws.SOCKET, buf: []u8, carry: usize) ?Head {
    var total = carry;
    while (true) {
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |k| return .{ .head_len = k + 4, .total = total };
        if (total == buf.len) return null;
        const n = ws.recv(s, buf.ptr + total, @intCast(buf.len - total), 0);
        if (n <= 0) return null;
        total += @intCast(n);
    }
}

fn drain(s: ws.SOCKET) void {
    const ms: DWORD = 2000;
    _ = ws.setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&ms), 4);
    var buf: [1024]u8 = undefined;
    while (ws.recv(s, &buf, buf.len, 0) > 0) {}
}

fn pump(from: ws.SOCKET, to: ws.SOCKET) void {
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = ws.recv(from, &buf, buf.len, 0);
        if (n <= 0) break;
        if (!sendAll(to, buf[0..@intCast(n)])) break;
    }
    _ = ws.shutdown(to, SD_SEND);
}

fn relay(a: ws.SOCKET, b: ws.SOCKET) void {
    const t = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, pump, .{ b, a }) catch {
        pump(a, b);
        return;
    };
    pump(a, b);
    t.join();
}

const Target = struct { allowed: bool = false, v6: bool = false, addr4: u32 = 0, addr6: [16]u8 = loopback6, port: u16 = 0 };

/// Prototype egress policy: only loopback destinations are ever connected.
/// Everything else (WebView2 background traffic) is refused and logged.
fn resolveTarget(host_in: []const u8, port: u16) Target {
    var host = host_in;
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    if (std.net.Ip4Address.parse(host, port)) |a| {
        const b: [4]u8 = @bitCast(a.sa.addr);
        return .{ .allowed = b[0] == 127, .addr4 = a.sa.addr, .port = port };
    } else |_| {}
    if (std.net.Ip6Address.parse(host, port)) |a| {
        return .{ .allowed = std.mem.eql(u8, &a.sa.addr, &loopback6), .v6 = true, .addr6 = a.sa.addr, .port = port };
    } else |_| {}
    if (std.ascii.eqlIgnoreCase(host, "localhost") or endsWithIgnoreCase(host, ".localhost"))
        return .{ .allowed = true, .addr4 = loopback4_be, .port = port };
    return .{ .port = port };
}

fn connectTarget(t: Target) ?ws.SOCKET {
    const s = ws.socket(if (t.v6) AF_INET6 else AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == ws.INVALID_SOCKET) return null;
    const rc = if (t.v6) blk: {
        var sa: ws.sockaddr.in6 = .{ .port = beport(t.port), .flowinfo = 0, .addr = t.addr6, .scope_id = 0 };
        break :blk ws.connect(s, @ptrCast(&sa), @sizeOf(ws.sockaddr.in6));
    } else blk: {
        var sa: ws.sockaddr.in = .{ .port = beport(t.port), .addr = t.addr4 };
        break :blk ws.connect(s, @ptrCast(&sa), @sizeOf(ws.sockaddr.in));
    };
    if (rc != 0) {
        _ = ws.closesocket(s);
        return null;
    }
    return s;
}

const HostPort = struct { host: []const u8, port: u16 };
fn splitHostPort(s: []const u8) ?HostPort {
    if (s.len > 0 and s[0] == '[') {
        const close = std.mem.indexOfScalar(u8, s, ']') orelse return null;
        const host = s[0 .. close + 1];
        if (close + 1 < s.len and s[close + 1] == ':')
            return .{ .host = host, .port = std.fmt.parseInt(u16, s[close + 2 ..], 10) catch return null };
        return .{ .host = host, .port = 80 };
    }
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |k|
        return .{ .host = s[0..k], .port = std.fmt.parseInt(u16, s[k + 1 ..], 10) catch return null };
    return .{ .host = s, .port = 80 };
}

// ─── admission ──────────────────────────────────────────────────────────

/// Fills the owner/admission fields of `rec` for the accepted IPv4 proxy
/// connection and returns whether it is admitted.
fn admit(c: *Conn, rec: *ProxyRec) bool {
    const srv = c.srv;
    rec.t_ms = nowMs();
    rec.peer_port = std.mem.bigToNative(u16, c.peer4.port);
    const own = tcpOwner4(c.peer4.addr, c.peer4.port, loopback4_be, beport(srv.port));
    rec.owner_pid = own.pid;
    rec.lookup_us = own.us;
    rec.rows = own.rows;
    if (srv.owner) |env| {
        // An environment is "armed" once its browser PID is known. Pend
        // early connections briefly instead of failing them.
        var waited: i64 = 0;
        while (env.browser_pid.load(.acquire) == 0 and waited < 5000) : (waited += 20) W.kernel32.Sleep(20);
        rec.waited_ms = waited;
    }
    if (srv.owner) |env| {
        var ft = std.time.Timer.start() catch unreachable;
        rec.fast_ok = fastAdmit(own.pid, env.browser_pid.load(.acquire));
        rec.fast_us = ft.read() / 1000;
        rec.in_infos = env.kindOf(own.pid) != null;
    }
    var timer = std.time.Timer.start() catch unreachable;
    if (ProcSnap.create()) |s| {
        defer s.destroy();
        rec.owner_name_len = copyTrunc(&rec.owner_name, s.nameOf(own.pid));
        if (srv.owner) |env| rec.in_tree = isInTree(s, own.pid, env.browser_pid.load(.acquire));
        rec.tree_us = timer.read() / 1000;
        if (envForPid(s, own.pid)) |oe| {
            rec.owner_env = oe.name;
            rec.owner_kind = oe.kindOf(own.pid) orelse -1;
        } else if (own.pid == self_pid) rec.owner_env = "self" else rec.owner_env = "none";
    }
    // Decision = tree walk; fast path and GetProcessInfos are logged for comparison.
    rec.admitted = if (srv.enforce) rec.in_tree else true;
    return rec.admitted;
}

// ─── connection handlers ────────────────────────────────────────────────

fn socksReply(s: ws.SOCKET, code: u8) void {
    _ = sendAll(s, &[_]u8{ 5, code, 0, 1, 0, 0, 0, 0, 0, 0 });
}

fn socksConn(c: *Conn) void {
    defer finishConn(c);
    var rec: ProxyRec = .{ .proxy = c.srv.name, .conn = c.id };
    const admitted = admit(c, &rec);
    defer pushProxyRec(rec);

    var hdr: [2]u8 = undefined;
    if (!recvExact(c.sock, &hdr)) {
        rec.note = "eof before greeting";
        return;
    }
    if (hdr[0] != 5) {
        rec.note = "not socks5";
        return;
    }
    var methods: [255]u8 = undefined;
    if (!recvExact(c.sock, methods[0..hdr[1]])) {
        rec.note = "eof in greeting";
        return;
    }
    rec.methods_len = (std.fmt.bufPrint(&rec.methods, "{x}", .{methods[0..@min(hdr[1], 16)]}) catch "").len;
    if (!admitted) {
        _ = sendAll(c.sock, &[_]u8{ 5, 0xFF });
        rec.note = "REJECTED by PID admission (05 FF)";
        return;
    }
    if (std.mem.indexOfScalar(u8, methods[0..hdr[1]], 0) == null) {
        _ = sendAll(c.sock, &[_]u8{ 5, 0xFF });
        rec.note = "no-auth method not offered";
        return;
    }
    _ = sendAll(c.sock, &[_]u8{ 5, 0 });

    var req: [4]u8 = undefined;
    if (!recvExact(c.sock, &req)) {
        rec.note = "eof before request";
        return;
    }
    var host_buf: [256]u8 = undefined;
    var host: []const u8 = "";
    var tag: []const u8 = "?";
    switch (req[3]) {
        1 => {
            var a: [4]u8 = undefined;
            if (!recvExact(c.sock, &a)) return;
            host = std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }) catch "";
            tag = "ipv4";
        },
        3 => {
            var l: [1]u8 = undefined;
            if (!recvExact(c.sock, &l)) return;
            if (!recvExact(c.sock, host_buf[0..l[0]])) return;
            host = host_buf[0..l[0]];
            tag = "domain";
        },
        4 => {
            var a: [16]u8 = undefined;
            if (!recvExact(c.sock, &a)) return;
            host = std.fmt.bufPrint(&host_buf, "{x}", .{&a}) catch "";
            tag = "ipv6";
        },
        else => {
            rec.note = "bad ATYP";
            return;
        },
    }
    var pb: [2]u8 = undefined;
    if (!recvExact(c.sock, &pb)) return;
    const port = std.mem.readInt(u16, &pb, .big);
    rec.target_len = (std.fmt.bufPrint(&rec.target, "{s}:{s}:{d}", .{ tag, host, port }) catch "").len;
    if (req[1] != 1) {
        socksReply(c.sock, 7);
        rec.note = "command not supported";
        return;
    }
    const t = resolveTarget(host, port);
    if (!t.allowed) {
        socksReply(c.sock, 2);
        rec.note = "target refused (non-loopback; prototype never egresses)";
        return;
    }
    const up = connectTarget(t) orelse {
        socksReply(c.sock, 5);
        rec.note = "upstream connect failed";
        return;
    };
    defer _ = ws.closesocket(up);
    socksReply(c.sock, 0);
    rec.note = "tunnel";
    var first: [8192]u8 = undefined;
    const n = ws.recv(c.sock, &first, first.len, 0);
    if (n <= 0) return;
    const chunk = first[0..@intCast(n)];
    rec.reqline_len = copyTrunc(&rec.reqline, chunk[0 .. std.mem.indexOf(u8, chunk, "\r\n") orelse chunk.len]);
    if (!sendAll(up, chunk)) return;
    relay(c.sock, up);
}

fn httpProxyConn(c: *Conn) void {
    defer finishConn(c);
    const srv = c.srv;
    var rec: ProxyRec = .{ .proxy = srv.name, .conn = c.id };
    _ = admit(c, &rec); // logged only: the fallback relies on credentials
    defer pushProxyRec(rec);
    var buf: [16384]u8 = undefined;
    var carry: usize = 0;
    var first = true;
    while (true) {
        const h = readHead(c.sock, &buf, carry) orelse {
            if (rec.note.len == 0) rec.note = "eof";
            return;
        };
        const head = buf[0..h.head_len];
        const line = head[0 .. std.mem.indexOf(u8, head, "\r\n") orelse head.len];
        rec.reqline_len = copyTrunc(&rec.reqline, line);
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const method = it.next() orelse "";
        const target = it.next() orelse "";
        const pa = headerValue(head, "Proxy-Authorization");
        if (first) {
            rec.first_had_auth = pa != null;
            first = false;
        }
        const ok = if (srv.auth) |want| (pa != null and std.mem.eql(u8, pa.?, want)) else true;
        if (!ok) {
            rec.auth_407 += 1;
            _ = srv.n407.fetchAdd(1, .monotonic);
            logf("{s}: conn {d}: 407 for \"{s}\" (Proxy-Authorization {s})", .{ srv.name, c.id, line, if (pa == null) "absent" else "wrong" });
            if (!sendAll(c.sock, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"wmux-s5\"\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")) return;
            carry = h.total - h.head_len;
            std.mem.copyForwards(u8, buf[0..carry], buf[h.head_len..h.total]);
            continue;
        }
        _ = srv.nauth.fetchAdd(1, .monotonic);
        const is_connect = std.mem.eql(u8, method, "CONNECT");
        var authority = target;
        if (!is_connect) {
            if (!std.mem.startsWith(u8, target, "http://")) {
                _ = sendAll(c.sock, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                rec.note = "unsupported request form";
                return;
            }
            const rest = target[7..];
            authority = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        }
        const hp = splitHostPort(authority) orelse {
            rec.note = "bad target";
            return;
        };
        rec.target_len = (std.fmt.bufPrint(&rec.target, "{s}:{s}:{d}", .{ if (is_connect) "connect" else "absolute", hp.host, hp.port }) catch "").len;
        const t = resolveTarget(hp.host, hp.port);
        if (!t.allowed) {
            _ = sendAll(c.sock, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            rec.note = "target refused (non-loopback; prototype never egresses)";
            return;
        }
        const up = connectTarget(t) orelse {
            _ = sendAll(c.sock, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            rec.note = "upstream connect failed";
            return;
        };
        defer _ = ws.closesocket(up);
        if (is_connect) {
            if (!sendAll(c.sock, "HTTP/1.1 200 Connection Established\r\n\r\n")) return;
            if (h.total > h.head_len and !sendAll(up, buf[h.head_len..h.total])) return;
            rec.note = "CONNECT tunnel (authorized)";
        } else {
            if (!sendAll(up, buf[0..h.total])) return;
            rec.note = "absolute-form request forwarded (authorized)";
        }
        relay(c.sock, up);
        return;
    }
}

const page_html =
    \\<!doctype html><html><head><meta charset="utf-8"><title>loaded</title></head><body>s5 probe
    \\<script>
    \\(function () {
    \\  var tag = location.pathname.replace(/^\//, '') || 'root';
    \\  try {
    \\    var ws = new WebSocket('ws://' + location.host + '/ws/' + tag);
    \\    ws.onopen = function () { ws.send('echo-' + tag); };
    \\    ws.onmessage = function (e) { document.title = 'ws-ok:' + e.data; };
    \\    ws.onerror = function () { document.title = 'ws-error'; };
    \\  } catch (e) { document.title = 'ws-throw'; }
    \\})();
    \\</script></body></html>
;

fn originConn(c: *Conn) void {
    defer finishConn(c);
    var buf: [16384]u8 = undefined;
    const h = readHead(c.sock, &buf, 0) orelse return;
    const head = buf[0..h.head_len];
    var rec: OriginRec = .{ .conn = c.id, .family = c.family, .t_ms = nowMs() };
    const line = head[0 .. std.mem.indexOf(u8, head, "\r\n") orelse head.len];
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next();
    const target = it.next() orelse "";
    var path = target;
    if (std.mem.startsWith(u8, target, "http://")) {
        rec.absolute_form = true;
        const rest = target[7..];
        path = if (std.mem.indexOfScalar(u8, rest, '/')) |k| rest[k..] else "/";
    }
    rec.path_len = copyTrunc(&rec.path, path);
    rec.host_len = copyTrunc(&rec.host, headerValue(head, "Host") orelse "");
    const own = if (c.family == AF_INET)
        tcpOwner4(c.peer4.addr, c.peer4.port, loopback4_be, beport(c.srv.port))
    else
        tcpOwner6(c.peer6.addr, c.peer6.port, loopback6, beport(c.srv.port));
    rec.owner_pid = own.pid;
    if (own.pid == self_pid) {
        rec.via = "proxy-relay";
    } else if (ProcSnap.create()) |s| {
        defer s.destroy();
        rec.via = if (envForPid(s, own.pid)) |e| e.direct_tag else "direct-unknown";
    }
    const upgrade = headerValue(head, "Upgrade") orelse "";
    if (std.ascii.eqlIgnoreCase(upgrade, "websocket")) {
        wsEcho(c.sock, head, buf[h.head_len..h.total], &rec);
        pushOriginRec(rec);
        return;
    }
    pushOriginRec(rec);
    if (std.mem.eql(u8, path, "/favicon.ico")) {
        _ = sendAll(c.sock, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    } else {
        var hb: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{page_html.len}) catch return;
        if (!sendAll(c.sock, hdr) or !sendAll(c.sock, page_html)) return;
    }
    _ = ws.shutdown(c.sock, SD_SEND);
    drain(c.sock);
}

fn wsEcho(s: ws.SOCKET, head: []const u8, extra: []const u8, rec: *OriginRec) void {
    const key = headerValue(head, "Sec-WebSocket-Key") orelse return;
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var acc: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&acc, &digest);
    var hb: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&hb, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{acc[0..]}) catch return;
    if (!sendAll(s, resp)) return;
    var fb: [2048]u8 = undefined;
    var have = copyTrunc(&fb, extra);
    have = readAtLeast(s, &fb, have, 2) orelse return;
    const len7: usize = fb[1] & 0x7F;
    if (len7 >= 126) return; // short frames only (prototype)
    _ = readAtLeast(s, &fb, have, 6 + len7) orelse return;
    var out: [2 + 125]u8 = undefined;
    out[0] = 0x81;
    out[1] = @intCast(len7);
    for (0..len7) |k| out[2 + k] = fb[6 + k] ^ fb[2 + (k % 4)];
    rec.ws_len = copyTrunc(&rec.ws_echo, out[2 .. 2 + len7]);
    _ = sendAll(s, out[0 .. 2 + len7]);
    _ = sendAll(s, &[_]u8{ 0x88, 0x02, 0x03, 0xE8 });
    _ = ws.shutdown(s, SD_SEND);
    drain(s);
}

// ─── environments ───────────────────────────────────────────────────────

const State = enum { idle, creating_env, creating_ctrl, navigating, waiting_ws, fetching_err, done, failed };
const AuthMode = enum { none, provide, cancel };

const UrlResult = struct {
    url: []const u8 = "",
    nav_ok: bool = false,
    web_error: i32 = -1,
    nav_ms: i64 = 0,
    title: [64]u8 = undefined,
    title_len: usize = 0,
    err: [200]u8 = undefined,
    err_len: usize = 0,
    note: []const u8 = "",
    auth_retries: u32 = 0,

    fn wsOk(self: *const UrlResult) bool {
        return std.mem.startsWith(u8, self.title[0..self.title_len], "ws-ok:");
    }
};

const Env = struct {
    name: []const u8,
    direct_tag: []const u8 = "",
    udf: []const u8 = "",
    udf_w: [:0]u16 = undefined,
    args: []const u8 = "",
    args_w: [:0]u16 = undefined,
    urls: []const []const u8 = &.{},
    auth: AuthMode = .none,
    defer_auth: bool = false,
    probe_only: bool = false,
    late_broker: ?*Server = null,
    late_broker_port: u16 = 0,
    release_env_early: bool = false,
    hwnd: ?HWND = null,
    browser_handle: ?HANDLE = null,
    t_browser_exit: i64 = 0,
    t_tree_empty: i64 = 0,
    t_killed: i64 = 0,
    killed_n: usize = 0,
    close_hr: HRESULT = 0,
    cur_nav_id: u64 = 0,
    other_completions: u32 = 0,
    pending_deferral: ?*RawCom = null,
    pending_args: ?*RawCom = null,
    deferral_due: i64 = 0,
    last_alive: []const u8 = "",
    options: EnvOptions = undefined,
    env: ?*wv2.ICoreWebView2Environment = null,
    controller: ?*wv2.ICoreWebView2Controller = null,
    webview: ?*wv2.ICoreWebView2 = null,
    browser_pid: std.atomic.Value(u32) = .init(0),
    armed_by: []const u8 = "",
    webview_bpid: u32 = 0,
    infos_mutex: std.Thread.Mutex = .{},
    infos_pid: [64]u32 = undefined,
    infos_kind: [64]i32 = undefined,
    infos_n: usize = 0,
    infos_at_create: []const u8 = "",
    state: State = .idle,
    url_i: usize = 0,
    deadline: i64 = 0,
    t_env_start: i64 = 0,
    t_env_done: i64 = 0,
    t_ctrl_done: i64 = 0,
    t_nav: i64 = 0,
    env_hr: HRESULT = 0,
    ctrl_hr: HRESULT = 0,
    results: [8]UrlResult = [_]UrlResult{.{}} ** 8,
    auth_events: u32 = 0,
    auth_uri: []const u8 = "",
    auth_challenge: []const u8 = "",
    exited: bool = false,
    exit_kind: i32 = -1,
    exit_pid: u32 = 0,
    t_exit: i64 = 0,
    udf_deleted: bool = false,
    t_deleted: i64 = 0,
    delete_err: []const u8 = "",

    fn kindOf(self: *Env, pid: u32) ?i32 {
        self.infos_mutex.lock();
        defer self.infos_mutex.unlock();
        for (0..self.infos_n) |i| if (self.infos_pid[i] == pid) return self.infos_kind[i];
        return null;
    }
    fn isFinished(self: *const Env) bool {
        return self.state == .done or self.state == .failed;
    }
    fn cur(self: *Env) *UrlResult {
        return &self.results[self.url_i];
    }
};

var env_store: [12]Env = undefined;
var envs: []Env = &.{};
var loader: *wv2.Loader = undefined;
var hinst: ?*anyopaque = null;
var msg_hwnd: ?HWND = null;
const class_name = L("WmuxS5ProbeHost");

fn envForPid(s: *const ProcSnap, pid: u32) ?*Env {
    for (envs) |*e| {
        if (e.probe_only) continue;
        const b = e.browser_pid.load(.acquire);
        if (b == 0) continue;
        if (e.kindOf(pid) != null or isInTree(s, pid, b)) return e;
    }
    return null;
}

fn kindName(k: i32) []const u8 {
    return switch (k) {
        0 => "browser",
        1 => "renderer",
        2 => "utility",
        3 => "sandbox_helper",
        4 => "gpu",
        5 => "ppapi_plugin",
        6 => "ppapi_broker",
        else => "?",
    };
}

/// Arms admission for `e`: records the browser PID and keeps a SYNCHRONIZE
/// handle so the browser's exit can be observed even after the
/// environment object is released.
fn armBrowser(e: *Env, pid: u32, by: []const u8) void {
    e.browser_pid.store(pid, .release);
    e.armed_by = by;
    e.browser_handle = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
    logf("env {s}: armed with browser pid {d} via {s} at {d} ms", .{ e.name, pid, by, nowMs() });
}

fn refreshInfos(e: *Env, why: []const u8) void {
    const env = e.env orelse return;
    const e8 = raw(env).qi(&IID_Env8) orelse {
        logf("env {s}: ICoreWebView2Environment8 unavailable", .{e.name});
        return;
    };
    defer e8.release();
    var coll: ?*RawCom = null;
    const hr = e8.fnAt(slot.env8_GetProcessInfos, GetObjFn)(e8, &coll);
    if (hr != 0 or coll == null) {
        logf("env {s}: GetProcessInfos failed hr=0x{x:0>8}", .{ e.name, hx(hr) });
        return;
    }
    const cl = coll.?;
    defer cl.release();
    var count: u32 = 0;
    _ = cl.fnAt(slot.coll_get_Count, GetU32Fn)(cl, &count);
    var lb: [600]u8 = undefined;
    var ll: usize = 0;
    e.infos_mutex.lock();
    e.infos_n = 0;
    var k: u32 = 0;
    while (k < count and e.infos_n < e.infos_pid.len) : (k += 1) {
        var info: ?*RawCom = null;
        if (cl.fnAt(slot.coll_GetValueAtIndex, GetAtFn)(cl, k, &info) != 0 or info == null) continue;
        const in = info.?;
        defer in.release();
        var pid: i32 = 0;
        var kind: i32 = -1;
        _ = in.fnAt(slot.info_get_ProcessId, GetI32Fn)(in, &pid);
        _ = in.fnAt(slot.info_get_Kind, GetI32Fn)(in, &kind);
        e.infos_pid[e.infos_n] = @intCast(pid);
        e.infos_kind[e.infos_n] = kind;
        e.infos_n += 1;
        ll += (std.fmt.bufPrint(lb[ll..], "{d}:{s} ", .{ pid, kindName(kind) }) catch "").len;
        if (kind == 0 and e.browser_pid.load(.acquire) == 0) {
            armBrowser(e, @intCast(pid), "GetProcessInfos");
        }
    }
    e.infos_mutex.unlock();
    logf("env {s}: process infos ({s}): {s}", .{ e.name, why, lb[0..ll] });
    if (std.mem.eql(u8, why, "env-created")) e.infos_at_create = gpa.dupe(u8, lb[0..ll]) catch "";
}

fn createHiddenWindow(title: [*:0]const u16) ?HWND {
    const hwnd = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, class_name, title, WS_POPUP | WS_CLIPCHILDREN, -32000, -32000, 640, 480, null, null, hinst, null) orelse return null;
    _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    return hwnd;
}

fn startEnv(e: *Env) void {
    e.state = .creating_env;
    e.t_env_start = nowMs();
    logf("env {s}: creating (udf={s}) args=\"{s}\"", .{ e.name, e.udf, e.args });
    const h = EnvDone.create(gpa, e, onEnvCreated) catch {
        e.state = .failed;
        return;
    };
    defer h.unref();
    const hr = loader.CreateCoreWebView2EnvironmentWithOptions(null, e.udf_w.ptr, @ptrCast(&e.options), @ptrCast(h));
    if (hr != 0) {
        e.env_hr = hr;
        e.state = .failed;
        logf("env {s}: CreateCoreWebView2EnvironmentWithOptions returned 0x{x:0>8} synchronously", .{ e.name, hx(hr) });
        checkAllDone();
    }
}

fn onEnvCreated(e: *Env, hr: HRESULT, envp: ?*wv2.ICoreWebView2Environment) void {
    e.t_env_done = nowMs();
    e.env_hr = hr;
    if (hr != 0 or envp == null) {
        logf("env {s}: environment creation FAILED hr=0x{x:0>8} after {d} ms", .{ e.name, hx(hr), e.t_env_done - e.t_env_start });
        e.state = .failed;
        checkAllDone();
        return;
    }
    const env = envp.?;
    env.addRef();
    e.env = env;
    logf("env {s}: environment created in {d} ms", .{ e.name, e.t_env_done - e.t_env_start });
    refreshInfos(e, "env-created");
    if (raw(env).qi(&IID_Env8)) |e8| {
        defer e8.release();
        if (InfosChangedHandler.create(gpa, e, onInfosChanged)) |h| {
            var tok: wv2.EventRegistrationToken = .{};
            _ = e8.fnAt(slot.env8_add_ProcessInfosChanged, AddHandlerFn)(e8, @ptrCast(h), &tok);
            h.unref();
        } else |_| {}
    }
    if (raw(env).qi(&IID_Env5)) |e5| {
        defer e5.release();
        if (BrowserExitedHandler.create(gpa, e, onBrowserExited)) |h| {
            var tok: wv2.EventRegistrationToken = .{};
            _ = e5.fnAt(slot.env5_add_BrowserProcessExited, AddHandlerFn)(e5, @ptrCast(h), &tok);
            h.unref();
        } else |_| {}
    }
    if (e.probe_only) logf("env {s}: environment object created on the busy user-data folder (creation is lazy); creating a controller", .{e.name});
    e.state = .creating_ctrl;
    const h = CtrlDone.create(gpa, e, onCtrlCreated) catch {
        e.state = .failed;
        checkAllDone();
        return;
    };
    defer h.unref();
    env.createController(e.hwnd.?, h) catch {
        logf("env {s}: CreateCoreWebView2Controller failed synchronously", .{e.name});
        e.state = .failed;
        checkAllDone();
    };
}

fn onInfosChanged(e: *Env, _: ?*wv2.ICoreWebView2Environment, _: ?*wv2.IUnknown) void {
    refreshInfos(e, "changed");
}

fn onBrowserExited(e: *Env, _: ?*wv2.ICoreWebView2Environment, args: ?*RawCom) void {
    var kind: i32 = -1;
    var pid: u32 = 0;
    if (args) |a| {
        _ = a.fnAt(slot.exited_get_Kind, GetI32Fn)(a, &kind);
        _ = a.fnAt(slot.exited_get_BrowserProcessId, GetU32Fn)(a, &pid);
    }
    e.exited = true;
    e.exit_kind = kind;
    e.exit_pid = pid;
    e.t_exit = nowMs();
    logf("env {s}: BrowserProcessExited kind={d} ({s}) pid={d}, {d} ms after close started", .{
        e.name, kind, if (kind == 0) "normal" else "failed", pid, e.t_exit - close_start,
    });
}

fn onCtrlCreated(e: *Env, hr: HRESULT, ctrl: ?*wv2.ICoreWebView2Controller) void {
    e.t_ctrl_done = nowMs();
    e.ctrl_hr = hr;
    if (hr != 0 or ctrl == null) {
        logf("env {s}: controller creation FAILED hr=0x{x:0>8}", .{ e.name, hx(hr) });
        e.state = .failed;
        checkAllDone();
        return;
    }
    const c = ctrl.?;
    c.addRef();
    e.controller = c;
    const wv = c.getCoreWebView2() catch {
        e.state = .failed;
        checkAllDone();
        return;
    };
    e.webview = wv;
    var bpid: u32 = 0;
    const bhr = raw(wv).fnAt(slot.webview_get_BrowserProcessId, GetU32Fn)(raw(wv), &bpid);
    e.webview_bpid = bpid;
    const infos_pid = e.browser_pid.load(.acquire);
    if (infos_pid == 0) armBrowser(e, bpid, "ICoreWebView2.BrowserProcessId");
    logf("env {s}: controller ready {d} ms after env; BrowserProcessId={d} (hr=0x{x:0>8}); GetProcessInfos browser={d} -> {s}", .{
        e.name, e.t_ctrl_done - e.t_env_done, bpid, hx(bhr), infos_pid, if (infos_pid == bpid) "MATCH" else "MISMATCH",
    });
    c.putBounds(.{ .left = 0, .top = 0, .right = 640, .bottom = 480 }) catch {};
    c.putIsVisible(true) catch {};
    if (std.mem.eql(u8, e.name, "A")) {
        for (envs) |*f| if (f.probe_only) startEnv(f);
    }
    if (e.probe_only) {
        logf("env {s}: UNEXPECTED controller on a busy user-data folder with different args; browser pid {d} (A's is {d})", .{ e.name, bpid, env_store[0].browser_pid.load(.acquire) });
        e.state = .done;
        checkAllDone();
        return;
    }
    if (NavDone.create(gpa, e, onNavCompleted)) |h| {
        _ = wv.addNavigationCompleted(h) catch {};
        h.unref();
    } else |_| {}
    if (NavStartingHandler.create(gpa, e, onNavStarting)) |h| {
        var tok: wv2.EventRegistrationToken = .{};
        _ = raw(wv).fnAt(slot.webview_add_NavigationStarting, AddHandlerFn)(raw(wv), @ptrCast(h), &tok);
        h.unref();
    } else |_| {}
    if (TitleChanged.create(gpa, e, onTitleChanged)) |h| {
        _ = wv.addDocumentTitleChanged(h) catch {};
        h.unref();
    } else |_| {}
    if (e.auth != .none) {
        if (raw(wv).qi(&IID_WebView2_10)) |w10| {
            defer w10.release();
            if (BasicAuthHandler.create(gpa, e, onBasicAuth)) |h| {
                var tok: wv2.EventRegistrationToken = .{};
                const ahr = w10.fnAt(slot.webview10_add_BasicAuthenticationRequested, AddHandlerFn)(w10, @ptrCast(h), &tok);
                h.unref();
                logf("env {s}: add_BasicAuthenticationRequested hr=0x{x:0>8}", .{ e.name, hx(ahr) });
            } else |_| {}
        } else logf("env {s}: ICoreWebView2_10 unavailable", .{e.name});
    }
    e.url_i = 0;
    navigateCurrent(e);
}

fn navigateCurrent(e: *Env) void {
    while (e.url_i < e.urls.len) {
        const url = e.urls[e.url_i];
        e.cur().* = .{ .url = url };
        if (e.late_broker) |srv| {
            if (e.url_i == 1 and srv.sock == ws.INVALID_SOCKET) {
                startServer(srv, e.late_broker_port) catch |err| logf("env {s}: late broker on :{d} failed: {s}", .{ e.name, e.late_broker_port, @errorName(err) });
            }
        }
        e.state = .navigating;
        e.cur_nav_id = 0;
        e.t_nav = nowMs();
        e.deadline = e.t_nav + 20_000;
        logf("env {s}: navigate #{d} {s}", .{ e.name, e.url_i, url });
        const w = std.unicode.utf8ToUtf16LeAllocZ(gpa, url) catch return;
        defer gpa.free(w);
        e.webview.?.navigate(w.ptr) catch {
            e.cur().note = "Navigate() failed";
            e.url_i += 1;
            continue;
        };
        return;
    }
    e.state = .done;
    logf("env {s}: all navigations finished", .{e.name});
    checkAllDone();
}

fn advance(e: *Env) void {
    e.url_i += 1;
    navigateCurrent(e);
}

fn onNavStarting(e: *Env, _: ?*wv2.ICoreWebView2, args: ?*RawCom) void {
    const a = args orelse return;
    var uri: ?[*:0]u16 = null;
    _ = a.fnAt(slot.navstart_get_Uri, GetStrFn)(a, &uri);
    const u8s = w2u(uri);
    if (uri) |p| wv2.CoTaskMemFree(p);
    var id: u64 = 0;
    _ = a.fnAt(slot.navstart_get_NavigationId, GetU64Fn)(a, &id);
    const mine = e.state == .navigating and e.cur_nav_id == 0;
    if (mine) e.cur_nav_id = id;
    logf("env {s}: NavigationStarting id={d} uri={s}{s}", .{ e.name, id, u8s, if (mine) "" else " (not the tracked navigation)" });
}

fn onNavCompleted(e: *Env, _: ?*wv2.ICoreWebView2, args: ?*wv2.ICoreWebView2NavigationCompletedEventArgs) void {
    const a = args orelse return;
    var id: u64 = 0;
    _ = raw(a).fnAt(slot.navdone_get_NavigationId, GetU64Fn)(raw(a), &id);
    // Only the completion of the navigation whose NavigationStarting we saw
    // after our Navigate() counts; anything else is a stale or internal one.
    if (e.state != .navigating or e.cur_nav_id == 0 or id != e.cur_nav_id) {
        e.other_completions += 1;
        logf("env {s}: NavigationCompleted id={d} success={} WebErrorStatus={d} ignored (tracked id={d}, state={s})", .{
            e.name, id, a.getIsSuccess() catch false, a.getWebErrorStatus() catch -1, e.cur_nav_id, @tagName(e.state),
        });
        return;
    }
    const r = e.cur();
    r.nav_ok = a.getIsSuccess() catch false;
    r.web_error = a.getWebErrorStatus() catch -1;
    r.nav_ms = nowMs() - e.t_nav;
    logf("env {s}: NavigationCompleted #{d} id={d} success={} WebErrorStatus={d} after {d} ms", .{ e.name, e.url_i, id, r.nav_ok, r.web_error, r.nav_ms });
    if (!r.nav_ok and r.web_error == 18 and e.auth == .provide and r.auth_retries < 2) {
        // VALID_PROXY_AUTHENTICATION_REQUIRED: WebView2 completes the
        // challenged navigation and starts a new one (new NavigationId,
        // same URI) once credentials were supplied. Track that one.
        r.auth_retries += 1;
        r.note = "first attempt completed with WebErrorStatus 18; tracked WebView2's automatic retry";
        e.cur_nav_id = 0;
        e.deadline = nowMs() + 20_000;
        logf("env {s}: waiting for the automatic re-navigation after proxy authentication", .{e.name});
        return;
    }
    if (r.nav_ok) {
        e.state = .waiting_ws;
        e.deadline = nowMs() + 8_000;
        checkTitle(e);
        return;
    }
    e.state = .fetching_err;
    e.deadline = nowMs() + 3_000;
    const h = ScriptDone.create(gpa, e, onErrText) catch {
        advance(e);
        return;
    };
    defer h.unref();
    e.webview.?.executeScript(L("(document.title || '') + ' | ' + (document.body ? document.body.innerText.replace(/\\s+/g, ' ').slice(0, 400) : '')"), h) catch advance(e);
}

fn onErrText(e: *Env, hr: HRESULT, json: ?[*:0]const u16) void {
    if (e.state != .fetching_err) return;
    const txt = w2u(json);
    const r = e.cur();
    if (std.mem.indexOf(u8, txt, "ERR_")) |k| {
        var end = k;
        while (end < txt.len and (std.ascii.isAlphanumeric(txt[end]) or txt[end] == '_')) end += 1;
        r.err_len = copyTrunc(&r.err, txt[k..end]);
    } else r.err_len = copyTrunc(&r.err, txt);
    logf("env {s}: error page (hr=0x{x:0>8}): {s}", .{ e.name, hx(hr), txt });
    advance(e);
}

fn checkTitle(e: *Env) void {
    if (e.state != .waiting_ws) return;
    const t = e.webview.?.getDocumentTitle() catch return;
    defer wv2.CoTaskMemFree(t);
    const s = w2u(t);
    if (std.mem.startsWith(u8, s, "ws-")) {
        const r = e.cur();
        r.title_len = copyTrunc(&r.title, s);
        logf("env {s}: page title \"{s}\" ({d} ms after navigate)", .{ e.name, s, nowMs() - e.t_nav });
        advance(e);
    }
}

fn onTitleChanged(e: *Env, _: ?*wv2.ICoreWebView2, _: ?*wv2.IUnknown) void {
    checkTitle(e);
}

fn onBasicAuth(e: *Env, _: ?*wv2.ICoreWebView2, args_opt: ?*RawCom) void {
    const args = args_opt orelse return;
    e.auth_events += 1;
    var uri: ?[*:0]u16 = null;
    var chal: ?[*:0]u16 = null;
    const h1 = args.fnAt(slot.auth_get_Uri, GetStrFn)(args, &uri);
    const h2 = args.fnAt(slot.auth_get_Challenge, GetStrFn)(args, &chal);
    const uri8 = w2u(uri);
    const chal8 = w2u(chal);
    if (uri) |p| wv2.CoTaskMemFree(p);
    if (chal) |p| wv2.CoTaskMemFree(p);
    if (e.auth_events == 1) {
        e.auth_uri = uri8;
        e.auth_challenge = chal8;
    }
    logf("env {s}: BasicAuthenticationRequested #{d}: Uri=\"{s}\" (hr=0x{x:0>8}) Challenge=\"{s}\" (hr=0x{x:0>8})", .{ e.name, e.auth_events, uri8, hx(h1), chal8, hx(h2) });
    if (e.auth == .cancel) {
        const hr = args.fnAt(slot.auth_put_Cancel, PutBoolFn)(args, 1);
        logf("env {s}: cancelled the challenge (hr=0x{x:0>8})", .{ e.name, hx(hr) });
        return;
    }
    if (e.defer_auth and e.pending_deferral == null) {
        var d: ?*RawCom = null;
        const dhr = args.fnAt(slot.auth_GetDeferral, GetObjFn)(args, &d);
        if (dhr == 0 and d != null) {
            args.addRef();
            e.pending_args = args;
            e.pending_deferral = d;
            e.deferral_due = nowMs() + 150;
            logf("env {s}: took a deferral; credentials will be supplied in 150 ms", .{e.name});
            return;
        }
        logf("env {s}: GetDeferral failed hr=0x{x:0>8}; answering synchronously", .{ e.name, hx(dhr) });
    }
    supplyCredentials(e, args);
}

fn supplyCredentials(e: *Env, args: *RawCom) void {
    var resp: ?*RawCom = null;
    const rhr = args.fnAt(slot.auth_get_Response, GetObjFn)(args, &resp);
    if (rhr != 0 or resp == null) {
        _ = args.fnAt(slot.auth_put_Cancel, PutBoolFn)(args, 1);
        logf("env {s}: get_Response failed hr=0x{x:0>8}; cancelled", .{ e.name, hx(rhr) });
        return;
    }
    const r = resp.?;
    defer r.release();
    const hu = r.fnAt(slot.resp_put_UserName, PutStrFn)(r, L("wmux"));
    const pw = std.unicode.utf8ToUtf16LeAllocZ(gpa, proxy_secret) catch return;
    defer gpa.free(pw);
    const hp = r.fnAt(slot.resp_put_Password, PutStrFn)(r, pw.ptr);
    logf("env {s}: supplied proxy credentials (put_UserName hr=0x{x:0>8}, put_Password hr=0x{x:0>8})", .{ e.name, hx(hu), hx(hp) });
}

/// Completes a pending BasicAuthenticationRequested deferral (E2 variant).
fn completeDeferral(e: *Env) void {
    const d = e.pending_deferral orelse return;
    const args = e.pending_args.?;
    supplyCredentials(e, args);
    const chr = d.fnAt(slot.deferral_Complete, NoArgFn)(d);
    logf("env {s}: deferral completed (hr=0x{x:0>8})", .{ e.name, hx(chr) });
    d.release();
    args.release();
    e.pending_deferral = null;
    e.pending_args = null;
}

// ─── phases ─────────────────────────────────────────────────────────────

const Phase = enum { running, hold, closing, deleting, finished };
var phase: Phase = .running;
var global_deadline: i64 = 0;
var hold_start: i64 = 0;
var close_start: i64 = 0;
var delete_start: i64 = 0;
var scratch_dir: []const u8 = "";
var hold_flag_path: []const u8 = "";
var hold_done_path: []const u8 = "";
var proxy_secret: []const u8 = "";
var self_intruder: []const u8 = "not run";
var bench_text: []const u8 = "not run";

fn checkAllDone() void {
    if (phase != .running) return;
    for (envs) |*e| {
        if (e.probe_only and e.state == .idle and env_store[0].state == .failed) continue;
        if (!e.isFinished()) return;
    }
    beginHold();
}

fn tick() void {
    const now = nowMs();
    switch (phase) {
        .running => {
            for (envs) |*e| {
                if (e.pending_deferral != null and now >= e.deferral_due) completeDeferral(e);
                switch (e.state) {
                    .navigating, .waiting_ws, .fetching_err => if (now > e.deadline) {
                        e.cur().note = switch (e.state) {
                            .navigating => "navigation timeout",
                            .waiting_ws => "websocket title timeout",
                            else => "error text timeout",
                        };
                        logf("env {s}: #{d} {s}", .{ e.name, e.url_i, e.cur().note });
                        advance(e);
                    },
                    else => {},
                }
            }
            if (phase == .running and now > global_deadline) {
                logf("GLOBAL TIMEOUT; moving on", .{});
                beginHold();
            }
        },
        .hold => if (fileExists(hold_done_path) or now - hold_start > 60_000) beginClose(),
        .closing => {
            for (envs) |*e| {
                if (e.browser_handle) |h| {
                    if (e.t_browser_exit == 0 and W.kernel32.WaitForSingleObject(h, 0) == WAIT_OBJECT_0) {
                        e.t_browser_exit = now;
                        logf("env {s}: browser process {d} exited {d} ms after Close()", .{ e.name, e.browser_pid.load(.acquire), now - close_start });
                    }
                }
            }
            if (now - last_tree_scan >= 2000) {
                last_tree_scan = now;
                const gone = scanTrees(now);
                if (now - close_start >= 60_000 and !kill_done) {
                    kill_done = true;
                    for (envs) |*e| {
                        if (e.env != null and !e.exited) killTree(e);
                    }
                }
                var all_exited = true;
                for (envs) |*e| {
                    if (e.env != null and !e.exited) all_exited = false;
                }
                if ((gone and all_exited) or now - close_start > 240_000) beginDelete();
            }
        },
        .deleting => {
            var all = true;
            for (envs) |*e| {
                if (e.probe_only or e.udf_deleted) continue;
                std.fs.deleteTreeAbsolute(e.udf) catch |err| {
                    e.delete_err = @errorName(err);
                    all = false;
                    continue;
                };
                if (!fileExists(e.udf)) {
                    e.udf_deleted = true;
                    e.t_deleted = now;
                    logf("env {s}: user-data folder deleted {d} ms after close started", .{ e.name, now - close_start });
                } else all = false;
            }
            if (all or now - delete_start > 20_000) {
                phase = .finished;
                _ = KillTimer(msg_hwnd, 1);
                PostQuitMessage(0);
            }
        },
        .finished => {},
    }
}

fn beginHold() void {
    phase = .hold;
    hold_start = nowMs();
    const t1 = std.Thread.spawn(.{}, selfIntruderTest, .{}) catch null;
    const t2 = std.Thread.spawn(.{}, benchLookups, .{}) catch null;
    if (t1) |t| t.join();
    if (t2) |t| t.join();
    var buf: [1024]u8 = undefined;
    var n: usize = (std.fmt.bufPrint(&buf, "{{\"pid\":{d},\"origin\":{d},\"socksA\":{d},\"socksB\":{d},\"socksD\":{d},\"socksOpen\":{d},\"httpE\":{d},\"httpG\":{d},\"browsers\":{{", .{
        self_pid, srv_origin4.port, srv_socksA.port, srv_socksB.port, srv_socksD.port, srv_socksOpen.port, srv_httpE.port, srv_httpG.port,
    }) catch "").len;
    var first = true;
    for (envs) |*e| {
        if (e.probe_only) continue;
        n += (std.fmt.bufPrint(buf[n..], "{s}\"{s}\":{d}", .{ if (first) "" else ",", e.name, e.browser_pid.load(.acquire) }) catch "").len;
        first = false;
    }
    n += (std.fmt.bufPrint(buf[n..], "}}}}", .{}) catch "").len;
    if (std.fs.createFileAbsolute(hold_flag_path, .{})) |f| {
        f.writeAll(buf[0..n]) catch {};
        f.close();
    } else |_| {}
    logf("HOLD: {s}", .{buf[0..n]});
}

fn beginClose() void {
    phase = .closing;
    close_start = nowMs();
    last_tree_scan = close_start;
    logf("closing controllers", .{});
    for (envs) |*e| {
        if (e.controller) |c| {
            e.close_hr = c.vtable.Close(c);
            logf("env {s}: ICoreWebView2Controller::Close hr=0x{x:0>8}{s}", .{ e.name, hx(e.close_hr), if (e.release_env_early) "; environment released immediately" else "; environment kept until BrowserProcessExited" });
        }
        if (e.webview) |w| w.release();
        if (e.controller) |c| c.release();
        e.webview = null;
        e.controller = null;
        if (e.release_env_early) {
            if (e.env) |env| env.release();
            e.env = null;
        }
    }
}

var last_tree_scan: i64 = 0;
var kill_done = false;

extern "kernel32" fn TerminateProcess(HANDLE, u32) callconv(.winapi) BOOL;

/// Terminates an environment's browser process tree (used only for
/// folders that are about to be deleted).
fn killTree(e: *Env) void {
    const root = e.browser_pid.load(.acquire);
    if (root == 0) return;
    const s = ProcSnap.create() orelse return;
    defer s.destroy();
    var n: usize = 0;
    for (0..s.n) |i| {
        if (!std.mem.eql(u8, s.name[i][0..s.name_len[i]], "msedgewebview2.exe")) continue;
        if (!isInTree(s, s.pid[i], root)) continue;
        if (OpenProcess(0x0001, 0, s.pid[i])) |h| { // PROCESS_TERMINATE
            if (TerminateProcess(h, 1) != 0) n += 1;
            W.CloseHandle(h);
        }
    }
    e.t_killed = nowMs();
    e.killed_n = n;
    logf("env {s}: browser tree still alive after the grace period; TerminateProcess on {d} processes", .{ e.name, n });
}

/// Logs the WebView2 processes still alive per environment; returns true
/// when every environment's process tree is gone.
fn scanTrees(now: i64) bool {
    const s = ProcSnap.create() orelse return false;
    defer s.destroy();
    var all_gone = true;
    for (envs) |*e| {
        const root = e.browser_pid.load(.acquire);
        if (root == 0 or e.t_tree_empty != 0) continue;
        if (e.probe_only and root == env_store[0].browser_pid.load(.acquire)) continue;
        var lb: [400]u8 = undefined;
        var ll: usize = 0;
        var n: usize = 0;
        for (0..s.n) |i| {
            if (!std.mem.eql(u8, s.name[i][0..s.name_len[i]], "msedgewebview2.exe")) continue;
            if (!isInTree(s, s.pid[i], root)) continue;
            var tb: [32]u8 = undefined;
            n += 1;
            ll += (std.fmt.bufPrint(lb[ll..], "{d}:{s} ", .{ s.pid[i], processType(s.pid[i], &tb) }) catch "").len;
        }
        if (n == 0) {
            e.t_tree_empty = now;
            logf("env {s}: no WebView2 process left ({d} ms after Close())", .{ e.name, now - close_start });
        } else {
            all_gone = false;
            e.last_alive = gpa.dupe(u8, lb[0..ll]) catch "";
            logf("env {s}: {d} processes alive {d} ms after Close(): {s}", .{ e.name, n, now - close_start, lb[0..ll] });
        }
    }
    return all_gone;
}

fn beginDelete() void {
    phase = .deleting;
    delete_start = nowMs();
    for (envs) |*e| {
        if (e.env) |env| env.release();
        e.env = null;
        if (e.hwnd) |h| _ = DestroyWindow(h);
        e.hwnd = null;
    }
}

fn selfIntruderTest() void {
    const s = ws.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == ws.INVALID_SOCKET) return;
    defer _ = ws.closesocket(s);
    var sa: ws.sockaddr.in = .{ .port = beport(srv_socksA.port), .addr = loopback4_be };
    if (ws.connect(s, @ptrCast(&sa), @sizeOf(ws.sockaddr.in)) != 0) {
        self_intruder = "connect failed";
        return;
    }
    if (!sendAll(s, &[_]u8{ 5, 1, 0 })) return;
    var r: [2]u8 = undefined;
    self_intruder = if (!recvExact(s, &r)) "closed by proxy" else if (r[1] == 0xFF) "rejected (05 FF)" else "ADMITTED";
    logf("self-intruder (this process -> socksA): {s}", .{self_intruder});
}

fn benchLookups() void {
    const ls = ws.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    defer _ = ws.closesocket(ls);
    var sa: ws.sockaddr.in = .{ .port = 0, .addr = loopback4_be };
    if (ws.bind(ls, @ptrCast(&sa), @sizeOf(ws.sockaddr.in)) != 0 or ws.listen(ls, 4) != 0) return;
    var la: ws.sockaddr.in = undefined;
    var len: i32 = @sizeOf(ws.sockaddr.in);
    _ = ws.getsockname(ls, @ptrCast(&la), &len);
    const cs = ws.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    defer _ = ws.closesocket(cs);
    if (ws.connect(cs, @ptrCast(&la), @sizeOf(ws.sockaddr.in)) != 0) return;
    const as = ws.accept(ls, null, null);
    defer _ = ws.closesocket(as);
    var ca: ws.sockaddr.in = undefined;
    len = @sizeOf(ws.sockaddr.in);
    _ = ws.getsockname(cs, @ptrCast(&ca), &len);
    var us: [200]u64 = undefined;
    var rows: u32 = 0;
    var correct: usize = 0;
    for (&us) |*u| {
        const o = tcpOwner4(ca.addr, ca.port, la.addr, la.port);
        u.* = o.us;
        rows = o.rows;
        if (o.pid == self_pid) correct += 1;
    }
    std.mem.sort(u64, &us, {}, std.sort.asc(u64));
    var total: u64 = 0;
    for (us) |u| total += u;
    var tus: [30]u64 = undefined;
    for (&tus) |*u| {
        var t = std.time.Timer.start() catch return;
        if (ProcSnap.create()) |s| {
            _ = isInTree(s, self_pid, self_pid);
            s.destroy();
        }
        u.* = t.read() / 1000;
    }
    std.mem.sort(u64, &tus, {}, std.sort.asc(u64));
    bench_text = std.fmt.allocPrint(gpa, "GetExtendedTcpTable(IPv4) lookup over {d} rows: mean {d} us, p50 {d} us, p95 {d} us, max {d} us, correct owner {d}/200; Toolhelp snapshot + walk: p50 {d} us, max {d} us", .{
        rows, total / us.len, us[100], us[190], us[199], correct, tus[15], tus[29],
    }) catch "bench format failed";
    logf("bench: {s}", .{bench_text});
}

// ─── foreground sampler ─────────────────────────────────────────────────

var fg_samples: u64 = 0;
var fg_changes: u64 = 0;

fn samplerMain() void {
    var last: u32 = 0;
    var bad = false;
    while (!stopping.load(.acquire)) {
        if (GetForegroundWindow()) |h| {
            var pid: DWORD = 0;
            _ = GetWindowThreadProcessId(h, &pid);
            if (pid != last) {
                last = pid;
                fg_changes += 1;
                bad = pid == self_pid;
                if (!bad) {
                    if (ProcSnap.create()) |s| {
                        defer s.destroy();
                        bad = isInTree(s, pid, self_pid);
                    }
                }
            }
            if (bad) {
                logf("FOREGROUND VIOLATION: the foreground window belongs to pid {d} in this process tree; aborting", .{pid});
                W.kernel32.ExitProcess(3);
            }
        }
        fg_samples += 1;
        W.kernel32.Sleep(100);
    }
}

// ─── window procedure ───────────────────────────────────────────────────

fn wndProc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    if (msg == WM_TIMER and msg_hwnd != null and hwnd == msg_hwnd.?) {
        tick();
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// ─── setup ──────────────────────────────────────────────────────────────

var srv_origin4: Server = .{ .name = "origin4", .kind = .origin };
var srv_origin6: Server = .{ .name = "origin6", .kind = .origin, .family = AF_INET6 };
var srv_socksA: Server = .{ .name = "socksA", .kind = .socks5, .enforce = true };
var srv_socksB: Server = .{ .name = "socksB", .kind = .socks5, .enforce = true };
var srv_socksD: Server = .{ .name = "socksD", .kind = .socks5, .enforce = true };
var srv_socksOpen: Server = .{ .name = "socksOpen", .kind = .socks5 };
var srv_httpE: Server = .{ .name = "httpE", .kind = .http_proxy };
var srv_httpG: Server = .{ .name = "httpG", .kind = .http_proxy };
var srv_httpE2: Server = .{ .name = "httpE2", .kind = .http_proxy };
var srv_socksH: Server = .{ .name = "socksH", .kind = .socks5, .enforce = true };
var have_ipv6 = false;

fn pathJoin(a: []const u8, b: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ a, b }) catch @panic("oom");
}

fn initEnv(e: *Env, name: []const u8, args: []const u8, urls: []const []const u8) void {
    e.* = .{ .name = name };
    e.direct_tag = std.fmt.allocPrint(gpa, "direct:{s}", .{name}) catch @panic("oom");
    e.udf = pathJoin(scratch_dir, std.fmt.allocPrint(gpa, "udf-{s}", .{name}) catch @panic("oom"));
    e.args = args;
    e.args_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, args) catch @panic("oom");
    e.urls = urls;
    e.options = .{ .owner = e };
}

fn fmtUrl(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(gpa, fmt, args) catch @panic("oom");
}

pub fn main() !void {
    t0_ns = std.time.nanoTimestamp();
    self_pid = W.GetCurrentProcessId();
    const argv = try std.process.argsAlloc(gpa);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--scratch") and i + 1 < argv.len) {
            scratch_dir = argv[i + 1];
            i += 1;
        }
    }
    if (scratch_dir.len == 0 or !std.fs.path.isAbsolute(scratch_dir)) {
        std.debug.print("usage: s5proto --scratch <absolute dir>\n", .{});
        std.process.exit(2);
    }
    std.fs.makeDirAbsolute(scratch_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    log_file = try std.fs.createFileAbsolute(pathJoin(scratch_dir, "s5.log"), .{});
    hold_flag_path = pathJoin(scratch_dir, "hold.flag");
    hold_done_path = pathJoin(scratch_dir, "hold.done");
    logf("s5proto pid={d} scratch={s}", .{ self_pid, scratch_dir });

    // Foreground sampler runs before any window exists.
    const sampler = try std.Thread.spawn(.{}, samplerMain, .{});

    var wsa: ws.WSADATA = undefined;
    if (ws.WSAStartup(0x0202, &wsa) != 0) return error.WSAStartup;

    var rnd: [12]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    proxy_secret = try std.fmt.allocPrint(gpa, "{x}", .{&rnd});
    const cred = try std.fmt.allocPrint(gpa, "wmux:{s}", .{proxy_secret});
    const b64 = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(cred.len));
    _ = std.base64.standard.Encoder.encode(b64, cred);
    srv_httpE.auth = try std.fmt.allocPrint(gpa, "Basic {s}", .{b64});
    const inline_b64 = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize("wmux:inline-secret".len));
    _ = std.base64.standard.Encoder.encode(inline_b64, "wmux:inline-secret");
    srv_httpG.auth = try std.fmt.allocPrint(gpa, "Basic {s}", .{inline_b64});
    srv_httpE2.auth = srv_httpE.auth;

    // Environments (records first: servers reference their owners).
    envs = env_store[0..9];
    const A = &env_store[0];
    const B = &env_store[1];
    const C = &env_store[2];
    const D = &env_store[3];
    const E = &env_store[4];
    const E2 = &env_store[5];
    const G = &env_store[6];
    const H = &env_store[7];
    const F = &env_store[8];
    srv_socksA.owner = A;
    srv_socksB.owner = B;
    srv_socksD.owner = D;
    srv_httpE.owner = E;
    srv_httpE2.owner = E2;
    srv_httpG.owner = G;
    srv_socksH.owner = H;

    // The first GetExtendedTcpTable call in a process is slow; warm it up.
    const warm = tcpOwner4(0, 0, 0, 0);
    logf("warm-up GetExtendedTcpTable: {d} us ({d} rows)", .{ warm.us, warm.rows });
    const warm2 = tcpOwner4(0, 0, 0, 0);
    logf("second GetExtendedTcpTable: {d} us ({d} rows)", .{ warm2.us, warm2.rows });

    // A port with no listener yet: env H's broker starts late on it.
    const late_port: u16 = blk: {
        var tmp: Server = .{ .name = "reserve", .kind = .socks5 };
        const s = ws.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        var sa: ws.sockaddr.in = .{ .port = 0, .addr = loopback4_be };
        _ = ws.bind(s, @ptrCast(&sa), @sizeOf(ws.sockaddr.in));
        var len: i32 = @sizeOf(ws.sockaddr.in);
        _ = ws.getsockname(s, @ptrCast(&sa), &len);
        _ = ws.closesocket(s);
        tmp.port = std.mem.bigToNative(u16, sa.port);
        break :blk tmp.port;
    };

    try startServer(&srv_origin4, 0);
    if (startServer(&srv_origin6, srv_origin4.port)) |_| {
        have_ipv6 = true;
    } else |err| logf("origin6 unavailable: {s}", .{@errorName(err)});
    try startServer(&srv_socksA, 0);
    try startServer(&srv_socksB, 0);
    try startServer(&srv_socksD, 0);
    try startServer(&srv_socksOpen, 0);
    try startServer(&srv_httpE, 0);
    try startServer(&srv_httpG, 0);
    try startServer(&srv_httpE2, 0);
    const T = srv_origin4.port;

    const a_urls_all = [_][]const u8{
        fmtUrl("http://127.0.0.1:{d}/A-ipv4", .{T}),
        fmtUrl("http://localhost:{d}/A-localhost", .{T}),
        fmtUrl("http://tenant.localhost:{d}/A-sublocalhost", .{T}),
        fmtUrl("http://[::1]:{d}/A-ipv6", .{T}),
    };
    const a_urls = try gpa.dupe([]const u8, if (have_ipv6) a_urls_all[0..] else a_urls_all[0..3]);
    const b_urls = try gpa.dupe([]const u8, &.{ fmtUrl("http://127.0.0.1:{d}/B-ipv4", .{T}), fmtUrl("http://localhost:{d}/B-localhost", .{T}) });
    const c_urls = try gpa.dupe([]const u8, &.{fmtUrl("http://127.0.0.1:{d}/C-intruder", .{T})});
    const d_urls = try gpa.dupe([]const u8, &.{ fmtUrl("http://127.0.0.1:{d}/D-ipv4", .{T}), fmtUrl("http://localhost:{d}/D-localhost", .{T}) });
    const e_urls = try gpa.dupe([]const u8, &.{ fmtUrl("http://127.0.0.1:{d}/E-first", .{T}), fmtUrl("http://127.0.0.1:{d}/E-second", .{T}), fmtUrl("http://localhost:{d}/E-localhost", .{T}) });
    const e2_urls = try gpa.dupe([]const u8, &.{ fmtUrl("http://127.0.0.1:{d}/E2-first", .{T}), fmtUrl("http://127.0.0.1:{d}/E2-second", .{T}) });
    const g_urls = try gpa.dupe([]const u8, &.{fmtUrl("http://127.0.0.1:{d}/G-inline", .{T})});
    const h_urls = try gpa.dupe([]const u8, &.{ fmtUrl("http://127.0.0.1:{d}/H-broker-down", .{T}), fmtUrl("http://127.0.0.1:{d}/H-broker-up", .{T}) });

    const bypass = "--proxy-bypass-list=<-loopback>";
    initEnv(A, "A", fmtUrl("--proxy-server=socks5://127.0.0.1:{d} {s}", .{ srv_socksA.port, bypass }), a_urls);
    initEnv(B, "B", fmtUrl("--proxy-server=socks5://127.0.0.1:{d} {s}", .{ srv_socksB.port, bypass }), b_urls);
    initEnv(C, "C", fmtUrl("--proxy-server=socks5://127.0.0.1:{d} {s}", .{ srv_socksA.port, bypass }), c_urls);
    initEnv(D, "D", fmtUrl("--proxy-server=socks5://127.0.0.1:{d}", .{srv_socksD.port}), d_urls);
    initEnv(E, "E", fmtUrl("--proxy-server=http://127.0.0.1:{d} {s}", .{ srv_httpE.port, bypass }), e_urls);
    E.auth = .provide;
    initEnv(E2, "E2", fmtUrl("--proxy-server=http://127.0.0.1:{d} {s}", .{ srv_httpE2.port, bypass }), e2_urls);
    E2.auth = .provide;
    E2.defer_auth = true;
    initEnv(G, "G", fmtUrl("--proxy-server=http://wmux:inline-secret@127.0.0.1:{d} {s}", .{ srv_httpG.port, bypass }), g_urls);
    G.auth = .cancel;
    initEnv(H, "H", fmtUrl("--proxy-server=socks5://127.0.0.1:{d} {s}", .{ late_port, bypass }), h_urls);
    H.late_broker = &srv_socksH;
    H.late_broker_port = late_port;
    initEnv(F, "F", fmtUrl("--proxy-server=socks5://127.0.0.1:{d} {s}", .{ srv_socksB.port, bypass }), &.{});
    F.udf = A.udf;
    F.probe_only = true;
    // Teardown recipe under test: keep every environment until its
    // BrowserProcessExited; after a 60 s grace period terminate the
    // remaining browser process trees (the folders are deleted anyway).
    F.release_env_early = true;
    for (envs) |*e| {
        if (e.probe_only) continue;
        std.fs.makeDirAbsolute(e.udf) catch {};
        e.udf_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, e.udf);
    }
    F.udf_w = A.udf_w;

    // COM, loader, hidden windows.
    _ = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    loader = try wv2.loadLoader();
    var ver: ?W.LPWSTR = null;
    if (loader.GetAvailableCoreWebView2BrowserVersionString(null, &ver) == 0) {
        logf("WebView2 runtime: {s}", .{w2u(ver)});
        if (ver) |v| wv2.CoTaskMemFree(v);
    }
    hinst = @ptrCast(W.kernel32.GetModuleHandleW(null));
    const wc: WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .hInstance = hinst, .lpszClassName = class_name };
    if (RegisterClassExW(&wc) == 0) return error.RegisterClass;
    const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
    msg_hwnd = CreateWindowExW(0, class_name, L("s5-timers"), 0, 0, 0, 0, 0, HWND_MESSAGE, null, hinst, null);
    for (envs) |*e| {
        e.hwnd = createHiddenWindow(L("wmux S5 probe"));
        if (e.hwnd == null) return error.CreateWindow;
    }
    global_deadline = nowMs() + 150_000;
    for (envs) |*e| if (!e.probe_only) startEnv(e);
    _ = SetTimer(msg_hwnd, 1, 100, null);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }

    stopping.store(true, .release);
    for ([_]*Server{ &srv_origin4, &srv_origin6, &srv_socksA, &srv_socksB, &srv_socksD, &srv_socksOpen, &srv_httpE, &srv_httpG, &srv_httpE2, &srv_socksH }) |s| {
        if (s.sock != ws.INVALID_SOCKET) _ = ws.closesocket(s.sock);
    }
    sampler.join();
    sum_file = std.fs.createFileAbsolute(pathJoin(scratch_dir, "summary.txt"), .{}) catch null;
    const failures = summarize();
    CoUninitialize();
    std.process.exit(if (failures == 0) 0 else 1);
}

// ─── summary and assertions ─────────────────────────────────────────────

var failures_total: u32 = 0;
fn check(name: []const u8, ok: bool, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, fmt, args) catch "";
    sumf("CHECK {s} {s}: {s}", .{ if (ok) "PASS" else "FAIL", name, detail });
    if (!ok) failures_total += 1;
}

fn originVia(path: []const u8) ?[]const u8 {
    for (origin_recs[0..n_origin_recs]) |*r| if (std.mem.eql(u8, r.path[0..r.path_len], path)) return r.via;
    return null;
}

fn proxySaw(proxy: []const u8, needle: []const u8) bool {
    for (proxy_recs[0..n_proxy_recs]) |*r| {
        if (!std.mem.eql(u8, r.proxy, proxy)) continue;
        if (std.mem.indexOf(u8, r.reqline[0..r.reqline_len], needle) != null) return true;
    }
    return false;
}

fn pathOf(u: []const u8) []const u8 {
    return u[std.mem.indexOfScalarPos(u8, u, 8, '/') orelse u.len ..];
}

fn summarize() u32 {
    recs_mutex.lock();
    defer recs_mutex.unlock();
    sumf("==== S5 summary (pid {d}) ====", .{self_pid});
    for (envs) |*e| {
        sumf("ENV {s} args=\"{s}\" env_hr=0x{x:0>8} env_ms={d} ctrl_hr=0x{x:0>8} ctrl_ms={d} browser_pid={d} armed_by={s} webview.BrowserProcessId={d} infos_at_create=[{s}] auth_events={d} other_completions={d}", .{
            e.name,                                                      e.args,                       hx(e.env_hr), e.t_env_done - e.t_env_start, hx(e.ctrl_hr),
            if (e.t_ctrl_done > 0) e.t_ctrl_done - e.t_env_done else -1, e.browser_pid.load(.acquire), e.armed_by,   e.webview_bpid,               e.infos_at_create,
            e.auth_events,                                               e.other_completions,
        });
        sumf("  SHUTDOWN close_hr=0x{x:0>8} env_released_early={} browser_exit_ms={d} BrowserProcessExited={} (kind {d}) at_ms={d} tree_empty_ms={d} killed={d} procs at_ms={d} udf_deleted={} at_ms={d} delete_err={s} last_alive=[{s}]", .{
            hx(e.close_hr),
            e.release_env_early,
            if (e.t_browser_exit > 0) e.t_browser_exit - close_start else -1,
            e.exited,
            e.exit_kind,
            if (e.t_exit > 0) e.t_exit - close_start else -1,
            if (e.t_tree_empty > 0) e.t_tree_empty - close_start else -1,
            e.killed_n,
            if (e.t_killed > 0) e.t_killed - close_start else -1,
            e.udf_deleted,
            if (e.t_deleted > 0) e.t_deleted - close_start else -1,
            e.delete_err,
            e.last_alive,
        });
        for (e.results[0..e.urls.len]) |*r| {
            sumf("  URL {s} nav_ok={} web_error={d} nav_ms={d} title=\"{s}\" err=\"{s}\" note={s}", .{ r.url, r.nav_ok, r.web_error, r.nav_ms, r.title[0..r.title_len], r.err[0..r.err_len], r.note });
        }
    }
    var lk: [256]u64 = undefined;
    var fk: [256]u64 = undefined;
    var tk: [256]u64 = undefined;
    var nk: usize = 0;
    var fast_agrees: usize = 0;
    var infos_agrees: usize = 0;
    var judged: usize = 0;
    for (proxy_recs[0..n_proxy_recs]) |*r| {
        sumf("PROXY {s} conn={d} t={d} owner={d}({s}) env={s} kind={s} in_tree={} in_infos={} fast={} admitted={} waited={d}ms lookup={d}us fast={d}us tree={d}us target={s} socks_methods={s} req=\"{s}\" 407s={d} first_had_auth={} note={s}", .{
            r.proxy,    r.conn,      r.t_ms,      r.owner_pid, r.owner_name[0..r.owner_name_len], r.owner_env,               kindName(r.owner_kind),      r.in_tree,                   r.in_infos, r.fast_ok,
            r.admitted, r.waited_ms, r.lookup_us, r.fast_us,   r.tree_us,                         r.target[0..r.target_len], r.methods[0..r.methods_len], r.reqline[0..r.reqline_len], r.auth_407, r.first_had_auth,
            r.note,
        });
        if (nk < lk.len) {
            lk[nk] = r.lookup_us;
            fk[nk] = r.fast_us;
            tk[nk] = r.tree_us;
            nk += 1;
        }
        if (std.mem.startsWith(u8, r.proxy, "socks") and !std.mem.eql(u8, r.proxy, "socksOpen")) {
            judged += 1;
            if (r.fast_ok == r.in_tree) fast_agrees += 1;
            if (r.in_infos == r.in_tree) infos_agrees += 1;
        }
    }
    if (nk > 0) {
        std.mem.sort(u64, lk[0..nk], {}, std.sort.asc(u64));
        std.mem.sort(u64, fk[0..nk], {}, std.sort.asc(u64));
        std.mem.sort(u64, tk[0..nk], {}, std.sort.asc(u64));
        sumf("ADMISSION-COST over {d} accepted connections: GetExtendedTcpTable p50 {d} us max {d} us; fast parent check p50 {d} us max {d} us; Toolhelp tree walk p50 {d} us max {d} us", .{
            nk, lk[nk / 2], lk[nk - 1], fk[nk / 2], fk[nk - 1], tk[nk / 2], tk[nk - 1],
        });
    }
    sumf("ADMISSION-AGREEMENT on {d} admission-enforcing connections: fast parent check agrees with tree walk {d}x, GetProcessInfos membership agrees {d}x", .{ judged, fast_agrees, infos_agrees });
    for (origin_recs[0..n_origin_recs]) |*r| {
        sumf("ORIGIN{s} conn={d} t={d} path={s} host={s} absolute_form={} via={s} owner={d} ws_echo={s}", .{
            if (r.family == AF_INET) "4" else "6", r.conn, r.t_ms, r.path[0..r.path_len], r.host[0..r.host_len], r.absolute_form, r.via, r.owner_pid, r.ws_echo[0..r.ws_len],
        });
    }
    sumf("SELF-INTRUDER {s}", .{self_intruder});
    sumf("BENCH {s}", .{bench_text});
    sumf("FOREGROUND samples={d} changes={d} violations=0", .{ fg_samples, fg_changes });
    sumf("HTTPPROXY httpE 407s={d} authorized={d}; httpE2 407s={d} authorized={d}; httpG 407s={d} authorized={d}", .{
        srv_httpE.n407.load(.monotonic), srv_httpE.nauth.load(.monotonic), srv_httpE2.n407.load(.monotonic), srv_httpE2.nauth.load(.monotonic),
        srv_httpG.n407.load(.monotonic), srv_httpG.nauth.load(.monotonic),
    });

    const A = &env_store[0];
    const B = &env_store[1];
    const C = &env_store[2];
    const D = &env_store[3];
    const E = &env_store[4];
    const E2 = &env_store[5];
    const G = &env_store[6];
    const H = &env_store[7];
    const F = &env_store[8];
    const pa = A.browser_pid.load(.acquire);
    const pb = B.browser_pid.load(.acquire);
    check("two-environments-one-process", A.env_hr == 0 and B.env_hr == 0 and pa != 0 and pb != 0 and pa != pb, "A browser {d}, B browser {d}", .{ pa, pb });
    for ([_]*Env{ A, B }) |e| {
        const px: []const u8 = if (e == A) "socksA" else "socksB";
        const other: []const u8 = if (e == A) "socksB" else "socksA";
        for (e.results[0..e.urls.len]) |*r| {
            const path = pathOf(r.url);
            var ws_path_buf: [128]u8 = undefined;
            const ws_path = std.fmt.bufPrint(&ws_path_buf, "/ws{s}", .{path}) catch "";
            const via = originVia(path) orelse "absent";
            const ws_via = originVia(ws_path) orelse "absent";
            var needle_buf: [128]u8 = undefined;
            const needle = std.fmt.bufPrint(&needle_buf, "{s} ", .{path}) catch "";
            check("loopback-through-own-proxy", r.nav_ok and r.wsOk() and std.mem.eql(u8, via, "proxy-relay") and std.mem.eql(u8, ws_via, "proxy-relay") and proxySaw(px, needle) and !proxySaw(other, needle), "env {s} {s}: nav_ok={} title={s} origin via={s} ws via={s} seen on {s}={} seen on {s}={}", .{
                e.name, r.url, r.nav_ok, r.title[0..r.title_len], via, ws_via, px, proxySaw(px, needle), other, proxySaw(other, needle),
            });
        }
    }
    var admitted_ok = true;
    var c_rejected: u32 = 0;
    var admitted_n: u32 = 0;
    for (proxy_recs[0..n_proxy_recs]) |*r| {
        const owner_name: []const u8 = if (std.mem.eql(u8, r.proxy, "socksA")) "A" else if (std.mem.eql(u8, r.proxy, "socksB")) "B" else if (std.mem.eql(u8, r.proxy, "socksD")) "D" else if (std.mem.eql(u8, r.proxy, "socksH")) "H" else continue;
        if (r.admitted) {
            admitted_n += 1;
            if (!std.mem.eql(u8, r.owner_env, owner_name)) admitted_ok = false;
        }
        if (std.mem.eql(u8, r.owner_env, "C") and !r.admitted) c_rejected += 1;
        if (std.mem.eql(u8, r.owner_env, "C") and r.admitted) admitted_ok = false;
    }
    check("pid-admission-only-own-tree", admitted_ok and admitted_n > 0, "{d} admitted connections, all owned by the proxy's environment tree: {}", .{ admitted_n, admitted_ok });
    check("intruder-environment-rejected", c_rejected > 0 and !C.results[0].nav_ok and originVia("/C-intruder") == null, "C connections rejected by socksA: {d}; C nav_ok={} web_error={d} err={s}; origin saw /C-intruder: {}", .{
        c_rejected, C.results[0].nav_ok, C.results[0].web_error, C.results[0].err[0..C.results[0].err_len], originVia("/C-intruder") != null,
    });
    check("non-browser-process-rejected", std.mem.eql(u8, self_intruder, "rejected (05 FF)"), "this process -> socksA: {s}", .{self_intruder});
    var d_ok = true;
    for (D.results[0..D.urls.len]) |*r| {
        const via = originVia(pathOf(r.url)) orelse "absent";
        if (!r.nav_ok or !std.mem.eql(u8, via, "direct:D")) d_ok = false;
    }
    var d_proxied: u32 = 0;
    for (proxy_recs[0..n_proxy_recs]) |*r| {
        if (!std.mem.eql(u8, r.proxy, "socksD")) continue;
        const t = r.target[0..r.target_len];
        if (std.mem.indexOf(u8, t, ":127.0.0.1:") != null or std.mem.indexOf(u8, t, "localhost") != null) d_proxied += 1;
    }
    check("default-bypass-keeps-loopback-direct", d_ok and d_proxied == 0, "env D (no <-loopback>): loopback reached the origin directly: {}; loopback CONNECTs on socksD: {d}", .{ d_ok, d_proxied });
    // Fallback: at least one navigation of E must have gone through the
    // authenticated HTTP proxy, with the WebSocket tunnelled by CONNECT.
    var e_any = false;
    for (E.results[0..E.urls.len]) |*r| {
        const via = originVia(pathOf(r.url)) orelse "absent";
        if (r.nav_ok and r.wsOk() and std.mem.eql(u8, via, "proxy-relay")) e_any = true;
    }
    check("fallback-http-proxy-basic-auth", E.auth_events > 0 and e_any and srv_httpE.n407.load(.monotonic) > 0, "BasicAuthenticationRequested events={d} Uri=\"{s}\" Challenge=\"{s}\"; httpE 407s={d} authorized={d}; an authenticated navigation + WebSocket succeeded: {}", .{
        E.auth_events, E.auth_uri, E.auth_challenge, srv_httpE.n407.load(.monotonic), srv_httpE.nauth.load(.monotonic), e_any,
    });
    for ([_]*Env{ E, E2 }) |e| {
        const r0 = &e.results[0];
        sumf("INFO first-navigation-under-proxy-auth env {s} ({s}): nav_ok={} web_error={d} err=\"{s}\" origin via={s}; second nav_ok={} via={s}; auth_events={d}; ignored completions={d}", .{
            e.name,              if (e.defer_auth) "deferral" else "synchronous",     r0.nav_ok,     r0.web_error,        r0.err[0..r0.err_len], originVia(pathOf(r0.url)) orelse "absent",
            e.results[1].nav_ok, originVia(pathOf(e.results[1].url)) orelse "absent", e.auth_events, e.other_completions,
        });
    }
    sumf("INFO inline-credentials (env G): auth_events={d} httpG 407s={d} authorized={d} nav_ok={} web_error={d} err={s} origin via={s}", .{
        G.auth_events, srv_httpG.n407.load(.monotonic), srv_httpG.nauth.load(.monotonic), G.results[0].nav_ok, G.results[0].web_error, G.results[0].err[0..G.results[0].err_len], originVia("/G-inline") orelse "absent",
    });
    check("broker-may-start-after-environment", !H.results[0].nav_ok and H.results[1].nav_ok and std.mem.eql(u8, originVia("/H-broker-up") orelse "", "proxy-relay"), "no listener: nav_ok={} err={s}; listener started on the same port: nav_ok={} via={s}", .{
        H.results[0].nav_ok, H.results[0].err[0..H.results[0].err_len], H.results[1].nav_ok, originVia("/H-broker-up") orelse "absent",
    });
    check("same-udf-different-args-fails", F.env_hr != 0 or F.ctrl_hr != 0, "second environment on udf-A with another --proxy-server: env hr=0x{x:0>8}, controller hr=0x{x:0>8}", .{ hx(F.env_hr), hx(F.ctrl_hr) });
    var del_ok = true;
    for (envs) |*e| {
        if (!e.probe_only and !e.udf_deleted) del_ok = false;
    }
    check("user-data-folders-deleted", del_ok, "all user-data folders removed after the browser process trees exited", .{});
    sumf("RESULT failures={d}", .{failures_total});
    return failures_total;
}
