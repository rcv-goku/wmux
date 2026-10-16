//! On-disk layout of persistent daemon slots (ADR-13):
//!
//!   ~/.wmux/daemon/<version>/<slot>/daemon.sock   Unix socket (0600, dir 0700)
//!   ~/.wmux/daemon/<version>/<slot>/daemon.lock   flock held by the server
//!   ~/.wmux/daemon/<version>/<slot>/daemon.pid    server pid (decimal + \n)
//!   ~/.wmux/daemon/<version>/<slot>/daemon.log    server stderr
//!
//! sockaddr_un caps paths at ~104 bytes; when the socket path would not fit,
//! it moves to `/tmp/wmuxd-remote-<uid>/<hash>.sock` (directory 0700).

const std = @import("std");
const Allocator = std.mem.Allocator;
const remote = @import("wmux_proto").remote;

pub const socket_name = "daemon.sock";
pub const lock_name = "daemon.lock";
pub const pid_name = "daemon.pid";
pub const log_name = "daemon.log";

/// Conservative limit (macOS sun_path is 104 bytes including the NUL).
pub const max_socket_path = 103;

/// `<home>/.wmux/daemon/<version>`
pub fn versionDir(gpa: Allocator, home: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(gpa, &.{ home, ".wmux", "daemon", remote.rpc.daemon_version });
}

/// `<home>/.wmux/daemon/<version>/<slot>`; `slot` must be a valid name.
pub fn slotDir(gpa: Allocator, home: []const u8, slot: []const u8) Allocator.Error![]u8 {
    std.debug.assert(remote.messages.isValidName(slot));
    return std.fs.path.join(gpa, &.{ home, ".wmux", "daemon", remote.rpc.daemon_version, slot });
}

pub fn fileIn(gpa: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(gpa, &.{ dir, name });
}

/// Directory holding the fallback socket for long slot paths.
pub fn fallbackDir(gpa: Allocator, uid: u32) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "/tmp/wmuxd-remote-{d}", .{uid});
}

/// Socket path for a slot directory: inside it when short enough, else in
/// `fallbackDir` named by a hash of the slot directory.
pub fn socketPath(gpa: Allocator, slot_dir: []const u8, uid: u32) Allocator.Error![]u8 {
    const inside = try fileIn(gpa, slot_dir, socket_name);
    if (inside.len <= max_socket_path) return inside;
    gpa.free(inside);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(slot_dir, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    return std.fmt.allocPrint(gpa, "/tmp/wmuxd-remote-{d}/{s}.sock", .{ uid, &hex });
}

const testing = std.testing;

test "unit: remote-daemon: slot paths live under ~/.wmux/daemon/<version>" {
    const gpa = testing.allocator;
    const dir = try slotDir(gpa, "/home/u", "ws-1");
    defer gpa.free(dir);
    try testing.expectEqualStrings("/home/u/.wmux/daemon/" ++ remote.rpc.daemon_version ++ "/ws-1", dir);
    const sock = try socketPath(gpa, dir, 1000);
    defer gpa.free(sock);
    try testing.expectEqualStrings("/home/u/.wmux/daemon/" ++ remote.rpc.daemon_version ++ "/ws-1/daemon.sock", sock);
    const v = try versionDir(gpa, "/home/u");
    defer gpa.free(v);
    try testing.expect(std.mem.startsWith(u8, dir, v));
}

test "unit: remote-daemon: long slot paths fall back to a hashed /tmp socket" {
    const gpa = testing.allocator;
    const dir = try slotDir(gpa, "/home/" ++ "u" ** 40, "s" ** 128);
    defer gpa.free(dir);
    const sock = try socketPath(gpa, dir, 4242);
    defer gpa.free(sock);
    try testing.expect(sock.len <= max_socket_path);
    try testing.expect(std.mem.startsWith(u8, sock, "/tmp/wmuxd-remote-4242/"));
    try testing.expect(std.mem.endsWith(u8, sock, ".sock"));
    // Deterministic per slot dir, distinct across slots.
    const again = try socketPath(gpa, dir, 4242);
    defer gpa.free(again);
    try testing.expectEqualStrings(sock, again);
    const other_dir = try slotDir(gpa, "/home/" ++ "u" ** 40, "t" ** 128);
    defer gpa.free(other_dir);
    const other = try socketPath(gpa, other_dir, 4242);
    defer gpa.free(other);
    try testing.expect(!std.mem.eql(u8, sock, other));
}
