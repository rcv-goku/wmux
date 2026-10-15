//! tmux-compat command engine (ADR-10.8, W3-6). Runs parsed tmux commands
//! against an abstract `Executor` (the CLI implements it with v2 calls; tests
//! use an in-memory fake) and renders tmux-compatible stdout/stderr and exit
//! codes (0 success, 1 failure; a failing command stops the sequence).
//!
//! Model mapping is the executor's business: it reports a `Snapshot` of
//! sessions -> windows -> panes. In wmux, `%N` pane ids are surface ref
//! numbers and `@N` window ids are workspace ref numbers. Target resolution,
//! formats, key translation, buffers, hooks and main-vertical teammate
//! placement are done here, purely.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parse = @import("parse.zig");
const format = @import("format.zig");
const keys = @import("keys.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

// ---------------------------------------------------------------------------
// Snapshot model (reported by the executor)
// ---------------------------------------------------------------------------

pub const Pane = struct {
    /// tmux pane id (`%N`); the wmux surface ref number.
    id: u32,
    /// wmux surface UUID ("" when unknown).
    uuid: []const u8 = "",
    /// wmux pane ref number (`pane:N`) of the split leaf holding the surface.
    wmux_pane: ?u32 = null,
    index: u32 = 0,
    active: bool = false,
    width: u32 = 80,
    height: u32 = 24,
    title: []const u8 = "",
    current_path: []const u8 = "",
    current_command: []const u8 = "",
    start_command: []const u8 = "",
    pid: ?u32 = null,
    dead: bool = false,
};

pub const Window = struct {
    /// tmux window id (`@N`); the wmux workspace ref number.
    id: u32,
    /// wmux workspace UUID ("" when unknown).
    uuid: []const u8 = "",
    index: u32 = 0,
    name: []const u8 = "",
    active: bool = false,
    /// The previously selected window of its session (`-` flag, `{last}`).
    last: bool = false,
    width: u32 = 80,
    height: u32 = 24,
    /// In pane index order.
    panes: []const Pane = &.{},
};

pub const Session = struct {
    /// tmux session id (`$N`).
    id: u32,
    name: []const u8,
    attached: bool = false,
    /// In window index order.
    windows: []const Window = &.{},
};

pub const Snapshot = struct {
    sessions: []const Session = &.{},
    /// The pane the shim runs in (`TMUX_PANE` / `CMUX_SURFACE_ID`), if known.
    caller_pane: ?u32 = null,
};

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

pub const ShellCommand = union(enum) {
    /// No command: the host's default shell.
    none,
    /// `-- cat`: an inert placeholder pane that `respawn-pane` replaces
    /// (Claude Code teammate protocol); never actually run `cat`.
    placeholder,
    /// One string: tmux runs it through `sh -c` (wmux: Git Bash `-c`).
    shell: []const u8,
    /// Several words: an argv executed directly.
    argv: []const []const u8,
};

pub const Spawn = struct {
    cwd: ?[]const u8 = null,
    /// `KEY=VALUE` entries from `-e`.
    env: []const []const u8 = &.{},
    command: ShellCommand = .none,
};

pub const Direction = enum { right, down, left, up };

pub const NewSessionReq = struct { name: ?[]const u8, window_name: ?[]const u8, detached: bool, spawn: Spawn };
pub const NewWindowReq = struct { session: u32, name: ?[]const u8, detached: bool, spawn: Spawn };
pub const SplitReq = struct {
    window: u32,
    /// The pane to split.
    target: u32,
    /// Where the new pane goes relative to `target`.
    direction: Direction,
    size: ?parse.Size,
    /// `-d`: keep focus where it is.
    detached: bool,
    /// `-f`: span the whole window.
    full: bool,
    spawn: Spawn,
};
pub const RespawnReq = struct { pane: u32, kill: bool, spawn: Spawn };
pub const SendItem = struct {
    bytes: []const u8,
    /// True for a translated key name (Enter, C-c, ...), false for text.
    key: bool,
};
pub const SendReq = struct { pane: u32, items: []const SendItem };
pub const PaneReq = struct { pane: u32 };
pub const WindowReq = struct { window: u32 };
pub const SessionReq = struct { session: u32 };
pub const PaneDirectionReq = struct { pane: u32, direction: Direction };
pub const TitleReq = struct { pane: u32, title: []const u8 };
pub const RenameReq = struct { id: u32, name: []const u8 };
pub const ResizeReq = struct {
    pane: u32,
    direction: ?Direction = null,
    amount: u32 = 1,
    width: ?parse.Size = null,
    height: ?parse.Size = null,
    zoom: bool = false,
};
pub const LayoutReq = struct { window: u32, layout: []const u8 };
pub const CaptureReq = struct {
    pane: u32,
    start: ?parse.Line = null,
    end: ?parse.Line = null,
    join: bool = false,
    escapes: bool = false,
    alternate: bool = false,
    keep_trailing: bool = false,
};
pub const MessageReq = struct { pane: ?u32, text: []const u8 };
pub const WaitMode = enum { wait, signal, lock, unlock };
pub const WaitReq = struct { channel: []const u8, mode: WaitMode };
pub const ShellReq = struct { command: []const u8, cwd: ?[]const u8 };
pub const OptionScope = enum { server, session, window, pane };
pub const OptionReq = struct {
    /// Raw `-t` value (unresolved; options are accepted and ignored).
    target: ?[]const u8,
    name: []const u8,
    value: ?[]const u8,
    scope: OptionScope,
    global: bool,
    unset: bool,
    append: bool,
};
pub const SwapReq = struct { src: u32, dst: u32, focus: bool };
pub const BreakReq = struct { pane: u32, detached: bool, name: ?[]const u8 };
pub const JoinReq = struct { src: u32, dst: u32, direction: Direction, size: ?parse.Size, detached: bool };
pub const PipeReq = struct { pane: u32, command: ?[]const u8, input: bool, output: bool, toggle: bool };
pub const ReadFileReq = struct {
    /// `-` means stdin.
    path: []const u8,
};
pub const WriteFileReq = struct { path: []const u8, data: []const u8, append: bool };

// ---------------------------------------------------------------------------
// Executor interface
// ---------------------------------------------------------------------------

pub const OpError = error{ OutOfMemory, Failed };

pub const OpCtx = struct {
    /// Per-run arena: results (snapshots, captured text) may live here.
    arena: Allocator,
    /// Set by an op before returning `error.Failed`; printed on stderr.
    message: ?[]const u8 = null,

    pub fn fail(self: *OpCtx, comptime fmt: []const u8, args: anytype) OpError {
        self.message = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
        return error.Failed;
    }
};

fn Op(comptime Req: type, comptime Ret: type) type {
    return ?*const fn (ptr: *anyopaque, ctx: *OpCtx, req: Req) OpError!Ret;
}

/// Every operation takes one request value. A null entry means the host
/// does not offer it; commands needing it print
/// `Unsupported tmux compatibility command: <verb>` and fail.
pub const VTable = struct {
    snapshot: Op(void, Snapshot) = null,
    /// Returns the new session's first pane id.
    newSession: Op(NewSessionReq, u32) = null,
    /// Returns the new window's pane id.
    newWindow: Op(NewWindowReq, u32) = null,
    /// Returns the new pane id.
    splitPane: Op(SplitReq, u32) = null,
    respawnPane: Op(RespawnReq, void) = null,
    sendKeys: Op(SendReq, void) = null,
    selectPane: Op(PaneReq, void) = null,
    selectPaneDirection: Op(PaneDirectionReq, void) = null,
    setPaneTitle: Op(TitleReq, void) = null,
    selectWindow: Op(WindowReq, void) = null,
    renameWindow: Op(RenameReq, void) = null,
    renameSession: Op(RenameReq, void) = null,
    killPane: Op(PaneReq, void) = null,
    killWindow: Op(WindowReq, void) = null,
    killSession: Op(SessionReq, void) = null,
    resizePane: Op(ResizeReq, void) = null,
    selectLayout: Op(LayoutReq, void) = null,
    capturePane: Op(CaptureReq, []const u8) = null,
    displayMessage: Op(MessageReq, void) = null,
    waitFor: Op(WaitReq, void) = null,
    /// Returns the shell command's exit code.
    runShell: Op(ShellReq, u8) = null,
    setOption: Op(OptionReq, void) = null,
    swapPane: Op(SwapReq, void) = null,
    /// Returns the moved pane's id.
    breakPane: Op(BreakReq, u32) = null,
    joinPane: Op(JoinReq, void) = null,
    pipePane: Op(PipeReq, void) = null,
    clearHistory: Op(PaneReq, void) = null,
    lastPane: Op(WindowReq, void) = null,
    lastWindow: Op(SessionReq, void) = null,
    nextWindow: Op(SessionReq, void) = null,
    previousWindow: Op(SessionReq, void) = null,
    readFile: Op(ReadFileReq, []const u8) = null,
    writeFile: Op(WriteFileReq, void) = null,
};

pub const Executor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
};

/// Builds an `Executor` from any type that declares some of the `VTable`
/// operations as `pub fn name(self: *T, ctx: *OpCtx, req: Req) OpError!Ret`.
pub fn implement(comptime T: type, ptr: *T) Executor {
    const S = struct {
        const vtable: VTable = blk: {
            var vt: VTable = .{};
            for (std.meta.fields(VTable)) |f| {
                if (@hasDecl(T, f.name)) {
                    const F = @typeInfo(@typeInfo(f.type).optional.child).pointer.child;
                    const info = @typeInfo(F).@"fn";
                    const Req = info.params[2].type.?;
                    const Ret = @typeInfo(info.return_type.?).error_union.payload;
                    @field(vt, f.name) = &Thunk(T, f.name, Req, Ret).call;
                }
            }
            break :blk vt;
        };
    };
    return .{ .ptr = ptr, .vtable = &S.vtable };
}

fn Thunk(comptime T: type, comptime name: []const u8, comptime Req: type, comptime Ret: type) type {
    return struct {
        fn call(p: *anyopaque, ctx: *OpCtx, req: Req) OpError!Ret {
            const self: *T = @ptrCast(@alignCast(p));
            return @field(T, name)(self, ctx, req);
        }
    };
}

fn OpRet(comptime name: []const u8) type {
    const F = @typeInfo(@typeInfo(@FieldType(VTable, name)).optional.child).pointer.child;
    return @typeInfo(@typeInfo(F).@"fn".return_type.?).error_union.payload;
}

/// Operations that do not change the model (no snapshot refresh after).
fn isReadOnly(comptime name: []const u8) bool {
    const ro = [_][]const u8{ "snapshot", "capturePane", "waitFor", "runShell", "readFile", "writeFile", "displayMessage", "setOption" };
    inline for (ro) |r| {
        if (comptime std.mem.eql(u8, r, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

pub const placeholder_message = "tmux compatibility placeholder. This command is currently not supported.";

pub const Options = struct {
    /// `#{socket_path}` when `-S` was not given.
    socket_path: []const u8 = "",
    /// `#{pid}` (the wmux app's process id).
    server_pid: ?u32 = null,
    /// Route split-window into the main-vertical agent column when the
    /// store holds a layout for the workspace (cmux placement).
    main_vertical_placement: bool = true,
    /// Seed that layout on the first `-h` split of a single-pane window, so
    /// teammates stack in a column even without `select-layout`.
    auto_main_vertical: bool = true,
};

pub const Error = error{ OutOfMemory, WriteFailed, CommandFailed };

/// Nested command depth for if-shell branches and hooks.
const max_depth = 8;

const default_formats = struct {
    const list_panes = "#{pane_index}: [#{pane_width}x#{pane_height}] #{pane_id}#{?pane_active, (active),}";
    const list_panes_session = "#{window_index}." ++ list_panes;
    const list_panes_all = "#{session_name}:" ++ list_panes_session;
    const list_windows = "#{window_index}: #{window_name}#{window_flags} (#{window_panes} panes) [#{window_width}x#{window_height}] #{window_id}#{?window_active, (active),}";
    const list_windows_all = "#{session_name}:" ++ list_windows;
    const list_sessions = "#{session_name}: #{session_windows} windows#{?session_attached, (attached),}";
    const list_buffers = "#{buffer_name}: #{buffer_size} bytes: \"#{buffer_sample}\"";
    const new_session = "#{session_name}:";
    const new_window = "#{session_name}:#{window_index}";
    const new_pane = "#{session_name}:#{window_index}.#{pane_index}";
    const display = "[#{session_name}] #{window_index}:#{window_name}, current pane #{pane_index} - (#{pane_id})";
};

/// Variables printed by `display-message -a`, in order.
const format_variables = [_][]const u8{
    "buffer_name",        "buffer_sample",        "buffer_size",
    "pane_active",        "pane_current_command", "pane_current_path",
    "pane_dead",          "pane_height",          "pane_id",
    "pane_index",         "pane_pid",             "pane_ref",
    "pane_start_command", "pane_title",           "pane_width",
    "pid",                "session_attached",     "session_id",
    "session_name",       "session_windows",      "socket_path",
    "version",            "window_active",        "window_flags",
    "window_height",      "window_id",            "window_index",
    "window_name",        "window_panes",         "window_uuid",
    "window_width",       "workspace_id",
};

const Found = struct {
    session: ?*const Session = null,
    window: ?*const Window = null,
    pane: ?*const Pane = null,
};

const Want = enum { session, window, pane };

pub const Engine = struct {
    gpa: Allocator,
    exec: Executor,
    /// Loaded by the caller (under the store lock); written back by the
    /// caller when `store_dirty` is set after `run`.
    store: *Store,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    options: Options = .{},
    store_dirty: bool = false,

    arena: Allocator = undefined,
    globals: parse.Globals = .{},
    snap: ?Snapshot = null,
    /// Set while hook commands run: like tmux, they never fire hooks.
    in_hook: bool = false,

    /// Runs one shim invocation (argv without argv[0]) and returns the exit
    /// code. Output is flushed before returning.
    pub fn run(self: *Engine, argv: []const []const u8) u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        self.arena = arena_state.allocator();
        self.snap = null;
        self.globals = .{};
        self.in_hook = false;
        defer self.snap = null;
        const code: u8 = self.runInner(argv) catch |e| switch (e) {
            error.OutOfMemory => blk: {
                self.err.writeAll("out of memory\n") catch {};
                break :blk 1;
            },
            error.WriteFailed, error.CommandFailed => 1,
        };
        self.out.flush() catch {};
        self.err.flush() catch {};
        return code;
    }

    fn runInner(self: *Engine, argv: []const []const u8) Error!u8 {
        var diag: parse.Diag = .{};
        const inv = parse.parseInvocation(self.arena, argv, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.err.print("{s}\n", .{diag.message});
                return 1;
            },
        };
        self.globals = inv.globals;
        if (inv.globals.version) {
            try self.out.print("{s}\n", .{parse.version_line});
            return 0;
        }
        for (inv.commands) |cmd| try self.execute(cmd, 0);
        return 0;
    }

    fn runString(self: *Engine, s: []const u8, depth: usize) Error!void {
        if (depth >= max_depth) return self.fail("command nesting too deep", .{});
        var diag: parse.Diag = .{};
        const cmds = parse.parseCommandString(self.arena, s, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail("{s}", .{diag.message}),
        };
        for (cmds) |cmd| try self.execute(cmd, depth);
    }

    fn execute(self: *Engine, cmd: parse.Command, depth: usize) Error!void {
        const a = cmd.args;
        switch (cmd.id()) {
            .new_session => try self.cmdNewSession(cmd),
            .new_window => try self.cmdNewWindow(cmd),
            .split_window => try self.cmdSplitWindow(cmd),
            .send_keys => try self.cmdSendKeys(cmd),
            .select_pane => try self.cmdSelectPane(cmd),
            .select_window => try self.cmdSelectWindow(cmd),
            .switch_client => {
                if (a.get('t') == null) return;
                const f = try self.resolve(a.get('t'), .session);
                if (f.window) |w| try self.call("selectWindow", cmd.word, WindowReq{ .window = w.id });
            },
            .select_layout => try self.cmdSelectLayout(cmd),
            .kill_pane => try self.cmdKillPane(cmd),
            .kill_window => try self.cmdKillWindow(cmd),
            .kill_session => try self.cmdKillSession(cmd),
            .respawn_pane => {
                const f = try self.resolve(a.get('t'), .pane);
                const spawn = try self.spawnFrom(a);
                try self.call("respawnPane", cmd.word, RespawnReq{ .pane = f.pane.?.id, .kill = a.has('k'), .spawn = spawn });
            },
            .list_panes => try self.cmdListPanes(cmd),
            .list_windows => try self.cmdListWindows(cmd),
            .list_sessions => try self.cmdListSessions(cmd),
            .display_message => try self.cmdDisplayMessage(cmd),
            .has_session => _ = try self.resolve(a.get('t'), .session),
            .resize_pane => try self.cmdResizePane(cmd),
            .capture_pane => try self.cmdCapturePane(cmd),
            .set_option, .set_window_option => try self.cmdSetOption(cmd),
            .show_options => try self.cmdShowOptions(cmd, null),
            .show_window_options => try self.cmdShowOptions(cmd, .window),
            .wait_for => {
                const mode: WaitMode = if (a.has('S')) .signal else if (a.has('L')) .lock else if (a.has('U')) .unlock else .wait;
                try self.call("waitFor", cmd.word, WaitReq{ .channel = a.positionals[0], .mode = mode });
            },
            .rename_window => {
                const f = try self.resolve(a.get('t'), .window);
                try self.call("renameWindow", cmd.word, RenameReq{ .id = f.window.?.id, .name = a.positionals[0] });
            },
            .rename_session => {
                const f = try self.resolve(a.get('t'), .session);
                try self.call("renameSession", cmd.word, RenameReq{ .id = f.session.?.id, .name = a.positionals[0] });
            },
            .last_pane => {
                const f = try self.resolve(a.get('t'), .window);
                try self.call("lastPane", cmd.word, WindowReq{ .window = f.window.?.id });
            },
            .last_window, .next_window, .previous_window => {
                const f = try self.resolve(a.get('t'), .session);
                const req: SessionReq = .{ .session = f.session.?.id };
                switch (cmd.id()) {
                    .last_window => try self.call("lastWindow", cmd.word, req),
                    .next_window => try self.call("nextWindow", cmd.word, req),
                    else => try self.call("previousWindow", cmd.word, req),
                }
            },
            .swap_pane => try self.cmdSwapPane(cmd),
            .break_pane => {
                const f = try self.resolve(a.get('s'), .pane);
                const id = try self.call("breakPane", cmd.word, BreakReq{ .pane = f.pane.?.id, .detached = a.has('d'), .name = a.get('n') });
                if (a.has('P')) try self.printForPane(id, a.get('F') orelse default_formats.new_pane);
            },
            .join_pane => try self.cmdJoinPane(cmd),
            .pipe_pane => {
                const f = try self.resolve(a.get('t'), .pane);
                const command: ?[]const u8 = if (a.positionals.len > 0 and a.positionals[0].len > 0) a.positionals[0] else null;
                try self.call("pipePane", cmd.word, PipeReq{
                    .pane = f.pane.?.id,
                    .command = command,
                    .input = a.has('I'),
                    .output = a.has('O') or !a.has('I'),
                    .toggle = a.has('o'),
                });
            },
            .clear_history => {
                const f = try self.resolve(a.get('t'), .pane);
                try self.call("clearHistory", cmd.word, PaneReq{ .pane = f.pane.?.id });
            },
            .find_window => try self.cmdFindWindow(cmd),
            .set_buffer => try self.cmdSetBuffer(cmd),
            .show_buffer => {
                const name = a.get('b') orelse store_mod.default_buffer;
                const data = self.store.getBuffer(name) orelse return self.fail("no buffer {s}", .{name});
                try self.out.writeAll(data);
                if (data.len == 0 or data[data.len - 1] != '\n') try self.out.writeByte('\n');
            },
            .save_buffer => {
                const name = a.get('b') orelse store_mod.default_buffer;
                const data = self.store.getBuffer(name) orelse return self.fail("no buffer {s}", .{name});
                const path = a.positionals[0];
                if (std.mem.eql(u8, path, "-")) {
                    try self.out.writeAll(data);
                } else {
                    try self.call("writeFile", cmd.word, WriteFileReq{ .path = path, .data = data, .append = a.has('a') });
                }
            },
            .load_buffer => {
                const data = try self.call("readFile", cmd.word, ReadFileReq{ .path = a.positionals[0] });
                try self.store.setBuffer(self.gpa, a.get('b') orelse store_mod.default_buffer, data, false);
                self.store_dirty = true;
            },
            .list_buffers => try self.cmdListBuffers(cmd),
            .paste_buffer => try self.cmdPasteBuffer(cmd),
            .delete_buffer => {
                const name = a.get('b') orelse store_mod.default_buffer;
                if (!self.store.deleteBuffer(self.gpa, name)) return self.fail("no buffer {s}", .{name});
                self.store_dirty = true;
            },
            .set_hook => try self.cmdSetHook(cmd, depth),
            .show_hooks => {
                const it_keys = self.store.hooks.keys();
                const it_vals = self.store.hooks.values();
                for (it_keys, it_vals) |k, v| {
                    if (a.positionals.len > 0 and !std.mem.eql(u8, a.positionals[0], k)) continue;
                    try self.out.print("{s} {s}\n", .{ k, v });
                }
            },
            .if_shell => try self.cmdIfShell(cmd, depth),
            .attach_session, .detach_client, .source_file, .refresh_client, .start_server, .bind_key, .unbind_key, .copy_mode => {},
            .display_popup => return self.fail(placeholder_message, .{}),
        }
        if (cmd.id() != .set_hook and !self.in_hook and depth < max_depth) {
            const hook_name = try std.fmt.allocPrint(self.arena, "after-{s}", .{cmd.spec.name});
            if (self.store.getHook(hook_name)) |hook| {
                const owned = try self.arena.dupe(u8, hook);
                self.runHook(owned, depth + 1) catch |e| switch (e) {
                    error.CommandFailed => {}, // hook failures never fail the command
                    else => return e,
                };
            }
        }
    }

    /// Runs hook commands with hooks disabled, as tmux does, so a hook can
    /// never re-trigger itself or another hook.
    fn runHook(self: *Engine, s: []const u8, depth: usize) Error!void {
        const was = self.in_hook;
        self.in_hook = true;
        defer self.in_hook = was;
        return self.runString(s, depth);
    }

    // -- plumbing ------------------------------------------------------------

    fn fail(self: *Engine, comptime fmt: []const u8, args: anytype) Error {
        self.err.print(fmt ++ "\n", args) catch return error.WriteFailed;
        return error.CommandFailed;
    }

    fn call(self: *Engine, comptime name: []const u8, verb: []const u8, req: anytype) Error!OpRet(name) {
        const f = @field(self.exec.vtable, name) orelse return self.fail(parse.unsupported_prefix ++ "{s}", .{verb});
        var ctx: OpCtx = .{ .arena = self.arena };
        const result = f(self.exec.ptr, &ctx, req) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => return self.fail("{s}", .{ctx.message orelse "command failed"}),
        };
        if (comptime !isReadOnly(name)) self.snap = null;
        return result;
    }

    fn getSnap(self: *Engine) Error!*const Snapshot {
        if (self.snap == null) self.snap = try self.call("snapshot", "list-sessions", {});
        return &self.snap.?;
    }

    fn markDirty(self: *Engine) void {
        self.store_dirty = true;
    }

    // -- resolution ----------------------------------------------------------

    fn activeWindow(s: *const Session) ?*const Window {
        for (s.windows) |*w| {
            if (w.active) return w;
        }
        return if (s.windows.len > 0) &s.windows[0] else null;
    }

    fn activePane(w: *const Window) ?*const Pane {
        for (w.panes) |*p| {
            if (p.active) return p;
        }
        return if (w.panes.len > 0) &w.panes[0] else null;
    }

    fn completeSession(s: *const Session) Found {
        const w = activeWindow(s);
        return .{ .session = s, .window = w, .pane = if (w) |x| activePane(x) else null };
    }

    fn completeWindow(s: *const Session, w: *const Window) Found {
        return .{ .session = s, .window = w, .pane = activePane(w) };
    }

    fn findPane(snap: *const Snapshot, comptime pred: anytype, arg: anytype) ?Found {
        for (snap.sessions) |*s| {
            for (s.windows) |*w| {
                for (w.panes) |*p| {
                    if (pred(p, arg)) return .{ .session = s, .window = w, .pane = p };
                }
            }
        }
        return null;
    }

    fn paneIdIs(p: *const Pane, n: u32) bool {
        return p.id == n;
    }

    fn paneUuidIs(p: *const Pane, u: []const u8) bool {
        return p.uuid.len > 0 and std.ascii.eqlIgnoreCase(p.uuid, u);
    }

    fn paneWmuxIs(p: *const Pane, n: u32) bool {
        return p.wmux_pane != null and p.wmux_pane.? == n and p.active;
    }

    fn paneWmuxAny(p: *const Pane, n: u32) bool {
        return p.wmux_pane != null and p.wmux_pane.? == n;
    }

    fn findPaneId(self: *Engine, n: u32) Error!?Found {
        const snap = try self.getSnap();
        if (findPane(snap, paneIdIs, n)) |f| return f;
        if (self.store.paneSurface(n)) |u| return findPane(snap, paneUuidIs, u);
        return null;
    }

    fn current(self: *Engine) Error!?Found {
        const snap = try self.getSnap();
        if (snap.caller_pane) |id| {
            // Same lookup as `-t %N`, including the store's pane map.
            if (try self.findPaneId(id)) |f| return f;
        }
        for (snap.sessions) |*s| {
            if (s.attached) return completeSession(s);
        }
        if (snap.sessions.len > 0) return completeSession(&snap.sessions[0]);
        return null;
    }

    fn findSessionByName(snap: *const Snapshot, raw: []const u8) ?*const Session {
        if (raw.len > 1 and raw[0] == '$') {
            if (std.fmt.parseInt(u32, raw[1..], 10)) |n| {
                for (snap.sessions) |*s| {
                    if (s.id == n) return s;
                }
                return null;
            } else |_| {}
        }
        const exact = raw.len > 0 and raw[0] == '=';
        const name = if (exact) raw[1..] else raw;
        for (snap.sessions) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        if (exact or name.len == 0) return null;
        var hit: ?*const Session = null;
        for (snap.sessions) |*s| {
            if (std.mem.startsWith(u8, s.name, name)) {
                if (hit != null) return null; // ambiguous
                hit = s;
            }
        }
        return hit;
    }

    fn findWindowIn(s: *const Session, raw: []const u8) ?*const Window {
        if (s.windows.len == 0) return null;
        if (raw.len > 1 and raw[0] == '@') {
            const n = std.fmt.parseInt(u32, raw[1..], 10) catch return null;
            for (s.windows) |*w| {
                if (w.id == n) return w;
            }
            return null;
        }
        if (std.mem.eql(u8, raw, "{start}") or std.mem.eql(u8, raw, "^")) return &s.windows[0];
        if (std.mem.eql(u8, raw, "{end}") or std.mem.eql(u8, raw, "$")) return &s.windows[s.windows.len - 1];
        if (std.mem.eql(u8, raw, "{last}") or std.mem.eql(u8, raw, "!")) {
            for (s.windows) |*w| {
                if (w.last) return w;
            }
            return null;
        }
        if (std.mem.eql(u8, raw, "+") or std.mem.eql(u8, raw, "-") or std.mem.eql(u8, raw, "{next}") or std.mem.eql(u8, raw, "{previous}")) {
            const act = activeWindow(s).?;
            const i = (@intFromPtr(act) - @intFromPtr(s.windows.ptr)) / @sizeOf(Window);
            const fwd = raw[0] == '+' or std.mem.eql(u8, raw, "{next}");
            const j = if (fwd) (i + 1) % s.windows.len else (i + s.windows.len - 1) % s.windows.len;
            return &s.windows[j];
        }
        if (std.fmt.parseInt(u32, raw, 10)) |idx| {
            for (s.windows) |*w| {
                if (w.index == idx) return w;
            }
            return null;
        } else |_| {}
        const exact = raw[0] == '=';
        const name = if (exact) raw[1..] else raw;
        for (s.windows) |*w| {
            if (std.mem.eql(u8, w.name, name)) return w;
        }
        if (exact or name.len == 0) return null;
        var hit: ?*const Window = null;
        for (s.windows) |*w| {
            if (std.mem.startsWith(u8, w.name, name)) {
                if (hit != null) return null;
                hit = w;
            }
        }
        return hit;
    }

    fn findPaneIn(w: *const Window, raw: []const u8) ?*const Pane {
        if (w.panes.len == 0) return null;
        if (raw.len > 1 and raw[0] == '%') {
            const n = std.fmt.parseInt(u32, raw[1..], 10) catch return null;
            for (w.panes) |*p| {
                if (p.id == n) return p;
            }
            return null;
        }
        if (std.mem.eql(u8, raw, "+") or std.mem.eql(u8, raw, "-") or std.mem.eql(u8, raw, "{next}") or std.mem.eql(u8, raw, "{previous}")) {
            const act = activePane(w).?;
            const fwd = raw[0] == '+' or std.mem.eql(u8, raw, "{next}");
            return neighbor(w, act, fwd);
        }
        // `{start}`/`{end}` are window tokens in tmux, not pane tokens.
        if (std.mem.eql(u8, raw, "{top}")) return &w.panes[0];
        if (std.mem.eql(u8, raw, "{bottom}")) return &w.panes[w.panes.len - 1];
        const idx = std.fmt.parseInt(u32, raw, 10) catch return null;
        for (w.panes) |*p| {
            if (p.index == idx) return p;
        }
        return null;
    }

    fn neighbor(w: *const Window, p: *const Pane, forward: bool) *const Pane {
        const i = (@intFromPtr(p) - @intFromPtr(w.panes.ptr)) / @sizeOf(Pane);
        const n = w.panes.len;
        return &w.panes[if (forward) (i + 1) % n else (i + n - 1) % n];
    }

    fn notFound(self: *Engine, want: Want, raw: []const u8) Error {
        return switch (want) {
            .session => self.fail("can't find session: {s}", .{raw}),
            .window => self.fail("can't find window: {s}", .{raw}),
            .pane => self.fail("can't find pane: {s}", .{raw}),
        };
    }

    /// Resolves a `-t`/`-s` value (null = current) into a session, window
    /// and pane. The result always has the parts `want` needs.
    fn resolve(self: *Engine, raw_opt: ?[]const u8, want: Want) Error!Found {
        const raw = raw_opt orelse "";
        const snap = try self.getSnap();
        const t = parse.parseTarget(raw);
        const found: Found = switch (t) {
            .current => (try self.current()) orelse return self.fail("no current session", .{}),
            .pane_id => |n| (try self.findPaneId(n)) orelse return self.notFound(want, raw),
            .wmux_pane => |n| findPane(snap, paneWmuxIs, n) orelse findPane(snap, paneWmuxAny, n) orelse return self.notFound(want, raw),
            .window_id => |n| blk: {
                for (snap.sessions) |*s| {
                    for (s.windows) |*w| {
                        if (w.id == n) break :blk completeWindow(s, w);
                    }
                }
                return self.notFound(want, raw);
            },
            .session_id => |n| blk: {
                for (snap.sessions) |*s| {
                    if (s.id == n) break :blk completeSession(s);
                }
                return self.notFound(want, raw);
            },
            .uuid => |u| blk: {
                if (findPane(snap, paneUuidIs, u)) |f| break :blk f;
                for (snap.sessions) |*s| {
                    for (s.windows) |*w| {
                        if (w.uuid.len > 0 and std.ascii.eqlIgnoreCase(w.uuid, u)) break :blk completeWindow(s, w);
                    }
                }
                return self.notFound(want, raw);
            },
            .bare => |name| blk: {
                // tmux's order per target type: a session target names a
                // session only (so kill-session never widens to the
                // session of a same-named window); a window target is a
                // window of the current session, then a session; a pane
                // target is a pane of the current window first.
                if (want != .session) {
                    if (try self.current()) |c| {
                        if (want == .pane) {
                            if (c.window) |w| {
                                if (findPaneIn(w, name)) |p| break :blk .{ .session = c.session, .window = w, .pane = p };
                            }
                        }
                        if (c.session) |s| {
                            if (findWindowIn(s, name)) |w| break :blk completeWindow(s, w);
                        }
                    }
                }
                if (findSessionByName(snap, name)) |s| break :blk completeSession(s);
                return self.notFound(want, raw);
            },
            .path => |p| blk: {
                const cur = try self.current();
                const s: *const Session = if (p.session) |sn|
                    findSessionByName(snap, sn) orelse return self.fail("can't find session: {s}", .{sn})
                else if (cur) |c| c.session.? else return self.fail("no current session", .{});
                const same_session = cur != null and cur.?.session == s;
                const w: *const Window = if (p.window) |wn|
                    findWindowIn(s, wn) orelse return self.fail("can't find window: {s}", .{wn})
                else if (same_session and cur.?.window != null) cur.?.window.? else activeWindow(s) orelse return self.fail("can't find window: {s}", .{raw});
                const pane: ?*const Pane = if (p.pane) |pn|
                    findPaneIn(w, pn) orelse return self.fail("can't find pane: {s}", .{pn})
                else if (same_session and cur.?.window == w) cur.?.pane else activePane(w);
                break :blk .{ .session = s, .window = w, .pane = pane };
            },
        };
        switch (want) {
            .session => if (found.session == null) return self.notFound(want, raw),
            .window => if (found.window == null) return self.notFound(want, raw),
            .pane => if (found.pane == null) return self.notFound(want, raw),
        }
        return found;
    }

    fn paneBySurface(w: *const Window, key: []const u8) ?*const Pane {
        for (w.panes) |*p| {
            if (p.uuid.len > 0 and std.ascii.eqlIgnoreCase(p.uuid, key)) return p;
        }
        if (key.len > 1 and key[0] == '%') {
            const n = std.fmt.parseInt(u32, key[1..], 10) catch return null;
            for (w.panes) |*p| {
                if (p.id == n and p.uuid.len == 0) return p;
            }
        }
        return null;
    }

    /// Store key for a pane: its surface UUID, or `%N` when unknown.
    fn surfaceKey(self: *Engine, p: *const Pane) Error![]const u8 {
        if (p.uuid.len > 0) return p.uuid;
        return std.fmt.allocPrint(self.arena, "%{d}", .{p.id});
    }

    /// Store key for a window: its workspace UUID, or `@N` when unknown.
    fn workspaceKey(self: *Engine, w: *const Window) Error![]const u8 {
        if (w.uuid.len > 0) return w.uuid;
        return std.fmt.allocPrint(self.arena, "@{d}", .{w.id});
    }

    fn recordPane(self: *Engine, id: u32) Error!?Found {
        const f = (try self.findPaneId(id)) orelse return null;
        const p = f.pane.?;
        if (p.uuid.len > 0) {
            const known = self.store.paneSurface(id);
            if (known == null or !std.mem.eql(u8, known.?, p.uuid)) {
                try self.store.setPaneSurface(self.gpa, id, p.uuid);
                self.markDirty();
            }
        }
        return f;
    }

    fn forgetPanes(self: *Engine, panes: []const Pane) Error!void {
        for (panes) |*p| {
            if (self.store.forgetSurface(self.gpa, try self.surfaceKey(p))) self.markDirty();
            if (self.store.paneSurface(p.id) != null) {
                // `%N` recorded with another surface key form.
                const kv = self.store.pane_surfaces.fetchOrderedRemove(p.id).?;
                self.gpa.free(kv.value);
                self.markDirty();
            }
        }
    }

    // -- formats -------------------------------------------------------------

    const FmtCtx = struct {
        engine: *Engine,
        found: Found = .{},
        buffer_name: ?[]const u8 = null,
        buffer_data: ?[]const u8 = null,

        fn resolver(self: *const FmtCtx) format.Resolver {
            return .{ .ptr = self, .lookupFn = lookup };
        }

        fn lookup(ptr: *const anyopaque, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
            const self: *const FmtCtx = @ptrCast(@alignCast(ptr));
            const e = self.engine;
            const P = struct {
                fn num(a: Allocator, n: anytype) Allocator.Error![]const u8 {
                    return std.fmt.allocPrint(a, "{d}", .{n});
                }
                fn flag(b: bool) []const u8 {
                    return if (b) "1" else "0";
                }
            };
            if (std.mem.eql(u8, name, "version")) return "3.4";
            if (std.mem.eql(u8, name, "socket_path")) return e.globals.socket_path orelse e.options.socket_path;
            if (std.mem.eql(u8, name, "pid")) return if (e.options.server_pid) |p| try P.num(arena, p) else null;
            if (std.mem.startsWith(u8, name, "buffer_")) {
                const data = self.buffer_data orelse return null;
                if (std.mem.eql(u8, name, "buffer_name")) return self.buffer_name;
                if (std.mem.eql(u8, name, "buffer_size")) return try P.num(arena, data.len);
                if (std.mem.eql(u8, name, "buffer_sample")) return try bufferSample(arena, data);
                return null;
            }
            if (std.mem.startsWith(u8, name, "pane_")) {
                const p = self.found.pane orelse return null;
                const k = name["pane_".len..];
                if (std.mem.eql(u8, k, "id")) return try std.fmt.allocPrint(arena, "%{d}", .{p.id});
                if (std.mem.eql(u8, k, "ref")) return try std.fmt.allocPrint(arena, "surface:{d}", .{p.id});
                if (std.mem.eql(u8, k, "index")) return try P.num(arena, p.index);
                if (std.mem.eql(u8, k, "active")) return P.flag(p.active);
                if (std.mem.eql(u8, k, "width")) return try P.num(arena, p.width);
                if (std.mem.eql(u8, k, "height")) return try P.num(arena, p.height);
                if (std.mem.eql(u8, k, "title")) return p.title;
                if (std.mem.eql(u8, k, "current_path")) return p.current_path;
                if (std.mem.eql(u8, k, "current_command")) return p.current_command;
                if (std.mem.eql(u8, k, "start_command")) return p.start_command;
                if (std.mem.eql(u8, k, "pid")) return if (p.pid) |x| try P.num(arena, x) else null;
                if (std.mem.eql(u8, k, "dead")) return P.flag(p.dead);
                return null;
            }
            if (std.mem.startsWith(u8, name, "window_") or std.mem.eql(u8, name, "workspace_id")) {
                const w = self.found.window orelse return null;
                if (std.mem.eql(u8, name, "workspace_id") or std.mem.eql(u8, name, "window_uuid")) return if (w.uuid.len > 0) w.uuid else null;
                const k = name["window_".len..];
                if (std.mem.eql(u8, k, "id")) return try std.fmt.allocPrint(arena, "@{d}", .{w.id});
                if (std.mem.eql(u8, k, "index")) return try P.num(arena, w.index);
                if (std.mem.eql(u8, k, "name")) return w.name;
                if (std.mem.eql(u8, k, "active")) return P.flag(w.active);
                if (std.mem.eql(u8, k, "flags")) return if (w.active) "*" else if (w.last) "-" else "";
                if (std.mem.eql(u8, k, "width")) return try P.num(arena, w.width);
                if (std.mem.eql(u8, k, "height")) return try P.num(arena, w.height);
                if (std.mem.eql(u8, k, "panes")) return try P.num(arena, w.panes.len);
                return null;
            }
            if (std.mem.startsWith(u8, name, "session_")) {
                const s = self.found.session orelse return null;
                const k = name["session_".len..];
                if (std.mem.eql(u8, k, "id")) return try std.fmt.allocPrint(arena, "${d}", .{s.id});
                if (std.mem.eql(u8, k, "name")) return s.name;
                if (std.mem.eql(u8, k, "attached")) return P.flag(s.attached);
                if (std.mem.eql(u8, k, "windows")) return try P.num(arena, s.windows.len);
                return null;
            }
            return null;
        }
    };

    fn expandWith(self: *Engine, ctx: *const FmtCtx, fmt: []const u8) Error![]const u8 {
        _ = self;
        return format.expand(ctx.engine.arena, fmt, ctx.resolver());
    }

    fn expandFound(self: *Engine, f: Found, fmt: []const u8) Error![]const u8 {
        const ctx: FmtCtx = .{ .engine = self, .found = f };
        return self.expandWith(&ctx, fmt);
    }

    fn printLine(self: *Engine, f: Found, fmt: []const u8) Error!void {
        try self.out.print("{s}\n", .{try self.expandFound(f, fmt)});
    }

    /// Prints a `-P` format for a pane created a moment ago.
    fn printForPane(self: *Engine, id: u32, fmt: []const u8) Error!void {
        if (try self.findPaneId(id)) |f| return self.printLine(f, fmt);
        const synthetic: Pane = .{ .id = id };
        try self.printLine(.{ .pane = &synthetic }, fmt);
    }

    /// Passes the filter (`-f`) when unset or truthy.
    fn passes(self: *Engine, f: Found, filter: ?[]const u8) Error!bool {
        const flt = filter orelse return true;
        return format.truthy(try self.expandFound(f, flt));
    }

    // -- spawning ------------------------------------------------------------

    fn spawnFrom(self: *Engine, a: parse.Args) Error!Spawn {
        const env = try a.getAll(self.arena, 'e');
        for (env) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse 0;
            if (eq == 0) return self.fail("invalid environment: {s}", .{kv});
        }
        const pos = a.positionals;
        const command: ShellCommand = switch (pos.len) {
            0 => .none,
            1 => if (std.mem.eql(u8, std.mem.trim(u8, pos[0], " \t"), "cat"))
                .placeholder
            else if (std.mem.trim(u8, pos[0], " \t").len == 0) .none else .{ .shell = pos[0] },
            else => .{ .argv = pos },
        };
        return .{ .cwd = a.get('c'), .env = env, .command = command };
    }

    // -- commands ------------------------------------------------------------

    fn cmdNewSession(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const fmt = a.get('F') orelse default_formats.new_session;
        if (a.get('s')) |name| {
            const snap = try self.getSnap();
            for (snap.sessions) |*s| {
                if (!std.mem.eql(u8, s.name, name)) continue;
                if (!a.has('A')) return self.fail("duplicate session: {s}", .{name});
                const f = completeSession(s);
                if (!a.has('d')) {
                    if (f.window) |w| try self.call("selectWindow", cmd.word, WindowReq{ .window = w.id });
                }
                if (a.has('P')) try self.printLine(f, fmt);
                return;
            }
        }
        const spawn = try self.spawnFrom(a);
        const id = try self.call("newSession", cmd.word, NewSessionReq{ .name = a.get('s'), .window_name = a.get('n'), .detached = a.has('d'), .spawn = spawn });
        _ = try self.recordPane(id);
        if (a.has('P')) try self.printForPane(id, fmt);
    }

    fn cmdNewWindow(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        // tmux: -t is a target window; the new window joins its session.
        const f = try self.resolve(a.get('t'), .window);
        const spawn = try self.spawnFrom(a);
        const id = try self.call("newWindow", cmd.word, NewWindowReq{ .session = f.session.?.id, .name = a.get('n'), .detached = a.has('d'), .spawn = spawn });
        _ = try self.recordPane(id);
        if (a.has('P')) try self.printForPane(id, a.get('F') orelse default_formats.new_window);
    }

    fn sizeArg(self: *Engine, a: parse.Args) Error!?parse.Size {
        if (a.get('l')) |l| return parse.parseSize(l, false) orelse self.fail("invalid size: {s}", .{l});
        if (a.get('p')) |p| return parse.parseSize(p, true) orelse self.fail("invalid percentage: {s}", .{p});
        return null;
    }

    fn cmdSplitWindow(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const f = try self.resolve(a.get('t'), .pane);
        const window = f.window.?;
        var target = f.pane.?;
        var direction: Direction = if (a.has('h'))
            (if (a.has('b')) .left else .right)
        else
            (if (a.has('b')) .up else .down);
        var size = try self.sizeArg(a);
        const spawn = try self.spawnFrom(a);

        const ws = try self.workspaceKey(window);
        const Placement = enum { none, column, seed };
        var placement: Placement = .none;
        if (self.options.main_vertical_placement) {
            if (self.store.getLayout(ws)) |lo| {
                if (paneBySurface(window, lo.main)) |main_p| {
                    const col_p: ?*const Pane = if (lo.column) |c| paneBySurface(window, c) else null;
                    const in_layout = target.id == main_p.id or (col_p != null and target.id == col_p.?.id);
                    if (in_layout and !a.has('b')) {
                        if (col_p) |c| {
                            target = c;
                            direction = .down;
                            size = null;
                        } else {
                            target = main_p;
                            direction = .right;
                        }
                        placement = .column;
                    }
                } else {
                    _ = self.store.removeLayout(self.gpa, ws);
                    self.markDirty();
                }
            } else if (self.options.auto_main_vertical and direction == .right and window.panes.len == 1) {
                placement = .seed;
            }
        }
        const target_key = try self.surfaceKey(target);
        const id = try self.call("splitPane", cmd.word, SplitReq{
            .window = window.id,
            .target = target.id,
            .direction = direction,
            .size = size,
            .detached = a.has('d'),
            .full = a.has('f'),
            .spawn = spawn,
        });
        const created = try self.recordPane(id);
        const new_key = if (created) |c| try self.surfaceKey(c.pane.?) else try std.fmt.allocPrint(self.arena, "%{d}", .{id});
        switch (placement) {
            .none => {},
            .column => try self.store.setLayoutColumn(self.gpa, ws, new_key),
            .seed => try self.store.setLayout(self.gpa, ws, target_key, new_key),
        }
        try self.store.setLastSplit(self.gpa, ws, new_key);
        self.markDirty();
        if (a.has('P')) try self.printForPane(id, a.get('F') orelse default_formats.new_pane);
    }

    fn cmdSendKeys(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const f = try self.resolve(a.get('t'), .pane);
        if (a.has('X')) return self.fail("not in a mode", .{});
        var repeat: u32 = 1;
        if (a.get('N')) |n| {
            repeat = std.fmt.parseInt(u32, n, 10) catch 0;
            if (repeat == 0 or repeat > 10_000) return self.fail("repeat count invalid: {s}", .{n});
        }
        var items: std.ArrayList(SendItem) = .empty;
        for (a.positionals) |raw| {
            const word = if (a.has('F')) try self.expandFound(f, raw) else raw;
            if (a.has('H')) {
                const b = keys.parseHexByte(word) orelse return self.fail("invalid key: {s}", .{word});
                try items.append(self.arena, .{ .bytes = try self.arena.dupe(u8, &.{b}), .key = true });
            } else if (a.has('l')) {
                if (word.len > 0) try items.append(self.arena, .{ .bytes = word, .key = false });
            } else if (try keys.lookup(self.arena, word)) |bytes| {
                try items.append(self.arena, .{ .bytes = bytes, .key = true });
            } else if (word.len > 0) {
                try items.append(self.arena, .{ .bytes = word, .key = false });
            }
        }
        if (items.items.len == 0) return;
        // Reserve the repeats up front: appending the list to itself must
        // never reallocate while the source slice points at the old buffer.
        const once = items.items.len;
        try items.ensureTotalCapacityPrecise(self.arena, once * repeat);
        for (1..repeat) |_| items.appendSliceAssumeCapacity(items.items[0..once]);
        try self.call("sendKeys", cmd.word, SendReq{ .pane = f.pane.?.id, .items = items.items });
    }

    fn cmdSelectPane(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const f = try self.resolve(a.get('t'), .pane);
        const pane = f.pane.?;
        if (a.get('T')) |title| {
            // Titles never move focus (teammate panes are created with -d).
            return self.call("setPaneTitle", cmd.word, TitleReq{ .pane = pane.id, .title = title });
        }
        const dir: ?Direction = if (a.has('L')) .left else if (a.has('R')) .right else if (a.has('U')) .up else if (a.has('D')) .down else null;
        if (dir) |d| return self.call("selectPaneDirection", cmd.word, PaneDirectionReq{ .pane = pane.id, .direction = d });
        if (a.has('l')) return self.call("lastPane", cmd.word, WindowReq{ .window = f.window.?.id });
        // Style, mark and input-enable flags alone do not select.
        if (a.has('P') or a.has('m') or a.has('M') or a.has('d') or a.has('e')) return;
        try self.call("selectPane", cmd.word, PaneReq{ .pane = pane.id });
    }

    fn cmdSelectWindow(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        if (a.has('l') or a.has('n') or a.has('p')) {
            // -t stays a target window; these act on its session.
            const f = try self.resolve(a.get('t'), .window);
            const req: SessionReq = .{ .session = f.session.?.id };
            if (a.has('l')) return self.call("lastWindow", cmd.word, req);
            if (a.has('n')) return self.call("nextWindow", cmd.word, req);
            return self.call("previousWindow", cmd.word, req);
        }
        const f = try self.resolve(a.get('t'), .window);
        const w = f.window.?;
        if (a.has('T') and w.active) {
            return self.call("lastWindow", cmd.word, SessionReq{ .session = f.session.?.id });
        }
        try self.call("selectWindow", cmd.word, WindowReq{ .window = w.id });
    }

    const known_layouts = [_][]const u8{
        "even-horizontal", "even-vertical",          "main-horizontal", "main-horizontal-mirrored",
        "main-vertical",   "main-vertical-mirrored", "tiled",
    };

    fn cmdSelectLayout(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        if (a.positionals.len == 0) return; // -n/-p/-o/-E or re-apply: nothing to do
        const layout = a.positionals[0];
        var known = false;
        for (known_layouts) |k| {
            if (std.mem.eql(u8, k, layout)) known = true;
        }
        // Custom layout strings ("b0a3,80x24,0,0{...}") pass through.
        if (!known and std.mem.indexOfScalar(u8, layout, ',') == null) return self.fail("invalid layout: {s}", .{layout});
        const f = try self.resolve(a.get('t'), .pane);
        const window = f.window.?;
        try self.call("selectLayout", cmd.word, LayoutReq{ .window = window.id, .layout = layout });
        if (!std.mem.eql(u8, layout, "main-vertical")) return;

        // Seed the agent column (cmux placement state).
        const ws = try self.workspaceKey(window);
        const snap = try self.getSnap();
        var main: ?*const Pane = null;
        var column: ?*const Pane = null;
        if (self.store.getLayout(ws)) |lo| {
            main = paneBySurface(window, lo.main);
            if (lo.column) |c| column = paneBySurface(window, c);
        }
        if (main == null) {
            if (a.get('t') == null) {
                if (snap.caller_pane) |cp| {
                    for (window.panes) |*p| {
                        if (p.id == cp) main = p;
                    }
                }
            }
            if (main == null) main = f.pane;
        }
        const main_p = main orelse return;
        if (column == null) {
            if (self.store.getLastSplit(ws)) |ls| {
                if (paneBySurface(window, ls)) |p| {
                    if (p.id != main_p.id) column = p;
                }
            }
        }
        const main_key = try self.surfaceKey(main_p);
        const col_key: ?[]const u8 = if (column) |c| try self.surfaceKey(c) else null;
        try self.store.setLayout(self.gpa, ws, main_key, col_key);
        self.markDirty();
    }

    fn cmdKillPane(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const f = try self.resolve(a.get('t'), .pane);
        const pane = f.pane.?;
        if (a.has('a')) {
            const panes = f.window.?.panes;
            for (panes) |*p| {
                if (p.id == pane.id) continue;
                try self.call("killPane", cmd.word, PaneReq{ .pane = p.id });
                try self.forgetPanes(p[0..1]);
            }
            return;
        }
        try self.call("killPane", cmd.word, PaneReq{ .pane = pane.id });
        try self.forgetPanes(pane[0..1]);
    }

    fn cmdKillWindow(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const f = try self.resolve(a.get('t'), .window);
        const window = f.window.?;
        const victims: []const Window = if (a.has('a')) f.session.?.windows else window[0..1];
        for (victims) |*w| {
            if (a.has('a') and w.id == window.id) continue;
            try self.call("killWindow", cmd.word, WindowReq{ .window = w.id });
            try self.forgetPanes(w.panes);
            if (self.store.removeLayout(self.gpa, try self.workspaceKey(w))) self.markDirty();
        }
    }

    fn cmdKillSession(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const f = try self.resolve(a.get('t'), .session);
        const sess = f.session.?;
        const snap = try self.getSnap();
        const victims: []const Session = if (a.has('a')) snap.sessions else sess[0..1];
        for (victims) |*s| {
            if (a.has('a') and s.id == sess.id) continue;
            if (a.has('C')) continue; // -C only clears alerts
            try self.call("killSession", cmd.word, SessionReq{ .session = s.id });
            for (s.windows) |*w| {
                try self.forgetPanes(w.panes);
                if (self.store.removeLayout(self.gpa, try self.workspaceKey(w))) self.markDirty();
            }
        }
    }

    fn cmdListPanes(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const snap = try self.getSnap();
        const filter = a.get('f');
        if (a.has('a')) {
            const fmt = a.get('F') orelse default_formats.list_panes_all;
            for (snap.sessions) |*s| for (s.windows) |*w| for (w.panes) |*p| {
                const f: Found = .{ .session = s, .window = w, .pane = p };
                if (try self.passes(f, filter)) try self.printLine(f, fmt);
            };
            return;
        }
        if (a.has('s')) {
            const t = try self.resolve(a.get('t'), .session);
            const s = t.session.?;
            const fmt = a.get('F') orelse default_formats.list_panes_session;
            for (s.windows) |*w| for (w.panes) |*p| {
                const f: Found = .{ .session = s, .window = w, .pane = p };
                if (try self.passes(f, filter)) try self.printLine(f, fmt);
            };
            return;
        }
        const t = try self.resolve(a.get('t'), .window);
        const fmt = a.get('F') orelse default_formats.list_panes;
        for (t.window.?.panes) |*p| {
            const f: Found = .{ .session = t.session, .window = t.window, .pane = p };
            if (try self.passes(f, filter)) try self.printLine(f, fmt);
        }
    }

    fn cmdListWindows(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const snap = try self.getSnap();
        const filter = a.get('f');
        if (a.has('a')) {
            const fmt = a.get('F') orelse default_formats.list_windows_all;
            for (snap.sessions) |*s| for (s.windows) |*w| {
                const f: Found = .{ .session = s, .window = w, .pane = activePane(w) };
                if (try self.passes(f, filter)) try self.printLine(f, fmt);
            };
            return;
        }
        const t = try self.resolve(a.get('t'), .session);
        const fmt = a.get('F') orelse default_formats.list_windows;
        for (t.session.?.windows) |*w| {
            const f: Found = .{ .session = t.session, .window = w, .pane = activePane(w) };
            if (try self.passes(f, filter)) try self.printLine(f, fmt);
        }
    }

    fn cmdListSessions(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const snap = try self.getSnap();
        const fmt = a.get('F') orelse default_formats.list_sessions;
        for (snap.sessions) |*s| {
            const f = completeSession(s);
            if (try self.passes(f, a.get('f'))) try self.printLine(f, fmt);
        }
    }

    fn cmdDisplayMessage(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        if (a.get('F') != null and a.positionals.len > 0) return self.fail("only one of -F or argument must be given", .{});
        // Without -t and without any session, formats still expand
        // (version, socket_path, pid).
        const f: Found = if (a.get('t') == null and (try self.current()) == null)
            .{}
        else
            try self.resolve(a.get('t'), .pane);
        if (a.has('a')) {
            const ctx: FmtCtx = .{ .engine = self, .found = f };
            for (format_variables) |name| {
                const v = (try FmtCtx.lookup(&ctx, self.arena, name)) orelse continue;
                try self.out.print("{s}={s}\n", .{ name, v });
            }
            return;
        }
        const msg = a.get('F') orelse if (a.positionals.len > 0) a.positionals[0] else default_formats.display;
        const text = if (a.has('l')) msg else try self.expandFound(f, msg);
        if (a.has('p')) {
            try self.out.print("{s}\n", .{text});
            return;
        }
        if (self.exec.vtable.displayMessage == null) {
            try self.out.print("{s}\n", .{text});
            return;
        }
        try self.call("displayMessage", cmd.word, MessageReq{ .pane = if (f.pane) |p| p.id else null, .text = text });
    }

    fn cmdResizePane(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const f = try self.resolve(a.get('t'), .pane);
        var req: ResizeReq = .{ .pane = f.pane.?.id, .zoom = a.has('Z') };
        req.direction = if (a.has('U')) .up else if (a.has('D')) .down else if (a.has('L')) .left else if (a.has('R')) .right else null;
        if (a.positionals.len > 0) {
            req.amount = std.fmt.parseInt(u32, a.positionals[0], 10) catch 0;
            if (req.amount == 0) return self.fail("adjustment invalid: {s}", .{a.positionals[0]});
        }
        if (a.get('x')) |x| req.width = parse.parseSize(x, false) orelse return self.fail("width invalid: {s}", .{x});
        if (a.get('y')) |y| req.height = parse.parseSize(y, false) orelse return self.fail("height invalid: {s}", .{y});
        if (req.direction == null and req.width == null and req.height == null and !req.zoom) return;
        try self.call("resizePane", cmd.word, req);
    }

    fn cmdCapturePane(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const f = try self.resolve(a.get('t'), .pane);
        var req: CaptureReq = .{
            .pane = f.pane.?.id,
            .join = a.has('J'),
            .escapes = a.has('e'),
            .alternate = a.has('a'),
            .keep_trailing = a.has('N'),
        };
        if (a.get('S')) |s| req.start = parse.parseLine(s) orelse return self.fail("start line invalid: {s}", .{s});
        if (a.get('E')) |e| req.end = parse.parseLine(e) orelse return self.fail("end line invalid: {s}", .{e});
        const text = try self.call("capturePane", cmd.word, req);
        if (a.has('p')) {
            try self.out.writeAll(text);
            if (text.len > 0 and text[text.len - 1] != '\n') try self.out.writeByte('\n');
            return;
        }
        try self.store.setBuffer(self.gpa, a.get('b') orelse store_mod.default_buffer, text, false);
        self.markDirty();
    }

    fn cmdSetOption(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        // Accepted and ignored unless the host wants to see options
        // (remain-on-exit for teammate panes, for example).
        if (self.exec.vtable.setOption == null or a.positionals.len == 0) return;
        const scope: OptionScope = if (cmd.id() == .set_window_option or a.has('w'))
            .window
        else if (a.has('p')) .pane else if (a.has('s')) .server else .session;
        try self.call("setOption", cmd.word, OptionReq{
            .target = a.get('t'),
            .name = a.positionals[0],
            .value = if (a.positionals.len > 1) a.positionals[1] else null,
            .scope = scope,
            .global = a.has('g'),
            .unset = a.has('u') or a.has('U'),
            .append = a.has('a'),
        });
    }

    const OptionDef = struct { name: []const u8, value: []const u8, scope: OptionScope };

    /// Fixed answers (cmux: extended-keys on, prefix C-b; passthrough off).
    const option_table = [_]OptionDef{
        .{ .name = "buffer-limit", .value = "50", .scope = .server },
        .{ .name = "default-terminal", .value = "screen-256color", .scope = .server },
        .{ .name = "escape-time", .value = "500", .scope = .server },
        .{ .name = "extended-keys", .value = "on", .scope = .server },
        .{ .name = "focus-events", .value = "off", .scope = .server },
        .{ .name = "set-clipboard", .value = "external", .scope = .server },
        .{ .name = "base-index", .value = "0", .scope = .session },
        .{ .name = "history-limit", .value = "2000", .scope = .session },
        .{ .name = "mouse", .value = "off", .scope = .session },
        .{ .name = "prefix", .value = "C-b", .scope = .session },
        .{ .name = "status", .value = "on", .scope = .session },
        .{ .name = "aggressive-resize", .value = "off", .scope = .window },
        .{ .name = "mode-keys", .value = "emacs", .scope = .window },
        .{ .name = "pane-base-index", .value = "0", .scope = .window },
        .{ .name = "allow-passthrough", .value = "off", .scope = .pane },
        .{ .name = "remain-on-exit", .value = "off", .scope = .pane },
    };

    fn cmdShowOptions(self: *Engine, cmd: parse.Command, forced: ?OptionScope) Error!void {
        const a = cmd.args;
        const values_only = a.has('v');
        if (a.positionals.len > 0) {
            const name = a.positionals[0];
            for (option_table) |o| {
                if (!std.mem.eql(u8, o.name, name)) continue;
                if (values_only) try self.out.print("{s}\n", .{o.value}) else try self.out.print("{s} {s}\n", .{ o.name, o.value });
                return;
            }
            // Unknown or user (@) options: nothing set, success (lenient so
            // probing clients never fail).
            return;
        }
        const scope: OptionScope = forced orelse if (a.has('s')) .server else if (a.has('w')) .window else if (a.has('p')) .pane else .session;
        for (option_table) |o| {
            if (o.scope != scope) continue;
            if (values_only) try self.out.print("{s}\n", .{o.value}) else try self.out.print("{s} {s}\n", .{ o.name, o.value });
        }
    }

    fn cmdSwapPane(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        var src: *const Pane = undefined;
        var dst: *const Pane = undefined;
        if (a.get('s') == null and (a.has('U') or a.has('D'))) {
            // -U/-D without -s: the target and its previous/next pane.
            const base = try self.resolve(a.get('t'), .pane);
            src = base.pane.?;
            dst = neighbor(base.window.?, src, a.has('D'));
        } else {
            // tmux's source defaults to the marked pane, else the current
            // pane; the shim has no marked pane.
            src = (try self.resolve(a.get('s'), .pane)).pane.?;
            dst = (try self.resolve(a.get('t'), .pane)).pane.?;
        }
        if (src.id == dst.id) return;
        try self.call("swapPane", cmd.word, SwapReq{ .src = src.id, .dst = dst.id, .focus = !a.has('d') });
    }

    fn cmdJoinPane(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        // As for swap-pane, -s defaults to the current pane.
        const src = (try self.resolve(a.get('s'), .pane)).pane.?;
        const dst = (try self.resolve(a.get('t'), .pane)).pane.?;
        if (src.id == dst.id) return self.fail("source and target panes must be different", .{});
        const direction: Direction = if (a.has('h'))
            (if (a.has('b')) .left else .right)
        else
            (if (a.has('b')) .up else .down);
        const size = try self.sizeArg(a);
        try self.call("joinPane", cmd.word, JoinReq{ .src = src.id, .dst = dst.id, .direction = direction, .size = size, .detached = a.has('d') });
    }

    fn containsText(hay: []const u8, needle: []const u8, ignore_case: bool) bool {
        if (ignore_case) return std.ascii.indexOfIgnoreCase(hay, needle) != null;
        return std.mem.indexOf(u8, hay, needle) != null;
    }

    fn cmdFindWindow(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const needle = a.positionals[0];
        const any_field = a.has('C') or a.has('N') or a.has('T');
        const by_name = !any_field or a.has('N');
        const by_title = !any_field or a.has('T');
        const by_content = (!any_field or a.has('C')) and self.exec.vtable.capturePane != null;
        const ic = a.has('i');
        // tmux: -t is a target pane; the search starts in its session.
        const start = try self.resolve(a.get('t'), .pane);
        const snap = try self.getSnap();
        // The target's session first, then the others in order.
        var order: std.ArrayList(*const Session) = .empty;
        try order.append(self.arena, start.session.?);
        for (snap.sessions) |*s| {
            if (s != start.session.?) try order.append(self.arena, s);
        }
        for (order.items) |s| for (s.windows) |*w| {
            var hit = by_name and containsText(w.name, needle, ic);
            if (!hit and by_title) {
                for (w.panes) |*p| {
                    if (containsText(p.title, needle, ic)) hit = true;
                }
            }
            if (!hit and by_content) {
                for (w.panes) |*p| {
                    const text = try self.call("capturePane", cmd.word, CaptureReq{ .pane = p.id });
                    if (containsText(text, needle, ic)) {
                        hit = true;
                        break;
                    }
                }
            }
            if (hit) return self.call("selectWindow", cmd.word, WindowReq{ .window = w.id });
        };
        return self.fail("no windows matching: {s}", .{needle});
    }

    fn cmdSetBuffer(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const name = a.get('b') orelse store_mod.default_buffer;
        if (a.get('n')) |new_name| {
            if (!try self.store.renameBuffer(self.gpa, name, new_name)) return self.fail("no buffer {s}", .{name});
            self.markDirty();
            if (a.positionals.len == 0) return;
            try self.store.setBuffer(self.gpa, new_name, a.positionals[0], a.has('a'));
            return;
        }
        if (a.positionals.len == 0) return self.fail("no data specified", .{});
        try self.store.setBuffer(self.gpa, name, a.positionals[0], a.has('a'));
        self.markDirty();
    }

    fn cmdListBuffers(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const fmt = a.get('F') orelse default_formats.list_buffers;
        const names = self.store.buffers.keys();
        const datas = self.store.buffers.values();
        // Most recent first, as tmux lists them.
        var i = names.len;
        while (i > 0) {
            i -= 1;
            const ctx: FmtCtx = .{ .engine = self, .buffer_name = names[i], .buffer_data = datas[i] };
            if (a.get('f')) |flt| {
                if (!format.truthy(try self.expandWith(&ctx, flt))) continue;
            }
            try self.out.print("{s}\n", .{try self.expandWith(&ctx, fmt)});
        }
    }

    fn cmdPasteBuffer(self: *Engine, cmd: parse.Command) Error!void {
        const a = cmd.args;
        const f = try self.resolve(a.get('t'), .pane);
        const name = a.get('b') orelse store_mod.default_buffer;
        const data = self.store.getBuffer(name) orelse return self.fail("no buffer {s}", .{name});
        var text: std.ArrayList(u8) = .empty;
        if (a.has('p')) try text.appendSlice(self.arena, "\x1b[200~");
        if (a.has('r')) {
            try text.appendSlice(self.arena, data);
        } else {
            const sep = a.get('s') orelse "\r";
            var it = std.mem.splitScalar(u8, data, '\n');
            var first = true;
            while (it.next()) |part| {
                if (!first) try text.appendSlice(self.arena, sep);
                first = false;
                try text.appendSlice(self.arena, part);
            }
        }
        if (a.has('p')) try text.appendSlice(self.arena, "\x1b[201~");
        if (data.len > 0) {
            const items = try self.arena.dupe(SendItem, &.{.{ .bytes = text.items, .key = false }});
            try self.call("sendKeys", cmd.word, SendReq{ .pane = f.pane.?.id, .items = items });
        }
        if (a.has('d')) {
            _ = self.store.deleteBuffer(self.gpa, name);
            self.markDirty();
        }
    }

    fn cmdSetHook(self: *Engine, cmd: parse.Command, depth: usize) Error!void {
        const a = cmd.args;
        const name = a.positionals[0];
        if (a.has('u')) {
            if (self.store.removeHook(self.gpa, name)) self.markDirty();
            return;
        }
        if (a.has('R')) {
            const hook = self.store.getHook(name) orelse return;
            return self.runHook(try self.arena.dupe(u8, hook), depth + 1);
        }
        if (a.positionals.len < 2) return self.fail("usage: {s} {s}", .{ cmd.spec.name, cmd.spec.usage });
        try self.store.setHook(self.gpa, name, a.positionals[1]);
        self.markDirty();
    }

    fn cmdIfShell(self: *Engine, cmd: parse.Command, depth: usize) Error!void {
        const a = cmd.args;
        const cond_src = a.positionals[0];
        var ok: bool = undefined;
        if (a.has('F')) {
            const f: Found = if (a.get('t') == null and (try self.current()) == null) .{} else try self.resolve(a.get('t'), .pane);
            ok = format.truthy(try self.expandFound(f, cond_src));
        } else {
            const cwd: ?[]const u8 = blk: {
                const f = (try self.current()) orelse break :blk null;
                const p = f.pane orelse break :blk null;
                break :blk if (p.current_path.len > 0) p.current_path else null;
            };
            ok = (try self.call("runShell", cmd.word, ShellReq{ .command = cond_src, .cwd = cwd })) == 0;
        }
        const branch: ?[]const u8 = if (ok) a.positionals[1] else if (a.positionals.len > 2) a.positionals[2] else null;
        if (branch) |b| try self.runString(b, depth + 1);
    }
};

/// `#{buffer_sample}`: the first 50 bytes (UTF-8 safe) with control
/// characters escaped.
fn bufferSample(arena: Allocator, data: []const u8) Allocator.Error![]const u8 {
    const head = store_mod.truncateUtf8(data, 50);
    var out: std.ArrayList(u8) = .empty;
    for (head) |c| switch (c) {
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '"' => try out.appendSlice(arena, "\\\""),
        0...8, 11, 12, 14...31, 127 => try out.print(arena, "\\{o:0>3}", .{c}),
        else => try out.append(arena, c),
    };
    if (head.len < data.len) try out.appendSlice(arena, "...");
    return out.items;
}
