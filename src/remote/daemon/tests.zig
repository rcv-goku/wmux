//! Test root for the wmuxd-remote daemon: unit tests of every daemon file
//! plus integration tests that drive a real server over pipes.

test {
    _ = @import("args.zig");
    _ = @import("fsops.zig");
    _ = @import("handlers.zig");
    _ = @import("paths.zig");
    _ = @import("persistent.zig");
    _ = @import("pty.zig");
    _ = @import("ring.zig");
    _ = @import("server.zig");
    _ = @import("session.zig");
    _ = @import("sizing.zig");
}

const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const remote = @import("wmux_proto").remote;
const rpc = remote.rpc;
const msgs = remote.messages;
const Server = @import("server.zig").Server;
const Config = @import("server.zig").Config;
const Client = @import("client.zig").Client;

const timeout = 10_000;

/// A server running `serve --stdio` semantics on a pipe pair in a thread.
const StdioHarness = struct {
    srv: Server,
    thread: std.Thread,
    client: Client,
    err: ?anyerror = null,

    fn start(gpa: std.mem.Allocator, cfg: Config) !*StdioHarness {
        const h = try gpa.create(StdioHarness);
        errdefer gpa.destroy(h);
        const to_srv = try posix.pipe2(.{ .CLOEXEC = true });
        const from_srv = try posix.pipe2(.{ .CLOEXEC = true });
        h.* = .{ .srv = .init(gpa, cfg), .thread = undefined, .client = .init(gpa, from_srv[0], to_srv[1], true) };
        _ = try h.srv.addConn(to_srv[0], from_srv[1], true);
        h.thread = try std.Thread.spawn(.{}, runThread, .{h});
        return h;
    }

    fn runThread(h: *StdioHarness) void {
        h.srv.run() catch |e| {
            h.err = e;
        };
    }

    /// Closing the client's write end is EOF for the server, which then
    /// kills its sessions and returns.
    fn stop(h: *StdioHarness) void {
        const gpa = h.srv.gpa;
        posix.close(h.client.wfd);
        h.client.wfd = h.client.rfd;
        h.thread.join();
        h.srv.deinit();
        h.client.deinit();
        gpa.destroy(h);
    }
};

fn homeCfg(home: []const u8) Config {
    return .{ .home = home, .kill_grace_ms = 500 };
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

fn int(v: std.json.Value, key: []const u8) i64 {
    return v.object.get(key).?.integer;
}

test "unit: remote-daemon: hello is enforced and negotiated" {
    const h = try StdioHarness.start(testing.allocator, homeCfg("/tmp"));
    defer h.stop();
    const c = &h.client;
    const early = try c.request(.ping, .{}, timeout);
    try testing.expect(!early.ok);
    try testing.expectEqualStrings("hello_required", early.code.?);
    const bad = try c.request(.hello, msgs.HelloParams{ .protocol_version = 99 }, timeout);
    try testing.expectEqualStrings("version_mismatch", bad.code.?);
    const ok = try c.hello(true, timeout);
    try testing.expect(ok.ok);
    try testing.expectEqualStrings(rpc.daemon_version, str(ok.result, "version"));
    try testing.expect(ok.result.object.get("binary_frames").?.bool);
    try testing.expect(!ok.result.object.get("persistent").?.bool);
    const again = try c.hello(true, timeout);
    try testing.expectEqualStrings("invalid_state", again.code.?);
    const pong = try c.request(.ping, .{}, timeout);
    try testing.expect(pong.result.object.get("pong").?.bool);
    const unknown = try c.request(.hello, .{}, timeout);
    try testing.expectEqualStrings("invalid_params", unknown.code.?);
}

test "unit: remote-daemon: unknown methods, malformed lines and stubs" {
    const h = try StdioHarness.start(testing.allocator, homeCfg("/tmp"));
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(false, timeout);
    try c.writeAll("{\"id\":5,\"method\":\"nope.nope\"}\n");
    const unk = try c.nextReply(timeout);
    try testing.expectEqual(@as(i64, 5), unk.id.?.int);
    try testing.expectEqualStrings("method_not_found", unk.code.?);
    try testing.expectEqualStrings("unknown method: nope.nope", unk.message.?);
    for ([_]rpc.Method{ .proxy_open, .proxy_close, .proxy_write, .proxy_stream_subscribe, .relay_accept }) |m| {
        const s = try c.request(m, .{}, timeout);
        try testing.expectEqualStrings("not_supported", s.code.?);
        try testing.expect(std.mem.endsWith(u8, s.message.?, "is not implemented in this package"));
    }
    try c.writeAll("{not json\n");
    try testing.expectEqualStrings("parse_error", (try c.nextReply(timeout)).code.?);
    try c.writeAll("{\"id\":9,\"method\":7}\n");
    const inv = try c.nextReply(timeout);
    try testing.expectEqualStrings("invalid_request", inv.code.?);
    try testing.expectEqual(@as(i64, 9), inv.id.?.int);
    try c.writeAll("[1,2]\n\n\r\n");
    try testing.expectEqualStrings("invalid_request", (try c.nextReply(timeout)).code.?);
    try testing.expect((try c.request(.ping, .{}, timeout)).ok);
}

const sh_cmd: []const []const u8 = &.{"/bin/sh"};
const sh_env: []const []const u8 = &.{ "PS1=$ ", "ENV=" };

fn openSh(c: *Client, sid: ?[]const u8, cols: u32, rows: u32) ![]const u8 {
    const r = try c.request(.session_open, msgs.SessionOpenParams{ .session_id = sid, .cols = cols, .rows = rows, .command = sh_cmd, .env = sh_env }, timeout);
    if (!r.ok) {
        std.log.warn("session.open failed: {s}", .{r.message.?});
        return error.TestUnexpectedResult;
    }
    return str(r.result, "session_id");
}

fn ptyAttach(c: *Client, sid: []const u8, cols: u32, rows: u32) !struct { aid: []const u8, channel: u32, replay: i64 } {
    const r = try c.request(.pty_attach, msgs.AttachParams{ .session_id = sid, .cols = cols, .rows = rows }, timeout);
    try testing.expect(r.ok);
    return .{ .aid = str(r.result, "attachment_id"), .channel = @intCast(int(r.result, "channel")), .replay = int(r.result, "replay_bytes") };
}

fn typeLine(c: *Client, sid: []const u8, line: []const u8) !void {
    var b64: [512]u8 = undefined;
    const enc = std.base64.standard.Encoder.encode(&b64, line);
    const r = try c.request(.pty_write, msgs.PtyWriteParams{ .session_id = sid, .data = enc }, timeout);
    try testing.expect(r.ok);
}

test "unit: remote-daemon: pty session runs echo, resizes smallest-wins and replays on reattach" {
    const h = try StdioHarness.start(testing.allocator, homeCfg("/tmp"));
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(true, timeout);
    const sid = try openSh(c, "itest-1", 100, 40);
    try testing.expectEqualStrings("itest-1", sid);
    const dup = try c.request(.session_open, msgs.SessionOpenParams{ .session_id = "itest-1", .command = sh_cmd }, timeout);
    try testing.expectEqualStrings("invalid_state", dup.code.?);

    const a1 = try ptyAttach(c, sid, 120, 50);
    try typeLine(c, sid, "echo hi-$((40+2))\n");
    try c.waitData(a1.channel, "hi-42", timeout);

    // Binary-frame input on the channel works too.
    try c.writeFrame(a1.channel, "echo fr-$((1+1))\n");
    try c.waitData(a1.channel, "fr-2", timeout);

    // A second, smaller attachment shrinks the PTY; per-dimension minimum.
    const a2 = try c.request(.session_attach, msgs.AttachParams{ .session_id = sid, .cols = 90, .rows = 60 }, timeout);
    try testing.expectEqual(@as(i64, 90), int(a2.result, "cols"));
    try testing.expectEqual(@as(i64, 50), int(a2.result, "rows"));
    try typeLine(c, sid, "stty size\n");
    try c.waitData(a1.channel, "50 90", timeout);
    // Resize the first attachment below the second.
    const rz = try c.request(.pty_resize, msgs.ResizeParams{ .attachment_id = a1.aid, .cols = 70, .rows = 20 }, timeout);
    try testing.expectEqual(@as(i64, 70), int(rz.result, "cols"));
    try testing.expectEqual(@as(i64, 20), int(rz.result, "rows"));
    const bad = try c.request(.pty_resize, msgs.ResizeParams{ .attachment_id = a1.aid, .cols = 0, .rows = 20 }, timeout);
    try testing.expectEqualStrings("invalid_params", bad.code.?);
    // Detaching the smaller one grows to the next smallest.
    const d1 = try c.request(.pty_detach, msgs.AttachmentIdParams{ .attachment_id = a1.aid }, timeout);
    try testing.expectEqual(@as(i64, 90), int(d1.result, "cols"));
    try testing.expectEqual(@as(i64, 60), int(d1.result, "rows"));
    try testing.expectEqual(@as(i64, 1), int(d1.result, "attachments"));
    // Detach all: the size is kept.
    const a2id = str(a2.result, "attachment_id");
    const d2 = try c.request(.session_detach, msgs.AttachmentIdParams{ .attachment_id = a2id }, timeout);
    try testing.expectEqual(@as(i64, 90), int(d2.result, "cols"));
    try testing.expectEqual(@as(i64, 0), int(d2.result, "attachments"));
    const gone = try c.request(.session_detach, msgs.AttachmentIdParams{ .attachment_id = a2id }, timeout);
    try testing.expectEqualStrings("not_found", gone.code.?);

    // Output produced while detached lands in the ring and is replayed.
    try typeLine(c, sid, "echo while-$((6*7))-detached\n");
    std.Thread.sleep(300 * std.time.ns_per_ms);
    const st = try c.request(.session_status, msgs.SessionIdParams{ .session_id = sid }, timeout);
    try testing.expectEqual(@as(i64, 0), int(st.result, "attachments"));
    try testing.expect(st.result.object.get("alive").?.bool);
    const a3 = try ptyAttach(c, sid, 200, 200);
    try testing.expect(a3.replay > 0);
    try c.waitData(a3.channel, "while-42-detached", timeout);
    try testing.expect(std.mem.indexOf(u8, c.channelData(a3.channel), "hi-42") != null);
    const st2 = try c.request(.session_status, msgs.SessionIdParams{ .session_id = sid }, timeout);
    try testing.expectEqual(@as(i64, 200), int(st2.result, "cols"));

    const lst = try c.request(.pty_list, .{}, timeout);
    const sessions = lst.result.object.get("sessions").?.array.items;
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqualStrings("itest-1", str(sessions[0], "session_id"));
    try testing.expectEqual(@as(i64, 1), int(sessions[0], "attachments"));
    try testing.expect(int(sessions[0], "scrollback_bytes") > 0);

    // The shell exiting ends the session with pty.exit.
    try typeLine(c, sid, "exit 7\n");
    const ev = try c.waitEvent(msgs.event_pty_exit, timeout);
    try testing.expectEqualStrings("itest-1", str(ev.params, "session_id"));
    try testing.expectEqual(@as(i64, 7), int(ev.params, "exit_code"));
    const after = try c.request(.session_status, msgs.SessionIdParams{ .session_id = sid }, timeout);
    try testing.expectEqualStrings("not_found", after.code.?);
}

test "unit: remote-daemon: without binary frames data arrives as pty.data events; close kills the shell" {
    const h = try StdioHarness.start(testing.allocator, homeCfg("/tmp"));
    defer h.stop();
    const c = &h.client;
    const hr = try c.hello(false, timeout);
    try testing.expect(!hr.result.object.get("binary_frames").?.bool);
    const sid = try openSh(c, null, 80, 24);
    try testing.expect(std.mem.startsWith(u8, sid, "s-"));
    const a = try ptyAttach(c, sid, 80, 24);
    try typeLine(c, sid, "printf 'caf\\303\\251-%s\\n' ok\n");
    try c.waitData(a.channel, "café-ok", timeout);
    const ev = try c.waitEvent(msgs.event_pty_data, timeout);
    try testing.expectEqualStrings(sid, str(ev.params, "session_id"));

    const pid = int((try c.request(.session_status, msgs.SessionIdParams{ .session_id = sid }, timeout)).result, "pid");
    const closed = try c.request(.pty_close, msgs.SessionIdParams{ .session_id = sid }, timeout);
    try testing.expect(closed.ok);
    try testing.expectEqualStrings("not_found", (try c.request(.pty_close, msgs.SessionIdParams{ .session_id = sid }, timeout)).code.?);
    try testing.expectEqualStrings("not_found", (try c.request(.pty_write, msgs.PtyWriteParams{ .session_id = sid, .data = "eA==" }, timeout)).code.?);
    // The process is reaped by the server (kill(pid, 0) fails once gone).
    var tries: usize = 0;
    while (std.c.kill(@intCast(pid), 0) == 0 and tries < 200) : (tries += 1) std.Thread.sleep(10 * std.time.ns_per_ms);
    try testing.expect(std.c.kill(@intCast(pid), 0) != 0);
}

test "unit: remote-daemon: request validation errors" {
    const h = try StdioHarness.start(testing.allocator, homeCfg("/tmp"));
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(true, timeout);
    const cases = [_]struct { rpc.Method, []const u8, []const u8 }{
        .{ .session_open, "{\"cols\":0}", "invalid_params" },
        .{ .session_open, "{\"cols\":10001}", "invalid_params" },
        .{ .session_open, "{\"session_id\":\"a/b\"}", "invalid_params" },
        .{ .session_open, "{\"command\":[]}", "invalid_params" },
        .{ .session_open, "{\"command\":[\"/definitely/not/here\"]}", "not_found" },
        .{ .session_open, "{\"command\":[\"not-on-path-wmux\"]}", "not_found" },
        .{ .session_attach, "{\"session_id\":\"nope\",\"cols\":1,\"rows\":1}", "not_found" },
        .{ .session_attach, "{\"session_id\":\"nope\"}", "invalid_params" },
        .{ .session_status, "{}", "invalid_params" },
        .{ .pty_write, "{\"session_id\":\"nope\",\"data\":\"!!\"}", "not_found" },
        .{ .pty_resize, "{\"attachment_id\":\"a-999\",\"cols\":1,\"rows\":1}", "not_found" },
    };
    for (cases) |cs| {
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{{\"id\":1000,\"method\":\"{s}\",\"params\":{s}}}\n", .{ cs[0].wireName(), cs[1] });
        try c.writeAll(line);
        const r = try c.nextReply(timeout);
        testing.expectEqualStrings(cs[2], r.code orelse "ok") catch |e| {
            std.log.warn("case {s} {s}: got {s}", .{ cs[0].wireName(), cs[1], r.code orelse "ok" });
            return e;
        };
    }
    const sid = try openSh(c, null, 80, 24);
    const bad64 = try c.request(.pty_write, msgs.PtyWriteParams{ .session_id = sid, .data = "!!!" }, timeout);
    try testing.expectEqualStrings("invalid_params", bad64.code.?);
}

test "unit: remote-daemon: oversized frames close the connection after an error" {
    const h = try StdioHarness.start(testing.allocator, homeCfg("/tmp"));
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(true, timeout);
    var hdr: [remote.frame.header_len]u8 = undefined;
    remote.frame.encodeHeader(&hdr, .pty_data, 1, remote.frame.default_max_frame_len + 1);
    try c.writeAll(&hdr);
    const r = try c.nextReply(timeout);
    try testing.expectEqualStrings("too_large", r.code.?);
    try testing.expectError(error.EndOfStream, c.pump(std.time.milliTimestamp() + timeout));
}

test "unit: remote-daemon: fs.put and fs.get over the protocol" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    const h = try StdioHarness.start(gpa, homeCfg(home));
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(true, timeout);

    const content = "#!/bin/sh\necho ☃\n";
    var b64: [128]u8 = undefined;
    const enc = std.base64.standard.Encoder.encode(&b64, content);
    const digest = @import("fsops.zig").sha256Hex(content);
    const put = try c.request(.fs_put, msgs.FsPutParams{ .path = "~/.wmux/bin/tool", .data = enc, .mode = 0o755, .sha256 = &digest, .mkdirs = true }, timeout);
    try testing.expect(put.ok);
    try testing.expectEqualStrings(&digest, str(put.result, "sha256"));
    try testing.expectEqual(@as(i64, content.len), int(put.result, "size"));
    const st = try tmp.dir.statFile(".wmux/bin/tool");
    try testing.expectEqual(@as(std.fs.File.Mode, 0o755), st.mode & 0o777);
    // mkdirs created the missing parents private.
    const bin = try tmp.dir.statFile(".wmux/bin");
    try testing.expectEqual(@as(std.fs.File.Mode, 0o700), bin.mode & 0o777);

    const got = try c.request(.fs_get, msgs.FsGetParams{ .path = ".wmux/bin/tool" }, timeout);
    try testing.expectEqualStrings(enc, str(got.result, "data"));
    try testing.expectEqualStrings(&digest, str(got.result, "sha256"));

    const empty = try c.request(.fs_put, msgs.FsPutParams{ .path = "~/.wmux/bin/tool", .data = "" }, timeout);
    try testing.expectEqualStrings("invalid_params", empty.code.?);
    try testing.expectEqualStrings("refusing to write a 0-byte file", empty.message.?);
    const mismatch = try c.request(.fs_put, msgs.FsPutParams{ .path = "~/.wmux/bin/tool", .data = "eA==", .sha256 = &digest }, timeout);
    try testing.expectEqualStrings("sha256 mismatch", mismatch.message.?);
    const still = try c.request(.fs_get, msgs.FsGetParams{ .path = "~/.wmux/bin/tool" }, timeout);
    try testing.expectEqualStrings(enc, str(still.result, "data"));
    const small = try c.request(.fs_get, msgs.FsGetParams{ .path = "~/.wmux/bin/tool", .max_bytes = 3 }, timeout);
    try testing.expectEqualStrings("too_large", small.code.?);
    const missing = try c.request(.fs_get, msgs.FsGetParams{ .path = "~/nope" }, timeout);
    try testing.expectEqualStrings("not_found", missing.code.?);
    const noparent = try c.request(.fs_put, msgs.FsPutParams{ .path = "~/a/b/c", .data = "eA==" }, timeout);
    try testing.expectEqualStrings("not_found", noparent.code.?);
    const badpath = try c.request(.fs_put, msgs.FsPutParams{ .path = "", .data = "eA==" }, timeout);
    try testing.expectEqualStrings("invalid_params", badpath.code.?);
    const badmode = try c.request(.fs_put, msgs.FsPutParams{ .path = "~/x", .data = "eA==", .mode = 0o17777 }, timeout);
    try testing.expectEqualStrings("invalid_params", badmode.code.?);

    // A FIFO is refused at once instead of blocking the daemon.
    const fifo = try std.fs.path.joinZ(gpa, &.{ home, "fifo" });
    defer gpa.free(fifo);
    try testing.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o600));
    const from_fifo = try c.request(.fs_get, msgs.FsGetParams{ .path = "~/fifo" }, timeout);
    try testing.expectEqualStrings("invalid_params", from_fifo.code.?);
    try testing.expectEqualStrings("not a regular file", from_fifo.message.?);
    try testing.expect((try c.request(.ping, .{}, timeout)).ok);
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: posix.mode_t) c_int;

test "unit: remote-daemon: a max-size fs.get reply does not disconnect a streaming client" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    // A file at the fs.get limit: its reply is one ~22.4 MiB base64 line.
    {
        const big = try gpa.alloc(u8, msgs.max_fs_bytes);
        defer gpa.free(big);
        @memset(big, 'q');
        try tmp.dir.writeFile(.{ .sub_path = "big.bin", .data = big });
    }
    const h = try StdioHarness.start(gpa, homeCfg(home));
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(true, timeout);
    // A session that keeps producing output while the reply drains (the
    // marker is computed by the shell, so the typed echo never matches).
    const sid = try openSh(c, null, 80, 24);
    const a = try ptyAttach(c, sid, 80, 24);
    try typeLine(c, sid, "while :; do echo t-$((2+2)); sleep 0.02; done\n");
    try c.waitData(a.channel, "t-4", timeout);
    // Request the file, then stop reading for a while: the server can only
    // flush a pipe buffer's worth, and PTY output queues behind the reply.
    try c.writeAll("{\"id\":77,\"method\":\"fs.get\",\"params\":{\"path\":\"~/big.bin\"}}\n");
    std.Thread.sleep(500 * std.time.ns_per_ms);
    const r = try c.nextReply(120_000);
    try testing.expect(r.ok);
    try testing.expectEqual(@as(i64, 77), r.id.?.int);
    try testing.expectEqual(@as(i64, msgs.max_fs_bytes), int(r.result, "size"));
    // Still connected, and the session still streams to this client.
    try testing.expect((try c.request(.ping, .{}, timeout)).ok);
    const before = std.mem.count(u8, c.channelData(a.channel), "t-4");
    var tries: usize = 0;
    while (std.mem.count(u8, c.channelData(a.channel), "t-4") == before and tries < 100) : (tries += 1)
        c.pump(std.time.milliTimestamp() + 100) catch |e| if (e != error.Timeout) return e;
    try testing.expect(std.mem.count(u8, c.channelData(a.channel), "t-4") > before);
}

/// Pumps until `needle` shows up in the channel's output, scanning only the
/// bytes that arrived since the last look (the buffer may be megabytes).
fn waitTail(c: *Client, channel: u32, needle: []const u8, timeout_ms: i64) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    var from: usize = 0;
    while (true) {
        const data = c.channelData(channel);
        if (std.mem.indexOfPos(u8, data, from, needle) != null) return;
        from = (data.len + 1) -| needle.len;
        try c.pump(deadline);
    }
}

test "unit: remote-daemon: a slow streaming client throttles the PTY instead of being dropped" {
    var cfg = homeCfg("/tmp");
    // Small limits keep the test light: 12 MB of output is three times
    // max_outbound.
    cfg.max_outbound = 4 * 1024 * 1024;
    cfg.pty_high_water = 256 * 1024;
    const h = try StdioHarness.start(testing.allocator, cfg);
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(true, timeout);
    const sid = try openSh(c, null, 80, 24);
    const a = try ptyAttach(c, sid, 80, 24);
    try typeLine(c, sid, "head -c 12000000 /dev/zero | tr '\\000' x; echo; echo end-$((5*5))\n");
    // Not reading: output backs up behind the full pipe. Without flow
    // control the queue passes max_outbound and the server drops us.
    std.Thread.sleep(1500 * std.time.ns_per_ms);
    try waitTail(c, a.channel, "end-25", 60_000);
    try testing.expect(std.mem.count(u8, c.channelData(a.channel), "x") >= 12_000_000);
    try testing.expect((try c.request(.ping, .{}, timeout)).ok);
}

/// Ends the client's request stream (end of input for the server) while it
/// keeps reading. Harnesses close `wfd` again later, so it becomes a dup of
/// the read end.
fn halfClose(c: *Client) !void {
    posix.close(c.wfd);
    c.wfd = try posix.dup(c.rfd);
}

/// Pumps until the server ends the stream; a timeout fails the test.
fn expectEndOfStream(c: *Client) !void {
    const deadline = std.time.milliTimestamp() + timeout;
    while (true) c.pump(deadline) catch |e| {
        try testing.expectEqual(error.EndOfStream, e);
        return;
    };
}

test "unit: remote-daemon: a client whose input ended gets its replies, then end of stream" {
    var cfg = homeCfg("/tmp");
    cfg.max_outbound = 4 * 1024 * 1024;
    cfg.pty_high_water = 256 * 1024;
    const h = try StdioHarness.start(testing.allocator, cfg);
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(true, timeout);
    const sid = try openSh(c, null, 80, 24);
    const a = try ptyAttach(c, sid, 80, 24);
    try typeLine(c, sid, "while :; do head -c 65536 /dev/zero | tr '\\000' z; done\n");
    try c.waitData(a.channel, "zzzz", timeout);
    // Stop reading: the queue reaches the high water and holds the PTY.
    std.Thread.sleep(500 * std.time.ns_per_ms);
    // A last request, then end of input, and still no reading for a while.
    try c.writeAll("{\"id\":42,\"method\":\"ping\"}\n");
    try halfClose(c);
    std.Thread.sleep(1500 * std.time.ns_per_ms);
    // The reply arrives behind the output queued before, then the stream
    // ends. Output queued after the input ended would have run the queue
    // past max_outbound and dropped the reply along with the connection.
    const before = c.channelData(a.channel).len;
    const r = try c.nextReply(timeout);
    try testing.expectEqual(@as(i64, 42), r.id.?.int);
    try expectEndOfStream(c);
    try testing.expect(c.channelData(a.channel).len - before < 2 * 1024 * 1024);
}

test "unit: remote-daemon: a closing client that takes nothing is dropped after the stall timeout" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    {
        const blob = try gpa.alloc(u8, 512 * 1024);
        defer gpa.free(blob);
        @memset(blob, 'q');
        try tmp.dir.writeFile(.{ .sub_path = "blob.bin", .data = blob });
    }
    var cfg = homeCfg(home);
    cfg.stall_timeout_ms = 300;
    const h = try StdioHarness.start(gpa, cfg);
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(true, timeout);
    // The reply (~700 KiB of base64) fills the pipe and the rest stays
    // queued, below the high water. The client ends its input and does not
    // read: it is gone, and nothing but the stall timeout would notice.
    try c.writeAll("{\"id\":5,\"method\":\"fs.get\",\"params\":{\"path\":\"~/blob.bin\"}}\n");
    try halfClose(c);
    // Without reading, wait for the server to close its end of the pipe
    // (POLLHUP is reported while unread data is still buffered).
    const deadline = std.time.milliTimestamp() + timeout;
    while (true) {
        var fds = [_]posix.pollfd{.{ .fd = c.rfd, .events = 0, .revents = 0 }};
        _ = try posix.poll(&fds, 50);
        if (fds[0].revents & posix.POLL.HUP != 0) break;
        if (std.time.milliTimestamp() > deadline) return error.Timeout;
    }
    // Dropped: what the pipe held, then end of stream in mid-reply.
    try testing.expectError(error.EndOfStream, c.nextReply(timeout));
}

test "unit: remote-daemon: pipelined replies that arrive in one read are all kept" {
    const h = try StdioHarness.start(testing.allocator, homeCfg("/tmp"));
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(false, timeout);
    try c.writeAll("{\"id\":11,\"method\":\"ping\"}\n{\"id\":12,\"method\":\"ping\"}\n{\"id\":13,\"method\":\"pty.list\"}\n");
    var id: i64 = 11;
    while (id <= 13) : (id += 1) try testing.expectEqual(id, (try c.nextReply(timeout)).id.?.int);
    // `request` still pairs a reply with its request afterwards.
    try testing.expect((try c.request(.ping, .{}, timeout)).ok);
}

/// One server thread with two pipe-pair clients (`serve --stdio` loop).
const PairHarness = struct {
    srv: Server,
    thread: std.Thread,
    a: Client,
    b: Client,

    fn start(gpa: std.mem.Allocator, cfg: Config) !*PairHarness {
        const h = try gpa.create(PairHarness);
        errdefer gpa.destroy(h);
        h.srv = .init(gpa, cfg);
        inline for (.{ "a", "b" }) |name| {
            const to_srv = try posix.pipe2(.{ .CLOEXEC = true });
            const from_srv = try posix.pipe2(.{ .CLOEXEC = true });
            @field(h, name) = .init(gpa, from_srv[0], to_srv[1], true);
            _ = try h.srv.addConn(to_srv[0], from_srv[1], true);
        }
        h.thread = try std.Thread.spawn(.{}, runThread, .{&h.srv});
        return h;
    }

    fn runThread(srv: *Server) void {
        srv.run() catch {};
    }

    fn stop(h: *PairHarness) void {
        const gpa = h.srv.gpa;
        for ([_]*Client{ &h.a, &h.b }) |c| {
            posix.close(c.wfd);
            c.wfd = c.rfd;
        }
        h.thread.join();
        h.srv.deinit();
        h.a.deinit();
        h.b.deinit();
        gpa.destroy(h);
    }
};

test "unit: remote-daemon: a client that stops reading is dropped after the stall timeout" {
    var cfg = homeCfg("/tmp");
    cfg.pty_high_water = 64 * 1024;
    cfg.stall_timeout_ms = 500;
    const h = try PairHarness.start(testing.allocator, cfg);
    defer h.stop();
    _ = try h.a.hello(true, timeout);
    _ = try h.b.hello(true, timeout);
    const sid = try openSh(&h.a, null, 80, 24);
    _ = try ptyAttach(&h.a, sid, 80, 24);
    const b = try ptyAttach(&h.b, sid, 80, 24);
    // Steady output; `a` never reads again (a half-open bridge). Its queue
    // passes the high water and holds the session back until it is dropped.
    try typeLine(&h.b, sid, "while :; do head -c 30000 /dev/zero | tr '\\000' y; echo t-$((3+4)); done\n");
    var seen: usize = 0;
    var from: usize = 0;
    const deadline = std.time.milliTimestamp() + 20_000;
    while (seen < 200) {
        const data = h.b.channelData(b.channel);
        seen += std.mem.count(u8, data[from..], "t-7");
        from = data.len -| 2;
        try h.b.pump(deadline);
    }
    // `a` was disconnected: after the queued bytes it reads end of stream.
    while (true) h.a.pump(std.time.milliTimestamp() + timeout) catch |e| {
        try testing.expectEqual(error.EndOfStream, e);
        break;
    };
}

test "unit: remote-daemon: session.close tells the other clients; attachments are per connection" {
    const h = try PairHarness.start(testing.allocator, homeCfg("/tmp"));
    defer h.stop();
    _ = try h.a.hello(true, timeout);
    _ = try h.b.hello(false, timeout);
    const sid = try openSh(&h.a, "shared", 100, 40);
    _ = try ptyAttach(&h.a, sid, 100, 40);
    const bat = try h.b.request(.session_attach, msgs.AttachParams{ .session_id = sid, .cols = 90, .rows = 30 }, timeout);
    const b_aid = str(bat.result, "attachment_id");
    // session.resize drives the same smallest-wins coordinator.
    const rz = try h.b.request(.session_resize, msgs.ResizeParams{ .attachment_id = b_aid, .cols = 70, .rows = 50 }, timeout);
    try testing.expectEqual(@as(i64, 70), int(rz.result, "cols"));
    try testing.expectEqual(@as(i64, 40), int(rz.result, "rows"));
    try testing.expectEqual(@as(i64, 2), int(rz.result, "attachments"));
    // Another connection cannot resize or detach b's attachment.
    const foreign = try h.a.request(.session_resize, msgs.ResizeParams{ .attachment_id = b_aid, .cols = 10, .rows = 10 }, timeout);
    try testing.expectEqualStrings("not_found", foreign.code.?);
    const foreign_detach = try h.a.request(.session_detach, msgs.AttachmentIdParams{ .attachment_id = b_aid }, timeout);
    try testing.expectEqualStrings("not_found", foreign_detach.code.?);

    // a closes the session: b is told its attachment ended, a is not.
    const closed = try h.a.request(.session_close, msgs.SessionIdParams{ .session_id = sid }, timeout);
    try testing.expect(closed.ok);
    try testing.expectEqualStrings("shared", str(closed.result, "session_id"));
    const ev = try h.b.waitEvent(msgs.event_pty_detached, timeout);
    try testing.expectEqualStrings("shared", str(ev.params, "session_id"));
    try testing.expectEqualStrings(b_aid, str(ev.params, "attachment_id"));
    try testing.expectEqualStrings("session_closed", str(ev.params, "reason"));
    try testing.expect((try h.a.request(.ping, .{}, timeout)).ok);
    for (h.a.events.items) |e| try testing.expect(!std.mem.eql(u8, e.name, msgs.event_pty_detached));
    const gone = try h.b.request(.session_status, msgs.SessionIdParams{ .session_id = sid }, timeout);
    try testing.expectEqualStrings("not_found", gone.code.?);
}

const persistent = @import("persistent.zig");

/// A persistent slot server on a Unix socket under a temporary home.
const SlotHarness = struct {
    gpa: std.mem.Allocator,
    tmp: testing.TmpDir,
    home: []u8,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    err: ?anyerror = null,
    slot: persistent.Slot = undefined,

    fn start(gpa: std.mem.Allocator, opts: persistent.ServerOptions) !*SlotHarness {
        const h = try gpa.create(SlotHarness);
        h.* = .{ .gpa = gpa, .tmp = testing.tmpDir(.{}), .home = undefined };
        h.home = try h.tmp.dir.realpathAlloc(gpa, ".");
        h.slot = try persistent.Slot.init(gpa, h.home, "ws-test");
        var o = opts;
        o.stop_flag = &h.stop_flag;
        o.kill_grace_ms = 500;
        h.thread = try std.Thread.spawn(.{}, run, .{ h, o });
        // Wait for the socket.
        var tries: usize = 0;
        while (tries < 500) : (tries += 1) {
            if (persistent.connect(h.slot.sock)) |fd| {
                posix.close(fd);
                break;
            } else |_| std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        return h;
    }

    fn run(h: *SlotHarness, o: persistent.ServerOptions) void {
        persistent.runServer(h.gpa, h.home, "ws-test", o) catch |e| {
            h.err = e;
        };
    }

    fn connect(h: *SlotHarness) !Client {
        const fd = try persistent.connect(h.slot.sock);
        return Client.init(h.gpa, fd, fd, true);
    }

    fn stop(h: *SlotHarness) void {
        h.stop_flag.store(true, .release);
        h.thread.join();
        h.slot.deinit(h.gpa);
        h.gpa.free(h.home);
        h.tmp.cleanup();
        h.gpa.destroy(h);
    }
};

test "unit: remote-daemon: persistent sessions survive client detach and replay on reattach" {
    const gpa = testing.allocator;
    const h = try SlotHarness.start(gpa, .{});
    defer h.stop();

    var c1 = try h.connect();
    const hr = try c1.hello(true, timeout);
    try testing.expect(hr.result.object.get("persistent").?.bool);
    try testing.expectEqualStrings("ws-test", str(hr.result, "slot"));
    var has_cap = false;
    for (hr.result.object.get("capabilities").?.array.items) |cap| {
        if (std.mem.eql(u8, cap.string, rpc.cap_persistent)) has_cap = true;
    }
    try testing.expect(has_cap);
    const sid = "keep-me";
    _ = try openSh(&c1, sid, 80, 24);
    const a1 = try ptyAttach(&c1, sid, 80, 24);
    try typeLine(&c1, sid, "echo first-$((20+3))\n");
    try c1.waitData(a1.channel, "first-23", timeout);
    const pid = int((try c1.request(.session_status, msgs.SessionIdParams{ .session_id = sid }, timeout)).result, "pid");
    // Client goes away without detaching (connection drop).
    c1.deinit();

    var c2 = try h.connect();
    defer c2.deinit();
    _ = try c2.hello(true, timeout);
    // The server notices the drop asynchronously.
    var atts: i64 = -1;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        const st = try c2.request(.session_status, msgs.SessionIdParams{ .session_id = sid }, timeout);
        try testing.expect(st.ok);
        atts = int(st.result, "attachments");
        try testing.expectEqual(pid, int(st.result, "pid"));
        try testing.expectEqual(@as(i64, 80), int(st.result, "cols"));
        if (atts == 0) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(i64, 0), atts);
    const a2 = try ptyAttach(&c2, sid, 100, 30);
    try c2.waitData(a2.channel, "first-23", timeout);
    try typeLine(&c2, sid, "echo second-$((40+4)); stty size\n");
    try c2.waitData(a2.channel, "second-44", timeout);
    try c2.waitData(a2.channel, "30 100", timeout);

    // status sees the running slot and its session.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try persistent.writeStatus(gpa, &aw.writer, h.home, null, false);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "ws-test running pid=") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "sessions=1 attachments=1") != null);
    aw.clearRetainingCapacity();
    try persistent.writeStatus(gpa, &aw.writer, h.home, "ws-test", true);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"running\":true") != null);
}

/// The bridge side of `serve --stdio --persistent` in a thread: pumps
/// between a pipe pair and the slot socket, then closes all three.
const BridgePump = struct {
    fn run(in_fd: posix.fd_t, out_fd: posix.fd_t, s: posix.fd_t) void {
        persistent.pump(in_fd, out_fd, s, null) catch {};
        posix.close(s);
        posix.close(in_fd);
        posix.close(out_fd);
    }
};

test "unit: remote-daemon: stdio bridge pumps bytes to the slot server" {
    const gpa = testing.allocator;
    const h = try SlotHarness.start(gpa, .{});
    defer h.stop();
    const to_bridge = try posix.pipe2(.{ .CLOEXEC = true });
    const from_bridge = try posix.pipe2(.{ .CLOEXEC = true });
    const sock = try persistent.connect(h.slot.sock);
    const t = try std.Thread.spawn(.{}, BridgePump.run, .{ to_bridge[0], from_bridge[1], sock });
    var c = Client.init(gpa, from_bridge[0], to_bridge[1], true);
    _ = try c.hello(true, timeout);
    const sid = try openSh(&c, null, 80, 24);
    const a = try ptyAttach(&c, sid, 80, 24);
    try typeLine(&c, sid, "echo via-bridge-$((1+2))\n");
    try c.waitData(a.channel, "via-bridge-3", timeout);
    // Closing stdin ends the bridge; the session stays in the server.
    c.deinit();
    t.join();
    var c2 = try h.connect();
    defer c2.deinit();
    _ = try c2.hello(false, timeout);
    const lst = try c2.request(.pty_list, .{}, timeout);
    try testing.expectEqual(@as(usize, 1), lst.result.object.get("sessions").?.array.items.len);
}

test "unit: remote-daemon: the bridge relays end of input and still delivers every reply" {
    const gpa = testing.allocator;
    const h = try SlotHarness.start(gpa, .{});
    defer h.stop();
    const to_bridge = try posix.pipe2(.{ .CLOEXEC = true });
    const from_bridge = try posix.pipe2(.{ .CLOEXEC = true });
    const sock = try persistent.connect(h.slot.sock);
    const t = try std.Thread.spawn(.{}, BridgePump.run, .{ to_bridge[0], from_bridge[1], sock });
    defer t.join();
    var c = Client.init(gpa, from_bridge[0], to_bridge[1], true);
    defer c.deinit();
    // A one-shot script (`printf ... | wmuxd-remote serve --stdio
    // --persistent`): pipelined requests, then end of input at once.
    try c.writeAll("{\"id\":1,\"method\":\"hello\",\"params\":{\"protocol_version\":1}}\n" ++
        "{\"id\":2,\"method\":\"ping\"}\n" ++
        "{\"id\":3,\"method\":\"pty.list\"}\n");
    try halfClose(&c);
    var id: i64 = 1;
    while (id <= 3) : (id += 1) {
        const r = try c.nextReply(timeout);
        try testing.expect(r.ok);
        try testing.expectEqual(id, r.id.?.int);
    }
    // The server closes the connection after its replies, and the bridge
    // follows, as `serve --stdio` would.
    try expectEndOfStream(&c);
}

test "unit: remote-daemon: a second server for the same slot is refused" {
    const gpa = testing.allocator;
    const h = try SlotHarness.start(gpa, .{});
    defer h.stop();
    try testing.expectError(error.AlreadyRunning, persistent.runServer(gpa, h.home, "ws-test", .{}));
    try testing.expect(persistent.lockHeld(h.slot.lock));
    try testing.expect(persistent.readPid(h.slot.pid) != null);
}

test "unit: remote-daemon: a brief probe of the slot lock does not stop a server from starting" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    var slot = try persistent.Slot.init(gpa, home, "probe");
    defer slot.deinit(gpa);
    try persistent.ensurePrivateDir(slot.dir);
    // Hold the lock the way `status` and `--persistent-stop` probe it (only
    // for longer) while the server starts.
    const probe = try std.fs.cwd().createFile(slot.lock, .{ .truncate = false, .mode = 0o600 });
    try posix.flock(probe.handle, posix.LOCK.EX | posix.LOCK.NB);
    const Run = struct {
        stop: std.atomic.Value(bool) = .init(false),
        err: ?anyerror = null,
        fn run(r: *@This(), g: std.mem.Allocator, h: []const u8) void {
            persistent.runServer(g, h, "probe", .{ .stop_flag = &r.stop, .kill_grace_ms = 100 }) catch |e| {
                r.err = e;
            };
        }
    };
    var r: Run = .{};
    const t = try std.Thread.spawn(.{}, Run.run, .{ &r, gpa, home });
    std.Thread.sleep(30 * std.time.ns_per_ms);
    probe.close();
    var fd: ?posix.fd_t = null;
    var tries: usize = 0;
    while (fd == null and tries < 300) : (tries += 1) {
        fd = persistent.connect(slot.sock) catch blk: {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            break :blk null;
        };
    }
    r.stop.store(true, .release);
    t.join();
    if (fd) |f| posix.close(f);
    try testing.expect(r.err == null);
    try testing.expect(fd != null);
}

test "unit: remote-daemon: idle ttl reaps detached sessions" {
    const gpa = testing.allocator;
    const h = try SlotHarness.start(gpa, .{ .session_ttl_ms = 300 });
    defer h.stop();
    var c = try h.connect();
    defer c.deinit();
    _ = try c.hello(true, timeout);
    const attached = try openSh(&c, "attached", 80, 24);
    _ = try ptyAttach(&c, attached, 80, 24);
    _ = try openSh(&c, "detached", 80, 24);
    var n: usize = 2;
    var tries: usize = 0;
    while (n != 1 and tries < 300) : (tries += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        n = (try c.request(.pty_list, .{}, timeout)).result.object.get("sessions").?.array.items.len;
    }
    try testing.expectEqual(@as(usize, 1), n);
    const lst = try c.request(.pty_list, .{}, timeout);
    try testing.expectEqualStrings("attached", str(lst.result.object.get("sessions").?.array.items[0], "session_id"));
}

test "unit: remote-daemon: huge output is streamed in full but replay is bounded by the ring" {
    const h = try StdioHarness.start(testing.allocator, homeCfg("/tmp"));
    defer h.stop();
    const c = &h.client;
    _ = try c.hello(true, timeout);
    const r = try c.request(.session_open, msgs.SessionOpenParams{ .command = sh_cmd, .env = sh_env, .scrollback_bytes = 4096 }, timeout);
    const sid = str(r.result, "session_id");
    const a = try ptyAttach(c, sid, 80, 24);
    // 300000 'x' then a marker; computed by the shell so the echo of the
    // typed command does not contain the marker.
    try typeLine(c, sid, "head -c 300000 /dev/zero | tr '\\000' x; echo; echo end-$((5*5))\n");
    try c.waitData(a.channel, "end-25", 30_000);
    try testing.expect(std.mem.count(u8, c.channelData(a.channel), "x") >= 300000);
    const b = try ptyAttach(c, sid, 80, 24);
    try testing.expect(b.replay > 0 and b.replay <= 4096);
    try c.waitData(b.channel, "end-25", timeout);
    const st = try c.request(.session_status, msgs.SessionIdParams{ .session_id = sid }, timeout);
    try testing.expectEqual(@as(i64, 4096), int(st.result, "scrollback_bytes"));
}
