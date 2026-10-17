//! Job object bindings (ARCHITECTURE ADR-3.8 job membership authorization,
//! ADR-3.9 instance and per-tab jobs, spike S4 wrapper jobs).
//!
//! Two layers in one file:
//!
//! - A pure core (flag composition, `ProcThreadAttributeValue`, attribute
//!   list and pid-list buffer sizing, the pid-list growth policy, Win32
//!   error mapping). It uses only `std` and is unit-tested on every OS.
//! - Thin kernel32 wrappers: `Job` (CreateJobObjectW, SetInformationJobObject,
//!   AssignProcessToJobObject, IsProcessInJob, QueryInformationJobObject with
//!   a growable buffer, TerminateJobObject) and `AttributeList` (an owned
//!   PROC_THREAD_ATTRIBUTE_LIST for CreateProcessW with
//!   PROC_THREAD_ATTRIBUTE_JOB_LIST). They are only analyzed when referenced,
//!   so this file compiles for any target; they run only on Windows.
//!
//! Nesting: Windows nests jobs through their processes. A process spawned
//! with a JOB_LIST attribute stays in every job of its parent (unless it
//! breaks away) and joins the listed jobs below them. W1-3 puts the wmux
//! process in the instance job (`Job.assignCurrentProcess`) and spawns each
//! terminal with a per-tab job (`Limits.tab`), so `IsProcessInJob(instance)`
//! holds for every descendant and survives reparenting and PID reuse.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const BOOL = windows.BOOL;

// ─── Constants (winnt.h, winbase.h) ─────────────────────────────────────

pub const JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION: u32 = 0x0400;
pub const JOB_OBJECT_LIMIT_BREAKAWAY_OK: u32 = 0x0800;
pub const JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK: u32 = 0x1000;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;

/// JOBOBJECTINFOCLASS values used here.
pub const JobObjectBasicProcessIdList: u32 = 3;
pub const JobObjectExtendedLimitInformation: u32 = 9;

pub const PROCESS_TERMINATE: u32 = 0x0001;
pub const PROCESS_SET_QUOTA: u32 = 0x0100;
pub const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

pub const CREATE_SUSPENDED: u32 = 0x0000_0004;
pub const CREATE_UNICODE_ENVIRONMENT: u32 = 0x0000_0400;
pub const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;
pub const EXTENDED_STARTUPINFO_PRESENT: u32 = 0x0008_0000;

/// `ProcThreadAttributeValue(Number, Thread, Input, Additive)` (winbase.h).
pub fn procThreadAttributeValue(number: u16, thread: bool, input: bool, additive: bool) usize {
    var v: usize = number;
    if (thread) v |= 0x0001_0000;
    if (input) v |= 0x0002_0000;
    if (additive) v |= 0x0004_0000;
    return v;
}

pub const PROC_THREAD_ATTRIBUTE_HANDLE_LIST = procThreadAttributeValue(2, false, true, false);
pub const PROC_THREAD_ATTRIBUTE_JOB_LIST = procThreadAttributeValue(13, false, true, false);
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = procThreadAttributeValue(22, false, true, false);

// Win32 error codes (winerror.h) that the wrappers distinguish.
pub const ERROR_FILE_NOT_FOUND: u32 = 2;
pub const ERROR_ACCESS_DENIED: u32 = 5;
pub const ERROR_INVALID_HANDLE: u32 = 6;
pub const ERROR_NOT_ENOUGH_MEMORY: u32 = 8;
pub const ERROR_OUTOFMEMORY: u32 = 14;
pub const ERROR_NOT_SUPPORTED: u32 = 50;
pub const ERROR_INVALID_PARAMETER: u32 = 87;
pub const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
pub const ERROR_ALREADY_EXISTS: u32 = 183;
pub const ERROR_MORE_DATA: u32 = 234;

// ─── Pure core ──────────────────────────────────────────────────────────

pub const Error = error{
    /// The handle lacks the needed access right, or a parent job forbids the
    /// operation (e.g. assigning a process that may not break away).
    AccessDenied,
    InvalidHandle,
    InvalidParameter,
    OutOfMemory,
    /// The process exited or the pid does not exist (OpenProcess).
    ProcessNotFound,
    NotSupported,
    Unexpected,
};

/// Raw Win32 error of the most recent failure on this thread (diagnostic
/// only: log it next to the returned error).
pub threadlocal var last_error: u32 = 0;

/// The kernel32 call a Win32 error came from: the same code means
/// different things per call (`errorFromWin32`).
pub const Call = enum {
    create_job,
    set_information,
    query_information,
    assign_process,
    is_process_in_job,
    open_process,
    terminate_job,
    attribute_list,
};

/// Map a Win32 error code (GetLastError) of `call` to `Error`. Only
/// OpenProcess reports a missing pid, as ERROR_INVALID_PARAMETER
/// (`ProcessNotFound`); every other call keeps `InvalidParameter`, and
/// ERROR_FILE_NOT_FOUND is `Unexpected` everywhere (no job call means a
/// missing process by it).
pub fn errorFromWin32(call: Call, code: u32) Error {
    return switch (code) {
        ERROR_ACCESS_DENIED => error.AccessDenied,
        ERROR_INVALID_HANDLE => error.InvalidHandle,
        ERROR_INVALID_PARAMETER => if (call == .open_process) error.ProcessNotFound else error.InvalidParameter,
        ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY => error.OutOfMemory,
        ERROR_NOT_SUPPORTED => error.NotSupported,
        else => error.Unexpected,
    };
}

/// The limits wmux uses. Everything else stays at the system default.
pub const Limits = struct {
    kill_on_job_close: bool = false,
    breakaway_ok: bool = false,
    silent_breakaway_ok: bool = false,
    die_on_unhandled_exception: bool = false,

    /// Per-tab job (ADR-3.9): only BREAKAWAY_OK, never KILL_ON_JOB_CLOSE,
    /// so GUI apps started from a shell survive closing the tab.
    pub const tab: Limits = .{ .breakaway_ok = true };
    /// Instance job (ADR-3.9): membership only; children may break away.
    pub const instance: Limits = .{ .breakaway_ok = true };
    /// Agent wrapper job (spike S4, ADR-10.6): binds only the direct child
    /// (exec emulation); descendants silently stay in the tab job.
    pub const wrapper: Limits = .{ .kill_on_job_close = true, .silent_breakaway_ok = true };

    /// `JOBOBJECT_BASIC_LIMIT_INFORMATION.LimitFlags` for these limits.
    pub fn flags(self: Limits) u32 {
        var f: u32 = 0;
        if (self.kill_on_job_close) f |= JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (self.breakaway_ok) f |= JOB_OBJECT_LIMIT_BREAKAWAY_OK;
        if (self.silent_breakaway_ok) f |= JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        if (self.die_on_unhandled_exception) f |= JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
        return f;
    }

    /// Inverse of `flags`; unknown bits are ignored.
    pub fn fromFlags(f: u32) Limits {
        return .{
            .kill_on_job_close = f & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE != 0,
            .breakaway_ok = f & JOB_OBJECT_LIMIT_BREAKAWAY_OK != 0,
            .silent_breakaway_ok = f & JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK != 0,
            .die_on_unhandled_exception = f & JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION != 0,
        };
    }
};

// ─── Structures (winnt.h) ───────────────────────────────────────────────

pub const LARGE_INTEGER = i64;

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: LARGE_INTEGER = 0,
    PerJobUserTimeLimit: LARGE_INTEGER = 0,
    LimitFlags: u32 = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: u32 = 0,
    Affinity: usize = 0,
    PriorityClass: u32 = 0,
    SchedulingClass: u32 = 0,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

/// Header of the JobObjectBasicProcessIdList result; `ProcessIdList` is a
/// variable-length ULONG_PTR array that starts at `pid_list_header_bytes`.
pub const JOBOBJECT_BASIC_PROCESS_ID_LIST = extern struct {
    NumberOfAssignedProcesses: u32,
    NumberOfProcessIdsInList: u32,
    ProcessIdList: [1]usize,
};

pub const pid_list_header_bytes = @offsetOf(JOBOBJECT_BASIC_PROCESS_ID_LIST, "ProcessIdList");

// ─── Pure buffer policies ───────────────────────────────────────────────

/// First pid-list capacity (entries). A tab rarely has more processes.
pub const pid_list_initial_capacity: usize = 32;
/// Upper bound (entries) so a hostile or broken job cannot make us allocate
/// without limit; far above any real process count.
pub const pid_list_max_capacity: usize = 1 << 20;

/// Words (`usize`) needed for a pid-list buffer holding `capacity` ids. The
/// buffer is a `[]usize` so the ULONG_PTR array is naturally aligned.
pub fn pidListWords(capacity: usize) usize {
    const bytes = pid_list_header_bytes + capacity * @sizeOf(usize);
    return std.math.divCeil(usize, bytes, @sizeOf(usize)) catch unreachable;
}

/// Pid entries that fit in a buffer of `words` words.
pub fn pidListCapacity(words: usize) usize {
    const bytes = words * @sizeOf(usize);
    if (bytes < pid_list_header_bytes) return 0;
    return (bytes - pid_list_header_bytes) / @sizeOf(usize);
}

/// Growth policy after ERROR_MORE_DATA: at least double, and leave headroom
/// over the reported process count because processes can join between two
/// queries. Null once the cap is reached.
pub fn nextPidCapacity(current: usize, assigned: u32) ?usize {
    if (current >= pid_list_max_capacity) return null;
    const a: usize = assigned;
    const wanted = @max(current *| 2, a +| a / 4 +| 8, pid_list_initial_capacity);
    return @min(wanted, pid_list_max_capacity);
}

pub const PidListView = struct {
    /// Processes in the job (may exceed `ids.len` if the buffer was short).
    assigned: u32,
    ids: []const usize,

    /// True when every assigned process is listed.
    pub fn complete(self: PidListView) bool {
        return self.ids.len >= self.assigned;
    }
};

/// Decode a JobObjectBasicProcessIdList buffer. A count larger than the
/// buffer (malformed or truncated input) is clamped to the buffer.
pub fn decodePidList(words: []const usize) PidListView {
    if (words.len * @sizeOf(usize) < pid_list_header_bytes) return .{ .assigned = 0, .ids = &.{} };
    const bytes = std.mem.sliceAsBytes(words);
    const assigned = std.mem.readInt(u32, bytes[0..4], builtin.cpu.arch.endian());
    const in_list = std.mem.readInt(u32, bytes[4..8], builtin.cpu.arch.endian());
    const first = pid_list_header_bytes / @sizeOf(usize);
    const n = @min(@as(usize, in_list), words.len - first);
    return .{ .assigned = assigned, .ids = words[first..][0..n] };
}

/// Copy pids into an owned `[]u32` (process ids are DWORDs; the ULONG_PTR
/// entries never exceed 32 bits). Duplicates are kept as reported.
pub fn pidsToOwned(gpa: std.mem.Allocator, ids: []const usize) error{OutOfMemory}![]u32 {
    const out = try gpa.alloc(u32, ids.len);
    for (ids, out) |id, *o| o.* = @truncate(id);
    return out;
}

/// Words (`usize`) for a PROC_THREAD_ATTRIBUTE_LIST of `bytes` bytes as
/// reported by InitializeProcThreadAttributeList's sizing call.
pub fn attributeListWords(bytes: usize) usize {
    return std.math.divCeil(usize, bytes, @sizeOf(usize)) catch unreachable;
}

/// Value size of a PROC_THREAD_ATTRIBUTE_JOB_LIST entry for `n` jobs.
pub fn jobListBytes(n: usize) usize {
    return n * @sizeOf(HANDLE);
}

// ─── kernel32 ───────────────────────────────────────────────────────────

extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*anyopaque, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetInformationJobObject(hJob: HANDLE, class: u32, info: *const anyopaque, len: u32) callconv(.winapi) BOOL;
extern "kernel32" fn QueryInformationJobObject(hJob: ?HANDLE, class: u32, info: *anyopaque, len: u32, ret_len: ?*u32) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn IsProcessInJob(hProcess: HANDLE, hJob: ?HANDLE, result: *BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateJobObject(hJob: HANDLE, exit_code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, pid: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: u32, flags: u32, size: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(
    list: *anyopaque,
    flags: u32,
    attribute: usize,
    value: *const anyopaque,
    size: usize,
    previous: ?*anyopaque,
    return_size: ?*usize,
) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;

fn lastError(call: Call) Error {
    const code = GetLastError();
    last_error = code;
    return errorFromWin32(call, code);
}

// ─── Job ────────────────────────────────────────────────────────────────

/// An owned job object handle. `deinit` closes it; with KILL_ON_JOB_CLOSE
/// that terminates every process still in the job once no other handle to
/// the job remains.
pub const Job = struct {
    handle: HANDLE,

    /// Create an unnamed job (named jobs would be reachable by other
    /// same-session processes) and apply `limits` when any flag is set.
    pub fn create(limits: Limits) Error!Job {
        const h = CreateJobObjectW(null, null) orelse return lastError(.create_job);
        var job: Job = .{ .handle = h };
        errdefer job.deinit();
        if (limits.flags() != 0) try job.setLimits(limits);
        return job;
    }

    pub fn deinit(self: *Job) void {
        _ = CloseHandle(self.handle);
        self.* = undefined;
    }

    /// SetInformationJobObject(JobObjectExtendedLimitInformation). Replaces
    /// all basic limit flags with `limits`.
    pub fn setLimits(self: Job, limits: Limits) Error!void {
        var info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
        info.BasicLimitInformation.LimitFlags = limits.flags();
        if (SetInformationJobObject(
            self.handle,
            JobObjectExtendedLimitInformation,
            &info,
            @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        ) == 0) return lastError(.set_information);
    }

    /// Current limit flags (QueryInformationJobObject).
    pub fn queryLimits(self: Job) Error!Limits {
        var info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
        if (QueryInformationJobObject(
            self.handle,
            JobObjectExtendedLimitInformation,
            &info,
            @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
            null,
        ) == 0) return lastError(.query_information);
        return Limits.fromFlags(info.BasicLimitInformation.LimitFlags);
    }

    /// AssignProcessToJobObject. `process` needs PROCESS_SET_QUOTA and
    /// PROCESS_TERMINATE. If the process is already in another job, this one
    /// is nested below it (Windows 8+).
    pub fn assign(self: Job, process: HANDLE) Error!void {
        if (AssignProcessToJobObject(self.handle, process) == 0) return lastError(.assign_process);
    }

    /// Put the calling process in this job (the instance job, ADR-3.9).
    pub fn assignCurrentProcess(self: Job) Error!void {
        return self.assign(GetCurrentProcess());
    }

    /// IsProcessInJob(process, this job). Membership includes nested jobs.
    pub fn contains(self: Job, process: HANDLE) Error!bool {
        return isProcessInJob(process, self.handle);
    }

    /// Same as `contains` for a pid (the RPC peer of ADR-3.8).
    pub fn containsPid(self: Job, pid: u32) Error!bool {
        return isPidInJob(pid, self.handle);
    }

    /// Pids of every process in the job, including nested jobs
    /// (JobObjectBasicProcessIdList). Caller frees the slice.
    pub fn processIds(self: Job, gpa: std.mem.Allocator) Error![]u32 {
        return queryProcessIds(gpa, self.handle);
    }

    /// TerminateJobObject: end every process in the job with `exit_code`.
    pub fn terminate(self: Job, exit_code: u32) Error!void {
        if (TerminateJobObject(self.handle, exit_code) == 0) return lastError(.terminate_job);
    }
};

/// IsProcessInJob. `job` null asks whether the process is in any job.
pub fn isProcessInJob(process: HANDLE, job: ?HANDLE) Error!bool {
    var result: BOOL = 0;
    if (IsProcessInJob(process, job, &result) == 0) return lastError(.is_process_in_job);
    return result != 0;
}

/// Open `pid` with PROCESS_QUERY_LIMITED_INFORMATION and ask IsProcessInJob.
/// A pid that no longer exists is `error.ProcessNotFound`.
pub fn isPidInJob(pid: u32, job: ?HANDLE) Error!bool {
    // OpenProcess reports a missing pid as ERROR_INVALID_PARAMETER.
    const process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return lastError(.open_process);
    defer _ = CloseHandle(process);
    return isProcessInJob(process, job);
}

/// QueryInformationJobObject(JobObjectBasicProcessIdList) with a buffer that
/// grows per `nextPidCapacity` until the whole list fits. `job` null queries
/// the job of the calling process.
pub fn queryProcessIds(gpa: std.mem.Allocator, job: ?HANDLE) Error![]u32 {
    var capacity = pid_list_initial_capacity;
    while (true) {
        const words = try gpa.alloc(usize, pidListWords(capacity));
        defer gpa.free(words);
        @memset(words, 0);
        const ok = QueryInformationJobObject(
            job,
            JobObjectBasicProcessIdList,
            words.ptr,
            @intCast(words.len * @sizeOf(usize)),
            null,
        ) != 0;
        if (!ok) {
            const code = GetLastError();
            if (code != ERROR_MORE_DATA) {
                last_error = code;
                return errorFromWin32(.query_information, code);
            }
        }
        const view = decodePidList(words);
        // Success means the kernel wrote every id it had; only
        // ERROR_MORE_DATA grows. (Re-querying on a success whose count
        // races with an exiting process would grow up to the cap and then
        // fail with OutOfMemory.)
        if (ok) return pidsToOwned(gpa, view.ids);
        capacity = nextPidCapacity(capacity, view.assigned) orelse return error.OutOfMemory;
    }
}

// ─── PROC_THREAD_ATTRIBUTE_LIST ─────────────────────────────────────────

/// An owned, initialized PROC_THREAD_ATTRIBUTE_LIST for
/// `STARTUPINFOEXW.lpAttributeList` (with EXTENDED_STARTUPINFO_PRESENT).
///
/// Lifetime rule (Win32): UpdateProcThreadAttribute stores the value
/// *pointer*, not a copy. Every value passed to `update`/`setJobList` must
/// stay valid until CreateProcessW returns.
pub const AttributeList = struct {
    words: []usize,

    /// Size the list for `count` attributes, allocate and initialize it.
    pub fn init(gpa: std.mem.Allocator, count: u32) Error!AttributeList {
        var size: usize = 0;
        // The sizing call fails with ERROR_INSUFFICIENT_BUFFER by design.
        if (InitializeProcThreadAttributeList(null, count, 0, &size) == 0) {
            const code = GetLastError();
            if (code != ERROR_INSUFFICIENT_BUFFER) {
                last_error = code;
                return errorFromWin32(.attribute_list, code);
            }
        }
        if (size == 0) return error.Unexpected;
        const words = try gpa.alloc(usize, attributeListWords(size));
        errdefer gpa.free(words);
        @memset(words, 0);
        var actual = words.len * @sizeOf(usize);
        if (InitializeProcThreadAttributeList(words.ptr, count, 0, &actual) == 0) return lastError(.attribute_list);
        return .{ .words = words };
    }

    pub fn deinit(self: *AttributeList, gpa: std.mem.Allocator) void {
        DeleteProcThreadAttributeList(self.words.ptr);
        gpa.free(self.words);
        self.* = undefined;
    }

    /// The pointer for `STARTUPINFOEXW.lpAttributeList`.
    pub fn ptr(self: AttributeList) *anyopaque {
        return self.words.ptr;
    }

    /// UpdateProcThreadAttribute(attribute, value, size).
    pub fn update(self: AttributeList, attribute: usize, value: *const anyopaque, size: usize) Error!void {
        if (UpdateProcThreadAttribute(self.ptr(), 0, attribute, value, size, null, null) == 0) return lastError(.attribute_list);
    }

    /// PROC_THREAD_ATTRIBUTE_JOB_LIST: the child starts inside `jobs`
    /// (in order, each nested below the previous and below the parent's
    /// jobs). `jobs` must outlive CreateProcessW.
    pub fn setJobList(self: AttributeList, jobs: []const HANDLE) Error!void {
        if (jobs.len == 0) return error.InvalidParameter;
        return self.update(PROC_THREAD_ATTRIBUTE_JOB_LIST, @ptrCast(jobs.ptr), jobListBytes(jobs.len));
    }
};

// ─── Tests (pure core; run on every OS) ─────────────────────────────────

test "unit: platform: job limit flags compose and round-trip" {
    try std.testing.expectEqual(@as(u32, 0), (Limits{}).flags());
    try std.testing.expectEqual(JOB_OBJECT_LIMIT_BREAKAWAY_OK, Limits.tab.flags());
    try std.testing.expectEqual(@as(u32, 0x3000), Limits.wrapper.flags());
    try std.testing.expect(Limits.tab.flags() & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE == 0);
    const all: Limits = .{
        .kill_on_job_close = true,
        .breakaway_ok = true,
        .silent_breakaway_ok = true,
        .die_on_unhandled_exception = true,
    };
    try std.testing.expectEqual(@as(u32, 0x3C00), all.flags());
    try std.testing.expectEqual(all, Limits.fromFlags(all.flags()));
    // Unknown bits are dropped.
    try std.testing.expectEqual(Limits.tab, Limits.fromFlags(0xFFFF_0000 | JOB_OBJECT_LIMIT_BREAKAWAY_OK));
}

test "unit: platform: job ProcThreadAttributeValue matches winbase.h" {
    try std.testing.expectEqual(@as(usize, 0x0002_000D), PROC_THREAD_ATTRIBUTE_JOB_LIST);
    try std.testing.expectEqual(@as(usize, 0x0002_0016), PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE);
    try std.testing.expectEqual(@as(usize, 0x0002_0002), PROC_THREAD_ATTRIBUTE_HANDLE_LIST);
    try std.testing.expectEqual(@as(usize, 0x0007_FFFF), procThreadAttributeValue(0xFFFF, true, true, true));
    try std.testing.expectEqual(@as(usize, 0), procThreadAttributeValue(0, false, false, false));
}

test "unit: platform: job structure layout matches winnt.h" {
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 64), @sizeOf(JOBOBJECT_BASIC_LIMIT_INFORMATION));
        try std.testing.expectEqual(@as(usize, 144), @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        try std.testing.expectEqual(@as(usize, 16), @offsetOf(JOBOBJECT_BASIC_LIMIT_INFORMATION, "LimitFlags"));
    }
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(IO_COUNTERS));
    try std.testing.expectEqual(@as(usize, 8), pid_list_header_bytes);
}

test "unit: platform: job error mapping per call" {
    const t = std.testing;
    inline for (@typeInfo(Call).@"enum".fields) |f| {
        const call: Call = @enumFromInt(f.value);
        try t.expectEqual(error.AccessDenied, errorFromWin32(call, ERROR_ACCESS_DENIED));
        try t.expectEqual(error.InvalidHandle, errorFromWin32(call, ERROR_INVALID_HANDLE));
        try t.expectEqual(error.OutOfMemory, errorFromWin32(call, ERROR_NOT_ENOUGH_MEMORY));
        try t.expectEqual(error.OutOfMemory, errorFromWin32(call, ERROR_OUTOFMEMORY));
        try t.expectEqual(error.NotSupported, errorFromWin32(call, ERROR_NOT_SUPPORTED));
        // No job call reports a missing process as ERROR_FILE_NOT_FOUND.
        try t.expectEqual(error.Unexpected, errorFromWin32(call, ERROR_FILE_NOT_FOUND));
        try t.expectEqual(error.Unexpected, errorFromWin32(call, 0));
        try t.expectEqual(error.Unexpected, errorFromWin32(call, 0xFFFF_FFFF));
        // Only OpenProcess means a missing pid by ERROR_INVALID_PARAMETER.
        const want: Error = if (call == .open_process) error.ProcessNotFound else error.InvalidParameter;
        try t.expectEqual(want, errorFromWin32(call, ERROR_INVALID_PARAMETER));
    }
}

test "unit: platform: job pid-list buffer sizing" {
    try std.testing.expectEqual(@as(usize, 0), pidListCapacity(0));
    try std.testing.expectEqual(@as(usize, 0), pidListCapacity(pidListWords(0)));
    for ([_]usize{ 1, 2, 31, 32, 1000, pid_list_max_capacity }) |cap| {
        try std.testing.expectEqual(cap, pidListCapacity(pidListWords(cap)));
    }
    try std.testing.expectEqual(@as(usize, 0), attributeListWords(0));
    try std.testing.expectEqual(@as(usize, 1), attributeListWords(1));
    try std.testing.expectEqual(@as(usize, 1), attributeListWords(@sizeOf(usize)));
    try std.testing.expectEqual(@as(usize, 2), attributeListWords(@sizeOf(usize) + 1));
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(HANDLE)), jobListBytes(2));
}

test "unit: platform: job pid-list growth policy" {
    // Always grows, at least doubling.
    try std.testing.expectEqual(@as(?usize, 64), nextPidCapacity(32, 0));
    try std.testing.expectEqual(@as(?usize, 64), nextPidCapacity(32, 33));
    // Headroom over a large reported count: 1000 + 250 + 8.
    try std.testing.expectEqual(@as(?usize, 1258), nextPidCapacity(32, 1000));
    // Starting from zero still reaches the initial capacity.
    try std.testing.expectEqual(@as(?usize, pid_list_initial_capacity), nextPidCapacity(0, 0));
    // Huge counts clamp to the cap, and the cap itself stops growth.
    try std.testing.expectEqual(@as(?usize, pid_list_max_capacity), nextPidCapacity(32, std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(?usize, pid_list_max_capacity), nextPidCapacity(pid_list_max_capacity - 1, 0));
    try std.testing.expectEqual(@as(?usize, null), nextPidCapacity(pid_list_max_capacity, 5));
    try std.testing.expectEqual(@as(?usize, null), nextPidCapacity(std.math.maxInt(usize), 0));
    // Terminates: repeated growth reaches null in a bounded number of steps.
    var cap: usize = pid_list_initial_capacity;
    var steps: usize = 0;
    while (nextPidCapacity(cap, std.math.maxInt(u32))) |next| : (steps += 1) {
        try std.testing.expect(next > cap);
        cap = next;
    }
    try std.testing.expect(steps <= 1);
}

fn writeHeader(words: []usize, assigned: u32, in_list: u32) void {
    const bytes = std.mem.sliceAsBytes(words);
    std.mem.writeInt(u32, bytes[0..4], assigned, builtin.cpu.arch.endian());
    std.mem.writeInt(u32, bytes[4..8], in_list, builtin.cpu.arch.endian());
}

test "unit: platform: job pid-list decoding" {
    const gpa = std.testing.allocator;
    // Empty buffer and header-only buffer.
    try std.testing.expectEqual(@as(usize, 0), decodePidList(&.{}).ids.len);
    const words = try gpa.alloc(usize, pidListWords(4));
    defer gpa.free(words);
    @memset(words, 0);
    var view = decodePidList(words);
    try std.testing.expect(view.complete());
    try std.testing.expectEqual(@as(usize, 0), view.ids.len);

    // A complete list.
    const first = pid_list_header_bytes / @sizeOf(usize);
    writeHeader(words, 3, 3);
    words[first + 0] = 4;
    words[first + 1] = 0xFFFF_FFFC;
    words[first + 2] = 1234;
    view = decodePidList(words);
    try std.testing.expect(view.complete());
    const owned = try pidsToOwned(gpa, view.ids);
    defer gpa.free(owned);
    try std.testing.expectEqualSlices(u32, &.{ 4, 0xFFFF_FFFC, 1234 }, owned);

    // Truncated (ERROR_MORE_DATA): more assigned than listed.
    writeHeader(words, 9, 2);
    view = decodePidList(words);
    try std.testing.expect(!view.complete());
    try std.testing.expectEqual(@as(u32, 9), view.assigned);
    try std.testing.expectEqual(@as(usize, 2), view.ids.len);

    // Malformed: the list count exceeds the buffer; clamp, never overread.
    writeHeader(words, 0xFFFF_FFFF, 0xFFFF_FFFF);
    view = decodePidList(words);
    try std.testing.expectEqual(pidListCapacity(words.len), view.ids.len);
    try std.testing.expect(!view.complete());
}
