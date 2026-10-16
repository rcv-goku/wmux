//! wmuxd-remote: the clean-room remote daemon of the wmux carrier (ADR-13).
//! See args.zig for the command line and wmux_proto/remote for the protocol.

const std = @import("std");
const posix = std.posix;
const remote = @import("wmux_proto").remote;
const args = @import("args.zig");
const persistent = @import("persistent.zig");
const pty = @import("pty.zig");
const server = @import("server.zig");

pub const std_options: std.Options = .{ .log_level = .info };

const usage =
    \\usage:
    \\  wmuxd-remote version
    \\  wmuxd-remote status [--slot <slot>] [--json]
    \\  wmuxd-remote serve --stdio [--persistent] [--slot <slot>] [--session-ttl <seconds>]
    \\  wmuxd-remote serve --persistent-stop [--slot <slot>]
    \\
    \\Speaks newline-delimited JSON-RPC (plus binary PTY frames after hello) on
    \\stdin/stdout. With --persistent, sessions live in a per-slot server under
    \\~/.wmux/daemon/<version>/<slot>/ and survive the connection.
    \\
;

var stop_flag: std.atomic.Value(bool) = .init(false);

fn onStopSignal(_: i32) callconv(.c) void {
    stop_flag.store(true, .release);
}

fn installSignals(ignore_hup: bool) void {
    const ign: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    const stop: posix.Sigaction = .{ .handler = .{ .handler = onStopSignal }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.PIPE, &ign, null);
    posix.sigaction(posix.SIG.TERM, &stop, null);
    posix.sigaction(posix.SIG.INT, &stop, null);
    posix.sigaction(posix.SIG.HUP, if (ignore_hup) &ign else &stop, null);
}

pub fn main() u8 {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const argv = std.process.argsAlloc(gpa) catch return 1;
    defer std.process.argsFree(gpa, argv);
    var out_buf: [4096]u8 = undefined;
    var out_w = std.fs.File.stdout().writer(&out_buf);
    const out = &out_w.interface;
    var err_buf: [1024]u8 = undefined;
    var err_w = std.fs.File.stderr().writer(&err_buf);
    const errw = &err_w.interface;
    const code = run(gpa, argv, out, errw);
    out.flush() catch {};
    errw.flush() catch {};
    return code;
}

fn run(gpa: std.mem.Allocator, argv: []const []const u8, out: *std.Io.Writer, errw: *std.Io.Writer) u8 {
    var detail: []const u8 = "";
    const cmd = args.parse(argv, &detail) catch |err| {
        const msg = switch (err) {
            error.MissingCommand => "missing command",
            error.UnknownCommand => "unknown command",
            error.UnknownFlag => "unknown flag",
            error.MissingValue => "missing value for flag",
            error.InvalidSlot => "slot must match [A-Za-z0-9._-]{1,128}",
            error.InvalidNumber => "invalid number",
            error.ConflictingFlags => "conflicting flags",
            error.MissingStdio => "serve requires --stdio or --persistent-stop",
        };
        if (detail.len > 0) errw.print("wmuxd-remote: {s}: {s}\n", .{ msg, detail }) catch {} else errw.print("wmuxd-remote: {s}\n", .{msg}) catch {};
        errw.writeAll(usage) catch {};
        return 2;
    };
    const home = pty.homeDir() orelse "/";
    switch (cmd) {
        .help => out.writeAll(usage) catch {},
        .version => out.print("wmuxd-remote {s} (protocol {d})\n", .{ remote.rpc.daemon_version, remote.rpc.protocol_version }) catch {},
        .cli => {
            errw.writeAll("wmuxd-remote: the cli relay is not implemented in this package\n") catch {};
            return 2;
        },
        .status => |st| persistent.writeStatus(gpa, out, home, st.slot, st.json) catch |err| {
            errw.print("wmuxd-remote: status failed: {s}\n", .{@errorName(err)}) catch {};
            return 1;
        },
        .serve => |s| return serve(gpa, s, home, out, errw),
    }
    return 0;
}

fn serve(gpa: std.mem.Allocator, s: args.Serve, home: []const u8, out: *std.Io.Writer, errw: *std.Io.Writer) u8 {
    const ttl_ms: i64 = @intCast(@min(s.session_ttl_s, std.math.maxInt(i64) / 1000) * 1000);
    switch (s.mode) {
        .stdio => {
            installSignals(false);
            var srv = server.Server.init(gpa, .{ .home = home, .session_ttl_ms = ttl_ms, .stop_flag = &stop_flag });
            defer srv.deinit();
            _ = srv.addConn(posix.STDIN_FILENO, posix.STDOUT_FILENO, false) catch return 1;
            srv.run() catch |err| {
                errw.print("wmuxd-remote: {s}\n", .{@errorName(err)}) catch {};
                return 1;
            };
        },
        .persistent_bridge => {
            installSignals(false);
            persistent.runBridge(gpa, home, s.slot, s.session_ttl_s, &stop_flag) catch |err| {
                errw.print("wmuxd-remote: cannot reach the slot server: {s}\n", .{@errorName(err)}) catch {};
                return 1;
            };
        },
        .persistent_server => {
            installSignals(true);
            persistent.runServer(gpa, home, s.slot, .{ .session_ttl_ms = ttl_ms, .stop_flag = &stop_flag }) catch |err| switch (err) {
                error.AlreadyRunning => return 0,
                else => {
                    errw.print("wmuxd-remote: server failed: {s}\n", .{@errorName(err)}) catch {};
                    return 1;
                },
            };
        },
        .persistent_stop => {
            const r = persistent.stopSlot(gpa, home, s.slot, 5000) catch |err| {
                errw.print("wmuxd-remote: stop failed: {s}\n", .{@errorName(err)}) catch {};
                return 1;
            };
            out.print("{s} {s}\n", .{ s.slot, @tagName(r) }) catch {};
        },
    }
    return 0;
}
