//! Legacy wmux-v1 JSON protocol: the pure parse / serialize / framing
//! layer of the agent-control named pipe (`wmux +browser ...`,
//! `wmux +workspace|+tab|+send ...`). No OS dependencies, unit-tested on
//! any target. The pipe transport lives in `rpc/server/legacy_pipe.zig`.
//!
//! Wire protocol: newline-delimited JSON over a message-type named pipe
//! at \\.\pipe\wmux-ipc-<pid>.
//!
//!   request:  {"id":1,"cmd":"open","args":{"url":"https://..."}}\n
//!   response: {"id":1,"ok":true,"data":...}\n
//!             {"id":1,"ok":false,"error":"..."}\n
//!
//! Moved out of `ipc.zig` in W0-A1 (ARCHITECTURE.md ADR-1.8, ADR-3.7).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

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

    // Workspace / tab / keystroke scripting.  Tab commands operate on
    // the focused PaneContainer (split-tree leaf) of the addressed
    // workspace; an optional "pane" arg overrides with a container index.
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
    // [workspace], [tab], [pane]}.
    notify,

    // Orchestration scripting (the agent-supervises-agent substrate). All
    // run synchronously on the GUI thread and reply directly, like the
    // workspace/tab verbs (they touch the live model). Indices follow the
    // same defaulting as send/notify (absent workspace/tab/pane => active).
    // All accept an optional "pane" arg to address a specific PaneContainer
    // by split-tree leaf index instead of the focused container.
    //
    // surface-list {[workspace]} -> JSON of every tab in every
    //   PaneContainer of the addressed workspace:
    //   [{pane, tab, id, type:"terminal"|"browser", focused, title}].
    // surface-focus {surface | (workspace,pane,[tab])} -> focus a surface
    //   by its stable id, or by workspace/pane(container)/tab index.
    // new-split {dir:"right"|"down"|"left"|"up", [workspace],[pane],
    //   [command]} -> split the addressed container; reply {id} of new pane.
    // set-status {[workspace],[tab],[pane], [text]} -> set/clear a per-tab
    //   status string the sidebar renders (empty/absent text clears it).
    // set-progress {[workspace],[tab],[pane], value:0..100|-1} -> set a
    //   per-tab progress percent; -1 (or "clear") clears it.
    // log {[workspace],[tab],[pane], text} -> append a line to the addressed
    //   tab's ring log buffer (and the global notif panel).
    // read-screen {[workspace],[tab],[pane],[lines],[scrollback]} -> the
    //   addressed pane terminal's screen text as UTF-8 (visible screen, or
    //   full scrollback when scrollback:true). THE agent-reads-agent verb.
    @"surface-list",
    @"surface-focus",
    @"new-split",
    @"swap-split",
    @"set-status",
    @"set-progress",
    log,
    @"read-screen",

    // capture-pane {[workspace],[tab],[pane],[scrollback:bool],[file:path]}
    //   -> dump the addressed pane's screen text (visible or full scrollback)
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
    // "off", [workspace], [tab], [pane]}. Defaults to the active tab in
    // the focused PaneContainer.
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
