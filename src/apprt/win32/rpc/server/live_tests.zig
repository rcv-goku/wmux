//! Live named-pipe tests of the v2 transport (W1-1a-t): real pipes named
//! `wmux-test-<pid>-<n>`, loopback only, no windows, no focus changes,
//! every server stopped and freed by its test (std.testing.allocator checks
//! leaks). On other OSes the live tests skip and only the std-only server
//! tests (admission, ratelimit, launch_pipe parsing) run.
//!
//! Windows command (PowerShell, from the repo root; Zig resolves `../logic`
//! imports only below the root file's directory, so the root sits in rpc/):
//!
//!     Set-Content src/apprt/win32/rpc/_w1_1a_t_root.zig 'test { _ = @import("server/live_tests.zig"); }'
//!     zig test --dep wmux_proto -Mroot=src/apprt/win32/rpc/_w1_1a_t_root.zig -Mwmux_proto=src/wmux_proto/proto.zig
//!     Remove-Item src/apprt/win32/rpc/_w1_1a_t_root.zig
//!
//! Cross-compile check from Linux (-target must precede the -M it applies to):
//!
//!     zig test -target x86_64-windows-gnu --dep wmux_proto -Mroot=src/apprt/win32/rpc/_w1_1a_t_root.zig -Mwmux_proto=src/wmux_proto/proto.zig --test-no-exec -femit-bin=live_tests.exe

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");
const envelope = proto.envelope;

const PipeServer = @import("PipeServer.zig");
const Connection = PipeServer.Connection;
const launch_pipe = @import("launch_pipe.zig");
const PipeClient = launch_pipe.PipeClient;
const Token = PipeServer.Token;

const testing = std.testing;
const is_windows = builtin.os.tag == .windows;

test {
    _ = @import("admission.zig");
    _ = @import("ratelimit.zig");
    _ = @import("launch_pipe.zig");
}

// ---------------------------------------------------------------------------
// Test dispatcher
// ---------------------------------------------------------------------------

/// Methods: `test.echo` (inline reply), `test.async` (a worker thread
/// begins and completes it), `test.poll` (polling token bucket),
/// `test.defer` (begun + deferred, token parked for the test),
/// `test.queue` (never begun, token parked). `params.deadline_ms`
/// overrides the request deadline.
const TestHandler = struct {
    gpa: Allocator,
    server: ?*PipeServer = null,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    parked: std.ArrayList(Token) = .empty,
    work: std.ArrayList(Work) = .empty,
    quit: bool = false,
    worker: ?std.Thread = null,

    const Work = struct { token: Token, id: std.json.Value, id_buf: [64]u8 };

    fn init(self: *TestHandler, gpa: Allocator) !void {
        self.* = .{ .gpa = gpa };
        self.worker = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    fn deinit(self: *TestHandler) void {
        self.mutex.lock();
        self.quit = true;
        self.mutex.unlock();
        self.cond.broadcast();
        if (self.worker) |t| t.join();
        self.parked.deinit(self.gpa);
        self.work.deinit(self.gpa);
    }

    fn handler(self: *TestHandler) PipeServer.Handler {
        return .{ .ctx = self, .dispatch = dispatch };
    }

    fn dispatch(ctx: ?*anyopaque, conn: *Connection, req: *PipeServer.Request) void {
        const self: *TestHandler = @ptrCast(@alignCast(ctx.?));
        const server = conn.server;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = envelope.parseRequest(arena, req.line) catch return;
        const r = switch (parsed) {
            .rejected => |rej| return reply(server, req.token, envelope.encodeRejectionAlloc(self.gpa, rej)),
            .request => |r| r,
        };
        if (r.params.get("deadline_ms")) |v| if (v == .integer) {
            req.deadline_ms = @intCast(v.integer);
        };
        const m = r.method;
        if (std.mem.eql(u8, m, "test.echo")) {
            return reply(server, req.token, envelope.encodeOkAlloc(self.gpa, r.id, .{ .echo = r.params.get("n") orelse .null }));
        } else if (std.mem.eql(u8, m, "test.poll")) {
            if (conn.takePollingToken()) |retry| return reply(server, req.token, PipeServer.ratelimit.rateLimitedLineAlloc(self.gpa, r.id, retry));
            return reply(server, req.token, envelope.encodeOkAlloc(self.gpa, r.id, .{ .polled = true }));
        } else if (std.mem.eql(u8, m, "test.async")) {
            var w: Work = .{ .token = req.token, .id = .null, .id_buf = undefined };
            if (r.id == .string and r.id.string.len <= w.id_buf.len) {
                @memcpy(w.id_buf[0..r.id.string.len], r.id.string);
                w.id = .{ .string = w.id_buf[0..r.id.string.len] };
            }
            self.mutex.lock();
            defer self.mutex.unlock();
            self.work.append(self.gpa, w) catch return;
            // id points into the stored element; fixed up by the worker.
            self.cond.signal();
            return;
        } else if (std.mem.eql(u8, m, "test.defer")) {
            _ = server.begin(req.token);
            _ = server.markDeferred(req.token);
            self.park(req.token);
        } else if (std.mem.eql(u8, m, "test.queue")) {
            self.park(req.token);
        } else {
            return reply(server, req.token, envelope.encodeErrorAlloc(self.gpa, r.id, .{ .code = .method_not_found, .message = proto.errors.msg.unknown_method }));
        }
    }

    fn reply(server: *PipeServer, token: Token, line: Allocator.Error![]u8) void {
        const l = line catch return;
        defer server.gpa.free(l);
        _ = server.complete(token, l);
    }

    fn park(self: *TestHandler, token: Token) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.parked.append(self.gpa, token) catch {};
        self.cond.broadcast();
    }

    /// Waits (bounded) until `n` tokens are parked; returns the n-th.
    fn waitParked(self: *TestHandler, n: usize) !Token {
        self.mutex.lock();
        defer self.mutex.unlock();
        var timer = try std.time.Timer.start();
        while (self.parked.items.len < n) {
            const spent = timer.read();
            if (spent >= 5 * std.time.ns_per_s) return error.TestTimeout;
            self.cond.timedWait(&self.mutex, 5 * std.time.ns_per_s - spent) catch {};
        }
        return self.parked.items[n - 1];
    }

    fn workerLoop(self: *TestHandler) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            while (self.work.items.len == 0 and !self.quit) self.cond.wait(&self.mutex);
            if (self.quit) return;
            var w = self.work.orderedRemove(0);
            if (w.id == .string) w.id = .{ .string = w.id_buf[0..w.id.string.len] };
            const server = self.server.?;
            self.mutex.unlock();
            if (server.begin(w.token)) {
                reply(server, w.token, envelope.encodeOkAlloc(self.gpa, w.id, .{ .worker = true }));
            }
            self.mutex.lock();
        }
    }
};

// ---------------------------------------------------------------------------
// Fixture and client helpers
// ---------------------------------------------------------------------------

var name_counter = std.atomic.Value(u32).init(0);

/// `wmux-test-<pid>-<n>`: unique per process and test.
fn testPipeName(buf: []u8) []const u8 {
    const n = name_counter.fetchAdd(1, .monotonic);
    return std.fmt.bufPrint(buf, "wmux-test-{d}-{d}", .{ std.os.windows.GetCurrentProcessId(), n }) catch unreachable;
}

const Fixture = struct {
    handler: TestHandler,
    server: *PipeServer,
    name_buf: [64]u8,
    name: []const u8,

    /// In place: the handler's address is the server's callback context.
    fn init(self: *Fixture, config: PipeServer.Config) !void {
        try self.handler.init(testing.allocator);
        errdefer self.handler.deinit();
        self.name = testPipeName(&self.name_buf);
        var c = config;
        c.name = self.name;
        self.server = try PipeServer.start(testing.allocator, c, self.handler.handler());
        self.handler.mutex.lock();
        self.handler.server = self.server;
        self.handler.mutex.unlock();
    }

    fn deinit(self: *Fixture) void {
        self.server.deinit();
        self.handler.deinit();
    }

    fn connect(self: *Fixture) !PipeClient {
        return PipeClient.connect(testing.allocator, self.name, 3_000);
    }
};

const io_timeout_ms: u32 = 5_000;

fn request(c: *PipeClient, line: []const u8) ![]const u8 {
    try c.writeLine(line, io_timeout_ms);
    return c.readLine(io_timeout_ms);
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.log.err("expected {s} in {s}", .{ needle, hay });
        return error.TestUnexpectedResult;
    }
}

/// Polls `cond` every 5 ms for up to 5 s (server-side state the protocol
/// does not expose as an event).
fn waitFor(ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    var timer = try std.time.Timer.start();
    while (!cond(ctx)) {
        if (timer.read() > 5 * std.time.ns_per_s) return error.TestTimeout;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}

fn liveIsZero(s: *PipeServer) bool {
    return s.counts().live == 0;
}

fn liveIsOne(s: *PipeServer) bool {
    return s.counts().live == 1;
}

// ---------------------------------------------------------------------------
// Live tests (Windows only)
// ---------------------------------------------------------------------------

const ClientResult = struct { err: ?anyerror = null };

fn concurrentClient(f: *Fixture, k: usize, out: *ClientResult) void {
    concurrentClientInner(f, k) catch |err| {
        out.err = err;
    };
}

fn concurrentClientInner(f: *Fixture, k: usize) !void {
    var c = try f.connect();
    defer c.close();
    const per_client = 20;
    var buf: [128]u8 = undefined;
    // Pipeline every request first: replies must still come back in order.
    for (0..per_client) |i| {
        const m = if (i % 2 == 0) "test.echo" else "test.async";
        const line = try std.fmt.bufPrint(&buf, "{{\"id\":\"c{d}-{d}\",\"method\":\"{s}\",\"params\":{{\"n\":{d}}}}}", .{ k, i, m, i });
        try c.writeLine(line, io_timeout_ms);
    }
    for (0..per_client) |i| {
        const got = try c.readLine(io_timeout_ms);
        const want = try std.fmt.bufPrint(&buf, "{{\"id\":\"c{d}-{d}\",\"ok\":true,", .{ k, i });
        if (!std.mem.startsWith(u8, got, want)) {
            std.log.err("client {d} reply {d}: {s}", .{ k, i, got });
            return error.TestUnexpectedResult;
        }
    }
}

test "unit: rpc: live: 16 concurrent clients get pipelined replies in order" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .name = "" });
    defer f.deinit();
    var results: [16]ClientResult = @splat(.{});
    var threads: [16]std.Thread = undefined;
    for (&threads, &results, 0..) |*t, *r, k| t.* = try std.Thread.spawn(.{}, concurrentClient, .{ &f, k, r });
    for (threads) |t| t.join();
    for (results) |r| if (r.err) |err| return err;
}

test "unit: rpc: live: pool saturation and pending expiry answer overloaded" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .name = "", .limits = .{ .max_live = 2, .max_pending = 1, .pending_wait_ms = 300 } });
    defer f.deinit();
    var c1 = try f.connect();
    var c1_open = true;
    defer if (c1_open) c1.close();
    try expectContains(try request(&c1, "{\"id\":1,\"method\":\"test.echo\"}"), "\"ok\":true");
    var c2 = try f.connect();
    defer c2.close();
    try expectContains(try request(&c2, "{\"id\":2,\"method\":\"test.echo\"}"), "\"ok\":true");

    // Third client waits for a slot; the fourth finds no room at all.
    var c3 = try f.connect();
    defer c3.close();
    var c4 = try f.connect();
    defer c4.close();
    const sat = try c4.readLine(io_timeout_ms);
    try expectContains(sat, "\"code\":\"overloaded\"");
    try expectContains(sat, "\"reason\":\"pool_saturated\"");
    try expectContains(sat, "\"retryable\":true");
    try expectContains(sat, "\"retry_after_ms\":");
    try testing.expectError(error.Closed, c4.readLine(io_timeout_ms));

    // The server may already have answered and closed: ignore write errors.
    c3.writeLine("{\"id\":3,\"method\":\"test.echo\"}", io_timeout_ms) catch {};
    const expired = try c3.readLine(io_timeout_ms);
    try expectContains(expired, "\"reason\":\"pending_expired\"");
    try testing.expectError(error.Closed, c3.readLine(io_timeout_ms));

    // A freed slot admits the next client. Wait until the server has seen
    // c1 leave: before that, a new client would wait in the 300 ms pending
    // window and could expire on a loaded machine.
    c1.close();
    c1_open = false;
    try waitFor(f.server, liveIsOne);
    var c5 = try f.connect();
    defer c5.close();
    try expectContains(try request(&c5, "{\"id\":5,\"method\":\"test.echo\"}"), "\"id\":5,\"ok\":true");
}

test "unit: rpc: live: a waiting client is admitted when a slot frees" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .name = "", .limits = .{ .max_live = 1, .max_pending = 1, .pending_wait_ms = 10_000 } });
    defer f.deinit();
    var c1 = try f.connect();
    try expectContains(try request(&c1, "{\"id\":1,\"method\":\"test.echo\"}"), "\"ok\":true");
    var c2 = try f.connect();
    defer c2.close();
    try c2.writeLine("{\"id\":2,\"method\":\"test.echo\"}", io_timeout_ms);
    c1.close();
    try expectContains(try c2.readLine(io_timeout_ms), "\"id\":2,\"ok\":true");
}

test "unit: rpc: live: polling burst gets rate_limited with retry_after_ms" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .name = "" });
    defer f.deinit();
    var c = try f.connect();
    defer c.close();
    // Burst 9, one token per 100 ms: 30 polls see rate_limited unless
    // serving them takes over 2 s.
    const polls = 30;
    for (0..polls) |_| try c.writeLine("{\"id\":\"p\",\"method\":\"test.poll\"}", io_timeout_ms);
    var limited: usize = 0;
    for (0..polls) |i| {
        const got = try c.readLine(io_timeout_ms);
        if (i == 0) try expectContains(got, "\"ok\":true");
        if (std.mem.indexOf(u8, got, "\"code\":\"rate_limited\"") != null) {
            try expectContains(got, "\"retry_after_ms\":");
            limited += 1;
        }
    }
    try testing.expect(limited >= 1);
}

test "unit: rpc: live: an oversized line is answered and the connection keeps working" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .name = "" });
    defer f.deinit();
    var c = try f.connect();
    defer c.close();
    const big = try testing.allocator.alloc(u8, PipeServer.framer.default_max_line + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try c.writeAll(big, io_timeout_ms);
    try c.writeAll("\n{\"id\":9,\"method\":\"test.echo\"}\n", io_timeout_ms);
    const first = try c.readLine(io_timeout_ms);
    try expectContains(first, "\"code\":\"invalid_request\",\"message\":\"Request too large\"");
    try expectContains(first, "\"max_bytes\":1048576");
    try expectContains(try c.readLine(io_timeout_ms), "\"id\":9,\"ok\":true");
    // Malformed input goes to the dispatcher, which answers it.
    try expectContains(try request(&c, "\xff\xfe"), "\"code\":\"invalid_utf8\"");
}

test "unit: rpc: live: a deferred reply for a departed client never reaches the slot's next client" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .name = "", .limits = .{ .max_live = 1, .max_pending = 0 } });
    defer f.deinit();
    var c1 = try f.connect();
    try c1.writeLine("{\"id\":\"old\",\"method\":\"test.defer\",\"params\":{\"deadline_ms\":200}}", io_timeout_ms);
    const t1 = try f.handler.waitParked(1);
    c1.close(); // disconnect mid-request
    // The request keeps its slot until its deadline, then the slot frees.
    try waitFor(f.server, liveIsZero);
    // The completion arrives after the client left: dropped.
    try testing.expectEqual(PipeServer.Completion.dropped, f.server.complete(t1, "{\"id\":\"old\",\"ok\":true,\"result\":{}}"));

    var c2 = try f.connect();
    defer c2.close();
    try c2.writeLine("{\"id\":\"new\",\"method\":\"test.defer\"}", io_timeout_ms);
    const t2 = try f.handler.waitParked(2);
    try testing.expectEqual(t1.conn_id, t2.conn_id); // same slot
    try testing.expectEqual(t1.request_seq, t2.request_seq); // same request number
    try testing.expect(t2.generation != t1.generation);
    // A stale completion racing the new client's request is still dropped.
    try testing.expectEqual(PipeServer.Completion.dropped, f.server.complete(t1, "{\"id\":\"old\",\"ok\":true,\"result\":{}}"));
    try testing.expectEqual(PipeServer.Completion.delivered, f.server.complete(t2, "{\"id\":\"new\",\"ok\":true,\"result\":{}}"));
    try testing.expectEqual(PipeServer.Completion.dropped, f.server.complete(t2, "{\"id\":\"twice\",\"ok\":true,\"result\":{}}"));
    try testing.expectEqualStrings("{\"id\":\"new\",\"ok\":true,\"result\":{}}", try c2.readLine(io_timeout_ms));
    try expectContains(try request(&c2, "{\"id\":\"next\",\"method\":\"test.echo\"}"), "\"id\":\"next\",\"ok\":true");
}

test "unit: rpc: live: deadlines answer timeout, retryable only when the request never ran" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .name = "" });
    defer f.deinit();
    var c = try f.connect();
    defer c.close();
    const queued = try request(&c, "{\"id\":\"q\",\"method\":\"test.queue\",\"params\":{\"deadline_ms\":150}}");
    try expectContains(queued, "\"id\":\"q\",\"ok\":false,\"error\":{\"code\":\"timeout\"");
    try expectContains(queued, "\"stage\":\"main_actor\",\"deadline_ms\":150,\"retryable\":true");
    const tq = try f.handler.waitParked(1);
    try testing.expect(!f.server.begin(tq)); // the UI thread skips expired requests

    const running = try request(&c, "{\"id\":\"r\",\"method\":\"test.defer\",\"params\":{\"deadline_ms\":150}}");
    try expectContains(running, "\"retryable\":false");
    const tr = try f.handler.waitParked(2);
    try testing.expectEqual(PipeServer.Completion.dropped, f.server.complete(tr, "{\"id\":\"r\",\"ok\":true,\"result\":{}}"));
    try expectContains(try request(&c, "{\"id\":\"after\",\"method\":\"test.echo\"}"), "\"id\":\"after\",\"ok\":true");
}

test "unit: rpc: live: shutdown with pending reads and in-flight requests joins quickly" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .name = "" });
    var stopped = false;
    defer if (!stopped) f.deinit();
    var idle: [4]PipeClient = undefined;
    for (&idle) |*c| {
        c.* = try f.connect();
        try expectContains(try request(c, "{\"id\":0,\"method\":\"test.echo\"}"), "\"ok\":true");
    }
    defer for (&idle) |*c| c.close();
    var queued = try f.connect();
    defer queued.close();
    try queued.writeLine("{\"id\":\"q\",\"method\":\"test.queue\",\"params\":{\"deadline_ms\":0}}", io_timeout_ms);
    var deferred = try f.connect();
    defer deferred.close();
    try deferred.writeLine("{\"id\":\"d\",\"method\":\"test.defer\",\"params\":{\"deadline_ms\":0}}", io_timeout_ms);
    _ = try f.handler.waitParked(2);
    const td = f.handler.parked.items[1];

    var timer = try std.time.Timer.start();
    f.server.stop();
    try testing.expect(timer.read() < 3 * std.time.ns_per_s);
    try testing.expectEqual(PipeServer.Completion.dropped, f.server.complete(td, "{}"));
    try testing.expect(!f.server.begin(f.handler.parked.items[0]));
    f.deinit();
    stopped = true;

    const q = try queued.readLine(io_timeout_ms);
    try expectContains(q, "\"id\":\"q\",\"ok\":false,\"error\":{\"code\":\"overloaded\"");
    try expectContains(q, "\"reason\":\"server_stopping\"");
    const d = try deferred.readLine(io_timeout_ms);
    try expectContains(d, "\"id\":\"d\",\"ok\":false,\"error\":{\"code\":\"cancelled\"");
    for (&idle) |*c| try testing.expectError(error.Closed, c.readLine(io_timeout_ms));
}

test "unit: rpc: live: a second server on the same name fails with PipeNameInUse" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .name = "" });
    defer f.deinit();
    var h2: TestHandler = undefined;
    try h2.init(testing.allocator);
    defer h2.deinit();
    try testing.expectError(error.PipeNameInUse, PipeServer.start(testing.allocator, .{ .name = f.name }, h2.handler()));
}

/// Connects and leaves at once, counting connects that found no pipe.
const Prober = struct {
    name: []const u8,
    budget_ns: u64,
    connects: usize = 0,
    not_found: usize = 0,
    err: ?anyerror = null,

    fn run(self: *Prober) void {
        var timer = std.time.Timer.start() catch |err| {
            self.err = err;
            return;
        };
        while (timer.read() < self.budget_ns) {
            var c = PipeClient.connect(testing.allocator, self.name, 1_000) catch |err| switch (err) {
                error.NotFound => {
                    self.not_found += 1;
                    continue;
                },
                error.Busy => continue,
                else => {
                    self.err = err;
                    return;
                },
            };
            self.connects += 1;
            c.close();
        }
    }
};

test "unit: rpc: live: the pipe name never disappears while clients connect and leave at once" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(.{ .name = "" });
    defer f.deinit();
    // These clients send nothing, so each connection closes its instance
    // right away. With no instance open the name does not exist: a client
    // gets ERROR_FILE_NOT_FOUND and another process could claim the name.
    var probers: [2]Prober = @splat(.{ .name = f.name, .budget_ns = 400 * std.time.ns_per_ms });
    var threads: [2]std.Thread = undefined;
    for (&threads, &probers) |*t, *p| t.* = try std.Thread.spawn(.{}, Prober.run, .{p});
    for (threads) |t| t.join();
    for (probers) |p| {
        if (p.err) |err| return err;
        try testing.expectEqual(@as(usize, 0), p.not_found);
        try testing.expect(p.connects > 0);
    }
}

const LaunchSink = struct {
    mutex: std.Thread.Mutex = .{},
    calls: usize = 0,
    intent: ?launch_pipe.Intent = null,
    first_path_len: usize = 0,
    client_pid: u32 = 0,

    fn onLaunch(ctx: ?*anyopaque, req: *const launch_pipe.LaunchRequest, client_pid: u32) bool {
        const self: *LaunchSink = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.calls += 1;
        self.intent = req.intent;
        self.first_path_len = if (req.paths.len > 0) req.paths[0].len else 0;
        self.client_pid = client_pid;
        return true;
    }
};

test "unit: rpc: live: launch pipe is claimed once and hands off app.launch" {
    if (!is_windows) return error.SkipZigTest;
    var control_buf: [64]u8 = undefined;
    const control = testPipeName(&control_buf);
    const name = try proto.pipe_name.launchName(testing.allocator, control);
    defer testing.allocator.free(name);

    var sink: LaunchSink = .{};
    const first = try launch_pipe.LaunchPipe.claim(testing.allocator, name, LaunchSink.onLaunch, &sink, .{});
    const lp = first.serving;
    defer lp.deinit();
    const second = try launch_pipe.LaunchPipe.claim(testing.allocator, name, LaunchSink.onLaunch, &sink, .{});
    try testing.expect(second == .exists);

    const reply = try launch_pipe.sendLaunch(testing.allocator, name, .{
        .intent = .open,
        .argv = &.{ "wmux.exe", "C:\\proj\\\xc3\xa9" },
        .cwd = "C:\\proj",
        .paths = &.{"C:\\proj\\\xc3\xa9"},
    }, io_timeout_ms);
    try testing.expect(reply.accepted);
    const own_pid = std.os.windows.GetCurrentProcessId();
    try testing.expectEqual(own_pid, reply.pid);
    sink.mutex.lock();
    defer sink.mutex.unlock();
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqual(launch_pipe.Intent.open, sink.intent.?);
    try testing.expectEqual(@as(usize, "C:\\proj\\\xc3\xa9".len), sink.first_path_len);
    try testing.expectEqual(own_pid, sink.client_pid);
}

test "unit: rpc: live: launch pipe answers only app.launch" {
    if (!is_windows) return error.SkipZigTest;
    var control_buf: [64]u8 = undefined;
    const name = try proto.pipe_name.launchName(testing.allocator, testPipeName(&control_buf));
    defer testing.allocator.free(name);
    var sink: LaunchSink = .{};
    const lp = (try launch_pipe.LaunchPipe.claim(testing.allocator, name, LaunchSink.onLaunch, &sink, .{})).serving;
    defer lp.deinit();
    var c = try PipeClient.connect(testing.allocator, name, 3_000);
    defer c.close();
    try testing.expect(c.serverIsSameUser());
    try expectContains(try request(&c, "{\"id\":1,\"method\":\"system.ping\"}"), "\"code\":\"method_not_found\"");
    try expectContains(try request(&c, "{\"id\":2,\"method\":\"app.launch\",\"params\":{\"intent\":\"nope\"}}"), "\"message\":\"Invalid intent\"");
    try testing.expectEqual(@as(usize, 0), sink.calls);
}

test "unit: rpc: live: connecting to a missing pipe fails fast with NotFound" {
    if (!is_windows) return error.SkipZigTest;
    var buf: [64]u8 = undefined;
    try testing.expectError(error.NotFound, PipeClient.connect(testing.allocator, testPipeName(&buf), 1_000));
}
