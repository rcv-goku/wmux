//! The session writer (ARCHITECTURE.md ADR-9.3): one coalescing worker
//! thread that writes `STATE\session\session.json` atomically. The UI
//! thread serializes the snapshot and hands over the bytes (`submit`); a
//! newer submission replaces one the thread has not started yet, so a
//! burst of saves costs one write. Each write is the integrity sequence
//! of logic/integrity.zig: `session.json.tmp` (truncate), FlushFileBuffers,
//! then `ReplaceFileW(session.json, tmp, session.json.bak)`, or
//! `MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)` for the first save (and
//! when ReplaceFileW fails), so a crash leaves the old or the new file,
//! never a torn one.
//!
//! `writeSync` runs the same sequence on the calling thread under the
//! same lock (the synchronous final save inside WM_ENDSESSION, the one UI
//! thread I/O exception of G3). `stop` writes what is still pending and
//! joins the thread (App.terminate, through the feature's deinit).

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const integrity = @import("logic/integrity.zig");

const log = std.log.scoped(.session);

pub const Writer = struct {
    gpa: Allocator,
    /// Absolute `STATE\session` directory (owned).
    dir: []u8,

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    /// Bytes waiting for the thread (owned), null when idle.
    pending: ?[]u8 = null,
    stopping: bool = false,
    thread: ?std.Thread = null,
    /// Serializes the file sequence between the thread and `writeSync`.
    io_mutex: std.Thread.Mutex = .{},

    /// Completed writes (diagnostics and tests).
    writes: std.atomic.Value(u32) = .init(0),

    pub fn init(gpa: Allocator, dir: []const u8) Allocator.Error!Writer {
        return .{ .gpa = gpa, .dir = try gpa.dupe(u8, dir) };
    }

    /// Start the worker thread. Without it every submission is written
    /// synchronously (a failed spawn degrades, it does not lose saves).
    pub fn start(self: *Writer) void {
        if (self.thread != null) return;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| blk: {
            log.warn("session writer thread failed to start err={}", .{err});
            break :blk null;
        };
    }

    /// Hand `bytes` (owned by `gpa`, moved here) to the writer. Any thread.
    pub fn submit(self: *Writer, bytes: []u8) void {
        if (self.thread == null) {
            defer self.gpa.free(bytes);
            self.writeSync(bytes) catch |err| log.warn("session save failed err={}", .{err});
            return;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending) |old| self.gpa.free(old);
        self.pending = bytes;
        self.cond.signal();
    }

    /// Write `bytes` now on the calling thread (borrowed). A submission
    /// still pending is dropped: `bytes` is newer.
    pub fn writeSync(self: *Writer, bytes: []const u8) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.pending) |old| {
                self.gpa.free(old);
                self.pending = null;
            }
        }
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        try atomicWrite(self.gpa, self.dir, bytes);
        _ = self.writes.fetchAdd(1, .monotonic);
    }

    /// Write what is pending, then stop and join the thread. Idempotent.
    pub fn stop(self: *Writer) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.stopping = true;
            self.cond.signal();
        }
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn deinit(self: *Writer) void {
        self.stop();
        if (self.pending) |p| self.gpa.free(p);
        self.pending = null;
        self.gpa.free(self.dir);
    }

    fn run(self: *Writer) void {
        while (true) {
            const bytes: []u8 = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (self.pending == null and !self.stopping) self.cond.wait(&self.mutex);
                const p = self.pending orelse return; // stopping, nothing left
                self.pending = null;
                break :blk p;
            };
            defer self.gpa.free(bytes);
            self.io_mutex.lock();
            defer self.io_mutex.unlock();
            if (atomicWrite(self.gpa, self.dir, bytes)) {
                _ = self.writes.fetchAdd(1, .monotonic);
            } else |err| {
                log.warn("session save failed err={}", .{err});
            }
        }
    }
};

// ── The atomic save sequence ────────────────────────────────────────

const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
const REPLACEFILE_IGNORE_MERGE_ERRORS: u32 = 0x2;

extern "kernel32" fn ReplaceFileW(
    lpReplacedFileName: [*:0]const u16,
    lpReplacementFileName: [*:0]const u16,
    lpBackupFileName: ?[*:0]const u16,
    dwReplaceFlags: u32,
    lpExclude: ?*anyopaque,
    lpReserved: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn MoveFileExW(
    lpExistingFileName: [*:0]const u16,
    lpNewFileName: [*:0]const u16,
    dwFlags: u32,
) callconv(.winapi) windows.BOOL;

/// Write `bytes` to `<dir>\session.json` with the integrity sequence.
pub fn atomicWrite(gpa: Allocator, dir: []const u8, bytes: []const u8) !void {
    std.fs.cwd().makePath(dir) catch {};
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();

    const primary_exists = if (d.access(integrity.session_file, .{})) |_| true else |_| false;
    for (integrity.saveSteps(primary_exists)) |step| switch (step) {
        .write_temp => {
            var f = try d.createFile(integrity.temp_file, .{ .truncate = true });
            defer f.close();
            try f.writeAll(bytes);
            // .flush_temp: FlushFileBuffers before the swap.
            try f.sync();
        },
        .flush_temp => {},
        .replace_with_backup => replace(gpa, dir) catch |err| {
            log.warn("ReplaceFileW failed ({}); moving the new session file in place", .{err});
            try moveInPlace(gpa, dir);
        },
        .move_write_through => try moveInPlace(gpa, dir),
    };
}

fn replace(gpa: Allocator, dir: []const u8) !void {
    const primary = try widePath(gpa, dir, integrity.session_file);
    defer gpa.free(primary);
    const tmp = try widePath(gpa, dir, integrity.temp_file);
    defer gpa.free(tmp);
    const bak = try widePath(gpa, dir, integrity.backup_file);
    defer gpa.free(bak);
    if (ReplaceFileW(primary, tmp, bak, REPLACEFILE_IGNORE_MERGE_ERRORS, null, null) == 0)
        return error.ReplaceFailed;
}

fn moveInPlace(gpa: Allocator, dir: []const u8) !void {
    const primary = try widePath(gpa, dir, integrity.session_file);
    defer gpa.free(primary);
    const tmp = try widePath(gpa, dir, integrity.temp_file);
    defer gpa.free(tmp);
    if (MoveFileExW(tmp, primary, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == 0)
        return error.MoveFailed;
}

/// `<dir>\<name>` as a NUL-terminated UTF-16 path (caller frees).
pub fn widePath(gpa: Allocator, dir: []const u8, name: []const u8) ![:0]u16 {
    const joined = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(joined);
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, joined);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: session: atomic write keeps a backup and coalesces submissions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);

    var w = try Writer.init(testing.allocator, dir);
    defer w.deinit();
    // First save: no session.json yet, moved in place.
    try w.writeSync("{\"n\":1}");
    // Second save: ReplaceFileW keeps the first as session.json.bak.
    try w.writeSync("{\"n\":2}");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{\"n\":2}", try tmp.dir.readFile(integrity.session_file, &buf));
    try testing.expectEqualStrings("{\"n\":1}", try tmp.dir.readFile(integrity.backup_file, &buf));
    try testing.expectError(error.FileNotFound, tmp.dir.access(integrity.temp_file, .{}));

    // The thread writes the newest of the submissions it has not started.
    w.start();
    w.submit(try testing.allocator.dupe(u8, "{\"n\":3}"));
    w.submit(try testing.allocator.dupe(u8, "{\"n\":4}"));
    w.stop();
    try testing.expectEqualStrings("{\"n\":4}", try tmp.dir.readFile(integrity.session_file, &buf));
    try testing.expect(w.writes.load(.monotonic) <= 4);
}
