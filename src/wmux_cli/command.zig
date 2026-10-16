//! Command spec and invocation context (ADR-4.9). Family files under
//! commands/ declare `pub const commands = [_]CommandSpec{ ... }`; main.zig
//! dispatches over commands/manifest.zig. A command's `run` gets a `Ctx`
//! with the parsed globals, its own arguments, the environment, the output
//! streams and the platform, and returns the exit code (ADR-4.7).

const std = @import("std");
const proto = @import("wmux_proto");
const Env = proto.env_names.Env;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const args_mod = @import("args.zig");
const brand_mod = @import("brand.zig");
const Brand = brand_mod.Brand;
const platform_mod = @import("platform.zig");
const Platform = platform_mod.Platform;
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const discovery = @import("discovery.zig");
const output = @import("output.zig");
const launch = @import("launch.zig");

/// Help task groups (cmux topics, in help order).
pub const Group = enum {
    start,
    agents,
    navigate,
    inspect,
    customize,
    automation,
    browser,
    remote,
    diagnostics,

    pub fn title(g: Group) []const u8 {
        return switch (g) {
            .start => "Start & Resume",
            .agents => "Agents",
            .navigate => "Navigate & Arrange",
            .inspect => "Inspect",
            .customize => "Customize",
            .automation => "Automation",
            .browser => "Browser",
            .remote => "Remote",
            .diagnostics => "Diagnostics / Advanced",
        };
    }
};

pub const SocketNeed = enum {
    /// Offline: never discovers or connects.
    none,
    /// Fails fast with the discovery error when no app is running.
    required,
    /// Starts `wmux.exe` and waits for its control pipe (ADR-4.9).
    launch_if_needed,
};

pub const RunFn = *const fn (ctx: *Ctx) anyerror!u8;

pub const CommandSpec = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    group: Group,
    hidden: bool = false,
    /// First line of `help` (`Usage: cmux <name> ...`).
    usage: []const u8,
    /// Full offline `--help` text (authored with the `cmux` spelling).
    help: []const u8,
    socket: SocketNeed = .required,
    /// cmux legacy verb: prints the one-time alias notice to stderr.
    legacy_notice: bool = false,
    /// The new spelling named by the legacy notice.
    legacy_alias_of: []const u8 = "",
    /// The command parses `--help` itself (launchers, `version`).
    handles_help: bool = false,
    run: RunFn,
};

/// The cmux legacy-verb notice (cmux wording, CLI contract "Migration
/// Rules"); suppressed by `CMUX_QUIET`/`WMUX_QUIET`.
pub fn writeLegacyNotice(w: *Writer, brand: Brand, legacy: []const u8, new: []const u8) Writer.Error!void {
    try w.print("{s}: '{s}' is now an alias for '{s}'. The legacy form keeps working indefinitely; set CMUX_QUIET=1 to silence this notice.\n", .{ brand.name(), legacy, new });
}

/// `CMUX_QUIET`/`WMUX_QUIET` set to anything but empty, `0` or `false`.
pub fn isQuiet(env: Env) bool {
    for ([_][]const u8{ proto.env_names.WMUX_QUIET, proto.env_names.CMUX_QUIET }) |n| {
        if (env.getNonEmpty(n)) |v| {
            const t = std.mem.trim(u8, v, " \t");
            if (!(std.mem.eql(u8, t, "0") or std.ascii.eqlIgnoreCase(t, "false") or t.len == 0)) return true;
        }
    }
    return false;
}

pub const Ctx = struct {
    gpa: Allocator,
    /// Per-invocation arena; everything a command allocates can live here.
    arena: Allocator,
    brand: Brand,
    parsed: args_mod.Parsed,
    /// The command's canonical name.
    command: []const u8,
    env: Env,
    /// Names of every environment variable (prefix checks such as
    /// `CMUX_AGENT_*`).
    env_names: []const []const u8 = &.{},
    /// Full environment for child processes (null in tests that never spawn).
    env_map: ?*const std.process.EnvMap = null,
    platform: Platform,
    out: *Writer,
    err: *Writer,
    /// The CLI's resolved channel.
    channel: []const u8,
    /// `cmux <version> ...` without a newline.
    version_summary: []const u8,
    /// A legacy `+verb` was rewritten (and its notice printed unless quiet);
    /// the cmux legacy verb it maps to prints no second notice.
    legacy_notice_shown: bool = false,
    socket: SocketNeed = .required,
    client: ?Client = null,

    pub fn deinit(self: *Ctx) void {
        if (self.client) |*c| c.deinit();
        self.client = null;
    }

    /// The command's arguments (presentation options removed).
    pub fn args(self: *const Ctx) []const []const u8 {
        return self.parsed.args;
    }

    pub fn json(self: *const Ctx) bool {
        return self.parsed.globals.json;
    }

    /// Writes `text` rebranded to stdout.
    pub fn print(self: *Ctx, text: []const u8) !void {
        try brand_mod.write(self.out, self.brand, text);
    }

    /// `<prog>: <message>` on stderr; returns exit code 2.
    pub fn usageError(self: *Ctx, comptime fmt: []const u8, a: anytype) u8 {
        self.err.print("{s}: " ++ fmt ++ "\n", .{self.brand.name()} ++ a) catch {};
        return output.exit.usage;
    }

    /// `<prog>: <message>` on stderr; returns exit code 1.
    pub fn runtimeError(self: *Ctx, comptime fmt: []const u8, a: anytype) u8 {
        self.err.print("{s}: " ++ fmt ++ "\n", .{self.brand.name()} ++ a) catch {};
        return output.exit.runtime;
    }

    /// Discovery inputs for this invocation.
    pub fn discoveryInputs(self: *Ctx) !discovery.Inputs {
        const state = try proto.paths.stateDir(self.arena, self.env, proto.paths.Style.native, self.channel);
        return .{
            .explicit_socket = self.parsed.globals.socket,
            .env = self.env,
            .channel = self.channel,
            .user_sid = self.platform.userSid(self.arena),
            .session = self.platform.sessionId(),
            .state_dir = state,
        };
    }

    /// Resolves and connects the control pipe once per invocation. Prints the
    /// discovery or connection error and returns null when that fails; the
    /// caller then exits 1.
    pub fn connect(self: *Ctx) !?*Client {
        if (self.client) |*c| return c;
        const in = try self.discoveryInputs();
        var outcome = try discovery.resolve(self.arena, self.platform, in);
        if (outcome == .none and self.socket == .launch_if_needed) {
            outcome = try launch.ensureControl(self, in);
        }
        const opts_base: client_mod.Options = .{
            .path = "",
            .capability = client_mod.capabilityFromEnv(self.env),
            .password = client_mod.passwordFrom(self.parsed.globals.password, self.env),
            .response_timeout_ms = client_mod.responseTimeoutMs(self.env),
        };
        switch (outcome) {
            .explicit => |e| {
                var o = opts_base;
                o.path = e.path;
                self.client = Client.init(self.arena, self.platform, o);
            },
            .live => |l| {
                if (l.unavailable_default) |d| try discovery.writeFallbackNotice(self.err, self.brand, d, l.path);
                var o = opts_base;
                o.path = l.path;
                self.client = Client.init(self.arena, self.platform, o);
                self.client.?.adopt(l.transport);
            },
            .rejected => |msg| {
                try self.err.print("{s}: {s}\n", .{ self.brand.name(), msg });
                return null;
            },
            .none => |tried| {
                try discovery.writeNoneFound(self.err, tried);
                return null;
            },
        }
        return &self.client.?;
    }

    /// One request. Connection problems come back as `.failure`.
    pub fn call(self: *Ctx, method: []const u8, params_json: ?[]const u8) !?client_mod.Outcome {
        const c = (try self.connect()) orelse return null;
        return try c.call(self.arena, method, params_json, .{ .polling = client_mod.isPolling(method) });
    }

    /// Prints a non-ok outcome (with the version-skew diagnosis on
    /// `method_not_found`) and returns exit code 1.
    pub fn reportError(self: *Ctx, method: []const u8, outcome: client_mod.Outcome) !u8 {
        switch (outcome) {
            .ok => return output.exit.ok,
            .failure => |f| try output.writeFailure(self.arena, self.err, f),
            .rpc_error => |e| {
                try output.writeRpcError(self.arena, self.err, e.err);
                if (e.err.known == .method_not_found and !std.mem.eql(u8, method, "system.identify")) {
                    var ident: ?std.json.Value = null;
                    if (self.client) |*c| {
                        const r = try c.call(self.arena, "system.identify", null, .{});
                        if (r == .ok) ident = r.ok.result;
                    }
                    try output.writeVersionSkew(self.arena, self.err, method, self.version_summary, ident);
                }
            },
        }
        return output.exit.runtime;
    }
};

const testing = std.testing;

test "unit: cli: legacy notice wording and quiet switches" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeLegacyNotice(&aw.writer, .cmux, "new-workspace", "workspace create");
    try testing.expectEqualStrings("cmux: 'new-workspace' is now an alias for 'workspace create'. The legacy form keeps working indefinitely; set CMUX_QUIET=1 to silence this notice.\n", aw.written());
    try testing.expect(!isQuiet(Env.empty));
    const q: []const Env.Pair = &.{.{ "CMUX_QUIET", "1" }};
    try testing.expect(isQuiet(Env.fromPairs(&q)));
    const w: []const Env.Pair = &.{.{ "WMUX_QUIET", "yes" }};
    try testing.expect(isQuiet(Env.fromPairs(&w)));
    const off: []const Env.Pair = &.{ .{ "CMUX_QUIET", "0" }, .{ "WMUX_QUIET", "false" } };
    try testing.expect(!isQuiet(Env.fromPairs(&off)));
}
