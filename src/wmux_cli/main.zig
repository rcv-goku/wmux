//! cmux / wmux command-line front end (ADR-4): a console-subsystem executable
//! built from std, `wmux_proto` and its own Win32 externs only; it never links
//! the Ghostty terminal, renderer, fonts or apprt. Installed as cli\cmux.exe,
//! cli\wmux.exe and cli\wmux.com (byte copies) and the cli\posix sh launchers.
//!
//! Dispatch (ADR-4.3): argv[0] (or `WMUX_ARGV0`) picks the brand or a shim;
//! a Ghostty-native `+action` is relayed to `..\wmux.exe`, a removed legacy
//! wmux `+verb` keeps its legacy output over the legacy pipe (relay.zig,
//! AF-11) or, without one, is mapped (commands/legacy_plus.zig); then the
//! cmux grammar (args.zig) selects a command from the
//! families in commands/manifest.zig. Help, version, guide and every
//! `<command> --help` work without a socket. `cmux <path>` opens an existing
//! path through the launch pipe. Command families register in
//! commands/manifest.zig, agent definitions in agents/manifest.zig.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("wmux_build_options");
const proto = @import("wmux_proto");
const Env = proto.env_names.Env;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const agents = @import("agents/manifest.zig");
pub const commands = @import("commands/manifest.zig");
pub const args = @import("args.zig");
pub const brand = @import("brand.zig");
pub const child_env = @import("child_env.zig");
pub const client = @import("client.zig");
pub const command = @import("command.zig");
pub const discovery = @import("discovery.zig");
pub const docs = @import("docs.zig");
pub const focus_default = @import("focus_default.zig");
pub const guide = @import("guide.zig");
pub const help = @import("help.zig");
pub const launch = @import("launch.zig");
pub const output = @import("output.zig");
pub const platform = @import("platform.zig");
pub const socket_status = @import("socket_status.zig");
pub const version = @import("version.zig");
pub const welcome = @import("welcome.zig");
pub const relay = @import("relay.zig");
const legacy_plus = @import("commands/legacy_plus.zig");
const wmux_ns = @import("commands/wmux_ns.zig");

const CommandSpec = command.CommandSpec;
const Brand = brand.Brand;

/// Every top-level command of every family (namespace families such as
/// `wmux_ns` are dispatched under their namespace word instead). Duplicate
/// names or aliases fail the build.
pub const all_commands: []const CommandSpec = blk: {
    @setEvalBranchQuota(1_000_000);
    var list: []const CommandSpec = &.{};
    for (commands.families) |fam| {
        if (@hasDecl(fam, "namespace")) continue;
        for (fam.commands) |c| list = list ++ &[_]CommandSpec{c};
    }
    for (list, 0..) |c, i| {
        for (list[0..i]) |p| {
            if (std.mem.eql(u8, p.name, c.name)) @compileError("duplicate CLI command: " ++ c.name);
            for (p.aliases) |a| if (std.mem.eql(u8, a, c.name)) @compileError("CLI command name collides with an alias: " ++ c.name);
        }
    }
    break :blk list;
};

fn findIn(list: []const CommandSpec, name: []const u8) ?*const CommandSpec {
    for (list) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
        for (c.aliases) |a| if (std.mem.eql(u8, a, name)) return c;
    }
    return null;
}

pub fn findCommand(name: []const u8) ?*const CommandSpec {
    return findIn(all_commands, name);
}

const namespace_commands: []const CommandSpec = blk: {
    var list: []const CommandSpec = &.{};
    for (wmux_ns.commands) |c| list = list ++ &[_]CommandSpec{c};
    break :blk list;
};

/// cmux cloud, account, mobile and macOS-only commands (Appendix C).
pub const unsupported = [_][]const u8{
    "vm",            "cloud",         "vpn",            "remotes",        "remote",
    "mobile",        "auth",          "login",          "logout",         "billing",
    "ai-accounts",   "coderouter",    "cr",             "iroh-diag",      "feedback",
    "project",       "simulator",     "ios",            "glaeda",         "recover",
    "vm-pty-attach", "vm-ssh-attach", "vm-pty-connect", "vm-tui-connect",
};
pub const unsupported_message = "not supported on wmux (requires cmux cloud/macOS)";

/// `vm agent` spellings of `agent` (`agent <claude|codex|opencode|pi> ...`).
const vm_agent_names = [_][]const u8{ "claude", "codex", "opencode", "pi", "--agent" };

fn isUnsupported(name: []const u8, rest: []const []const u8) bool {
    for (unsupported) |u| if (std.mem.eql(u8, u, name)) return true;
    const first: []const u8 = if (rest.len > 0) rest[0] else "";
    if (std.mem.eql(u8, name, "session") and std.mem.eql(u8, first, "move")) return true;
    if (std.mem.eql(u8, name, "agent")) {
        for (vm_agent_names) |a| if (std.mem.eql(u8, a, first)) return true;
    }
    return false;
}

/// The channel this CLI talks to: the compiled default (build option
/// `channel` when present), overridden by `WMUX_CHANNEL`/`WMUX_TAG`.
pub fn compiledChannel() []const u8 {
    if (@hasDecl(build_options, "channel")) return build_options.channel;
    return proto.channel.compiledDefault(builtin.mode, null);
}

/// Everything one invocation needs; tests pass a fake platform and
/// in-memory writers.
pub const Runtime = struct {
    arena: Allocator,
    platform: platform.Platform,
    env: Env,
    env_names: []const []const u8 = &.{},
    env_map: ?*const std.process.EnvMap = null,
    out: *Writer,
    err: *Writer,
    version_info: version.Info = version.compiled,
};

/// Runs one invocation (`argv[0]` included) and returns the exit code.
pub fn run(rt: Runtime, argv: []const []const u8) u8 {
    return runInner(rt, argv) catch |err| switch (err) {
        error.OutOfMemory => {
            rt.err.writeAll("cmux: out of memory\n") catch {};
            return output.exit.runtime;
        },
        else => {
            rt.err.print("cmux: {s}\n", .{@errorName(err)}) catch {};
            return output.exit.runtime;
        },
    };
}

fn runInner(rt: Runtime, argv: []const []const u8) !u8 {
    const argv0: []const u8 = if (argv.len > 0) argv[0] else "cmux";
    const b: Brand = switch (brand.classify(argv0, rt.env.get(proto.env_names.WMUX_ARGV0))) {
        .cli => |x| x,
        .tmux => {
            try rt.err.writeAll("tmux: the wmux tmux compatibility shim is not available in this build\n");
            return output.exit.runtime;
        },
        .agent_wrapper => |name| {
            try rt.err.print("{s}: the wmux agent wrapper is not available in this build\n", .{name});
            return output.exit.runtime;
        },
    };
    var rest: []const []const u8 = if (argv.len > 0) argv[1..] else argv;
    var plus_rewritten = false;

    // Legacy `+verb` at argv[1] (ADR-4.3 step 2, ADR-4.11, AF-11): Ghostty's
    // own `+actions` run in `..\wmux.exe`; the removed wmux verbs keep their
    // legacy output over the legacy pipe (relay.zig) and fall back to the
    // cmux mapping when no legacy pipe exists.
    if (rest.len > 0 and rest[0].len > 1 and rest[0][0] == '+') {
        const verb = rest[0][1..];
        if (relay.isGhosttyAction(verb)) return relayToGui(rt, b, rest);
        if (relay.isLegacyVerb(verb)) {
            const io: relay.LegacyIo = .{
                .arena = rt.arena,
                .out = rt.out,
                .err = rt.err,
                .ghostty_pid = rt.env.get(proto.env_names.GHOSTTY_PID),
            };
            switch (relay.runLegacy(io, rt.platform, rest)) {
                .done => |code| return code,
                .version => return relayToGui(rt, b, &.{"--version"}),
                .fallback => {},
            }
        }
        switch (try legacy_plus.map(rt.arena, rest)) {
            .relay => return relayToGui(rt, b, rest),
            .usage => |msg| {
                try rt.err.print("{s}: ", .{b.name()});
                try brand.write(rt.err, b, msg);
                try rt.err.writeByte('\n');
                return output.exit.usage;
            },
            .rewrite => |r| {
                if (!command.isQuiet(rt.env)) try command.writeLegacyNotice(rt.err, b, r.legacy, r.new);
                rest = r.argv;
                plus_rewritten = true;
            },
        }
    }

    var diag: args.Diag = .{};
    const parsed = args.parse(rt.arena, rest, &diag) catch |err| switch (err) {
        error.Usage => {
            try rt.err.print("{s}: {s}\n", .{ b.name(), diag.message });
            return output.exit.usage;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    var ctx: command.Ctx = .{
        .gpa = rt.arena,
        .arena = rt.arena,
        .brand = b,
        .parsed = parsed,
        .command = "",
        .env = rt.env,
        .env_names = rt.env_names,
        .env_map = rt.env_map,
        .platform = rt.platform,
        .out = rt.out,
        .err = rt.err,
        .channel = try proto.channel.resolveFromEnv(rt.arena, compiledChannel(), rt.env),
        .version_summary = try version.summaryAlloc(rt.arena, b, rt.version_info),
        .legacy_notice_shown = plus_rewritten,
    };
    defer ctx.deinit();

    if (parsed.command_flag) |flag| switch (flag) {
        .help => {
            try help.writeTopLevel(rt.out, b);
            return output.exit.ok;
        },
        .version => return runSpec(&ctx, findCommand("version").?),
        .skill => return runSpec(&ctx, findCommand("guide").?),
    };
    const name = parsed.command orelse {
        try help.writeTopLevel(rt.out, b);
        return output.exit.ok;
    };

    if (isUnsupported(name, parsed.args)) {
        try rt.err.print("{s} {s}: {s}\n", .{ b.name(), name, unsupported_message });
        return output.exit.usage;
    }
    if (findCommand(name)) |spec| return runSpec(&ctx, spec);
    if (std.mem.eql(u8, name, "wmux")) return runNamespace(&ctx, parsed.args);
    // `wmux <sub>` aliases `wmux wmux <sub>` when <sub> is not a cmux command.
    if (b == .wmux) if (findIn(namespace_commands, name)) |spec| return runSpec(&ctx, spec);

    const first: ?[]const u8 = if (parsed.args.len > 0) parsed.args[0] else null;
    if (help.findCatalog(name, first)) |entry| {
        if (parsed.help_requested) {
            try help.writeCatalogHelp(rt.out, b, entry);
            return output.exit.ok;
        }
        try rt.err.print("{s}: '", .{b.name()});
        try brand.write(rt.err, b, entry.name);
        try rt.err.writeAll("' is not available in this build of wmux yet\n");
        return output.exit.runtime;
    }

    // `cmux <path>` (ADR-4.3 step 4): command names win over paths.
    if (rt.platform.pathExists(name)) {
        const paths = try std.mem.concat(rt.arena, []const u8, &.{ &.{name}, parsed.options() });
        return launch.openPaths(&ctx, paths);
    }

    try rt.err.print("{s}: unknown command '{s}'. Run '{s} help' for usage.\n", .{ b.name(), name, b.name() });
    return output.exit.usage;
}

fn runSpec(ctx: *command.Ctx, spec: *const CommandSpec) !u8 {
    ctx.command = spec.name;
    ctx.socket = spec.socket;
    if (ctx.parsed.help_requested and !spec.handles_help) {
        try brand.write(ctx.out, ctx.brand, spec.help);
        if (spec.help.len == 0 or spec.help[spec.help.len - 1] != '\n') try ctx.out.writeByte('\n');
        return output.exit.ok;
    }
    // One notice per invocation: `+workspace list` names list-workspaces,
    // itself a cmux legacy verb, and does not print that verb's notice too.
    if (spec.legacy_notice and !ctx.legacy_notice_shown and !command.isQuiet(ctx.env)) {
        try command.writeLegacyNotice(ctx.err, ctx.brand, spec.name, spec.legacy_alias_of);
    }
    return spec.run(ctx);
}

/// `cmux wmux <sub>`: wmux-only commands (Appendix B.3).
fn runNamespace(ctx: *command.Ctx, rest: []const []const u8) !u8 {
    const wants_help = rest.len == 0 or std.mem.eql(u8, rest[0], "--help") or std.mem.eql(u8, rest[0], "-h");
    if (!wants_help) {
        if (findIn(namespace_commands, rest[0])) |spec| {
            ctx.parsed.args = rest[1..];
            return runSpec(ctx, spec);
        }
    }
    const out = if (wants_help) ctx.out else ctx.err;
    if (!wants_help) try out.print("{s}: unknown wmux subcommand '{s}'\n", .{ ctx.brand.name(), rest[0] });
    try out.print("Usage: {s} wmux <subcommand> [args]\n\nSubcommands:\n", .{ctx.brand.name()});
    if (namespace_commands.len == 0) try out.writeAll("  (none in this build)\n");
    for (namespace_commands) |c| try out.print("  {s}\n", .{c.name});
    return if (wants_help) output.exit.ok else output.exit.usage;
}

/// Relays a Ghostty-native or not-yet-replaced `+action` to `..\wmux.exe`
/// with inherited handles and propagates its exit code.
fn relayToGui(rt: Runtime, b: Brand, rest: []const []const u8) !u8 {
    const self_exe = rt.platform.selfExePath(rt.arena) orelse {
        try rt.err.print("{s}: cannot relay {s}: the CLI's own path is unknown\n", .{ b.name(), rest[0] });
        return output.exit.runtime;
    };
    const gui = (try launch.guiExePath(rt.arena, self_exe)) orelse {
        try rt.err.print("{s}: cannot relay {s}: {s} is not inside INSTALL\\cli\n", .{ b.name(), rest[0], self_exe });
        return output.exit.runtime;
    };
    var map = std.process.EnvMap.init(rt.arena);
    if (rt.env_map) |src| {
        var it = src.iterator();
        while (it.next()) |e| try map.put(e.key_ptr.*, e.value_ptr.*);
    }
    try child_env.sanitize(&map);
    const argv = try std.mem.concat(rt.arena, []const u8, &.{ &.{gui}, rest });
    return rt.platform.runInherit(rt.arena, argv, &map) catch {
        try rt.err.print("{s}: cannot run {s}\n", .{ b.name(), gui });
        return output.exit.runtime;
    };
}

// ----- process entry -----

const win = if (builtin.os.tag == .windows) @import("win.zig") else struct {};

pub fn main() u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv_z = std.process.argsAlloc(arena) catch return output.exit.runtime;
    const argv = arena.alloc([]const u8, argv_z.len) catch return output.exit.runtime;
    for (argv_z, 0..) |a, i| argv[i] = a;
    var env_map = std.process.getEnvMap(arena) catch std.process.EnvMap.init(arena);
    var names: std.ArrayList([]const u8) = .empty;
    var it = env_map.iterator();
    while (it.next()) |e| names.append(arena, e.key_ptr.*) catch return output.exit.runtime;

    var out_buf: [16 * 1024]u8 = undefined;
    var err_buf: [4 * 1024]u8 = undefined;
    var out_stream: Stream = undefined;
    var err_stream: Stream = undefined;
    out_stream.init(.stdout, &out_buf);
    err_stream.init(.stderr, &err_buf);

    const code = run(.{
        .arena = arena,
        .platform = platform.native(),
        .env = Env.fromEnvMap(&env_map),
        .env_names = names.items,
        .env_map = &env_map,
        .out = out_stream.writer(),
        .err = err_stream.writer(),
    }, argv);
    out_stream.finish();
    err_stream.finish();
    return code;
}

/// stdout/stderr: `WriteConsoleW` through `Utf16Sink` when the handle is a
/// Windows console, plain UTF-8 bytes otherwise (ADR-4.7).
const Stream = struct {
    file: std.fs.File.Writer = undefined,
    console: ?output.Utf16Sink = null,

    fn init(self: *Stream, which: enum { stdout, stderr }, buf: []u8) void {
        self.* = .{};
        if (builtin.os.tag == .windows) {
            const id: u32 = if (which == .stdout) win.STD_OUTPUT_HANDLE else win.STD_ERROR_HANDLE;
            if (win.consoleHandle(id)) |h| {
                self.console = output.Utf16Sink.init(h, win.writeConsoleUnits, buf);
                return;
            }
        }
        const f = if (which == .stdout) std.fs.File.stdout() else std.fs.File.stderr();
        self.file = f.writer(buf);
    }

    fn writer(self: *Stream) *Writer {
        if (self.console) |*c| return &c.interface;
        return &self.file.interface;
    }

    fn finish(self: *Stream) void {
        if (self.console) |*c| {
            c.interface.flush() catch {};
            c.finish() catch {};
        } else self.file.interface.flush() catch {};
    }
};

test {
    // Force semantic analysis of the process entry and the native platform
    // (and through it win.zig) in test builds, including the Windows
    // cross-compile.
    _ = &main;
    _ = platform.native();
    _ = agents;
    _ = commands;
    _ = args;
    _ = brand;
    _ = child_env;
    _ = client;
    _ = command;
    _ = discovery;
    _ = docs;
    _ = focus_default;
    _ = guide;
    _ = help;
    _ = launch;
    _ = output;
    _ = platform;
    _ = socket_status;
    _ = version;
    _ = welcome;
    _ = legacy_plus;
    _ = relay;
    _ = @import("tests.zig");
    _ = @import("logic/tests.zig");
    _ = @import("hooks/tests.zig");
    _ = @import("wmux_proto");
    _ = @import("tmux/tests.zig");
}
