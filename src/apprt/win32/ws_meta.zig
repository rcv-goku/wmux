//! Stage 2 sidebar workspace metadata: off-UI-thread population of each
//! workspace's git branch, listening TCP ports, and PR status.
//!
//! THREADING: every function here runs on a worker thread spawned per
//! refresh tick (App.refreshWorkspaceMetadata). It NEVER touches Window /
//! App / HWND / GDI state — it is handed a self-contained, owned `Job`
//! (working_dir string + root child PIDs captured on the UI thread) and
//! produces an owned `Result` that the UI thread applies after a
//! PostMessageW hop. The pure parsing/merging helpers are factored out so
//! the wire-free logic is unit tested without spawning git or opening the
//! TCP table.
//!
//! All work is best-effort: a missing git/gh, an absent repo, or a TCP
//! table error leaves the corresponding field empty rather than erroring.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Window = @import("Window.zig");
const PrState = Window.PrState;

const log = std.log.scoped(.win32);

/// A self-contained refresh request for one workspace, built on the UI
/// thread and owned by the worker thread (which frees it). The worker may
/// not dereference `window`/anything live — it is an opaque token echoed
/// back in the Result purely so the UI thread can re-locate the workspace
/// (validated by pointer + index + meta_token before applying).
pub const Job = struct {
    /// Opaque back-pointer to the *Window, validated on the UI thread.
    window: *anyopaque,
    /// Workspace index within that window at dispatch time.
    ws_idx: usize,
    /// Token stamped on the workspace at dispatch; the result applies only
    /// if it still matches (guards against a recycled slot).
    token: u64,
    /// Owned copy of the workspace's working_dir, or null when unbound
    /// (no git/gh work; ports may still be probed if pids is non-empty).
    working_dir: ?[]u8,
    /// Owned list of root child PIDs (one per tab's ConPTY child) whose
    /// process trees are scanned for listening ports.
    root_pids: []u32,
    /// Whether to run `gh pr view` (network; gated to a slower cadence by
    /// the dispatcher).
    want_pr: bool,

    pub fn deinit(self: *Job, alloc: Allocator) void {
        if (self.working_dir) |d| alloc.free(d);
        alloc.free(self.root_pids);
    }
};

/// The computed metadata for one workspace, posted back to the UI thread
/// (heap-allocated, ownership transferred via PostMessageW lParam). The UI
/// handler applies it (after revalidation) and frees it.
pub const Result = struct {
    window: *anyopaque,
    ws_idx: usize,
    token: u64,
    /// Branch name (empty when unknown / not a worktree). Inline buffer so
    /// the apply path on the UI thread never allocates.
    branch: [Window.MAX_BRANCH_BYTES]u8 = undefined,
    branch_len: u8 = 0,
    ports: [Window.MAX_PORTS]u16 = undefined,
    port_count: u8 = 0,
    pr_state: PrState = .none,
    pr_number: u32 = 0,
    /// Whether the gh probe ran at all; when false the UI keeps the prior
    /// PR cache instead of clearing it (so the slow-cadence gh refresh
    /// doesn't blank the marker on every fast tick).
    pr_probed: bool = false,

    pub fn setBranch(self: *Result, branch: []const u8) void {
        const n: u8 = @intCast(@min(branch.len, Window.MAX_BRANCH_BYTES));
        @memcpy(self.branch[0..n], branch[0..n]);
        self.branch_len = n;
    }

    pub fn setPorts(self: *Result, src: []const u16) void {
        const n: u8 = @intCast(@min(src.len, Window.MAX_PORTS));
        @memcpy(self.ports[0..n], src[0..n]);
        self.port_count = n;
    }
};

/// Run one job to completion on the worker thread and return an owned
/// Result. Never errors: every step degrades to an empty field.
pub fn run(alloc: Allocator, job: *const Job) !*Result {
    const result = try alloc.create(Result);
    result.* = .{ .window = job.window, .ws_idx = job.ws_idx, .token = job.token };

    if (job.working_dir) |dir| {
        if (gitBranch(alloc, dir)) |branch| {
            defer alloc.free(branch);
            result.setBranch(branch);
        }
        if (job.want_pr) {
            result.pr_probed = true;
            if (ghPrStatus(alloc, dir)) |pr| {
                result.pr_state = pr.state;
                result.pr_number = pr.number;
            }
        }
    }

    if (job.root_pids.len > 0) {
        const ports = collectListeningPorts(alloc, job.root_pids) catch &[_]u16{};
        defer if (ports.len > 0) alloc.free(ports);
        result.setPorts(ports);
    }

    return result;
}

// ---------------------------------------------------------------------------
// git branch
// ---------------------------------------------------------------------------

/// `git -C <dir> rev-parse --abbrev-ref HEAD` → the branch name (owned), or
/// null on any failure (no git, not a repo, detached HEAD reports "HEAD").
fn gitBranch(alloc: Allocator, dir: []const u8) ?[]u8 {
    const out = runCapture(alloc, &.{ "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" }) orelse return null;
    defer alloc.free(out);
    const trimmed = parseBranch(out) orelse return null;
    return alloc.dupe(u8, trimmed) catch null;
}

/// Pure: trim git's rev-parse output to a usable branch name, or null when
/// empty. (Detached HEAD prints "HEAD"; we keep it — the row then shows
/// "HEAD", a truthful "detached" hint — but an empty line is dropped.)
pub fn parseBranch(raw: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (t.len == 0) return null;
    return t;
}

// ---------------------------------------------------------------------------
// gh PR status
// ---------------------------------------------------------------------------

const PrInfo = struct { state: PrState, number: u32 };

/// `gh pr view --json number,state,isDraft` in `dir` → the PR state, or
/// null when gh is absent, unauthenticated, or no PR exists for the branch.
fn ghPrStatus(alloc: Allocator, dir: []const u8) ?PrInfo {
    // gh respects -C? No: gh has no -C. Run it with cwd set to dir.
    const out = runCaptureCwd(alloc, &.{ "gh", "pr", "view", "--json", "number,state,isDraft" }, dir) orelse return null;
    defer alloc.free(out);
    return parseGhPr(out);
}

/// Pure: parse `gh pr view --json number,state,isDraft` output. gh emits a
/// JSON object on success and a non-JSON "no pull requests found" line (on
/// stderr, captured) otherwise. Returns null when no PR / unparsable.
/// state precedence: isDraft wins over OPEN; otherwise the textual state.
pub fn parseGhPr(raw: []const u8) ?PrInfo {
    const t = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (t.len == 0 or t[0] != '{') return null;

    const number = jsonNumberField(t, "\"number\":") orelse return null;
    const state_str = jsonStringField(t, "\"state\":") orelse return null;
    const is_draft = std.mem.indexOf(u8, t, "\"isDraft\":true") != null;

    const state: PrState = if (std.ascii.eqlIgnoreCase(state_str, "MERGED"))
        .merged
    else if (std.ascii.eqlIgnoreCase(state_str, "CLOSED"))
        .closed
    else if (is_draft)
        .draft
    else if (std.ascii.eqlIgnoreCase(state_str, "OPEN"))
        .open
    else
        return null;

    return .{ .state = state, .number = number };
}

/// Extract an integer value following `key` (e.g. `"number":`) in a flat
/// JSON object. Tolerates whitespace after the colon.
fn jsonNumberField(json: []const u8, key: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, json, key) orelse return null;
    var i = at + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    const start = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u32, json[start..i], 10) catch null;
}

/// Extract a string value following `key` (e.g. `"state":`) in a flat JSON
/// object (no escape handling needed for gh's enum-like state values).
fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, json, key) orelse return null;
    var i = at + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len and json[i] != '"') i += 1;
    if (i >= json.len) return null;
    return json[start..i];
}

// ---------------------------------------------------------------------------
// listening ports
// ---------------------------------------------------------------------------

/// Collect the distinct listening TCP ports owned by `root_pids` and all of
/// their descendant processes (the dev server is usually a grandchild of
/// the ConPTY shell). Returns an owned, ascending, deduped, capped slice
/// (empty slices are static, do not free). Worker-thread only.
fn collectListeningPorts(alloc: Allocator, root_pids: []const u32) ![]u16 {
    if (comptime builtin.os.tag != .windows) return &[_]u16{};

    // Expand the root PIDs to their full descendant set via a process
    // snapshot, then match listening TCP rows by owning PID.
    var pid_set = std.AutoHashMap(u32, void).init(alloc);
    defer pid_set.deinit();
    try collectDescendants(alloc, root_pids, &pid_set);

    var ports = std.ArrayList(u16).empty;
    defer ports.deinit(alloc);

    const table = getTcpListenerTable(alloc) catch return &[_]u16{};
    defer alloc.free(table);

    for (table) |row| {
        if (!pid_set.contains(row.dwOwningPid)) continue;
        // Ports are stored big-endian (network order) in the table.
        const port = std.mem.bigToNative(u16, @truncate(row.dwLocalPort));
        if (port == 0) continue;
        try ports.append(alloc, port);
    }

    return mergePorts(alloc, ports.items);
}

/// Pure: sort ascending, dedup, and cap to MAX_PORTS. Returns an owned
/// slice (or a static empty slice when there is nothing). Exposed for
/// testing the merge rule independently of the TCP table.
pub fn mergePorts(alloc: Allocator, raw: []const u16) ![]u16 {
    if (raw.len == 0) return &[_]u16{};
    const copy = try alloc.dupe(u16, raw);
    defer alloc.free(copy);
    std.mem.sort(u16, copy, {}, std.sort.asc(u16));
    var out = std.ArrayList(u16).empty;
    errdefer out.deinit(alloc);
    var last: ?u16 = null;
    for (copy) |p| {
        if (last != null and last.? == p) continue;
        if (out.items.len >= Window.MAX_PORTS) break;
        try out.append(alloc, p);
        last = p;
    }
    return out.toOwnedSlice(alloc);
}

/// A (pid, ppid) pair from a process snapshot. Pulled out so the
/// descendant-closure walk is unit testable without a live snapshot.
pub const ProcPair = struct { pid: u32, ppid: u32 };

/// Pure: given the full process list and a set of root pids, add every
/// descendant pid (transitively) into `set` (roots included). Bounded by
/// the process count so a malformed ppid cycle cannot loop forever.
pub fn closeDescendants(
    alloc: Allocator,
    procs: []const ProcPair,
    roots: []const u32,
    set: *std.AutoHashMap(u32, void),
) !void {
    for (roots) |r| try set.put(r, {});
    // Repeatedly sweep the table adding any proc whose parent is already in
    // the set, until a full sweep adds nothing. At most procs.len sweeps.
    _ = alloc;
    var changed = true;
    var guard: usize = 0;
    while (changed and guard <= procs.len) : (guard += 1) {
        changed = false;
        for (procs) |p| {
            if (set.contains(p.pid)) continue;
            if (set.contains(p.ppid)) {
                try set.put(p.pid, {});
                changed = true;
            }
        }
    }
}

/// Win32: snapshot all processes and fill `set` with `root_pids` plus all
/// their descendants.
fn collectDescendants(alloc: Allocator, root_pids: []const u32, set: *std.AutoHashMap(u32, void)) !void {
    if (comptime builtin.os.tag != .windows) {
        for (root_pids) |r| try set.put(r, {});
        return;
    }

    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) {
        for (root_pids) |r| try set.put(r, {});
        return;
    }
    defer _ = CloseHandle(snap);

    var procs = std.ArrayList(ProcPair).empty;
    defer procs.deinit(alloc);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) != 0) {
        while (true) {
            procs.append(alloc, .{ .pid = entry.th32ProcessID, .ppid = entry.th32ParentProcessID }) catch {};
            if (Process32NextW(snap, &entry) == 0) break;
        }
    }

    try closeDescendants(alloc, procs.items, root_pids, set);
}

/// Win32: fetch the TCP listener table (IPv4) as an owned slice of rows.
fn getTcpListenerTable(alloc: Allocator) ![]MIB_TCPROW_OWNER_PID {
    if (comptime builtin.os.tag != .windows) return &[_]MIB_TCPROW_OWNER_PID{};

    var size: u32 = 0;
    // First call: discover the required buffer size.
    _ = GetExtendedTcpTable(null, &size, 0, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if (size == 0) return &[_]MIB_TCPROW_OWNER_PID{};

    const buf = try alloc.alignedAlloc(u8, .of(MIB_TCPTABLE_OWNER_PID), size);
    defer alloc.free(buf);

    const rc = GetExtendedTcpTable(buf.ptr, &size, 0, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if (rc != 0) return &[_]MIB_TCPROW_OWNER_PID{};

    const tablep: *MIB_TCPTABLE_OWNER_PID = @ptrCast(buf.ptr);
    const n = tablep.dwNumEntries;
    if (n == 0) return &[_]MIB_TCPROW_OWNER_PID{};

    // The table layout is { dwNumEntries: u32, table: [n]row } with the
    // first row immediately following the count (after natural padding).
    const rows_ptr: [*]MIB_TCPROW_OWNER_PID = @ptrCast(&tablep.table);
    const out = try alloc.alloc(MIB_TCPROW_OWNER_PID, n);
    @memcpy(out, rows_ptr[0..n]);
    return out;
}

// ---------------------------------------------------------------------------
// process spawning (git / gh)
// ---------------------------------------------------------------------------

/// Spawn argv, capture stdout, return it owned on exit-0 (else null). The
/// child's cwd is the parent's (git uses -C); stderr is discarded.
fn runCapture(alloc: Allocator, argv: []const []const u8) ?[]u8 {
    return runCaptureCwd(alloc, argv, null);
}

/// Spawn argv with cwd `cwd` (or inherited when null), capture stdout, and
/// return it owned on a clean exit-0. Any spawn/wait error or non-zero exit
/// yields null. Caps captured output at 64 KiB (branch/PR JSON are tiny).
/// stderr is piped (collectOutput asserts both streams are .Pipe) but its
/// content is dropped — we only care about stdout.
fn runCaptureCwd(alloc: Allocator, argv: []const []const u8, cwd: ?[]const u8) ?[]u8 {
    var child = std.process.Child.init(argv, alloc);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return null;

    var stdout = std.ArrayList(u8).empty;
    var stderr = std.ArrayList(u8).empty;
    defer stdout.deinit(alloc);
    defer stderr.deinit(alloc);
    child.collectOutput(alloc, &stdout, &stderr, 64 * 1024) catch {
        _ = child.wait() catch {};
        return null;
    };
    const term = child.wait() catch return null;
    const ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;
    return stdout.toOwnedSlice(alloc) catch null;
}

// ---------------------------------------------------------------------------
// Win32 declarations (TCP table + toolhelp). Not in std/internal_os
// bindings; declared locally and used only on the worker thread.
// ---------------------------------------------------------------------------

const HANDLE = std.os.windows.HANDLE;
const BOOL = std.os.windows.BOOL;
const DWORD = std.os.windows.DWORD;
const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;

const AF_INET: u32 = 2;
// TCP_TABLE_CLASS.TCP_TABLE_OWNER_PID_LISTENER
const TCP_TABLE_OWNER_PID_LISTENER: u32 = 3;
const TH32CS_SNAPPROCESS: u32 = 0x00000002;

const MIB_TCPROW_OWNER_PID = extern struct {
    dwState: u32,
    dwLocalAddr: u32,
    dwLocalPort: u32,
    dwRemoteAddr: u32,
    dwRemotePort: u32,
    dwOwningPid: u32,
};

const MIB_TCPTABLE_OWNER_PID = extern struct {
    dwNumEntries: u32,
    table: [1]MIB_TCPROW_OWNER_PID,
};

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

extern "iphlpapi" fn GetExtendedTcpTable(
    pTcpTable: ?*anyopaque,
    pdwSize: *u32,
    bOrder: BOOL,
    ulAf: u32,
    TableClass: u32,
    Reserved: u32,
) callconv(.winapi) DWORD;

extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: u32, th32ProcessID: u32) callconv(.winapi) HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Tests (pure helpers only — no spawning, no Win32)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ws_meta: parseBranch trims and rejects empty" {
    try testing.expectEqualStrings("main", parseBranch("main\n").?);
    try testing.expectEqualStrings("feat/x", parseBranch("  feat/x  \r\n").?);
    try testing.expectEqualStrings("HEAD", parseBranch("HEAD\n").?);
    try testing.expectEqual(@as(?[]const u8, null), parseBranch("\n  \t"));
    try testing.expectEqual(@as(?[]const u8, null), parseBranch(""));
}

test "ws_meta: parseGhPr open/draft/merged/closed" {
    {
        const pr = parseGhPr("{\"isDraft\":false,\"number\":42,\"state\":\"OPEN\"}").?;
        try testing.expectEqual(PrState.open, pr.state);
        try testing.expectEqual(@as(u32, 42), pr.number);
    }
    {
        const pr = parseGhPr("{\"isDraft\":true,\"number\":7,\"state\":\"OPEN\"}").?;
        try testing.expectEqual(PrState.draft, pr.state);
        try testing.expectEqual(@as(u32, 7), pr.number);
    }
    {
        const pr = parseGhPr("{\"number\":9,\"state\":\"MERGED\",\"isDraft\":false}").?;
        try testing.expectEqual(PrState.merged, pr.state);
        try testing.expectEqual(@as(u32, 9), pr.number);
    }
    {
        const pr = parseGhPr("{\"number\":3,\"state\":\"CLOSED\",\"isDraft\":false}").?;
        try testing.expectEqual(PrState.closed, pr.state);
    }
}

test "ws_meta: parseGhPr rejects non-JSON and missing fields" {
    try testing.expectEqual(@as(?PrInfo, null), parseGhPr("no pull requests found for branch"));
    try testing.expectEqual(@as(?PrInfo, null), parseGhPr(""));
    try testing.expectEqual(@as(?PrInfo, null), parseGhPr("{\"state\":\"OPEN\"}")); // no number
    try testing.expectEqual(@as(?PrInfo, null), parseGhPr("{\"number\":1}")); // no state
    try testing.expectEqual(@as(?PrInfo, null), parseGhPr("{\"number\":1,\"state\":\"WEIRD\",\"isDraft\":false}"));
}

test "ws_meta: mergePorts sorts, dedups, and caps" {
    const alloc = testing.allocator;
    {
        const out = try mergePorts(alloc, &.{ 8080, 3000, 8080, 3000, 5173 });
        defer if (out.len > 0) alloc.free(out);
        try testing.expectEqualSlices(u16, &.{ 3000, 5173, 8080 }, out);
    }
    {
        // Empty stays a static empty slice (no free needed).
        const out = try mergePorts(alloc, &.{});
        try testing.expectEqual(@as(usize, 0), out.len);
    }
    {
        // Cap at MAX_PORTS.
        var many: [Window.MAX_PORTS + 4]u16 = undefined;
        for (&many, 0..) |*p, i| p.* = @intCast(1000 + i);
        const out = try mergePorts(alloc, &many);
        defer alloc.free(out);
        try testing.expectEqual(Window.MAX_PORTS, out.len);
        try testing.expectEqual(@as(u16, 1000), out[0]);
    }
}

test "ws_meta: closeDescendants gathers the transitive child set" {
    const alloc = testing.allocator;
    // Tree: 100 -> 200 -> 300, 200 -> 301; 999 unrelated.
    const procs = [_]ProcPair{
        .{ .pid = 200, .ppid = 100 },
        .{ .pid = 300, .ppid = 200 },
        .{ .pid = 301, .ppid = 200 },
        .{ .pid = 999, .ppid = 1 },
    };
    var set = std.AutoHashMap(u32, void).init(alloc);
    defer set.deinit();
    try closeDescendants(alloc, &procs, &.{100}, &set);
    try testing.expect(set.contains(100));
    try testing.expect(set.contains(200));
    try testing.expect(set.contains(300));
    try testing.expect(set.contains(301));
    try testing.expect(!set.contains(999));
    try testing.expectEqual(@as(u32, 4), set.count());
}

test "ws_meta: closeDescendants terminates on a ppid cycle" {
    const alloc = testing.allocator;
    // Pathological self/mutual parent cycle must not loop forever.
    const procs = [_]ProcPair{
        .{ .pid = 10, .ppid = 11 },
        .{ .pid = 11, .ppid = 10 },
    };
    var set = std.AutoHashMap(u32, void).init(alloc);
    defer set.deinit();
    try closeDescendants(alloc, &procs, &.{10}, &set);
    try testing.expect(set.contains(10));
    try testing.expect(set.contains(11));
}
