const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");

// The wire protocol and line framing are shared with the server so the
// request/response shape can never drift. ipc.zig only compiles on
// Windows (it pulls in named-pipe externs), so it's imported lazily
// inside the Windows-only code path below.

/// Options exists so the shared CLI machinery (completions, docs,
/// `Action.options()`) has a type to reflect over. `+browser` parses its
/// own positional subcommand and arguments in `run`, so the only flag
/// handled here is `--help`.
pub const Options = struct {
    pub fn deinit(self: *Options) void {
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `+browser` command drives the WebView2 browser panes of a running
/// Ghostty instance over a per-process named pipe (the agent IPC server),
/// enabling scripted/agentic control of the embedded browser.
///
/// Subcommands:
///
///   * `open <url> [--tab|--split]`: Open a new browser pane and navigate
///     it to `<url>`. Defaults to a split of the active pane; `--tab`
///     opens it as a new tab instead. Prints the new pane's numeric id.
///
///   * `navigate <url> [--id N]`: Navigate an existing browser pane to
///     `<url>`. Without `--id`, the most recently created browser pane is
///     used.
///
///   * `eval <js> [--id N]`: Evaluate JavaScript in a browser pane and
///     print the JSON-encoded result. Without `--id`, the most recently
///     created browser pane is used.
///
///   * `snapshot [--id N]`: Print a compact accessibility snapshot of the
///     pane as a JSON array of `{ref, role, name}`. `ref` is a CDP
///     backendNodeId an agent feeds to `click`/`fill`.
///
///   * `click <ref> [--id N]`: Click the element identified by the
///     `backendNodeId` `<ref>` (from `snapshot`).
///
///   * `fill <ref> <text> [--id N]`: Focus the element identified by
///     `<ref>` and insert `<text>`.
///
///   * `list`: List the ids of the live browser panes.
///
/// The target instance's IPC pipe is `ghostty-ipc-<pid>` (shared with the
/// `+workspace`/`+tab`/`+send` scripting verbs). The pid is taken from the
/// `GHOSTTY_PID` environment variable (exported into every shell Ghostty
/// spawns); if it is unset, `+browser` connects to the sole `ghostty-ipc-*`
/// pipe present and errors if there are zero or more than one.
///
/// Only supported on Windows.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    if (comptime builtin.os.tag != .windows) {
        var buf: [256]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buf);
        const stderr = &stderr_writer.interface;
        try stderr.print("+browser is only supported on Windows.\n", .{});
        stderr.flush() catch {};
        return 1;
    }

    return windows_impl.run(alloc);
}

/// All Windows-specific machinery, kept in a struct so the whole thing is
/// only semantically analyzed on Windows (the `else` branch above is
/// comptime-known false elsewhere, so this is never referenced).
const windows_impl = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const kernel32 = windows.kernel32;
    const ipc = @import("../apprt/win32/ipc.zig");

    // FindFirstFileW / FindNextFileW for enumerating named pipes. std
    // doesn't surface these, so declare the minimum we need.
    const WIN32_FIND_DATAW = extern struct {
        dwFileAttributes: windows.DWORD,
        ftCreationTime: windows.FILETIME,
        ftLastAccessTime: windows.FILETIME,
        ftLastWriteTime: windows.FILETIME,
        nFileSizeHigh: windows.DWORD,
        nFileSizeLow: windows.DWORD,
        dwReserved0: windows.DWORD,
        dwReserved1: windows.DWORD,
        cFileName: [windows.MAX_PATH]u16,
        cAlternateFileName: [14]u16,
    };

    extern "kernel32" fn FindFirstFileW(
        lpFileName: windows.LPCWSTR,
        lpFindFileData: *WIN32_FIND_DATAW,
    ) callconv(.winapi) windows.HANDLE;

    extern "kernel32" fn FindNextFileW(
        hFindFile: windows.HANDLE,
        lpFindFileData: *WIN32_FIND_DATAW,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn FindClose(hFindFile: windows.HANDLE) callconv(.winapi) windows.BOOL;

    fn run(alloc: Allocator) !u8 {
        var out_buf: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&out_buf);
        const stdout = &stdout_writer.interface;
        var err_buf: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&err_buf);
        const stderr = &stderr_writer.interface;

        const code = runImpl(alloc, stdout, stderr) catch |err| blk: {
            stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
            break :blk @as(u8, 1);
        };
        stdout.flush() catch {};
        stderr.flush() catch {};
        return code;
    }

    const Command = enum { open, navigate, eval, list, snapshot, click, fill };

    fn runImpl(
        alloc: Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();

        // argsIterator skips argv0 AND transparently filters out any
        // "+"-prefixed token (the "+browser" action selector), so the
        // first value here is already the subcommand.

        // Subcommand.
        const sub_str = iter.next() orelse {
            try stderr.print("usage: ghostty +browser <open|navigate|eval|list|snapshot|click|fill> [args]\n", .{});
            return 1;
        };
        if (std.mem.eql(u8, sub_str, "--help") or std.mem.eql(u8, sub_str, "-h")) {
            return Action.help_error;
        }
        const sub = std.meta.stringToEnum(Command, sub_str) orelse {
            try stderr.print("unknown subcommand '{s}'\n", .{sub_str});
            return 1;
        };

        // Collect positional and flag args after the subcommand. `fill`
        // takes two positionals (<ref> <text>); everything else takes at
        // most one.
        var positional: ?[]const u8 = null;
        var positional2: ?[]const u8 = null;
        var id: ?u32 = null;
        var as_tab = false;
        var as_split = false;
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--tab")) {
                as_tab = true;
            } else if (std.mem.eql(u8, arg, "--split")) {
                as_split = true;
            } else if (std.mem.startsWith(u8, arg, "--id=")) {
                id = std.fmt.parseInt(u32, arg["--id=".len..], 10) catch {
                    try stderr.print("invalid --id value\n", .{});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--id")) {
                const v = iter.next() orelse {
                    try stderr.print("--id requires a value\n", .{});
                    return 1;
                };
                id = std.fmt.parseInt(u32, v, 10) catch {
                    try stderr.print("invalid --id value\n", .{});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Action.help_error;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try stderr.print("unknown flag '{s}'\n", .{arg});
                return 1;
            } else if (positional == null) {
                positional = try alloc.dupe(u8, arg);
            } else if (positional2 == null and sub == .fill) {
                positional2 = try alloc.dupe(u8, arg);
            } else {
                try stderr.print("unexpected argument '{s}'\n", .{arg});
                return 1;
            }
        }

        // Build the request JSON for the chosen subcommand.
        const request = switch (sub) {
            .open => req: {
                const url = positional orelse {
                    try stderr.print("open requires a <url>\n", .{});
                    return 1;
                };
                const target: []const u8 = if (as_tab) "tab" else "split";
                break :req try std.fmt.allocPrint(
                    alloc,
                    "{{\"id\":1,\"cmd\":\"open\",\"args\":{{\"url\":{f},\"target\":\"{s}\"}}}}\n",
                    .{ std.json.fmt(url, .{}), target },
                );
            },
            .navigate => req: {
                const url = positional orelse {
                    try stderr.print("navigate requires a <url>\n", .{});
                    return 1;
                };
                break :req if (id) |n|
                    try std.fmt.allocPrint(
                        alloc,
                        "{{\"id\":1,\"cmd\":\"navigate\",\"args\":{{\"url\":{f},\"id\":{d}}}}}\n",
                        .{ std.json.fmt(url, .{}), n },
                    )
                else
                    try std.fmt.allocPrint(
                        alloc,
                        "{{\"id\":1,\"cmd\":\"navigate\",\"args\":{{\"url\":{f}}}}}\n",
                        .{std.json.fmt(url, .{})},
                    );
            },
            .eval => req: {
                const js = positional orelse {
                    try stderr.print("eval requires a <js> expression\n", .{});
                    return 1;
                };
                break :req if (id) |n|
                    try std.fmt.allocPrint(
                        alloc,
                        "{{\"id\":1,\"cmd\":\"eval\",\"args\":{{\"js\":{f},\"id\":{d}}}}}\n",
                        .{ std.json.fmt(js, .{}), n },
                    )
                else
                    try std.fmt.allocPrint(
                        alloc,
                        "{{\"id\":1,\"cmd\":\"eval\",\"args\":{{\"js\":{f}}}}}\n",
                        .{std.json.fmt(js, .{})},
                    );
            },
            .snapshot => if (id) |n|
                try std.fmt.allocPrint(
                    alloc,
                    "{{\"id\":1,\"cmd\":\"snapshot\",\"args\":{{\"id\":{d}}}}}\n",
                    .{n},
                )
            else
                try alloc.dupe(u8, "{\"id\":1,\"cmd\":\"snapshot\"}\n"),
            .click => req: {
                const ref_str = positional orelse {
                    try stderr.print("click requires a <ref>\n", .{});
                    return 1;
                };
                const ref = std.fmt.parseInt(i64, ref_str, 10) catch {
                    try stderr.print("invalid <ref> (must be an integer backendNodeId)\n", .{});
                    return 1;
                };
                break :req if (id) |n|
                    try std.fmt.allocPrint(
                        alloc,
                        "{{\"id\":1,\"cmd\":\"click\",\"args\":{{\"ref\":{d},\"id\":{d}}}}}\n",
                        .{ ref, n },
                    )
                else
                    try std.fmt.allocPrint(
                        alloc,
                        "{{\"id\":1,\"cmd\":\"click\",\"args\":{{\"ref\":{d}}}}}\n",
                        .{ref},
                    );
            },
            .fill => req: {
                const ref_str = positional orelse {
                    try stderr.print("fill requires a <ref> and <text>\n", .{});
                    return 1;
                };
                const text = positional2 orelse {
                    try stderr.print("fill requires a <ref> and <text>\n", .{});
                    return 1;
                };
                const ref = std.fmt.parseInt(i64, ref_str, 10) catch {
                    try stderr.print("invalid <ref> (must be an integer backendNodeId)\n", .{});
                    return 1;
                };
                break :req if (id) |n|
                    try std.fmt.allocPrint(
                        alloc,
                        "{{\"id\":1,\"cmd\":\"fill\",\"args\":{{\"ref\":{d},\"text\":{f},\"id\":{d}}}}}\n",
                        .{ ref, std.json.fmt(text, .{}), n },
                    )
                else
                    try std.fmt.allocPrint(
                        alloc,
                        "{{\"id\":1,\"cmd\":\"fill\",\"args\":{{\"ref\":{d},\"text\":{f}}}}}\n",
                        .{ ref, std.json.fmt(text, .{}) },
                    );
            },
            // `list` has no server command yet; it's answered client-side
            // by enumerating pipes / a future server query. For now drive
            // it through a no-op eval-less path: report the resolved pipe.
            .list => {
                return listPanes(alloc, stdout, stderr);
            },
        };
        defer alloc.free(request);

        return sendRequest(alloc, request, stdout, stderr);
    }

    /// Resolve the target pipe, send one request line, read one response
    /// line, and print `data` (on ok) or `error` (on failure).
    fn sendRequest(
        alloc: Allocator,
        request: []const u8,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        const pipe_path = resolvePipePath(alloc, stderr) catch |err| switch (err) {
            error.NoInstance, error.MultipleInstances => return 1,
            else => return err,
        };
        defer alloc.free(pipe_path);

        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pipe_path);
        defer alloc.free(path_w);

        const handle = kernel32.CreateFileW(
            path_w.ptr,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            0,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) {
            try stderr.print("could not connect to Ghostty IPC pipe ({s})\n", .{pipe_path});
            return 1;
        }
        defer windows.CloseHandle(handle);

        // Write the request as a single message.
        var written: windows.DWORD = 0;
        if (kernel32.WriteFile(
            handle,
            request.ptr,
            @intCast(request.len),
            &written,
            null,
        ) == 0) {
            try stderr.print("failed to write IPC request\n", .{});
            return 1;
        }

        // Read until we have one full response line.
        var framer: ipc.LineFramer = .{};
        defer framer.deinit(alloc);
        var read_buf: [4096]u8 = undefined;
        const line = while (true) {
            if (framer.next()) |l| break l;
            var n: windows.DWORD = 0;
            if (kernel32.ReadFile(
                handle,
                @ptrCast(&read_buf),
                read_buf.len,
                &n,
                null,
            ) == 0 or n == 0) {
                try stderr.print("no response from Ghostty\n", .{});
                return 1;
            }
            try framer.feed(alloc, read_buf[0..n]);
        };

        return printResponse(alloc, line, stdout, stderr);
    }

    /// Parse the response line and print data (ok) or error (failure).
    /// Returns 0 on ok, 1 on a server error.
    fn printResponse(
        alloc: Allocator,
        line: []const u8,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch {
            try stderr.print("malformed response: {s}\n", .{line});
            return 1;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                try stderr.print("malformed response: {s}\n", .{line});
                return 1;
            },
        };
        const ok = if (obj.get("ok")) |v| (v == .bool and v.bool) else false;
        if (!ok) {
            const msg = if (obj.get("error")) |v|
                (if (v == .string) v.string else "unknown error")
            else
                "unknown error";
            try stderr.print("{s}\n", .{msg});
            return 1;
        }

        // Print the data verbatim as JSON.
        if (obj.get("data")) |data| {
            try std.json.Stringify.value(data, .{}, stdout);
            try stdout.writeAll("\n");
        }
        return 0;
    }

    /// `list` for now resolves and reports the target instance. A proper
    /// server-side enumeration arrives with the snapshot/click stage; this
    /// keeps the subcommand usable (and the pipe-resolution path tested).
    fn listPanes(
        alloc: Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        const pipe_path = resolvePipePath(alloc, stderr) catch |err| switch (err) {
            error.NoInstance, error.MultipleInstances => return 1,
            else => return err,
        };
        defer alloc.free(pipe_path);
        try stdout.print("connected instance pipe: {s}\n", .{pipe_path});
        return 0;
    }

    const ResolveError = error{ NoInstance, MultipleInstances } || Allocator.Error;

    /// Resolve the full "\\.\pipe\ghostty-ipc-<pid>" path. Prefer the
    /// GHOSTTY_PID env var (set in every Ghostty-spawned shell); otherwise
    /// enumerate ghostty-ipc-* pipes and require exactly one. Caller
    /// frees the returned slice.
    fn resolvePipePath(alloc: Allocator, stderr: *std.Io.Writer) ResolveError![]u8 {
        if (std.process.getEnvVarOwned(alloc, "GHOSTTY_PID")) |pid_str| {
            defer alloc.free(pid_str);
            const trimmed = std.mem.trim(u8, pid_str, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                return std.fmt.allocPrint(
                    alloc,
                    "\\\\.\\pipe\\ghostty-ipc-{s}",
                    .{trimmed},
                );
            }
        } else |_| {}

        // Enumerate \\.\pipe\ghostty-ipc-* and require exactly one.
        const pattern_w = std.unicode.utf8ToUtf16LeStringLiteral(
            "\\\\.\\pipe\\ghostty-ipc-*",
        );
        var find_data: WIN32_FIND_DATAW = undefined;
        const find = FindFirstFileW(pattern_w, &find_data);
        if (find == windows.INVALID_HANDLE_VALUE) {
            stderr.print(
                "no running Ghostty instance found (set GHOSTTY_PID or start Ghostty)\n",
                .{},
            ) catch {};
            return error.NoInstance;
        }
        defer _ = FindClose(find);

        var name_buf: [windows.MAX_PATH]u8 = undefined;
        const first_len = std.unicode.utf16LeToUtf8(
            &name_buf,
            std.mem.sliceTo(&find_data.cFileName, 0),
        ) catch return error.NoInstance;
        const first = try alloc.dupe(u8, name_buf[0..first_len]);
        errdefer alloc.free(first);

        // If a second match exists, the target is ambiguous.
        if (FindNextFileW(find, &find_data) != 0) {
            stderr.print(
                "multiple Ghostty instances found; set GHOSTTY_PID to choose one\n",
                .{},
            ) catch {};
            alloc.free(first);
            return error.MultipleInstances;
        }

        const path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\{s}", .{first});
        alloc.free(first);
        return path;
    }
} else struct {};
