//! wmux spike S6: fake "cli\cmux.exe" used as the forwarding target (prototype, MIT).
//!
//! Modes (argv[1]):
//!   argv                 print a JSON report: raw command line, argv, own exe
//!                        path, pid/ppid, job membership, std handle kinds,
//!                        inherited Ctrl+C-ignore flag, WMUX_ARGV0
//!   exit <n>             exit with n (decimal, 0x hex or negative; all 32 bits)
//!   cat                  copy stdin to stdout (binary)
//!   sha                  print "<bytes> <sha256>" of stdin
//!   emit <n>             write n pattern bytes ((i*7+3)&0xff) to stdout
//!   stderr               "OUT-LINE" to stdout, "ERR-LINE" to stderr, exit 3
//!   ctrlc [secs]         print READY, exit 130 on Ctrl+C/Break, 124 on timeout
//!   sleep <secs>         print PID=<pid>, sleep, exit 0
//!   spawn-grandchild <s> start "<self> sleep <s>" detached, print GPID=<pid>
//! Build: zig build-exe target.zig -O ReleaseSafe -target x86_64-windows-gnu
const std = @import("std");
const w = std.os.windows;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn GetConsoleMode(h: w.HANDLE, mode: *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetFileType(h: w.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn IsProcessInJob(process: w.HANDLE, job: ?w.HANDLE, result: *w.BOOL) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(.winapi) w.BOOL, add: w.BOOL) callconv(.winapi) w.BOOL;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, len: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(h: w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateProcessW(
    app: ?[*:0]const u16,
    cmd: ?[*:0]u16,
    pa: ?*anyopaque,
    ta: ?*anyopaque,
    inherit: w.BOOL,
    flags: u32,
    env: ?*anyopaque,
    cwd: ?[*:0]const u16,
    si: *w.STARTUPINFOW,
    pi: *w.PROCESS_INFORMATION,
) callconv(.winapi) w.BOOL;
extern "ntdll" fn NtQueryInformationProcess(h: w.HANDLE, class: u32, info: *anyopaque, len: u32, ret_len: ?*u32) callconv(.winapi) i32;

const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));

const PROCESS_BASIC_INFORMATION = extern struct {
    ExitStatus: i32,
    PebBaseAddress: ?*anyopaque,
    AffinityMask: usize,
    BasePriority: i32,
    UniqueProcessId: usize,
    InheritedFromUniqueProcessId: usize,
};

var got_ctrl = std.atomic.Value(u32).init(0xFFFF_FFFF);

fn ctrlHandler(ctrl: u32) callconv(.winapi) w.BOOL {
    if (ctrl == 0 or ctrl == 1) {
        got_ctrl.store(ctrl, .seq_cst);
        return 1;
    }
    return 0;
}

fn handleKind(which: u32) []const u8 {
    const h = GetStdHandle(which) orelse return "null";
    if (@intFromPtr(h) == std.math.maxInt(usize)) return "invalid";
    var mode: u32 = 0;
    if (GetConsoleMode(h, &mode) != 0) return "console";
    return switch (GetFileType(h)) {
        1 => "disk",
        2 => "char",
        3 => "pipe",
        else => "unknown",
    };
}

fn ppid() usize {
    var pbi = std.mem.zeroes(PROCESS_BASIC_INFORMATION);
    if (NtQueryInformationProcess(GetCurrentProcess(), 0, &pbi, @sizeOf(PROCESS_BASIC_INFORMATION), null) != 0) return 0;
    return pbi.InheritedFromUniqueProcessId;
}

fn writeAll(which: u32, bytes: []const u8) void {
    const f: std.fs.File = .{ .handle = GetStdHandle(which) orelse return };
    f.writeAll(bytes) catch {};
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.process.argsAlloc(arena);
    const mode: []const u8 = if (args.len > 1) args[1] else "argv";

    if (std.mem.eql(u8, mode, "argv")) {
        const cl = GetCommandLineW();
        const cl8 = try std.unicode.wtf16LeToWtf8Alloc(arena, cl[0..std.mem.len(cl)]);
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe = std.fs.selfExePath(&exe_buf) catch "?";
        var in_job: w.BOOL = 0;
        _ = IsProcessInJob(GetCurrentProcess(), null, &in_job);
        const argv0_env: ?[]const u8 = std.process.getEnvVarOwned(arena, "WMUX_ARGV0") catch null;
        const params = w.peb().ProcessParameters;
        const Report = struct {
            cmdline: []const u8,
            argv: []const [:0]u8,
            exe: []const u8,
            pid: u32,
            ppid: usize,
            in_job: bool,
            stdin: []const u8,
            stdout: []const u8,
            stderr: []const u8,
            console_cp: u32,
            console_window: bool,
            ignore_ctrl_c_flag: bool,
            WMUX_ARGV0: ?[]const u8,
        };
        const report: Report = .{
            .cmdline = cl8,
            .argv = args,
            .exe = exe,
            .pid = GetCurrentProcessId(),
            .ppid = ppid(),
            .in_job = in_job != 0,
            .stdin = handleKind(STD_INPUT_HANDLE),
            .stdout = handleKind(STD_OUTPUT_HANDLE),
            .stderr = handleKind(STD_ERROR_HANDLE),
            .console_cp = GetConsoleOutputCP(),
            .console_window = GetConsoleWindow() != null,
            .ignore_ctrl_c_flag = (params.ConsoleFlags & 1) != 0,
            .WMUX_ARGV0 = argv0_env,
        };
        var aw: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(report, .{}, &aw.writer);
        try aw.writer.writeAll("\n");
        writeAll(STD_OUTPUT_HANDLE, aw.written());
        // Optional copy to a file: proves where the report went when stdout did not
        // reach the caller (e.g. a new console was created for us).
        if (std.process.getEnvVarOwned(arena, "WMUXSPIKEFWD_REPORT")) |path| {
            if (std.fs.createFileAbsolute(path, .{})) |f| {
                defer f.close();
                f.writeAll(aw.written()) catch {};
            } else |_| {}
        } else |_| {}
        return;
    }

    if (std.mem.eql(u8, mode, "exit")) {
        const v: i64 = if (args.len > 2) std.fmt.parseInt(i64, args[2], 0) catch 99 else 0;
        ExitProcess(@truncate(@as(u64, @bitCast(v))));
    }

    if (std.mem.eql(u8, mode, "cat") or std.mem.eql(u8, mode, "sha")) {
        const in: std.fs.File = .{ .handle = GetStdHandle(STD_INPUT_HANDLE) orelse return error.NoStdin };
        const out: std.fs.File = .{ .handle = GetStdHandle(STD_OUTPUT_HANDLE) orelse return error.NoStdout };
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var total: u64 = 0;
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = in.read(&buf) catch |err| switch (err) {
                error.BrokenPipe => 0,
                else => return err,
            };
            if (n == 0) break;
            total += n;
            if (mode[0] == 'c') try out.writeAll(buf[0..n]) else hasher.update(buf[0..n]);
        }
        if (mode[0] == 's') {
            var digest: [32]u8 = undefined;
            hasher.final(&digest);
            const hex = std.fmt.bytesToHex(digest, .lower);
            const line = try std.fmt.allocPrint(arena, "{d} {s}\n", .{ total, &hex });
            try out.writeAll(line);
        }
        return;
    }

    if (std.mem.eql(u8, mode, "emit")) {
        const count: usize = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 0) else 0;
        const out: std.fs.File = .{ .handle = GetStdHandle(STD_OUTPUT_HANDLE) orelse return error.NoStdout };
        var buf: [65536]u8 = undefined;
        var i: usize = 0;
        while (i < count) {
            const chunk = @min(buf.len, count - i);
            for (buf[0..chunk], 0..) |*b, k| b.* = @truncate((i + k) *% 7 +% 3);
            try out.writeAll(buf[0..chunk]);
            i += chunk;
        }
        return;
    }

    if (std.mem.eql(u8, mode, "stderr")) {
        writeAll(STD_OUTPUT_HANDLE, "OUT-LINE\n");
        writeAll(STD_ERROR_HANDLE, "ERR-LINE\n");
        ExitProcess(3);
    }

    if (std.mem.eql(u8, mode, "ctrlc")) {
        const secs: u32 = if (args.len > 2) std.fmt.parseInt(u32, args[2], 10) catch 20 else 20;
        _ = SetConsoleCtrlHandler(ctrlHandler, 1);
        const flag = (w.peb().ProcessParameters.ConsoleFlags & 1) != 0;
        writeAll(STD_OUTPUT_HANDLE, if (flag) "READY ignore_flag=1\r\n" else "READY ignore_flag=0\r\n");
        var t: u32 = 0;
        while (t < secs * 10) : (t += 1) {
            Sleep(100);
            const c = got_ctrl.load(.seq_cst);
            if (c != 0xFFFF_FFFF) {
                writeAll(STD_OUTPUT_HANDLE, if (c == 0) "GOT_CTRL_C\r\n" else "GOT_CTRL_BREAK\r\n");
                ExitProcess(130);
            }
        }
        writeAll(STD_OUTPUT_HANDLE, "TIMEOUT\r\n");
        ExitProcess(124);
    }

    if (std.mem.eql(u8, mode, "sleep")) {
        const secs: u32 = if (args.len > 2) std.fmt.parseInt(u32, args[2], 10) catch 10 else 10;
        const line = try std.fmt.allocPrint(arena, "PID={d}\n", .{GetCurrentProcessId()});
        writeAll(STD_OUTPUT_HANDLE, line);
        Sleep(secs * 1000);
        return;
    }

    if (std.mem.eql(u8, mode, "spawn-grandchild")) {
        const secs: []const u8 = if (args.len > 2) args[2] else "15";
        var self_w: [32768]u16 = undefined;
        const n = GetModuleFileNameW(null, &self_w, self_w.len);
        self_w[n] = 0;
        const self8 = try std.unicode.wtf16LeToWtf8Alloc(arena, self_w[0..n]);
        const cmd8 = try std.fmt.allocPrint(arena, "\"{s}\" sleep {s}", .{ self8, secs });
        const cmd16 = try std.unicode.wtf8ToWtf16LeAllocZ(arena, cmd8);
        var si = std.mem.zeroes(w.STARTUPINFOW);
        si.cb = @sizeOf(w.STARTUPINFOW);
        var pi: w.PROCESS_INFORMATION = undefined;
        // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP, no handle inheritance.
        if (CreateProcessW(self_w[0..n :0], cmd16, null, null, 0, 0x8 | 0x200, null, null, &si, &pi) == 0)
            return error.SpawnFailed;
        _ = CloseHandle(pi.hThread);
        _ = CloseHandle(pi.hProcess);
        const line = try std.fmt.allocPrint(arena, "GPID={d}\n", .{pi.dwProcessId});
        writeAll(STD_OUTPUT_HANDLE, line);
        return;
    }

    writeAll(STD_ERROR_HANDLE, "unknown mode\n");
    ExitProcess(2);
}
