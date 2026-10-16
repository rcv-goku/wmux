//! End-to-end tests of the `browser` family through `main.run` over the
//! in-memory platform and a scripted v2 server: request params as the
//! server receives them, text and JSON output, exit codes, offline help and
//! availability, and goldens under test/cli/golden/browser*.txt (read from
//! the working directory, or `WMUX_CLI_GOLDEN_DIR`; `WMUX_UPDATE_GOLDEN=1`
//! rewrites them).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const Env = proto.env_names.Env;
const main = @import("../../main.zig");
const fake = @import("../../fake.zig");
const files = @import("files.zig");

pub const Result = struct { code: u8, out: []const u8, err: []const u8 };

const test_sid = "S-1-5-21-1000-1000-1000-1001";

pub const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    fp: fake.Platform,
    pairs: std.ArrayList(Env.Pair),
    pairs_slice: []const Env.Pair,
    env_map: std.process.EnvMap,
    server: fake.Server,
    mem: files.Memory,

    /// A harness with a live control pipe answered by `handler`.
    pub fn init(self: *Harness, handler: fake.Handler) !void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena_state.allocator();
        self.fp = fake.Platform.init(a);
        self.fp.sid = test_sid;
        self.fp.session = 1;
        self.fp.cwd_path = if (builtin.os.tag == .windows) "C:\\work" else "/work";
        self.pairs = .empty;
        self.pairs_slice = &.{};
        self.env_map = std.process.EnvMap.init(a);
        self.setEnv("WMUX_CHANNEL", "stable");
        self.server = fake.Server.init(a);
        self.server.handler = handler;
        const h = proto.pipe_name.sidHash8(test_sid);
        try self.fp.addServer(try proto.pipe_name.controlName(a, "stable", &h, 1), &self.server);
        self.mem = .{ .a = a };
        files.writer = self.mem.writer();
    }

    pub fn deinit(self: *Harness) void {
        files.writer = .{};
        self.arena_state.deinit();
    }

    pub fn alloc(self: *Harness) Allocator {
        return self.arena_state.allocator();
    }

    pub fn setEnv(self: *Harness, name: []const u8, value: []const u8) void {
        self.pairs.append(self.alloc(), .{ name, value }) catch unreachable;
        self.env_map.put(name, value) catch unreachable;
    }

    pub fn run(self: *Harness, argv: []const []const u8) Result {
        const al = self.alloc();
        var out: std.Io.Writer.Allocating = .init(al);
        var err: std.Io.Writer.Allocating = .init(al);
        self.pairs_slice = self.pairs.items;
        var names: std.ArrayList([]const u8) = .empty;
        for (self.pairs.items) |p| names.append(al, p[0]) catch unreachable;
        self.server.requests.clearRetainingCapacity();
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

    /// The single browser request of the last run (skipping identify).
    pub fn request(self: *Harness, method: []const u8) ?fake.Request {
        for (self.server.requests.items) |r| if (std.mem.eql(u8, r.method, method)) return r;
        return null;
    }

    pub fn expectRequest(self: *Harness, method: []const u8, params_json: []const u8) !void {
        const r = self.request(method) orelse {
            std.debug.print("no {s} request; saw {d} requests\n", .{ method, self.server.requests.items.len });
            return error.TestExpectedRequest;
        };
        try testing.expectEqualStrings(params_json, r.params_json);
    }
};

pub fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

pub fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (!contains(hay, needle)) {
        std.debug.print("\n--- expected to find ---\n{s}\n--- in ---\n{s}\n", .{ needle, hay });
        return error.TestExpectedContains;
    }
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

test {
    _ = @import("tests_run.zig");
}
