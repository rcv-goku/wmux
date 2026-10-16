//! Test harness of the cf-cli-misc families: runs whole invocations through
//! `main.run` over the fake platform and a scripted pipe server, records
//! writes through an in-memory `util.Fs`, and compares goldens under
//! `test/cli/golden/` (run from the repository root, or set
//! `WMUX_CLI_GOLDEN_DIR`; `WMUX_UPDATE_GOLDEN=1` rewrites them).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const Env = proto.env_names.Env;
const main = @import("../../main.zig");
const fake = @import("../../fake.zig");
const util = @import("util.zig");

pub const Result = struct { code: u8, out: []const u8, err: []const u8 };

pub const test_sid = "S-1-5-21-1000-1000-1000-1001";

/// Joins `parts` with the native separator (test paths stay portable).
pub fn p(a: Allocator, parts: []const []const u8) []const u8 {
    return proto.paths.join(a, proto.paths.Style.native, parts) catch unreachable;
}

/// A root that is absolute for the native path style.
pub const root: []const u8 = if (proto.paths.Style.native == .windows) "C:\\t" else "/t";
/// An absolute path outside `root`.
pub const other_root: []const u8 = if (proto.paths.Style.native == .windows) "C:\\o" else "/o";

pub const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    fp: fake.Platform,
    pairs: std.ArrayList(Env.Pair),
    pairs_slice: []const Env.Pair,
    env_map: std.process.EnvMap,
    server: fake.Server,
    /// Directories `isDir` reports in addition to parents of files.
    dirs: std.ArrayList([]const u8),
    /// `fileId` treats a path under `from` as the same path under `to`
    /// (an 8.3 name, junction or symlink for the same directory).
    aliases: std.ArrayList(Alias),
    writes: usize,
    fail_writes: bool,

    pub const Alias = struct { from: []const u8, to: []const u8 };

    pub fn init(self: *Harness) void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena_state.allocator();
        self.fp = fake.Platform.init(a);
        self.fp.sid = test_sid;
        self.fp.session = 1;
        self.fp.cwd_path = p(a, &.{ root, "work" });
        self.pairs = .empty;
        self.pairs_slice = &.{};
        self.env_map = std.process.EnvMap.init(a);
        self.server = fake.Server.init(a);
        self.dirs = .empty;
        self.aliases = .empty;
        self.writes = 0;
        self.fail_writes = false;
        self.setEnv("WMUX_CHANNEL", "stable");
        util.fs = .{ .ptr = self, .vtable = &mem_vtable };
    }

    pub fn deinit(self: *Harness) void {
        util.fs = util.native_fs;
        self.arena_state.deinit();
    }

    pub fn alloc(self: *Harness) Allocator {
        return self.arena_state.allocator();
    }

    pub fn setEnv(self: *Harness, name: []const u8, value: []const u8) void {
        self.pairs.append(self.alloc(), .{ name, value }) catch unreachable;
        self.env_map.put(name, value) catch unreachable;
    }

    /// Serves the control pipe with `handler`.
    pub fn serve(self: *Harness, handler: fake.Handler) void {
        self.server.handler = handler;
        const h = proto.pipe_name.sidHash8(test_sid);
        const path = proto.pipe_name.controlName(self.alloc(), "stable", &h, 1) catch unreachable;
        self.fp.addServer(path, &self.server) catch unreachable;
    }

    pub fn addFile(self: *Harness, path: []const u8, bytes: []const u8) void {
        self.fp.addFile(path, bytes) catch unreachable;
    }

    pub fn addDir(self: *Harness, path: []const u8) void {
        self.dirs.append(self.alloc(), path) catch unreachable;
        // Directories exist for `Platform.pathExists`.
        self.fp.addFile(path, "") catch unreachable;
    }

    /// `from` is another spelling of the directory `to` for `fileId`. The
    /// fake platform matches paths exactly, so files reached through both
    /// spellings must be added under both.
    pub fn addAlias(self: *Harness, from: []const u8, to: []const u8) void {
        self.aliases.append(self.alloc(), .{ .from = from, .to = to }) catch unreachable;
    }

    /// Current bytes of a fake file.
    pub fn file(self: *Harness, path: []const u8) ?[]const u8 {
        var i = self.fp.files.items.len;
        while (i > 0) {
            i -= 1;
            const f = self.fp.files.items[i];
            if (std.mem.eql(u8, f.path, path)) return f.bytes;
        }
        return null;
    }

    pub fn run(self: *Harness, argv: []const []const u8) Result {
        const al = self.alloc();
        var out: std.Io.Writer.Allocating = .init(al);
        var err: std.Io.Writer.Allocating = .init(al);
        self.pairs_slice = self.pairs.items;
        var names: std.ArrayList([]const u8) = .empty;
        for (self.pairs.items) |pair| names.append(al, pair[0]) catch unreachable;
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

    /// The last request the server received.
    pub fn last(self: *Harness) fake.Request {
        return self.server.requests.items[self.server.requests.items.len - 1];
    }

    pub fn requestCount(self: *Harness) usize {
        return self.server.requests.items.len;
    }

    const mem_vtable: util.Fs.VTable = .{ .writeFile = memWrite, .listDir = memList, .isDir = memIsDir, .fileId = memFileId };

    /// A hash of the path after lexical normalization and the alias table;
    /// null for paths the fake does not know (they cannot be opened).
    fn memFileId(ptr: ?*anyopaque, path: []const u8) ?util.FileId {
        const self = self_(ptr);
        if (!self.fp.platform().pathExists(path) and !memIsDir(ptr, path)) return null;
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const a = fba.allocator();
        var real = std.fs.path.resolve(a, &.{path}) catch return null;
        for (self.aliases.items) |al| {
            if (!std.mem.startsWith(u8, real, al.from)) continue;
            const rest = real[al.from.len..];
            if (rest.len > 0 and rest[0] != '/' and rest[0] != '\\') continue;
            real = std.mem.concat(a, u8, &.{ al.to, rest }) catch return null;
            break;
        }
        return .{ .volume = 1, .index = std.hash.Wyhash.hash(0, real) };
    }

    fn self_(ptr: ?*anyopaque) *Harness {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn memWrite(ptr: ?*anyopaque, _: Allocator, path: []const u8, bytes: []const u8) util.WriteError!void {
        const self = self_(ptr);
        if (self.fail_writes) return error.WriteFailed;
        self.writes += 1;
        const copy = self.alloc().dupe(u8, bytes) catch return error.OutOfMemory;
        for (self.fp.files.items) |*f| if (std.mem.eql(u8, f.path, path)) {
            f.bytes = copy;
            return;
        };
        self.fp.addFile(path, copy) catch return error.OutOfMemory;
    }

    fn memList(ptr: ?*anyopaque, arena: Allocator, path: []const u8) ?[]const []const u8 {
        const self = self_(ptr);
        if (!memIsDir(ptr, path)) return null;
        var names: std.ArrayList([]const u8) = .empty;
        for (self.fp.files.items) |f| {
            const d = std.fs.path.dirname(f.path) orelse continue;
            if (std.mem.eql(u8, d, path)) names.append(arena, std.fs.path.basename(f.path)) catch return null;
        }
        return names.items;
    }

    fn memIsDir(ptr: ?*anyopaque, path: []const u8) bool {
        const self = self_(ptr);
        for (self.dirs.items) |d| if (std.mem.eql(u8, d, path)) return true;
        for (self.fp.files.items) |f| {
            const d = std.fs.path.dirname(f.path) orelse continue;
            if (std.mem.eql(u8, d, path)) return true;
        }
        return false;
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

/// Exit code and stderr substring of a failed invocation.
pub fn expectFail(r: Result, code: u8, needle: []const u8) !void {
    if (r.code != code) std.debug.print("\nexit {d} (want {d}); stderr:\n{s}\nstdout:\n{s}\n", .{ r.code, code, r.err, r.out });
    try testing.expectEqual(code, r.code);
    try expectContains(r.err, needle);
}

pub fn expectOk(r: Result) !void {
    if (r.code != 0) std.debug.print("\nexit {d}; stderr:\n{s}\n", .{ r.code, r.err });
    try testing.expectEqual(@as(u8, 0), r.code);
}

fn goldenDir(al: Allocator) []const u8 {
    return std.process.getEnvVarOwned(al, "WMUX_CLI_GOLDEN_DIR") catch "test/cli/golden";
}

/// Rewrites Windows test paths under `C:\t` (or `C:\\t` inside JSON) to the
/// POSIX spelling `/t/...` so one golden serves both hosts. Only path tokens
/// that start at the test root change; other backslashes stay.
pub fn normalizePaths(al: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const plain = std.mem.startsWith(u8, s[i..], "C:\\t");
        const json = std.mem.startsWith(u8, s[i..], "C:\\\\t");
        if (!plain and !json) {
            try out.append(al, s[i]);
            i += 1;
            continue;
        }
        try out.appendSlice(al, "/t");
        i += if (json) 5 else 4;
        while (i < s.len and std.mem.indexOfScalar(u8, " \t\r\n\"',)", s[i]) == null) {
            if (s[i] == '\\') {
                try out.append(al, '/');
                i += if (json and i + 1 < s.len and s[i + 1] == '\\') 2 else 1;
            } else {
                try out.append(al, s[i]);
                i += 1;
            }
        }
    }
    return out.items;
}

pub fn expectGolden(al: Allocator, name: []const u8, raw_actual: []const u8) !void {
    const actual = try normalizePaths(al, raw_actual);
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

/// Parses a request's params as a JSON object (for field asserts).
pub fn param(req: fake.Request, key: []const u8) ?std.json.Value {
    return switch (req.params) {
        .object => |o| o.get(key),
        else => null,
    };
}

test "unit: cli-misc-harness: golden path normalization touches only test-root paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("OK /t/work/a.md x\\y \"/t/cfg/w.json\" \\\"q\\\"", try normalizePaths(a, "OK C:\\t\\work\\a.md x\\y \"C:\\\\t\\\\cfg\\\\w.json\" \\\"q\\\""));
    try testing.expectEqualStrings("/t/work/a.md", try normalizePaths(a, "/t/work/a.md"));
    try testing.expectEqualStrings("", try normalizePaths(a, ""));
}
