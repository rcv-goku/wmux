//! The app log file (ARCHITECTURE.md Appendix G / AF-16): every std.log
//! record goes to `STATE\logs\wmux.log` (app/paths.zig logsDir) as well
//! as to stderr, filtered by WMUX_LOG (app/runtime_env.zig LogLevel,
//! default info). The file rotates at 8 MiB to `wmux.log.1` (two files at
//! most, so at most 16 MiB).
//!
//! std.log's sink is the Ghostty `logFn` (src/main_ghostty.zig), which
//! writes one line per record to the process stderr handle and re-reads
//! that handle on every record. `start` therefore points STD_ERROR_HANDLE
//! at a pipe whose reader thread tees each line to the original stderr
//! (unchanged console and harness output) and, when its level passes
//! WMUX_LOG, to the file with a UTC timestamp. No Ghostty file changes.
//!
//! The reader thread lives until `stop` (or process exit); `start` is
//! idempotent and best effort: a log that cannot be opened is reported on
//! stderr and the app runs on without it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const LogLevel = @import("runtime_env.zig").LogLevel;
const RuntimeEnv = @import("runtime_env.zig").RuntimeEnv;
const paths = @import("paths.zig");
const w32 = @import("../platform/win32.zig");

const log = std.log.scoped(.app_logger);

pub const file_name = "wmux.log";
pub const rotated_name = "wmux.log.1";

/// Rotation threshold of wmux.log (Appendix G: 8 MiB x 2).
pub const max_file_bytes: u64 = 8 * 1024 * 1024;

/// A line longer than this is written in pieces (each piece keeps the
/// level of the line it belongs to).
const max_line_bytes = 8 * 1024;

// ---------------------------------------------------------------------------
// The rotating file
// ---------------------------------------------------------------------------

/// `wmux.log` in `dir`, rotated to `wmux.log.1` before a write would take
/// it past `max_bytes`. Single writer (the tee thread).
pub const RotatingFile = struct {
    dir: std.fs.Dir,
    max_bytes: u64,
    file: ?std.fs.File = null,
    size: u64 = 0,

    /// Open (append) or create wmux.log in `dir`. Takes ownership of
    /// `dir`.
    pub fn open(dir: std.fs.Dir, max_bytes: u64) !RotatingFile {
        var self: RotatingFile = .{ .dir = dir, .max_bytes = max_bytes };
        try self.reopen();
        return self;
    }

    pub fn close(self: *RotatingFile) void {
        if (self.file) |f| f.close();
        self.file = null;
        self.dir.close();
    }

    fn reopen(self: *RotatingFile) !void {
        const f = try self.dir.createFile(file_name, .{ .truncate = false, .read = false });
        errdefer f.close();
        const end = try f.getEndPos();
        try f.seekTo(end);
        self.file = f;
        self.size = end;
    }

    /// Append `bytes` (one or more whole lines), rotating first when
    /// the file would grow past `max_bytes` (a non-empty file only, so a
    /// single oversized write still lands).
    pub fn write(self: *RotatingFile, bytes: []const u8) !void {
        if (needsRotation(self.size, bytes.len, self.max_bytes)) try self.rotate();
        const f = self.file orelse try self.reopenAndGet();
        try f.writeAll(bytes);
        self.size += bytes.len;
    }

    fn reopenAndGet(self: *RotatingFile) !std.fs.File {
        try self.reopen();
        return self.file.?;
    }

    /// wmux.log -> wmux.log.1 (replacing it), then a fresh wmux.log.
    pub fn rotate(self: *RotatingFile) !void {
        if (self.file) |f| f.close();
        self.file = null;
        self.dir.deleteFile(rotated_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try self.dir.rename(file_name, rotated_name);
        try self.reopen();
    }
};

/// Whether appending `add` bytes to a file of `size` bytes must rotate it
/// first. Pure (unit-tested).
pub fn needsRotation(size: u64, add: usize, max_bytes: u64) bool {
    return size > 0 and size + add > max_bytes;
}

// ---------------------------------------------------------------------------
// Line handling
// ---------------------------------------------------------------------------

/// The level of a Ghostty logFn line ("<level>(<scope>): ..." or
/// "<level>: ..."), or null when the line does not start with one (a
/// continuation, a panic trace, a child's output). Pure (unit-tested).
pub fn lineLevel(line: []const u8) ?LogLevel {
    const table = .{
        .{ "error", LogLevel.err },
        .{ "warning", LogLevel.warn },
        .{ "info", LogLevel.info },
        .{ "debug", LogLevel.debug },
    };
    inline for (table) |entry| {
        const word = entry[0];
        if (line.len > word.len and std.mem.startsWith(u8, line, word) and
            (line[word.len] == '(' or line[word.len] == ':'))
        {
            return entry[1];
        }
    }
    return null;
}

/// `2026-10-17T01:02:03.456Z ` for `ms` milliseconds since the epoch
/// (24 bytes plus a space). Pure (unit-tested).
pub fn formatTimestamp(buf: *[25]u8, ms: i64) []const u8 {
    const clamped: u64 = @intCast(@max(ms, 0));
    const secs = std.time.epoch.EpochSeconds{ .secs = clamped / 1000 };
    const day = secs.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = secs.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z ", .{
        day.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        clamped % 1000,
    }) catch unreachable;
}

/// Splits the stderr byte stream into lines and writes the ones WMUX_LOG
/// allows to a RotatingFile, each prefixed with a timestamp. A line
/// without a level prefix keeps the level of the previous line.
pub const LineFilter = struct {
    threshold: LogLevel,
    out: *RotatingFile,
    line: [max_line_bytes]u8 = undefined,
    len: usize = 0,
    level: LogLevel = .info,
    /// Clock for the timestamps (tests pin it).
    now_ms: *const fn () i64 = &std.time.milliTimestamp,

    pub fn feed(self: *LineFilter, bytes: []const u8) void {
        for (bytes) |b| {
            if (b == '\n') {
                self.flushLine(true);
                continue;
            }
            if (self.len == self.line.len) self.flushLine(false);
            self.line[self.len] = b;
            self.len += 1;
        }
    }

    /// Write the buffered partial line, if any (end of stream).
    pub fn finish(self: *LineFilter) void {
        if (self.len > 0) self.flushLine(true);
    }

    fn flushLine(self: *LineFilter, complete: bool) void {
        var text = self.line[0..self.len];
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
        if (lineLevel(text)) |lvl| self.level = lvl;
        defer self.len = 0;
        if (!self.threshold.allows(self.level)) return;
        var ts_buf: [25]u8 = undefined;
        const ts = formatTimestamp(&ts_buf, self.now_ms());
        var buf: [25 + max_line_bytes + 1]u8 = undefined;
        @memcpy(buf[0..ts.len], ts);
        @memcpy(buf[ts.len..][0..text.len], text);
        var n = ts.len + text.len;
        if (complete) {
            buf[n] = '\n';
            n += 1;
        }
        self.out.write(buf[0..n]) catch {};
    }
};

// ---------------------------------------------------------------------------
// The stderr tee (process-wide)
// ---------------------------------------------------------------------------

const Tee = struct {
    file: RotatingFile,
    filter: LineFilter,
    read_end: windows.HANDLE,
    write_end: windows.HANDLE,
    /// The stderr handle before `start` (null when there was none).
    original: ?windows.HANDLE,
    thread: std.Thread,
};

var tee: ?*Tee = null;
var tee_mutex: std.Thread.Mutex = .{};

/// Open `STATE\logs\wmux.log` and start teeing stderr into it. Idempotent;
/// does nothing when WMUX_LOG is "off". Call on the UI thread once the
/// RuntimeEnv is parsed.
pub fn start(alloc: Allocator, env: *const RuntimeEnv) void {
    if (comptime builtin.os.tag != .windows) return;
    if (env.log_level == .off) return;
    tee_mutex.lock();
    defer tee_mutex.unlock();
    if (tee != null) return;
    startLocked(alloc, env) catch |err| {
        log.warn("log file unavailable: {}", .{err});
    };
}

fn startLocked(alloc: Allocator, env: *const RuntimeEnv) !void {
    const dir_path = try paths.logsDir(alloc, env);
    defer alloc.free(dir_path);
    try std.fs.cwd().makePath(dir_path);
    var file = try RotatingFile.open(try std.fs.cwd().openDir(dir_path, .{}), max_file_bytes);
    errdefer file.close();

    var ts_buf: [25]u8 = undefined;
    var header_buf: [160]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s}wmux log opened pid={d} level={s}\n", .{
        formatTimestamp(&ts_buf, std.time.milliTimestamp()),
        w32.GetCurrentProcessId(),
        @tagName(env.log_level),
    }) catch unreachable;
    try file.write(header);

    // Neither end is inheritable: child processes never hold the pipe.
    const sa: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = windows.FALSE,
    };
    var read_end: windows.HANDLE = undefined;
    var write_end: windows.HANDLE = undefined;
    try windows.CreatePipe(&read_end, &write_end, &sa);
    errdefer {
        windows.CloseHandle(read_end);
        windows.CloseHandle(write_end);
    }

    const t = try std.heap.page_allocator.create(Tee);
    errdefer std.heap.page_allocator.destroy(t);
    const original = windows.peb().ProcessParameters.hStdError;
    t.* = .{
        .file = file,
        .filter = undefined,
        .read_end = read_end,
        .write_end = write_end,
        .original = if (original == windows.INVALID_HANDLE_VALUE) null else original,
        .thread = undefined,
    };
    t.filter = .{ .threshold = env.log_level, .out = &t.file };
    t.thread = try std.Thread.spawn(.{}, teeThread, .{t});
    if (w32.SetStdHandle(w32.STD_ERROR_HANDLE, write_end) == 0) {
        // Without the redirect nothing would reach the pipe: undo.
        windows.CloseHandle(write_end);
        t.thread.join();
        windows.CloseHandle(read_end);
        t.file.close();
        std.heap.page_allocator.destroy(t);
        return error.SetStdHandleFailed;
    }
    tee = t;
}

/// Restore the original stderr, drain the pipe and close the log. Safe
/// to call without `start`.
pub fn stop() void {
    if (comptime builtin.os.tag != .windows) return;
    tee_mutex.lock();
    defer tee_mutex.unlock();
    const t = tee orelse return;
    tee = null;
    _ = w32.SetStdHandle(w32.STD_ERROR_HANDLE, t.original);
    windows.CloseHandle(t.write_end);
    t.thread.join();
    windows.CloseHandle(t.read_end);
    t.file.close();
    std.heap.page_allocator.destroy(t);
}

fn teeThread(t: *Tee) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = windows.ReadFile(t.read_end, &buf, null) catch break;
        if (n == 0) break;
        if (t.original) |h| _ = windows.WriteFile(h, buf[0..n], null) catch {};
        t.filter.feed(buf[0..n]);
    }
    t.filter.finish();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: app: logger line levels follow the Ghostty log prefix" {
    try testing.expectEqual(@as(?LogLevel, .info), lineLevel("info: ghostty version=1"));
    try testing.expectEqual(@as(?LogLevel, .debug), lineLevel("debug(win32): x"));
    try testing.expectEqual(@as(?LogLevel, .warn), lineLevel("warning(io_exec): y"));
    try testing.expectEqual(@as(?LogLevel, .err), lineLevel("error: z"));
    try testing.expectEqual(@as(?LogLevel, null), lineLevel("information"));
    try testing.expectEqual(@as(?LogLevel, null), lineLevel("    at main.zig:1"));
    try testing.expectEqual(@as(?LogLevel, null), lineLevel("info"));
}

test "unit: app: logger timestamps are UTC ISO-8601 with milliseconds" {
    var buf: [25]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z ", formatTimestamp(&buf, 0));
    // 2026-10-17T01:02:03.456Z
    try testing.expectEqualStrings("2026-10-17T01:02:03.456Z ", formatTimestamp(&buf, 1792198923456));
}

test "unit: app: logger rotation threshold" {
    try testing.expect(!needsRotation(0, 100, 10)); // an empty file takes any write
    try testing.expect(!needsRotation(5, 5, 10));
    try testing.expect(needsRotation(6, 5, 10));
    try testing.expect(!needsRotation(max_file_bytes - 10, 10, max_file_bytes));
    try testing.expect(needsRotation(max_file_bytes - 10, 11, max_file_bytes));
}

fn fixedClock() i64 {
    return 0;
}

test "unit: app: logger rotates wmux.log into wmux.log.1 and filters by level" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var file = try RotatingFile.open(try tmp.dir.openDir(".", .{}), 64);
    defer file.close();

    var filter: LineFilter = .{ .threshold = .info, .out = &file, .now_ms = &fixedClock };
    // 25-byte timestamp + text + newline per kept line.
    filter.feed("info: first\ndebug(x): dropped\n  continuation dropped too\n");
    filter.feed("warning(y): sec");
    filter.feed("ond\r\n");
    filter.finish();

    const rotated = try tmp.dir.readFileAlloc(testing.allocator, rotated_name, 1024);
    defer testing.allocator.free(rotated);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z info: first\n", rotated);
    const current = try tmp.dir.readFileAlloc(testing.allocator, file_name, 1024);
    defer testing.allocator.free(current);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z warning(y): second\n", current);

    // A second rotation replaces wmux.log.1; there are never more than two files.
    try file.write("x" ** 60);
    try file.write("y");
    const again = try tmp.dir.readFileAlloc(testing.allocator, rotated_name, 1024);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z warning(y): second\n", again);
    const last = try tmp.dir.readFileAlloc(testing.allocator, file_name, 1024);
    defer testing.allocator.free(last);
    try testing.expectEqualStrings("x" ** 60 ++ "y", last);
    var it = tmp.dir.iterate();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count);
}

test "unit: app: logger appends to an existing wmux.log" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = file_name, .data = "old\n" });
    var file = try RotatingFile.open(try tmp.dir.openDir(".", .{}), max_file_bytes);
    defer file.close();
    try testing.expectEqual(@as(u64, 4), file.size);
    try file.write("new\n");
    const got = try tmp.dir.readFileAlloc(testing.allocator, file_name, 1024);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("old\nnew\n", got);
}
