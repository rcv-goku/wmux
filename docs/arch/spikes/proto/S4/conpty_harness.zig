//! conpty_harness.exe: runs a command line inside a fresh pseudoconsole (the way a wmux tab
//! runs its shell), writes input bytes on a timeline (0x03 = what the terminal sends for
//! Ctrl+C), captures the output, tracks PIDs announced as CHILDPID=/GRANDCHILDPID=/pid=, and
//! reports exit codes, survival and job membership. Headless: no window is ever created.
//!
//! Usage: conpty_harness [options] -- <command line>
//!   --timeout <ms>        overall deadline (default 15000)
//!   --ctrlc-at <ms>       write 0x03 at t (repeatable)
//!   --input-at <ms>:<s>   write text <s> at t ("\r" in <s> is turned into CR)
//!   --kill-root-at <ms>   TerminateProcess(root) at t
//!   --close-at <ms>       ClosePseudoConsole at t
//!   --check-at <ms>       print a snapshot of tracked processes at t (repeatable)
//!   --outer-job           start root inside a job whose only limit is BREAKAWAY_OK (ADR-3.9 tab job)
//!   --linger <ms>         after root exits keep reading <ms>, then snapshot (default 700)
//!   --arm <text>          action times count from the moment <text> first appears in the output
//!                         (robust against slow process start on a loaded machine)
//!   --pre <marker>|<s>    write text <s> as soon as <marker> first appears (independent of --arm;
//!                         used to type a command at the first shell prompt)
//!   --new-group           create the root with CREATE_NEW_PROCESS_GROUP
//!   --gen-at <ms>:<c|break>:<root|0>   AttachConsole(root) and GenerateConsoleCtrlEvent(CTRL_C|CTRL_BREAK,
//!                         group = root pid or 0), the API a supervisor would use instead of typing ^C
const std = @import("std");
const w = @import("w32.zig");

const ActionKind = enum { ctrlc, input, kill_root, close, check, gen };

fn ignoreAll(_: w.DWORD) callconv(.winapi) w.BOOL {
    return w.TRUE; // the harness may attach to the pty console to generate events; never die from them
}
const Action = struct { t: u64, kind: ActionKind, text: []const u8 = "", done: bool = false };

const Tracked = struct { label: []const u8, pid: u32, h: ?w.HANDLE };

var g_mutex: std.Thread.Mutex = .{};
var g_out: std.ArrayList(u8) = .empty;
var g_out_read: w.HANDLE = undefined;
var g_reader_done = std.atomic.Value(bool).init(false);
var g_fg_violation = std.atomic.Value(u32).init(0);
var g_watch_pids: [64]u32 = .{0} ** 64;
var g_watch_n = std.atomic.Value(usize).init(0);

fn readerMain() void {
    var buf: [8192]u8 = undefined;
    while (true) {
        var n: w.DWORD = 0;
        if (w.ReadFile(g_out_read, &buf, buf.len, &n, null) == 0 or n == 0) break;
        g_mutex.lock();
        g_out.appendSlice(std.heap.page_allocator, buf[0..n]) catch {};
        g_mutex.unlock();
    }
    g_reader_done.store(true, .release);
}

fn foregroundSampler() void {
    // Abort if any process of this test ever owns the foreground window (it never should).
    while (!g_reader_done.load(.acquire)) {
        if (w.GetForegroundWindow()) |hwnd| {
            var pid: w.DWORD = 0;
            _ = w.GetWindowThreadProcessId(hwnd, &pid);
            const n = g_watch_n.load(.acquire);
            for (g_watch_pids[0..n]) |p| if (p != 0 and p == pid) g_fg_violation.store(pid, .release);
        }
        w.Sleep(100);
    }
}

fn watch(pid: u32) void {
    const n = g_watch_n.load(.acquire);
    if (n < g_watch_pids.len) {
        g_watch_pids[n] = pid;
        g_watch_n.store(n + 1, .release);
    }
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = std.process.argsAlloc(a) catch unreachable;

    var timeout: u64 = 15000;
    var linger: u64 = 700;
    var outer = false;
    var new_group = false;
    var arm: ?[]const u8 = null;
    var pre_marker: ?[]const u8 = null;
    var pre_text: []const u8 = "";
    var actions: std.ArrayList(Action) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--outer-job")) {
            outer = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--new-group")) {
            new_group = true;
            continue;
        }
        i += 1;
        if (i >= args.len) break;
        const v = args[i];
        const simple = [_]struct { []const u8, ActionKind }{
            .{ "--ctrlc-at", .ctrlc }, .{ "--kill-root-at", .kill_root },
            .{ "--close-at", .close }, .{ "--check-at", .check },
        };
        var matched = false;
        for (simple) |s| if (std.mem.eql(u8, arg, s[0])) {
            actions.append(a, .{ .t = w.parseU32(v), .kind = s[1] }) catch unreachable;
            matched = true;
        };
        if (matched) continue;
        if (std.mem.eql(u8, arg, "--arm")) {
            arm = v;
        } else if (std.mem.eql(u8, arg, "--pre")) {
            const bar = std.mem.indexOfScalar(u8, v, '|') orelse continue;
            pre_marker = v[0..bar];
            pre_text = unescape(a, v[bar + 1 ..]);
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            timeout = w.parseU32(v);
        } else if (std.mem.eql(u8, arg, "--linger")) {
            linger = w.parseU32(v);
        } else if (std.mem.eql(u8, arg, "--gen-at") or std.mem.eql(u8, arg, "--input-at")) {
            const colon = std.mem.indexOfScalar(u8, v, ':') orelse continue;
            const is_gen = std.mem.eql(u8, arg, "--gen-at");
            const text = if (is_gen) v[colon + 1 ..] else unescape(a, v[colon + 1 ..]);
            actions.append(a, .{ .t = w.parseU32(v[0..colon]), .kind = if (is_gen) .gen else .input, .text = text }) catch unreachable;
        }
    }

    // Command line = everything after the first " -- " (verbatim, quoting preserved).
    const full = std.mem.span(w.GetCommandLineW());
    const sep = std.mem.indexOf(u16, full, std.unicode.utf8ToUtf16LeStringLiteral(" -- ")) orelse {
        w.print("usage: conpty_harness [options] -- <command line>\r\n", .{});
        w.ExitProcess(2);
    };
    const cmd = a.dupeZ(u16, full[sep + 4 ..]) catch unreachable;
    w.print("HARNESS cmd={s}\r\n", .{w.toUtf8(a, cmd)});

    // Pipes + pseudoconsole.
    var in_r: w.HANDLE = undefined;
    var in_w: w.HANDLE = undefined;
    var out_r: w.HANDLE = undefined;
    var out_w: w.HANDLE = undefined;
    if (w.CreatePipe(&in_r, &in_w, null, 0) == 0 or w.CreatePipe(&out_r, &out_w, null, 0) == 0) {
        w.print("HARNESS CreatePipe failed err={d}\r\n", .{w.GetLastError()});
        w.ExitProcess(3);
    }
    var hpc: w.HPCON = undefined;
    const hr = w.CreatePseudoConsole(.{ .X = 120, .Y = 30 }, in_r, out_w, 0, &hpc);
    if (hr != 0) {
        w.print("HARNESS CreatePseudoConsole failed hr=0x{X}\r\n", .{@as(u32, @bitCast(@as(i32, @intCast(hr))))});
        w.ExitProcess(3);
    }
    _ = w.CloseHandle(in_r);
    _ = w.CloseHandle(out_w);
    g_out_read = out_r;
    const reader = std.Thread.spawn(.{}, readerMain, .{}) catch unreachable;
    watch(w.GetCurrentProcessId());
    const sampler = std.Thread.spawn(.{}, foregroundSampler, .{}) catch unreachable;

    // Optional outer job (wmux per-tab job: BREAKAWAY_OK only, never KILL_ON_JOB_CLOSE).
    var outer_job: ?w.HANDLE = null;
    if (outer) {
        outer_job = w.CreateJobObjectW(null, null);
        var info: w.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
        info.BasicLimitInformation.LimitFlags = w.JOB_OBJECT_LIMIT_BREAKAWAY_OK;
        if (w.SetInformationJobObject(outer_job.?, w.JobObjectExtendedLimitInformation, &info, @sizeOf(w.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0)
            w.print("HARNESS outer SetInformationJobObject failed err={d}\r\n", .{w.GetLastError()});
    }

    var si: w.STARTUPINFOEXW = .{ .StartupInfo = .{ .cb = @sizeOf(w.STARTUPINFOEXW) }, .lpAttributeList = null };
    const nattr: w.DWORD = if (outer_job != null) 2 else 1;
    var size: usize = 0;
    _ = w.InitializeProcThreadAttributeList(null, nattr, 0, &size);
    const attr_mem = a.alignedAlloc(u8, .@"16", size) catch unreachable;
    _ = w.InitializeProcThreadAttributeList(attr_mem.ptr, nattr, 0, &size);
    if (w.UpdateProcThreadAttribute(attr_mem.ptr, 0, w.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(w.HPCON), null, null) == 0)
        w.print("HARNESS UpdateProcThreadAttribute(PSEUDOCONSOLE) failed err={d}\r\n", .{w.GetLastError()});
    if (outer_job) |*j| {
        if (w.UpdateProcThreadAttribute(attr_mem.ptr, 0, w.PROC_THREAD_ATTRIBUTE_JOB_LIST, @ptrCast(j), @sizeOf(w.HANDLE), null, null) == 0)
            w.print("HARNESS UpdateProcThreadAttribute(JOB_LIST) failed err={d}\r\n", .{w.GetLastError()});
    }
    si.lpAttributeList = attr_mem.ptr;
    // Same recipe as wmux's src/Command.zig: STARTF_USESTDHANDLES with null handles (the child
    // opens the pseudoconsole), bInheritHandles=TRUE, lpApplicationName=NULL.
    si.StartupInfo.dwFlags = w.STARTF_USESTDHANDLES;

    var pi: w.PROCESS_INFORMATION = undefined;
    const create_flags = w.EXTENDED_STARTUPINFO_PRESENT | w.CREATE_UNICODE_ENVIRONMENT | (if (new_group) w.CREATE_NEW_PROCESS_GROUP else 0);
    if (w.CreateProcessW(null, cmd.ptr, null, null, w.TRUE, create_flags, null, null, &si.StartupInfo, &pi) == 0) {
        w.print("HARNESS CreateProcessW failed err={d}\r\n", .{w.GetLastError()});
        w.ClosePseudoConsole(hpc);
        w.ExitProcess(4);
    }
    _ = w.CloseHandle(pi.hThread);
    watch(pi.dwProcessId);
    const t0 = w.GetTickCount64();
    w.print("HARNESS root pid={d}\r\n", .{pi.dwProcessId});

    var tracked: std.ArrayList(Tracked) = .empty;
    var scanned: usize = 0;
    var root_exited_at: ?u64 = null;
    var root_code: w.DWORD = 0;
    var closed = false;
    var armed_at: ?u64 = if (arm == null) 0 else null;

    while (true) {
        const now = w.GetTickCount64() - t0;
        scanned = scanPids(a, &tracked, scanned);
        if (pre_marker) |m| {
            g_mutex.lock();
            const seen = std.mem.indexOf(u8, g_out.items, m) != null;
            g_mutex.unlock();
            if (seen) {
                var n: w.DWORD = 0;
                _ = w.WriteFile(in_w, pre_text.ptr, @intCast(pre_text.len), &n, null);
                w.print("HARNESS t={d} saw \"{s}\", typed {d} bytes\r\n", .{ now, m, pre_text.len });
                pre_marker = null;
            }
        }
        if (armed_at == null) {
            g_mutex.lock();
            const seen = std.mem.indexOf(u8, g_out.items, arm.?) != null;
            g_mutex.unlock();
            if (seen) {
                armed_at = now;
                w.print("HARNESS t={d} armed (saw \"{s}\")\r\n", .{ now, arm.? });
            }
        }
        if (g_fg_violation.load(.acquire) != 0) {
            w.print("HARNESS FOREGROUND VIOLATION pid={d}; aborting\r\n", .{g_fg_violation.load(.acquire)});
            killAll(&tracked, pi.hProcess, outer_job);
            w.ExitProcess(5);
        }
        for (actions.items) |*act| {
            const base = armed_at orelse break;
            if (act.done or now < base + act.t) continue;
            act.done = true;
            switch (act.kind) {
                .ctrlc => {
                    var n: w.DWORD = 0;
                    _ = w.WriteFile(in_w, "\x03", 1, &n, null);
                    w.print("HARNESS t={d} wrote 0x03\r\n", .{now});
                },
                .input => {
                    var n: w.DWORD = 0;
                    _ = w.WriteFile(in_w, act.text.ptr, @intCast(act.text.len), &n, null);
                    w.print("HARNESS t={d} wrote {d} bytes\r\n", .{ now, act.text.len });
                },
                .kill_root => {
                    _ = w.TerminateProcess(pi.hProcess, 0xDEAD);
                    w.print("HARNESS t={d} TerminateProcess(root)\r\n", .{now});
                },
                .close => {
                    w.print("HARNESS t={d} ClosePseudoConsole...\r\n", .{now});
                    w.ClosePseudoConsole(hpc);
                    closed = true;
                    w.print("HARNESS t={d} ClosePseudoConsole returned\r\n", .{w.GetTickCount64() - t0});
                },
                .check => snapshot(&tracked, pi.hProcess, outer_job, now),
                .gen => {
                    const ev: w.DWORD = if (std.mem.startsWith(u8, act.text, "break")) w.CTRL_BREAK_EVENT else w.CTRL_C_EVENT;
                    const group: w.DWORD = if (std.mem.endsWith(u8, act.text, ":root")) pi.dwProcessId else 0;
                    _ = w.FreeConsole();
                    if (w.AttachConsole(pi.dwProcessId) == 0) {
                        w.print("HARNESS t={d} AttachConsole(root) failed err={d}\r\n", .{ now, w.GetLastError() });
                    } else {
                        // Observed: a handler registered before AttachConsole did not protect this
                        // process (it died with 0xC000013A on a group-0 CTRL_C_EVENT); register after
                        // attaching and also set the ignore flag (no children are created after this).
                        _ = w.SetConsoleCtrlHandler(null, w.TRUE);
                        _ = w.SetConsoleCtrlHandler(ignoreAll, w.TRUE);
                        const ok = w.GenerateConsoleCtrlEvent(ev, group);
                        const err = w.GetLastError();
                        w.Sleep(50);
                        _ = w.FreeConsole();
                        w.print("HARNESS t={d} GenerateConsoleCtrlEvent({s}, group={d}) ok={d} err={d}\r\n", .{ now, if (ev == w.CTRL_C_EVENT) "CTRL_C_EVENT" else "CTRL_BREAK_EVENT", group, ok, if (ok == 0) err else 0 });
                    }
                },
            }
        }
        if (root_exited_at == null and w.WaitForSingleObject(pi.hProcess, 0) == w.WAIT_OBJECT_0) {
            _ = w.GetExitCodeProcess(pi.hProcess, &root_code);
            root_exited_at = now;
            w.print("HARNESS t={d} root exited code={d} (0x{X})\r\n", .{ now, root_code, root_code });
        }
        if (root_exited_at) |t| if (now >= t + linger) break;
        if (now >= timeout) {
            w.print("HARNESS t={d} TIMEOUT (root still running)\r\n", .{now});
            break;
        }
        w.Sleep(5);
    }
    scanned = scanPids(a, &tracked, scanned);
    snapshot(&tracked, pi.hProcess, outer_job, w.GetTickCount64() - t0);

    // Cleanup: nothing may survive the test.
    killAll(&tracked, pi.hProcess, outer_job);
    if (!closed) w.ClosePseudoConsole(hpc);
    _ = w.CloseHandle(in_w);
    reader.join();
    sampler.join();
    const w32im = std.mem.indexOf(u8, g_out.items, "\x1b[?9001h") != null;
    w.print("HARNESS conpty requested win32-input-mode (CSI ?9001h): {s}\r\n", .{if (w32im) "yes" else "no"});
    w.print("--- pty output (VT stripped) ---\r\n", .{});
    printStripped(a, g_out.items);
    w.print("--- end ---\r\n", .{});
    w.ExitProcess(0);
}

/// "\r" -> CR, "\e" -> ESC (win32-input-mode sequences are written as \e[Vk;Sc;Uc;Kd;Cs;Rc_).
fn unescape(a: std.mem.Allocator, s: []const u8) []const u8 {
    const t = std.mem.replaceOwned(u8, a, s, "\\r", "\r") catch unreachable;
    return std.mem.replaceOwned(u8, a, t, "\\e", "\x1b") catch unreachable;
}

fn scanPids(a: std.mem.Allocator, tracked: *std.ArrayList(Tracked), from: usize) usize {
    g_mutex.lock();
    const text = a.dupe(u8, g_out.items) catch unreachable;
    g_mutex.unlock();
    const labels = [_][]const u8{ "GRANDCHILDPID=", "CHILDPID=", "spawned pid=" };
    // Only scan complete lines.
    const end = (std.mem.lastIndexOfScalar(u8, text, '\n') orelse return from) + 1;
    if (end <= from) return from;
    const chunk = text[from..end];
    for (labels) |label| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, chunk, pos, label)) |at| {
            pos = at + label.len;
            if (std.mem.eql(u8, label, "CHILDPID=") and at > 0 and chunk[at - 1] == 'D') continue; // part of GRANDCHILDPID=
            var e = pos;
            while (e < chunk.len and chunk[e] >= '0' and chunk[e] <= '9') e += 1;
            const pid = std.fmt.parseInt(u32, chunk[pos..e], 10) catch continue;
            var known = false;
            for (tracked.items) |t| if (t.pid == pid) {
                known = true;
            };
            if (known) continue;
            const h = w.OpenProcess(w.SYNCHRONIZE | w.PROCESS_QUERY_LIMITED_INFORMATION | w.PROCESS_TERMINATE, w.FALSE, pid);
            const name = if (std.mem.eql(u8, label, "GRANDCHILDPID=")) "grandchild" else if (std.mem.eql(u8, label, "CHILDPID=")) "child" else "wrapper-child";
            tracked.append(a, .{ .label = name, .pid = pid, .h = h }) catch unreachable;
            watch(pid);
        }
    }
    return end;
}

fn snapshot(tracked: *std.ArrayList(Tracked), root: w.HANDLE, outer_job: ?w.HANDLE, now: u64) void {
    w.print("HARNESS snapshot t={d}\r\n", .{now});
    w.print("HARNESS   root alive={s}{s}\r\n", .{ aliveStr(root), jobStr(root, outer_job) });
    for (tracked.items) |t| {
        if (t.h) |h| {
            var code: w.DWORD = 0;
            _ = w.GetExitCodeProcess(h, &code);
            w.print("HARNESS   {s} pid={d} alive={s} exitcode={d} (0x{X}){s}\r\n", .{ t.label, t.pid, aliveStr(h), code, code, jobStr(h, outer_job) });
        } else w.print("HARNESS   {s} pid={d} (could not open: already gone)\r\n", .{ t.label, t.pid });
    }
    if (outer_job) |j| {
        var buf: [8 + 64 * 8]u8 align(8) = undefined;
        if (w.QueryInformationJobObject(j, w.JobObjectBasicProcessIdList, &buf, buf.len, null) != 0) {
            const assigned = std.mem.readInt(u32, buf[0..4], .little);
            const listed = std.mem.readInt(u32, buf[4..8], .little);
            w.print("HARNESS   outer job: assigned={d} listed={d} pids=", .{ assigned, listed });
            var k: usize = 0;
            while (k < listed and k < 64) : (k += 1) {
                const pid = std.mem.readInt(u64, buf[8 + k * 8 ..][0..8], .little);
                w.print("{d} ", .{pid});
            }
            w.print("\r\n", .{});
        } else w.print("HARNESS   outer job query failed err={d}\r\n", .{w.GetLastError()});
    }
}

fn aliveStr(h: w.HANDLE) []const u8 {
    return if (w.WaitForSingleObject(h, 0) == w.WAIT_TIMEOUT) "yes" else "no";
}

fn jobStr(h: w.HANDLE, outer_job: ?w.HANDLE) []const u8 {
    const j = outer_job orelse return "";
    var in_job: w.BOOL = 0;
    if (w.IsProcessInJob(h, j, &in_job) == 0) return " in_outer_job=?";
    return if (in_job != 0) " in_outer_job=1" else " in_outer_job=0";
}

fn killAll(tracked: *std.ArrayList(Tracked), root: w.HANDLE, outer_job: ?w.HANDLE) void {
    for (tracked.items) |t| if (t.h) |h| if (w.WaitForSingleObject(h, 0) == w.WAIT_TIMEOUT) {
        _ = w.TerminateProcess(h, 0xC1EA);
        w.print("HARNESS cleanup: killed leftover {s} pid={d}\r\n", .{ t.label, t.pid });
    };
    if (w.WaitForSingleObject(root, 0) == w.WAIT_TIMEOUT) {
        _ = w.TerminateProcess(root, 0xC1EA);
        w.print("HARNESS cleanup: killed leftover root\r\n", .{});
    }
    if (outer_job) |j| _ = w.TerminateJobObject(j, 0xC1EA);
}

fn printStripped(a: std.mem.Allocator, raw: []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    var k: usize = 0;
    while (k < raw.len) {
        const c = raw[k];
        if (c == 0x1b and k + 1 < raw.len) {
            const n = raw[k + 1];
            if (n == '[') {
                var e = k + 2;
                while (e < raw.len and !(raw[e] >= 0x40 and raw[e] <= 0x7e)) e += 1;
                if (e < raw.len and (raw[e] == 'H' or raw[e] == 'f')) out.append(a, '\n') catch {};
                k = e + 1;
                continue;
            } else if (n == ']') {
                var e = k + 2;
                while (e < raw.len and raw[e] != 0x07 and !(raw[e] == 0x1b and e + 1 < raw.len and raw[e + 1] == '\\')) e += 1;
                k = if (e < raw.len and raw[e] == 0x07) e + 1 else e + 2;
                continue;
            }
            k += 2;
            continue;
        }
        if (c == '\r') {
            k += 1;
            continue;
        }
        if (c == '\n' or (c >= 0x20 and c < 0x7f)) out.append(a, c) catch {};
        k += 1;
    }
    var it = std.mem.splitScalar(u8, out.items, '\n');
    while (it.next()) |line| {
        const t = std.mem.trimRight(u8, line, " ");
        if (t.len == 0) continue;
        w.print("  | {s}\r\n", .{t});
    }
}
