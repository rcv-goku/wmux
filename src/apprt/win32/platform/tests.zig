//! Tests for the platform bindings job.zig, dpapi.zig and shell.zig
//! (WP PB-platform).
//!
//! Windows (pure core + live Win32 tests; run from the repo root, about 5 s):
//!   zig test -target x86_64-windows-gnu -lc -lcrypt32 -lshell32 -lole32 -lshlwapi src/apprt/win32/platform/tests.zig
//! Any other OS (pure core; the live tests skip):
//!   zig test src/apprt/win32/platform/tests.zig
//!
//! The live tests only start `cmd.exe` with CREATE_NO_WINDOW (suspended
//! until the job checks ran), never show a window, never change focus,
//! touch no network beyond `ping 127.0.0.1`, write no files, and terminate
//! every child they start even when an assertion fails. They never call
//! `shell.shellExecute` or `shell.revealInExplorer` (both visible).
const std = @import("std");
const builtin = @import("builtin");

const job = @import("job.zig");
const dpapi = @import("dpapi.zig");
const shell = @import("shell.zig");

test {
    _ = job;
    _ = dpapi;
    _ = shell;
}

test "unit: platform: (windows) every wrapper type-checks" {
    if (!is_windows) return error.SkipZigTest;
    // Reference without calling: forces analysis of wrappers no test runs
    // (shellExecute and revealInExplorer would open visible windows).
    std.testing.refAllDecls(job);
    std.testing.refAllDecls(job.Job);
    std.testing.refAllDecls(job.AttributeList);
    std.testing.refAllDecls(dpapi);
    std.testing.refAllDecls(shell);
}

const is_windows = builtin.os.tag == .windows;
const HANDLE = job.HANDLE;
const BOOL = job.BOOL;

// ─── Child process helper (Windows) ─────────────────────────────────────

const STARTUPINFOW = extern struct {
    cb: u32 = @sizeOf(STARTUPINFOW),
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW = .{ .cb = @sizeOf(STARTUPINFOEXW) },
    lpAttributeList: ?*anyopaque = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

extern "kernel32" fn CreateProcessW(
    app: ?[*:0]const u16,
    cmdline: ?[*:0]u16,
    process_attrs: ?*anyopaque,
    thread_attrs: ?*anyopaque,
    inherit: BOOL,
    flags: u32,
    env: ?*anyopaque,
    cwd: ?[*:0]const u16,
    startup: *STARTUPINFOW,
    info: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn ResumeThread(thread: HANDLE) callconv(.winapi) u32;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(process: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 258;
const STILL_ACTIVE: u32 = 259;

const Child = struct {
    process: HANDLE,
    thread: HANDLE,
    pid: u32,

    /// Start `cmdline` hidden and suspended, inside `jobs` when given
    /// (PROC_THREAD_ATTRIBUTE_JOB_LIST).
    fn spawn(gpa: std.mem.Allocator, cmdline: []const u8, jobs: ?[]const HANDLE) !Child {
        const cmd = try shell.toWideZ(gpa, cmdline);
        defer gpa.free(cmd);
        var attrs: ?job.AttributeList = null;
        defer if (attrs) |*a| a.deinit(gpa);
        var si: STARTUPINFOEXW = .{};
        var flags = job.CREATE_NO_WINDOW | job.CREATE_SUSPENDED;
        if (jobs) |list| {
            attrs = try job.AttributeList.init(gpa, 1);
            try attrs.?.setJobList(list);
            si.lpAttributeList = attrs.?.ptr();
            flags |= job.EXTENDED_STARTUPINFO_PRESENT;
        } else {
            si.StartupInfo.cb = @sizeOf(STARTUPINFOW);
        }
        var pi: PROCESS_INFORMATION = undefined;
        if (CreateProcessW(null, cmd.ptr, null, null, 0, flags, null, null, &si.StartupInfo, &pi) == 0)
            return error.CreateProcessFailed;
        return .{ .process = pi.hProcess, .thread = pi.hThread, .pid = pi.dwProcessId };
    }

    fn resumeMain(self: Child) !void {
        if (ResumeThread(self.thread) == std.math.maxInt(u32)) return error.ResumeFailed;
    }

    /// Exit code, or error.Timeout if still running after `ms`.
    fn wait(self: Child, ms: u32) !u32 {
        switch (WaitForSingleObject(self.process, ms)) {
            WAIT_OBJECT_0 => {},
            WAIT_TIMEOUT => return error.Timeout,
            else => return error.WaitFailed,
        }
        var code: u32 = 0;
        if (GetExitCodeProcess(self.process, &code) == 0) return error.WaitFailed;
        return code;
    }

    /// Terminate if still running, then close both handles.
    fn deinit(self: *Child) void {
        var code: u32 = 0;
        if (GetExitCodeProcess(self.process, &code) != 0 and code == STILL_ACTIVE) {
            _ = TerminateProcess(self.process, 1);
            _ = WaitForSingleObject(self.process, 5000);
        }
        _ = CloseHandle(self.thread);
        _ = CloseHandle(self.process);
        self.* = undefined;
    }
};

fn containsPid(pids: []const u32, pid: u32) bool {
    return std.mem.indexOfScalar(u32, pids, pid) != null;
}

/// `"%SystemRoot%\System32\cmd.exe" /c <args>` (absolute, so the current
/// directory is never searched). Caller frees.
fn cmdLine(gpa: std.mem.Allocator, args: []const u8) ![]u8 {
    const root = std.process.getEnvVarOwned(gpa, "SystemRoot") catch try gpa.dupe(u8, "C:\\Windows");
    defer gpa.free(root);
    return std.fmt.allocPrint(gpa, "\"{s}\\System32\\cmd.exe\" /c {s}", .{ root, args });
}

// ─── job.zig (Windows) ──────────────────────────────────────────────────

test "unit: platform: job (windows) JOB_LIST spawn is in the job and lists its pid" {
    if (!is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var j = try job.Job.create(job.Limits.tab);
    defer j.deinit();
    try std.testing.expectEqual(job.Limits.tab, try j.queryLimits());

    const cmd = try cmdLine(gpa, "exit 7");
    defer gpa.free(cmd);
    var child = try Child.spawn(gpa, cmd, &.{j.handle});
    defer child.deinit();

    try std.testing.expect(try j.contains(child.process));
    try std.testing.expect(try j.containsPid(child.pid));
    try std.testing.expect(try job.isProcessInJob(child.process, null));
    const pids = try j.processIds(gpa);
    defer gpa.free(pids);
    try std.testing.expectEqual(@as(usize, 1), pids.len);
    try std.testing.expectEqual(child.pid, pids[0]);

    try child.resumeMain();
    try std.testing.expectEqual(@as(u32, 7), try child.wait(10_000));
}

test "unit: platform: job (windows) AssignProcessToJobObject" {
    if (!is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var j = try job.Job.create(job.Limits.tab);
    defer j.deinit();

    const cmd = try cmdLine(gpa, "exit 7");
    defer gpa.free(cmd);
    var child = try Child.spawn(gpa, cmd, null);
    defer child.deinit();

    try std.testing.expect(!try j.contains(child.process));
    const before = try j.processIds(gpa);
    defer gpa.free(before);
    try std.testing.expectEqual(@as(usize, 0), before.len);

    try j.assign(child.process);
    try std.testing.expect(try j.contains(child.process));
    const pids = try j.processIds(gpa);
    defer gpa.free(pids);
    try std.testing.expect(containsPid(pids, child.pid));

    try child.resumeMain();
    try std.testing.expectEqual(@as(u32, 7), try child.wait(10_000));
}

test "unit: platform: job (windows) nested tab job under an instance job" {
    if (!is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var outer = try job.Job.create(job.Limits.instance);
    defer outer.deinit();
    var inner = try job.Job.create(job.Limits.tab);
    defer inner.deinit();
    var other = try job.Job.create(.{});
    defer other.deinit();

    const cmd = try cmdLine(gpa, "exit 7");
    defer gpa.free(cmd);
    var child = try Child.spawn(gpa, cmd, &.{outer.handle});
    defer child.deinit();
    // Assigning a process that is already in a job nests the new job.
    try inner.assign(child.process);

    try std.testing.expect(try outer.contains(child.process));
    try std.testing.expect(try inner.contains(child.process));
    try std.testing.expect(!try other.contains(child.process));
    const outer_pids = try outer.processIds(gpa);
    defer gpa.free(outer_pids);
    try std.testing.expect(containsPid(outer_pids, child.pid));
    const inner_pids = try inner.processIds(gpa);
    defer gpa.free(inner_pids);
    try std.testing.expect(containsPid(inner_pids, child.pid));

    try child.resumeMain();
    try std.testing.expectEqual(@as(u32, 7), try child.wait(10_000));
}

test "unit: platform: job (windows) kill-on-close terminates a long-running child" {
    if (!is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    // Plain KILL_ON_JOB_CLOSE (not Limits.wrapper): with SILENT_BREAKAWAY_OK
    // the ping grandchild would leave the job and outlive the test.
    const limits: job.Limits = .{ .kill_on_job_close = true };
    var j = try job.Job.create(limits);
    var job_open = true;
    defer if (job_open) j.deinit();
    try std.testing.expectEqual(limits, try j.queryLimits());

    const cmd = try cmdLine(gpa, "ping -n 30 127.0.0.1 >nul");
    defer gpa.free(cmd);
    var child = try Child.spawn(gpa, cmd, &.{j.handle});
    defer child.deinit();
    try child.resumeMain();
    try std.testing.expectError(error.Timeout, child.wait(300));

    // Closing the last job handle kills cmd (and ping inside the job).
    j.deinit();
    job_open = false;
    _ = try child.wait(10_000);
}

test "unit: platform: job (windows) attribute list and pid errors" {
    if (!is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var list = try job.AttributeList.init(gpa, 2);
    defer list.deinit(gpa);
    try std.testing.expectError(error.InvalidParameter, list.setJobList(&.{}));
    var j = try job.Job.create(.{});
    defer j.deinit();
    const handles = [_]HANDLE{j.handle};
    try list.setJobList(&handles);
    // Pids are multiples of 4; this one never exists.
    try std.testing.expectError(error.ProcessNotFound, job.isPidInJob(0xFFFF_FFF3, j.handle));
}

// ─── dpapi.zig (Windows) ────────────────────────────────────────────────

test "unit: platform: dpapi (windows) round trip without entropy" {
    if (!is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const plain = "wmux socket password \xe2\x9c\x93";
    const sealed = try dpapi.protect(gpa, plain, null);
    defer gpa.free(sealed);
    try std.testing.expect(sealed.len > plain.len);
    try std.testing.expect(std.mem.indexOf(u8, sealed, plain) == null);
    const opened = try dpapi.unprotect(gpa, sealed, null);
    defer dpapi.freeSecret(gpa, opened);
    try std.testing.expectEqualStrings(plain, opened);

    // Empty plaintext round-trips too.
    const sealed_empty = try dpapi.protect(gpa, "", null);
    defer gpa.free(sealed_empty);
    const opened_empty = try dpapi.unprotect(gpa, sealed_empty, null);
    defer dpapi.freeSecret(gpa, opened_empty);
    try std.testing.expectEqual(@as(usize, 0), opened_empty.len);
}

test "unit: platform: dpapi (windows) round trip with entropy" {
    if (!is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var secret: [32]u8 = undefined;
    std.crypto.random.bytes(&secret);
    const entropy = "wmux-cap-v1|test";
    const sealed = try dpapi.protect(gpa, &secret, entropy);
    defer gpa.free(sealed);
    const opened = try dpapi.unprotect(gpa, sealed, entropy);
    defer dpapi.freeSecret(gpa, opened);
    try std.testing.expectEqualSlices(u8, &secret, opened);

    // Wrong or missing entropy fails.
    try std.testing.expectError(error.InvalidData, dpapi.unprotect(gpa, sealed, "wmux-cap-v1|other"));
    try std.testing.expectError(error.InvalidData, dpapi.unprotect(gpa, sealed, null));
}

test "unit: platform: dpapi (windows) tampered or truncated ciphertext is rejected" {
    if (!is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const sealed = try dpapi.protect(gpa, "secret", null);
    defer gpa.free(sealed);
    const copy = try gpa.dupe(u8, sealed);
    defer gpa.free(copy);

    // Flip one bit in the payload (the tail holds the encrypted data and
    // its HMAC).
    copy[copy.len - 10] ^= 0x01;
    if (dpapi.unprotect(gpa, copy, null)) |p| {
        dpapi.freeSecret(gpa, p);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expect(err == error.InvalidData or err == error.InvalidParameter);

    // Truncated and garbage input.
    if (dpapi.unprotect(gpa, sealed[0 .. sealed.len / 2], null)) |p| {
        dpapi.freeSecret(gpa, p);
        return error.TestUnexpectedResult;
    } else |_| {}
    if (dpapi.unprotect(gpa, "not a dpapi blob", null)) |p| {
        dpapi.freeSecret(gpa, p);
        return error.TestUnexpectedResult;
    } else |_| {}
}

// ─── shell.zig (Windows) ────────────────────────────────────────────────

test "unit: platform: shell (windows) known folders are existing absolute paths" {
    if (!is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    for ([_]shell.KnownFolder{ .local_app_data, .roaming_app_data, .profile }) |folder| {
        const path = try shell.knownFolderPath(gpa, folder);
        defer gpa.free(path);
        try std.testing.expect(path.len > 3);
        try std.testing.expect(std.fs.path.isAbsoluteWindows(path));
        var dir = try std.fs.openDirAbsolute(path, .{});
        dir.close();
    }
}

test "unit: platform: shell (windows) AssocQueryStringW finds the .txt handler" {
    if (!is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const exe = try shell.assocQueryString(gpa, .executable, ".txt", null);
    defer gpa.free(exe);
    try std.testing.expect(exe.len > 0);
    const open_cmd = try shell.assocQueryString(gpa, .command, ".txt", "open");
    defer gpa.free(open_cmd);
    try std.testing.expect(open_cmd.len > 0);

    // An unregistered extension has no association.
    if (shell.assocQueryString(gpa, .executable, ".wmux-test-no-such-ext-7f3a", null)) |s| {
        gpa.free(s);
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectError(error.InvalidPath, shell.assocQueryString(gpa, .executable, "", null));
}
