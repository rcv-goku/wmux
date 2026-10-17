//! cmux invocation grammar (ADR-4.4, cmux CLI contract "Global Invocation"):
//!
//! `cmux [--socket <pipe>] [--password <pw>] [--window <id|ref|index>] <command>
//!       [options] [--json] [--id-format refs|uuids|both] [--] [args]`
//!
//! - `--socket`, `--password` and `--window` are global only before the
//!   command; after it they belong to the command.
//! - `--json` and `--id-format` are accepted before or after the command and
//!   are removed from the command's arguments.
//! - `--` ends option parsing: everything after it is payload, including
//!   `--help` and `--version`. Values starting with `+` are ordinary values.
//! - `--help`/`-h`, `--version`/`-v` and `--skill` are recognized in command
//!   position only; `--help`/`-h` among the command's own options (before
//!   `--`) request the command's help.

const std = @import("std");
const proto = @import("wmux_proto");
const idformat = proto.idformat;
const Allocator = std.mem.Allocator;

pub const Globals = struct {
    socket: ?[]const u8 = null,
    password: ?[]const u8 = null,
    window: ?[]const u8 = null,
    json: bool = false,
    id_format: idformat.Mode = .default,
    /// True when `--id-format` was given (`rpc` stays raw otherwise).
    id_format_explicit: bool = false,
};

/// A flag that took the command position.
pub const CommandFlag = enum { help, version, skill };

pub const Parsed = struct {
    globals: Globals = .{},
    /// The command token as typed (null when only global options were given).
    command: ?[]const u8 = null,
    /// Set when the command position held `--help`/`-h`, `--version`/`-v`
    /// or `--skill`.
    command_flag: ?CommandFlag = null,
    /// Arguments after the command with presentation options removed. A
    /// `--` terminator and everything after it are kept verbatim.
    args: []const []const u8 = &.{},
    /// `--help` or `-h` appeared among `args` before `--`.
    help_requested: bool = false,

    /// `args` before the `--` terminator.
    pub fn options(self: Parsed) []const []const u8 {
        for (self.args, 0..) |a, i| if (std.mem.eql(u8, a, "--")) return self.args[0..i];
        return self.args;
    }

    /// Tokens after the `--` terminator (empty when there is none).
    pub fn payload(self: Parsed) []const []const u8 {
        for (self.args, 0..) |a, i| if (std.mem.eql(u8, a, "--")) return self.args[i + 1 ..];
        return &.{};
    }
};

/// Usage error text (printed as `<prog>: <message>`, exit 2).
pub const Diag = struct {
    message: []const u8 = "",
};

pub const Error = error{ Usage, OutOfMemory };

const ValueOpt = enum { socket, password, window, id_format };

/// Splits `--name=value`; returns null when `arg` is not `--name` or
/// `--name=...`.
fn matchOpt(arg: []const u8, name: []const u8) ?struct { inline_value: ?[]const u8 } {
    if (!std.mem.startsWith(u8, arg, name)) return null;
    if (arg.len == name.len) return .{ .inline_value = null };
    if (arg[name.len] == '=') return .{ .inline_value = arg[name.len + 1 ..] };
    return null;
}

fn setValue(g: *Globals, opt: ValueOpt, value: []const u8, diag: *Diag) Error!void {
    switch (opt) {
        .socket => g.socket = value,
        .password => g.password = value,
        .window => g.window = value,
        .id_format => {
            g.id_format = idformat.Mode.parse(value) orelse {
                diag.message = idformat.invalid_message;
                return error.Usage;
            };
            g.id_format_explicit = true;
        },
    }
}

fn missingValue(opt: ValueOpt, diag: *Diag) Error {
    diag.message = switch (opt) {
        .socket => "--socket requires a value",
        .password => "--password requires a value",
        .window => "--window requires a value",
        .id_format => idformat.invalid_message,
    };
    return error.Usage;
}

/// Parses the arguments after argv[0]. Slices in the result point into
/// `argv`; `args` is allocated in `arena`.
pub fn parse(arena: Allocator, argv: []const []const u8, diag: *Diag) Error!Parsed {
    var out: Parsed = .{};
    var i: usize = 0;

    // Global options before the command.
    const before = [_]struct { []const u8, ValueOpt }{
        .{ "--socket", .socket },
        .{ "--password", .password },
        .{ "--window", .window },
        .{ "--id-format", .id_format },
    };
    outer: while (i < argv.len) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--json")) {
            out.globals.json = true;
            i += 1;
            continue;
        }
        for (before) |b| {
            if (matchOpt(a, b[0])) |m| {
                if (m.inline_value) |v| {
                    try setValue(&out.globals, b[1], v, diag);
                    i += 1;
                } else {
                    if (i + 1 >= argv.len) return missingValue(b[1], diag);
                    try setValue(&out.globals, b[1], argv[i + 1], diag);
                    i += 2;
                }
                continue :outer;
            }
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            out.command_flag = .help;
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-v")) {
            out.command_flag = .version;
        } else if (std.mem.eql(u8, a, "--skill")) {
            out.command_flag = .skill;
        } else if (std.mem.eql(u8, a, "--")) {
            // `cmux -- <command>`: the next token is the command even if it
            // looks like an option.
            i += 1;
            if (i >= argv.len) break;
        } else if (a.len > 1 and a[0] == '-') {
            diag.message = try std.fmt.allocPrint(arena, "unknown global option '{s}'", .{a});
            return error.Usage;
        }
        out.command = argv[i];
        i += 1;
        break;
    }

    // The command's arguments: strip presentation options before `--`.
    var rest: std.ArrayList([]const u8) = .empty;
    while (i < argv.len) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) {
            try rest.appendSlice(arena, argv[i..]);
            break;
        }
        if (std.mem.eql(u8, a, "--json")) {
            out.globals.json = true;
            i += 1;
            continue;
        }
        if (matchOpt(a, "--id-format")) |m| {
            if (m.inline_value) |v| {
                try setValue(&out.globals, .id_format, v, diag);
                i += 1;
            } else {
                if (i + 1 >= argv.len) return missingValue(.id_format, diag);
                try setValue(&out.globals, .id_format, argv[i + 1], diag);
                i += 2;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) out.help_requested = true;
        try rest.append(arena, a);
        i += 1;
    }
    out.args = try rest.toOwnedSlice(arena);
    return out;
}

const testing = std.testing;

test {
    _ = @import("logic/args_cases.zig");
}

fn parseOk(arena: Allocator, argv: []const []const u8) !Parsed {
    var diag: Diag = .{};
    return parse(arena, argv, &diag);
}

fn expectUsage(argv: []const []const u8, message: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = .{};
    try testing.expectError(error.Usage, parse(arena_state.allocator(), argv, &diag));
    try testing.expectEqualStrings(message, diag.message);
}

fn expectArgs(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "unit: cli: args global options before the command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try parseOk(arena_state.allocator(), &.{ "--socket", "\\\\.\\pipe\\x", "--password", "+secret", "--window", "window:2", "ping" });
    try testing.expectEqualStrings("\\\\.\\pipe\\x", p.globals.socket.?);
    try testing.expectEqualStrings("+secret", p.globals.password.?);
    try testing.expectEqualStrings("window:2", p.globals.window.?);
    try testing.expectEqualStrings("ping", p.command.?);
    try testing.expectEqual(@as(usize, 0), p.args.len);
}

test "unit: cli: args equals forms and last value wins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try parseOk(arena_state.allocator(), &.{ "--socket=a", "--socket=b", "--password=", "--id-format=uuids", "rpc", "x" });
    try testing.expectEqualStrings("b", p.globals.socket.?);
    try testing.expectEqualStrings("", p.globals.password.?);
    try testing.expectEqual(idformat.Mode.uuids, p.globals.id_format);
    try testing.expect(p.globals.id_format_explicit);
    try expectArgs(&.{"x"}, p.args);
}

test "unit: cli: args presentation options before or after give identical results" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p1 = try parseOk(a, &.{ "--json", "list-workspaces", "--id-format", "both" });
    const p2 = try parseOk(a, &.{ "list-workspaces", "--json", "--id-format", "both" });
    const p3 = try parseOk(a, &.{ "--id-format", "both", "--json", "list-workspaces" });
    for ([_]Parsed{ p1, p2, p3 }) |p| {
        try testing.expect(p.globals.json);
        try testing.expectEqual(idformat.Mode.both, p.globals.id_format);
        try testing.expectEqualStrings("list-workspaces", p.command.?);
        try testing.expectEqual(@as(usize, 0), p.args.len);
    }
}

test "unit: cli: args socket after the command belongs to the command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try parseOk(arena_state.allocator(), &.{ "list-workspaces", "--socket", "/x", "--window", "1", "--password", "p" });
    try testing.expectEqual(@as(?[]const u8, null), p.globals.socket);
    try testing.expectEqual(@as(?[]const u8, null), p.globals.window);
    try testing.expectEqual(@as(?[]const u8, null), p.globals.password);
    try expectArgs(&.{ "--socket", "/x", "--window", "1", "--password", "p" }, p.args);
}

test "unit: cli: args double dash keeps payload untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try parseOk(arena_state.allocator(), &.{ "send", "--surface", "surface:1", "--", "--help", "--json", "--id-format", "bogus", "--version" });
    try testing.expect(!p.help_requested);
    try testing.expect(!p.globals.json);
    try testing.expect(!p.globals.id_format_explicit);
    try expectArgs(&.{ "--surface", "surface:1" }, p.options());
    try expectArgs(&.{ "--help", "--json", "--id-format", "bogus", "--version" }, p.payload());
}

test "unit: cli: args plus values and version text after the command are ordinary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try parseOk(arena_state.allocator(), &.{ "send", "+workspace", "--version", "-v", "+" });
    try testing.expectEqualStrings("send", p.command.?);
    try testing.expectEqual(@as(?CommandFlag, null), p.command_flag);
    try expectArgs(&.{ "+workspace", "--version", "-v", "+" }, p.args);
}

test "unit: cli: args help request among command options" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect((try parseOk(a, &.{ "ping", "--help" })).help_requested);
    try testing.expect((try parseOk(a, &.{ "rpc", "x", "-h" })).help_requested);
    try testing.expect(!(try parseOk(a, &.{ "rpc", "--", "-h" })).help_requested);
    try testing.expect(!(try parseOk(a, &.{ "rpc", "--helpful" })).help_requested);
}

test "unit: cli: args command position flags" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const h = try parseOk(a, &.{"--help"});
    try testing.expectEqual(CommandFlag.help, h.command_flag.?);
    try testing.expectEqual(CommandFlag.help, (try parseOk(a, &.{"-h"})).command_flag.?);
    try testing.expectEqual(CommandFlag.version, (try parseOk(a, &.{ "--json", "-v" })).command_flag.?);
    const s = try parseOk(a, &.{ "--skill", "-h" });
    try testing.expectEqual(CommandFlag.skill, s.command_flag.?);
    try testing.expect(s.help_requested);
    const none = try parseOk(a, &.{});
    try testing.expectEqual(@as(?[]const u8, null), none.command);
    try testing.expectEqual(@as(?CommandFlag, null), none.command_flag);
    const only_globals = try parseOk(a, &.{ "--socket", "x" });
    try testing.expectEqual(@as(?[]const u8, null), only_globals.command);
    const dashed = try parseOk(a, &.{ "--", "--odd-name", "y" });
    try testing.expectEqualStrings("--odd-name", dashed.command.?);
    try expectArgs(&.{"y"}, dashed.args);
}

test "unit: cli: args usage errors" {
    try expectUsage(&.{"--socket"}, "--socket requires a value");
    try expectUsage(&.{ "--json", "--password" }, "--password requires a value");
    try expectUsage(&.{"--window"}, "--window requires a value");
    try expectUsage(&.{ "--id-format", "ids", "ping" }, "--id-format must be one of: refs, uuids, both");
    try expectUsage(&.{ "ping", "--id-format" }, "--id-format must be one of: refs, uuids, both");
    try expectUsage(&.{ "ping", "--id-format=REFS" }, "--id-format must be one of: refs, uuids, both");
    try expectUsage(&.{ "--frobnicate", "ping" }, "unknown global option '--frobnicate'");
}

test "unit: cli: args unicode and huge argument lists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = try parseOk(a, &.{ "--window", "\u{65e5}\u{672c}", "send", "\u{1F600} h\u{e9}llo" });
    try testing.expectEqualStrings("\u{65e5}\u{672c}", p.globals.window.?);
    try expectArgs(&.{"\u{1F600} h\u{e9}llo"}, p.args);

    var many: [5000][]const u8 = undefined;
    many[0] = "send";
    for (many[1..], 1..) |*m, n| m.* = if (n % 2 == 0) "--json" else "x";
    const big = try parseOk(a, &many);
    try testing.expect(big.globals.json);
    try testing.expectEqual(@as(usize, 2500), big.args.len);
}
