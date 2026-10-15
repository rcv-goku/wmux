//! tmux command-line grammar for the tmux-compat shim (ADR-10.8, W3-6):
//! global flags before the verb (`-L -S -f -V -v`), a lone whitespace-bearing
//! argument split shell-style, command chaining with `;` / `\;`, verb aliases
//! and unique prefixes, getopt-style per-command flags and the target grammar
//! (`session:window.pane`, `%N`, `@N`, `$N` and wmux handles).
//!
//! Everything here is pure: callers pass an arena and receive slices that
//! borrow from it (and from the input argv).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What `-V` / `-v` print (cmux answers with this version).
pub const version_line = "tmux 3.4";
/// Printed for every verb outside the supported table.
pub const unsupported_prefix = "Unsupported tmux compatibility command: ";

pub const Error = error{ OutOfMemory, Syntax, Usage, UnknownCommand };

/// Human-readable message for the last parse failure (arena-owned).
pub const Diag = struct {
    message: []const u8 = "",

    fn set(self: *Diag, arena: Allocator, comptime fmt: []const u8, args: anytype) Error {
        self.message = std.fmt.allocPrint(arena, fmt, args) catch return error.OutOfMemory;
        return error.Usage;
    }
};

// ---------------------------------------------------------------------------
// Command table
// ---------------------------------------------------------------------------

pub const CommandId = enum {
    new_session,
    new_window,
    split_window,
    send_keys,
    select_pane,
    select_window,
    switch_client,
    select_layout,
    kill_pane,
    kill_window,
    kill_session,
    respawn_pane,
    list_panes,
    list_windows,
    list_sessions,
    display_message,
    has_session,
    resize_pane,
    capture_pane,
    set_option,
    set_window_option,
    show_options,
    show_window_options,
    wait_for,
    rename_window,
    rename_session,
    last_pane,
    last_window,
    next_window,
    previous_window,
    swap_pane,
    break_pane,
    join_pane,
    pipe_pane,
    clear_history,
    find_window,
    set_buffer,
    show_buffer,
    save_buffer,
    load_buffer,
    list_buffers,
    paste_buffer,
    delete_buffer,
    set_hook,
    show_hooks,
    if_shell,
    attach_session,
    detach_client,
    source_file,
    refresh_client,
    start_server,
    bind_key,
    unbind_key,
    copy_mode,
    display_popup,
};

pub const CommandSpec = struct {
    id: CommandId,
    name: []const u8,
    aliases: []const []const u8 = &.{},
    /// getopt string (`x:` takes a value). null = lenient: no flag parsing,
    /// every argument is kept as a positional and nothing is validated.
    flags: ?[]const u8,
    min_args: usize = 0,
    max_args: ?usize = 0,
    usage: []const u8 = "",
};

const unbounded: ?usize = null;

/// The supported verb table. Flag sets follow tmux 3.4 so that anything a
/// tmux client may pass parses; unused flags are accepted and ignored.
pub const commands = [_]CommandSpec{
    .{ .id = .new_session, .name = "new-session", .aliases = &.{"new"}, .flags = "Ac:dDe:EF:f:n:Ps:t:x:Xy:", .max_args = unbounded, .usage = "[-AdDEPX] [-c start-directory] [-e environment] [-F format] [-f flags] [-n window-name] [-s session-name] [-t target-session] [-x width] [-y height] [shell-command [argument ...]]" },
    .{ .id = .new_window, .name = "new-window", .aliases = &.{"neww"}, .flags = "abc:de:F:kn:PSt:", .max_args = unbounded, .usage = "[-abdkPS] [-c start-directory] [-e environment] [-F format] [-n window-name] [-t target-window] [shell-command [argument ...]]" },
    .{ .id = .split_window, .name = "split-window", .aliases = &.{"splitw"}, .flags = "bc:de:fF:hIl:p:Pt:vZ", .max_args = unbounded, .usage = "[-bdefhIPvZ] [-c start-directory] [-e environment] [-F format] [-l size] [-t target-pane] [shell-command [argument ...]]" },
    .{ .id = .send_keys, .name = "send-keys", .aliases = &.{"send"}, .flags = "c:FHKlMN:Rt:X", .max_args = unbounded, .usage = "[-FHKlMRX] [-c target-client] [-N repeat-count] [-t target-pane] [key ...]" },
    .{ .id = .select_pane, .name = "select-pane", .aliases = &.{"selectp"}, .flags = "DdeLlMmP:RT:t:UZ", .usage = "[-DdeLlMmRUZ] [-T title] [-t target-pane]" },
    .{ .id = .select_window, .name = "select-window", .aliases = &.{"selectw"}, .flags = "lnpTt:", .usage = "[-lnpT] [-t target-window]" },
    .{ .id = .switch_client, .name = "switch-client", .aliases = &.{"switchc"}, .flags = "c:EFlnO:pt:rT:Z", .usage = "[-ElnprZ] [-c target-client] [-t target-session] [-T key-table]" },
    .{ .id = .select_layout, .name = "select-layout", .aliases = &.{"selectl"}, .flags = "Enopt:", .max_args = 1, .usage = "[-Enop] [-t target-pane] [layout-name]" },
    .{ .id = .kill_pane, .name = "kill-pane", .aliases = &.{"killp"}, .flags = "at:", .usage = "[-a] [-t target-pane]" },
    .{ .id = .kill_window, .name = "kill-window", .aliases = &.{"killw"}, .flags = "at:", .usage = "[-a] [-t target-window]" },
    .{ .id = .kill_session, .name = "kill-session", .flags = "aCt:", .usage = "[-aC] [-t target-session]" },
    .{ .id = .respawn_pane, .name = "respawn-pane", .aliases = &.{"respawnp"}, .flags = "c:e:kt:", .max_args = unbounded, .usage = "[-k] [-c start-directory] [-e environment] [-t target-pane] [shell-command [argument ...]]" },
    .{ .id = .list_panes, .name = "list-panes", .aliases = &.{"lsp"}, .flags = "aF:f:st:", .usage = "[-as] [-F format] [-f filter] [-t target-window]" },
    .{ .id = .list_windows, .name = "list-windows", .aliases = &.{"lsw"}, .flags = "aF:f:t:", .usage = "[-a] [-F format] [-f filter] [-t target-session]" },
    .{ .id = .list_sessions, .name = "list-sessions", .aliases = &.{"ls"}, .flags = "F:f:", .usage = "[-F format] [-f filter]" },
    .{ .id = .display_message, .name = "display-message", .aliases = &.{ "display", "displayp" }, .flags = "aCc:d:lINpt:F:v", .max_args = 1, .usage = "[-aCIlNpv] [-c target-client] [-d delay] [-F format] [-t target-pane] [message]" },
    .{ .id = .has_session, .name = "has-session", .aliases = &.{"has"}, .flags = "t:", .usage = "[-t target-session]" },
    .{ .id = .resize_pane, .name = "resize-pane", .aliases = &.{"resizep"}, .flags = "DLMRTt:Ux:y:Z", .max_args = 1, .usage = "[-DLMRTUZ] [-x width] [-y height] [-t target-pane] [adjustment]" },
    .{ .id = .capture_pane, .name = "capture-pane", .aliases = &.{"capturep"}, .flags = "ab:CeE:JNpPqS:Tt:", .usage = "[-aCeJNpPqT] [-b buffer-name] [-E end-line] [-S start-line] [-t target-pane]" },
    .{ .id = .set_option, .name = "set-option", .aliases = &.{"set"}, .flags = "aFgopqst:uUw", .max_args = unbounded, .usage = "[-aFgopqsuUw] [-t target-pane] option [value]" },
    .{ .id = .set_window_option, .name = "set-window-option", .aliases = &.{"setw"}, .flags = "aFgoqt:u", .max_args = unbounded, .usage = "[-aFgoqu] [-t target-window] option [value]" },
    .{ .id = .show_options, .name = "show-options", .aliases = &.{ "show", "show-option" }, .flags = "AgHpqst:vw", .max_args = 1, .usage = "[-AgHpqsvw] [-t target-pane] [option]" },
    .{ .id = .show_window_options, .name = "show-window-options", .aliases = &.{"showw"}, .flags = "gvt:", .max_args = 1, .usage = "[-gv] [-t target-window] [option]" },
    .{ .id = .wait_for, .name = "wait-for", .aliases = &.{"wait"}, .flags = "LSU", .min_args = 1, .max_args = 1, .usage = "[-L|-S|-U] channel" },
    .{ .id = .rename_window, .name = "rename-window", .aliases = &.{"renamew"}, .flags = "t:", .min_args = 1, .max_args = 1, .usage = "[-t target-window] new-name" },
    .{ .id = .rename_session, .name = "rename-session", .aliases = &.{"rename"}, .flags = "t:", .min_args = 1, .max_args = 1, .usage = "[-t target-session] new-name" },
    .{ .id = .last_pane, .name = "last-pane", .aliases = &.{"lastp"}, .flags = "det:Z", .usage = "[-deZ] [-t target-window]" },
    .{ .id = .last_window, .name = "last-window", .aliases = &.{"last"}, .flags = "t:", .usage = "[-t target-session]" },
    .{ .id = .next_window, .name = "next-window", .aliases = &.{"next"}, .flags = "at:", .usage = "[-a] [-t target-session]" },
    .{ .id = .previous_window, .name = "previous-window", .aliases = &.{"prev"}, .flags = "at:", .usage = "[-a] [-t target-session]" },
    .{ .id = .swap_pane, .name = "swap-pane", .aliases = &.{"swapp"}, .flags = "dDs:t:UZ", .usage = "[-dDUZ] [-s src-pane] [-t dst-pane]" },
    .{ .id = .break_pane, .name = "break-pane", .aliases = &.{"breakp"}, .flags = "abdPF:n:s:t:", .usage = "[-abdP] [-F format] [-n window-name] [-s src-pane] [-t dst-window]" },
    .{ .id = .join_pane, .name = "join-pane", .aliases = &.{ "joinp", "move-pane", "movep" }, .flags = "bdfhvp:l:s:t:", .usage = "[-bdfhv] [-l size] [-s src-pane] [-t dst-pane]" },
    .{ .id = .pipe_pane, .name = "pipe-pane", .aliases = &.{"pipep"}, .flags = "IOot:", .max_args = 1, .usage = "[-IOo] [-t target-pane] [shell-command]" },
    .{ .id = .clear_history, .name = "clear-history", .aliases = &.{"clearhist"}, .flags = "Ht:", .usage = "[-H] [-t target-pane]" },
    .{ .id = .find_window, .name = "find-window", .aliases = &.{"findw"}, .flags = "CiNrt:TZ", .min_args = 1, .max_args = 1, .usage = "[-CiNrTZ] [-t target-pane] match-string" },
    .{ .id = .set_buffer, .name = "set-buffer", .aliases = &.{"setb"}, .flags = "ab:t:n:w", .max_args = 1, .usage = "[-aw] [-b buffer-name] [-n new-buffer-name] [-t target-client] [data]" },
    .{ .id = .show_buffer, .name = "show-buffer", .aliases = &.{"showb"}, .flags = "b:", .usage = "[-b buffer-name]" },
    .{ .id = .save_buffer, .name = "save-buffer", .aliases = &.{"saveb"}, .flags = "ab:", .min_args = 1, .max_args = 1, .usage = "[-a] [-b buffer-name] path" },
    .{ .id = .load_buffer, .name = "load-buffer", .aliases = &.{"loadb"}, .flags = "b:t:w", .min_args = 1, .max_args = 1, .usage = "[-w] [-b buffer-name] [-t target-client] path" },
    .{ .id = .list_buffers, .name = "list-buffers", .aliases = &.{"lsb"}, .flags = "F:f:", .usage = "[-F format] [-f filter]" },
    .{ .id = .paste_buffer, .name = "paste-buffer", .aliases = &.{"pasteb"}, .flags = "db:prSs:t:", .usage = "[-dprS] [-s separator] [-b buffer-name] [-t target-pane]" },
    .{ .id = .delete_buffer, .name = "delete-buffer", .aliases = &.{"deleteb"}, .flags = "b:", .usage = "[-b buffer-name]" },
    .{ .id = .set_hook, .name = "set-hook", .flags = "agpRt:uw", .min_args = 1, .max_args = 2, .usage = "[-agpRuw] [-t target-pane] hook [command]" },
    .{ .id = .show_hooks, .name = "show-hooks", .flags = "gpt:w", .max_args = 1, .usage = "[-gpw] [-t target-pane] [hook]" },
    .{ .id = .if_shell, .name = "if-shell", .aliases = &.{"if"}, .flags = "bFt:", .min_args = 2, .max_args = 3, .usage = "[-bF] [-t target-pane] shell-command command [command]" },
    .{ .id = .attach_session, .name = "attach-session", .aliases = &.{ "attach", "a" }, .flags = null },
    .{ .id = .detach_client, .name = "detach-client", .aliases = &.{"detach"}, .flags = null },
    .{ .id = .source_file, .name = "source-file", .aliases = &.{"source"}, .flags = null },
    .{ .id = .refresh_client, .name = "refresh-client", .aliases = &.{"refresh"}, .flags = null },
    .{ .id = .start_server, .name = "start-server", .aliases = &.{"start"}, .flags = null },
    .{ .id = .bind_key, .name = "bind-key", .aliases = &.{"bind"}, .flags = null },
    .{ .id = .unbind_key, .name = "unbind-key", .aliases = &.{"unbind"}, .flags = null },
    .{ .id = .copy_mode, .name = "copy-mode", .flags = null },
    .{ .id = .display_popup, .name = "display-popup", .aliases = &.{"popup"}, .flags = null },
};

comptime {
    // Every id appears exactly once, and no name or alias is claimed twice.
    @setEvalBranchQuota(1_000_000);
    for (std.meta.tags(CommandId)) |id| {
        var count: usize = 0;
        for (commands) |c| {
            if (c.id == id) count += 1;
        }
        if (count != 1) @compileError("tmux command table: id listed " ++ std.fmt.comptimePrint("{d}", .{count}) ++ " times: " ++ @tagName(id));
    }
    for (commands, 0..) |a, i| {
        for (commands[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) @compileError("tmux command table: duplicate name " ++ a.name);
            for (b.aliases) |al| {
                if (std.mem.eql(u8, a.name, al)) @compileError("tmux command table: duplicate alias " ++ al);
            }
            for (a.aliases) |al| {
                if (std.mem.eql(u8, b.name, al)) @compileError("tmux command table: duplicate alias " ++ al);
                for (b.aliases) |bl| {
                    if (std.mem.eql(u8, al, bl)) @compileError("tmux command table: duplicate alias " ++ al);
                }
            }
        }
    }
}

pub fn spec(id: CommandId) *const CommandSpec {
    for (&commands) |*c| {
        if (c.id == id) return c;
    }
    unreachable;
}

pub const Lookup = union(enum) {
    found: *const CommandSpec,
    ambiguous: []const *const CommandSpec,
    unknown,
};

/// Exact name or alias first (ASCII case-insensitive), then a unique prefix
/// of a canonical name, as tmux does.
pub fn lookupCommand(arena: Allocator, word: []const u8) Allocator.Error!Lookup {
    if (word.len == 0) return .unknown;
    for (&commands) |*c| {
        if (std.ascii.eqlIgnoreCase(c.name, word)) return .{ .found = c };
        for (c.aliases) |al| {
            if (std.ascii.eqlIgnoreCase(al, word)) return .{ .found = c };
        }
    }
    var hits: std.ArrayList(*const CommandSpec) = .empty;
    for (&commands) |*c| {
        if (word.len < c.name.len and std.ascii.startsWithIgnoreCase(c.name, word)) try hits.append(arena, c);
    }
    return switch (hits.items.len) {
        0 => .unknown,
        1 => .{ .found = hits.items[0] },
        else => .{ .ambiguous = hits.items },
    };
}

// ---------------------------------------------------------------------------
// Parsed argument model
// ---------------------------------------------------------------------------

pub const Flag = struct { c: u8, value: ?[]const u8 };

pub const Args = struct {
    flags: []const Flag = &.{},
    positionals: []const []const u8 = &.{},

    pub fn has(self: Args, c: u8) bool {
        for (self.flags) |f| {
            if (f.c == c) return true;
        }
        return false;
    }

    /// Last value given for `-c` (tmux semantics: later flags win).
    pub fn get(self: Args, c: u8) ?[]const u8 {
        var out: ?[]const u8 = null;
        for (self.flags) |f| {
            if (f.c == c) out = f.value;
        }
        return out;
    }

    /// Every value of a repeatable flag such as `-e`, in order.
    pub fn getAll(self: Args, arena: Allocator, c: u8) Allocator.Error![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (self.flags) |f| {
            if (f.c == c) {
                if (f.value) |v| try list.append(arena, v);
            }
        }
        return list.items;
    }
};

pub const Command = struct {
    spec: *const CommandSpec,
    /// The verb as typed (used in messages).
    word: []const u8,
    args: Args,

    pub fn id(self: Command) CommandId {
        return self.spec.id;
    }
};

pub const Globals = struct {
    socket_name: ?[]const u8 = null, // -L
    socket_path: ?[]const u8 = null, // -S
    config_file: ?[]const u8 = null, // -f
    version: bool = false, // -V / -v
};

pub const Invocation = struct {
    globals: Globals = .{},
    commands: []const Command = &.{},
};

// ---------------------------------------------------------------------------
// Shell-style splitting and chaining
// ---------------------------------------------------------------------------

/// Splits a command string the way a POSIX shell would split words, with
/// tmux's separator rule: an unquoted `;` (alone, at the end of a word, or
/// escaped as `\;`) ends a command. Returns one argv per command; empty
/// commands are dropped. `#` is never a comment (`#{pane_id}` is common).
pub fn splitCommandString(arena: Allocator, s: []const u8, diag: *Diag) Error![]const []const []const u8 {
    var groups: std.ArrayList([]const []const u8) = .empty;
    var argv: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;

    const State = enum { plain, single, double };
    var state: State = .plain;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        switch (state) {
            .single => {
                if (ch == '\'') state = .plain else try word.append(arena, ch);
            },
            .double => switch (ch) {
                '"' => state = .plain,
                '\\' => {
                    if (i + 1 < s.len and std.mem.indexOfScalar(u8, "\"\\$`\n", s[i + 1]) != null) {
                        i += 1;
                        if (s[i] != '\n') try word.append(arena, s[i]);
                    } else try word.append(arena, ch);
                },
                else => try word.append(arena, ch),
            },
            .plain => switch (ch) {
                ' ', '\t', '\n', '\r' => {
                    if (in_word) {
                        try argv.append(arena, try word.toOwnedSlice(arena));
                        in_word = false;
                    }
                },
                '\'' => {
                    state = .single;
                    in_word = true;
                },
                '"' => {
                    state = .double;
                    in_word = true;
                },
                ';' => {
                    if (in_word) {
                        try argv.append(arena, try word.toOwnedSlice(arena));
                        in_word = false;
                    }
                    try endGroup(arena, &groups, &argv);
                },
                '\\' => {
                    if (i + 1 < s.len) {
                        i += 1;
                        if (s[i] == ';') {
                            if (in_word) {
                                try argv.append(arena, try word.toOwnedSlice(arena));
                                in_word = false;
                            }
                            try endGroup(arena, &groups, &argv);
                        } else if (s[i] != '\n') {
                            try word.append(arena, s[i]);
                            in_word = true;
                        }
                    } else {
                        try word.append(arena, ch);
                        in_word = true;
                    }
                },
                else => {
                    try word.append(arena, ch);
                    in_word = true;
                },
            },
        }
    }
    if (state != .plain) {
        diag.message = "syntax error: unterminated quote";
        return error.Syntax;
    }
    if (in_word) try argv.append(arena, try word.toOwnedSlice(arena));
    try endGroup(arena, &groups, &argv);
    return groups.items;
}

fn endGroup(arena: Allocator, groups: *std.ArrayList([]const []const u8), argv: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (argv.items.len == 0) return;
    try groups.append(arena, try argv.toOwnedSlice(arena));
}

/// Splits an argv into commands at separator arguments: `;` or `\;` alone,
/// or a trailing unescaped `;` on a word. A trailing `\;` keeps a literal
/// `;` (tmux's escape for nested command sequences).
pub fn splitArgvChain(arena: Allocator, argv: []const []const u8) Allocator.Error![]const []const []const u8 {
    var groups: std.ArrayList([]const []const u8) = .empty;
    var cur: std.ArrayList([]const u8) = .empty;
    for (argv) |a| {
        if (std.mem.eql(u8, a, ";") or std.mem.eql(u8, a, "\\;")) {
            try endGroup(arena, &groups, &cur);
        } else if (a.len >= 3 and std.mem.endsWith(u8, a, "\\;")) {
            try cur.append(arena, try std.mem.concat(arena, u8, &.{ a[0 .. a.len - 2], ";" }));
        } else if (a.len >= 2 and a[a.len - 1] == ';') {
            try cur.append(arena, a[0 .. a.len - 1]);
            try endGroup(arena, &groups, &cur);
        } else {
            try cur.append(arena, a);
        }
    }
    try endGroup(arena, &groups, &cur);
    return groups.items;
}

// ---------------------------------------------------------------------------
// Invocation parsing
// ---------------------------------------------------------------------------

/// Parses the shim's argv (without argv[0]).
pub fn parseInvocation(arena: Allocator, argv: []const []const u8, diag: *Diag) Error!Invocation {
    var inv: Invocation = .{};
    var i: usize = 0;
    globals: while (i < argv.len) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') break;
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            switch (c) {
                'V', 'v' => inv.globals.version = true,
                // Accepted and ignored (UTF-8, 256 colours, login shell,
                // no-start, control mode is not offered but harmless here).
                '2', 'u', 'l', 'N', 'D', 'q' => {},
                'L', 'S', 'f', 'T' => {
                    var value: []const u8 = undefined;
                    if (j + 1 < a.len) {
                        value = a[j + 1 ..];
                    } else if (i + 1 < argv.len) {
                        i += 1;
                        value = argv[i];
                    } else {
                        return diag.set(arena, "tmux: option requires an argument -- {c}", .{c});
                    }
                    switch (c) {
                        'L' => inv.globals.socket_name = value,
                        'S' => inv.globals.socket_path = value,
                        'f' => inv.globals.config_file = value,
                        else => {},
                    }
                    i += 1;
                    continue :globals;
                },
                else => return diag.set(arena, "tmux: unknown option -- {c}", .{c}),
            }
        }
        i += 1;
    }
    if (inv.globals.version) return inv;

    const rest = argv[i..];
    const groups: []const []const []const u8 = if (rest.len == 1 and hasWhitespace(rest[0]))
        try splitCommandString(arena, rest[0], diag)
    else
        try splitArgvChain(arena, rest);

    if (groups.len == 0) {
        // Plain `tmux` means new-session.
        const cmd = try parseCommand(arena, &.{"new-session"}, diag);
        inv.commands = try arena.dupe(Command, &.{cmd});
        return inv;
    }
    var cmds: std.ArrayList(Command) = .empty;
    for (groups) |g| try cmds.append(arena, try parseCommand(arena, g, diag));
    inv.commands = cmds.items;
    return inv;
}

/// Parses a command sequence from a single string (if-shell branches, hooks).
pub fn parseCommandString(arena: Allocator, s: []const u8, diag: *Diag) Error![]const Command {
    const groups = try splitCommandString(arena, s, diag);
    var cmds: std.ArrayList(Command) = .empty;
    for (groups) |g| try cmds.append(arena, try parseCommand(arena, g, diag));
    return cmds.items;
}

fn hasWhitespace(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, " \t\r\n") != null;
}

/// Parses one command: verb lookup, then getopt over the remaining words.
/// Flag parsing stops at `--` or the first non-flag word (tmux uses `+`
/// getopt semantics, so a shell command after the flags keeps its own).
pub fn parseCommand(arena: Allocator, argv: []const []const u8, diag: *Diag) Error!Command {
    std.debug.assert(argv.len > 0);
    const word = argv[0];
    const s = switch (try lookupCommand(arena, word)) {
        .found => |c| c,
        .ambiguous => |list| {
            var names: std.ArrayList(u8) = .empty;
            for (list, 0..) |c, n| {
                if (n > 0) try names.appendSlice(arena, ", ");
                try names.appendSlice(arena, c.name);
            }
            diag.message = try std.fmt.allocPrint(arena, "ambiguous command: {s}, could be: {s}", .{ word, names.items });
            return error.UnknownCommand;
        },
        .unknown => {
            diag.message = try std.fmt.allocPrint(arena, unsupported_prefix ++ "{s}", .{word});
            return error.UnknownCommand;
        },
    };
    const words = argv[1..];
    const optstring = s.flags orelse return .{ .spec = s, .word = word, .args = .{ .positionals = words } };

    var flags: std.ArrayList(Flag) = .empty;
    var i: usize = 0;
    outer: while (i < words.len) {
        const a = words[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') break;
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            const at = if (c == ':') null else std.mem.indexOfScalar(u8, optstring, c);
            const pos = at orelse return usageError(arena, diag, s, "unknown flag -{c}", .{c});
            const takes = pos + 1 < optstring.len and optstring[pos + 1] == ':';
            if (!takes) {
                try flags.append(arena, .{ .c = c, .value = null });
                continue;
            }
            if (j + 1 < a.len) {
                try flags.append(arena, .{ .c = c, .value = a[j + 1 ..] });
            } else if (i + 1 < words.len) {
                i += 1;
                try flags.append(arena, .{ .c = c, .value = words[i] });
            } else {
                return usageError(arena, diag, s, "-{c} expects an argument", .{c});
            }
            i += 1;
            continue :outer;
        }
        i += 1;
    }
    const positionals = words[i..];
    if (positionals.len < s.min_args or (s.max_args != null and positionals.len > s.max_args.?)) {
        diag.message = try std.fmt.allocPrint(arena, "usage: {s} {s}", .{ s.name, s.usage });
        return error.Usage;
    }
    return .{ .spec = s, .word = word, .args = .{ .flags = flags.items, .positionals = positionals } };
}

fn usageError(arena: Allocator, diag: *Diag, s: *const CommandSpec, comptime fmt: []const u8, args: anytype) Error {
    const what = try std.fmt.allocPrint(arena, fmt, args);
    diag.message = try std.fmt.allocPrint(arena, "command {s}: {s}\nusage: {s} {s}", .{ s.name, what, s.name, s.usage });
    return error.Usage;
}

// ---------------------------------------------------------------------------
// Targets
// ---------------------------------------------------------------------------

/// A parsed `-t`/`-s` value. tmux forms: `%N` pane id, `@N` window id, `$N`
/// session id, `session:window.pane` (each part optional), `=name` exact
/// match. wmux handles: `surface:N`/`tab:N` (same number as `%N`),
/// `workspace:N` (same number as `@N`), `pane:N` and UUIDs.
pub const Target = union(enum) {
    /// `-t ''`: the current target.
    current,
    pane_id: u32,
    window_id: u32,
    session_id: u32,
    wmux_pane: u32,
    uuid: []const u8,
    /// Neither `:` nor `.`: a pane id, window or session depending on use.
    bare: []const u8,
    path: Path,

    pub const Path = struct {
        session: ?[]const u8 = null,
        window: ?[]const u8 = null,
        pane: ?[]const u8 = null,
    };
};

pub fn parseTarget(s: []const u8) Target {
    if (s.len == 0) return .current;
    if (handleNumber(s, "surface:") orelse handleNumber(s, "tab:")) |n| return .{ .pane_id = n };
    if (handleNumber(s, "workspace:")) |n| return .{ .window_id = n };
    if (handleNumber(s, "pane:")) |n| return .{ .wmux_pane = n };
    if (isUuid(s)) return .{ .uuid = trimBraces(s) };
    if (s[0] == '%' or s[0] == '@' or s[0] == '$') {
        if (std.mem.indexOfAny(u8, s, ":.") == null) {
            if (std.fmt.parseInt(u32, s[1..], 10)) |n| {
                return switch (s[0]) {
                    '%' => .{ .pane_id = n },
                    '@' => .{ .window_id = n },
                    else => .{ .session_id = n },
                };
            } else |_| {}
        }
    }
    const colon = std.mem.indexOfScalar(u8, s, ':');
    if (colon) |c| {
        const sess = s[0..c];
        const rest = s[c + 1 ..];
        var p: Target.Path = .{ .session = if (sess.len > 0) sess else null };
        splitWindowPane(rest, &p);
        return .{ .path = p };
    }
    // `%N` panes have no dot; a dot means window.pane in the current session.
    if (std.mem.indexOfScalar(u8, s, '.') != null and s[0] != '%') {
        var p: Target.Path = .{};
        splitWindowPane(s, &p);
        return .{ .path = p };
    }
    return .{ .bare = s };
}

fn splitWindowPane(rest: []const u8, p: *Target.Path) void {
    if (std.mem.lastIndexOfScalar(u8, rest, '.')) |d| {
        if (d > 0) p.window = rest[0..d];
        if (d + 1 < rest.len) p.pane = rest[d + 1 ..];
    } else if (rest.len > 0) {
        p.window = rest;
    }
}

fn handleNumber(s: []const u8, prefix: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    const digits = s[prefix.len..];
    if (digits.len == 0) return null;
    for (digits) |d| if (!std.ascii.isDigit(d)) return null;
    const n = std.fmt.parseInt(u32, digits, 10) catch return null;
    return if (n == 0) null else n;
}

fn trimBraces(s: []const u8) []const u8 {
    if (s.len == 38 and s[0] == '{' and s[37] == '}') return s[1..37];
    return s;
}

/// 8-4-4-4-12 hex, any case, optional braces.
pub fn isUuid(s0: []const u8) bool {
    const s = trimBraces(s0);
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Sizes and line numbers
// ---------------------------------------------------------------------------

pub const Size = union(enum) {
    cells: u32,
    percent: u8,
};

/// `-l 30` (cells) or `-l 70%`; `-p 70` passes `percent_only`.
pub fn parseSize(s: []const u8, percent_only: bool) ?Size {
    if (s.len == 0) return null;
    if (percent_only or s[s.len - 1] == '%') {
        const digits = if (s[s.len - 1] == '%') s[0 .. s.len - 1] else s;
        const n = std.fmt.parseInt(u8, digits, 10) catch return null;
        if (n == 0 or n > 100) return null;
        return .{ .percent = n };
    }
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    if (n == 0) return null;
    return .{ .cells = n };
}

/// capture-pane `-S`/`-E`: a signed line number or `-` (history start/end).
pub const Line = union(enum) {
    edge,
    number: i32,
};

pub fn parseLine(s: []const u8) ?Line {
    if (std.mem.eql(u8, s, "-")) return .edge;
    const n = std.fmt.parseInt(i32, s, 10) catch return null;
    return .{ .number = n };
}

// ---------------------------------------------------------------------------
// Tests (more golden coverage lives in tests.zig)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: tmux: parse: getopt clusters and attached values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = .{};
    const cmd = try parseCommand(arena, &.{ "splitw", "-dh", "-l70%", "-t", "%3", "-PF", "#{pane_id}", "--", "cat" }, &diag);
    try testing.expectEqual(CommandId.split_window, cmd.id());
    try testing.expect(cmd.args.has('d') and cmd.args.has('h') and cmd.args.has('P'));
    try testing.expectEqualStrings("70%", cmd.args.get('l').?);
    try testing.expectEqualStrings("%3", cmd.args.get('t').?);
    try testing.expectEqualStrings("#{pane_id}", cmd.args.get('F').?);
    try testing.expectEqual(@as(usize, 1), cmd.args.positionals.len);
    try testing.expectEqualStrings("cat", cmd.args.positionals[0]);
}

test "unit: tmux: parse: targets" {
    try testing.expectEqual(@as(u32, 7), parseTarget("%7").pane_id);
    try testing.expectEqual(@as(u32, 2), parseTarget("@2").window_id);
    try testing.expectEqual(@as(u32, 1), parseTarget("$1").session_id);
    try testing.expectEqual(@as(u32, 9), parseTarget("surface:9").pane_id);
    try testing.expectEqual(@as(u32, 9), parseTarget("tab:9").pane_id);
    try testing.expectEqual(@as(u32, 4), parseTarget("workspace:4").window_id);
    try testing.expectEqual(@as(u32, 5), parseTarget("pane:5").wmux_pane);
    try testing.expectEqual(Target.current, parseTarget(""));
    try testing.expectEqualStrings("main", parseTarget("main").bare);
    const p = parseTarget("dev:2.1").path;
    try testing.expectEqualStrings("dev", p.session.?);
    try testing.expectEqualStrings("2", p.window.?);
    try testing.expectEqualStrings("1", p.pane.?);
    const q = parseTarget(":1").path;
    try testing.expect(q.session == null and q.pane == null);
    try testing.expectEqualStrings("1", q.window.?);
    const r = parseTarget(".2").path;
    try testing.expect(r.session == null and r.window == null);
    try testing.expectEqualStrings("2", r.pane.?);
    const u = parseTarget("{0b5d6c1e-9f3a-4a7b-8c2d-1e2f3a4b5c6d}");
    try testing.expectEqualStrings("0b5d6c1e-9f3a-4a7b-8c2d-1e2f3a4b5c6d", u.uuid);
    // `surface:0` is not a valid ref: falls back to the tmux grammar.
    try testing.expectEqualStrings("surface", parseTarget("surface:0").path.session.?);
}

test "unit: tmux: parse: sizes and lines" {
    try testing.expectEqual(Size{ .percent = 70 }, parseSize("70%", false).?);
    try testing.expectEqual(Size{ .cells = 30 }, parseSize("30", false).?);
    try testing.expectEqual(Size{ .percent = 30 }, parseSize("30", true).?);
    try testing.expect(parseSize("0", false) == null);
    try testing.expect(parseSize("101%", false) == null);
    try testing.expect(parseSize("x%", false) == null);
    try testing.expect(parseSize("", false) == null);
    try testing.expectEqual(Line.edge, parseLine("-").?);
    try testing.expectEqual(Line{ .number = -20 }, parseLine("-20").?);
    try testing.expect(parseLine("abc") == null);
}
