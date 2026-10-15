//! spawner.exe: "another program spawns claude" probe.
//!   spawner create <command line...>   CreateProcessW(NULL, "<command line>") (the raw API search:
//!                                      app dir, cwd, system dirs, PATH; only ".exe" is appended)
//!   spawner search <name>              SearchPathW(NULL, name, ".exe") result
const std = @import("std");
const w = @import("w32.zig");

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = std.process.argsAlloc(a) catch unreachable;
    if (args.len < 3) {
        w.print("usage: spawner create <cmdline> | spawner search <name>\r\n", .{});
        w.ExitProcess(2);
    }
    if (std.mem.eql(u8, args[1], "search")) {
        const name = w.toUtf16Z(a, args[2]);
        var buf: [32768]u16 = undefined;
        const n = w.SearchPathW(null, name.ptr, std.unicode.utf8ToUtf16LeStringLiteral(".exe"), buf.len, &buf, null);
        if (n == 0) w.print("SPAWNER SearchPathW({s}) failed err={d}\r\n", .{ args[2], w.GetLastError() }) else w.print("SPAWNER SearchPathW({s}) = {s}\r\n", .{ args[2], w.toUtf8(a, buf[0..n]) });
        w.ExitProcess(0);
    }
    // Raw tail after "create " so the caller's quoting is preserved.
    const full = std.mem.span(w.GetCommandLineW());
    const marker = std.unicode.utf8ToUtf16LeStringLiteral(" create ");
    const at = std.mem.indexOf(u16, full, marker) orelse w.ExitProcess(2);
    const cmd = a.dupeZ(u16, full[at + marker.len ..]) catch unreachable;
    var si: w.STARTUPINFOW = .{ .cb = @sizeOf(w.STARTUPINFOW) };
    var pi: w.PROCESS_INFORMATION = undefined;
    if (w.CreateProcessW(null, cmd.ptr, null, null, w.TRUE, 0, null, null, &si, &pi) == 0) {
        w.print("SPAWNER CreateProcessW(NULL, \"{s}\") failed err={d}\r\n", .{ w.toUtf8(a, cmd), w.GetLastError() });
        w.ExitProcess(1);
    }
    _ = w.WaitForSingleObject(pi.hProcess, w.INFINITE);
    var code: w.DWORD = 0;
    _ = w.GetExitCodeProcess(pi.hProcess, &code);
    w.print("SPAWNER child exit={d}\r\n", .{code});
    w.ExitProcess(code);
}
