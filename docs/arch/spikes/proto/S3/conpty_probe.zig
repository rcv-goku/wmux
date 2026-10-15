//! S3 spike reference prototype (not shipped): raw ConPTY output probe.
//!
//! Spawns a command under the in-box ConPTY (kernel32!CreatePseudoConsole)
//! exactly the way wmux does in src/pty.zig + src/Command.zig (UTF-8 console
//! code pages, STARTF_USESTDHANDLES with null handles, bInheritHandles=TRUE,
//! CREATE_UNICODE_ENVIRONMENT|EXTENDED_STARTUPINFO_PRESENT) and logs every
//! output chunk with a millisecond timestamp, so the startup clear/redraw
//! sequence that ConPTY sends to the terminal can be inspected.
//!
//! Build (outside the repo tree):
//!   zig build-exe conpty_probe.zig -target x86_64-windows-gnu -O ReleaseSafe
//!
//! Usage:
//!   conpty_probe <out.txt> <cols> <rows> <flags> <run_ms>
//!                <resize_at_ms|-1> <resize_cols> <resize_rows>
//!                <input_at_ms|-1> <input_text|-> <cmdline...>
//!
//! flags: 0 = wmux default, 1 = PSEUDOCONSOLE_INHERIT_CURSOR (the probe then
//! answers ConPTY's DSR-CPR query with row 10, column 1).
//! input_text: "\r" in the argument is sent as a carriage return.

const std = @import("std");
const w = std.os.windows;

const HPCON = *anyopaque;
const COORD = extern struct { X: i16, Y: i16 };

const STARTUPINFOEXW = extern struct {
    StartupInfo: w.STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const EXTENDED_STARTUPINFO_PRESENT: u32 = 0x00080000;
const CREATE_UNICODE_ENVIRONMENT: u32 = 0x00000400;

extern "kernel32" fn CreatePseudoConsole(size: COORD, hInput: w.HANDLE, hOutput: w.HANDLE, dwFlags: u32, phPC: *HPCON) callconv(.winapi) w.HRESULT;
extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) w.HRESULT;
extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
extern "kernel32" fn CreatePipe(hReadPipe: *w.HANDLE, hWritePipe: *w.HANDLE, lpPipeAttributes: ?*const w.SECURITY_ATTRIBUTES, nSize: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn SetConsoleCP(cp: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: u32, flags: u32, size: *usize) callconv(.winapi) w.BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: ?*anyopaque, flags: u32, attr: usize, value: ?*anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: w.BOOL, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *w.STARTUPINFOW, pi: *w.PROCESS_INFORMATION) callconv(.winapi) w.BOOL;
extern "kernel32" fn ReadFile(h: w.HANDLE, buf: [*]u8, n: u32, read: *u32, ov: ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn WriteFile(h: w.HANDLE, buf: [*]const u8, n: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(h: w.HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn TerminateProcess(h: w.HANDLE, code: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(h: w.HANDLE) callconv(.winapi) w.BOOL;

const Chunk = struct { t_ms: i64, data: []u8 };

const Shared = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    chunks: std.ArrayList(Chunk) = .empty,
    markers: std.ArrayList(Chunk) = .empty,
    t0: i64,
    out_read: w.HANDLE,
    in_write: w.HANDLE,
    answer_dsr: bool,
    read_error: u32 = 0,
};

fn now() i64 {
    return std.time.milliTimestamp();
}

fn readerMain(s: *Shared) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        if (ReadFile(s.out_read, &buf, buf.len, &n, null) == 0) {
            s.read_error = GetLastError();
            return;
        }
        if (n == 0) continue;
        const t = now() - s.t0;
        const copy = s.gpa.dupe(u8, buf[0..n]) catch return;
        s.mutex.lock();
        s.chunks.append(s.gpa, .{ .t_ms = t, .data = copy }) catch {};
        s.mutex.unlock();
        // INHERIT_CURSOR mode: ConPTY blocks until the terminal answers
        // DSR 6 (ESC[6n) with a CPR. Pretend the cursor is at row 10 col 1.
        if (s.answer_dsr and std.mem.indexOf(u8, buf[0..n], "\x1b[6n") != null) {
            const resp = "\x1b[10;1R";
            var wr: u32 = 0;
            _ = WriteFile(s.in_write, resp.ptr, resp.len, &wr, null);
            mark(s, "answered DSR-CPR with ESC[10;1R");
        }
    }
}

fn mark(s: *Shared, text: []const u8) void {
    const copy = s.gpa.dupe(u8, text) catch return;
    s.mutex.lock();
    defer s.mutex.unlock();
    s.markers.append(s.gpa, .{ .t_ms = now() - s.t0, .data = copy }) catch {};
}

fn escapeInto(out: *std.ArrayList(u8), gpa: std.mem.Allocator, data: []const u8) !void {
    for (data) |c| {
        switch (c) {
            0x1b => try out.appendSlice(gpa, "\\e"),
            0x07 => try out.appendSlice(gpa, "\\a"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            0x00...0x06, 0x08...0x09, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {
                var tmp: [4]u8 = undefined;
                try out.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "\\x{x:0>2}", .{c}));
            },
            else => try out.append(gpa, c),
        }
    }
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 12) {
        std.debug.print("usage: conpty_probe <out> <cols> <rows> <flags> <run_ms> <resize_at|-1> <rcols> <rrows> <input_at|-1> <input|-> <cmdline...>\n", .{});
        std.process.exit(2);
    }
    const out_path = args[1];
    const cols = try std.fmt.parseInt(i16, args[2], 10);
    const rows = try std.fmt.parseInt(i16, args[3], 10);
    const flags = try std.fmt.parseInt(u32, args[4], 10);
    const run_ms = try std.fmt.parseInt(i64, args[5], 10);
    const resize_at = try std.fmt.parseInt(i64, args[6], 10);
    const rcols = try std.fmt.parseInt(i16, args[7], 10);
    const rrows = try std.fmt.parseInt(i16, args[8], 10);
    const input_at = try std.fmt.parseInt(i64, args[9], 10);
    const input_raw = args[10];
    const cmdline = try std.mem.join(gpa, " ", args[11..]);
    defer gpa.free(cmdline);

    // Input text: translate the two-character sequence \r into CR.
    const input_text = try std.mem.replaceOwned(u8, gpa, input_raw, "\\r", "\r");
    defer gpa.free(input_text);

    var in_read: w.HANDLE = undefined;
    var in_write: w.HANDLE = undefined;
    var out_read: w.HANDLE = undefined;
    var out_write: w.HANDLE = undefined;
    if (CreatePipe(&in_read, &in_write, null, 0) == 0) return error.CreatePipeIn;
    if (CreatePipe(&out_read, &out_write, null, 0) == 0) return error.CreatePipeOut;

    // Same as wmux src/pty.zig: UTF-8 console code pages before creation.
    _ = SetConsoleCP(65001);
    _ = SetConsoleOutputCP(65001);

    var hpc: HPCON = undefined;
    const hr = CreatePseudoConsole(.{ .X = cols, .Y = rows }, in_read, out_write, flags, &hpc);
    if (hr != 0) {
        std.debug.print("CreatePseudoConsole hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.CreatePseudoConsole;
    }
    // ConPTY duplicated its ends; close ours so the reader sees EOF later.
    _ = CloseHandle(in_read);
    _ = CloseHandle(out_write);

    var attr_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr_buf = try gpa.alloc(u8, attr_size);
    defer gpa.free(attr_buf);
    if (InitializeProcThreadAttributeList(attr_buf.ptr, 1, 0, &attr_size) == 0) return error.InitAttr;
    if (UpdateProcThreadAttribute(attr_buf.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(HPCON), null, null) == 0) return error.UpdateAttr;

    var si: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    si.StartupInfo.dwFlags = w.STARTF_USESTDHANDLES;
    si.lpAttributeList = attr_buf.ptr;

    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, cmdline);
    defer gpa.free(cmd_w);

    var shared: Shared = .{
        .gpa = gpa,
        .t0 = now(),
        .out_read = out_read,
        .in_write = in_write,
        .answer_dsr = (flags & 1) != 0,
    };

    // Start the reader BEFORE the child: with INHERIT_CURSOR ConPTY emits
    // its DSR query immediately.
    const reader = try std.Thread.spawn(.{}, readerMain, .{&shared});

    var pi: w.PROCESS_INFORMATION = undefined;
    if (CreateProcessW(null, cmd_w.ptr, null, null, w.TRUE, CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT, null, null, &si.StartupInfo, &pi) == 0) {
        std.debug.print("CreateProcessW failed err={d}\n", .{GetLastError()});
        return error.CreateProcess;
    }
    mark(&shared, "child spawned");

    var resized = false;
    var typed = false;
    while (now() - shared.t0 < run_ms) {
        const t = now() - shared.t0;
        if (!resized and resize_at >= 0 and t >= resize_at) {
            resized = true;
            const rhr = ResizePseudoConsole(hpc, .{ .X = rcols, .Y = rrows });
            var mbuf: [96]u8 = undefined;
            mark(&shared, try std.fmt.bufPrint(&mbuf, "ResizePseudoConsole({d}x{d}) hr=0x{x}", .{ rcols, rrows, @as(u32, @bitCast(rhr)) }));
        }
        if (!typed and input_at >= 0 and t >= input_at and !std.mem.eql(u8, input_text, "-")) {
            typed = true;
            var wr: u32 = 0;
            _ = WriteFile(in_write, input_text.ptr, @intCast(input_text.len), &wr, null);
            mark(&shared, "wrote input text");
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    // Snapshot the report before closing: ClosePseudoConsole can block
    // (documented: it waits until the final frame is drained).
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        const pre_path = try std.fmt.allocPrint(gpa, "{s}.pre.txt", .{out_path});
        defer gpa.free(pre_path);
        try writeReport(gpa, &shared, pre_path, cmdline, cols, rows, flags, run_ms);
    }

    // Kill the client first, then close the pseudoconsole. Closing first
    // with a client that keeps the console alive can block indefinitely.
    mark(&shared, "TerminateProcess(child)");
    _ = TerminateProcess(pi.hProcess, 1);
    _ = WaitForSingleObject(pi.hProcess, 5000);
    mark(&shared, "ClosePseudoConsole");
    ClosePseudoConsole(hpc);
    mark(&shared, "ClosePseudoConsole returned");
    _ = CloseHandle(pi.hProcess);
    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(in_write);
    reader.join();
    _ = CloseHandle(out_read);

    try writeReport(gpa, &shared, out_path, cmdline, cols, rows, flags, run_ms);
}

fn writeReport(
    gpa: std.mem.Allocator,
    shared: *Shared,
    out_path: []const u8,
    cmdline: []const u8,
    cols: i16,
    rows: i16,
    flags: u32,
    run_ms: i64,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    for (shared.chunks.items) |c| try all.appendSlice(gpa, c.data);

    var hdr: [512]u8 = undefined;
    try out.appendSlice(gpa, try std.fmt.bufPrint(&hdr, "cmd: {s}\nsize: {d}x{d} flags: {d} run_ms: {d} total_bytes: {d} chunks: {d} reader_exit_err: {d}\n", .{ cmdline, cols, rows, flags, run_ms, all.items.len, shared.chunks.items.len, shared.read_error }));

    const needles = [_][]const u8{ "\x1b[2J", "\x1b[3J", "\x1b[J", "\x1b[0J", "\x1b[H", "\x1b[1;1H", "\x1b[?25l", "\x1b[?25h", "\x1b[?1049h", "\x1b[6n", "\x1b[?9001h", "\x1b[?1004h", "\x1b]0;", "\x1b[K", "\x1b[m", "\x1b[0m", "\x1b[?2026h", "\x1bc" };
    try out.appendSlice(gpa, "sequence counts (first byte offset):\n");
    for (needles) |n| {
        var count: usize = 0;
        var first: ?usize = null;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, all.items, i, n)) |pos| {
            count += 1;
            if (first == null) first = pos;
            i = pos + n.len;
        }
        try out.appendSlice(gpa, "  ");
        try escapeInto(&out, gpa, n);
        try out.appendSlice(gpa, try std.fmt.bufPrint(&hdr, " = {d}", .{count}));
        if (first) |f| try out.appendSlice(gpa, try std.fmt.bufPrint(&hdr, " (first at byte {d})", .{f}));
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "markers:\n");
    for (shared.markers.items) |m| {
        try out.appendSlice(gpa, try std.fmt.bufPrint(&hdr, "  [+{d:>6}ms] {s}\n", .{ m.t_ms, m.data }));
    }
    try out.appendSlice(gpa, "chunks:\n");
    for (shared.chunks.items) |c| {
        try out.appendSlice(gpa, try std.fmt.bufPrint(&hdr, "[+{d:>6}ms] ({d} bytes) ", .{ c.t_ms, c.data.len }));
        try escapeInto(&out, gpa, c.data);
        try out.append(gpa, '\n');
    }

    const f = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(out.items);
}
