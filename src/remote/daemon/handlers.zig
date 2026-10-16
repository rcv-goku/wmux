//! Request dispatch and the method handlers. Each handler replies exactly
//! once on its connection; params are decoded in a per-request arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const remote = @import("wmux_proto").remote;
const rpc = remote.rpc;
const msgs = remote.messages;
const frame = remote.frame;
const srvmod = @import("server.zig");
const Server = srvmod.Server;
const Conn = srvmod.Conn;
const sessmod = @import("session.zig");
const Session = sessmod.Session;
const fsops = @import("fsops.zig");

const log = std.log.scoped(.remote_daemon);

const HandlerError = error{ InvalidParams, OutOfMemory };

pub fn handleLine(srv: *Server, c: *Conn, line: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(srv.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const req = rpc.parseRequest(a, line) catch |err| switch (err) {
        error.ParseError => return srv.sendError(c, null, .parse_error, "invalid JSON"),
        error.InvalidRequest => return srv.sendError(c, rpc.bestEffortId(a, line), .invalid_request, "invalid request"),
        error.OutOfMemory => return srv.sendError(c, null, .internal_error, "out of memory"),
    };
    const m = rpc.Method.parse(req.method) orelse {
        // The name is client input of any length (G6: cap echoed text).
        const name = @import("wmux_proto").utf8.truncateUtf8(req.method, msgs.max_name_len);
        const msg = std.fmt.allocPrint(a, "unknown method: {s}", .{name}) catch "unknown method";
        return srv.sendError(c, req.id, .method_not_found, msg);
    };
    if (!c.hello_done and m != .hello) return srv.sendError(c, req.id, .hello_required, "hello is required before other methods");
    dispatch(srv, c, a, req.id, req.params, m) catch |err| switch (err) {
        error.InvalidParams => srv.sendError(c, req.id, .invalid_params, "invalid params"),
        error.OutOfMemory => srv.sendError(c, req.id, .internal_error, "out of memory"),
    };
}

fn dispatch(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value, m: rpc.Method) HandlerError!void {
    if (m.isStub()) {
        var buf: [96]u8 = undefined;
        return srv.sendError(c, id, .not_supported, rpc.notImplementedMessage(&buf, m));
    }
    switch (m) {
        .hello => try hello(srv, c, a, id, params),
        .ping => srv.sendOk(c, id, msgs.PingResult{ .time_ms = std.time.milliTimestamp() }),
        .session_open => try sessionOpen(srv, c, a, id, params),
        .session_close, .pty_close => try sessionClose(srv, c, a, id, params),
        .session_attach => try attach(srv, c, a, id, params, false),
        .pty_attach => try attach(srv, c, a, id, params, true),
        .session_resize, .pty_resize => try resize(srv, c, a, id, params),
        .session_detach, .pty_detach => try detach(srv, c, a, id, params),
        .session_status => try status(srv, c, a, id, params),
        .pty_list => try list(srv, c, a, id),
        .pty_write => try ptyWrite(srv, c, a, id, params),
        .fs_put => try fsPut(srv, c, a, id, params),
        .fs_get => try fsGet(srv, c, a, id, params),
        .proxy_open, .proxy_close, .proxy_write, .proxy_stream_subscribe, .relay_accept => unreachable,
    }
}

/// Client-to-daemon binary frames: PTY input on an attachment's channel.
pub fn handleFrame(srv: *Server, c: *Conn, f: frame.Frame) void {
    if (f.kind != .pty_data) return; // proxy streams are not implemented here
    for (srv.sessions.values()) |s| {
        for (s.attachments.items) |att| {
            if (att.conn_id != c.id or att.channel != f.channel) continue;
            s.queueInput(srv.gpa, f.payload) catch |err| log.info("dropped input for {s}: {s}", .{ s.id, @errorName(err) });
            return;
        }
    }
}

fn hello(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value) HandlerError!void {
    const p = try rpc.parseParams(msgs.HelloParams, a, params);
    if (c.hello_done) return srv.sendError(c, id, .invalid_state, "hello already completed");
    const neg = msgs.negotiate(p) catch {
        const msg = std.fmt.allocPrint(a, "unsupported protocol version {d}; daemon speaks {d}", .{ p.protocol_version, rpc.protocol_version }) catch "unsupported protocol version";
        return srv.sendError(c, id, .version_mismatch, msg);
    };
    var caps: std.ArrayList([]const u8) = .empty;
    try caps.appendSlice(a, &rpc.capabilities);
    if (srv.cfg.persistent) try caps.append(a, rpc.cap_persistent);
    std.mem.sort([]const u8, caps.items, {}, lessStr);
    c.hello_done = true;
    c.binary = neg.binary_frames;
    srv.sendOk(c, id, msgs.HelloResult{
        .capabilities = caps.items,
        .persistent = srv.cfg.persistent,
        .slot = srv.cfg.slot,
        .pid = std.c.getpid(),
        .binary_frames = neg.binary_frames,
    });
    // Enabled after the reply: the client sends frames only once it has it.
    c.decoder.binary_enabled = neg.binary_frames;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn notFound(srv: *Server, c: *Conn, id: ?rpc.Id) void {
    srv.sendError(c, id, .not_found, "session not found");
}

fn badSize(srv: *Server, c: *Conn, id: ?rpc.Id) void {
    srv.sendError(c, id, .invalid_params, "cols and rows must be between 1 and 10000");
}

fn sessionOpen(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value) HandlerError!void {
    const p = try rpc.parseParams(msgs.SessionOpenParams, a, params);
    if (!msgs.isValidSize(p.cols, p.rows)) return badSize(srv, c, id);
    var id_buf: [32]u8 = undefined;
    const sid = if (p.session_id) |s| blk: {
        if (!msgs.isValidName(s)) return srv.sendError(c, id, .invalid_params, "session_id must match [A-Za-z0-9._-]{1,128}");
        if (srv.sessions.contains(s)) return srv.sendError(c, id, .invalid_state, "session already exists");
        break :blk s;
    } else newSessionId(srv, &id_buf);
    if (p.command) |argv| if (argv.len == 0) return srv.sendError(c, id, .invalid_params, "command must not be empty");
    const scrollback: usize = if (p.scrollback_bytes) |b| b else sessmod.default_scrollback;
    const s = Session.create(srv.gpa, sid, .{
        .argv = p.command,
        .env = p.env,
        .cwd = p.cwd,
        .size = .{ .cols = @intCast(p.cols), .rows = @intCast(p.rows) },
    }, scrollback, std.time.milliTimestamp()) catch |err| {
        const msg = switch (err) {
            error.FileNotFound => "command not found",
            error.InvalidArgv => "invalid command",
            error.OpenPtyFailed => "PTY allocation failed",
            else => std.fmt.allocPrint(a, "failed to start session: {s}", .{@errorName(err)}) catch "failed to start session",
        };
        const code: rpc.ErrorCode = switch (err) {
            error.FileNotFound => .not_found,
            error.InvalidArgv => .invalid_params,
            else => .io_error,
        };
        return srv.sendError(c, id, code, msg);
    };
    srv.sessions.put(srv.gpa, s.id, s) catch {
        srv.discardSession(s);
        return error.OutOfMemory;
    };
    log.info("session {s} started (pid {d})", .{ s.id, s.pid });
    srv.sendOk(c, id, msgs.SessionOpenResult{ .session_id = s.id, .pid = s.pid, .cols = s.size.cols, .rows = s.size.rows });
}

fn newSessionId(srv: *Server, buf: *[32]u8) []const u8 {
    while (true) {
        var r: [6]u8 = undefined;
        std.crypto.random.bytes(&r);
        const sid = std.fmt.bufPrint(buf, "s-{s}", .{std.fmt.bytesToHex(r, .lower)}) catch unreachable;
        if (!srv.sessions.contains(sid)) return sid;
    }
}

fn sessionClose(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value) HandlerError!void {
    const p = try rpc.parseParams(msgs.SessionIdParams, a, params);
    const s = srv.sessions.get(p.session_id) orelse return notFound(srv, c, id);
    const sid = try a.dupe(u8, s.id);
    srv.closeSession(s, "session_closed", c.id);
    srv.sendOk(c, id, msgs.CloseResult{ .session_id = sid });
}

fn attach(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value, stream: bool) HandlerError!void {
    const p = try rpc.parseParams(msgs.AttachParams, a, params);
    if (!msgs.isValidSize(p.cols, p.rows)) return badSize(srv, c, id);
    const s = srv.sessions.get(p.session_id) orelse return notFound(srv, c, id);
    var id_buf: [32]u8 = undefined;
    const aid = try srv.gpa.dupe(u8, srv.newAttachmentId(&id_buf));
    errdefer srv.gpa.free(aid);
    const channel: ?u32 = if (stream) c.next_channel else null;
    try s.attachments.append(srv.gpa, .{
        .id = aid,
        .conn_id = c.id,
        .channel = channel,
        .size = .{ .cols = @intCast(p.cols), .rows = @intCast(p.rows) },
    });
    if (stream) c.next_channel +%= 1;
    s.applySize();
    const replay = if (stream and p.replay) s.ring.slices() else [2][]const u8{ &.{}, &.{} };
    srv.sendOk(c, id, msgs.AttachResult{
        .session_id = s.id,
        .attachment_id = aid,
        .cols = s.size.cols,
        .rows = s.size.rows,
        .channel = channel,
        .replay_bytes = if (stream) replay[0].len + replay[1].len else null,
        .binary_frames = if (stream) c.binary else null,
    });
    if (channel) |ch| for (replay) |part| if (part.len > 0) srv.sendData(c, ch, s.id, part);
}

const Found = struct { s: *Session, index: usize };

fn findOwnAttachment(srv: *Server, c: *Conn, aid: []const u8) ?Found {
    for (srv.sessions.values()) |s| {
        if (s.findAttachment(aid)) |i| {
            if (s.attachments.items[i].conn_id != c.id) return null;
            return .{ .s = s, .index = i };
        }
    }
    return null;
}

fn resize(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value) HandlerError!void {
    const p = try rpc.parseParams(msgs.ResizeParams, a, params);
    if (!msgs.isValidSize(p.cols, p.rows)) return badSize(srv, c, id);
    const f = findOwnAttachment(srv, c, p.attachment_id) orelse return srv.sendError(c, id, .not_found, "attachment not found");
    f.s.attachments.items[f.index].size = .{ .cols = @intCast(p.cols), .rows = @intCast(p.rows) };
    f.s.applySize();
    srv.sendOk(c, id, sizeResult(f.s));
}

fn detach(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value) HandlerError!void {
    const p = try rpc.parseParams(msgs.AttachmentIdParams, a, params);
    const f = findOwnAttachment(srv, c, p.attachment_id) orelse return srv.sendError(c, id, .not_found, "attachment not found");
    f.s.removeAttachmentAt(srv.gpa, f.index, std.time.milliTimestamp());
    srv.sendOk(c, id, sizeResult(f.s));
}

fn sizeResult(s: *Session) msgs.SizeResult {
    return .{ .session_id = s.id, .cols = s.size.cols, .rows = s.size.rows, .attachments = @intCast(s.attachments.items.len) };
}

fn info(a: Allocator, s: *Session) Allocator.Error!msgs.SessionInfo {
    const atts = try a.alloc(msgs.AttachmentInfo, s.attachments.items.len);
    for (atts, s.attachments.items) |*d, att| d.* = .{
        .attachment_id = att.id,
        .cols = att.size.cols,
        .rows = att.size.rows,
        .streaming = att.channel != null,
    };
    return .{
        .session_id = s.id,
        .pid = s.pid,
        .alive = s.alive(),
        .cols = s.size.cols,
        .rows = s.size.rows,
        .attachments = @intCast(s.attachments.items.len),
        .scrollback_bytes = s.scrollbackBytes(),
        .created_ms = s.created_ms,
        .attachment_list = atts,
    };
}

fn status(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value) HandlerError!void {
    const p = try rpc.parseParams(msgs.SessionIdParams, a, params);
    const s = srv.sessions.get(p.session_id) orelse return notFound(srv, c, id);
    srv.sendOk(c, id, try info(a, s));
}

fn list(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id) HandlerError!void {
    const out = try a.alloc(msgs.SessionInfo, srv.sessions.count());
    for (out, srv.sessions.values()) |*d, s| d.* = try info(a, s);
    srv.sendOk(c, id, msgs.PtyListResult{ .sessions = out });
}

fn decodeB64(a: Allocator, s: []const u8, max: usize) error{ InvalidBase64, TooLarge, OutOfMemory }![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return error.InvalidBase64;
    if (n > max) return error.TooLarge;
    const out = try a.alloc(u8, n);
    dec.decode(out, s) catch return error.InvalidBase64;
    return out;
}

fn ptyWrite(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value) HandlerError!void {
    const p = try rpc.parseParams(msgs.PtyWriteParams, a, params);
    const s = srv.sessions.get(p.session_id) orelse return notFound(srv, c, id);
    const data = decodeB64(a, p.data, msgs.max_pty_write) catch |err| return switch (err) {
        error.InvalidBase64 => srv.sendError(c, id, .invalid_params, "data is not valid base64"),
        error.TooLarge => srv.sendError(c, id, .too_large, "write exceeds 1048576 bytes"),
        error.OutOfMemory => error.OutOfMemory,
    };
    s.queueInput(srv.gpa, data) catch |err| return switch (err) {
        error.Busy => srv.sendError(c, id, .busy, "input queue full"),
        error.Closed => srv.sendError(c, id, .invalid_state, "session has exited"),
        error.OutOfMemory => error.OutOfMemory,
    };
    srv.sendOk(c, id, msgs.PtyWriteResult{ .bytes = data.len });
}

fn fsPut(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value) HandlerError!void {
    const p = try rpc.parseParams(msgs.FsPutParams, a, params);
    const path = fsops.resolvePath(a, srv.cfg.home, p.path) catch |err| return switch (err) {
        error.InvalidPath => srv.sendError(c, id, .invalid_params, "invalid path"),
        error.OutOfMemory => error.OutOfMemory,
    };
    const mode = p.mode orelse 0o600;
    if (mode > 0o7777) return srv.sendError(c, id, .invalid_params, "invalid mode");
    const data = decodeB64(a, p.data, msgs.max_fs_bytes) catch |err| return switch (err) {
        error.InvalidBase64 => srv.sendError(c, id, .invalid_params, "data is not valid base64"),
        error.TooLarge => srv.sendError(c, id, .too_large, "file exceeds 16777216 bytes"),
        error.OutOfMemory => error.OutOfMemory,
    };
    const digest = fsops.put(path, data, .{ .mode = @intCast(mode), .expected_sha256 = p.sha256, .mkdirs = p.mkdirs }) catch |err| {
        const r: struct { rpc.ErrorCode, []const u8 } = switch (err) {
            error.EmptyFile => .{ .invalid_params, "refusing to write a 0-byte file" },
            error.ChecksumMismatch => .{ .invalid_params, "sha256 mismatch" },
            error.InvalidPath => .{ .invalid_params, "invalid path" },
            error.FileNotFound => .{ .not_found, "parent directory not found" },
            error.AccessDenied, error.PermissionDenied => .{ .io_error, "permission denied" },
            error.IsDir => .{ .invalid_params, "path is a directory" },
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .io_error, std.fmt.allocPrint(a, "write failed: {s}", .{@errorName(err)}) catch "write failed" },
        };
        return srv.sendError(c, id, r[0], r[1]);
    };
    srv.sendOk(c, id, msgs.FsPutResult{ .path = path, .size = data.len, .sha256 = try a.dupe(u8, &digest) });
}

fn fsGet(srv: *Server, c: *Conn, a: Allocator, id: ?rpc.Id, params: std.json.Value) HandlerError!void {
    const p = try rpc.parseParams(msgs.FsGetParams, a, params);
    const path = fsops.resolvePath(a, srv.cfg.home, p.path) catch |err| return switch (err) {
        error.InvalidPath => srv.sendError(c, id, .invalid_params, "invalid path"),
        error.OutOfMemory => error.OutOfMemory,
    };
    const max: usize = @intCast(@min(p.max_bytes orelse msgs.max_fs_bytes, msgs.max_fs_bytes));
    const got = fsops.get(a, path, max) catch |err| {
        const r: struct { rpc.ErrorCode, []const u8 } = switch (err) {
            error.TooLarge => .{ .too_large, "file too large" },
            error.FileNotFound => .{ .not_found, "file not found" },
            error.IsDir => .{ .invalid_params, "path is a directory" },
            // NoDevice: open(2) of a socket path fails with ENXIO.
            error.NotRegularFile, error.NoDevice => .{ .invalid_params, "not a regular file" },
            error.AccessDenied, error.PermissionDenied => .{ .io_error, "permission denied" },
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .io_error, std.fmt.allocPrint(a, "read failed: {s}", .{@errorName(err)}) catch "read failed" },
        };
        return srv.sendError(c, id, r[0], r[1]);
    };
    const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(got.data.len));
    _ = std.base64.standard.Encoder.encode(enc, got.data);
    srv.sendOk(c, id, msgs.FsGetResult{ .path = path, .size = got.data.len, .sha256 = try a.dupe(u8, &got.sha256), .data = enc });
}
