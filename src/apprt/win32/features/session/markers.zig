//! Session files and markers on disk (ARCHITECTURE.md ADR-9.1, 9.4, 9.8,
//! ADR-2.2): where `STATE\session\` and `STATE\run\` are, the
//! `session.running` and `session.restoring` markers, the crash-loop
//! rotation to `session.crashed-<ms>.json`, the quarantine of an unusable
//! primary file, and the persisted handle reservations
//! (`STATE\run\handles.json`). The decisions are logic/integrity.zig's;
//! this file only executes them. Startup-time I/O on the UI thread (before
//! the first window) plus the tiny synchronous reservation write that
//! ADR-2.2 requires before a reserved ref is handed out.

const std = @import("std");
const Allocator = std.mem.Allocator;

const RuntimeEnv = @import("../../app/runtime_env.zig").RuntimeEnv;
const app_paths = @import("../../app/paths.zig");
const handle_registry = @import("../../model/logic/handle_registry.zig");
const integrity = @import("logic/integrity.zig");

const log = std.log.scoped(.session);

/// `STATE\session` (directory name, ADR-9.1).
pub const session_dir_name = "session";
/// `STATE\run` (directory name, Appendix G.1).
pub const run_dir_name = "run";
/// The persisted handle reservations under `STATE\run`.
pub const handles_file = "handles.json";

/// `STATE\session` for `env` (caller frees).
pub fn sessionDir(gpa: Allocator, env: *const RuntimeEnv) ![]u8 {
    return app_paths.statePath(gpa, env, session_dir_name);
}

/// `STATE\run` for `env` (caller frees).
pub fn runDir(gpa: Allocator, env: *const RuntimeEnv) ![]u8 {
    return app_paths.statePath(gpa, env, run_dir_name);
}

/// Milliseconds since the epoch (quarantine names).
pub fn nowMs() i64 {
    return std.time.milliTimestamp();
}

/// Whether `<dir>\<name>` exists.
pub fn exists(dir: []const u8, name: []const u8) bool {
    var d = std.fs.cwd().openDir(dir, .{}) catch return false;
    defer d.close();
    d.access(name, .{}) catch return false;
    return true;
}

/// Read `<dir>\<name>` (caller frees), null when missing or unreadable.
pub fn readFile(gpa: Allocator, dir: []const u8, name: []const u8, max: usize) ?[]u8 {
    var d = std.fs.cwd().openDir(dir, .{}) catch return null;
    defer d.close();
    return d.readFileAlloc(gpa, name, max) catch null;
}

/// Write `<dir>\<name>` (truncate), creating the directory.
pub fn writeFile(dir: []const u8, name: []const u8, bytes: []const u8) !void {
    std.fs.cwd().makePath(dir) catch {};
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();
    try d.writeFile(.{ .sub_path = name, .data = bytes });
}

/// Delete `<dir>\<name>`; a missing file is fine.
pub fn delete(dir: []const u8, name: []const u8) void {
    var d = std.fs.cwd().openDir(dir, .{}) catch return;
    defer d.close();
    d.deleteFile(name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("could not delete {s} err={}", .{ name, err }),
    };
}

/// Rename `<dir>\<from>` to `<dir>\<to>` (replacing `to`).
pub fn rename(dir: []const u8, from: []const u8, to: []const u8) !void {
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();
    try d.rename(from, to);
}

// ── session.restoring ───────────────────────────────────────────────

/// Mark a restore in progress (ADR-9.4 crash-loop guard).
pub fn writeRestoring(dir: []const u8) void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{{\"pid\":{d},\"started_ms\":{d}}}", .{ currentPid(), nowMs() }) catch unreachable;
    writeFile(dir, integrity.restoring_marker, text) catch |err|
        log.warn("could not write {s} err={}", .{ integrity.restoring_marker, err });
}

pub fn clearRestoring(dir: []const u8) void {
    delete(dir, integrity.restoring_marker);
}

/// The previous restore crashed: rename `session.json` to
/// `session.crashed-<ms>.json` and drop the marker, so the next launch
/// restores normally (from the backup or nothing). Returns the new name
/// (in `buf`) when a snapshot was rotated.
pub fn rotateCrashed(dir: []const u8, buf: []u8) ?[]const u8 {
    defer clearRestoring(dir);
    if (!exists(dir, integrity.session_file)) return null;
    const name = integrity.crashedName(buf, nowMs()) catch return null;
    rename(dir, integrity.session_file, name) catch |err| {
        log.warn("could not rotate the crashed session err={}", .{err});
        return null;
    };
    return name;
}

/// Move an unusable `session.json` aside to `session.unusable-<ms>.json`.
pub fn quarantineUnusable(dir: []const u8) void {
    var buf: [64]u8 = undefined;
    const name = integrity.unusableName(&buf, nowMs()) catch return;
    rename(dir, integrity.session_file, name) catch |err|
        log.warn("could not quarantine the unusable session file err={}", .{err});
}

/// Keep a newer-schema `session.json` as `session.schema-v<N>.json`.
pub fn copySchemaVersion(gpa: Allocator, dir: []const u8, version: u32) void {
    var buf: [64]u8 = undefined;
    const name = integrity.schemaVersionName(&buf, version) catch return;
    const bytes = readFile(gpa, dir, integrity.session_file, 64 * 1024 * 1024) orelse return;
    defer gpa.free(bytes);
    writeFile(dir, name, bytes) catch |err| log.warn("could not keep {s} err={}", .{ name, err });
}

// ── session.running ─────────────────────────────────────────────────

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn OpenProcess(access: u32, inherit: std.os.windows.BOOL, pid: u32) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn GetProcessTimes(
    process: std.os.windows.HANDLE,
    creation: *std.os.windows.FILETIME,
    exit: *std.os.windows.FILETIME,
    kernel: *std.os.windows.FILETIME,
    user: *std.os.windows.FILETIME,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetExitCodeProcess(process: std.os.windows.HANDLE, code: *u32) callconv(.winapi) std.os.windows.BOOL;

const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
const STILL_ACTIVE: u32 = 259;

pub fn currentPid() u32 {
    return GetCurrentProcessId();
}

fn startFiletime(process: std.os.windows.HANDLE) ?u64 {
    var c: std.os.windows.FILETIME = undefined;
    var e: std.os.windows.FILETIME = undefined;
    var k: std.os.windows.FILETIME = undefined;
    var u: std.os.windows.FILETIME = undefined;
    if (GetProcessTimes(process, &c, &e, &k, &u) == 0) return null;
    return (@as(u64, c.dwHighDateTime) << 32) | c.dwLowDateTime;
}

/// This process as a running marker.
pub fn selfMarker() integrity.RunningMarker {
    return .{
        .pid = currentPid(),
        .process_start_filetime = startFiletime(GetCurrentProcess()) orelse 0,
    };
}

/// Whether the process a marker names still runs (ADR-9.8).
pub fn liveness(m: integrity.RunningMarker) integrity.Liveness {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, m.pid) orelse return .dead;
    defer std.os.windows.CloseHandle(h);
    var code: u32 = 0;
    if (GetExitCodeProcess(h, &code) != 0 and code != STILL_ACTIVE) return .dead;
    const start = startFiletime(h) orelse return .alive_other;
    return if (start == m.process_start_filetime) .alive_same else .alive_other;
}

/// Read the `session.running` marker left in `dir` (null when none).
pub fn readRunning(gpa: Allocator, dir: []const u8) ?integrity.RunningMarker {
    const bytes = readFile(gpa, dir, integrity.running_marker, 4096) orelse return null;
    defer gpa.free(bytes);
    return integrity.parseRunningMarker(gpa, bytes);
}

pub fn writeRunning(dir: []const u8) void {
    var buf: [96]u8 = undefined;
    const text = integrity.formatRunningMarker(selfMarker(), &buf) catch return;
    writeFile(dir, integrity.running_marker, text) catch |err|
        log.warn("could not write {s} err={}", .{ integrity.running_marker, err });
}

pub fn clearRunning(dir: []const u8) void {
    delete(dir, integrity.running_marker);
}

// ── STATE\run\handles.json (ADR-2.2) ────────────────────────────────

pub const Kind = handle_registry.Kind;
pub const Marks = std.EnumArray(Kind, u32);

/// `{"reserved":{"window":64,...},"next":{...}}` for `reg`.
pub fn formatHandles(reg: *const handle_registry.HandleRegistry, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();
    inline for (.{ "reserved", "next" }) |section| {
        try jw.objectField(section);
        try jw.beginObject();
        const marks = if (comptime std.mem.eql(u8, section, "reserved")) &reg.reserved else &reg.next;
        for (std.enums.values(Kind)) |k| {
            try jw.objectField(@tagName(k));
            try jw.write(marks.get(k));
        }
        try jw.endObject();
    }
    try jw.endObject();
}

pub const PersistedHandles = struct {
    reserved: Marks = .initFill(0),
    next: Marks = .initFill(0),
};

/// Parse `handles.json`; unknown or malformed parts read as 0.
pub fn parseHandles(gpa: Allocator, bytes: []const u8) PersistedHandles {
    var out: PersistedHandles = .{};
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return out;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return out,
    };
    inline for (.{ "reserved", "next" }) |section| {
        if (root.get(section)) |v| if (v == .object) {
            for (std.enums.values(Kind)) |k| {
                if (v.object.get(@tagName(k))) |n| if (n == .integer) {
                    if (std.math.cast(u32, n.integer)) |x| @field(out, section).set(k, x);
                };
            }
        };
    }
    return out;
}

/// Write `STATE\run\handles.json` for `reg` now (the registry's
/// `on_reserve` hook: before the reserved ref is handed out).
pub fn writeHandles(run_dir: []const u8, reg: *const handle_registry.HandleRegistry) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    formatHandles(reg, &w) catch return;
    writeFile(run_dir, handles_file, w.buffered()) catch |err|
        log.warn("could not persist the handle reservations err={}", .{err});
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: session: handle reservations persist and seed a new registry" {
    var reg: handle_registry.HandleRegistry = .{};
    defer reg.deinit(testing.allocator);
    var obj: u8 = 0;
    _ = try reg.mint(testing.allocator, .workspace, &obj);
    _ = try reg.mint(testing.allocator, .workspace, &obj);
    _ = try reg.mint(testing.allocator, .surface, &obj);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatHandles(&reg, &w);
    const p = parseHandles(testing.allocator, w.buffered());
    try testing.expectEqual(@as(u32, 64), p.reserved.get(.workspace));
    try testing.expectEqual(@as(u32, 2), p.next.get(.workspace));
    try testing.expectEqual(@as(u32, 1), p.next.get(.surface));

    // A new process seeds from the reservations: the next ref passes every
    // ref the crashed process could have handed out.
    var fresh: handle_registry.HandleRegistry = .{};
    defer fresh.deinit(testing.allocator);
    fresh.seed(p.next, p.reserved);
    const h = try fresh.mint(testing.allocator, .workspace, &obj);
    try testing.expectEqual(@as(u32, 65), h.ref);
    // Junk reads as zeros.
    const junk = parseHandles(testing.allocator, "not json");
    try testing.expectEqual(@as(u32, 0), junk.reserved.get(.pane));
}

test "unit: session: markers rotate a crashed snapshot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    try writeFile(dir, integrity.session_file, "{}");
    writeRestoring(dir);
    try testing.expect(exists(dir, integrity.restoring_marker));
    var buf: [64]u8 = undefined;
    const name = rotateCrashed(dir, &buf).?;
    try testing.expect(std.mem.startsWith(u8, name, "session.crashed-"));
    try testing.expect(!exists(dir, integrity.restoring_marker));
    try testing.expect(!exists(dir, integrity.session_file));
    try testing.expect(exists(dir, name));
    // Our own process is alive with the same start time.
    try testing.expectEqual(integrity.Liveness.alive_same, liveness(selfMarker()));
}
