//! Command line of `wmuxd-remote` (pure parsing, no I/O).
//!
//!   wmuxd-remote version
//!   wmuxd-remote status [--slot <slot>] [--json]
//!   wmuxd-remote serve --stdio [--persistent] [--slot <slot>] [--session-ttl <seconds>]
//!   wmuxd-remote serve --persistent-stop [--slot <slot>]
//!   wmuxd-remote serve --persistent-server [--slot <slot>] [--session-ttl <seconds>]  (internal)
//!   wmuxd-remote cli ...  (relay; not implemented in this package)
//!
//! `--flag value` and `--flag=value` are both accepted.

const std = @import("std");
const remote = @import("wmux_proto").remote;

pub const default_slot = "default";
/// Detached sessions idle this long are reaped (0 disables).
pub const default_session_ttl_s: u64 = 7 * 24 * 60 * 60;

pub const ServeMode = enum { stdio, persistent_bridge, persistent_server, persistent_stop };

pub const Serve = struct {
    mode: ServeMode,
    slot: []const u8 = default_slot,
    session_ttl_s: u64 = default_session_ttl_s,
};

pub const Command = union(enum) {
    help,
    version,
    status: struct { slot: ?[]const u8 = null, json: bool = false },
    serve: Serve,
    cli,
};

pub const Error = error{
    MissingCommand,
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    InvalidSlot,
    InvalidNumber,
    ConflictingFlags,
    MissingStdio,
};

/// Fills `detail` with the offending argument when parsing fails.
pub fn parse(argv: []const []const u8, detail: *[]const u8) Error!Command {
    detail.* = "";
    if (argv.len == 0) return error.MissingCommand;
    const base = std.fs.path.basename(argv[0]);
    if (std.mem.eql(u8, base, "cmux") or std.mem.eql(u8, base, "wmux")) return .cli;
    if (argv.len < 2) return error.MissingCommand;
    const cmd = argv[1];
    const rest = argv[2..];
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) return .version;
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return .help;
    if (std.mem.eql(u8, cmd, "cli")) return .cli;
    var it: FlagIter = .{ .args = rest, .detail = detail };
    if (std.mem.eql(u8, cmd, "status")) {
        var st: @FieldType(Command, "status") = .{};
        while (try it.next()) |f| {
            if (f.is("--json")) {
                try f.noValue();
                st.json = true;
            } else if (f.is("--slot")) {
                st.slot = try slotValue(try it.value(f), detail);
            } else if (f.is("--help")) return .help else return f.unknown();
        }
        return .{ .status = st };
    }
    if (std.mem.eql(u8, cmd, "serve")) return parseServe(&it, detail);
    detail.* = cmd;
    return error.UnknownCommand;
}

fn parseServe(it: *FlagIter, detail: *[]const u8) Error!Command {
    var stdio = false;
    var persistent = false;
    var server = false;
    var stop = false;
    var s: Serve = .{ .mode = .stdio };
    while (try it.next()) |f| {
        if (f.is("--stdio")) {
            try f.noValue();
            stdio = true;
        } else if (f.is("--persistent")) {
            try f.noValue();
            persistent = true;
        } else if (f.is("--persistent-server")) {
            try f.noValue();
            server = true;
        } else if (f.is("--persistent-stop")) {
            try f.noValue();
            stop = true;
        } else if (f.is("--slot")) {
            s.slot = try slotValue(try it.value(f), detail);
        } else if (f.is("--session-ttl")) {
            const v = try it.value(f);
            s.session_ttl_s = std.fmt.parseInt(u64, v, 10) catch {
                detail.* = v;
                return error.InvalidNumber;
            };
        } else if (f.is("--help")) return .help else return f.unknown();
    }
    const modes = @as(u8, @intFromBool(server)) + @intFromBool(stop) + @intFromBool(stdio);
    if (modes > 1 or (persistent and !stdio)) return error.ConflictingFlags;
    if (server) {
        s.mode = .persistent_server;
    } else if (stop) {
        s.mode = .persistent_stop;
    } else if (stdio) {
        s.mode = if (persistent) .persistent_bridge else .stdio;
    } else return error.MissingStdio;
    return .{ .serve = s };
}

fn slotValue(v: []const u8, detail: *[]const u8) Error![]const u8 {
    if (!remote.messages.isValidName(v)) {
        detail.* = v;
        return error.InvalidSlot;
    }
    return v;
}

const Flag = struct {
    name: []const u8,
    inline_value: ?[]const u8,
    raw: []const u8,
    detail: *[]const u8,

    fn is(self: Flag, n: []const u8) bool {
        return std.mem.eql(u8, self.name, n);
    }

    fn noValue(self: Flag) Error!void {
        if (self.inline_value != null) return self.unknown();
    }

    fn unknown(self: Flag) Error {
        self.detail.* = self.raw;
        return error.UnknownFlag;
    }
};

const FlagIter = struct {
    args: []const []const u8,
    i: usize = 0,
    detail: *[]const u8,

    fn next(self: *FlagIter) Error!?Flag {
        if (self.i >= self.args.len) return null;
        const a = self.args[self.i];
        self.i += 1;
        if (!std.mem.startsWith(u8, a, "--") and !std.mem.eql(u8, a, "-h")) {
            self.detail.* = a;
            return error.UnknownFlag;
        }
        if (std.mem.eql(u8, a, "-h")) return .{ .name = "--help", .inline_value = null, .raw = a, .detail = self.detail };
        if (std.mem.indexOfScalar(u8, a, '=')) |eq|
            return .{ .name = a[0..eq], .inline_value = a[eq + 1 ..], .raw = a, .detail = self.detail };
        return .{ .name = a, .inline_value = null, .raw = a, .detail = self.detail };
    }

    fn value(self: *FlagIter, f: Flag) Error![]const u8 {
        if (f.inline_value) |v| return v;
        if (self.i >= self.args.len) {
            self.detail.* = f.name;
            return error.MissingValue;
        }
        const v = self.args[self.i];
        self.i += 1;
        return v;
    }
};

const testing = std.testing;

fn p(argv: []const []const u8) Error!Command {
    var d: []const u8 = "";
    return parse(argv, &d);
}

test "unit: remote-daemon: serve modes parse" {
    const a = try p(&.{ "wmuxd-remote", "serve", "--stdio" });
    try testing.expectEqual(ServeMode.stdio, a.serve.mode);
    try testing.expectEqualStrings(default_slot, a.serve.slot);
    const b = try p(&.{ "x", "serve", "--stdio", "--persistent", "--slot", "ws-1" });
    try testing.expectEqual(ServeMode.persistent_bridge, b.serve.mode);
    try testing.expectEqualStrings("ws-1", b.serve.slot);
    const c = try p(&.{ "x", "serve", "--persistent-stop", "--slot=s.2" });
    try testing.expectEqual(ServeMode.persistent_stop, c.serve.mode);
    try testing.expectEqualStrings("s.2", c.serve.slot);
    const d = try p(&.{ "x", "serve", "--persistent-server", "--session-ttl", "0" });
    try testing.expectEqual(ServeMode.persistent_server, d.serve.mode);
    try testing.expectEqual(@as(u64, 0), d.serve.session_ttl_s);
}

test "unit: remote-daemon: other commands parse" {
    try testing.expectEqual(Command.version, try p(&.{ "x", "version" }));
    try testing.expectEqual(Command.help, try p(&.{ "x", "--help" }));
    try testing.expectEqual(Command.cli, try p(&.{ "x", "cli", "notify" }));
    try testing.expectEqual(Command.cli, try p(&.{ "/home/u/.wmux/bin/cmux", "notify" }));
    const s = try p(&.{ "x", "status", "--json", "--slot", "a" });
    try testing.expect(s.status.json);
    try testing.expectEqualStrings("a", s.status.slot.?);
}

test "unit: remote-daemon: bad command lines are rejected with detail" {
    var d: []const u8 = "";
    try testing.expectError(error.MissingCommand, parse(&.{}, &d));
    try testing.expectError(error.MissingCommand, parse(&.{"x"}, &d));
    try testing.expectError(error.UnknownCommand, parse(&.{ "x", "nope" }, &d));
    try testing.expectEqualStrings("nope", d);
    try testing.expectError(error.UnknownFlag, parse(&.{ "x", "serve", "--stdio", "--bogus" }, &d));
    try testing.expectEqualStrings("--bogus", d);
    try testing.expectError(error.UnknownFlag, parse(&.{ "x", "serve", "--stdio=1" }, &d));
    try testing.expectError(error.UnknownFlag, parse(&.{ "x", "serve", "stdio" }, &d));
    try testing.expectError(error.MissingValue, parse(&.{ "x", "serve", "--stdio", "--slot" }, &d));
    try testing.expectError(error.InvalidSlot, parse(&.{ "x", "serve", "--stdio", "--slot", "../etc" }, &d));
    try testing.expectEqualStrings("../etc", d);
    try testing.expectError(error.InvalidSlot, parse(&.{ "x", "serve", "--stdio", "--slot=" }, &d));
    try testing.expectError(error.InvalidNumber, parse(&.{ "x", "serve", "--stdio", "--session-ttl", "-1" }, &d));
    try testing.expectError(error.MissingStdio, parse(&.{ "x", "serve" }, &d));
    try testing.expectError(error.ConflictingFlags, parse(&.{ "x", "serve", "--persistent" }, &d));
    try testing.expectError(error.ConflictingFlags, parse(&.{ "x", "serve", "--stdio", "--persistent-stop" }, &d));
}
