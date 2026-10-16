//! fs.put / fs.get. Uploads are atomic: data goes to a hidden temp file in
//! the target directory, is fsynced and size/checksum-verified, then renamed
//! over the target. A 0-byte upload is never promoted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hex = [64]u8;

pub fn sha256Hex(data: []const u8) Hex {
    var d: [32]u8 = undefined;
    Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// Resolves a client path: `~` and `~/x` and relative paths are relative to
/// `home`; absolute paths stay. Empty paths and NUL bytes are rejected.
pub fn resolvePath(gpa: Allocator, home: []const u8, path: []const u8) error{ InvalidPath, OutOfMemory }![]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (std.mem.eql(u8, path, "~")) return gpa.dupe(u8, home);
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(gpa, &.{ home, path[2..] });
    if (path[0] == '~') return error.InvalidPath; // ~user is not supported
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    return std.fs.path.join(gpa, &.{ home, path });
}

/// `mkdir -p` that creates the missing directories with mode 0o700 (as
/// `FsPutParams.mkdirs` documents); existing directories are left alone.
fn makePrivatePath(path: []const u8) std.fs.Dir.MakeError!void {
    var it = try std.fs.path.componentIterator(path);
    while (it.next()) |comp| {
        std.posix.mkdir(comp.path, 0o700) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
}

pub const PutOptions = struct {
    mode: std.fs.File.Mode = 0o600,
    expected_sha256: ?[]const u8 = null,
    mkdirs: bool = false,
};

pub const PutError = error{
    InvalidPath,
    EmptyFile,
    ChecksumMismatch,
    ShortWrite,
} || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.Dir.RenameError ||
    std.fs.Dir.MakeError || std.fs.File.StatError || std.fs.File.SyncError || std.fs.File.ChmodError || Allocator.Error;

/// Writes `data` to `abs_path` atomically and returns its SHA-256 (hex).
pub fn put(abs_path: []const u8, data: []const u8, opts: PutOptions) PutError!Hex {
    if (data.len == 0) return error.EmptyFile;
    const digest = sha256Hex(data);
    if (opts.expected_sha256) |want| {
        if (!std.ascii.eqlIgnoreCase(want, &digest)) return error.ChecksumMismatch;
    }
    const dir_path = std.fs.path.dirname(abs_path) orelse return error.InvalidPath;
    const base = std.fs.path.basename(abs_path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.InvalidPath;
    if (opts.mkdirs) try makePrivatePath(dir_path);
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    var rnd: [8]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    var tmp_buf: [std.fs.max_name_bytes + 32]u8 = undefined;
    const short_base = base[0..@min(base.len, 200)];
    const tmp = std.fmt.bufPrint(&tmp_buf, ".{s}.wmux-tmp-{s}", .{ short_base, std.fmt.bytesToHex(rnd, .lower) }) catch return error.InvalidPath;

    var file = try dir.createFile(tmp, .{ .exclusive = true, .mode = opts.mode });
    var promoted = false;
    defer if (!promoted) dir.deleteFile(tmp) catch {};
    {
        defer file.close();
        // createFile's mode is filtered by the umask; set it exactly.
        try file.chmod(opts.mode);
        try file.writeAll(data);
        try file.sync();
        const st = try file.stat();
        if (st.size != data.len or st.size == 0) return error.ShortWrite;
    }
    try dir.rename(tmp, base);
    promoted = true;
    return digest;
}

pub const GetError = error{ TooLarge, IsDir, NotRegularFile } || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.File.StatError || Allocator.Error;

pub const Got = struct {
    data: []u8,
    sha256: Hex,
};

/// Reads at most `max_bytes` of a regular file; larger files fail with
/// TooLarge. The open does not block and anything but a regular file is
/// refused: opening a FIFO without a writer, or reading a device, would
/// stall the daemon's only thread and every session with it.
pub fn get(gpa: Allocator, abs_path: []const u8, max_bytes: usize) GetError!Got {
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true, .CLOEXEC = true };
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    const file: std.fs.File = .{ .handle = try std.posix.openat(std.posix.AT.FDCWD, abs_path, flags, 0) };
    defer file.close();
    const st = try file.stat();
    if (st.kind == .directory) return error.IsDir;
    if (st.kind != .file) return error.NotRegularFile;
    if (st.size > max_bytes) return error.TooLarge;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        if (list.items.len + n > max_bytes) return error.TooLarge;
        try list.appendSlice(gpa, buf[0..n]);
    }
    const data = try list.toOwnedSlice(gpa);
    return .{ .data = data, .sha256 = sha256Hex(data) };
}

const testing = std.testing;

test "unit: remote-daemon: fs paths resolve against home" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "~", "/h" },
        .{ "~/a/b", "/h/a/b" },
        .{ "rel/x", "/h/rel/x" },
        .{ "/abs/y", "/abs/y" },
        .{ "~/☃.txt", "/h/☃.txt" },
    };
    for (cases) |c| {
        const got = try resolvePath(gpa, "/h", c[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
    try testing.expectError(error.InvalidPath, resolvePath(gpa, "/h", ""));
    try testing.expectError(error.InvalidPath, resolvePath(gpa, "/h", "a\x00b"));
    try testing.expectError(error.InvalidPath, resolvePath(gpa, "/h", "~root/x"));
}

test "unit: remote-daemon: fs.put is atomic, verified and never promotes empty files" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const target = try std.fs.path.join(gpa, &.{ root, "sub", "dir", "f.bin" });
    defer gpa.free(target);

    // Missing parent without mkdirs.
    try testing.expectError(error.FileNotFound, put(target, "x", .{}));
    const h = try put(target, "hello", .{ .mkdirs = true });
    try testing.expectEqualStrings(&sha256Hex("hello"), &h);
    const got = try get(gpa, target, 1024);
    defer gpa.free(got.data);
    try testing.expectEqualStrings("hello", got.data);
    try testing.expectEqualStrings(&h, &got.sha256);
    const st = try std.fs.cwd().statFile(target);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o600), st.mode & 0o777);

    // Empty and checksum-mismatched uploads leave the old file intact.
    try testing.expectError(error.EmptyFile, put(target, "", .{}));
    try testing.expectError(error.ChecksumMismatch, put(target, "new", .{ .expected_sha256 = &sha256Hex("other") }));
    const still = try get(gpa, target, 1024);
    defer gpa.free(still.data);
    try testing.expectEqualStrings("hello", still.data);

    // Matching checksum (upper case accepted) replaces; no temp files remain.
    var upper = sha256Hex("new");
    for (&upper) |*c| c.* = std.ascii.toUpper(c.*);
    _ = try put(target, "new", .{ .expected_sha256 = &upper, .mode = 0o755 });
    const st2 = try std.fs.cwd().statFile(target);
    try testing.expectEqual(@as(std.fs.File.Mode, 0o755), st2.mode & 0o777);
    var d = try tmp.dir.openDir("sub/dir", .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next()) |e| : (n += 1) try testing.expectEqualStrings("f.bin", e.name);
    try testing.expectEqual(@as(usize, 1), n);
}

test "unit: remote-daemon: fs.put creates missing parents private" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const target = try std.fs.path.join(gpa, &.{ root, "p", "q", "f" });
    defer gpa.free(target);
    _ = try put(target, "x", .{ .mkdirs = true });
    for ([_][]const u8{ "p", "p/q" }) |d| {
        const st = try tmp.dir.statFile(d);
        try testing.expectEqual(@as(std.fs.File.Mode, 0o700), st.mode & 0o777);
    }
}

test "unit: remote-daemon: fs.get enforces the size cap and rejects directories" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const f = try std.fs.path.join(gpa, &.{ root, "big" });
    defer gpa.free(f);
    var big: [4096]u8 = undefined;
    @memset(&big, 'z');
    _ = try put(f, &big, .{});
    try testing.expectError(error.TooLarge, get(gpa, f, 4095));
    const ok = try get(gpa, f, 4096);
    gpa.free(ok.data);
    try testing.expectError(error.IsDir, get(gpa, root, 10));
    const missing = try std.fs.path.join(gpa, &.{ root, "nope" });
    defer gpa.free(missing);
    try testing.expectError(error.FileNotFound, get(gpa, missing, 10));
    try testing.expectError(error.InvalidPath, put("/", "x", .{}));
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.posix.mode_t) c_int;

test "unit: remote-daemon: fs.get refuses a FIFO without blocking" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const fifo = try std.fs.path.joinZ(gpa, &.{ root, "fifo" });
    defer gpa.free(fifo);
    try testing.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o600));
    // Opening a FIFO with no writer would block the daemon's only thread.
    try testing.expectError(error.NotRegularFile, get(gpa, fifo, 10));
}
