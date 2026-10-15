//! File integrity rules of the session store (ADR-9.1, 9.3, 9.4, 9.8), as
//! pure decisions the Win32 side executes: file and marker names, the
//! atomic save sequence, the launch-time backup rotation, which file to
//! restore from and what to quarantine, the crash-loop guard and the
//! unclean-exit check. No I/O happens here.

const std = @import("std");
const schema = @import("schema_v3.zig");

const Allocator = std.mem.Allocator;

// ── Names (all relative to `STATE\session\`) ────────────────────────

pub const session_file = "session.json";
/// Copied from `session.json` at launch before the first save; backs
/// "Restore Previous App Launch" and is the last recovery fallback.
pub const previous_file = "session-previous.json";
/// `ReplaceFileW` backup of the replaced `session.json`.
pub const backup_file = "session.json.bak";
/// Written, flushed, then swapped in.
pub const temp_file = "session.json.tmp";
/// `{pid, process_start_filetime}` while an instance runs.
pub const running_marker = "session.running";
/// Exists while a restore is in progress (crash-loop guard).
pub const restoring_marker = "session.restoring";
pub const scrollback_dir = "scrollback";
/// Legacy migration source, relative to `%LOCALAPPDATA%\ghostty\`.
pub const legacy_file = "session-state.json";

/// `session.unusable-<ms>.json`: a primary file that failed to parse.
pub fn unusableName(buf: []u8, ms: i64) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "session.unusable-{d}.json", .{@max(ms, 0)});
}

/// `session.crashed-<ms>.json`: a snapshot whose restore crashed.
pub fn crashedName(buf: []u8, ms: i64) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "session.crashed-{d}.json", .{@max(ms, 0)});
}

/// `session.schema-v<N>.json`: a side copy of a newer-schema file.
pub fn schemaVersionName(buf: []u8, version: u32) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "session.schema-v{d}.json", .{version});
}

/// `scrollback/<UUID>.vt` for a surface UUID (canonicalized to uppercase).
pub fn scrollbackRef(buf: *[50]u8, surface_uuid: []const u8) error{InvalidUuid}![]const u8 {
    var id: [36]u8 = undefined;
    if (!schema.canonicalUuid(surface_uuid, &id)) return error.InvalidUuid;
    return std.fmt.bufPrint(buf, scrollback_dir ++ "/{s}.vt", .{&id}) catch unreachable;
}

/// True only for `scrollback/<UUID>.vt` exactly (either slash, canonical
/// or lowercase UUID). Anything else (absolute paths, `..`, drive letters,
/// other names) must not be opened: a session file may come from an
/// untrusted import.
pub fn isSafeScrollbackRef(ref: []const u8) bool {
    const prefix_len = scrollback_dir.len + 1;
    if (ref.len != prefix_len + 36 + 3) return false;
    if (!std.mem.eql(u8, ref[0..scrollback_dir.len], scrollback_dir)) return false;
    if (ref[scrollback_dir.len] != '/' and ref[scrollback_dir.len] != '\\') return false;
    if (!std.mem.eql(u8, ref[ref.len - 3 ..], ".vt")) return false;
    var id: [36]u8 = undefined;
    return schema.canonicalUuid(ref[prefix_len .. prefix_len + 36], &id);
}

// ── Save sequence ───────────────────────────────────────────────────

pub const SaveStep = enum {
    /// Write the bytes to `session.json.tmp` (truncate).
    write_temp,
    /// `FlushFileBuffers` on the temp file, then close it.
    flush_temp,
    /// `ReplaceFileW(session.json, tmp, session.json.bak)`.
    replace_with_backup,
    /// `MoveFileExW(tmp, session.json, REPLACE_EXISTING|WRITE_THROUGH)`.
    move_write_through,
};

/// Steps of one atomic save. The first save (no `session.json` yet) cannot
/// use `ReplaceFileW` and moves the temp file instead.
pub fn saveSteps(primary_exists: bool) []const SaveStep {
    return if (primary_exists)
        &.{ .write_temp, .flush_temp, .replace_with_backup }
    else
        &.{ .write_temp, .flush_temp, .move_write_through };
}

/// What to do when `ReplaceFileW` fails: retry once with the move, which
/// still leaves either the old or the new file in place.
pub fn fallbackAfterReplaceFailure() SaveStep {
    return .move_write_through;
}

/// At launch, before the first save: copy `session.json` over
/// `session-previous.json` only when the primary was usable, so a corrupt
/// file never destroys the last good previous launch.
pub fn shouldRotatePrevious(primary: ?Verdict) bool {
    const v = primary orelse return false;
    return v == .ok;
}

// ── Classification and recovery ─────────────────────────────────────

pub const Verdict = union(enum) {
    ok,
    /// Zero bytes or only whitespace (e.g. power loss during the first save).
    empty,
    corrupt,
    /// Another app's or format's JSON (`schema` is not `wmux-session`).
    not_session,
    /// A legacy wmux v1/v2 file in the v3 location.
    legacy: u32,
    /// A newer `wmux-session` than this build reads.
    future: u32,
};

/// Classifies file contents by fully parsing them (in a scratch arena).
pub fn classify(gpa: Allocator, bytes: []const u8) error{OutOfMemory}!Verdict {
    if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) return .empty;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diag: schema.Diagnostics = .{};
    _ = schema.parseLeaky(arena.allocator(), bytes, .{}, &diag) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Corrupt => .corrupt,
        error.NotSession => .not_session,
        error.LegacyVersion => .{ .legacy = clampVersion(diag.version) },
        error.FutureVersion => .{ .future = clampVersion(diag.version) },
    };
    return .ok;
}

fn clampVersion(v: ?i64) u32 {
    return std.math.cast(u32, v orelse 0) orelse std.math.maxInt(u32);
}

pub const Source = enum { primary, backup, previous };

/// What was found on disk; `null` = the file does not exist.
pub const Observed = struct {
    primary: ?Verdict = null,
    backup: ?Verdict = null,
    previous: ?Verdict = null,
};

pub const Quarantine = union(enum) {
    /// Rename `session.json` to `unusableName(now)`.
    move_unusable,
    /// Copy `session.json` to `schemaVersionName(N)` and leave it alone.
    copy_schema_version: u32,
};

pub const Notice = enum {
    none,
    /// The primary was unusable or newer; restored from `.bak`.
    recovered_from_backup,
    /// Restored from `session-previous.json`.
    recovered_from_previous,
    /// The primary was newer than this build and nothing older was usable.
    newer_schema,
    /// Files existed but none was usable.
    nothing_restorable,
};

pub const LoadPlan = struct {
    source: ?Source = null,
    quarantine: ?Quarantine = null,
    notice: Notice = .none,
};

/// Decides which file to restore from (ADR-9.8): the primary when usable;
/// otherwise quarantine it (an unusable file is moved aside, a newer-schema
/// file is preserved as a side copy) and fall back to `.bak`, then
/// `session-previous.json`. Unusable or newer fallbacks are skipped, never
/// quarantined.
pub fn planLoad(o: Observed) LoadPlan {
    var plan: LoadPlan = .{};
    if (o.primary) |p| switch (p) {
        .ok => return .{ .source = .primary },
        .future => |n| plan.quarantine = .{ .copy_schema_version = n },
        .empty, .corrupt, .not_session, .legacy => plan.quarantine = .move_unusable,
    };
    if (o.backup) |b| if (b == .ok) {
        plan.source = .backup;
        plan.notice = if (plan.quarantine != null) .recovered_from_backup else .none;
        return plan;
    };
    if (o.previous) |p| if (p == .ok) {
        plan.source = .previous;
        plan.notice = if (plan.quarantine != null or o.backup != null) .recovered_from_previous else .none;
        return plan;
    };
    if (plan.quarantine) |q| {
        plan.notice = if (q == .copy_schema_version) .newer_schema else .nothing_restorable;
    } else if (o.backup != null or o.previous != null) {
        plan.notice = .nothing_restorable;
    }
    return plan;
}

/// The legacy file is migrated only when no v3 file exists at all.
pub fn shouldMigrateLegacy(o: Observed, legacy_exists: bool) bool {
    return legacy_exists and o.primary == null and o.backup == null and o.previous == null;
}

pub const ImportError = error{
    /// Not JSON, not a session, or structurally broken.
    InvalidSession,
    /// A pre-v3 file: `restore-session --from` reads v3 only.
    UnsupportedVersion,
    /// Newer than this build: refused, never partially read.
    NewerVersion,
};

/// `session.import` accepts only a current-version session.
pub fn checkImport(v: Verdict) ImportError!void {
    return switch (v) {
        .ok => {},
        .legacy => error.UnsupportedVersion,
        .future => error.NewerVersion,
        .empty, .corrupt, .not_session => error.InvalidSession,
    };
}

// ── Launch guard and markers ────────────────────────────────────────

pub const LaunchInputs = struct {
    /// `WMUX_DISABLE_SESSION_RESTORE` or `CMUX_DISABLE_SESSION_RESTORE` set.
    restore_disabled: bool = false,
    test_mode: bool = false,
    /// `WMUX_TEST_SESSION_RESTORE=1`.
    test_session_restore: bool = false,
    /// Path, URL, `-e`, `--working-directory` or a forwarded `new_window`.
    explicit_intent: bool = false,
    /// `session.restoring` exists: the previous restore crashed.
    restoring_marker: bool = false,
};

pub const LaunchDecision = struct {
    restore: bool,
    /// Rename `session.json` to `crashedName(now)` and delete the marker.
    rotate_crashed: bool = false,
    crash_notice: bool = false,
};

/// ADR-9.4. A crashed restore always rotates the snapshot (whatever else
/// this launch wants), so the next launch restores normally instead of
/// crashing again.
pub fn decideLaunch(in: LaunchInputs) LaunchDecision {
    if (in.restoring_marker) return .{ .restore = false, .rotate_crashed = true, .crash_notice = true };
    if (in.restore_disabled or in.explicit_intent) return .{ .restore = false };
    if (in.test_mode and !in.test_session_restore) return .{ .restore = false };
    return .{ .restore = true };
}

/// Env values that turn a flag on: present and not empty, `0`, `false`,
/// `no` or `off` (case-insensitive).
pub fn envFlag(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return false, " \t");
    if (v.len == 0) return false;
    const off = [_][]const u8{ "0", "false", "no", "off" };
    for (off) |o| if (std.ascii.eqlIgnoreCase(v, o)) return false;
    return true;
}

pub const RunningMarker = struct {
    pid: u32,
    /// Process creation time as a Windows FILETIME (100 ns ticks).
    process_start_filetime: u64,
};

pub fn formatRunningMarker(m: RunningMarker, buf: []u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"pid\":{d},\"process_start_filetime\":{d}}}", .{ m.pid, m.process_start_filetime });
}

/// Null when the marker is not a JSON object with both integer fields.
pub fn parseRunningMarker(gpa: Allocator, bytes: []const u8) ?RunningMarker {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .parse_numbers = false }) catch return null;
    defer parsed.deinit();
    const o = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    return .{
        .pid = markerInt(u32, o.get("pid")) orelse return null,
        .process_start_filetime = markerInt(u64, o.get("process_start_filetime")) orelse return null,
    };
}

fn markerInt(comptime T: type, v: ?std.json.Value) ?T {
    const s = switch (v orelse return null) {
        .number_string => |s| s,
        else => return null,
    };
    return std.fmt.parseInt(T, s, 10) catch null;
}

pub const Liveness = enum {
    /// No process with that pid.
    dead,
    /// A process with that pid and the same start time: still running.
    alive_same,
    /// The pid was reused by another process.
    alive_other,
};

/// An instance exited uncleanly when its `session.running` marker remains
/// and its process is gone (or the pid now names another process).
pub fn isUncleanExit(marker: ?RunningMarker, owner: Liveness) bool {
    if (marker == null) return false;
    return owner != .alive_same;
}

/// After an unclean exit a scrollback checkpoint is merged only when it is
/// newer than the last saved snapshot (never over a newer save). A session
/// without a parseable `created_at` accepts the checkpoint.
pub fn shouldMergeCheckpoint(checkpoint_ms: i64, session_created_at: ?[]const u8) bool {
    const saved = schema.parseTimestamp(session_created_at orelse return true) orelse return true;
    return checkpoint_ms > saved;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "unit: session: file and quarantine names" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("session.unusable-1792058400123.json", try unusableName(&buf, 1_792_058_400_123));
    try testing.expectEqualStrings("session.crashed-0.json", try crashedName(&buf, -1));
    try testing.expectEqualStrings("session.schema-v4.json", try schemaVersionName(&buf, 4));
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, unusableName(&tiny, 1));
    var sb: [50]u8 = undefined;
    try testing.expectEqualStrings("scrollback/ABCDEF01-2345-4678-9ABC-DEF012345678.vt", try scrollbackRef(&sb, "abcdef01-2345-4678-9abc-def012345678"));
    try testing.expectError(error.InvalidUuid, scrollbackRef(&sb, "..\\..\\evil"));
}

test "unit: session: only canonical scrollback refs are safe" {
    try testing.expect(isSafeScrollbackRef("scrollback/ABCDEF01-2345-4678-9ABC-DEF012345678.vt"));
    try testing.expect(isSafeScrollbackRef("scrollback\\abcdef01-2345-4678-9abc-def012345678.vt"));
    const bad = [_][]const u8{
        "",
        "scrollback/../../../../Windows/system32/x.vt",
        "C:\\Users\\me\\scrollback\\ABCDEF01-2345-4678-9ABC-DEF012345678.vt",
        "/scrollback/ABCDEF01-2345-4678-9ABC-DEF012345678.vt",
        "scrollback/ABCDEF01-2345-4678-9ABC-DEF012345678.txt",
        "scrollbacks/BCDEF01-2345-4678-9ABC-DEF012345678.vt",
        "scrollback/ABCDEF01-2345-4678-9ABC-DEF01234567/.vt",
        "\\\\server\\share\\ABCDEF01-2345-4678-9ABC-DEF0123.vt",
    };
    for (bad) |b| try testing.expect(!isSafeScrollbackRef(b));
}

test "unit: session: atomic save sequence" {
    try testing.expectEqualSlices(SaveStep, &.{ .write_temp, .flush_temp, .move_write_through }, saveSteps(false));
    try testing.expectEqualSlices(SaveStep, &.{ .write_temp, .flush_temp, .replace_with_backup }, saveSteps(true));
    try testing.expectEqual(SaveStep.move_write_through, fallbackAfterReplaceFailure());
    try testing.expect(shouldRotatePrevious(.ok));
    try testing.expect(!shouldRotatePrevious(null));
    try testing.expect(!shouldRotatePrevious(.corrupt));
    try testing.expect(!shouldRotatePrevious(.{ .future = 4 }));
}

test "unit: session: classify file contents" {
    const a = testing.allocator;
    try testing.expectEqual(Verdict.empty, try classify(a, ""));
    try testing.expectEqual(Verdict.empty, try classify(a, " \r\n\t"));
    try testing.expectEqual(Verdict.corrupt, try classify(a, "{\"schema\":\"wmux-session\",\"vers"));
    try testing.expectEqual(Verdict.corrupt, try classify(a, "\x00\x00\x00\x00"));
    try testing.expectEqual(Verdict.not_session, try classify(a, "{\"schema\":\"other\"}"));
    try testing.expectEqual(Verdict{ .legacy = 2 }, try classify(a, "{\"version\":2,\"workspaces\":[]}"));
    try testing.expectEqual(Verdict{ .future = 7 }, try classify(a, "{\"schema\":\"wmux-session\",\"version\":7}"));
    try testing.expectEqual(Verdict.ok, try classify(a, @embedFile("testdata/v3_full.json")));
}

test "unit: session: load plan prefers primary, then backup, then previous" {
    try testing.expectEqual(LoadPlan{ .source = .primary }, planLoad(.{ .primary = .ok, .backup = .corrupt, .previous = .ok }));
    try testing.expectEqual(LoadPlan{}, planLoad(.{}));
    // Corrupt primary: quarantined, recovered from backup.
    try testing.expectEqual(
        LoadPlan{ .source = .backup, .quarantine = .move_unusable, .notice = .recovered_from_backup },
        planLoad(.{ .primary = .corrupt, .backup = .ok, .previous = .ok }),
    );
    // Empty primary, unusable backup: previous.
    try testing.expectEqual(
        LoadPlan{ .source = .previous, .quarantine = .move_unusable, .notice = .recovered_from_previous },
        planLoad(.{ .primary = .empty, .backup = .corrupt, .previous = .ok }),
    );
    // Missing primary (first save crashed before the move) with backup.
    try testing.expectEqual(LoadPlan{ .source = .backup }, planLoad(.{ .backup = .ok }));
    // Newer schema: side copy kept, older fallback used.
    try testing.expectEqual(
        LoadPlan{ .source = .previous, .quarantine = .{ .copy_schema_version = 4 }, .notice = .recovered_from_previous },
        planLoad(.{ .primary = .{ .future = 4 }, .previous = .ok }),
    );
    try testing.expectEqual(
        LoadPlan{ .quarantine = .{ .copy_schema_version = 9 }, .notice = .newer_schema },
        planLoad(.{ .primary = .{ .future = 9 }, .backup = .{ .future = 9 } }),
    );
    try testing.expectEqual(
        LoadPlan{ .quarantine = .move_unusable, .notice = .nothing_restorable },
        planLoad(.{ .primary = .not_session, .backup = .corrupt, .previous = .{ .legacy = 2 } }),
    );
    try testing.expectEqual(LoadPlan{ .quarantine = .move_unusable, .notice = .nothing_restorable }, planLoad(.{ .primary = .{ .legacy = 1 } }));
    try testing.expectEqual(LoadPlan{ .notice = .nothing_restorable }, planLoad(.{ .previous = .corrupt }));
}

test "unit: session: legacy migration runs only without any v3 file" {
    try testing.expect(shouldMigrateLegacy(.{}, true));
    try testing.expect(!shouldMigrateLegacy(.{}, false));
    try testing.expect(!shouldMigrateLegacy(.{ .primary = .corrupt }, true));
    try testing.expect(!shouldMigrateLegacy(.{ .previous = .ok }, true));
    try testing.expect(!shouldMigrateLegacy(.{ .backup = .empty }, true));
}

test "unit: session: import accepts only the current version" {
    try checkImport(.ok);
    try testing.expectError(error.NewerVersion, checkImport(.{ .future = 4 }));
    try testing.expectError(error.UnsupportedVersion, checkImport(.{ .legacy = 2 }));
    try testing.expectError(error.InvalidSession, checkImport(.corrupt));
    try testing.expectError(error.InvalidSession, checkImport(.empty));
    try testing.expectError(error.InvalidSession, checkImport(.not_session));
}

test "unit: session: launch guard and crash-loop rotation" {
    try testing.expectEqual(LaunchDecision{ .restore = true }, decideLaunch(.{}));
    try testing.expectEqual(LaunchDecision{ .restore = false }, decideLaunch(.{ .restore_disabled = true }));
    try testing.expectEqual(LaunchDecision{ .restore = false }, decideLaunch(.{ .explicit_intent = true }));
    try testing.expectEqual(LaunchDecision{ .restore = false }, decideLaunch(.{ .test_mode = true }));
    try testing.expectEqual(LaunchDecision{ .restore = true }, decideLaunch(.{ .test_mode = true, .test_session_restore = true }));
    const crashed: LaunchDecision = .{ .restore = false, .rotate_crashed = true, .crash_notice = true };
    try testing.expectEqual(crashed, decideLaunch(.{ .restoring_marker = true }));
    try testing.expectEqual(crashed, decideLaunch(.{ .restoring_marker = true, .restore_disabled = true }));
    // The launch after the rotation (marker deleted) restores normally.
    try testing.expectEqual(LaunchDecision{ .restore = true }, decideLaunch(.{ .restoring_marker = false }));
}

test "unit: session: env flags" {
    try testing.expect(!envFlag(null));
    try testing.expect(!envFlag(""));
    try testing.expect(!envFlag("0"));
    try testing.expect(!envFlag(" FALSE "));
    try testing.expect(!envFlag("Off"));
    try testing.expect(!envFlag("no"));
    try testing.expect(envFlag("1"));
    try testing.expect(envFlag("true"));
    try testing.expect(envFlag("yes"));
}

test "unit: session: running marker round-trips and rejects junk" {
    var buf: [96]u8 = undefined;
    const m: RunningMarker = .{ .pid = 4242, .process_start_filetime = 133_000_000_000_000_000 };
    const text = try formatRunningMarker(m, &buf);
    try testing.expectEqualStrings("{\"pid\":4242,\"process_start_filetime\":133000000000000000}", text);
    try testing.expectEqual(m, parseRunningMarker(testing.allocator, text).?);
    try testing.expectEqual(
        RunningMarker{ .pid = 1, .process_start_filetime = std.math.maxInt(u64) },
        parseRunningMarker(testing.allocator, "{\"pid\":1,\"process_start_filetime\":18446744073709551615,\"x\":0}").?,
    );
    const junk = [_][]const u8{ "", "{", "{}", "{\"pid\":-1,\"process_start_filetime\":1}", "{\"pid\":\"1\",\"process_start_filetime\":1}", "{\"pid\":1}", "[1,2]", "{\"pid\":4294967296,\"process_start_filetime\":1}" };
    for (junk) |j| try testing.expect(parseRunningMarker(testing.allocator, j) == null);
}

test "unit: session: unclean exit detection and checkpoint merge" {
    const m: RunningMarker = .{ .pid = 7, .process_start_filetime = 99 };
    try testing.expect(!isUncleanExit(null, .dead));
    try testing.expect(isUncleanExit(m, .dead));
    try testing.expect(isUncleanExit(m, .alive_other));
    try testing.expect(!isUncleanExit(m, .alive_same));
    const saved = "2026-10-15T10:00:00.000Z";
    try testing.expect(shouldMergeCheckpoint(1_792_058_400_001, saved));
    try testing.expect(!shouldMergeCheckpoint(1_792_058_400_000, saved));
    try testing.expect(!shouldMergeCheckpoint(1_000, saved));
    try testing.expect(shouldMergeCheckpoint(1_000, null));
    try testing.expect(shouldMergeCheckpoint(1_000, "garbage"));
}
