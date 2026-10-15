//! child.exe: dummy "real agent" for the Ctrl+C / job / exit-code tests.
//!   child sleep <ms>             default Ctrl+C handling (dies with STATUS_CONTROL_C_EXIT)
//!   child handler <ms>           handler: CTRL_C -> print, ExitProcess(42); timeout -> exit 7
//!   child handler-continue <ms>  handler: CTRL_C -> print, keep running; exit 9 at the end
//!   child raw <ms>               console raw mode (no ENABLE_PROCESSED_INPUT); 0x03 key -> exit 43; timeout -> exit 8
//!   child exit <code>            exit immediately with <code> (decimal, -N or 0x hex)
//!   child grandchild <ms>        spawn "child sleep <ms>" (grandchild), then sleep <ms>
//! Every mode first prints CHILDPID=<pid> so the ConPTY harness can track it.
const std = @import("std");
const w = @import("w32.zig");

var g_mode_continue = false;

fn handler(ctrl: w.DWORD) callconv(.winapi) w.BOOL {
    w.print("CHILD got ctrl event {d}\r\n", .{ctrl});
    if (ctrl == w.CTRL_C_EVENT or ctrl == w.CTRL_BREAK_EVENT) {
        if (g_mode_continue) return w.TRUE;
        w.ExitProcess(42);
    }
    // handler-continue: a distinct code on console close proves the wrapper propagates it
    if (ctrl == w.CTRL_CLOSE_EVENT and g_mode_continue) w.ExitProcess(44);
    return w.FALSE;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const all = std.process.argsAlloc(a) catch unreachable;
    // When launched as "node.exe <script.js> args" (npm shim bypass), skip the script argument.
    const args = if (all.len > 1 and std.mem.endsWith(u8, all[1], ".js")) all[1..] else all;
    const mode = if (args.len > 1) args[1] else "sleep";
    const num: u32 = if (args.len > 2) w.parseU32(args[2]) else 5000;

    w.print("CHILDPID={d} mode={s}\r\n", .{ w.GetCurrentProcessId(), mode });

    if (std.mem.eql(u8, mode, "exit")) {
        w.ExitProcess(num);
    } else if (std.mem.eql(u8, mode, "sleep")) {
        w.Sleep(num);
        w.print("CHILD sleep done\r\n", .{});
        w.ExitProcess(0);
    } else if (std.mem.eql(u8, mode, "handler") or std.mem.eql(u8, mode, "handler-continue")) {
        g_mode_continue = std.mem.eql(u8, mode, "handler-continue");
        if (w.SetConsoleCtrlHandler(handler, w.TRUE) == 0)
            w.print("CHILD SetConsoleCtrlHandler failed err={d}\r\n", .{w.GetLastError()});
        w.Sleep(num);
        w.print("CHILD timeout (no exit via ctrl event)\r\n", .{});
        w.ExitProcess(if (g_mode_continue) 9 else 7);
    } else if (std.mem.eql(u8, mode, "raw")) {
        rawMode(num);
    } else if (std.mem.eql(u8, mode, "grandchild")) {
        spawnGrandchild(a, num, 0);
        w.Sleep(num);
        w.print("CHILD grandchild-parent done\r\n", .{});
        w.ExitProcess(0);
    } else if (std.mem.eql(u8, mode, "daemon")) {
        // libuv "detached" spawn flags (what a Node/Bun agent uses for a background daemon),
        // then the agent itself exits normally.
        spawnGrandchild(a, num, w.DETACHED_PROCESS | w.CREATE_NEW_PROCESS_GROUP);
        w.Sleep(500);
        w.print("CHILD daemon parent exiting\r\n", .{});
        w.ExitProcess(0);
    }
    w.print("CHILD unknown mode\r\n", .{});
    w.ExitProcess(99);
}

fn rawMode(timeout_ms: u32) noreturn {
    const conin = std.unicode.utf8ToUtf16LeStringLiteral("CONIN$");
    const h = w.CreateFileW(conin, w.GENERIC_READ | w.GENERIC_WRITE, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE, null, w.OPEN_EXISTING, 0, null);
    if (h == w.INVALID_HANDLE_VALUE) {
        w.print("CHILD raw: CONIN$ open failed err={d}\r\n", .{w.GetLastError()});
        w.ExitProcess(98);
    }
    var old: w.DWORD = 0;
    _ = w.GetConsoleMode(h, &old);
    if (w.SetConsoleMode(h, w.ENABLE_WINDOW_INPUT) == 0)
        w.print("CHILD raw: SetConsoleMode failed err={d}\r\n", .{w.GetLastError()});
    w.print("CHILD raw mode set (old=0x{x})\r\n", .{old});
    const start = w.GetTickCount64();
    while (true) {
        const elapsed = w.GetTickCount64() - start;
        if (elapsed >= timeout_ms) break;
        const r = w.WaitForSingleObject(h, @intCast(timeout_ms - elapsed));
        if (r != w.WAIT_OBJECT_0) break;
        var recs: [16]w.INPUT_RECORD = undefined;
        var n: w.DWORD = 0;
        if (w.ReadConsoleInputW(h, &recs, recs.len, &n) == 0) break;
        for (recs[0..n]) |rec| {
            if (rec.EventType == w.KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0 and rec.Event.KeyEvent.uChar == 3) {
                w.print("CHILD raw got 0x03 key event (no CTRL_C_EVENT)\r\n", .{});
                _ = w.SetConsoleMode(h, old);
                w.ExitProcess(43);
            }
        }
    }
    _ = w.SetConsoleMode(h, old);
    w.print("CHILD raw timeout\r\n", .{});
    w.ExitProcess(8);
}

fn spawnGrandchild(a: std.mem.Allocator, ms: u32, flags: w.DWORD) void {
    const self = w.toUtf8(a, w.modulePath(a));
    const line = std.fmt.allocPrint(a, "\"{s}\" sleep {d}", .{ self, ms }) catch unreachable;
    const wline = w.toUtf16Z(a, line);
    var si: w.STARTUPINFOW = .{ .cb = @sizeOf(w.STARTUPINFOW) };
    var pi: w.PROCESS_INFORMATION = undefined;
    if (w.CreateProcessW(null, wline.ptr, null, null, w.FALSE, flags, null, null, &si, &pi) == 0) {
        w.print("CHILD grandchild spawn failed err={d}\r\n", .{w.GetLastError()});
        return;
    }
    w.print("GRANDCHILDPID={d}\r\n", .{pi.dwProcessId});
    _ = w.CloseHandle(pi.hThread);
    _ = w.CloseHandle(pi.hProcess);
}
