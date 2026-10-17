//! Offline conformance of the CLI front end (W1-2c): goldens for help,
//! help topics, version, guide and per-command `--help`; the adapted cmux
//! no-socket probes for the families wmux does not claim (G2, Appendix E
//! D19); and the guarantee that none of them touches a pipe. Goldens live
//! in test/cli/golden/ (run from the repository root, or set
//! `WMUX_CLI_GOLDEN_DIR`; `WMUX_UPDATE_GOLDEN=1` rewrites them). Wired from
//! the test block of help.zig.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const Env = proto.env_names.Env;
const main = @import("../main.zig");
const fake = @import("../fake.zig");

const Result = struct { code: u8, out: []const u8, err: []const u8 };

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    fp: fake.Platform,
    pairs: std.ArrayList(Env.Pair),
    pairs_slice: []const Env.Pair,

    fn init(self: *Harness) void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        self.fp = fake.Platform.init(self.arena_state.allocator());
        self.fp.sid = "S-1-5-21-1000-1000-1000-1001";
        self.fp.session = 1;
        self.pairs = .empty;
        self.pairs_slice = &.{};
        self.setEnv("WMUX_CHANNEL", "stable");
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
    }

    fn alloc(self: *Harness) Allocator {
        return self.arena_state.allocator();
    }

    fn setEnv(self: *Harness, name: []const u8, value: []const u8) void {
        self.pairs.append(self.alloc(), .{ name, value }) catch unreachable;
    }

    fn run(self: *Harness, argv: []const []const u8) Result {
        const al = self.alloc();
        var out: std.Io.Writer.Allocating = .init(al);
        var err: std.Io.Writer.Allocating = .init(al);
        self.pairs_slice = self.pairs.items;
        var names: std.ArrayList([]const u8) = .empty;
        for (self.pairs.items) |p| names.append(al, p[0]) catch unreachable;
        const code = main.run(.{
            .arena = al,
            .platform = self.fp.platform(),
            .env = Env.fromPairs(&self.pairs_slice),
            .env_names = names.items,
            .out = &out.writer,
            .err = &err.writer,
            .version_info = .{ .version = "1.2.3", .build = "456", .commit = "abcdef0123" },
        }, argv);
        return .{ .code = code, .out = out.written(), .err = err.written() };
    }
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn goldenDir(al: Allocator) []const u8 {
    return std.process.getEnvVarOwned(al, "WMUX_CLI_GOLDEN_DIR") catch "test/cli/golden";
}

fn expectGolden(al: Allocator, name: []const u8, actual: []const u8) !void {
    const path = try std.fs.path.join(al, &.{ goldenDir(al), name });
    if (std.process.hasEnvVarConstant("WMUX_UPDATE_GOLDEN")) {
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = actual });
        return;
    }
    const raw = std.fs.cwd().readFileAlloc(al, path, 1 << 20) catch |err| {
        std.debug.print("cannot read golden {s}: {s} (run from the repository root or set WMUX_CLI_GOLDEN_DIR)\n", .{ path, @errorName(err) });
        return err;
    };
    const expected = try std.mem.replaceOwned(u8, al, raw, "\r\n", "\n");
    try testing.expectEqualStrings(expected, actual);
}

test "unit: cli-golden: offline help, topics, version, guide and per-command help" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const cases = [_]struct { []const u8, []const []const u8 }{
        .{ "help.txt", &.{ "cmux", "help" } },
        .{ "help.txt", &.{ "cmux", "--help" } },
        .{ "help.txt", &.{ "cmux", "help", "bogus" } },
        .{ "help-agents.txt", &.{ "cmux", "help", "agents" } },
        .{ "help-diagnostics.txt", &.{ "cmux", "help", "diagnostics" } },
        .{ "version.txt", &.{ "cmux", "version" } },
        .{ "version.txt", &.{ "cmux", "-v" } },
        .{ "version.txt", &.{ "cmux", "version", "--help" } },
        .{ "guide.txt", &.{ "cmux", "guide" } },
        .{ "guide.txt", &.{ "cmux", "--skill" } },
        .{ "guide-json.txt", &.{ "cmux", "guide", "--json" } },
        .{ "welcome.txt", &.{ "cmux", "welcome" } },
        .{ "ping-help.txt", &.{ "cmux", "ping", "--help" } },
        .{ "send-help.txt", &.{ "cmux", "send", "--help" } },
        .{ "rpc-help.txt", &.{ "cmux", "rpc", "-h" } },
        .{ "wmux-help-agents.txt", &.{ "wmux", "help", "agents" } },
    };
    for (cases) |c| {
        const r = h.run(c[1]);
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expectEqualStrings("", r.err);
        try expectGolden(h.alloc(), c[0], r.out);
    }
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

/// cmux contract probes of families wmux does not claim (cloud, account,
/// coderouter, feedback; G2, Appendix E D19): a usage error naming the
/// family, never help text and never a connection.
const unsupported_probes = [_][]const []const u8{
    &.{ "cloud", "--help" },                    &.{ "cloud", "guide" },       &.{ "cloud", "--skill" },
    &.{ "vm", "guide" },                        &.{ "vm", "--skill" },        &.{ "vm", "--help" },
    &.{ "vm", "run", "-h" },                    &.{ "vm", "new", "--help" },  &.{ "cloud", "guide", "--help" },
    &.{ "glaeda", "--help" },                   &.{ "auth", "--help" },       &.{ "remotes", "--help" },
    &.{ "remote", "--help" },                   &.{ "coderouter", "--help" }, &.{ "feedback", "--help" },
    &.{ "vm", "exec", "demo", "--", "--help" },
};

test "unit: cli-probes: unclaimed cmux families exit 2 offline without help" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    for (unsupported_probes) |p| {
        const argv = try std.mem.concat(h.alloc(), []const u8, &.{ &.{"cmux"}, p });
        const r = h.run(argv);
        try testing.expectEqual(@as(u8, 2), r.code);
        try testing.expectEqualStrings("", r.out);
        try testing.expect(contains(r.err, "not supported on wmux"));
        try testing.expect(contains(r.err, p[0]));
    }
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

test "unit: cli-probes: help, version and guide ignore socket settings and never connect" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.setEnv("CMUX_SOCKET_PATH", "\\\\.\\pipe\\wmux-probe-none");
    h.setEnv("CMUX_SOCKET", "\\\\.\\pipe\\wmux-probe-other");
    const forms = [_][]const []const u8{
        &.{ "cmux", "--socket", "\\\\.\\pipe\\nope", "--help" },
        &.{ "cmux", "--password", "x", "help", "remote" },
        &.{ "cmux", "--window", "window:9", "version" },
        &.{ "cmux", "--json", "--skill" },
        &.{ "cmux", "--id-format", "both", "guide" },
        &.{ "cmux", "docs", "api" },
        &.{ "cmux", "list-workspaces", "--help" },
        &.{ "cmux", "new-workspace", "-h" },
    };
    for (forms) |f| {
        const r = h.run(f);
        if (r.code != 0 or r.out.len == 0) {
            std.debug.print("\noffline form failed: {any} (exit {d})\n{s}\n", .{ f, r.code, r.err });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}

test "unit: cli-probes: guide json content equals the text form" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const text = h.run(&.{ "cmux", "guide" });
    const js = h.run(&.{ "cmux", "--skill", "--json" });
    try testing.expectEqual(@as(u8, 0), js.code);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.alloc(), js.out, .{});
    try testing.expectEqualStrings("cmux", v.object.get("topic").?.string);
    try testing.expectEqualStrings("markdown", v.object.get("format").?.string);
    try testing.expectEqualStrings(text.out, v.object.get("content").?.string);
    for ([_][]const []const u8{ &.{ "cmux", "guide", "x" }, &.{ "cmux", "--skill", "x", "y" } }) |f| {
        const r = h.run(f);
        try testing.expectEqual(@as(u8, 2), r.code);
        try testing.expect(contains(r.err, "Usage: cmux guide | cmux --skill [--json]"));
    }
}

test "unit: cli-probes: wmux spelling of the contract probes" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.setEnv("WMUX_ARGV0", "wmux");
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{"--help"}, "wmux - control wmux via named pipe" },
        .{ &.{ "help", "--help" }, "Usage: wmux help [topic]" },
        .{ &.{"--help"}, "wmux help <start|agents|navigate|inspect|customize|automation|browser|remote|diagnostics>" },
        .{ &.{"--skill"}, "# wmux guide" },
        .{ &.{ "guide", "--help" }, "Usage: wmux guide | wmux --skill [--json]" },
        .{ &.{"-v"}, "wmux 1.2.3 (456) [abcdef0]" },
        .{ &.{ "welcome", "--help" }, "Usage: wmux welcome" },
        .{ &.{"welcome"}, "wmux shortcuts" },
        .{ &.{ "docs", "settings" }, "Config files:" },
        .{ &.{ "capture-pane", "--help" }, "Usage: wmux capture-pane [--workspace <id|ref|index>]" },
    };
    for (cases) |c| {
        const argv = try std.mem.concat(h.alloc(), []const u8, &.{ &.{"cmux.exe"}, c[0] });
        const r = h.run(argv);
        if (r.code != 0 or !contains(r.out, c[1])) {
            std.debug.print("\nwmux probe failed: {any}\nwant: {s}\nout:\n{s}\n", .{ c[0], c[1], r.out });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(@as(usize, 0), h.fp.connects);
}
