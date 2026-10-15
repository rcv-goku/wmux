//! Legacy Ghostty config-file operations: resolve (and create) the user
//! config file, open it or its folder in the shell, and set the default
//! shell by rewriting its `command =` line on a worker thread followed by a
//! hard config reload.
//!
//! Moved verbatim from App.zig in W0-A1 (ARCHITECTURE.md ADR-1.8). W1-4
//! builds the settings layer (loader, snapshot, watcher, Ghostty overlay)
//! around this (ADR-5).

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("../App.zig");
const configpkg = @import("../../../config.zig");
const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.win32);


/// Posted by the setDefaultShell worker thread after the config file has
/// been written successfully. Signals the UI thread to perform a
/// reload_config so the new command takes effect. No payload.
pub const WM_APP_SHELL_SET: u32 = w32.WM_APP + 6;

/// Template written when the config file is missing at open time so the
/// editor has something to show. Config.load writes a fuller template at
/// startup; this covers a file deleted while the app is running.
const CONFIG_TEMPLATE =
    "# Ghostty config — see https://ghostty.org/docs/config\n" ++
    "# window-show-sidebar = true\n" ++
    "# window-sidebar-width = 220\n";

/// Resolve the user config file path the same way config loading does
/// (XDG shim: %LOCALAPPDATA%\ghostty\config.ghostty unless overridden),
/// creating parent directories and a commented template when the file
/// is missing. The returned path is owned by the caller.
fn resolveConfigFile(self: *App) ?[]const u8 {
    const path = configpkg.preferredDefaultFilePath(
        self.core_app.alloc,
    ) catch |err| {
        log.err("failed to get config path: {}", .{err});
        return null;
    };
    if (std.fs.accessAbsolute(path, .{})) |_| {} else |_| {
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                log.warn("failed to create config dir={s} err={}", .{ dir, err });
            };
        }
        if (std.fs.createFileAbsolute(path, .{ .exclusive = true })) |file| {
            defer file.close();
            file.writeAll(CONFIG_TEMPLATE) catch |err| {
                log.warn("failed to write config template err={}", .{err});
            };
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => log.warn("failed to create config file={s} err={}", .{ path, err }),
        }
    }
    return path;
}

/// Produce config-file text with the `command` key set to `value`,
/// preserving every other line. If a non-comment `command = ...` line
/// already exists, the first one is replaced in place (later duplicates
/// are left untouched — the config parser uses the last occurrence, but
/// rewriting only the first keeps edits minimal and predictable); a
/// commented `# command = ...` line is NOT treated as a match. If no
/// active `command` line exists, `command = <value>` is appended on its
/// own line (with a preceding newline only when the source does not end
/// in one). The result is owned by the caller.
///
/// `value` is a raw config value (e.g. "pwsh.exe" or
/// "wsl.exe --cd ~ -d Ubuntu") and is written verbatim; callers pass a
/// program name or a space-joined argv that the config's Command parser
/// understands.
fn setCommandInConfigText(
    alloc: Allocator,
    source: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var replaced = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        // splitScalar yields a trailing empty segment when the source
        // ends in '\n'; preserve the structure by re-emitting newlines
        // between segments rather than after each.
        if (!first) try out.append(alloc, '\n');
        first = false;

        // A line is the `command` key if, after trimming, the text
        // before the first '=' equals "command" (case-sensitive, like
        // the config parser). Tolerate a trailing '\r' from CRLF files.
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (!replaced) {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const key = std.mem.trim(u8, trimmed[0..eq], " \t");
                if (std.mem.eql(u8, key, "command")) {
                    try out.appendSlice(alloc, "command = ");
                    try out.appendSlice(alloc, value);
                    replaced = true;
                    continue;
                }
            }
        }
        try out.appendSlice(alloc, raw_line);
    }

    if (!replaced) {
        // Append on its own line. Add a separating newline unless the
        // file is empty or already ends in one.
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(alloc, '\n');
        }
        try out.appendSlice(alloc, "command = ");
        try out.appendSlice(alloc, value);
        try out.append(alloc, '\n');
    }

    return out.toOwnedSlice(alloc);
}

/// Set the default shell by writing `command = <value>` into the user
/// config file (preserving all other content), then hard-reloading so
/// the change takes effect for subsequently created tabs/splits. This
/// is the GUI exposure of the `command` config option, which the
/// default-tab path already honors (see Exec.zig). `value` is written
/// verbatim as the config value (e.g. "pwsh.exe").
///
/// The file I/O (read + transform + atomic write) is performed on a
/// detached worker thread so the UI thread is never blocked by slow
/// disks. On success the worker posts WM_APP_SHELL_SET back to
/// msg_hwnd, where the UI thread triggers a reload_config.
pub fn setDefaultShell(self: *App, value: []const u8) void {
    const alloc = self.core_app.alloc;

    // resolveConfigFile creates the file (with the template) when it is
    // missing, so the read below always sees a real file. This is a
    // quick stat + possible create of a small template — fast enough for
    // the UI thread and required before the worker can read the file.
    const path = resolveConfigFile(self) orelse return;

    const value_copy = alloc.dupe(u8, value) catch {
        alloc.free(path);
        return;
    };

    const ctx = alloc.create(ShellSetCtx) catch {
        alloc.free(path);
        alloc.free(value_copy);
        return;
    };
    ctx.* = .{
        .alloc = alloc,
        .path = path,
        .value = value_copy,
        .msg_hwnd = self.msg_hwnd,
    };

    const thread = std.Thread.spawn(.{}, shellSetWorker, .{ctx}) catch {
        alloc.free(path);
        alloc.free(value_copy);
        alloc.destroy(ctx);
        return;
    };
    thread.detach();
}

const ShellSetCtx = struct {
    alloc: Allocator,
    path: []const u8,
    value: []const u8,
    msg_hwnd: ?w32.HWND,
};

/// Worker-thread entry for setDefaultShell: reads the config, transforms
/// it, writes it back atomically, then signals the UI thread. Touches
/// only its owned ctx and the filesystem — never live App/Window state.
fn shellSetWorker(ctx: *ShellSetCtx) void {
    const alloc = ctx.alloc;
    defer {
        alloc.free(ctx.path);
        alloc.free(ctx.value);
        alloc.destroy(ctx);
    }

    const source = std.fs.cwd().readFileAlloc(
        alloc,
        ctx.path,
        16 * 1024 * 1024,
    ) catch |err| {
        log.err("set default shell: failed to read config={s} err={}", .{ ctx.path, err });
        return;
    };
    defer alloc.free(source);

    const updated = setCommandInConfigText(alloc, source, ctx.value) catch |err| {
        log.err("set default shell: failed to build config text err={}", .{err});
        return;
    };
    defer alloc.free(updated);

    writeFileAtomic(alloc, ctx.path, updated) catch |err| {
        log.err("set default shell: failed to write config={s} err={}", .{ ctx.path, err });
        return;
    };

    log.info("set default shell: wrote command={s} to {s}", .{ ctx.value, ctx.path });

    // Signal the UI thread to reload_config. No payload needed.
    if (ctx.msg_hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, WM_APP_SHELL_SET, 0, 0);
    }
}

/// UI-thread handler for WM_APP_SHELL_SET: the worker finished writing
/// the config file, so reload it.
pub fn handleShellSet(self: *App) void {
    self.core_app.performAction(self, .reload_config) catch |err| {
        log.err("set default shell: reload failed: {}", .{err});
    };
}

/// Write `data` to `path` atomically by writing to a temp file in the
/// same directory and renaming it over the destination. Falls back to a
/// direct write if a temp file cannot be created in that directory.
fn writeFileAtomic(alloc: Allocator, path: []const u8, data: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);

    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    const tmp_name = try std.fmt.allocPrint(alloc, "{s}.ghostty-tmp", .{base});
    defer alloc.free(tmp_name);

    {
        const file = dir.createFile(tmp_name, .{ .truncate = true }) catch {
            // Could not create a temp file (e.g. read-only dir quirk);
            // fall back to a direct overwrite.
            try dir.writeFile(.{ .sub_path = base, .data = data });
            return;
        };
        defer file.close();
        try file.writeAll(data);
    }
    errdefer dir.deleteFile(tmp_name) catch {};
    try dir.rename(tmp_name, base);
}

/// Open the user config file in its default editor, falling back to
/// notepad.exe when nothing is associated with the file (extensionless
/// legacy `config` paths commonly have no "open" verb).
pub fn openConfigFile(self: *App) void {
    const path = resolveConfigFile(self) orelse return;
    defer self.core_app.alloc.free(path);

    var wbuf: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return;
    if (wlen >= wbuf.len) return;
    wbuf[wlen] = 0;

    // ShellExecuteW returns > 32 on success; <= 32 is an SE_ERR_* code.
    const result = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        @ptrCast(&wbuf),
        null,
        null,
        w32.SW_SHOW,
    );
    if (result > 32) return;
    log.warn("ShellExecuteW open config failed code={d}, falling back to notepad", .{result});

    // CreateProcessW may modify the command line, so build it in a
    // mutable buffer. Quoting is safe: Windows paths cannot contain '"'.
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("notepad.exe \"");
    var cmd_buf: [prefix.len + wbuf.len + 2]u16 = undefined;
    @memcpy(cmd_buf[0..prefix.len], prefix);
    @memcpy(cmd_buf[prefix.len .. prefix.len + wlen], wbuf[0..wlen]);
    cmd_buf[prefix.len + wlen] = '"';
    cmd_buf[prefix.len + wlen + 1] = 0;

    var si = std.mem.zeroes(w32.STARTUPINFOW);
    si.cb = @sizeOf(w32.STARTUPINFOW);
    var pi = std.mem.zeroes(w32.PROCESS_INFORMATION);
    if (w32.CreateProcessW(
        null,
        @ptrCast(&cmd_buf),
        null,
        null,
        0,
        0,
        null,
        null,
        &si,
        &pi,
    ) != 0) {
        if (pi.hProcess) |h| _ = w32.CloseHandle(h);
        if (pi.hThread) |h| _ = w32.CloseHandle(h);
    } else {
        log.err("notepad fallback failed for config path={s}", .{path});
    }
}

/// Open the folder containing the user config file in Explorer.
/// resolveConfigFile created the directory, so the open cannot race a
/// missing folder.
pub fn openConfigFolder(self: *App) void {
    const path = resolveConfigFile(self) orelse return;
    defer self.core_app.alloc.free(path);
    const dir = std.fs.path.dirname(path) orelse return;

    var wbuf: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, dir) catch return;
    if (wlen >= wbuf.len) return;
    wbuf[wlen] = 0;
    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        @ptrCast(&wbuf),
        null,
        null,
        w32.SW_SHOW,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: set command appends when absent" {
    const alloc = testing.allocator;
    const src = "# Ghostty config\nwindow-show-sidebar = true\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "# Ghostty config\nwindow-show-sidebar = true\ncommand = pwsh.exe\n",
        out,
    );
}

test "unit: set command appends a newline when file lacks a trailing one" {
    const alloc = testing.allocator;
    const src = "theme = dark"; // no trailing newline
    const out = try setCommandInConfigText(alloc, src, "cmd.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("theme = dark\ncommand = cmd.exe\n", out);
}

test "unit: set command appends into an empty file" {
    const alloc = testing.allocator;
    const out = try setCommandInConfigText(alloc, "", "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("command = pwsh.exe\n", out);
}

test "unit: set command replaces an existing active line in place" {
    const alloc = testing.allocator;
    const src = "theme = dark\ncommand = cmd.exe\nfont-size = 12\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    // Replaced in place; surrounding lines untouched; no extra append.
    try testing.expectEqualStrings(
        "theme = dark\ncommand = pwsh.exe\nfont-size = 12\n",
        out,
    );
}

test "unit: set command tolerates whitespace around the key and equals" {
    const alloc = testing.allocator;
    const src = "  command   =   cmd.exe  \nfont-size = 12\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("command = pwsh.exe\nfont-size = 12\n", out);
}

test "unit: set command ignores commented and lookalike keys" {
    const alloc = testing.allocator;
    // A commented command line and a different key that contains the
    // substring must NOT be treated as the active command; the value is
    // appended instead.
    const src = "# command = cmd.exe\ninitial-command = top\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "# command = cmd.exe\ninitial-command = top\ncommand = pwsh.exe\n",
        out,
    );
}

test "unit: set command replaces only the first active line" {
    const alloc = testing.allocator;
    const src = "command = cmd.exe\ncommand = bash\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    // Only the first is rewritten; the duplicate is preserved verbatim
    // (the parser uses the last, but minimal edits are the contract).
    try testing.expectEqualStrings("command = pwsh.exe\ncommand = bash\n", out);
}

test "unit: set command preserves CRLF on untouched lines" {
    const alloc = testing.allocator;
    const src = "theme = dark\r\ncommand = cmd.exe\r\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    // The replaced line is normalized to "command = pwsh.exe" (LF); the
    // other line keeps its CRLF. The match tolerates the trailing \r.
    try testing.expectEqualStrings("theme = dark\r\ncommand = pwsh.exe\n", out);
}

test "unit: set command accepts an argv value verbatim" {
    const alloc = testing.allocator;
    const out = try setCommandInConfigText(
        alloc,
        "theme = dark\n",
        "wsl.exe --cd ~ -d Ubuntu",
    );
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "theme = dark\ncommand = wsl.exe --cd ~ -d Ubuntu\n",
        out,
    );
}

test "unit: set command replaces the key on a final line without a newline" {
    const alloc = testing.allocator;
    const src = "theme = dark\ncommand = cmd.exe"; // EOF right after the value
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    // Replaced in place — no duplicate appended, and the file's missing
    // trailing newline is preserved as-is.
    try testing.expectEqualStrings("theme = dark\ncommand = pwsh.exe", out);
}

test "unit: set command CRLF key at EOF without a final LF" {
    const alloc = testing.allocator;
    // The last line ends in a bare \r (no \n); the \r must not defeat
    // the key match.
    const src = "theme = dark\r\ncommand = cmd.exe\r";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("theme = dark\r\ncommand = pwsh.exe", out);
}

test "unit: set command commented key followed by real key replaces the real one" {
    const alloc = testing.allocator;
    const src = "# command = old.exe\ncommand = cmd.exe\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("# command = old.exe\ncommand = pwsh.exe\n", out);
}

test "unit: set command matches when the old value contains equals" {
    const alloc = testing.allocator;
    // The key is the text before the FIRST '='; later '=' belong to the
    // value and must not break the match.
    const src = "command = env FOO=bar bash\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("command = pwsh.exe\n", out);
}

test "unit: set command writes a new value containing equals verbatim" {
    const alloc = testing.allocator;
    const out = try setCommandInConfigText(alloc, "theme = dark\n", "cmd.exe /c set X=1");
    defer alloc.free(out);
    try testing.expectEqualStrings("theme = dark\ncommand = cmd.exe /c set X=1\n", out);
}

test "unit: set command appends to an only-comments file" {
    const alloc = testing.allocator;
    const src = "# one\n# command = nope\n# three\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings(
        "# one\n# command = nope\n# three\ncommand = pwsh.exe\n",
        out,
    );
}

test "unit: set command ignores a command line without equals" {
    const alloc = testing.allocator;
    // No '=' means no key: the line is preserved and a real entry is
    // appended instead.
    const src = "command\n";
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("command\ncommand = pwsh.exe\n", out);
}

test "unit: set command preserves very long lines byte for byte" {
    const alloc = testing.allocator;
    // A line far beyond any fixed buffer (16 KiB) must survive
    // unmodified, both before and after the replaced key.
    const long_len = 16 * 1024;
    const long = try alloc.alloc(u8, long_len);
    defer alloc.free(long);
    @memset(long, 'x');
    long[0] = '#';
    long[1] = ' ';
    const src = try std.fmt.allocPrint(
        alloc,
        "{s}\ncommand = cmd.exe\n{s}\n",
        .{ long, long },
    );
    defer alloc.free(src);
    const out = try setCommandInConfigText(alloc, src, "pwsh.exe");
    defer alloc.free(out);
    const expected = try std.fmt.allocPrint(
        alloc,
        "{s}\ncommand = pwsh.exe\n{s}\n",
        .{ long, long },
    );
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, out);
}

test "unit: set command preserves leading and trailing value spaces verbatim" {
    const alloc = testing.allocator;
    // The value is written verbatim after "command = "; surrounding
    // spaces are part of it, on both the replace and append paths.
    {
        const out = try setCommandInConfigText(alloc, "command = cmd.exe\n", " pwsh.exe ");
        defer alloc.free(out);
        try testing.expectEqualStrings("command =  pwsh.exe \n", out);
    }
    {
        const out = try setCommandInConfigText(alloc, "theme = dark\n", " pwsh.exe ");
        defer alloc.free(out);
        try testing.expectEqualStrings("theme = dark\ncommand =  pwsh.exe \n", out);
    }
}

test "unit: set command appends after a BOM-only file" {
    const alloc = testing.allocator;
    // A UTF-8 BOM is opaque content, not whitespace: it is preserved
    // byte for byte and the appended entry starts on its own line.
    const out = try setCommandInConfigText(alloc, "\xEF\xBB\xBF", "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("\xEF\xBB\xBF\ncommand = pwsh.exe\n", out);
}

test "unit: set command appends after a CRLF-only file" {
    const alloc = testing.allocator;
    // A file holding a single blank CRLF line: the bare \r line is no
    // key match, the existing line ending is reused as the separator,
    // and nothing is duplicated.
    const out = try setCommandInConfigText(alloc, "\r\n", "pwsh.exe");
    defer alloc.free(out);
    try testing.expectEqualStrings("\r\ncommand = pwsh.exe\n", out);
}
