//! S5 spike, teardown probe: how long does a WebView2 browser process (and
//! the lock on its user-data folder) outlive ICoreWebView2Controller::Close(),
//! and which teardown recipe is deterministic?
//!
//! Variants (each its own environment, user-data folder and hidden off-screen
//! window; pick with --only a,b,c; default: all, concurrently):
//!   plain          navigate about:blank, Close, release controller/webview/env
//!   keepenv        like plain, keep the environment until BrowserProcessExited
//!   nohandler      like plain, no BrowserProcessExited handler at all
//!   removehandler  like plain, remove_BrowserProcessExited before release
//!   destroywnd     like plain plus DestroyWindow(parent) right after Close
//!   proxy          like plain with --proxy-server=socks5://127.0.0.1:9 <-loopback>
//!   noclose        release everything WITHOUT calling Close
//!   kill           like keepenv, then TerminateProcess on the browser process
//!                  tree 3 s after Close (env kept to observe the event)
//!   reattach       2 s after plain's Close, create a new environment on
//!                  plain's user-data folder with the same arguments
//! After the waiting phase (--wait seconds, default 60) every user-data folder
//! is deleted with retries (60 s cap). Standalone; build like s5proto.zig.
const std = @import("std");
const wv2 = @import("wv2");
const W = std.os.windows;
const HWND = W.HWND;
const HRESULT = W.HRESULT;
const GUID = W.GUID;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const gpa = std.heap.page_allocator;

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, W.WPARAM, W.LPARAM) callconv(.winapi) W.LRESULT,
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
const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: W.WPARAM, lParam: W.LPARAM, time: u32, pt: W.POINT };
const PROCESSENTRY32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    szExeFile: [260]u16,
};
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, W.WPARAM, W.LPARAM) callconv(.winapi) W.LRESULT;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) W.BOOL;
extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) W.BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) W.LRESULT;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) W.BOOL;
extern "user32" fn SetTimer(?HWND, usize, u32, ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowThreadProcessId(HWND, ?*u32) callconv(.winapi) u32;
extern "kernel32" fn OpenProcess(u32, W.BOOL, u32) callconv(.winapi) ?W.HANDLE;
extern "kernel32" fn TerminateProcess(W.HANDLE, u32) callconv(.winapi) W.BOOL;
extern "kernel32" fn Process32FirstW(W.HANDLE, *PROCESSENTRY32W) callconv(.winapi) W.BOOL;
extern "kernel32" fn Process32NextW(W.HANDLE, *PROCESSENTRY32W) callconv(.winapi) W.BOOL;
extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemAlloc(usize) callconv(.winapi) ?*anyopaque;
const SYNCHRONIZE: u32 = 0x0010_0000;
const PROCESS_TERMINATE: u32 = 0x0001;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

const IID_EnvOptions = GUID.parse("{2fde08a8-1e9a-4766-8c05-95a9ceb9d1c5}");
const IID_Env5 = GUID.parse("{319e423d-e0d7-4b8d-9254-ae9475de9b17}");
const IID_BrowserProcessExitedHandler = GUID.parse("{fa504257-a216-4911-a860-fe8825712861}");

const RawCom = extern struct {
    vtable: [*]const *const anyopaque,
    fn fnAt(self: *RawCom, comptime idx: usize, comptime Fn: type) Fn {
        return @ptrCast(@alignCast(self.vtable[idx]));
    }
    fn release(self: *RawCom) void {
        _ = self.fnAt(2, *const fn (*RawCom) callconv(.winapi) u32)(self);
    }
};
fn raw(p: anytype) *RawCom {
    return @ptrCast(@alignCast(p));
}

/// Minimal host-implemented ICoreWebView2EnvironmentOptions (static storage).
const Options = extern struct {
    vtable: *const [11]*const anyopaque = &vt,
    args: [*:0]const u16,
    const vt = [11]*const anyopaque{ &qi, &ref, &ref, &getArgs, &putStr, &getEmpty, &putStr, &getTarget, &putStr, &getBool, &putBool };
    fn qi(self: *Options, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (wv2.guidEql(riid, &IID_EnvOptions) or wv2.guidEql(riid, &wv2.IID_IUnknown)) {
            out.* = self;
            return 0;
        }
        out.* = null;
        return wv2.E_NOINTERFACE;
    }
    fn ref(_: *Options) callconv(.winapi) u32 {
        return 1;
    }
    fn dup(s: []const u16, out: *?[*:0]u16) HRESULT {
        const p: [*]u16 = @ptrCast(@alignCast(CoTaskMemAlloc((s.len + 1) * 2) orelse return @bitCast(@as(u32, 0x8007000E))));
        @memcpy(p[0..s.len], s);
        p[s.len] = 0;
        out.* = @ptrCast(p);
        return 0;
    }
    fn getArgs(self: *Options, out: *?[*:0]u16) callconv(.winapi) HRESULT {
        return dup(std.mem.span(self.args), out);
    }
    fn getEmpty(_: *Options, out: *?[*:0]u16) callconv(.winapi) HRESULT {
        return dup(L(""), out);
    }
    fn getTarget(_: *Options, out: *?[*:0]u16) callconv(.winapi) HRESULT {
        return dup(L("86.0.616.0"), out);
    }
    fn putStr(_: *Options, _: ?[*:0]const u16) callconv(.winapi) HRESULT {
        return 0;
    }
    fn getBool(_: *Options, out: *W.BOOL) callconv(.winapi) HRESULT {
        out.* = 0;
        return 0;
    }
    fn putBool(_: *Options, _: W.BOOL) callconv(.winapi) HRESULT {
        return 0;
    }
};

const Variant = struct {
    name: []const u8,
    args: [:0]const u16 = L(""),
    keep_env: bool = false,
    destroy_window: bool = false,
    call_close: bool = true,
    exit_handler: bool = true,
    remove_handler: bool = false,
    kill_after_ms: i64 = 0,
    follow: ?[]const u8 = null,
    // runtime
    udf: []const u8 = "",
    udf_w: [:0]u16 = undefined,
    hwnd: ?HWND = null,
    options: Options = undefined,
    started: bool = false,
    env: ?*wv2.ICoreWebView2Environment = null,
    controller: ?*wv2.ICoreWebView2Controller = null,
    webview: ?*wv2.ICoreWebView2 = null,
    exit_token: wv2.EventRegistrationToken = .{},
    browser_pid: u32 = 0,
    browser: ?W.HANDLE = null,
    ctrl_hr: HRESULT = 0,
    navigated: bool = false,
    closed: bool = false,
    killed: bool = false,
    t_close: i64 = 0,
    t_browser_exit: i64 = 0,
    t_exited_event: i64 = 0,
    exit_kind: i32 = -1,
    deleted: bool = false,
    t_deleted: i64 = 0,
};

var variants = [_]Variant{
    .{ .name = "plain" },
    .{ .name = "keepenv", .keep_env = true },
    .{ .name = "nohandler", .exit_handler = false },
    .{ .name = "removehandler", .remove_handler = true },
    .{ .name = "destroywnd", .destroy_window = true },
    .{ .name = "proxy", .args = L("--proxy-server=socks5://127.0.0.1:9 --proxy-bypass-list=<-loopback>") },
    .{ .name = "noclose", .call_close = false },
    .{ .name = "kill", .keep_env = true, .kill_after_ms = 3000 },
    .{ .name = "reattach", .follow = "plain" },
};
var vlist: []Variant = &variants;
var wait_ms: i64 = 60_000;
var t0: i128 = 0;
var log_file: ?std.fs.File = null;
var phase: enum { running, deleting } = .running;
var phase_start: i64 = 0;
var msg_hwnd: ?HWND = null;
var self_pid: u32 = 0;
var last_report: i64 = 0;
var scratch: []const u8 = "";
var loader: *wv2.Loader = undefined;
var hinst: ?*anyopaque = null;
const cls = L("WmuxS5CloseProbe");

fn nowMs() i64 {
    return @intCast(@divTrunc(std.time.nanoTimestamp() - t0, std.time.ns_per_ms));
}
fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d:>7}ms] " ++ fmt ++ "\n", .{nowMs()} ++ args) catch return;
    if (log_file) |f| f.writeAll(line) catch {};
    std.fs.File.stdout().writeAll(line) catch {};
}
fn hx(hr: HRESULT) u32 {
    return @bitCast(hr);
}
fn find(name: []const u8) ?*Variant {
    for (vlist) |*v| if (std.mem.eql(u8, v.name, name)) return v;
    return null;
}

const EnvDone = wv2.EnvironmentCompletedHandler(Variant);
const CtrlDone = wv2.ControllerCompletedHandler(Variant);
const NavDone = wv2.NavigationCompletedEventHandler(Variant);
const Exited = wv2.Handler(IID_BrowserProcessExitedHandler, Variant, ?*wv2.ICoreWebView2Environment, ?*RawCom);

fn start(v: *Variant) void {
    v.started = true;
    v.options = .{ .args = v.args.ptr };
    v.hwnd = CreateWindowExW(0x0800_0080, cls, L("s5close"), 0x8000_0000, -32000, -32000, 320, 240, null, null, hinst, null);
    _ = ShowWindow(v.hwnd.?, 4); // SW_SHOWNOACTIVATE
    const h = EnvDone.create(gpa, v, onEnv) catch return;
    defer h.unref();
    const hr = loader.CreateCoreWebView2EnvironmentWithOptions(null, v.udf_w.ptr, @ptrCast(&v.options), @ptrCast(h));
    if (hr != 0) logf("{s}: CreateCoreWebView2EnvironmentWithOptions 0x{x:0>8}", .{ v.name, hx(hr) });
}

fn onEnv(v: *Variant, hr: HRESULT, env: ?*wv2.ICoreWebView2Environment) void {
    if (hr != 0 or env == null) return logf("{s}: env failed 0x{x:0>8}", .{ v.name, hx(hr) });
    env.?.addRef();
    v.env = env;
    var e5: ?*anyopaque = null;
    if (v.exit_handler and env.?.vtable.QueryInterface(env.?, &IID_Env5, &e5) == 0) {
        const r: *RawCom = @ptrCast(@alignCast(e5.?));
        if (Exited.create(gpa, v, onExited)) |h| {
            _ = r.fnAt(12, *const fn (*RawCom, *anyopaque, *wv2.EventRegistrationToken) callconv(.winapi) HRESULT)(r, @ptrCast(h), &v.exit_token);
            h.unref();
        } else |_| {}
        r.release();
    }
    const h = CtrlDone.create(gpa, v, onCtrl) catch return;
    defer h.unref();
    env.?.createController(v.hwnd.?, h) catch {};
}

fn onCtrl(v: *Variant, hr: HRESULT, c: ?*wv2.ICoreWebView2Controller) void {
    v.ctrl_hr = hr;
    if (hr != 0 or c == null) return logf("{s}: controller failed 0x{x:0>8}", .{ v.name, hx(hr) });
    c.?.addRef();
    v.controller = c;
    const wv = c.?.getCoreWebView2() catch return;
    v.webview = wv;
    _ = raw(wv).fnAt(37, *const fn (*RawCom, *u32) callconv(.winapi) HRESULT)(raw(wv), &v.browser_pid);
    v.browser = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE, 0, v.browser_pid);
    if (v.follow) |f| {
        const leader = find(f).?;
        logf("{s}: controller ready on {s}'s folder {d} ms after its Close; browser pid {d} ({s}'s was {d}: {s})", .{
            v.name, f, nowMs() - leader.t_close, v.browser_pid, f, leader.browser_pid, if (v.browser_pid == leader.browser_pid) "REATTACHED to the lingering browser" else "new browser process",
        });
    } else logf("{s}: controller ready, browser pid {d}", .{ v.name, v.browser_pid });
    if (NavDone.create(gpa, v, onNav)) |nh| {
        _ = wv.addNavigationCompleted(nh) catch {};
        nh.unref();
    } else |_| {}
    wv.navigate(L("about:blank")) catch {};
}

fn onNav(v: *Variant, _: ?*wv2.ICoreWebView2, _: ?*wv2.ICoreWebView2NavigationCompletedEventArgs) void {
    v.navigated = true;
}

fn onExited(v: *Variant, _: ?*wv2.ICoreWebView2Environment, args: ?*RawCom) void {
    if (args) |a| _ = a.fnAt(3, *const fn (*RawCom, *i32) callconv(.winapi) HRESULT)(a, &v.exit_kind);
    v.t_exited_event = nowMs();
    logf("{s}: BrowserProcessExited kind={d} ({s}) {d} ms after Close", .{ v.name, v.exit_kind, if (v.exit_kind == 0) "normal" else "failed", v.t_exited_event - v.t_close });
}

fn closeOne(v: *Variant) void {
    v.closed = true;
    v.t_close = nowMs();
    if (v.controller) |c| {
        if (v.call_close) logf("{s}: Close hr=0x{x:0>8}", .{ v.name, hx(c.vtable.Close(c)) });
        c.release();
    }
    if (v.webview) |w| w.release();
    v.controller = null;
    v.webview = null;
    if (v.destroy_window) {
        _ = DestroyWindow(v.hwnd.?);
        v.hwnd = null;
    }
    if (v.remove_handler) {
        if (v.env) |e| {
            var e5: ?*anyopaque = null;
            if (e.vtable.QueryInterface(e, &IID_Env5, &e5) == 0) {
                const r: *RawCom = @ptrCast(@alignCast(e5.?));
                const rhr = r.fnAt(13, *const fn (*RawCom, wv2.EventRegistrationToken) callconv(.winapi) HRESULT)(r, v.exit_token);
                logf("{s}: remove_BrowserProcessExited hr=0x{x:0>8}", .{ v.name, hx(rhr) });
                r.release();
            }
        }
    }
    if (!v.keep_env) {
        if (v.env) |e| e.release();
        v.env = null;
    }
}

/// Terminates the browser process and every descendant (Toolhelp snapshot
/// taken before the browser dies, so parent links are still meaningful).
fn killTree(v: *Variant) void {
    v.killed = true;
    var pids: [64]u32 = undefined;
    var n: usize = 0;
    pids[0] = v.browser_pid;
    n = 1;
    const h = W.kernel32.CreateToolhelp32Snapshot(0x2, 0);
    if (h != W.INVALID_HANDLE_VALUE) {
        defer W.CloseHandle(h);
        var grew = true;
        while (grew) {
            grew = false;
            var e = std.mem.zeroes(PROCESSENTRY32W);
            e.dwSize = @sizeOf(PROCESSENTRY32W);
            var ok = Process32FirstW(h, &e);
            while (ok != 0) : (ok = Process32NextW(h, &e)) {
                const known = std.mem.indexOfScalar(u32, pids[0..n], e.th32ProcessID) != null;
                const parent_known = std.mem.indexOfScalar(u32, pids[0..n], e.th32ParentProcessID) != null;
                if (!known and parent_known and n < pids.len) {
                    pids[n] = e.th32ProcessID;
                    n += 1;
                    grew = true;
                }
            }
        }
    }
    for (pids[0..n]) |pid| {
        if (OpenProcess(PROCESS_TERMINATE, 0, pid)) |ph| {
            _ = TerminateProcess(ph, 1);
            W.CloseHandle(ph);
        }
    }
    logf("{s}: TerminateProcess on {d} processes of browser {d}, {d} ms after Close", .{ v.name, n, v.browser_pid, nowMs() - v.t_close });
}

fn tick() void {
    const now = nowMs();
    if (GetForegroundWindow()) |h| {
        var pid: u32 = 0;
        _ = GetWindowThreadProcessId(h, &pid);
        if (pid == self_pid) {
            logf("FOREGROUND VIOLATION; aborting", .{});
            W.kernel32.ExitProcess(3);
        }
    }
    switch (phase) {
        .running => {
            var all_done = true;
            for (vlist) |*v| {
                if (v.follow) |f| {
                    const leader = find(f) orelse continue;
                    if (!v.started and leader.closed and now - leader.t_close >= 2000) start(v);
                }
                if (!v.started) {
                    all_done = false;
                    continue;
                }
                if (!v.closed) {
                    if (v.navigated or (v.ctrl_hr != 0) or now > 60_000) closeOne(v);
                    all_done = false;
                    continue;
                }
                if (v.kill_after_ms > 0 and !v.killed and now - v.t_close >= v.kill_after_ms) killTree(v);
                if (v.browser) |b| {
                    if (v.t_browser_exit == 0 and W.kernel32.WaitForSingleObject(b, 0) == 0) {
                        v.t_browser_exit = now;
                        logf("{s}: browser process {d} exited {d} ms after Close", .{ v.name, v.browser_pid, now - v.t_close });
                    }
                }
                const done = if (v.keep_env and v.exit_handler) v.t_exited_event != 0 else (v.browser == null or v.t_browser_exit != 0);
                if (!done) all_done = false;
                if (!done and now - last_report >= 10_000) logf("{s}: still waiting {d} ms after Close", .{ v.name, now - v.t_close });
            }
            if (now - last_report >= 10_000) last_report = now;
            if (all_done or now - phase_start > wait_ms) {
                for (vlist) |*v| {
                    if (v.env) |e| e.release();
                    v.env = null;
                }
                phase = .deleting;
                phase_start = now;
            }
        },
        .deleting => {
            var all = true;
            for (vlist) |*v| {
                if (v.deleted or v.follow != null) continue;
                std.fs.deleteTreeAbsolute(v.udf) catch {
                    all = false;
                    continue;
                };
                v.deleted = true;
                v.t_deleted = now;
                logf("{s}: user-data folder deleted {d} ms after Close", .{ v.name, now - v.t_close });
            }
            if (all or now - phase_start > 60_000) PostQuitMessage(0);
        },
    }
}

fn wndProc(hwnd: HWND, msg: u32, wp: W.WPARAM, lp: W.LPARAM) callconv(.winapi) W.LRESULT {
    if (msg == 0x0113 and msg_hwnd != null and hwnd == msg_hwnd.?) {
        tick();
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

pub fn main() !void {
    t0 = std.time.nanoTimestamp();
    self_pid = W.GetCurrentProcessId();
    const argv = try std.process.argsAlloc(gpa);
    if (argv.len < 3 or !std.mem.eql(u8, argv[1], "--scratch")) return error.Usage;
    scratch = argv[2];
    var ai: usize = 3;
    while (ai + 1 < argv.len) : (ai += 2) {
        if (std.mem.eql(u8, argv[ai], "--wait")) wait_ms = 1000 * (std.fmt.parseInt(i64, argv[ai + 1], 10) catch 60);
        if (std.mem.eql(u8, argv[ai], "--only")) {
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, argv[ai + 1], ',');
            while (it.next()) |want| {
                for (variants[n..], n..) |cand, k| {
                    if (std.mem.eql(u8, cand.name, want)) {
                        std.mem.swap(Variant, &variants[n], &variants[k]);
                        n += 1;
                        break;
                    }
                }
            }
            vlist = variants[0..n];
        }
    }
    std.fs.makeDirAbsolute(scratch) catch {};
    log_file = try std.fs.createFileAbsolute(try std.fmt.allocPrint(gpa, "{s}\\s5close.log", .{scratch}), .{});
    _ = CoInitializeEx(null, 0x2);
    loader = try wv2.loadLoader();
    hinst = @ptrCast(W.kernel32.GetModuleHandleW(null));
    const wc: WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .hInstance = hinst, .lpszClassName = cls };
    _ = RegisterClassExW(&wc);
    msg_hwnd = CreateWindowExW(0, cls, L("t"), 0, 0, 0, 0, 0, @ptrFromInt(@as(usize, @bitCast(@as(isize, -3)))), null, hinst, null);
    for (vlist) |*v| {
        const owner = if (v.follow) |f| (find(f) orelse return error.FollowTargetNotSelected) else v;
        v.udf = try std.fmt.allocPrint(gpa, "{s}\\udf-{s}", .{ scratch, owner.name });
        v.udf_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, v.udf);
        if (v.follow) |_| v.args = owner.args;
    }
    for (vlist) |*v| if (v.follow == null) start(v);
    phase_start = 0;
    _ = SetTimer(msg_hwnd, 1, 100, null);
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) _ = DispatchMessageW(&msg);
    for (vlist) |*v| {
        logf("RESULT {s}: ctrl_hr=0x{x:0>8} browser_exit_ms={d} BrowserProcessExited_ms={d} (kind {d}) udf_deleted={} deleted_ms={d}", .{
            v.name,
            hx(v.ctrl_hr),
            if (v.t_browser_exit > 0) v.t_browser_exit - v.t_close else -1,
            if (v.t_exited_event > 0) v.t_exited_event - v.t_close else -1,
            v.exit_kind,
            v.deleted,
            if (v.t_deleted > 0) v.t_deleted - v.t_close else -1,
        });
    }
}
