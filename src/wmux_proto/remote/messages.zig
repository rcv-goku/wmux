//! Param, result and event payloads of the wmuxd-remote methods (ADR-13),
//! plus hello negotiation and identifier rules. Field names are the wire keys.
//!
//! Model: a *session* is one PTY (shell process plus a bounded scrollback
//! ring). An *attachment* is one client's view of a session with its own
//! size; the PTY size is the minimum over attachments (smallest wins).
//! `session.attach` registers a size-only attachment; `pty.attach` also
//! streams output on a per-connection channel, starting with a replay of the
//! scrollback ring. PTY bytes in JSON are base64 (standard alphabet).

const std = @import("std");
const rpc = @import("rpc.zig");

/// Session ids, attachment ids and slot names: `[A-Za-z0-9._-]{1,128}`,
/// excluding `.` and `..` (they also name directories).
pub const max_name_len = 128;

pub fn isValidName(s: []const u8) bool {
    if (s.len == 0 or s.len > max_name_len) return false;
    if (std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Terminal sizes outside 1..max_dimension are rejected.
pub const max_dimension: u16 = 10_000;

pub fn isValidSize(cols: u32, rows: u32) bool {
    return cols >= 1 and rows >= 1 and cols <= max_dimension and rows <= max_dimension;
}

/// Max decoded bytes in one fs.put / fs.get.
pub const max_fs_bytes: usize = 16 * 1024 * 1024;
/// Max decoded bytes in one pty.write.
pub const max_pty_write: usize = 1024 * 1024;

pub const HelloParams = struct {
    protocol_version: u32,
    client: ?[]const u8 = null,
    client_version: ?[]const u8 = null,
    capabilities: []const []const u8 = &.{},
};

pub const HelloResult = struct {
    name: []const u8 = "wmuxd-remote",
    version: []const u8 = rpc.daemon_version,
    protocol_version: u32 = rpc.protocol_version,
    capabilities: []const []const u8,
    persistent: bool,
    slot: ?[]const u8 = null,
    pid: i64,
    /// True when PTY data will flow as binary frames on this connection.
    binary_frames: bool,
};

pub const Negotiated = struct {
    binary_frames: bool,
};

pub const NegotiateError = error{VersionMismatch};

/// Enforces the protocol version and picks per-connection options.
pub fn negotiate(p: HelloParams) NegotiateError!Negotiated {
    if (p.protocol_version != rpc.protocol_version) return error.VersionMismatch;
    var binary = false;
    for (p.capabilities) |c| {
        if (std.mem.eql(u8, c, rpc.cap_binary_frames)) binary = true;
    }
    return .{ .binary_frames = binary };
}

pub const PingResult = struct {
    pong: bool = true,
    time_ms: i64,
};

pub const SessionOpenParams = struct {
    /// Client-chosen id; generated when absent.
    session_id: ?[]const u8 = null,
    cols: u32 = 80,
    rows: u32 = 24,
    /// argv; the user's login shell when absent.
    command: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    /// Extra `NAME=value` entries added to the daemon's environment.
    env: []const []const u8 = &.{},
    /// Scrollback ring size; clamped by the daemon.
    scrollback_bytes: ?u32 = null,
};

pub const SessionOpenResult = struct {
    session_id: []const u8,
    pid: i64,
    cols: u32,
    rows: u32,
};

pub const SessionIdParams = struct {
    session_id: []const u8,
};

pub const AttachParams = struct {
    session_id: []const u8,
    cols: u32,
    rows: u32,
    /// pty.attach only: replay the scrollback ring before live output.
    replay: bool = true,
};

pub const AttachResult = struct {
    session_id: []const u8,
    attachment_id: []const u8,
    /// Effective PTY size after this attachment joined.
    cols: u32,
    rows: u32,
    /// pty.attach only: data channel and how many replay bytes follow.
    channel: ?u32 = null,
    replay_bytes: ?u64 = null,
    binary_frames: ?bool = null,
};

pub const ResizeParams = struct {
    attachment_id: []const u8,
    cols: u32,
    rows: u32,
};

pub const AttachmentIdParams = struct {
    attachment_id: []const u8,
};

pub const SizeResult = struct {
    session_id: []const u8,
    cols: u32,
    rows: u32,
    attachments: u32,
};

pub const PtyWriteParams = struct {
    session_id: []const u8,
    /// base64
    data: []const u8,
};

pub const PtyWriteResult = struct {
    bytes: u64,
};

pub const AttachmentInfo = struct {
    attachment_id: []const u8,
    cols: u32,
    rows: u32,
    streaming: bool,
};

pub const SessionInfo = struct {
    session_id: []const u8,
    pid: i64,
    alive: bool,
    cols: u32,
    rows: u32,
    attachments: u32,
    scrollback_bytes: u64,
    created_ms: i64,
    attachment_list: []const AttachmentInfo = &.{},
};

pub const PtyListResult = struct {
    sessions: []const SessionInfo,
};

pub const CloseResult = struct {
    session_id: []const u8,
    closed: bool = true,
};

pub const FsPutParams = struct {
    path: []const u8,
    /// base64; must decode to at least one byte.
    data: []const u8,
    /// File mode; 0o600 when absent.
    mode: ?u32 = null,
    /// Optional lowercase hex SHA-256 verified before the rename.
    sha256: ?[]const u8 = null,
    /// Create missing parent directories (0o700).
    mkdirs: bool = false,
};

pub const FsPutResult = struct {
    path: []const u8,
    size: u64,
    sha256: []const u8,
};

pub const FsGetParams = struct {
    path: []const u8,
    max_bytes: ?u64 = null,
};

pub const FsGetResult = struct {
    path: []const u8,
    size: u64,
    sha256: []const u8,
    /// base64
    data: []const u8,
};

/// Event `pty.data` (only when binary frames were not negotiated).
pub const PtyDataEvent = struct {
    channel: u32,
    session_id: []const u8,
    data: []const u8,
};

/// Event `pty.exit`: the session's process ended and the session is gone.
pub const PtyExitEvent = struct {
    session_id: []const u8,
    exit_code: ?i64 = null,
    signal: ?i64 = null,
};

/// Event `pty.detached`: the daemon dropped an attachment (session closed).
pub const PtyDetachedEvent = struct {
    session_id: []const u8,
    attachment_id: []const u8,
    reason: []const u8,
};

pub const event_pty_data = "pty.data";
pub const event_pty_exit = "pty.exit";
pub const event_pty_detached = "pty.detached";

const testing = std.testing;

test "unit: remote-protocol: names follow the slot/session charset" {
    try testing.expect(isValidName("default"));
    try testing.expect(isValidName("a.b_c-9"));
    try testing.expect(isValidName("x" ** 128));
    try testing.expect(!isValidName("x" ** 129));
    try testing.expect(!isValidName(""));
    try testing.expect(!isValidName("."));
    try testing.expect(!isValidName(".."));
    try testing.expect(isValidName("..."));
    try testing.expect(!isValidName("a/b"));
    try testing.expect(!isValidName("a b"));
    try testing.expect(!isValidName("caf\xc3\xa9"));
}

test "unit: remote-protocol: sizes are bounded" {
    try testing.expect(isValidSize(80, 24));
    try testing.expect(isValidSize(1, 1));
    try testing.expect(isValidSize(max_dimension, max_dimension));
    try testing.expect(!isValidSize(0, 24));
    try testing.expect(!isValidSize(80, 0));
    try testing.expect(!isValidSize(max_dimension + 1, 24));
}

test "unit: remote-protocol: hello enforces the version and negotiates binary frames" {
    try testing.expectError(error.VersionMismatch, negotiate(.{ .protocol_version = 2 }));
    try testing.expectError(error.VersionMismatch, negotiate(.{ .protocol_version = 0 }));
    try testing.expect(!(try negotiate(.{ .protocol_version = 1 })).binary_frames);
    const caps = [_][]const u8{ "other", rpc.cap_binary_frames };
    try testing.expect((try negotiate(.{ .protocol_version = 1, .capabilities = &caps })).binary_frames);
}
