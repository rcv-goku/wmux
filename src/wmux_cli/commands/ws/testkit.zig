//! Test harness for the window/workspace/workspace-group families: runs
//! `main.run` over the fake platform with a scripted v2 server (one reply
//! per method), records the requests and compares text with goldens under
//! `test/cli/golden/` (relative to the repository root, or
//! `WMUX_CLI_GOLDEN_DIR`; `WMUX_UPDATE_GOLDEN=1` rewrites them).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const Env = proto.env_names.Env;
const main = @import("../../main.zig");
const fake = @import("../../fake.zig");

pub const Result = struct { code: u8, out: []const u8, err: []const u8 };

const test_sid = "S-1-5-21-1000-1000-1000-1001";

pub const Reply = struct { method: []const u8, action: fake.Action };

pub const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    fp: fake.Platform,
    server: fake.Server,
    replies: std.ArrayList(Reply),
    pairs: std.ArrayList(Env.Pair),
    pairs_slice: []const Env.Pair,
    env_map: std.process.EnvMap,

    /// A harness with a live control pipe; `CMUX_QUIET=1` keeps legacy
    /// notices out of stderr unless a test clears it with `noisy`.
    pub fn init(self: *Harness) !void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena_state.allocator();
        self.fp = fake.Platform.init(a);
        self.fp.sid = test_sid;
        self.fp.session = 1;
        self.replies = .empty;
        self.pairs = .empty;
        self.pairs_slice = &.{};
        self.env_map = std.process.EnvMap.init(a);
        self.setEnv("WMUX_CHANNEL", "stable");
        self.setEnv("CMUX_QUIET", "1");
        self.server = fake.Server.init(a);
        self.server.handler = handler;
        self.server.user = self;
        const h = proto.pipe_name.sidHash8(test_sid);
        const control = try proto.pipe_name.controlName(a, "stable", &h, 1);
        try self.fp.addServer(control, &self.server);
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

    /// Removes an environment variable set earlier.
    pub fn unsetEnv(self: *Harness, name: []const u8) void {
        var i: usize = 0;
        while (i < self.pairs.items.len) {
            if (std.mem.eql(u8, self.pairs.items[i][0], name)) _ = self.pairs.orderedRemove(i) else i += 1;
        }
        self.env_map.remove(name);
    }

    /// Legacy alias notices on (the harness starts with `CMUX_QUIET=1`).
    pub fn noisy(self: *Harness) void {
        self.unsetEnv("CMUX_QUIET");
    }

    /// Replies `{"ok":true,"result":<json>}` to `method`; newlines in
    /// `json` (multi-line test literals) are dropped.
    pub fn ok(self: *Harness, method: []const u8, json: []const u8) void {
        const line = std.mem.replaceOwned(u8, self.alloc(), json, "\n", "") catch unreachable;
        self.replies.append(self.alloc(), .{ .method = method, .action = .{ .ok = line } }) catch unreachable;
    }

    /// Replies with an error envelope to `method`.
    pub fn fail(self: *Harness, method: []const u8, json: []const u8) void {
        self.replies.append(self.alloc(), .{ .method = method, .action = .{ .err = json } }) catch unreachable;
    }

    fn handler(server: *fake.Server, req: fake.Request) fake.Action {
        const self: *Harness = @ptrCast(@alignCast(server.user.?));
        var i = self.replies.items.len;
        while (i > 0) {
            i -= 1;
            const r = self.replies.items[i];
            if (std.mem.eql(u8, r.method, req.method)) return r.action;
        }
        return .{ .err = "{\"code\":\"method_not_found\",\"message\":\"Unknown method\"}" };
    }

    pub fn run(self: *Harness, argv: []const []const u8) Result {
        const al = self.alloc();
        var out: std.Io.Writer.Allocating = .init(al);
        var err: std.Io.Writer.Allocating = .init(al);
        self.pairs_slice = self.pairs.items;
        var names: std.ArrayList([]const u8) = .empty;
        for (self.pairs.items) |p| names.append(al, p[0]) catch unreachable;
        const full = std.mem.concat(al, []const u8, &.{ &.{"cmux"}, argv }) catch unreachable;
        const code = main.run(.{
            .arena = al,
            .platform = self.fp.platform(),
            .env = Env.fromPairs(&self.pairs_slice),
            .env_names = names.items,
            .env_map = &self.env_map,
            .out = &out.writer,
            .err = &err.writer,
            .version_info = .{ .version = "1.2.3", .build = "456", .commit = "abcdef0123" },
        }, full);
        return .{ .code = code, .out = out.written(), .err = err.written() };
    }

    /// Requests other than the `system.identify` skew probe.
    pub fn requests(self: *Harness) []const fake.Request {
        return self.server.requests.items;
    }

    /// The last request: method and minified params must match.
    pub fn expectLast(self: *Harness, method: []const u8, params_json: []const u8) !void {
        const reqs = self.server.requests.items;
        if (reqs.len == 0) {
            std.debug.print("\nno request was sent; expected {s} {s}\n", .{ method, params_json });
            return error.TestNoRequest;
        }
        const r = reqs[reqs.len - 1];
        try testing.expectEqualStrings(method, r.method);
        try testing.expectEqualStrings(params_json, r.params_json);
    }

    pub fn requestCount(self: *Harness) usize {
        return self.server.requests.items.len;
    }
};

/// Runs `argv`, expects success with empty stderr, returns stdout.
pub fn expectOk(h: *Harness, argv: []const []const u8) ![]const u8 {
    const r = h.run(argv);
    if (r.code != 0 or r.err.len != 0) {
        std.debug.print("\ncmux {s}: exit {d}\nout:\n{s}\nerr:\n{s}\n", .{ std.mem.join(h.alloc(), " ", argv) catch "", r.code, r.out, r.err });
        return error.TestUnexpectedFailure;
    }
    return r.out;
}

/// Runs `argv`, expects exit 2 without contacting the server, and the first
/// stderr line to be `cmux: <msg>`.
pub fn expectUsage(h: *Harness, argv: []const []const u8, msg: []const u8) !void {
    const before = h.requestCount();
    const r = h.run(argv);
    const want = try std.fmt.allocPrint(h.alloc(), "cmux: {s}\n", .{msg});
    if (r.code != 2 or !std.mem.startsWith(u8, r.err, want)) {
        std.debug.print("\ncmux {s}: exit {d}\nwant stderr prefix: {s}\nerr:\n{s}\n", .{ std.mem.join(h.alloc(), " ", argv) catch "", r.code, want, r.err });
        return error.TestExpectedUsage;
    }
    try testing.expectEqual(before, h.requestCount());
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

/// `cmux <argv> --help` matches the golden and never connects.
pub fn expectHelpGolden(h: *Harness, argv: []const []const u8, golden: []const u8) !void {
    const connects = h.fp.connects;
    const full = try std.mem.concat(h.alloc(), []const u8, &.{ argv, &.{"--help"} });
    const out = try expectOk(h, full);
    try expectGolden(h.alloc(), golden, out);
    try testing.expectEqual(connects, h.fp.connects);
}
