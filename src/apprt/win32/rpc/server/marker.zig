//! The instance marker `STATE\run\instance.json` (ARCHITECTURE.md ADR-3.1,
//! Appendix G.1; W1-1a): how clients find this instance's pipes without a
//! socket environment (the CLI's discovery step 3, ADR-4.5).
//!
//!     {"pipe":"\\\\.\\pipe\\wmux-<channel>-<sidhash8>-s<n>[-alt-<8hex>]",
//!      "launch_pipe":"...-launch","pid":1234,"exe":"C:\\...\\wmux.exe",
//!      "version":"...","protocol":2,"channel":"stable",
//!      "boot_id":"<uuid of this process run>","started_at":"2026-10-17T09:30:00Z"}
//!
//! Written once the control pipe serves, by atomic replace (a temporary
//! file renamed over the old marker); deleted on clean exit only while it
//! still names this process (a newer instance may have replaced it).
//! STATE is `WMUX_STATE_DIR`, else `%LOCALAPPDATA%\wmux\<channel>`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("wmux_proto");

const log = std.log.scoped(.rpc_server);

pub const Marker = struct {
    pipe: []const u8,
    launch_pipe: ?[]const u8 = null,
    pid: u32,
    exe: []const u8 = "",
    version: []const u8 = "",
    protocol: u32 = 2,
    channel: []const u8,
    boot_id: []const u8,
    started_at: []const u8,
};

/// `STATE\run\instance.json` (heap). `state_override` is WMUX_STATE_DIR
/// as parsed by the app; null when neither it nor LOCALAPPDATA is set.
pub fn pathAlloc(gpa: Allocator, state_override: ?[]const u8, channel: []const u8) Allocator.Error!?[]u8 {
    const state = if (state_override) |s| try gpa.dupe(u8, s) else blk: {
        var map = std.process.getEnvMap(gpa) catch return null;
        defer map.deinit();
        break :blk (try proto.paths.stateDir(gpa, proto.env_names.Env.fromEnvMap(&map), .windows, channel)) orelse return null;
    };
    defer gpa.free(state);
    return try proto.paths.runFile(gpa, .windows, state, proto.paths.files.instance_json);
}

/// The marker as one JSON document (heap).
pub fn encodeAlloc(gpa: Allocator, m: Marker) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, m, .{ .whitespace = .indent_2 }) catch error.OutOfMemory;
}

/// RFC 3339 UTC time of `ms` since the epoch, e.g. `2026-10-17T09:30:00Z`.
pub fn rfc3339(buf: *[20]u8, ms: i64) []const u8 {
    const secs: u64 = @intCast(@max(ms, 0) / 1000);
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year,             md.month.numeric(),      @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Writes `m` to `path` by atomic replace, creating `STATE\run`.
pub fn write(gpa: Allocator, path: []const u8, m: Marker) !void {
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(dir_path);
    const text = try encodeAlloc(gpa, m);
    defer gpa.free(text);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.{d}.tmp", .{ path, m.pid });
    defer gpa.free(tmp);
    {
        const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer f.close();
        try f.writeAll(text);
        try f.writeAll("\n");
    }
    std.fs.cwd().rename(tmp, path) catch |err| {
        std.fs.cwd().deleteFile(tmp) catch {};
        return err;
    };
}

/// The pid a marker names, or null when it is missing or unreadable.
pub fn readPid(gpa: Allocator, path: []const u8) ?u32 {
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024) catch return null;
    defer gpa.free(bytes);
    return parsePid(gpa, bytes);
}

/// The `pid` of marker text. Pure (unit-tested).
pub fn parsePid(gpa: Allocator, bytes: []const u8) ?u32 {
    const Pid = struct { pid: ?u32 = null };
    const parsed = std.json.parseFromSlice(Pid, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    return parsed.value.pid;
}

/// Deletes the marker at `path` if it still names `pid`.
pub fn remove(gpa: Allocator, path: []const u8, pid: u32) void {
    if (readPid(gpa, path) != pid) return;
    std.fs.cwd().deleteFile(path) catch |err| log.warn("instance marker not deleted: {}", .{err});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: rpc: instance marker round-trips through write, readPid and remove" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const path = try proto.paths.runFile(gpa, .windows, root, "instance.json");
    defer gpa.free(path);
    var ts: [20]u8 = undefined;
    const m: Marker = .{
        .pipe = "\\\\.\\pipe\\wmux-test-0a1b2c3d-1f2e3d4c-s1",
        .launch_pipe = "\\\\.\\pipe\\wmux-test-0a1b2c3d-1f2e3d4c-s1-launch",
        .pid = 4242,
        .exe = "C:\\wmux\\wmux.exe",
        .version = "1.2.3",
        .channel = "test-0a1b2c3d",
        .boot_id = "6F1C2A2E-0000-4000-8000-000000000000",
        .started_at = rfc3339(&ts, 1_760_693_400_000),
    };
    try write(gpa, path, m);
    try write(gpa, path, m); // replaces
    try testing.expectEqual(@as(?u32, 4242), readPid(gpa, path));
    const bytes = try std.fs.cwd().readFileAlloc(gpa, path, 4096);
    defer gpa.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("protocol").?.integer);
    try testing.expectEqualStrings(m.pipe, parsed.value.object.get("pipe").?.string);
    try testing.expectEqualStrings("2025-10-17T09:30:00Z", parsed.value.object.get("started_at").?.string);
    // Another pid's marker is left alone; ours is deleted.
    remove(gpa, path, 1);
    try testing.expectEqual(@as(?u32, 4242), readPid(gpa, path));
    remove(gpa, path, 4242);
    try testing.expectEqual(@as(?u32, null), readPid(gpa, path));
    try testing.expectEqual(@as(?u32, null), parsePid(gpa, "not json"));
}
