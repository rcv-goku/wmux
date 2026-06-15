//! Named-pipe IPC server core for agent-scriptable control of a running
//! Ghostty instance: browser panes (`ghostty +browser ...`) plus the
//! workspace/tab/keystroke scripting API (`ghostty +workspace|+tab|+send
//! ...`).
//!
//! Wire protocol: newline-delimited JSON over a message-type named pipe
//! at \\.\pipe\ghostty-ipc-<pid>.
//!
//!   request:  {"id":1,"cmd":"open","args":{"url":"https://..."}}\n
//!   response: {"id":1,"ok":true,"data":...}\n
//!             {"id":1,"ok":false,"error":"..."}\n
//!
//! The module is split into three layers:
//!
//!   (a) a pure protocol layer (parse / serialize / framing) with no
//!       OS dependencies, unit-tested on any target;
//!   (b) a thin Win32 named-pipe layer (extern decls + a security
//!       descriptor restricting the pipe to the current user);
//!   (c) `Server`, which ties them together: a dedicated pipe thread
//!       accepts one client at a time, reads newline-delimited
//!       requests, heap-allocates each parsed `Request`, and hands it
//!       to a callback. In production the callback PostMessageW's the
//!       request pointer to App's msg_hwnd; here it is modeled as a
//!       plain function pointer so the module stays standalone.
//!       Responses may be written from any thread via send{Ok,Error}.
//!
//! Concurrency note (the reason the pipe is opened FILE_FLAG_OVERLAPPED):
//! a synchronous duplex pipe handle serializes *all* I/O on the file
//! object, so a WriteFile issued from another thread (e.g. the GUI
//! thread answering a request) blocks behind the pipe thread's pending
//! ReadFile — deadlocking request/response. Overlapped I/O keeps reads
//! and writes independent and gives us clean shutdown via an event +
//! CancelIoEx instead of the dummy-connect / CancelSynchronousIo hacks
//! needed for synchronous handles.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const kernel32 = windows.kernel32;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const log = std.log.scoped(.win32_ipc);

// ---------------------------------------------------------------------------
// Protocol layer (pure; no OS dependencies)
// ---------------------------------------------------------------------------

/// Hard cap on a single newline-delimited request line. Anything larger
/// is a protocol violation and drops the connection.
pub const max_line_bytes: usize = 1024 * 1024;

/// Commands the agent IPC understands. The server core only validates
/// the name; execution lives with the callback owner (App). The first
/// group drives browser panes; the second is the workspace/tab/keystroke
/// scripting API (the cmux socket-API equivalent).
pub const Command = enum {
    // Browser pane control.
    open,
    navigate,
    eval,
    snapshot,
    click,
    fill,

    // Workspace / tab / keystroke scripting.
    @"workspace-list",
    @"workspace-new",
    @"workspace-select",
    @"workspace-close",
    @"tab-list",
    @"tab-new",
    @"tab-select",
    @"tab-close",
    send,

    // Notification ring: set/clear the per-pane "needs attention"
    // indicator (the agent-waiting ring). Args: {action:"ring"|"clear",
    // [workspace], [tab]}.
    notify,

    // Orchestration scripting (the agent-supervises-agent substrate). All
    // run synchronously on the GUI thread and reply directly, like the
    // workspace/tab verbs (they touch the live model). Indices follow the
    // same defaulting as send/notify (absent workspace/tab => active).
    //
    // surface-list {[workspace],[tab]} -> JSON of panes in the addressed
    //   tab: [{id, kind:"terminal"|"browser", focused, title}].
    // surface-focus {surface | (workspace,tab,pane)} -> focus a pane by its
    //   stable surface id, or by workspace/tab/pane index.
    // new-split {dir:"right"|"down", [workspace],[tab],[command]} -> split
    //   the addressed (or active) pane; reply {id} of the new pane.
    // set-status {[workspace],[tab], [text]} -> set/clear a per-tab status
    //   string the sidebar renders (empty/absent text clears it).
    // set-progress {[workspace],[tab], value:0..100|-1} -> set a per-tab
    //   progress percent; -1 (or "clear") clears it.
    // log {[workspace],[tab], text} -> append a line to the addressed tab's
    //   ring log buffer (and the global notif panel).
    // read-screen {[workspace],[tab],[lines],[scrollback]} -> the addressed
    //   pane terminal's screen text as UTF-8 (visible screen, or full
    //   scrollback when scrollback:true). THE agent-reads-agent verb.
    @"surface-list",
    @"surface-focus",
    @"new-split",
    @"swap-split",
    @"set-status",
    @"set-progress",
    log,
    @"read-screen",

    // capture-pane {[workspace],[tab],[scrollback:bool],[file:path]} ->
    //   dump the addressed pane's screen text (visible or full scrollback)
    //   and either return it as the IPC response or write it to a file. The
    //   tmux `capture-pane` equivalent for session restore.
    @"capture-pane",

    // Session capture/resume: record (per surface) which agent runs in a
    // pane and its native session id, and replay the agent's resume argv.
    // session-capture {agent, session, [surface]} -> Store.put.
    // session-resume {[surface],[workspace],[tab]} -> relaunch via
    //   AgentKind.resumeArgv into the pane (ipcSendText).
    // session-list -> dump the whole store as JSON.
    @"session-capture",
    @"session-resume",
    @"session-list",

    @"select-layout",
    // Toggle synchronized input for a tab. Args: {action:"toggle"|"on"|
    // "off", [workspace], [tab]}. Defaults to the active workspace/tab.
    @"sync-input",
    // Pane movement: break a pane out of its split into a new tab, or
    // move it to an adjacent/specific tab.
    @"break-pane",
    @"move-pane",
    // Full session save/restore (tmux-resurrect style).
    @"session-save",
    @"session-restore",
    // Flash the focused pane (brief visual highlight).
    @"flash-pane",
    // Workspace description: set/clear the user-facing description text
    // shown below the workspace name in the sidebar.
    // workspace-set-description {workspace, text} -> ok.
    @"workspace-set-description",
    // Right sidebar toggle (mirrors toggle_sidebar for the right panel).
    @"toggle-right-sidebar",
};

/// Protocol-level failures that map to error responses.
pub const ErrorCode = enum {
    parse_error,
    invalid_request,
    unknown_command,
    message_too_long,

    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .parse_error => "request is not valid JSON",
            .invalid_request => "request must be an object with a non-negative integer \"id\", a string \"cmd\", and an optional object \"args\"",
            .unknown_command => "unknown command",
            .message_too_long => "request exceeds maximum length",
        };
    }
};

/// A parsed request. Heap-allocated by `parseLine`; whoever receives it
/// (the callback, in production the GUI thread after the PostMessageW
/// hop) owns it and must call `destroy()` exactly once.
pub const Request = struct {
    gpa: Allocator,
    /// Backing storage for `args`; everything the json Value points at
    /// lives here.
    arena: std.heap.ArenaAllocator,
    id: u64,
    cmd: Command,
    /// The request's "args" object, or `.null` when absent.
    args: std.json.Value,
    /// Side channel for work done on the pipe thread before the request
    /// reaches the UI thread: `workspace-new --worktree` runs `git
    /// worktree add` off-loop (so a slow git can't stall the message
    /// pump), then stashes the resolved worktree path here for the UI
    /// handler to bind to the new workspace. Heap-allocated with `gpa`,
    /// owned by the Request, freed in destroy(). Null for every other
    /// request (and for a plain `workspace-new` with no worktree).
    worktree_path: ?[]u8 = null,

    pub fn destroy(self: *Request) void {
        const gpa = self.gpa;
        if (self.worktree_path) |p| gpa.free(p);
        self.arena.deinit();
        gpa.destroy(self);
    }
};

// Typed accessors over Request.args. Command-specific argument
// validation (e.g. click's required integer "ref", fill's required
// string "text") happens in the handlers via these; they live here so
// the pure protocol tests can cover them without dragging in App.

/// Read an optional u32 "id" field from the request args: the pane
/// address used by navigate/eval/snapshot/click/fill.
pub fn argId(req: *const Request) ?u32 {
    if (req.args != .object) return null;
    const v = req.args.object.get("id") orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

/// Read a required string field from the request args.
pub fn argString(req: *const Request, key: []const u8) ?[]const u8 {
    if (req.args != .object) return null;
    const v = req.args.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Read an i64 field (the CDP backendNodeId `ref`) from the request args.
pub fn argI64(req: *const Request, key: []const u8) ?i64 {
    if (req.args != .object) return null;
    const v = req.args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// Read an optional u32 field by name: the workspace/tab indices used by
/// the workspace/tab/send commands. Out-of-range or non-integer values
/// (negative, fractional, beyond u32, a string) yield null so handlers
/// can answer a clean error. Distinct from `argId`, which is hard-wired
/// to the browser pane address key "id".
pub fn argU32(req: *const Request, key: []const u8) ?u32 {
    if (req.args != .object) return null;
    const v = req.args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

/// Read an optional bool field by name (e.g. send's "enter"). A missing
/// field or any non-bool value yields null; handlers default it.
pub fn argBool(req: *const Request, key: []const u8) ?bool {
    if (req.args != .object) return null;
    const v = req.args.object.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

/// Read an optional u64 field by name: a stable surface id (the core
/// Surface.id exported to shells as GHOSTTY_SURFACE_ID). A surface id is
/// a random non-zero u64, which can exceed i64 range, so it arrives over
/// JSON as either an .integer (<= i64 max) or a .number_string (beyond
/// it); both are accepted. Negative, fractional, or non-numeric values
/// yield null so handlers can answer a clean error. Distinct from argU32
/// (workspace/tab indices, which stay small).
pub fn argU64(req: *const Request, key: []const u8) ?u64 {
    if (req.args != .object) return null;
    const v = req.args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        // std.json emits integers beyond i64 as .number_string; a surface
        // id (full u64 range) can land here.
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

/// Read an optional i64 field by name with the same lenient typing as
/// argU64 for the integer case (used by set-progress, where -1 means
/// "clear"). number_string is parsed as i64; out-of-range/non-numeric
/// yields null.
pub fn argI64Named(req: *const Request, key: []const u8) ?i64 {
    if (req.args != .object) return null;
    const v = req.args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Status / progress / log ring (pure; the sidebar metadata model)
// ---------------------------------------------------------------------------

/// A small fixed-capacity ring of recent log lines for one tab. Pushed by
/// the `log` IPC verb and rendered by the sidebar (Stage 2). Kept here, in
/// the pure protocol layer, so the wrap/newest-first/truncation rules are
/// unit-testable without a live Window. Each line is stored in an inline
/// fixed buffer (no per-push allocation, matching the tab-title/name
/// buffers on Workspace); over-long lines are byte-truncated.
pub const max_log_line_bytes: usize = 160;
pub const log_ring_capacity: usize = 8;

pub const LogRing = struct {
    /// Inline storage for each line + its used length.
    lines: [log_ring_capacity][max_log_line_bytes]u8 = undefined,
    lens: [log_ring_capacity]u16 = @splat(0),
    /// Index where the next push lands (mod capacity).
    head: usize = 0,
    /// Number of live lines (<= capacity).
    len: usize = 0,

    /// Append a line, truncating to max_log_line_bytes and dropping the
    /// oldest once full. Invalid UTF-8 is not the ring's concern (the
    /// renderer is lossy); the byte truncation may split a codepoint, so
    /// callers that care should pre-truncate on a boundary.
    pub fn push(self: *LogRing, text: []const u8) void {
        const n: u16 = @intCast(@min(text.len, max_log_line_bytes));
        @memcpy(self.lines[self.head][0..n], text[0..n]);
        self.lens[self.head] = n;
        self.head = (self.head + 1) % log_ring_capacity;
        if (self.len < log_ring_capacity) self.len += 1;
    }

    /// The display_idx-th newest line (0 = newest), or null past the end.
    pub fn at(self: *const LogRing, display_idx: usize) ?[]const u8 {
        if (display_idx >= self.len) return null;
        // head points one past the newest; walk backward.
        const slot = (self.head + log_ring_capacity - 1 - display_idx) % log_ring_capacity;
        return self.lines[slot][0..self.lens[slot]];
    }

    /// The newest line, or null when empty (the sidebar's "latest" text).
    pub fn latest(self: *const LogRing) ?[]const u8 {
        return self.at(0);
    }

    pub fn clear(self: *LogRing) void {
        self.head = 0;
        self.len = 0;
    }
};

// ---------------------------------------------------------------------------
// Worktree-path construction (pure; used by workspace-new --worktree)
// ---------------------------------------------------------------------------

/// Failures from validating a git branch name destined for a worktree
/// directory under <repo>/.worktrees/.
pub const WorktreeError = error{
    /// The branch name is empty or only separators/whitespace.
    EmptyBranch,
    /// The branch name would escape the .worktrees directory: it contains
    /// a path separator, a drive/volume marker, or a ".." traversal
    /// component. Branches like "feature/x" are common in git, but we
    /// flatten them in worktreePath; an explicit path-traversal attempt
    /// ("../x", "a/../../b") is rejected outright rather than flattened so
    /// a hostile branch name can never write outside .worktrees.
    UnsafeBranch,
    /// The branch name is longer than the directory-name budget.
    BranchTooLong,
};

/// Hard cap on a sanitized worktree directory name (well under any
/// filesystem component limit; keeps the joined path bounded).
pub const max_worktree_name: usize = 128;

/// Reject a branch name that must never become a directory name because
/// it could escape <repo>/.worktrees/. Run BEFORE sanitization on the
/// raw, caller-supplied branch so traversal can't be laundered into a
/// safe-looking name. Rules:
///   * empty (after trimming ASCII whitespace) → EmptyBranch
///   * contains any '/' or '\\' path separator → UnsafeBranch
///     (git allows slashes in branches, but we keep one flat directory
///     under .worktrees and refuse to create nested dirs from the name)
///   * a ".." component, or a leading/trailing/standalone ".." → Unsafe
///   * a ':' (Windows drive/ADS marker) → UnsafeBranch
/// On success returns the trimmed branch slice (a subslice of `branch`).
pub fn validateBranch(branch: []const u8) WorktreeError![]const u8 {
    const trimmed = std.mem.trim(u8, branch, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.EmptyBranch;
    if (std.mem.eql(u8, trimmed, "..") or std.mem.eql(u8, trimmed, "."))
        return error.UnsafeBranch;
    for (trimmed) |ch| {
        switch (ch) {
            '/', '\\', ':' => return error.UnsafeBranch,
            else => {},
        }
    }
    // A literal ".." anywhere is traversal even without a separator on
    // either side (defense in depth; the separator check above already
    // catches "../").
    if (std.mem.indexOf(u8, trimmed, "..") != null) return error.UnsafeBranch;
    if (trimmed.len > max_worktree_name) return error.BranchTooLong;
    return trimmed;
}

/// Turn a (validated) branch name into a safe directory-name component:
/// every byte that isn't ASCII alphanumeric, '-', '_', or '.' becomes
/// '-'. validateBranch has already rejected separators and traversal, so
/// this only normalizes display-hostile bytes (spaces, punctuation) into
/// a tidy folder name. Writes into `buf` and returns the written slice;
/// the caller sizes buf >= max_worktree_name.
pub fn sanitizeBranchName(branch: []const u8, buf: []u8) []u8 {
    std.debug.assert(buf.len >= branch.len);
    for (branch, 0..) |ch, i| {
        buf[i] = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => ch,
            else => '-',
        };
    }
    return buf[0..branch.len];
}

/// Build the absolute worktree path <repo>/.worktrees/<sanitized-branch>
/// for a validated branch. `repo` is the resolved repository root
/// (forward or back slashes both fine on Windows). Caller owns the
/// returned slice. Validation (validateBranch) is the caller's
/// responsibility and must run first; this asserts the branch is already
/// separator/traversal-free.
pub fn worktreePath(
    alloc: Allocator,
    repo: []const u8,
    validated_branch: []const u8,
) Allocator.Error![]u8 {
    var name_buf: [max_worktree_name]u8 = undefined;
    const name = sanitizeBranchName(validated_branch, &name_buf);
    // std.fs.path.join normalizes the separator per the host; on Windows
    // this yields backslashes, which git -C accepts.
    return std.fs.path.join(alloc, &.{ repo, ".worktrees", name });
}

pub const ParseFailure = struct {
    /// Request id when it could be recovered from the malformed
    /// request, 0 otherwise.
    id: u64,
    code: ErrorCode,
};

pub const ParseResult = union(enum) {
    ok: *Request,
    err: ParseFailure,
};

/// Parse one newline-stripped request line. Protocol violations are
/// reported in-band as `.err` (so the server can answer them); only
/// allocation failure is a Zig error.
pub fn parseLine(gpa: Allocator, line: []const u8) Allocator.Error!ParseResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const root = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        line,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return parseFailure(&arena, 0, .parse_error),
    };

    const obj = switch (root) {
        .object => |o| o,
        else => return parseFailure(&arena, 0, .invalid_request),
    };

    const id: u64 = id: {
        const value = obj.get("id") orelse
            return parseFailure(&arena, 0, .invalid_request);
        switch (value) {
            .integer => |i| {
                if (i < 0) return parseFailure(&arena, 0, .invalid_request);
                break :id @intCast(i);
            },
            else => return parseFailure(&arena, 0, .invalid_request),
        }
    };

    const cmd: Command = cmd: {
        const value = obj.get("cmd") orelse
            return parseFailure(&arena, id, .invalid_request);
        const name = switch (value) {
            .string => |s| s,
            else => return parseFailure(&arena, id, .invalid_request),
        };
        break :cmd std.meta.stringToEnum(Command, name) orelse
            return parseFailure(&arena, id, .unknown_command);
    };

    const args: std.json.Value = args: {
        const value = obj.get("args") orelse break :args .null;
        switch (value) {
            .object, .null => break :args value,
            else => return parseFailure(&arena, id, .invalid_request),
        }
    };

    const req = try gpa.create(Request);
    req.* = .{
        .gpa = gpa,
        .arena = arena,
        .id = id,
        .cmd = cmd,
        .args = args,
        .worktree_path = null,
    };
    return .{ .ok = req };
}

fn parseFailure(
    arena: *std.heap.ArenaAllocator,
    id: u64,
    code: ErrorCode,
) ParseResult {
    arena.deinit();
    return .{ .err = .{ .id = id, .code = code } };
}

/// Serialize a success response, trailing newline included. `data_json`
/// must already be valid JSON (the GUI thread typically produces it
/// with std.json); null serializes as "data":null. Caller owns the
/// returned slice.
pub fn serializeOk(
    alloc: Allocator,
    id: u64,
    data_json: ?[]const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"id\":{d},\"ok\":true,\"data\":{s}}}\n",
        .{ id, data_json orelse "null" },
    );
}

/// Serialize an error response, trailing newline included. `msg` is
/// JSON-escaped. id 0 means the request id could not be recovered.
/// Caller owns the returned slice.
pub fn serializeError(
    alloc: Allocator,
    id: u64,
    msg: []const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"id\":{d},\"ok\":false,\"error\":{f}}}\n",
        .{ id, std.json.fmt(msg, .{}) },
    );
}

/// Newline framing with partial-buffer accumulation: ReadFile chunks go
/// in via feed(), complete lines (without their "\n" or "\r\n") come
/// out via next(). Slices returned by next() are only valid until the
/// next feed() call.
pub const LineFramer = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Offset of the first unconsumed byte in `buf`.
    start: usize = 0,

    pub fn deinit(self: *LineFramer, alloc: Allocator) void {
        self.buf.deinit(alloc);
        self.* = undefined;
    }

    pub fn feed(
        self: *LineFramer,
        alloc: Allocator,
        chunk: []const u8,
    ) error{ OutOfMemory, MessageTooLong }!void {
        // Compact the consumed prefix so the buffer can't grow without
        // bound across many requests.
        if (self.start > 0) {
            const remaining = self.buf.items.len - self.start;
            std.mem.copyForwards(
                u8,
                self.buf.items[0..remaining],
                self.buf.items[self.start..],
            );
            self.buf.shrinkRetainingCapacity(remaining);
            self.start = 0;
        }
        if (self.buf.items.len + chunk.len > max_line_bytes) {
            return error.MessageTooLong;
        }
        try self.buf.appendSlice(alloc, chunk);
    }

    pub fn next(self: *LineFramer) ?[]const u8 {
        const unread = self.buf.items[self.start..];
        const nl = std.mem.indexOfScalar(u8, unread, '\n') orelse return null;
        var line = unread[0..nl];
        self.start += nl + 1;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        return line;
    }
};

// ---------------------------------------------------------------------------
// Win32 pipe layer
// ---------------------------------------------------------------------------

// Constants not exposed by std.os.windows.
const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const PIPE_REJECT_REMOTE_CLIENTS: u32 = 0x00000008;
const TOKEN_QUERY: u32 = 0x0008;
const TOKEN_USER_CLASS: c_int = 1; // TOKEN_INFORMATION_CLASS.TokenUser
const SDDL_REVISION_1: u32 = 1;

const SID_AND_ATTRIBUTES = extern struct {
    Sid: ?*anyopaque,
    Attributes: windows.DWORD,
};

const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};

extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn DisconnectNamedPipe(
    hNamedPipe: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetOverlappedResult(
    hFile: windows.HANDLE,
    lpOverlapped: *windows.OVERLAPPED,
    lpNumberOfBytesTransferred: *windows.DWORD,
    bWait: windows.BOOL,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bManualReset: windows.BOOL,
    bInitialState: windows.BOOL,
    lpName: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn SetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;

extern "kernel32" fn ResetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;

extern "kernel32" fn WaitForMultipleObjects(
    nCount: windows.DWORD,
    lpHandles: [*]const windows.HANDLE,
    bWaitAll: windows.BOOL,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

extern "advapi32" fn OpenProcessToken(
    ProcessHandle: windows.HANDLE,
    DesiredAccess: windows.DWORD,
    TokenHandle: *windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn GetTokenInformation(
    TokenHandle: windows.HANDLE,
    TokenInformationClass: c_int,
    TokenInformation: ?*anyopaque,
    TokenInformationLength: windows.DWORD,
    ReturnLength: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn ConvertSidToStringSidW(
    Sid: *anyopaque,
    StringSid: *?windows.LPWSTR,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    StringSecurityDescriptor: windows.LPCWSTR,
    StringSDRevision: windows.DWORD,
    SecurityDescriptor: *?*anyopaque,
    SecurityDescriptorSize: ?*windows.ULONG,
) callconv(.winapi) windows.BOOL;

/// Security descriptor restricting the pipe to the current user:
/// SDDL "D:P(A;;GA;;;<user-sid>)" — a protected DACL (no inherited
/// ACEs) with a single ACE granting GENERIC_ALL to the process owner's
/// SID. Everyone else — other local users, services, and (belt and
/// suspenders, on top of PIPE_REJECT_REMOTE_CLIENTS) remote clients —
/// is implicitly denied.
const PipeSecurity = struct {
    descriptor: *anyopaque,

    fn init(alloc: Allocator) !PipeSecurity {
        // Current process token → TOKEN_USER → SID.
        var token: windows.HANDLE = undefined;
        if (OpenProcessToken(
            windows.GetCurrentProcess(),
            TOKEN_QUERY,
            &token,
        ) == 0) return error.OpenProcessTokenFailed;
        defer windows.CloseHandle(token);

        var token_buf: [256]u8 align(@alignOf(TOKEN_USER)) = undefined;
        var needed: windows.DWORD = 0;
        if (GetTokenInformation(
            token,
            TOKEN_USER_CLASS,
            &token_buf,
            token_buf.len,
            &needed,
        ) == 0) return error.GetTokenInformationFailed;
        const user: *const TOKEN_USER = @ptrCast(&token_buf);
        const sid = user.User.Sid orelse return error.GetTokenInformationFailed;

        // SID → "S-1-5-21-..." string.
        var sid_w: ?windows.LPWSTR = null;
        if (ConvertSidToStringSidW(sid, &sid_w) == 0) {
            return error.ConvertSidFailed;
        }
        defer _ = LocalFree(sid_w);
        const sid_utf8 = try std.unicode.utf16LeToUtf8Alloc(
            alloc,
            std.mem.span(sid_w.?),
        );
        defer alloc.free(sid_utf8);

        // SDDL string → security descriptor (LocalAlloc'd by the OS).
        const sddl = try std.fmt.allocPrint(
            alloc,
            "D:P(A;;GA;;;{s})",
            .{sid_utf8},
        );
        defer alloc.free(sddl);
        const sddl_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, sddl);
        defer alloc.free(sddl_w);

        var sd: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_w.ptr,
            SDDL_REVISION_1,
            &sd,
            null,
        ) == 0) return error.ConvertSddlFailed;

        return .{ .descriptor = sd.? };
    }

    fn deinit(self: *PipeSecurity) void {
        _ = LocalFree(self.descriptor);
        self.* = undefined;
    }
};

/// Format the production pipe name "ghostty-ipc-<pid>" into buf. The CLI
/// clients (+browser/+workspace/+tab/+send) resolve the target window's
/// pid and open \\.\pipe\ghostty-ipc-<pid> with CreateFileW.
pub fn defaultPipeName(buf: []u8) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(
        buf,
        "ghostty-ipc-{d}",
        .{windows.GetCurrentProcessId()},
    );
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/// Invoked on the pipe thread for each successfully parsed request.
/// The callee takes ownership of `req` and must call `req.destroy()`
/// exactly once. In production wiring this PostMessageW's the request
/// pointer to App's msg_hwnd and the GUI thread answers later via
/// `server.sendOk` / `server.sendError`; answering directly from the
/// callback also works. The signature deliberately does not mention
/// `*Server` (that would create a type dependency loop through the
/// callback field); owners reach their server through `ctx`.
pub const RequestCallback = *const fn (ctx: ?*anyopaque, req: *Request) void;

pub const Server = struct {
    alloc: Allocator,
    /// Full "\\.\pipe\<name>" path, NUL-terminated UTF-16, owned.
    path_w: [:0]u16,
    pipe: windows.HANDLE,
    callback: RequestCallback,
    callback_ctx: ?*anyopaque,

    /// Manual-reset, signaled once by stop(); every subsequent wait
    /// returns immediately.
    stop_event: windows.HANDLE,
    /// Completion event for connect/read overlapped ops (pipe thread only).
    io_event: windows.HANDLE,
    /// Completion event for write overlapped ops; guarded by write_mutex.
    write_event: windows.HANDLE,

    /// Serializes senders so each response is one atomic pipe message.
    write_mutex: std.Thread.Mutex = .{},
    running: std.atomic.Value(bool),
    connected: std.atomic.Value(bool),
    thread: ?std.Thread = null,

    /// Create the pipe \\.\pipe\<name> and spawn the pipe thread.
    /// `name` is the bare pipe name (see `defaultPipeName`).
    pub fn start(
        alloc: Allocator,
        name: []const u8,
        callback: RequestCallback,
        callback_ctx: ?*anyopaque,
    ) !*Server {
        const path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\{s}", .{name});
        defer alloc.free(path);
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
        errdefer alloc.free(path_w);

        var sec = try PipeSecurity.init(alloc);
        defer sec.deinit();
        var sa = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = sec.descriptor,
            .bInheritHandle = windows.FALSE,
        };

        // The pipe is created here, synchronously, so a client may
        // CreateFileW the moment start() returns. FIRST_PIPE_INSTANCE
        // defeats pipe-squatting: creation fails if the name already
        // exists. Message type so each WriteFile is one message; byte
        // read mode because the newline framing handles splitting and
        // never needs ERROR_MORE_DATA handling.
        const pipe = kernel32.CreateNamedPipeW(
            path_w.ptr,
            windows.PIPE_ACCESS_DUPLEX |
                FILE_FLAG_FIRST_PIPE_INSTANCE |
                FILE_FLAG_OVERLAPPED,
            windows.PIPE_TYPE_MESSAGE |
                windows.PIPE_READMODE_BYTE |
                windows.PIPE_WAIT |
                PIPE_REJECT_REMOTE_CLIENTS,
            1, // single instance: one agent client at a time
            64 * 1024,
            64 * 1024,
            0,
            &sa,
        );
        if (pipe == windows.INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
        errdefer windows.CloseHandle(pipe);

        const stop_event = CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
            return error.CreateEventFailed;
        errdefer windows.CloseHandle(stop_event);
        const io_event = CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
            return error.CreateEventFailed;
        errdefer windows.CloseHandle(io_event);
        const write_event = CreateEventW(null, windows.TRUE, windows.FALSE, null) orelse
            return error.CreateEventFailed;
        errdefer windows.CloseHandle(write_event);

        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .path_w = path_w,
            .pipe = pipe,
            .callback = callback,
            .callback_ctx = callback_ctx,
            .stop_event = stop_event,
            .io_event = io_event,
            .write_event = write_event,
            .running = std.atomic.Value(bool).init(true),
            .connected = std.atomic.Value(bool).init(false),
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stop the pipe thread and free everything, including `self`.
    ///
    /// Unblocking mechanism: because every blocking op on the pipe
    /// thread (ConnectNamedPipe / ReadFile) is overlapped and actually
    /// waits on WaitForMultipleObjects({io_event, stop_event}), stop()
    /// only has to signal stop_event and CancelIoEx any in-flight op.
    /// No client-side dummy connect or CancelSynchronousIo needed —
    /// those are the workarounds for synchronous handles, which we
    /// can't use anyway (see the module doc on the sync-handle
    /// write/read deadlock).
    ///
    /// Must be the last call into the server: callers are responsible
    /// for ensuring no sendOk/sendError is in flight on other threads
    /// (in production, App stops IPC before tearing down the GUI
    /// thread's response path).
    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
        _ = SetEvent(self.stop_event);
        // Cancels pending I/O issued by any thread on this handle,
        // including a sender blocked in GetOverlappedResult.
        _ = kernel32.CancelIoEx(self.pipe, null);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        windows.CloseHandle(self.pipe);
        windows.CloseHandle(self.stop_event);
        windows.CloseHandle(self.io_event);
        windows.CloseHandle(self.write_event);
        self.alloc.free(self.path_w);
        self.alloc.destroy(self);
    }

    /// Send a success response. Thread-safe. `data_json` must already
    /// be valid serialized JSON; null sends "data":null.
    pub fn sendOk(self: *Server, id: u64, data_json: ?[]const u8) !void {
        const msg = try serializeOk(self.alloc, id, data_json);
        defer self.alloc.free(msg);
        try self.writeAll(msg);
    }

    /// Send an error response. Thread-safe. `msg` is JSON-escaped.
    pub fn sendError(self: *Server, id: u64, msg: []const u8) !void {
        const out = try serializeError(self.alloc, id, msg);
        defer self.alloc.free(out);
        try self.writeAll(out);
    }

    // -- pipe thread ------------------------------------------------------

    fn run(self: *Server) void {
        while (self.running.load(.acquire)) {
            switch (self.acceptOne()) {
                .connected => {
                    self.connected.store(true, .release);
                    self.readLoop();
                    self.connected.store(false, .release);
                    _ = DisconnectNamedPipe(self.pipe);
                },
                // A client connected and vanished before we accepted.
                .retry => _ = DisconnectNamedPipe(self.pipe),
                .shutdown => return,
            }
        }
    }

    const AcceptResult = enum { connected, retry, shutdown };

    fn acceptOne(self: *Server) AcceptResult {
        var ov = std.mem.zeroes(windows.OVERLAPPED);
        ov.hEvent = self.io_event;
        _ = ResetEvent(self.io_event);

        var pending = false;
        if (ConnectNamedPipe(self.pipe, &ov) == 0) {
            switch (windows.GetLastError()) {
                .PIPE_CONNECTED => {}, // client raced us; already connected
                .IO_PENDING => pending = true,
                .NO_DATA => return .retry,
                else => |err| {
                    log.warn(
                        "ConnectNamedPipe failed, stopping IPC server: error={d}",
                        .{@intFromEnum(err)},
                    );
                    return .shutdown;
                },
            }
        }
        if (pending) {
            if (self.completeOverlapped(&ov) == null) return .shutdown;
        }
        if (!self.running.load(.acquire)) return .shutdown;
        return .connected;
    }

    fn readLoop(self: *Server) void {
        var framer: LineFramer = .{};
        defer framer.deinit(self.alloc);

        var buf: [4096]u8 = undefined;
        while (self.running.load(.acquire)) {
            const n = self.readChunk(&buf) orelse return;
            if (n == 0) continue;

            framer.feed(self.alloc, buf[0..n]) catch |err| {
                if (err == error.MessageTooLong) {
                    self.sendError(0, ErrorCode.message_too_long.message()) catch {};
                }
                // Framing state is unrecoverable; drop the connection.
                return;
            };
            while (framer.next()) |line| {
                if (line.len == 0) continue;
                self.dispatchLine(line);
            }
        }
    }

    /// One overlapped ReadFile. Returns bytes read, or null when the
    /// client disconnected or the server is stopping.
    fn readChunk(self: *Server, buf: []u8) ?windows.DWORD {
        var ov = std.mem.zeroes(windows.OVERLAPPED);
        ov.hEvent = self.io_event;
        _ = ResetEvent(self.io_event);

        if (kernel32.ReadFile(
            self.pipe,
            @ptrCast(buf.ptr),
            @intCast(buf.len),
            null,
            &ov,
        ) == 0) {
            switch (windows.GetLastError()) {
                .IO_PENDING => {},
                else => return null, // BROKEN_PIPE etc.: client gone
            }
        }
        return self.completeOverlapped(&ov);
    }

    /// Wait for an overlapped connect/read on io_event to complete,
    /// racing the stop event. Returns bytes transferred, or null on
    /// stop or failure. On stop the op is canceled and drained so the
    /// kernel is done with `ov` before it leaves the caller's stack.
    fn completeOverlapped(
        self: *Server,
        ov: *windows.OVERLAPPED,
    ) ?windows.DWORD {
        const handles = [_]windows.HANDLE{ self.io_event, self.stop_event };
        const which = WaitForMultipleObjects(
            handles.len,
            &handles,
            windows.FALSE,
            windows.INFINITE,
        );
        var n: windows.DWORD = 0;
        if (which != windows.WAIT_OBJECT_0) {
            // Stop requested (or the wait itself failed): cancel + drain.
            _ = kernel32.CancelIoEx(self.pipe, ov);
            _ = GetOverlappedResult(self.pipe, ov, &n, windows.TRUE);
            return null;
        }
        if (GetOverlappedResult(self.pipe, ov, &n, windows.TRUE) == 0) return null;
        return n;
    }

    fn dispatchLine(self: *Server, line: []const u8) void {
        const result = parseLine(self.alloc, line) catch {
            // OOM: an error response would also have to allocate.
            return;
        };
        switch (result) {
            .ok => |req| self.callback(self.callback_ctx, req),
            .err => |failure| self.sendError(
                failure.id,
                failure.code.message(),
            ) catch |err| {
                log.warn("failed to send IPC error response: {}", .{err});
            },
        }
    }

    /// Write one response as a single pipe message. Thread-safe: the
    /// write mutex serializes concurrent senders, and overlapped I/O
    /// keeps writes independent of the pipe thread's pending ReadFile.
    fn writeAll(
        self: *Server,
        bytes: []const u8,
    ) error{ NotConnected, WriteFailed }!void {
        if (!self.connected.load(.acquire)) return error.NotConnected;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        var ov = std.mem.zeroes(windows.OVERLAPPED);
        ov.hEvent = self.write_event;
        _ = ResetEvent(self.write_event);

        if (kernel32.WriteFile(
            self.pipe,
            bytes.ptr,
            @intCast(bytes.len),
            null,
            &ov,
        ) == 0) {
            switch (windows.GetLastError()) {
                .IO_PENDING => {},
                else => return error.WriteFailed,
            }
        }
        var n: windows.DWORD = 0;
        if (GetOverlappedResult(self.pipe, &ov, &n, windows.TRUE) == 0) {
            return error.WriteFailed;
        }
        if (n != bytes.len) return error.WriteFailed;
    }
};

// ---------------------------------------------------------------------------
// Tests: protocol layer
// ---------------------------------------------------------------------------

test "ipc: framer splits multiple lines in one chunk" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    try framer.feed(alloc, "{\"a\":1}\n{\"b\":2}\n");
    try testing.expectEqualStrings("{\"a\":1}", framer.next().?);
    try testing.expectEqualStrings("{\"b\":2}", framer.next().?);
    try testing.expect(framer.next() == null);
}

test "ipc: framer accumulates partial chunks" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    try framer.feed(alloc, "{\"id\":1,");
    try testing.expect(framer.next() == null);
    try framer.feed(alloc, "\"cmd\":\"open\"}");
    try testing.expect(framer.next() == null);
    try framer.feed(alloc, "\n{\"id\":2}\n{");
    try testing.expectEqualStrings("{\"id\":1,\"cmd\":\"open\"}", framer.next().?);
    try testing.expectEqualStrings("{\"id\":2}", framer.next().?);
    try testing.expect(framer.next() == null);
    try framer.feed(alloc, "}\n");
    try testing.expectEqualStrings("{}", framer.next().?);
}

test "ipc: framer strips CRLF line endings" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    try framer.feed(alloc, "a\r\nb\n\r\n");
    try testing.expectEqualStrings("a", framer.next().?);
    try testing.expectEqualStrings("b", framer.next().?);
    try testing.expectEqualStrings("", framer.next().?);
    try testing.expect(framer.next() == null);
}

test "ipc: framer rejects oversized lines" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    const big = try alloc.alloc(u8, max_line_bytes + 1);
    defer alloc.free(big);
    @memset(big, 'a');
    try testing.expectError(error.MessageTooLong, framer.feed(alloc, big));
}

test "ipc: parse request round-trips id, cmd, and args" {
    const result = try parseLine(
        testing.allocator,
        "{\"id\":42,\"cmd\":\"open\",\"args\":{\"url\":\"https://example.com\"}}",
    );
    const req = result.ok;
    defer req.destroy();

    try testing.expectEqual(@as(u64, 42), req.id);
    try testing.expectEqual(Command.open, req.cmd);
    try testing.expectEqualStrings(
        "https://example.com",
        req.args.object.get("url").?.string,
    );
}

test "ipc: parse request without args" {
    const result = try parseLine(
        testing.allocator,
        "{\"id\":1,\"cmd\":\"snapshot\"}",
    );
    const req = result.ok;
    defer req.destroy();

    try testing.expectEqual(@as(u64, 1), req.id);
    try testing.expectEqual(Command.snapshot, req.cmd);
    try testing.expectEqual(std.json.Value.null, req.args);
}

test "ipc: parse bad JSON yields parse_error with id 0" {
    const result = try parseLine(testing.allocator, "{\"id\":3,, nope");
    try testing.expectEqual(ErrorCode.parse_error, result.err.code);
    try testing.expectEqual(@as(u64, 0), result.err.id);
}

test "ipc: parse non-object yields invalid_request" {
    const result = try parseLine(testing.allocator, "[1,2,3]");
    try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
}

test "ipc: parse missing or malformed id yields invalid_request" {
    {
        const result = try parseLine(testing.allocator, "{\"cmd\":\"open\"}");
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
        try testing.expectEqual(@as(u64, 0), result.err.id);
    }
    {
        const result = try parseLine(
            testing.allocator,
            "{\"id\":\"seven\",\"cmd\":\"open\"}",
        );
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
    }
    {
        const result = try parseLine(
            testing.allocator,
            "{\"id\":-1,\"cmd\":\"open\"}",
        );
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
    }
}

test "ipc: parse unknown cmd preserves the request id" {
    const result = try parseLine(
        testing.allocator,
        "{\"id\":7,\"cmd\":\"frobnicate\"}",
    );
    try testing.expectEqual(ErrorCode.unknown_command, result.err.code);
    try testing.expectEqual(@as(u64, 7), result.err.id);
}

test "ipc: parse non-object args yields invalid_request" {
    const result = try parseLine(
        testing.allocator,
        "{\"id\":1,\"cmd\":\"open\",\"args\":4}",
    );
    try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
    try testing.expectEqual(@as(u64, 1), result.err.id);
}

test "ipc: serialize ok response" {
    const out = try serializeOk(testing.allocator, 5, "{\"title\":\"hi\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"id\":5,\"ok\":true,\"data\":{\"title\":\"hi\"}}\n",
        out,
    );
}

test "ipc: serialize ok response without data" {
    const out = try serializeOk(testing.allocator, 12, null);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"id\":12,\"ok\":true,\"data\":null}\n", out);
}

test "ipc: serialize error response escapes the message" {
    const out = try serializeError(testing.allocator, 0, "bad \"quote\"\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"id\":0,\"ok\":false,\"error\":\"bad \\\"quote\\\"\\n\"}\n",
        out,
    );
}

test "ipc: response id round-trips through JSON" {
    const alloc = testing.allocator;
    const out = try serializeOk(alloc, 4294967295, "true");
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        // Strip the trailing newline; it's framing, not JSON.
        std.mem.trimRight(u8, out, "\n"),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqual(
        @as(i64, 4294967295),
        parsed.value.object.get("id").?.integer,
    );
    try testing.expect(parsed.value.object.get("ok").?.bool);
    try testing.expect(parsed.value.object.get("data").?.bool);
}

test "ipc: framer reassembles a request fed one byte at a time" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    const wire = "{\"id\":9,\"cmd\":\"eval\"}\r\n";
    for (wire, 0..) |byte, i| {
        try framer.feed(alloc, &.{byte});
        if (i < wire.len - 1) try testing.expect(framer.next() == null);
    }
    try testing.expectEqualStrings("{\"id\":9,\"cmd\":\"eval\"}", framer.next().?);
    try testing.expect(framer.next() == null);
}

test "ipc: framer accepts a line exactly at the cap" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    // max_line_bytes - 1 content bytes + "\n" buffers exactly
    // max_line_bytes, the largest frame feed() admits.
    const content = try alloc.alloc(u8, max_line_bytes - 1);
    defer alloc.free(content);
    @memset(content, 'x');
    try framer.feed(alloc, content);
    try testing.expect(framer.next() == null);
    try framer.feed(alloc, "\n");
    const line = framer.next().?;
    try testing.expectEqual(max_line_bytes - 1, line.len);
    try testing.expectEqual(@as(u8, 'x'), line[0]);
    try testing.expectEqual(@as(u8, 'x'), line[line.len - 1]);
    try testing.expect(framer.next() == null);
}

test "ipc: framer rejects one byte over the cap across feeds" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    // Fill to exactly the cap without a newline; the line can never be
    // completed because even its own terminator pushes it over.
    const half = try alloc.alloc(u8, max_line_bytes / 2);
    defer alloc.free(half);
    @memset(half, 'y');
    try framer.feed(alloc, half);
    try framer.feed(alloc, half);
    try testing.expectError(error.MessageTooLong, framer.feed(alloc, "\n"));
}

test "ipc: framer cap applies to the pending line, not the connection" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    // Two back-to-back maximum-size lines: consuming the first must
    // compact the buffer so the second doesn't trip the cap.
    const content = try alloc.alloc(u8, max_line_bytes - 1);
    defer alloc.free(content);
    @memset(content, 'z');
    try framer.feed(alloc, content);
    try framer.feed(alloc, "\n");
    try testing.expectEqual(max_line_bytes - 1, framer.next().?.len);
    try framer.feed(alloc, content);
    try framer.feed(alloc, "\n");
    try testing.expectEqual(max_line_bytes - 1, framer.next().?.len);
    try testing.expect(framer.next() == null);
}

test "ipc: framer mixes LF and CRLF endings in one chunk" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    try framer.feed(alloc, "a\nbb\r\n\nccc\r\n\r\n d \n");
    try testing.expectEqualStrings("a", framer.next().?);
    try testing.expectEqualStrings("bb", framer.next().?);
    try testing.expectEqualStrings("", framer.next().?);
    try testing.expectEqualStrings("ccc", framer.next().?);
    try testing.expectEqualStrings("", framer.next().?);
    try testing.expectEqualStrings(" d ", framer.next().?);
    try testing.expect(framer.next() == null);
}

test "ipc: framer handles CRLF split across feeds" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    try framer.feed(alloc, "first\r");
    try testing.expect(framer.next() == null);
    try framer.feed(alloc, "\nsecond\n");
    try testing.expectEqualStrings("first", framer.next().?);
    try testing.expectEqualStrings("second", framer.next().?);
    try testing.expect(framer.next() == null);
}

test "ipc: framer treats CR as data except immediately before LF" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    // Interior CR is payload; only the CR of a final CRLF is stripped,
    // and at most one of them.
    try framer.feed(alloc, "a\rb\nc\r\r\n\r\n");
    try testing.expectEqualStrings("a\rb", framer.next().?);
    try testing.expectEqualStrings("c\r", framer.next().?);
    try testing.expectEqualStrings("", framer.next().?);
    try testing.expect(framer.next() == null);
}

test "ipc: framer survives many messages through compaction" {
    const alloc = testing.allocator;
    var framer: LineFramer = .{};
    defer framer.deinit(alloc);

    var wire_buf: [32]u8 = undefined;
    var expected_buf: [32]u8 = undefined;
    for (0..200) |i| {
        const wire = try std.fmt.bufPrint(&wire_buf, "{{\"id\":{d}}}\n", .{i});
        // Split each message across two feeds so a partial tail sits in
        // the buffer at every compaction.
        try framer.feed(alloc, wire[0 .. wire.len / 2]);
        try testing.expect(framer.next() == null);
        try framer.feed(alloc, wire[wire.len / 2 ..]);
        const expected = try std.fmt.bufPrint(&expected_buf, "{{\"id\":{d}}}", .{i});
        try testing.expectEqualStrings(expected, framer.next().?);
        try testing.expect(framer.next() == null);
    }
}

test "ipc: parse accepts every command name" {
    const alloc = testing.allocator;
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        const line = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":1,\"cmd\":\"{s}\"}}",
            .{field.name},
        );
        defer alloc.free(line);
        const result = try parseLine(alloc, line);
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqual(@field(Command, field.name), req.cmd);
    }
}

test "ipc: parse id boundaries" {
    const alloc = testing.allocator;
    // id 0 is accepted (it doubles as the unrecoverable-id sentinel in
    // responses, but the protocol does not reserve it).
    {
        const result = try parseLine(alloc, "{\"id\":0,\"cmd\":\"open\"}");
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqual(@as(u64, 0), req.id);
    }
    // Largest JSON integer std.json yields as .integer (i64 max).
    {
        const result = try parseLine(
            alloc,
            "{\"id\":9223372036854775807,\"cmd\":\"open\"}",
        );
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqual(@as(u64, 9223372036854775807), req.id);
    }
    // Beyond i64: std.json yields .number_string, not .integer.
    {
        const result = try parseLine(
            alloc,
            "{\"id\":18446744073709551615,\"cmd\":\"open\"}",
        );
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
        try testing.expectEqual(@as(u64, 0), result.err.id);
    }
    // Fractional id.
    {
        const result = try parseLine(alloc, "{\"id\":1.5,\"cmd\":\"open\"}");
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
    }
    // Boolean id.
    {
        const result = try parseLine(alloc, "{\"id\":true,\"cmd\":\"open\"}");
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
    }
}

test "ipc: parse duplicate keys is a parse error" {
    // std.json's default duplicate_field_behavior is .@"error", which
    // parseLine reports as parse_error; no object ever materializes, so
    // the id cannot be recovered.
    const result = try parseLine(
        testing.allocator,
        "{\"id\":1,\"id\":2,\"cmd\":\"open\"}",
    );
    try testing.expectEqual(ErrorCode.parse_error, result.err.code);
    try testing.expectEqual(@as(u64, 0), result.err.id);
}

test "ipc: parse missing or malformed cmd preserves the recovered id" {
    {
        const result = try parseLine(testing.allocator, "{\"id\":9}");
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
        try testing.expectEqual(@as(u64, 9), result.err.id);
    }
    {
        const result = try parseLine(
            testing.allocator,
            "{\"id\":11,\"cmd\":42}",
        );
        try testing.expectEqual(ErrorCode.invalid_request, result.err.code);
        try testing.expectEqual(@as(u64, 11), result.err.id);
    }
}

test "ipc: parse tolerates unknown extra fields" {
    const result = try parseLine(
        testing.allocator,
        "{\"id\":3,\"cmd\":\"click\",\"args\":{\"ref\":7,\"hover\":true},\"trace\":\"x\"}",
    );
    const req = result.ok;
    defer req.destroy();
    try testing.expectEqual(@as(u64, 3), req.id);
    try testing.expectEqual(Command.click, req.cmd);
    try testing.expectEqual(@as(i64, 7), argI64(req, "ref").?);
    // Unknown args keys ride along untouched for the handler to ignore.
    try testing.expect(req.args.object.get("hover").?.bool);
}

test "ipc: parse explicit null args" {
    const result = try parseLine(
        testing.allocator,
        "{\"id\":2,\"cmd\":\"snapshot\",\"args\":null}",
    );
    const req = result.ok;
    defer req.destroy();
    try testing.expectEqual(std.json.Value.null, req.args);
    // snapshot's optional pane address is simply absent.
    try testing.expect(argId(req) == null);
}

test "ipc: click arg validation via argI64" {
    const alloc = testing.allocator;
    // Missing ref → null (App answers MissingRef).
    {
        const result = try parseLine(
            alloc,
            "{\"id\":1,\"cmd\":\"click\",\"args\":{}}",
        );
        const req = result.ok;
        defer req.destroy();
        try testing.expect(argI64(req, "ref") == null);
    }
    // ref must be an integer, not a numeric string.
    {
        const result = try parseLine(
            alloc,
            "{\"id\":1,\"cmd\":\"click\",\"args\":{\"ref\":\"12\"}}",
        );
        const req = result.ok;
        defer req.destroy();
        try testing.expect(argI64(req, "ref") == null);
    }
    // No args object at all.
    {
        const result = try parseLine(alloc, "{\"id\":1,\"cmd\":\"click\"}");
        const req = result.ok;
        defer req.destroy();
        try testing.expect(argI64(req, "ref") == null);
    }
    // Valid; argI64 passes any i64 through, including negatives.
    {
        const result = try parseLine(
            alloc,
            "{\"id\":1,\"cmd\":\"click\",\"args\":{\"ref\":-3}}",
        );
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqual(@as(i64, -3), argI64(req, "ref").?);
    }
}

test "ipc: fill arg validation via argI64 and argString" {
    const alloc = testing.allocator;
    // Missing text → null (App answers MissingText).
    {
        const result = try parseLine(
            alloc,
            "{\"id\":4,\"cmd\":\"fill\",\"args\":{\"ref\":7}}",
        );
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqual(@as(i64, 7), argI64(req, "ref").?);
        try testing.expect(argString(req, "text") == null);
    }
    // text must be a string.
    {
        const result = try parseLine(
            alloc,
            "{\"id\":4,\"cmd\":\"fill\",\"args\":{\"ref\":7,\"text\":42}}",
        );
        const req = result.ok;
        defer req.destroy();
        try testing.expect(argString(req, "text") == null);
    }
    // Fully valid fill with non-ASCII text via a JSON unicode escape.
    {
        const result = try parseLine(
            alloc,
            "{\"id\":4,\"cmd\":\"fill\",\"args\":{\"ref\":7,\"text\":\"Col\\u00f3n\"}}",
        );
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqualStrings("Colón", argString(req, "text").?);
    }
}

test "ipc: argId validates the optional pane address" {
    const alloc = testing.allocator;
    const Case = struct { line: []const u8, expect: ?u32 };
    const cases = [_]Case{
        .{ .line = "{\"id\":1,\"cmd\":\"eval\",\"args\":{\"id\":0}}", .expect = 0 },
        .{ .line = "{\"id\":1,\"cmd\":\"eval\",\"args\":{\"id\":4294967295}}", .expect = 4294967295 },
        .{ .line = "{\"id\":1,\"cmd\":\"eval\",\"args\":{\"id\":4294967296}}", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"eval\",\"args\":{\"id\":-1}}", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"eval\",\"args\":{\"id\":\"3\"}}", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"eval\",\"args\":{}}", .expect = null },
    };
    for (cases) |case| {
        const result = try parseLine(alloc, case.line);
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqual(case.expect, argId(req));
    }
}

test "ipc: argU32 reads named index fields, rejecting out-of-range" {
    const alloc = testing.allocator;
    const Case = struct { line: []const u8, key: []const u8, expect: ?u32 };
    const cases = [_]Case{
        // index 0 is a valid workspace/tab address (unlike a missing key).
        .{ .line = "{\"id\":1,\"cmd\":\"workspace-select\",\"args\":{\"index\":0}}", .key = "index", .expect = 0 },
        .{ .line = "{\"id\":1,\"cmd\":\"workspace-select\",\"args\":{\"index\":3}}", .key = "index", .expect = 3 },
        .{ .line = "{\"id\":1,\"cmd\":\"tab-new\",\"args\":{\"workspace\":4294967295}}", .key = "workspace", .expect = 4294967295 },
        .{ .line = "{\"id\":1,\"cmd\":\"tab-new\",\"args\":{\"workspace\":4294967296}}", .key = "workspace", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"send\",\"args\":{\"tab\":-1}}", .key = "tab", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"send\",\"args\":{\"tab\":1.5}}", .key = "tab", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"send\",\"args\":{\"tab\":\"2\"}}", .key = "tab", .expect = null },
        // A different key than the one present → null.
        .{ .line = "{\"id\":1,\"cmd\":\"tab-new\",\"args\":{\"workspace\":2}}", .key = "tab", .expect = null },
        // No args object at all.
        .{ .line = "{\"id\":1,\"cmd\":\"workspace-list\"}", .key = "index", .expect = null },
    };
    for (cases) |case| {
        const result = try parseLine(alloc, case.line);
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqual(case.expect, argU32(req, case.key));
    }
}

test "ipc: argBool reads the optional enter flag" {
    const alloc = testing.allocator;
    const Case = struct { line: []const u8, expect: ?bool };
    const cases = [_]Case{
        .{ .line = "{\"id\":1,\"cmd\":\"send\",\"args\":{\"enter\":true}}", .expect = true },
        .{ .line = "{\"id\":1,\"cmd\":\"send\",\"args\":{\"enter\":false}}", .expect = false },
        // Missing → null (handler defaults to no CR).
        .{ .line = "{\"id\":1,\"cmd\":\"send\",\"args\":{\"text\":\"x\"}}", .expect = null },
        // Wrong type → null.
        .{ .line = "{\"id\":1,\"cmd\":\"send\",\"args\":{\"enter\":1}}", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"send\",\"args\":{\"enter\":\"true\"}}", .expect = null },
        // No args object at all.
        .{ .line = "{\"id\":1,\"cmd\":\"send\"}", .expect = null },
    };
    for (cases) |case| {
        const result = try parseLine(alloc, case.line);
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqual(case.expect, argBool(req, "enter"));
    }
}

test "ipc: argU64 reads a full-range surface id" {
    const alloc = testing.allocator;
    const Case = struct { line: []const u8, expect: ?u64 };
    const cases = [_]Case{
        .{ .line = "{\"id\":1,\"cmd\":\"surface-focus\",\"args\":{\"surface\":1}}", .expect = 1 },
        // i64 max arrives as .integer.
        .{ .line = "{\"id\":1,\"cmd\":\"surface-focus\",\"args\":{\"surface\":9223372036854775807}}", .expect = 9223372036854775807 },
        // Beyond i64: std.json yields .number_string; argU64 still parses it.
        .{ .line = "{\"id\":1,\"cmd\":\"surface-focus\",\"args\":{\"surface\":18446744073709551615}}", .expect = 18446744073709551615 },
        // Negative / fractional / string-typed / absent -> null.
        .{ .line = "{\"id\":1,\"cmd\":\"surface-focus\",\"args\":{\"surface\":-1}}", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"surface-focus\",\"args\":{\"surface\":1.5}}", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"surface-focus\",\"args\":{\"surface\":\"7\"}}", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"surface-focus\",\"args\":{}}", .expect = null },
    };
    for (cases) |case| {
        const result = try parseLine(alloc, case.line);
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqual(case.expect, argU64(req, "surface"));
    }
}

test "ipc: argI64Named reads progress including the -1 clear sentinel" {
    const alloc = testing.allocator;
    const Case = struct { line: []const u8, expect: ?i64 };
    const cases = [_]Case{
        .{ .line = "{\"id\":1,\"cmd\":\"set-progress\",\"args\":{\"value\":0}}", .expect = 0 },
        .{ .line = "{\"id\":1,\"cmd\":\"set-progress\",\"args\":{\"value\":100}}", .expect = 100 },
        .{ .line = "{\"id\":1,\"cmd\":\"set-progress\",\"args\":{\"value\":-1}}", .expect = -1 },
        .{ .line = "{\"id\":1,\"cmd\":\"set-progress\",\"args\":{\"value\":\"x\"}}", .expect = null },
        .{ .line = "{\"id\":1,\"cmd\":\"set-progress\",\"args\":{}}", .expect = null },
    };
    for (cases) |case| {
        const result = try parseLine(alloc, case.line);
        const req = result.ok;
        defer req.destroy();
        try testing.expectEqual(case.expect, argI64Named(req, "value"));
    }
}

test "ipc: LogRing newest-first, wraps, and truncates" {
    var ring: LogRing = .{};
    try testing.expect(ring.latest() == null);
    try testing.expect(ring.at(0) == null);

    ring.push("first");
    ring.push("second");
    try testing.expectEqualStrings("second", ring.latest().?);
    try testing.expectEqualStrings("second", ring.at(0).?);
    try testing.expectEqualStrings("first", ring.at(1).?);
    try testing.expect(ring.at(2) == null);

    // Fill past capacity; the oldest drops, newest-first order holds.
    for (0..log_ring_capacity) |i| {
        var buf: [8]u8 = undefined;
        ring.push(std.fmt.bufPrint(&buf, "L{d}", .{i}) catch unreachable);
    }
    try testing.expectEqual(log_ring_capacity, ring.len);
    var ebuf: [8]u8 = undefined;
    const newest = std.fmt.bufPrint(&ebuf, "L{d}", .{log_ring_capacity - 1}) catch unreachable;
    try testing.expectEqualStrings(newest, ring.latest().?);

    // Over-long line is byte-truncated to the cap.
    const big = [_]u8{'x'} ** (max_log_line_bytes + 50);
    ring.push(&big);
    try testing.expectEqual(@as(usize, max_log_line_bytes), ring.latest().?.len);

    ring.clear();
    try testing.expectEqual(@as(usize, 0), ring.len);
    try testing.expect(ring.latest() == null);
}

test "ipc: send arg validation via argString/argU32/argBool" {
    const alloc = testing.allocator;
    // A fully-specified send: text + workspace + tab + enter all present.
    const result = try parseLine(
        alloc,
        "{\"id\":5,\"cmd\":\"send\",\"args\":{\"text\":\"echo hi\",\"workspace\":1,\"tab\":0,\"enter\":true}}",
    );
    const req = result.ok;
    defer req.destroy();
    try testing.expectEqual(Command.send, req.cmd);
    try testing.expectEqualStrings("echo hi", argString(req, "text").?);
    try testing.expectEqual(@as(u32, 1), argU32(req, "workspace").?);
    try testing.expectEqual(@as(u32, 0), argU32(req, "tab").?);
    try testing.expect(argBool(req, "enter").?);
}

// ---------------------------------------------------------------------------
// Tests: worktree path construction + branch sanitization
// ---------------------------------------------------------------------------

test "ipc: validateBranch accepts ordinary branch names" {
    try testing.expectEqualStrings("feature-x", try validateBranch("feature-x"));
    try testing.expectEqualStrings("v1.2.3", try validateBranch("v1.2.3"));
    try testing.expectEqualStrings("fix_42", try validateBranch("fix_42"));
    // Surrounding whitespace is trimmed.
    try testing.expectEqualStrings("trim-me", try validateBranch("  trim-me\t"));
}

test "ipc: validateBranch rejects empty and whitespace-only names" {
    try testing.expectError(error.EmptyBranch, validateBranch(""));
    try testing.expectError(error.EmptyBranch, validateBranch("   "));
    try testing.expectError(error.EmptyBranch, validateBranch("\t\n "));
}

test "ipc: validateBranch rejects path traversal and separators" {
    // The headline attack: escape .worktrees via "..".
    try testing.expectError(error.UnsafeBranch, validateBranch("../x"));
    try testing.expectError(error.UnsafeBranch, validateBranch(".."));
    try testing.expectError(error.UnsafeBranch, validateBranch("a/../../b"));
    try testing.expectError(error.UnsafeBranch, validateBranch("..\\evil"));
    // A lone "." is not a usable directory name either.
    try testing.expectError(error.UnsafeBranch, validateBranch("."));
    // Any separator is refused (we keep a single flat .worktrees dir).
    try testing.expectError(error.UnsafeBranch, validateBranch("feature/x"));
    try testing.expectError(error.UnsafeBranch, validateBranch("a\\b"));
    // Windows drive / alternate-data-stream marker.
    try testing.expectError(error.UnsafeBranch, validateBranch("C:evil"));
    // ".." embedded without a separator on each side is still traversal.
    try testing.expectError(error.UnsafeBranch, validateBranch("a..b"));
}

test "ipc: validateBranch rejects an over-long name" {
    const long = [_]u8{'a'} ** (max_worktree_name + 1);
    try testing.expectError(error.BranchTooLong, validateBranch(&long));
    // Exactly at the cap is fine.
    const at_cap = [_]u8{'a'} ** max_worktree_name;
    try testing.expectEqualStrings(&at_cap, try validateBranch(&at_cap));
}

test "ipc: sanitizeBranchName maps display-hostile bytes to dashes" {
    var buf: [max_worktree_name]u8 = undefined;
    // Spaces, punctuation → '-'; alnum/-/_/. pass through.
    try testing.expectEqualStrings("a-b-c", sanitizeBranchName("a b c", &buf));
    try testing.expectEqualStrings("v1.2.3", sanitizeBranchName("v1.2.3", &buf));
    try testing.expectEqualStrings("keep_me-", sanitizeBranchName("keep_me!", &buf));
    // A name that's already clean is unchanged.
    try testing.expectEqualStrings("feature-x", sanitizeBranchName("feature-x", &buf));
}

test "ipc: worktreePath joins repo/.worktrees/<sanitized>" {
    const alloc = testing.allocator;
    const branch = try validateBranch("feature x");
    const path = try worktreePath(alloc, "C:\\repos\\app", branch);
    defer alloc.free(path);
    // std.fs.path.join normalizes to the host separator (backslash on
    // Windows); assert the tail components regardless of separator style.
    try testing.expect(std.mem.endsWith(u8, path, "feature-x"));
    try testing.expect(std.mem.indexOf(u8, path, ".worktrees") != null);
    try testing.expect(std.mem.startsWith(u8, path, "C:\\repos\\app"));
}

test "ipc: worktreePath round-trips a clean branch" {
    const alloc = testing.allocator;
    const branch = try validateBranch("v1.2.3");
    const path = try worktreePath(alloc, "/home/me/proj", branch);
    defer alloc.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "v1.2.3"));
    try testing.expect(std.mem.indexOf(u8, path, ".worktrees") != null);
}

test "ipc: every error code has a JSON-safe message" {
    const alloc = testing.allocator;
    inline for (@typeInfo(ErrorCode).@"enum".fields) |field| {
        const code: ErrorCode = @enumFromInt(field.value);
        const msg = code.message();
        try testing.expect(msg.len > 0);

        // The message must survive serializeError → JSON parse intact
        // (invalid_request's message contains embedded quotes).
        const out = try serializeError(alloc, 1, msg);
        defer alloc.free(out);
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            alloc,
            std.mem.trimRight(u8, out, "\n"),
            .{},
        );
        defer parsed.deinit();
        try testing.expectEqualStrings(
            msg,
            parsed.value.object.get("error").?.string,
        );
        try testing.expect(!parsed.value.object.get("ok").?.bool);
    }
}

test "ipc: serializeError escapes backslashes, control chars, and non-ASCII" {
    const alloc = testing.allocator;
    const msg = "path C:\\Users\\Colón\x01\ttab \"q\"";
    const out = try serializeError(alloc, 6, msg);
    defer alloc.free(out);

    // Exactly one frame: the only newline byte is the trailing frame
    // terminator, so the embedded control characters were escaped.
    try testing.expectEqual(out.len - 1, std.mem.indexOfScalar(u8, out, '\n').?);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        std.mem.trimRight(u8, out, "\n"),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings(msg, parsed.value.object.get("error").?.string);
    try testing.expectEqual(@as(i64, 6), parsed.value.object.get("id").?.integer);
}

test "ipc: serializeOk passes data through verbatim" {
    const alloc = testing.allocator;
    // data_json is already-serialized JSON: serializeOk must not
    // re-escape its backslashes or unicode escapes.
    const data = "{\"path\":\"C:\\\\Users\\\\Col\\u00f3n\",\"n\":[1,2]}";
    const out = try serializeOk(alloc, 0, data);
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "{\"id\":0,\"ok\":true,\"data\":{\"path\":\"C:\\\\Users\\\\Col\\u00f3n\",\"n\":[1,2]}}\n",
        out,
    );

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        std.mem.trimRight(u8, out, "\n"),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "C:\\Users\\Colón",
        parsed.value.object.get("data").?.object.get("path").?.string,
    );
}

test "ipc: serialize preserves ids beyond i64 range" {
    const alloc = testing.allocator;
    const out = try serializeError(alloc, std.math.maxInt(u64), "x");
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "{\"id\":18446744073709551615,\"ok\":false,\"error\":\"x\"}\n",
        out,
    );
}

test "ipc: recoverable parse failures keep the id through serializeError" {
    const alloc = testing.allocator;
    // The id is recoverable here: well-formed envelope, bad command.
    const result = try parseLine(alloc, "{\"id\":88,\"cmd\":\"explode\"}");
    const failure = result.err;
    try testing.expectEqual(@as(u64, 88), failure.id);
    try testing.expectEqual(ErrorCode.unknown_command, failure.code);

    // Serialize it the way Server.dispatchLine answers.
    const out = try serializeError(alloc, failure.id, failure.code.message());
    defer alloc.free(out);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        std.mem.trimRight(u8, out, "\n"),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 88), parsed.value.object.get("id").?.integer);
    try testing.expect(!parsed.value.object.get("ok").?.bool);
    try testing.expectEqualStrings(
        ErrorCode.unknown_command.message(),
        parsed.value.object.get("error").?.string,
    );
}

// ---------------------------------------------------------------------------
// Tests: end-to-end over a real named pipe (Windows only)
// ---------------------------------------------------------------------------

test "ipc: end-to-end request and response over a named pipe" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buf,
        "ghostty-ipc-test-{d}",
        .{windows.GetCurrentProcessId()},
    );

    const TestCtx = struct {
        server: ?*Server = null,

        fn onRequest(ctx_ptr: ?*anyopaque, req: *Request) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            const server = ctx.server.?;
            defer req.destroy();
            if (req.cmd != .open) {
                server.sendError(req.id, "expected open") catch {};
                return;
            }
            server.sendOk(req.id, "\"opened\"") catch {};
        }
    };
    var ctx: TestCtx = .{};

    const server = try Server.start(alloc, name, TestCtx.onRequest, &ctx);
    defer server.stop();
    // Safe: no client can connect (and thus no callback can fire)
    // until we CreateFileW below.
    ctx.server = server;

    // --- client side, plain synchronous CreateFileW like the CLI ---
    const path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\{s}", .{name});
    defer alloc.free(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);

    const client = kernel32.CreateFileW(
        path_w.ptr,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );
    try testing.expect(client != windows.INVALID_HANDLE_VALUE);
    defer windows.CloseHandle(client);

    var framer: LineFramer = .{};
    defer framer.deinit(alloc);
    var read_buf: [1024]u8 = undefined;

    // Round 1: valid request → ok response with data.
    {
        const request =
            "{\"id\":7,\"cmd\":\"open\",\"args\":{\"url\":\"https://example.com\"}}\n";
        var written: windows.DWORD = 0;
        try testing.expect(kernel32.WriteFile(
            client,
            request.ptr,
            request.len,
            &written,
            null,
        ) != 0);
        try testing.expectEqual(@as(windows.DWORD, request.len), written);

        const line = line: while (true) {
            var n: windows.DWORD = 0;
            try testing.expect(kernel32.ReadFile(
                client,
                @ptrCast(&read_buf),
                read_buf.len,
                &n,
                null,
            ) != 0);
            try framer.feed(alloc, read_buf[0..n]);
            if (framer.next()) |l| break :line l;
        };

        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        try testing.expectEqual(@as(i64, 7), parsed.value.object.get("id").?.integer);
        try testing.expect(parsed.value.object.get("ok").?.bool);
        try testing.expectEqualStrings(
            "opened",
            parsed.value.object.get("data").?.string,
        );
    }

    // Round 2: malformed JSON → in-band error response from the server.
    {
        const request = "this is not json\n";
        var written: windows.DWORD = 0;
        try testing.expect(kernel32.WriteFile(
            client,
            request.ptr,
            request.len,
            &written,
            null,
        ) != 0);

        const line = line: while (true) {
            if (framer.next()) |l| break :line l;
            var n: windows.DWORD = 0;
            try testing.expect(kernel32.ReadFile(
                client,
                @ptrCast(&read_buf),
                read_buf.len,
                &n,
                null,
            ) != 0);
            try framer.feed(alloc, read_buf[0..n]);
        };

        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        try testing.expectEqual(@as(i64, 0), parsed.value.object.get("id").?.integer);
        try testing.expect(!parsed.value.object.get("ok").?.bool);
        try testing.expectEqualStrings(
            ErrorCode.parse_error.message(),
            parsed.value.object.get("error").?.string,
        );
    }
}

test "ipc: stop unblocks a pending read while a client is connected" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buf,
        "ghostty-ipc-stoptest-{d}",
        .{windows.GetCurrentProcessId()},
    );

    const handler = struct {
        fn onRequest(ctx: ?*anyopaque, req: *Request) void {
            _ = ctx;
            req.destroy();
        }
    };

    const server = try Server.start(alloc, name, handler.onRequest, null);

    const path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\{s}", .{name});
    defer alloc.free(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);

    const client = kernel32.CreateFileW(
        path_w.ptr,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );
    try testing.expect(client != windows.INVALID_HANDLE_VALUE);
    defer windows.CloseHandle(client);

    // Give the pipe thread time to park inside the overlapped ReadFile
    // wait, then stop with the client still attached. stop() must not
    // hang: the stop event + CancelIoEx aborts the pending read.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    server.stop();
}
