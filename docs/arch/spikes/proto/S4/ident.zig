//! ident.exe: dummy "agent" that prints which binary ran and what it received.
//! Copied/hardlinked as claude.exe, tmux.exe, node.exe ... in the S4 PATH-precedence tests.
//! Exit code: $S4_EXIT (decimal or 0x hex), default 0.
const std = @import("std");
const w = @import("w32.zig");

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const exe = w.toUtf8(a, w.modulePath(a));
    const cmdline = w.toUtf8(a, std.mem.span(w.GetCommandLineW()));
    w.print("S4IDENT exe={s}\r\n", .{exe});
    w.print("S4IDENT cmdline={s}\r\n", .{cmdline});

    const args = std.process.argsAlloc(a) catch unreachable;
    for (args, 0..) |arg, i| w.print("S4IDENT argv[{d}]=<{s}>\r\n", .{ i, arg });
    w.print("S4IDENT cwd={s}\r\n", .{w.currentDir(a)});
    if (w.getEnv(a, "CLAUDECODE")) |v| w.print("S4IDENT env CLAUDECODE={s}\r\n", .{v});
    if (w.getEnv(a, "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS")) |v| w.print("S4IDENT env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS={s}\r\n", .{v});
    if (w.getEnv(a, "S4_MARK")) |v| w.print("S4IDENT env S4_MARK={s}\r\n", .{v});
    if (w.getEnv(a, "S4_WRAPPED_BY")) |v| w.print("S4IDENT env S4_WRAPPED_BY={s}\r\n", .{v});

    // stdin probe (only when asked; avoids blocking on an interactive console)
    if (w.getEnv(a, "S4_READ_STDIN")) |_| {
        var total: usize = 0;
        var first: [64]u8 = undefined;
        var first_len: usize = 0;
        const hin = w.GetStdHandle(w.STD_INPUT_HANDLE);
        if (hin) |h| {
            var buf: [4096]u8 = undefined;
            while (true) {
                var n: w.DWORD = 0;
                if (w.ReadFile(h, &buf, buf.len, &n, null) == 0 or n == 0) break;
                if (first_len < first.len) {
                    const take = @min(first.len - first_len, n);
                    @memcpy(first[first_len .. first_len + take], buf[0..take]);
                    first_len += take;
                }
                total += n;
            }
        }
        w.print("S4IDENT stdin bytes={d} head=<{s}>\r\n", .{ total, std.mem.trimRight(u8, first[0..first_len], "\r\n") });
    }

    const code: u32 = if (w.getEnv(a, "S4_EXIT")) |s| w.parseU32(s) else 0;
    w.ExitProcess(code);
}
