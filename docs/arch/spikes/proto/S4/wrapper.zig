//! wrapper.exe: prototype of the ADR-10.6 agent wrapper (hardlinked/copied as claude.exe).
//! It resolves the "real" binary on PATH minus itself, launches it in the same console inside a
//! kill-on-close job, survives console control events, waits, and exits with the child's code.
//!
//! Spike-only knobs (environment):
//!   S4_WRAP_CTRL      handler (default) | ignore-before | ignore-after | none
//!   S4_WRAP_JOB       attr (default: PROC_THREAD_ATTRIBUTE_JOB_LIST) | suspend (CREATE_SUSPENDED + Assign) | none
//!   S4_WRAP_JOBFLAGS  kill (default: KILL_ON_JOB_CLOSE) | kill-silent (KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK)
//!   S4_WRAP_HANDLES   list (default: dup'd std handles + PROC_THREAD_ATTRIBUTE_HANDLE_LIST) | inherit
//!   S4_WRAP_SELFSKIP  identity (default: skip PATH hits that are the same file as this exe) | string (skip own dir by name only)
//!   S4_WRAP_CMDSHIM   bypass (default: npm cmd-shim -> program + script directly) | cmd (cmd.exe with BatBadBut-safe quoting) | raw (cmd.exe + verbatim tail; unsafe)
//!   S4_WRAP_REAL      explicit real binary (automation.claudeBinaryPath analog)
//!   S4_WRAP_VERBOSE   1 -> diagnostics on stderr
//! The defaults reproduce ADR-10.6 as written where the spike compared variants; the decision note
//! (docs/arch/spikes/S4-agent-shims.md) recommends handler + attr + kill-silent + list + identity
//! (plus a shim-directory sentinel) + bypass.
const std = @import("std");
const w = @import("w32.zig");

var g_verbose = false;
var g_child: ?w.HANDLE = null;
var g_interrupted = std.atomic.Value(bool).init(false);

fn ctrlHandler(ctrl: w.DWORD) callconv(.winapi) w.BOOL {
    if (g_verbose) w.eprint("WRAPPER got ctrl event {d}\r\n", .{ctrl});
    switch (ctrl) {
        // The console delivers Ctrl+C/Ctrl+Break to every attached process; the child decides.
        // Before the child exists, remember it so the launch is abandoned (as if exec'd and killed).
        w.CTRL_C_EVENT, w.CTRL_BREAK_EVENT => {
            if (g_child == null) g_interrupted.store(true, .release);
            return w.TRUE;
        },
        else => {
            // Close/logoff/shutdown: give the child its own grace period before the job kills it.
            if (g_child) |h| {
                _ = w.WaitForSingleObject(h, 4500);
                var code: w.DWORD = 0xC000013A;
                _ = w.GetExitCodeProcess(h, &code);
                w.ExitProcess(code);
            }
            return w.FALSE;
        },
    }
}

const Kind = enum { exe, cmd, ps1 };

const Real = struct {
    path: []const u16,
    kind: Kind,
};

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    g_verbose = w.getEnv(a, "S4_WRAP_VERBOSE") != null;
    // Default mode installs the handler first thing, so there is no startup window in which a
    // Ctrl+C kills the wrapper but not the (not yet created) child.
    const ctrl_mode0 = w.getEnv(a, "S4_WRAP_CTRL") orelse "handler";
    if (std.mem.eql(u8, ctrl_mode0, "handler")) _ = w.SetConsoleCtrlHandler(ctrlHandler, w.TRUE);

    const self_path = w.modulePath(a);
    const stem = exeStem(self_path);

    // Recursion guard: a wrapper that finds another wrapper copy (or itself) must not loop.
    const depth: u32 = if (w.getEnv(a, "S4_WRAP_DEPTH")) |s| w.parseU32(s) else 0;
    if (depth >= 2) {
        w.eprint("{s}: wrapper recursion detected (depth {d}); refusing to relaunch\r\n", .{ w.toUtf8(a, stem), depth });
        w.ExitProcess(126);
    }
    setEnv(a, "S4_WRAP_DEPTH", std.fmt.allocPrint(a, "{d}", .{depth + 1}) catch unreachable);
    setEnv(a, "S4_WRAPPED_BY", std.fmt.allocPrint(a, "{d}", .{w.GetCurrentProcessId()}) catch unreachable);

    var qpf: i64 = 0;
    var q0: i64 = 0;
    var q1: i64 = 0;
    _ = w.QueryPerformanceFrequency(&qpf);
    _ = w.QueryPerformanceCounter(&q0);
    const real = resolveReal(a, self_path, stem) orelse {
        w.eprint("{s}: real binary not found on PATH (set the agent binary path setting)\r\n", .{w.toUtf8(a, stem)});
        w.ExitProcess(127);
    };
    _ = w.QueryPerformanceCounter(&q1);
    if (g_verbose) w.eprint("WRAPPER resolved in {d} us\r\n", .{@divTrunc((q1 - q0) * 1_000_000, qpf)});

    const tail = skipArgv0(std.mem.span(w.GetCommandLineW()));
    var app: []const u16 = real.path;
    var cmdline: []const u16 = undefined;
    switch (real.kind) {
        .exe => cmdline = join(a, &.{ q(a, real.path), if (tail.len > 0) sp else &.{}, tail }),
        .ps1 => {
            app = findOnPath(a, "pwsh.exe", null) orelse findOnPath(a, "powershell.exe", null) orelse real.path;
            cmdline = join(a, &.{ q(a, app), L(" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "), q(a, real.path), if (tail.len > 0) sp else &.{}, tail });
        },
        .cmd => {
            const mode = w.getEnv(a, "S4_WRAP_CMDSHIM") orelse "bypass";
            var done = false;
            if (std.mem.eql(u8, mode, "bypass")) {
                if (npmShimTarget(a, real.path, self_path)) |t| {
                    app = t.program;
                    cmdline = if (t.script) |s|
                        join(a, &.{ q(a, t.program), sp, q(a, s), if (tail.len > 0) sp else &.{}, tail })
                    else
                        join(a, &.{ q(a, t.program), if (tail.len > 0) sp else &.{}, tail });
                    done = true;
                } else if (g_verbose) w.eprint("WRAPPER npm shim not recognized; falling back to cmd.exe\r\n", .{});
            }
            if (!done) {
                app = w.getEnvW(a, "ComSpec") orelse L("C:\\Windows\\System32\\cmd.exe");
                if (std.mem.eql(u8, mode, "raw")) {
                    cmdline = join(a, &.{ q(a, app), L(" /d /s /c \""), q(a, real.path), if (tail.len > 0) sp else &.{}, tail, L("\"") });
                } else {
                    const args = std.process.argsAlloc(a) catch unreachable;
                    var buf: std.ArrayList(u16) = .empty;
                    buf.appendSlice(a, q(a, app)) catch unreachable;
                    buf.appendSlice(a, L(" /d /e:ON /v:OFF /s /c \"")) catch unreachable;
                    buf.appendSlice(a, q(a, real.path)) catch unreachable;
                    for (args[1..]) |arg| {
                        buf.append(a, ' ') catch unreachable;
                        appendBatchArg(a, &buf, arg) catch {
                            w.eprint("{s}: argument cannot be passed through cmd.exe safely: <{s}>\r\n", .{ w.toUtf8(a, stem), arg });
                            w.ExitProcess(2);
                        };
                    }
                    buf.append(a, '"') catch unreachable;
                    cmdline = buf.items;
                }
            }
        },
    }
    if (g_verbose) {
        w.eprint("WRAPPER self={s}\r\n", .{w.toUtf8(a, self_path)});
        w.eprint("WRAPPER real={s} kind={s}\r\n", .{ w.toUtf8(a, real.path), @tagName(real.kind) });
        w.eprint("WRAPPER app={s}\r\n", .{w.toUtf8(a, app)});
        w.eprint("WRAPPER cmdline={s}\r\n", .{w.toUtf8(a, cmdline)});
    }

    const code = launch(a, app, cmdline);
    if (g_verbose) w.eprint("WRAPPER child exit code {d} (0x{X})\r\n", .{ code, code });
    w.ExitProcess(code);
}

fn launch(a: std.mem.Allocator, app: []const u16, cmdline: []const u16) u32 {
    const ctrl_mode = w.getEnv(a, "S4_WRAP_CTRL") orelse "handler";
    const job_mode = w.getEnv(a, "S4_WRAP_JOB") orelse "attr";
    const job_flags = w.getEnv(a, "S4_WRAP_JOBFLAGS") orelse "kill";
    const handles_mode = w.getEnv(a, "S4_WRAP_HANDLES") orelse "list";

    // ("handler" mode was installed at the top of main)
    if (std.mem.eql(u8, ctrl_mode, "ignore-before")) _ = w.SetConsoleCtrlHandler(null, w.TRUE);

    // Job: kill-on-close emulates exec (the child cannot outlive the wrapper).
    var job: ?w.HANDLE = null;
    if (!std.mem.eql(u8, job_mode, "none")) {
        job = w.CreateJobObjectW(null, null);
        if (job == null) {
            w.eprint("WRAPPER CreateJobObjectW failed err={d}\r\n", .{w.GetLastError()});
        } else {
            var info: w.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
            info.BasicLimitInformation.LimitFlags = w.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if (std.mem.eql(u8, job_flags, "kill-silent"))
                info.BasicLimitInformation.LimitFlags |= w.JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
            if (w.SetInformationJobObject(job.?, w.JobObjectExtendedLimitInformation, &info, @sizeOf(w.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0)
                w.eprint("WRAPPER SetInformationJobObject failed err={d}\r\n", .{w.GetLastError()});
        }
    }

    // Standard handles: duplicate as inheritable and restrict inheritance to exactly these.
    var si: w.STARTUPINFOEXW = .{ .StartupInfo = .{ .cb = @sizeOf(w.STARTUPINFOEXW) }, .lpAttributeList = null };
    var dup: [3]?w.HANDLE = .{ null, null, null };
    var list: [3]w.HANDLE = undefined;
    var nlist: usize = 0;
    const use_list = std.mem.eql(u8, handles_mode, "list");
    if (use_list) {
        const ids = [_]w.DWORD{ w.STD_INPUT_HANDLE, w.STD_OUTPUT_HANDLE, w.STD_ERROR_HANDLE };
        for (ids, 0..) |id, i| {
            const h = w.GetStdHandle(id) orelse continue;
            if (h == w.INVALID_HANDLE_VALUE) continue;
            var d: w.HANDLE = undefined;
            if (w.DuplicateHandle(w.GetCurrentProcess(), h, w.GetCurrentProcess(), &d, 0, w.TRUE, w.DUPLICATE_SAME_ACCESS) == 0) {
                if (g_verbose) w.eprint("WRAPPER DuplicateHandle(std {d}) failed err={d}\r\n", .{ i, w.GetLastError() });
                continue;
            }
            dup[i] = d;
            list[nlist] = d;
            nlist += 1;
        }
        si.StartupInfo.dwFlags |= w.STARTF_USESTDHANDLES;
        si.StartupInfo.hStdInput = dup[0];
        si.StartupInfo.hStdOutput = dup[1];
        si.StartupInfo.hStdError = dup[2];
    }

    const use_job_attr = job != null and std.mem.eql(u8, job_mode, "attr");
    const nattr: w.DWORD = @as(w.DWORD, if (use_job_attr) 1 else 0) + @as(w.DWORD, if (use_list and nlist > 0) 1 else 0);
    var flags: w.DWORD = w.CREATE_UNICODE_ENVIRONMENT;
    var attr_mem: []u8 = &.{};
    if (nattr > 0) {
        var size: usize = 0;
        _ = w.InitializeProcThreadAttributeList(null, nattr, 0, &size);
        attr_mem = a.alignedAlloc(u8, .@"16", size) catch unreachable;
        if (w.InitializeProcThreadAttributeList(attr_mem.ptr, nattr, 0, &size) == 0)
            w.eprint("WRAPPER InitializeProcThreadAttributeList failed err={d}\r\n", .{w.GetLastError()});
        if (use_job_attr) {
            if (w.UpdateProcThreadAttribute(attr_mem.ptr, 0, w.PROC_THREAD_ATTRIBUTE_JOB_LIST, @ptrCast(&job.?), @sizeOf(w.HANDLE), null, null) == 0)
                w.eprint("WRAPPER UpdateProcThreadAttribute(JOB_LIST) failed err={d}\r\n", .{w.GetLastError()});
        }
        if (use_list and nlist > 0) {
            if (w.UpdateProcThreadAttribute(attr_mem.ptr, 0, w.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, @ptrCast(&list), nlist * @sizeOf(w.HANDLE), null, null) == 0)
                w.eprint("WRAPPER UpdateProcThreadAttribute(HANDLE_LIST) failed err={d}\r\n", .{w.GetLastError()});
        }
        si.lpAttributeList = attr_mem.ptr;
        flags |= w.EXTENDED_STARTUPINFO_PRESENT;
    }
    const suspend_assign = job != null and std.mem.eql(u8, job_mode, "suspend");
    if (suspend_assign) flags |= w.CREATE_SUSPENDED;

    const app_z = a.dupeZ(u16, app) catch unreachable;
    const cmd_z = a.dupeZ(u16, cmdline) catch unreachable;
    var pi: w.PROCESS_INFORMATION = undefined;
    if (g_interrupted.load(.acquire)) {
        if (g_verbose) w.eprint("WRAPPER interrupted before launch\r\n", .{});
        return 0xC000013A; // STATUS_CONTROL_C_EXIT, what the agent itself would have returned
    }
    const t0 = w.GetTickCount64();
    if (w.CreateProcessW(app_z.ptr, cmd_z.ptr, null, null, w.TRUE, flags, null, null, &si.StartupInfo, &pi) == 0) {
        const err = w.GetLastError();
        w.eprint("WRAPPER CreateProcessW failed err={d}\r\n", .{err});
        return 0x80000000 | err;
    }
    for (dup) |d| if (d) |h| {
        _ = w.CloseHandle(h);
    };
    if (nattr > 0) w.DeleteProcThreadAttributeList(attr_mem.ptr);
    g_child = pi.hProcess;
    if (suspend_assign) {
        if (w.AssignProcessToJobObject(job.?, pi.hProcess) == 0)
            w.eprint("WRAPPER AssignProcessToJobObject failed err={d}\r\n", .{w.GetLastError()});
    }
    if (std.mem.eql(u8, ctrl_mode, "ignore-after")) _ = w.SetConsoleCtrlHandler(null, w.TRUE);
    if (suspend_assign) _ = w.ResumeThread(pi.hThread);
    _ = w.CloseHandle(pi.hThread);
    if (g_verbose) {
        var in_job: w.BOOL = 0;
        if (job) |j| _ = w.IsProcessInJob(pi.hProcess, j, &in_job);
        w.eprint("WRAPPER spawned pid={d} in {d} ms; in wrapper job={d}\r\n", .{ pi.dwProcessId, w.GetTickCount64() - t0, in_job });
    }

    _ = w.WaitForSingleObject(pi.hProcess, w.INFINITE);
    var code: w.DWORD = 0;
    _ = w.GetExitCodeProcess(pi.hProcess, &code);
    return code;
}

// ------------------------------------------------------------- resolution

fn exeStem(path: []const u16) []const u16 {
    var start: usize = 0;
    for (path, 0..) |c, i| if (c == '\\' or c == '/') {
        start = i + 1;
    };
    const base = path[start..];
    var end = base.len;
    var i = base.len;
    while (i > 0) : (i -= 1) if (base[i - 1] == '.') {
        end = i - 1;
        break;
    };
    return base[0..end];
}

fn dirOf(path: []const u16) []const u16 {
    var i = path.len;
    while (i > 0) : (i -= 1) if (path[i - 1] == '\\' or path[i - 1] == '/') return path[0 .. i - 1];
    return path[0..0];
}

const FileId = struct { vol: u32, hi: u32, lo: u32 };

fn fileId(a: std.mem.Allocator, path: []const u16) ?FileId {
    const z = a.dupeZ(u16, path) catch return null;
    const h = w.CreateFileW(z.ptr, 0, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, null, w.OPEN_EXISTING, w.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h == w.INVALID_HANDLE_VALUE) return null;
    defer _ = w.CloseHandle(h);
    var info: w.BY_HANDLE_FILE_INFORMATION = undefined;
    if (w.GetFileInformationByHandle(h, &info) == 0) return null;
    return .{ .vol = info.dwVolumeSerialNumber, .hi = info.nFileIndexHigh, .lo = info.nFileIndexLow };
}

fn isFile(a: std.mem.Allocator, path: []const u16) bool {
    const z = a.dupeZ(u16, path) catch return false;
    const attr = w.GetFileAttributesW(z.ptr);
    return attr != w.INVALID_FILE_ATTRIBUTES and (attr & w.FILE_ATTRIBUTE_DIRECTORY) == 0;
}

fn fullPath(a: std.mem.Allocator, path: []const u16) []const u16 {
    const z = a.dupeZ(u16, path) catch return path;
    var buf: [32768]u16 = undefined;
    const n = w.GetFullPathNameW(z.ptr, buf.len, &buf, null);
    if (n == 0 or n >= buf.len) return path;
    var out = buf[0..n];
    while (out.len > 3 and (out[out.len - 1] == '\\' or out[out.len - 1] == '/')) out = out[0 .. out.len - 1];
    return a.dupe(u16, out) catch path;
}

fn eqlIgnoreCaseW(x: []const u16, y: []const u16) bool {
    if (x.len != y.len) return false;
    for (x, y) |c1, c2| {
        const l1 = if (c1 >= 'A' and c1 <= 'Z') c1 + 32 else c1;
        const l2 = if (c2 >= 'A' and c2 <= 'Z') c2 + 32 else c2;
        if (l1 != l2) return false;
    }
    return true;
}

/// Directory-first, then extension order (.exe preferred), like cmd.exe's search but never
/// returning this executable (by file identity, which also catches 8.3 names, hardlinks and
/// duplicate PATH spellings).
fn resolveReal(a: std.mem.Allocator, self_path: []const u16, stem: []const u16) ?Real {
    if (w.getEnvW(a, "S4_WRAP_REAL")) |p| return .{ .path = p, .kind = kindOf(p) };
    const self_id = fileId(a, self_path);
    const self_dir = fullPath(a, dirOf(self_path));
    const by_string = if (w.getEnv(a, "S4_WRAP_SELFSKIP")) |m| std.mem.eql(u8, m, "string") else false;
    const path_env = w.getEnvW(a, "PATH") orelse return null;
    const exts = [_][]const u16{ L(".exe"), L(".com"), L(".cmd"), L(".bat"), L(".ps1") };
    var it = std.mem.tokenizeScalar(u16, path_env, ';');
    while (it.next()) |raw_entry| {
        var entry = raw_entry;
        if (entry.len >= 2 and entry[0] == '"' and entry[entry.len - 1] == '"') entry = entry[1 .. entry.len - 1];
        if (entry.len == 0) continue;
        const dir = fullPath(a, entry);
        if (eqlIgnoreCaseW(dir, self_dir)) {
            if (g_verbose) w.eprint("WRAPPER skip own dir (string match): {s}\r\n", .{w.toUtf8(a, dir)});
            continue;
        }
        for (exts) |ext| {
            const cand = join(a, &.{ dir, L("\\"), stem, ext });
            if (!isFile(a, cand)) continue;
            if (!by_string) {
                if (self_id) |sid| if (fileId(a, cand)) |cid| if (sid.vol == cid.vol and sid.hi == cid.hi and sid.lo == cid.lo) {
                    if (g_verbose) w.eprint("WRAPPER skip self (same file id): {s}\r\n", .{w.toUtf8(a, cand)});
                    continue;
                };
            }
            return .{ .path = cand, .kind = kindOf(cand) };
        }
    }
    return null;
}

fn kindOf(p: []const u16) Kind {
    if (p.len >= 4) {
        const ext = p[p.len - 4 ..];
        if (eqlIgnoreCaseW(ext, L(".cmd")) or eqlIgnoreCaseW(ext, L(".bat"))) return .cmd;
        if (eqlIgnoreCaseW(ext, L(".ps1"))) return .ps1;
    }
    return .exe;
}

fn findOnPath(a: std.mem.Allocator, comptime name: []const u8, skip_dir: ?[]const u16) ?[]const u16 {
    const path_env = w.getEnvW(a, "PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u16, path_env, ';');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const dir = fullPath(a, entry);
        if (skip_dir) |s| if (eqlIgnoreCaseW(dir, s)) continue;
        const cand = join(a, &.{ dir, L("\\" ++ name) });
        if (isFile(a, cand)) return cand;
    }
    return null;
}

const ShimTarget = struct { program: []const u16, script: ?[]const u16 };

/// Recognizes npm cmd-shim output ("%dp0%\<relative target>" ... %*) and returns the program
/// to launch directly (node.exe next to the shim, else node.exe on PATH) plus the script.
fn npmShimTarget(a: std.mem.Allocator, shim: []const u16, self_path: []const u16) ?ShimTarget {
    const shim8 = w.toUtf8(a, shim);
    const file = std.fs.openFileAbsolute(shim8, .{}) catch return null;
    defer file.close();
    var buf: [65536]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const text = buf[0..n];
    const marker = "\"%dp0%\\";
    const at = std.mem.lastIndexOf(u8, text, marker) orelse return null;
    const rest = text[at + marker.len ..];
    const close = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const rel = rest[0..close];
    if (std.mem.indexOf(u8, text[at..], "%*") == null) return null;
    const dir = dirOf(shim);
    const target = join(a, &.{ dir, L("\\"), w.toUtf16Z(a, rel) });
    if (!isFile(a, target)) return null;
    if (kindOf(target) == .exe and !std.ascii.endsWithIgnoreCase(rel, ".js") and !std.ascii.endsWithIgnoreCase(rel, ".mjs") and !std.ascii.endsWithIgnoreCase(rel, ".cjs"))
        return .{ .program = target, .script = null };
    const local_node = join(a, &.{ dir, L("\\node.exe") });
    const node = if (isFile(a, local_node)) local_node else (findOnPath(a, "node.exe", fullPath(a, dirOf(self_path))) orelse return null);
    return .{ .program = node, .script = target };
}

// ------------------------------------------------------------- quoting

const sp: []const u16 = L(" ");

fn L(comptime s: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn join(a: std.mem.Allocator, parts: []const []const u16) []u16 {
    return std.mem.concat(a, u16, parts) catch unreachable;
}

/// Quotes an executable path for the first command-line token (paths cannot contain '"').
fn q(a: std.mem.Allocator, s: []const u16) []u16 {
    return join(a, &.{ L("\""), s, L("\"") });
}

/// argv[0] ends at the first unquoted space/tab; quotes toggle (UCRT rule, no escapes).
fn skipArgv0(cl: []const u16) []const u16 {
    var i: usize = 0;
    var inq = false;
    while (i < cl.len) : (i += 1) {
        const c = cl[i];
        if (c == '"') {
            inq = !inq;
        } else if (!inq and (c == ' ' or c == '\t')) break;
    }
    while (i < cl.len and (cl[i] == ' ' or cl[i] == '\t')) i += 1;
    return cl[i..];
}

/// One argument for `cmd.exe /d /e:ON /v:OFF /s /c ""x.cmd" args"` whose script forwards %*
/// to a UCRT-parsed program. Always quoted, so cmd's quote state stays balanced and & | < > ^ ( )
/// stay literal; '"' becomes '""' (keeps cmd balanced, UCRT reads a literal quote); backslashes
/// before a quote or the closing quote are doubled; '%' becomes '%%cd:~,%' so cmd's command-line
/// percent expansion yields a literal '%'. CR/LF/NUL cannot cross cmd.exe and are rejected.
fn appendBatchArg(a: std.mem.Allocator, out: *std.ArrayList(u16), arg8: []const u8) !void {
    const arg = std.unicode.utf8ToUtf16LeAlloc(a, arg8) catch return error.Bad;
    for (arg) |c| if (c == '\r' or c == '\n' or c == 0) return error.Bad;
    try out.append(a, '"');
    var bs: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            bs += 1;
            continue;
        }
        if (c == '"') {
            try out.appendNTimes(a, '\\', bs * 2);
            try out.appendSlice(a, L("\"\""));
        } else {
            try out.appendNTimes(a, '\\', bs);
            if (c == '%') try out.appendSlice(a, L("%%cd:~,%")) else try out.append(a, c);
        }
        bs = 0;
    }
    try out.appendNTimes(a, '\\', bs * 2);
    try out.append(a, '"');
}

fn setEnv(a: std.mem.Allocator, comptime name: []const u8, value: []const u8) void {
    const wv = w.toUtf16Z(a, value);
    _ = w.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), wv.ptr);
}
