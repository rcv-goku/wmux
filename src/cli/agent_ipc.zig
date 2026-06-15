//! Shared client helpers for the agent IPC CLI verbs
//! (`+workspace`/`+tab`/`+send`). Resolves the target instance's named
//! pipe (`ghostty-ipc-<pid>`), sends one request line, reads one response
//! line, and prints `data` (on ok) or `error` (on failure) — the same
//! round-trip `+browser` performs, factored out so the scripting verbs
//! don't each re-implement the FindFirstFileW pipe enumeration.
//!
//! Windows-only: the named-pipe machinery is gated behind a comptime
//! os.tag check by the callers, which only reference `impl` on Windows.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The Windows-only implementation, mirroring `cli/browser.zig`'s private
/// machinery. Kept in a struct so it is only semantically analyzed on
/// Windows (callers gate references behind `builtin.os.tag == .windows`).
pub const impl = if (builtin.os.tag == .windows) struct {
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

    /// Resolve the target pipe, send one request line, read one response
    /// line, and print `data` (on ok) or `error` (on failure). Returns 0
    /// on ok, 1 on any client or server error.
    pub fn sendRequest(
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

    const ResolveError = error{ NoInstance, MultipleInstances } || Allocator.Error;

    /// Resolve the full "\\.\pipe\ghostty-ipc-<pid>" path. Prefer the
    /// GHOSTTY_PID env var (set in every Ghostty-spawned shell); otherwise
    /// enumerate ghostty-ipc-* pipes and require exactly one. Caller
    /// frees the returned slice.
    pub fn resolvePipePath(alloc: Allocator, stderr: *std.Io.Writer) ResolveError![]u8 {
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

        // If a second match exists, the target is ambiguous. The errdefer
        // above frees `first` on this error return — do NOT also free it
        // here, or the block is freed twice (a double-free that crashes when
        // the allocator has unmapped the page, e.g. a large/own-page block).
        if (FindNextFileW(find, &find_data) != 0) {
            stderr.print(
                "multiple Ghostty instances found; set GHOSTTY_PID to choose one\n",
                .{},
            ) catch {};
            return error.MultipleInstances;
        }

        const path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\{s}", .{first});
        alloc.free(first);
        return path;
    }
} else struct {};
