//! Test harness for the notify/sidebar_meta/events families: runs `main.run`
//! over the fake platform with a scripted control pipe (same shape as
//! tests.zig) and compares goldens under `test/cli/golden/` (run from the
//! repository root, or set `WMUX_CLI_GOLDEN_DIR`; `WMUX_UPDATE_GOLDEN=1`
//! rewrites them).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const Env = proto.env_names.Env;
const main = @import("../../main.zig");
pub const fake = @import("../../fake.zig");

pub const Result = struct { code: u8, out: []const u8, err: []const u8 };

pub const test_sid = "S-1-5-21-1000-1000-1000-1001";

pub const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    fp: fake.Platform,
    server: fake.Server,
    pairs: std.ArrayList(Env.Pair),
    pairs_slice: []const Env.Pair,
    env_map: std.process.EnvMap,

    /// A harness with a live control pipe answered by `handler`.
    pub fn init(self: *Harness, handler: fake.Handler) !void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena_state.allocator();
        self.fp = fake.Platform.init(a);
        self.fp.sid = test_sid;
        self.fp.session = 1;
        self.pairs = .empty;
        self.pairs_slice = &.{};
        self.env_map = std.process.EnvMap.init(a);
        self.setEnv("WMUX_CHANNEL", "stable");
        self.server = fake.Server.init(a);
        self.server.handler = handler;
        try self.fp.addServer(self.control(), &self.server);
    }

    pub fn deinit(self: *Harness) void {
        self.arena_state.deinit();
    }

    pub fn alloc(self: *Harness) Allocator {
        return self.arena_state.allocator();
    }

    pub fn setEnv(self: *Harness, name: []const u8, value: []const u8) void {
        self.pairs.append(self.alloc(), .{ name, value }) catch unreachable;
        self.env_map.put(name, value) catch unreachable;
    }

    pub fn control(self: *Harness) []const u8 {
        const h = proto.pipe_name.sidHash8(test_sid);
        return proto.pipe_name.controlName(self.alloc(), "stable", &h, 1) catch unreachable;
    }

    pub fn run(self: *Harness, argv: []const []const u8) Result {
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
            .env_map = &self.env_map,
            .out = &out.writer,
            .err = &err.writer,
            .version_info = .{ .version = "1.2.3", .build = "456", .commit = "abcdef0123" },
        }, argv);
        return .{ .code = code, .out = out.written(), .err = err.written() };
    }

    /// Requests whose method is not discovery noise, newest last.
    pub fn last(self: *Harness) fake.Request {
        return self.server.requests.items[self.server.requests.items.len - 1];
    }

    pub fn requestCount(self: *Harness) usize {
        return self.server.requests.items.len;
    }
};

/// Answers every request with `{}`.
pub fn okHandler(_: *fake.Server, _: fake.Request) fake.Action {
    return .{ .ok = "{}" };
}

pub fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

pub fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (!contains(hay, needle)) {
        std.debug.print("\n--- expected to find ---\n{s}\n--- in ---\n{s}\n", .{ needle, hay });
        return error.TestExpectedContains;
    }
}

/// Exit code, stdout and stderr in one check.
pub fn expectResult(r: Result, code: u8, out: []const u8, err: []const u8) !void {
    testing.expectEqualStrings(err, r.err) catch |e| {
        std.debug.print("stdout was:\n{s}\n", .{r.out});
        return e;
    };
    try testing.expectEqualStrings(out, r.out);
    try testing.expectEqual(code, r.code);
}

fn goldenDir(al: Allocator) []const u8 {
    return std.process.getEnvVarOwned(al, "WMUX_CLI_GOLDEN_DIR") catch "test/cli/golden";
}

pub fn expectGolden(al: Allocator, name: []const u8, actual: []const u8) !void {
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
