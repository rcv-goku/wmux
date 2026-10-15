//! Unit tests for the tmux-compat engine (ADR-10.8, W3-6): golden command
//! lines against an in-memory fake executor, checking stdout, stderr, exit
//! codes, the executor operation log and the compat store.
//!
//! zig test --dep wmux_proto -Mroot=src/wmux_cli/tmux/tests.zig -Mwmux_proto=src/wmux_proto/proto.zig

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const parse = @import("parse.zig");
const engine = @import("engine.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

test {
    _ = @import("wmux_proto");
    _ = @import("parse.zig");
    _ = @import("format.zig");
    _ = @import("keys.zig");
    _ = @import("store.zig");
    _ = @import("engine.zig");
}

// ---------------------------------------------------------------------------
// Fake executor: sessions -> windows -> panes, every operation logged
// ---------------------------------------------------------------------------

const FSession = struct { id: u32, name: []u8, attached: bool };
const FWindow = struct { id: u32, session: u32, name: []u8, active: bool, last: bool = false };
const FPane = struct { id: u32, window: u32, active: bool, title: []u8, uuid: [36]u8 };

const Fake = struct {
    gpa: Allocator,
    sessions: std.ArrayList(FSession) = .empty,
    windows: std.ArrayList(FWindow) = .empty,
    panes: std.ArrayList(FPane) = .empty,
    log: std.ArrayList(u8) = .empty,
    caller: ?u32 = null,
    next_session: u32 = 0,
    next_window: u32 = 1,
    next_pane: u32 = 1,
    capture_text: []const u8 = "line one\nline two\n",
    shell_exit: u8 = 0,
    fail_next: ?[]const u8 = null,

    fn deinit(self: *Fake) void {
        for (self.sessions.items) |s| self.gpa.free(s.name);
        for (self.windows.items) |w| self.gpa.free(w.name);
        for (self.panes.items) |p| self.gpa.free(p.title);
        self.sessions.deinit(self.gpa);
        self.windows.deinit(self.gpa);
        self.panes.deinit(self.gpa);
        self.log.deinit(self.gpa);
    }

    fn logf(self: *Fake, comptime fmt: []const u8, args: anytype) void {
        self.log.print(self.gpa, fmt ++ "\n", args) catch @panic("oom");
    }

    fn checkFail(self: *Fake, ctx: *engine.OpCtx) engine.OpError!void {
        if (self.fail_next) |m| {
            self.fail_next = null;
            return ctx.fail("{s}", .{m});
        }
    }

    fn uuidFor(id: u32) [36]u8 {
        var b: [36]u8 = undefined;
        _ = std.fmt.bufPrint(&b, "00000000-0000-4000-8000-{d:0>12}", .{id}) catch unreachable;
        return b;
    }

    fn addSession(self: *Fake, name: ?[]const u8, attached: bool) !u32 {
        const id = self.next_session;
        self.next_session += 1;
        const n = if (name) |x| try self.gpa.dupe(u8, x) else try std.fmt.allocPrint(self.gpa, "{d}", .{id});
        try self.sessions.append(self.gpa, .{ .id = id, .name = n, .attached = attached });
        return id;
    }

    fn addWindow(self: *Fake, session: u32, name: ?[]const u8, active: bool) !u32 {
        const id = self.next_window;
        self.next_window += 1;
        if (active) {
            for (self.windows.items) |*w| {
                if (w.session == session) {
                    w.last = w.active;
                    w.active = false;
                }
            }
        }
        try self.windows.append(self.gpa, .{ .id = id, .session = session, .name = try self.gpa.dupe(u8, name orelse "shell"), .active = active });
        return id;
    }

    fn addPane(self: *Fake, window: u32, at: ?usize, active: bool) !u32 {
        const id = self.next_pane;
        self.next_pane += 1;
        if (active) self.deactivatePanes(window);
        const p: FPane = .{ .id = id, .window = window, .active = active, .title = try self.gpa.dupe(u8, ""), .uuid = uuidFor(id) };
        if (at) |i| try self.panes.insert(self.gpa, i, p) else try self.panes.append(self.gpa, p);
        return id;
    }

    fn deactivatePanes(self: *Fake, window: u32) void {
        for (self.panes.items) |*p| {
            if (p.window == window) p.active = false;
        }
    }

    fn paneIdx(self: *Fake, id: u32) usize {
        for (self.panes.items, 0..) |p, i| {
            if (p.id == id) return i;
        }
        @panic("unknown pane");
    }

    fn windowOf(self: *Fake, id: u32) *FWindow {
        for (self.windows.items) |*w| {
            if (w.id == id) return w;
        }
        @panic("unknown window");
    }

    fn removePane(self: *Fake, id: u32) void {
        const p = self.panes.orderedRemove(self.paneIdx(id));
        self.gpa.free(p.title);
        var left = false;
        for (self.panes.items) |q| {
            if (q.window == p.window) left = true;
        }
        if (!left) self.removeWindow(p.window);
    }

    fn removeWindow(self: *Fake, id: u32) void {
        var i: usize = 0;
        while (i < self.panes.items.len) {
            if (self.panes.items[i].window == id) {
                self.gpa.free(self.panes.items[i].title);
                _ = self.panes.orderedRemove(i);
            } else i += 1;
        }
        for (self.windows.items, 0..) |w, j| {
            if (w.id == id) {
                self.gpa.free(w.name);
                _ = self.windows.orderedRemove(j);
                break;
            }
        }
    }

    fn describeSpawn(a: Allocator, s: engine.Spawn) ![]const u8 {
        const cmd = switch (s.command) {
            .none => try a.dupe(u8, "none"),
            .placeholder => try a.dupe(u8, "placeholder"),
            .shell => |x| try std.fmt.allocPrint(a, "shell[{s}]", .{x}),
            .argv => |v| try std.fmt.allocPrint(a, "argv[{s}]", .{try std.mem.join(a, "|", v)}),
        };
        return std.fmt.allocPrint(a, "cwd={s} env={s} cmd={s}", .{ s.cwd orelse "-", try std.mem.join(a, ",", s.env), cmd });
    }

    fn sizeText(a: Allocator, s: ?parse.Size) ![]const u8 {
        const v = s orelse return "-";
        return switch (v) {
            .cells => |c| std.fmt.allocPrint(a, "{d}", .{c}),
            .percent => |p| std.fmt.allocPrint(a, "{d}%", .{p}),
        };
    }

    // -- ops ---------------------------------------------------------------

    pub fn snapshot(self: *Fake, ctx: *engine.OpCtx, _: void) engine.OpError!engine.Snapshot {
        const a = ctx.arena;
        var sessions: std.ArrayList(engine.Session) = .empty;
        for (self.sessions.items) |s| {
            var wins: std.ArrayList(engine.Window) = .empty;
            var widx: u32 = 0;
            for (self.windows.items) |w| {
                if (w.session != s.id) continue;
                var panes: std.ArrayList(engine.Pane) = .empty;
                var pidx: u32 = 0;
                for (self.panes.items) |p| {
                    if (p.window != w.id) continue;
                    try panes.append(a, .{
                        .id = p.id,
                        .uuid = try a.dupe(u8, &p.uuid),
                        .wmux_pane = p.id + 100,
                        .index = pidx,
                        .active = p.active,
                        .title = try a.dupe(u8, p.title),
                        .current_path = "/home/me/proj",
                        .current_command = "bash",
                        .pid = 4000 + p.id,
                    });
                    pidx += 1;
                }
                const wuuid = try std.fmt.allocPrint(a, "11111111-0000-4000-8000-{d:0>12}", .{w.id});
                try wins.append(a, .{ .id = w.id, .uuid = wuuid, .index = widx, .name = try a.dupe(u8, w.name), .active = w.active, .last = w.last, .width = 160, .height = 48, .panes = panes.items });
                widx += 1;
            }
            try sessions.append(a, .{ .id = s.id, .name = try a.dupe(u8, s.name), .attached = s.attached, .windows = wins.items });
        }
        return .{ .sessions = sessions.items, .caller_pane = self.caller };
    }

    pub fn newSession(self: *Fake, ctx: *engine.OpCtx, req: engine.NewSessionReq) engine.OpError!u32 {
        try self.checkFail(ctx);
        self.logf("newSession name={s} window={s} detached={} {s}", .{ req.name orelse "-", req.window_name orelse "-", req.detached, try describeSpawn(ctx.arena, req.spawn) });
        const s = self.addSession(req.name, !req.detached) catch return error.OutOfMemory;
        const w = self.addWindow(s, req.window_name, true) catch return error.OutOfMemory;
        return self.addPane(w, null, true) catch return error.OutOfMemory;
    }

    pub fn newWindow(self: *Fake, ctx: *engine.OpCtx, req: engine.NewWindowReq) engine.OpError!u32 {
        try self.checkFail(ctx);
        self.logf("newWindow session=${d} name={s} detached={} {s}", .{ req.session, req.name orelse "-", req.detached, try describeSpawn(ctx.arena, req.spawn) });
        const w = self.addWindow(req.session, req.name, !req.detached) catch return error.OutOfMemory;
        return self.addPane(w, null, true) catch return error.OutOfMemory;
    }

    pub fn splitPane(self: *Fake, ctx: *engine.OpCtx, req: engine.SplitReq) engine.OpError!u32 {
        try self.checkFail(ctx);
        self.logf("split window=@{d} target=%{d} dir={s} size={s} detached={} {s}", .{ req.window, req.target, @tagName(req.direction), try sizeText(ctx.arena, req.size), req.detached, try describeSpawn(ctx.arena, req.spawn) });
        const i = self.paneIdx(req.target);
        const at = switch (req.direction) {
            .right, .down => i + 1,
            .left, .up => i,
        };
        return self.addPane(req.window, at, !req.detached) catch return error.OutOfMemory;
    }

    pub fn respawnPane(self: *Fake, ctx: *engine.OpCtx, req: engine.RespawnReq) engine.OpError!void {
        try self.checkFail(ctx);
        self.logf("respawn %{d} kill={} {s}", .{ req.pane, req.kill, try describeSpawn(ctx.arena, req.spawn) });
    }

    pub fn sendKeys(self: *Fake, ctx: *engine.OpCtx, req: engine.SendReq) engine.OpError!void {
        try self.checkFail(ctx);
        var line: std.ArrayList(u8) = .empty;
        for (req.items) |it| {
            try line.appendSlice(ctx.arena, if (it.key) " key:" else " text:");
            for (it.bytes) |c| {
                if (c < 0x20 or c == 0x7f) try line.print(ctx.arena, "\\x{x:0>2}", .{c}) else try line.append(ctx.arena, c);
            }
        }
        self.logf("send %{d}{s}", .{ req.pane, line.items });
    }

    pub fn selectPane(self: *Fake, _: *engine.OpCtx, req: engine.PaneReq) engine.OpError!void {
        self.logf("selectPane %{d}", .{req.pane});
        const p = &self.panes.items[self.paneIdx(req.pane)];
        self.deactivatePanes(p.window);
        p.active = true;
    }

    pub fn selectPaneDirection(self: *Fake, _: *engine.OpCtx, req: engine.PaneDirectionReq) engine.OpError!void {
        self.logf("selectPaneDirection %{d} {s}", .{ req.pane, @tagName(req.direction) });
    }

    pub fn setPaneTitle(self: *Fake, _: *engine.OpCtx, req: engine.TitleReq) engine.OpError!void {
        self.logf("title %{d} {s}", .{ req.pane, req.title });
        const p = &self.panes.items[self.paneIdx(req.pane)];
        self.gpa.free(p.title);
        p.title = self.gpa.dupe(u8, req.title) catch return error.OutOfMemory;
    }

    pub fn selectWindow(self: *Fake, _: *engine.OpCtx, req: engine.WindowReq) engine.OpError!void {
        self.logf("selectWindow @{d}", .{req.window});
        const target = self.windowOf(req.window);
        for (self.windows.items) |*w| {
            if (w.session == target.session) {
                w.last = w.active and w.id != req.window;
                w.active = w.id == req.window;
            }
        }
    }

    pub fn renameWindow(self: *Fake, _: *engine.OpCtx, req: engine.RenameReq) engine.OpError!void {
        self.logf("renameWindow @{d} {s}", .{ req.id, req.name });
        const w = self.windowOf(req.id);
        self.gpa.free(w.name);
        w.name = self.gpa.dupe(u8, req.name) catch return error.OutOfMemory;
    }

    pub fn renameSession(self: *Fake, _: *engine.OpCtx, req: engine.RenameReq) engine.OpError!void {
        self.logf("renameSession ${d} {s}", .{ req.id, req.name });
        for (self.sessions.items) |*s| {
            if (s.id == req.id) {
                self.gpa.free(s.name);
                s.name = self.gpa.dupe(u8, req.name) catch return error.OutOfMemory;
            }
        }
    }

    pub fn killPane(self: *Fake, _: *engine.OpCtx, req: engine.PaneReq) engine.OpError!void {
        self.logf("killPane %{d}", .{req.pane});
        self.removePane(req.pane);
    }

    pub fn killWindow(self: *Fake, _: *engine.OpCtx, req: engine.WindowReq) engine.OpError!void {
        self.logf("killWindow @{d}", .{req.window});
        self.removeWindow(req.window);
    }

    pub fn killSession(self: *Fake, _: *engine.OpCtx, req: engine.SessionReq) engine.OpError!void {
        self.logf("killSession ${d}", .{req.session});
        var i: usize = 0;
        while (i < self.windows.items.len) {
            if (self.windows.items[i].session == req.session) self.removeWindow(self.windows.items[i].id) else i += 1;
        }
        for (self.sessions.items, 0..) |s, j| {
            if (s.id == req.session) {
                self.gpa.free(s.name);
                _ = self.sessions.orderedRemove(j);
                break;
            }
        }
    }

    pub fn resizePane(self: *Fake, ctx: *engine.OpCtx, req: engine.ResizeReq) engine.OpError!void {
        self.logf("resize %{d} dir={s} amount={d} x={s} y={s} zoom={}", .{ req.pane, if (req.direction) |d| @tagName(d) else "-", req.amount, try sizeText(ctx.arena, req.width), try sizeText(ctx.arena, req.height), req.zoom });
    }

    pub fn selectLayout(self: *Fake, _: *engine.OpCtx, req: engine.LayoutReq) engine.OpError!void {
        self.logf("layout @{d} {s}", .{ req.window, req.layout });
    }

    pub fn capturePane(self: *Fake, ctx: *engine.OpCtx, req: engine.CaptureReq) engine.OpError![]const u8 {
        const s = if (req.start) |l| switch (l) {
            .edge => "-",
            .number => |n| try std.fmt.allocPrint(ctx.arena, "{d}", .{n}),
        } else "none";
        self.logf("capture %{d} start={s} join={}", .{ req.pane, s, req.join });
        return self.capture_text;
    }

    pub fn displayMessage(self: *Fake, _: *engine.OpCtx, req: engine.MessageReq) engine.OpError!void {
        self.logf("message {s}", .{req.text});
    }

    pub fn waitFor(self: *Fake, _: *engine.OpCtx, req: engine.WaitReq) engine.OpError!void {
        self.logf("waitFor {s} {s}", .{ req.channel, @tagName(req.mode) });
    }

    pub fn runShell(self: *Fake, _: *engine.OpCtx, req: engine.ShellReq) engine.OpError!u8 {
        self.logf("shell [{s}] cwd={s}", .{ req.command, req.cwd orelse "-" });
        return if (std.mem.eql(u8, req.command, "false")) 1 else self.shell_exit;
    }

    pub fn setOption(self: *Fake, _: *engine.OpCtx, req: engine.OptionReq) engine.OpError!void {
        self.logf("option {s} {s}={s} target={s}", .{ @tagName(req.scope), req.name, req.value orelse "-", req.target orelse "-" });
    }

    pub fn swapPane(self: *Fake, _: *engine.OpCtx, req: engine.SwapReq) engine.OpError!void {
        self.logf("swap %{d} %{d} focus={}", .{ req.src, req.dst, req.focus });
    }

    pub fn breakPane(self: *Fake, _: *engine.OpCtx, req: engine.BreakReq) engine.OpError!u32 {
        self.logf("break %{d} detached={} name={s}", .{ req.pane, req.detached, req.name orelse "-" });
        const p = &self.panes.items[self.paneIdx(req.pane)];
        const old = self.windowOf(p.window);
        const w = self.addWindow(old.session, req.name, !req.detached) catch return error.OutOfMemory;
        self.panes.items[self.paneIdx(req.pane)].window = w;
        return req.pane;
    }

    pub fn joinPane(self: *Fake, ctx: *engine.OpCtx, req: engine.JoinReq) engine.OpError!void {
        self.logf("join %{d} -> %{d} dir={s} size={s}", .{ req.src, req.dst, @tagName(req.direction), try sizeText(ctx.arena, req.size) });
    }

    pub fn pipePane(self: *Fake, _: *engine.OpCtx, req: engine.PipeReq) engine.OpError!void {
        self.logf("pipe %{d} {s} in={} out={}", .{ req.pane, req.command orelse "-", req.input, req.output });
    }

    pub fn clearHistory(self: *Fake, _: *engine.OpCtx, req: engine.PaneReq) engine.OpError!void {
        self.logf("clearHistory %{d}", .{req.pane});
    }

    pub fn lastPane(self: *Fake, _: *engine.OpCtx, req: engine.WindowReq) engine.OpError!void {
        self.logf("lastPane @{d}", .{req.window});
    }

    pub fn lastWindow(self: *Fake, _: *engine.OpCtx, req: engine.SessionReq) engine.OpError!void {
        self.logf("lastWindow ${d}", .{req.session});
    }

    pub fn nextWindow(self: *Fake, _: *engine.OpCtx, req: engine.SessionReq) engine.OpError!void {
        self.logf("nextWindow ${d}", .{req.session});
    }

    pub fn previousWindow(self: *Fake, _: *engine.OpCtx, req: engine.SessionReq) engine.OpError!void {
        self.logf("previousWindow ${d}", .{req.session});
    }

    pub fn readFile(self: *Fake, ctx: *engine.OpCtx, req: engine.ReadFileReq) engine.OpError![]const u8 {
        self.logf("read {s}", .{req.path});
        if (std.mem.eql(u8, req.path, "missing")) return ctx.fail("No such file or directory", .{});
        return std.fmt.allocPrint(ctx.arena, "contents of {s}", .{req.path});
    }

    pub fn writeFile(self: *Fake, _: *engine.OpCtx, req: engine.WriteFileReq) engine.OpError!void {
        self.logf("write {s} append={} {s}", .{ req.path, req.append, req.data });
    }
};

/// Only `snapshot`: every other operation is unavailable.
const Minimal = struct {
    fake: *Fake,
    pub fn snapshot(self: *Minimal, ctx: *engine.OpCtx, req: void) engine.OpError!engine.Snapshot {
        return self.fake.snapshot(ctx, req);
    }
};

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

const Harness = struct {
    gpa: Allocator,
    fake: Fake,
    store: Store = .{},
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    eng: engine.Engine,

    /// One session "main" (attached) with window @1 and pane %1 (the caller).
    fn create() !*Harness {
        const gpa = testing.allocator;
        const h = try gpa.create(Harness);
        h.* = .{
            .gpa = gpa,
            .fake = .{ .gpa = gpa },
            .out = .init(gpa),
            .err = .init(gpa),
            .eng = undefined,
        };
        h.eng = .{
            .gpa = gpa,
            .exec = engine.implement(Fake, &h.fake),
            .store = &h.store,
            .out = &h.out.writer,
            .err = &h.err.writer,
            .options = .{ .socket_path = "/tmp/wmux/WS", .server_pid = 4242 },
        };
        const s = try h.fake.addSession("main", true);
        const w = try h.fake.addWindow(s, "shell", true);
        h.fake.caller = try h.fake.addPane(w, null, true);
        return h;
    }

    fn destroy(h: *Harness) void {
        h.fake.deinit();
        h.store.deinit(h.gpa);
        h.out.deinit();
        h.err.deinit();
        h.gpa.destroy(h);
    }

    fn clear(h: *Harness) void {
        h.out.clearRetainingCapacity();
        h.err.clearRetainingCapacity();
        h.fake.log.clearRetainingCapacity();
    }

    /// Runs argv and checks exit code, stdout and stderr; then clears them
    /// (the op log is kept for `expectLog`).
    fn expect(h: *Harness, argv: []const []const u8, code: u8, stdout: []const u8, stderr: []const u8) !void {
        const got = h.eng.run(argv);
        try testing.expectEqualStrings(stderr, h.err.written());
        try testing.expectEqualStrings(stdout, h.out.written());
        try testing.expectEqual(code, got);
        h.out.clearRetainingCapacity();
        h.err.clearRetainingCapacity();
    }

    fn expectLog(h: *Harness, want: []const u8) !void {
        try testing.expectEqualStrings(want, h.fake.log.items);
        h.fake.log.clearRetainingCapacity();
    }
};

const UUID1 = "00000000-0000-4000-8000-000000000001";
const UUID2 = "00000000-0000-4000-8000-000000000002";
const UUID3 = "00000000-0000-4000-8000-000000000003";
const UUID4 = "00000000-0000-4000-8000-000000000004";
const WS1 = "11111111-0000-4000-8000-000000000001";

// ---------------------------------------------------------------------------
// Golden tests
// ---------------------------------------------------------------------------

test "unit: tmux: version flags print tmux 3.4 without touching the executor" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{"-V"}, 0, "tmux 3.4\n", "");
    try h.expect(&.{"-v"}, 0, "tmux 3.4\n", "");
    try h.expect(&.{ "-L", "claude-swarm", "-V" }, 0, "tmux 3.4\n", "");
    try h.expect(&.{ "-2uV", "split-window" }, 0, "tmux 3.4\n", "");
    try h.expectLog("");
}

test "unit: tmux: global flag errors" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{"-L"}, 1, "", "tmux: option requires an argument -- L\n");
    try h.expect(&.{ "-x", "ls" }, 1, "", "tmux: unknown option -- x\n");
}

test "unit: tmux: single-string command and global socket flags" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{"display-message -p #{pane_id}"}, 0, "%1\n", "");
    try h.expect(&.{ "-L", "claude-swarm", "display-message -p '#{session_name}:#{window_index}'" }, 0, "main:0\n", "");
    try h.expect(&.{ "-S", "C:\\tmp\\sock", "display", "-p", "#{socket_path}" }, 0, "C:\\tmp\\sock\n", "");
    try h.expect(&.{ "display", "-p", "#{socket_path} #{pid} #{version}" }, 0, "/tmp/wmux/WS 4242 3.4\n", "");
    try h.expect(&.{"DISPLAY-MESSAGE -p #{pane_id}"}, 0, "%1\n", "");
    try h.expect(&.{"display -p 'unterminated"}, 1, "", "syntax error: unterminated quote\n");
}

test "unit: tmux: Claude Code teammate protocol stacks an agent column" {
    const h = try Harness.create();
    defer h.destroy();
    // Teammate 1: placeholder split right of the leader.
    try h.expect(&.{ "split-window", "-d", "-t", "%1", "-h", "-l", "70%", "-P", "-F", "#{pane_id}", "--", "cat" }, 0, "%2\n", "");
    try h.expectLog("split window=@1 target=%1 dir=right size=70% detached=true cwd=- env= cmd=placeholder\n");
    try h.expect(&.{ "select-pane", "-t", "%2", "-T", "alice" }, 0, "", "");
    try h.expect(&.{ "set-option", "-p", "-t", "%2", "remain-on-exit", "failed" }, 0, "", "");
    try h.expect(&.{ "respawn-pane", "-k", "-t", "%2", "--", "cd '/c/proj' && env CLAUDECODE=1 'C:/claude.exe' --agent-id alice@t" }, 0, "", "");
    try h.expectLog(
        \\title %2 alice
        \\option pane remain-on-exit=failed target=%2
        \\respawn %2 kill=true cwd=- env= cmd=shell[cd '/c/proj' && env CLAUDECODE=1 'C:/claude.exe' --agent-id alice@t]
        \\
    );
    const lo = h.store.getLayout(WS1).?;
    try testing.expectEqualStrings(UUID1, lo.main);
    try testing.expectEqualStrings(UUID2, lo.column.?);
    try testing.expect(h.eng.store_dirty);

    // Teammates 2 and 3 stack downward in the column, whatever -h/-l say.
    try h.expect(&.{ "split-window", "-d", "-t", "%1", "-h", "-l", "70%", "-P", "-F", "#{pane_id}", "--", "cat" }, 0, "%3\n", "");
    try h.expect(&.{ "split-window", "-d", "-t", "%1", "-h", "-l", "70%", "-P", "-F", "#{pane_id}", "--", "cat" }, 0, "%4\n", "");
    try h.expectLog(
        \\split window=@1 target=%2 dir=down size=- detached=true cwd=- env= cmd=placeholder
        \\split window=@1 target=%3 dir=down size=- detached=true cwd=- env= cmd=placeholder
        \\
    );
    try testing.expectEqualStrings(UUID4, h.store.getLayout(WS1).?.column.?);
    try testing.expectEqualStrings(UUID4, h.store.getLastSplit(WS1).?);
    try testing.expectEqualStrings(UUID3, h.store.paneSurface(3).?);
    // Leader keeps focus (-d) and the pane list is leader + three teammates.
    try h.expect(&.{ "list-panes", "-F", "#{pane_id} #{pane_active} #{pane_title}" }, 0, "%1 1 \n%2 0 alice\n%3 0 \n%4 0 \n", "");
}

test "unit: tmux: select-layout main-vertical seeds placement from lastSplitSurface" {
    const h = try Harness.create();
    defer h.destroy();
    h.eng.options.auto_main_vertical = false;
    try h.expect(&.{ "splitw", "-h", "-d", "-P", "-F", "#{pane_id}" }, 0, "%2\n", "");
    try testing.expect(h.store.getLayout(WS1) == null);
    try testing.expectEqualStrings(UUID2, h.store.getLastSplit(WS1).?);
    try h.expect(&.{ "select-layout", "-t", "%1", "main-vertical" }, 0, "", "");
    const lo = h.store.getLayout(WS1).?;
    try testing.expectEqualStrings(UUID1, lo.main);
    try testing.expectEqualStrings(UUID2, lo.column.?);
    try h.expect(&.{ "splitw", "-h", "-d", "-t", "%1" }, 0, "", "");
    try h.expectLog(
        \\split window=@1 target=%1 dir=right size=- detached=true cwd=- env= cmd=none
        \\layout @1 main-vertical
        \\split window=@1 target=%2 dir=down size=- detached=true cwd=- env= cmd=none
        \\
    );
    // Other layouts pass through and leave the column state alone.
    try h.expect(&.{ "select-layout", "tiled" }, 0, "", "");
    try testing.expect(h.store.getLayout(WS1) != null);
    try h.expect(&.{ "select-layout", "bogus" }, 1, "", "invalid layout: bogus\n");
    try h.expect(&.{ "select-layout", "b0a3,160x48,0,0{80x48,0,0,1,79x48,81,0,2}" }, 0, "", "");
    try h.expect(&.{ "select-layout", "-n" }, 0, "", "");
}

test "unit: tmux: placement survives a closed column surface and a closed leader" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "split-window", "-d", "-h", "--", "cat" }, 0, "", "");
    try h.expect(&.{ "split-window", "-d", "-h", "--", "cat" }, 0, "", "");
    try h.expect(&.{ "kill-pane", "-t", "%3" }, 0, "", "");
    try testing.expect(h.store.getLayout(WS1).?.column == null);
    try testing.expect(h.store.paneSurface(3) == null);
    h.fake.log.clearRetainingCapacity();
    // Column gone: the next teammate goes right of the leader again.
    try h.expect(&.{ "split-window", "-d", "-h", "-P", "-F", "#{pane_id}", "--", "cat" }, 0, "%4\n", "");
    try h.expectLog("split window=@1 target=%1 dir=right size=- detached=true cwd=- env= cmd=placeholder\n");
    try testing.expectEqualStrings(UUID4, h.store.getLayout(WS1).?.column.?);
    // Leader gone: the layout is dropped and splits are honored as given.
    try h.expect(&.{ "kill-pane", "-t", "%1" }, 0, "", "");
    try testing.expect(h.store.getLayout(WS1) == null);
    h.fake.caller = 2;
    h.fake.log.clearRetainingCapacity();
    try h.expect(&.{ "split-window", "-d", "-v", "-t", "%4" }, 0, "", "");
    try h.expectLog("split window=@1 target=%4 dir=down size=- detached=true cwd=- env= cmd=none\n");
}

test "unit: tmux: split-window flags: sizes, cwd, env, argv, before" {
    const h = try Harness.create();
    defer h.destroy();
    h.eng.options.main_vertical_placement = false;
    try h.expect(&.{ "split-window", "-v", "-l", "10", "-c", "C:\\work dir", "-e", "A=1", "-e", "B=two words", "-P", "--", "bash", "-lc", "echo hi" }, 0, "main:0.1\n", "");
    try h.expect(&.{ "split-window", "-bh", "-p", "30", "-t", "%1", "vim file.txt" }, 0, "", "");
    try h.expect(&.{ "split-window", "-b", "-t", "%1" }, 0, "", "");
    try h.expectLog(
        \\split window=@1 target=%1 dir=down size=10 detached=false cwd=C:\work dir env=A=1,B=two words cmd=argv[bash|-lc|echo hi]
        \\split window=@1 target=%1 dir=left size=30% detached=false cwd=- env= cmd=shell[vim file.txt]
        \\split window=@1 target=%1 dir=up size=- detached=false cwd=- env= cmd=none
        \\
    );
    try h.expect(&.{ "split-window", "-l", "0" }, 1, "", "invalid size: 0\n");
    try h.expect(&.{ "split-window", "-l", "150%" }, 1, "", "invalid size: 150%\n");
    try h.expect(&.{ "split-window", "-p", "abc" }, 1, "", "invalid percentage: abc\n");
    try h.expect(&.{ "split-window", "-e", "NOEQUALS" }, 1, "", "invalid environment: NOEQUALS\n");
    try h.expect(&.{ "split-window", "-t" }, 1, "", "command split-window: -t expects an argument\nusage: split-window [-bdefhIPvZ] [-c start-directory] [-e environment] [-F format] [-l size] [-t target-pane] [shell-command [argument ...]]\n");
    try h.expect(&.{ "split-window", "-Q" }, 1, "", "command split-window: unknown flag -Q\nusage: split-window [-bdefhIPvZ] [-c start-directory] [-e environment] [-F format] [-l size] [-t target-pane] [shell-command [argument ...]]\n");
}

test "unit: tmux: send-keys key names, literal, hex, repeat and unicode" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "send-keys", "-t", "%1", "echo hi", "Enter" }, 0, "", "");
    try h.expect(&.{ "send", "-t", "%1", "C-c" }, 0, "", "");
    try h.expect(&.{ "send-keys", "-l", "Enter" }, 0, "", "");
    try h.expect(&.{ "send-keys", "-H", "0d", "0x1b" }, 0, "", "");
    try h.expect(&.{ "send-keys", "-N", "3", "BSpace" }, 0, "", "");
    try h.expect(&.{ "send-keys", "héllo ✓", "KPEnter" }, 0, "", "");
    try h.expect(&.{ "send-keys", "-F", "-t", "%1", "#{pane_id}", "Tab" }, 0, "", "");
    try h.expect(&.{"send-keys"}, 0, "", ""); // nothing to send: no op
    try h.expectLog(
        \\send %1 text:echo hi key:\x0d
        \\send %1 key:\x03
        \\send %1 text:Enter
        \\send %1 key:\x0d key:\x1b
        \\send %1 key:\x7f key:\x7f key:\x7f
        \\send %1 text:héllo ✓ key:\x0d
        \\send %1 text:%1 key:\x09
        \\
    );
    try h.expect(&.{ "send-keys", "-H", "zz" }, 1, "", "invalid key: zz\n");
    try h.expect(&.{ "send-keys", "-N", "0", "x" }, 1, "", "repeat count invalid: 0\n");
    try h.expect(&.{ "send-keys", "-X", "cancel" }, 1, "", "not in a mode\n");
    try h.expect(&.{ "send-keys", "-t", "%99", "x" }, 1, "", "can't find pane: %99\n");
}

test "unit: tmux: send-keys -N repeats every item after allocations in between" {
    const h = try Harness.create();
    defer h.destroy();
    // M-x and M-y allocate their bytes after the item list, so growing the
    // list for the repeats cannot happen in place.
    try h.expect(&.{ "send-keys", "-N", "2", "-t", "%1", "a", "M-x", "M-y" }, 0, "", "");
    try h.expect(&.{ "send-keys", "-N", "3", "-F", "#{pane_id}", "C-c" }, 0, "", "");
    try h.expectLog(
        \\send %1 text:a key:\x1bx key:\x1by text:a key:\x1bx key:\x1by
        \\send %1 text:%1 key:\x03 text:%1 key:\x03 text:%1 key:\x03
        \\
    );
    try h.expect(&.{ "send-keys", "-N", "10000", "x" }, 0, "", "");
    try testing.expectEqual(@as(usize, "send %1".len + 10000 * " text:x".len + 1), h.fake.log.items.len);
    try h.expect(&.{ "send-keys", "-N", "10001", "x" }, 1, "", "repeat count invalid: 10001\n");
}

test "unit: tmux: send-keys with a huge literal payload" {
    const h = try Harness.create();
    defer h.destroy();
    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try h.expect(&.{ "send-keys", "-l", "-t", "%1", big }, 0, "", "");
    try testing.expectEqual(@as(usize, "send %1 text:".len + big.len + 1), h.fake.log.items.len);
}

test "unit: tmux: target syntax resolves tmux forms and wmux handles" {
    const h = try Harness.create();
    defer h.destroy();
    h.eng.options.main_vertical_placement = false;
    try h.expect(&.{ "split-window", "-d" }, 0, "", "");
    try h.expect(&.{ "new-window", "-d", "-n", "logs" }, 0, "", "");
    const fmt = "#{session_name}:#{window_index}.#{pane_index} #{pane_id} #{window_id}";
    const cases = [_][2][]const u8{
        .{ "%2", "main:0.1 %2 @1" },
        .{ "main:0.1", "main:0.1 %2 @1" },
        .{ "main:1", "main:1.0 %3 @2" },
        .{ "main:logs", "main:1.0 %3 @2" },
        .{ "main:lo", "main:1.0 %3 @2" },
        .{ "=main:1", "main:1.0 %3 @2" },
        .{ ":1", "main:1.0 %3 @2" },
        .{ ".1", "main:0.1 %2 @1" },
        .{ "@2", "main:1.0 %3 @2" },
        .{ "$0", "main:0.0 %1 @1" },
        .{ "main", "main:0.0 %1 @1" },
        .{ "logs", "main:1.0 %3 @2" },
        .{ "1.0", "main:1.0 %3 @2" },
        .{ "surface:2", "main:0.1 %2 @1" },
        .{ "tab:3", "main:1.0 %3 @2" },
        .{ "workspace:2", "main:1.0 %3 @2" },
        .{ "pane:102", "main:0.1 %2 @1" },
        .{ UUID2, "main:0.1 %2 @1" },
        .{ "{00000000-0000-4000-8000-000000000003}", "main:1.0 %3 @2" },
        .{ "11111111-0000-4000-8000-000000000002", "main:1.0 %3 @2" },
        .{ "main:{end}", "main:1.0 %3 @2" },
        .{ "main:^", "main:0.0 %1 @1" },
        .{ ":0.+", "main:0.1 %2 @1" },
        .{ "", "main:0.0 %1 @1" },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "{s}\n", .{c[1]});
        h.expect(&.{ "display-message", "-p", "-t", c[0], fmt }, 0, want, "") catch |e| {
            std.log.err("target {s}", .{c[0]});
            return e;
        };
    }
    try h.expect(&.{ "display", "-p", "-t", "nosuch:0", "x" }, 1, "", "can't find session: nosuch\n");
    try h.expect(&.{ "display", "-p", "-t", "main:9", "x" }, 1, "", "can't find window: 9\n");
    try h.expect(&.{ "display", "-p", "-t", "main:0.7", "x" }, 1, "", "can't find pane: 7\n");
    try h.expect(&.{ "display", "-p", "-t", "@99", "x" }, 1, "", "can't find pane: @99\n");
    try h.expect(&.{ "display", "-p", "-t", "nothing", "x" }, 1, "", "can't find pane: nothing\n");
    try h.expect(&.{ "has-session", "-t", "$7" }, 1, "", "can't find session: $7\n");
}

test "unit: tmux: %N falls back to the store's pane-surface map" {
    const h = try Harness.create();
    defer h.destroy();
    // A host whose pane numbering changed: %42 recorded for surface UUID1.
    try h.store.setPaneSurface(testing.allocator, 42, UUID1);
    try h.expect(&.{ "display", "-p", "-t", "%42", "#{pane_id}" }, 0, "%1\n", "");
}

test "unit: tmux: the caller pane honours the store's pane-surface map" {
    const h = try Harness.create();
    defer h.destroy();
    h.eng.options.main_vertical_placement = false;
    try h.expect(&.{ "split-window", "-d" }, 0, "", "");
    h.fake.log.clearRetainingCapacity();
    // TMUX_PANE=%42 was recorded for surface UUID2 (a renumbered host).
    try h.store.setPaneSurface(testing.allocator, 42, UUID2);
    h.fake.caller = 42;
    try h.expect(&.{ "display", "-p", "#{pane_id}" }, 0, "%2\n", "");
    try h.expect(&.{ "split-window", "-d", "-P", "-F", "#{pane_id}" }, 0, "%3\n", "");
    try h.expectLog("split window=@1 target=%2 dir=down size=- detached=true cwd=- env= cmd=none\n");
}

test "unit: tmux: bare targets follow tmux's lookup order for each target type" {
    const h = try Harness.create();
    defer h.destroy();
    h.eng.options.main_vertical_placement = false;
    try h.expect(&.{ "split-window", "-d" }, 0, "", ""); // %2: pane 1 of window 0
    try h.expect(&.{ "new-window", "-d", "-n", "logs" }, 0, "", ""); // window 1 (@2) with %3
    h.fake.log.clearRetainingCapacity();
    // Pane targets: a pane of the current window first, then a window of
    // the current session, then a session.
    const fmt = "#{window_index}.#{pane_index} #{pane_id}";
    const cases = [_][2][]const u8{
        .{ "1", "0.1 %2" },
        .{ "+", "0.1 %2" },
        .{ "{bottom}", "0.1 %2" },
        .{ "{end}", "1.0 %3" },
        .{ "logs", "1.0 %3" },
        .{ "main", "0.0 %1" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "{s}\n", .{c[1]});
        h.expect(&.{ "display-message", "-p", "-t", c[0], fmt }, 0, want, "") catch |e| {
            std.log.err("target {s}", .{c[0]});
            return e;
        };
    }
    try h.expect(&.{ "display", "-p", "-t", "5", "x" }, 1, "", "can't find pane: 5\n");
    try h.expect(&.{ "kill-pane", "-t", "1" }, 0, "", "");
    try h.expectLog("killPane %2\n");
    // Session targets name sessions only: a window name never widens to
    // the session that holds it.
    try h.expect(&.{ "kill-session", "-t", "logs" }, 1, "", "can't find session: logs\n");
    try h.expect(&.{ "has-session", "-t", "logs" }, 1, "", "can't find session: logs\n");
    try h.expect(&.{ "rename-session", "-t", "logs", "x" }, 1, "", "can't find session: logs\n");
    try h.expectLog("");
    // new-window and select-window take window targets, find-window a pane.
    try h.expect(&.{ "new-window", "-d", "-t", "logs", "-P", "-F", "#{session_name}:#{window_index}" }, 0, "main:2\n", "");
    try h.expect(&.{ "select-window", "-n", "-t", "logs" }, 0, "", "");
    try h.expect(&.{ "find-window", "-t", "logs", "-N", "logs" }, 0, "", "");
    try h.expectLog(
        \\newWindow session=$0 name=- detached=true cwd=- env= cmd=none
        \\nextWindow $0
        \\selectWindow @2
        \\
    );
}

test "unit: tmux: list commands with default and custom formats" {
    const h = try Harness.create();
    defer h.destroy();
    h.eng.options.main_vertical_placement = false;
    try h.expect(&.{ "split-window", "-d" }, 0, "", "");
    try h.expect(&.{ "new-window", "-d", "-n", "naïve ✓" }, 0, "", "");
    try h.expect(&.{"list-panes"}, 0, "0: [80x24] %1 (active)\n1: [80x24] %2\n", "");
    try h.expect(&.{ "lsp", "-s" }, 0, "0.0: [80x24] %1 (active)\n0.1: [80x24] %2\n1.0: [80x24] %3 (active)\n", "");
    try h.expect(&.{ "list-panes", "-a", "-f", "#{pane_active}" }, 0, "main:0.0: [80x24] %1 (active)\nmain:1.0: [80x24] %3 (active)\n", "");
    try h.expect(&.{ "list-panes", "-t", "main:1", "-F", "#{pane_id} #{pane_current_path} #{pane_current_command} #{pane_pid} #{pane_ref}" }, 0, "%3 /home/me/proj bash 4003 surface:3\n", "");
    try h.expect(&.{"list-windows"}, 0, "0: shell* (2 panes) [160x48] @1 (active)\n1: naïve ✓ (1 panes) [160x48] @2\n", "");
    try h.expect(&.{ "lsw", "-F", "#{window_id} #{window_name} #{window_uuid}" }, 0, "@1 shell 11111111-0000-4000-8000-000000000001\n@2 naïve ✓ 11111111-0000-4000-8000-000000000002\n", "");
    try h.expect(&.{"list-sessions"}, 0, "main: 2 windows (attached)\n", "");
    try h.expect(&.{ "ls", "-F", "#{session_id} #{session_name} #{session_attached} #{session_windows}" }, 0, "$0 main 1 2\n", "");
    try h.expectLog("split window=@1 target=%1 dir=down size=- detached=true cwd=- env= cmd=none\nnewWindow session=$0 name=naïve ✓ detached=true cwd=- env= cmd=none\n");
}

test "unit: tmux: has-session, new-session -A and duplicates" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "has-session", "-t", "main" }, 0, "", "");
    try h.expect(&.{ "has", "-t", "claude-swarm" }, 1, "", "can't find session: claude-swarm\n");
    try h.expect(&.{ "new-session", "-d", "-s", "claude-swarm", "-n", "lead", "-P", "-F", "#{session_name}:#{window_index} #{pane_id}", "--", "cat" }, 0, "claude-swarm:0 %2\n", "");
    try h.expect(&.{ "has-session", "-t", "claude-swarm" }, 0, "", "");
    try h.expect(&.{ "new-session", "-d", "-s", "claude-swarm" }, 1, "", "duplicate session: claude-swarm\n");
    try h.expect(&.{ "new-session", "-A", "-s", "claude-swarm", "-P" }, 0, "claude-swarm:\n", "");
    try h.expect(&.{ "new", "-d" }, 0, "", "");
    try h.expectLog(
        \\newSession name=claude-swarm window=lead detached=true cwd=- env= cmd=placeholder
        \\selectWindow @2
        \\newSession name=- window=- detached=true cwd=- env= cmd=none
        \\
    );
    try h.expect(&.{ "new-window", "-t", "claude-swarm", "-d", "-P", "-F", "#{window_index} #{pane_id}" }, 0, "1 %4\n", "");
    try h.expect(&.{ "kill-session", "-t", "claude-swarm" }, 0, "", "");
    try h.expect(&.{ "has-session", "-t", "claude-swarm" }, 1, "", "can't find session: claude-swarm\n");
}

test "unit: tmux: empty argv means new-session" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{}, 0, "", "");
    try h.expectLog("newSession name=- window=- detached=false cwd=- env= cmd=none\n");
}

test "unit: tmux: command chaining with ; and \\;" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "display", "-p", "a", ";", "display", "-p", "b", "\\;", "display", "-p", "c;", "display", "-p", "d\\;" }, 0, "a\nb\nc\nd;\n", "");
    try h.expect(&.{"display -p one; display -p two \\; display -p 'th;ree'"}, 0, "one\ntwo\nth;ree\n", "");
    // A parse error anywhere runs nothing.
    try h.expect(&.{ "send-keys", "x", ";", "frobnicate" }, 1, "", "Unsupported tmux compatibility command: frobnicate\n");
    try h.expectLog("");
    // A runtime error stops the rest of the sequence.
    try h.expect(&.{ "display", "-p", "-t", "%9", "x", ";", "display", "-p", "after" }, 1, "", "can't find pane: %9\n");
    // Empty commands between separators are dropped.
    try h.expect(&.{ ";", ";", "display", "-p", "ok", ";" }, 0, "ok\n", "");
}

test "unit: tmux: chaining a thousand commands" {
    const h = try Harness.create();
    defer h.destroy();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    for (0..1000) |i| {
        if (i > 0) try argv.append(testing.allocator, ";");
        try argv.appendSlice(testing.allocator, &.{ "display", "-p", "#{pane_id}" });
    }
    const code = h.eng.run(argv.items);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqual(@as(usize, 3000), h.out.written().len);
}

test "unit: tmux: unsupported, ambiguous and prefix commands" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{"kill-server"}, 1, "", "Unsupported tmux compatibility command: kill-server\n");
    try h.expect(&.{"choose-tree"}, 1, "", "Unsupported tmux compatibility command: choose-tree\n");
    try h.expect(&.{"sel"}, 1, "", "ambiguous command: sel, could be: select-pane, select-window, select-layout\n");
    try h.expect(&.{ "list-p", "-F", "#D" }, 0, "%1\n", "");
    try h.expect(&.{"popup"}, 1, "", engine.placeholder_message ++ "\n");
    try h.expect(&.{ "display-popup", "-E", "htop" }, 1, "", engine.placeholder_message ++ "\n");
    for ([_][]const u8{ "attach", "attach-session", "detach-client", "source-file", "refresh-client", "bind-key", "unbind-key", "copy-mode", "start-server" }) |verb| {
        try h.expect(&.{ verb, "-t", "x", "whatever" }, 0, "", "");
    }
    try h.expectLog("");
}

test "unit: tmux: usage errors for positional counts" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{"wait-for"}, 1, "", "usage: wait-for [-L|-S|-U] channel\n");
    try h.expect(&.{ "rename-window", "a", "b" }, 1, "", "usage: rename-window [-t target-window] new-name\n");
    try h.expect(&.{ "if-shell", "true" }, 1, "", "usage: if-shell [-bF] [-t target-pane] shell-command command [command]\n");
}

test "unit: tmux: show-options answers fixed values; set-option is accepted" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "show-options", "-gv", "extended-keys" }, 0, "on\n", "");
    try h.expect(&.{ "show", "-g", "prefix" }, 0, "prefix C-b\n", "");
    try h.expect(&.{ "show-options", "-g", "allow-passthrough" }, 0, "allow-passthrough off\n", "");
    try h.expect(&.{ "show-options", "-p", "-t", "%1" }, 0, "allow-passthrough off\nremain-on-exit off\n", "");
    try h.expect(&.{ "show-options", "-g" }, 0, "base-index 0\nhistory-limit 2000\nmouse off\nprefix C-b\nstatus on\n", "");
    try h.expect(&.{ "show-option", "-s" }, 0, "buffer-limit 50\ndefault-terminal screen-256color\nescape-time 500\nextended-keys on\nfocus-events off\nset-clipboard external\n", "");
    try h.expect(&.{ "showw", "-g" }, 0, "aggressive-resize off\nmode-keys emacs\npane-base-index 0\n", "");
    try h.expect(&.{ "show-options", "-gqv", "@unknown" }, 0, "", "");
    try h.expect(&.{ "set", "-g", "mouse", "on" }, 0, "", "");
    try h.expect(&.{ "setw", "-g", "mode-keys", "vi" }, 0, "", "");
    try h.expectLog("option session mouse=on target=-\noption window mode-keys=vi target=-\n");
}

test "unit: tmux: set-option is a silent no-op without host support" {
    const h = try Harness.create();
    defer h.destroy();
    var min: Minimal = .{ .fake = &h.fake };
    h.eng.exec = engine.implement(Minimal, &min);
    try h.expect(&.{ "set-option", "-g", "status", "off" }, 0, "", "");
    try h.expect(&.{ "split-window", "-h" }, 1, "", "Unsupported tmux compatibility command: split-window\n");
    try h.expect(&.{ "display-message", "hello #{pane_id}" }, 0, "hello %1\n", "");
    try h.expect(&.{ "list-panes", "-F", "#{pane_id}" }, 0, "%1\n", "");
}

test "unit: tmux: display-message variants" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "display-message", "-p" }, 0, "[main] 0:shell, current pane 0 - (%1)\n", "");
    try h.expect(&.{ "display", "-p", "-F", "#{window_flags}#{?pane_active,A,}" }, 0, "*A\n", "");
    try h.expect(&.{ "display", "-pl", "#{pane_id}" }, 0, "#{pane_id}\n", "");
    try h.expect(&.{ "display", "-p", "-F", "x", "y" }, 1, "", "only one of -F or argument must be given\n");
    try h.expect(&.{ "display", "status: #{pane_id}" }, 0, "", "");
    try h.expectLog("message status: %1\n");
    try h.expect(&.{ "display", "-a" }, 0,
        \\pane_active=1
        \\pane_current_command=bash
        \\pane_current_path=/home/me/proj
        \\pane_dead=0
        \\pane_height=24
        \\pane_id=%1
        \\pane_index=0
        \\pane_pid=4001
        \\pane_ref=surface:1
        \\pane_start_command=
        \\pane_title=
        \\pane_width=80
        \\pid=4242
        \\session_attached=1
        \\session_id=$0
        \\session_name=main
        \\session_windows=1
        \\socket_path=/tmp/wmux/WS
        \\version=3.4
        \\window_active=1
        \\window_flags=*
        \\window_height=48
        \\window_id=@1
        \\window_index=0
        \\window_name=shell
        \\window_panes=1
        \\window_uuid=11111111-0000-4000-8000-000000000001
        \\window_width=160
        \\workspace_id=11111111-0000-4000-8000-000000000001
        \\
    , "");
}

test "unit: tmux: formats work with no sessions at all" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "kill-session", "-t", "main" }, 0, "", "");
    try h.expect(&.{ "display", "-p", "#{version} [#{pane_id}]" }, 0, "3.4 []\n", "");
    try h.expect(&.{"list-sessions"}, 0, "", "");
    try h.expect(&.{"has-session"}, 1, "", "no current session\n");
    try h.expect(&.{ "split-window", "-h" }, 1, "", "no current session\n");
}

test "unit: tmux: capture-pane prints or stores a buffer" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "capture-pane", "-p", "-t", "%1", "-S", "-100", "-J" }, 0, "line one\nline two\n", "");
    try h.expect(&.{ "capturep", "-p", "-S", "-", "-E", "-" }, 0, "line one\nline two\n", "");
    h.fake.capture_text = "no newline";
    try h.expect(&.{ "capture-pane", "-p" }, 0, "no newline\n", "");
    h.fake.capture_text = "";
    try h.expect(&.{ "capture-pane", "-p" }, 0, "", "");
    h.fake.capture_text = "kept";
    try h.expect(&.{ "capture-pane", "-b", "cap" }, 0, "", "");
    try testing.expectEqualStrings("kept", h.store.getBuffer("cap").?);
    try h.expect(&.{ "capture-pane", "-S", "top" }, 1, "", "start line invalid: top\n");
    try h.expectLog(
        \\capture %1 start=-100 join=true
        \\capture %1 start=- join=false
        \\capture %1 start=none join=false
        \\capture %1 start=none join=false
        \\capture %1 start=none join=false
        \\
    );
}

test "unit: tmux: buffers: set, show, list, paste, save, load, delete" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "set-buffer", "hello" }, 0, "", "");
    try h.expect(&.{"paste-buffer"}, 0, "", "");
    try h.expect(&.{ "set-buffer", "-b", "multi", "a\nb\n" }, 0, "", "");
    try h.expect(&.{ "paste-buffer", "-b", "multi", "-t", "%1" }, 0, "", "");
    try h.expect(&.{ "paste-buffer", "-b", "multi", "-r" }, 0, "", "");
    try h.expect(&.{ "paste-buffer", "-b", "multi", "-p", "-s", " " }, 0, "", "");
    try h.expectLog(
        \\send %1 text:hello
        \\send %1 text:a\x0db\x0d
        \\send %1 text:a\x0ab\x0a
        \\send %1 text:\x1b[200~a b \x1b[201~
        \\
    );
    try h.expect(&.{"show-buffer"}, 0, "hello\n", "");
    try h.expect(&.{ "showb", "-b", "multi" }, 0, "a\nb\n", "");
    try h.expect(&.{"list-buffers"}, 0, "multi: 4 bytes: \"a\\nb\\n\"\ndefault: 5 bytes: \"hello\"\n", "");
    try h.expect(&.{ "lsb", "-F", "#{buffer_name}" }, 0, "multi\ndefault\n", "");
    try h.expect(&.{ "set-buffer", "-a", " world" }, 0, "", "");
    try h.expect(&.{ "save-buffer", "-" }, 0, "hello world", "");
    try h.expect(&.{ "save-buffer", "-a", "C:\\out.txt" }, 0, "", "");
    try h.expect(&.{ "load-buffer", "-b", "loaded", "in.txt" }, 0, "", "");
    try testing.expectEqualStrings("contents of in.txt", h.store.getBuffer("loaded").?);
    try h.expect(&.{ "load-buffer", "missing" }, 1, "", "No such file or directory\n");
    try h.expectLog("write C:\\out.txt append=true hello world\nread in.txt\nread missing\n");
    try h.expect(&.{ "set-buffer", "-b", "loaded", "-n", "renamed" }, 0, "", "");
    try testing.expect(h.store.getBuffer("loaded") == null);
    try h.expect(&.{ "delete-buffer", "-b", "renamed" }, 0, "", "");
    try h.expect(&.{ "delete-buffer", "-b", "renamed" }, 1, "", "no buffer renamed\n");
    try h.expect(&.{ "paste-buffer", "-b", "nope" }, 1, "", "no buffer nope\n");
    try h.expect(&.{"set-buffer"}, 1, "", "no data specified\n");
    try h.expect(&.{ "paste-buffer", "-d" }, 0, "", "");
    try testing.expect(h.store.getBuffer("default") == null);
    try testing.expect(h.eng.store_dirty);
}

test "unit: tmux: list-buffers sample is UTF-8 safe and escaped" {
    const h = try Harness.create();
    defer h.destroy();
    const long = "ééééééééééééééééééééééééé\x01tail"; // 50 bytes of é, then more
    try h.expect(&.{ "set-buffer", "-b", "u", long }, 0, "", "");
    try h.expect(&.{"list-buffers"}, 0, "u: 55 bytes: \"ééééééééééééééééééééééééé...\"\n", "");
    try h.expect(&.{ "set-buffer", "-b", "c", "\x01\"\\" }, 0, "", "");
    try h.expect(&.{ "lsb", "-f", "#{==:#{buffer_name},c}" }, 0, "c: 3 bytes: \"\\001\\\"\\\\\"\n", "");
}

test "unit: tmux: kill-pane, kill-window and -a variants" {
    const h = try Harness.create();
    defer h.destroy();
    h.eng.options.main_vertical_placement = false;
    try h.expect(&.{ "split-window", "-d" }, 0, "", "");
    try h.expect(&.{ "split-window", "-d" }, 0, "", "");
    try h.expect(&.{ "kill-pane", "-a", "-t", "%1" }, 0, "", "");
    try h.expect(&.{ "new-window", "-d" }, 0, "", "");
    try h.expect(&.{ "new-window", "-d" }, 0, "", "");
    try h.expect(&.{ "killw", "-t", ":2" }, 0, "", "");
    try h.expect(&.{ "kill-window", "-a" }, 0, "", "");
    try h.expectLog(
        \\split window=@1 target=%1 dir=down size=- detached=true cwd=- env= cmd=none
        \\split window=@1 target=%1 dir=down size=- detached=true cwd=- env= cmd=none
        \\killPane %3
        \\killPane %2
        \\newWindow session=$0 name=- detached=true cwd=- env= cmd=none
        \\newWindow session=$0 name=- detached=true cwd=- env= cmd=none
        \\killWindow @3
        \\killWindow @2
        \\
    );
    try h.expect(&.{ "list-panes", "-a", "-F", "#{pane_id}" }, 0, "%1\n", "");
}

test "unit: tmux: select, rename, resize, navigation and pane moves" {
    const h = try Harness.create();
    defer h.destroy();
    h.eng.options.main_vertical_placement = false;
    try h.expect(&.{ "split-window", "-d", "-h" }, 0, "", "");
    h.fake.log.clearRetainingCapacity();
    try h.expect(&.{ "select-pane", "-t", "%2" }, 0, "", "");
    try h.expect(&.{ "selectp", "-L" }, 0, "", "");
    try h.expect(&.{ "select-pane", "-l" }, 0, "", "");
    try h.expect(&.{ "select-pane", "-t", "%1", "-P", "bg=red" }, 0, "", "");
    try h.expect(&.{ "select-window", "-t", ":0" }, 0, "", "");
    try h.expect(&.{ "select-window", "-n" }, 0, "", "");
    try h.expect(&.{ "switch-client", "-t", "main" }, 0, "", "");
    try h.expect(&.{ "rename-window", "-t", "@1", "agents ✓" }, 0, "", "");
    try h.expect(&.{ "rename-session", "team" }, 0, "", "");
    try h.expect(&.{ "resize-pane", "-t", "%1", "-L", "5" }, 0, "", "");
    try h.expect(&.{ "resizep", "-x", "30%", "-y", "10" }, 0, "", "");
    try h.expect(&.{ "resize-pane", "-Z" }, 0, "", "");
    try h.expect(&.{"resize-pane"}, 0, "", "");
    try h.expect(&.{ "last-pane", "-t", "team:0" }, 0, "", "");
    try h.expect(&.{"last-window"}, 0, "", "");
    try h.expect(&.{"next-window"}, 0, "", "");
    try h.expect(&.{"previous-window"}, 0, "", "");
    try h.expect(&.{ "swap-pane", "-s", "%1", "-t", "%2", "-d" }, 0, "", "");
    try h.expect(&.{ "swap-pane", "-U" }, 0, "", "");
    try h.expect(&.{ "join-pane", "-h", "-s", "%2", "-t", "%1", "-l", "40%" }, 0, "", "");
    try h.expect(&.{ "pipe-pane", "-o", "cat >> log.txt" }, 0, "", "");
    try h.expect(&.{"pipe-pane"}, 0, "", "");
    try h.expect(&.{ "clear-history", "-t", "%2" }, 0, "", "");
    try h.expect(&.{ "wait-for", "-S", "done" }, 0, "", "");
    try h.expect(&.{ "wait-for", "done" }, 0, "", "");
    try h.expect(&.{ "wait-for", "-L", "lock" }, 0, "", "");
    try h.expectLog(
        \\selectPane %2
        \\selectPaneDirection %1 left
        \\lastPane @1
        \\selectWindow @1
        \\nextWindow $0
        \\selectWindow @1
        \\renameWindow @1 agents ✓
        \\renameSession $0 team
        \\resize %1 dir=left amount=5 x=- y=- zoom=false
        \\resize %1 dir=- amount=1 x=30% y=10 zoom=false
        \\resize %1 dir=- amount=1 x=- y=- zoom=true
        \\lastPane @1
        \\lastWindow $0
        \\nextWindow $0
        \\previousWindow $0
        \\swap %1 %2 focus=false
        \\swap %1 %2 focus=true
        \\join %2 -> %1 dir=right size=40%
        \\pipe %1 cat >> log.txt in=false out=true
        \\pipe %1 - in=false out=true
        \\clearHistory %2
        \\waitFor done signal
        \\waitFor done wait
        \\waitFor lock lock
        \\
    );
    try h.expect(&.{ "resize-pane", "-L", "x" }, 1, "", "adjustment invalid: x\n");
    try h.expect(&.{ "join-pane", "-t", "%1" }, 1, "", "no marked target\n");
    try h.expect(&.{ "join-pane", "-s", "%1", "-t", "%1" }, 1, "", "source and target panes must be different\n");
    try h.expect(&.{ "break-pane", "-d", "-s", "%2", "-n", "solo", "-P", "-F", "#{window_name} #{pane_id}" }, 0, "solo %2\n", "");
}

test "unit: tmux: find-window matches names, titles and content" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "new-window", "-d", "-n", "api-server" }, 0, "", "");
    try h.expect(&.{ "new-window", "-d", "-n", "docs" }, 0, "", "");
    h.fake.log.clearRetainingCapacity();
    try h.expect(&.{ "find-window", "-N", "api" }, 0, "", "");
    try h.expect(&.{ "find-window", "-Ni", "DOCS" }, 0, "", "");
    try h.expect(&.{ "find-window", "-N", "nomatch" }, 1, "", "no windows matching: nomatch\n");
    h.fake.capture_text = "error: boom";
    try h.expect(&.{ "findw", "-C", "boom" }, 0, "", "");
    try h.expectLog("selectWindow @2\nselectWindow @3\ncapture %1 start=none join=false\nselectWindow @1\n");
}

test "unit: tmux: if-shell with formats and shell exit codes" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "if-shell", "-F", "#{pane_active}", "display -p yes", "display -p no" }, 0, "yes\n", "");
    try h.expect(&.{ "if", "-F", "#{==:#{window_index},5}", "display -p yes", "display -p no" }, 0, "no\n", "");
    try h.expect(&.{ "if-shell", "-F", "", "display -p yes" }, 0, "", "");
    try h.expect(&.{ "if-shell", "true", "display -p ok; display -p twice" }, 0, "ok\ntwice\n", "");
    try h.expect(&.{ "if-shell", "false", "display -p ok", "display -p else" }, 0, "else\n", "");
    try h.expect(&.{ "if-shell", "-F", "1", "nosuchverb" }, 1, "", "Unsupported tmux compatibility command: nosuchverb\n");
    try h.expectLog("shell [true] cwd=/home/me/proj\nshell [false] cwd=/home/me/proj\n");
}

test "unit: tmux: if-shell recursion is bounded" {
    const h = try Harness.create();
    defer h.destroy();
    try h.store.setHook(testing.allocator, "after-display-message", "display -p again");
    // The hook re-triggers itself; nesting stops at the bound and the
    // outer command still succeeds.
    const code = h.eng.run(&.{ "display", "-p", "first" });
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.startsWith(u8, h.out.written(), "first\nagain\n"));
    try testing.expect(std.mem.count(u8, h.out.written(), "again") <= 8);
}

test "unit: tmux: set-hook stores, runs after commands and unsets" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "set-hook", "-g", "after-split-window", "display -p hooked" }, 0, "", "");
    try testing.expectEqualStrings("display -p hooked", h.store.getHook("after-split-window").?);
    try h.expect(&.{ "split-window", "-d", "-v" }, 0, "hooked\n", "");
    try h.expect(&.{"show-hooks"}, 0, "after-split-window display -p hooked\n", "");
    try h.expect(&.{ "set-hook", "-R", "after-split-window" }, 0, "hooked\n", "");
    try h.expect(&.{ "set-hook", "-u", "after-split-window" }, 0, "", "");
    try h.expect(&.{ "split-window", "-d", "-v" }, 0, "", "");
    try h.expect(&.{"show-hooks"}, 0, "", "");
    try h.expect(&.{ "set-hook", "lonely" }, 1, "", "usage: set-hook [-agpRuw] [-t target-pane] hook [command]\n");
}

test "unit: tmux: executor failures surface their message" {
    const h = try Harness.create();
    defer h.destroy();
    h.fake.fail_next = "pane %2 still active";
    try h.expect(&.{ "respawn-pane", "-t", "%1" }, 1, "", "pane %2 still active\n");
    h.fake.fail_next = "Workspace not found";
    try h.expect(&.{ "split-window", "-h" }, 1, "", "Workspace not found\n");
    try testing.expect(h.store.getLayout(WS1) == null);
}

test "unit: tmux: store dirty flag only on store changes" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "display", "-p", "x" }, 0, "x\n", "");
    try h.expect(&.{ "list-panes", "-F", "#D" }, 0, "%1\n", "");
    try testing.expect(!h.eng.store_dirty);
    try h.expect(&.{ "set-buffer", "x" }, 0, "", "");
    try testing.expect(h.eng.store_dirty);
}

test "unit: tmux: store round-trips through the engine" {
    const h = try Harness.create();
    defer h.destroy();
    try h.expect(&.{ "split-window", "-d", "-h", "--", "cat" }, 0, "", "");
    try h.expect(&.{ "set-buffer", "-b", "n", "naïve" }, 0, "", "");
    const json = try h.store.toJson(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{
        \\  "buffers": {
        \\    "n": "naïve"
        \\  },
        \\  "hooks": {},
        \\  "mainVerticalLayouts": {
        \\    "11111111-0000-4000-8000-000000000001": {
        \\      "mainSurfaceId": "00000000-0000-4000-8000-000000000001",
        \\      "lastColumnSurfaceId": "00000000-0000-4000-8000-000000000002"
        \\    }
        \\  },
        \\  "lastSplitSurface": {
        \\    "11111111-0000-4000-8000-000000000001": "00000000-0000-4000-8000-000000000002"
        \\  },
        \\  "paneSurfaces": {
        \\    "%2": "00000000-0000-4000-8000-000000000002"
        \\  }
        \\}
        \\
    , json);
}
