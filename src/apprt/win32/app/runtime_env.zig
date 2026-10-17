//! Every WMUX_* app input, parsed once at startup (ARCHITECTURE.md
//! ADR-1.6, ADR-12.3, Appendix G.2). The app reads `app.runtime_env`,
//! never the process environment, for these.
//!
//! Flags are true for "1", "true", "yes" or "on" (ASCII case-insensitive,
//! surrounding whitespace ignored) and false for anything else, including
//! unset and empty. Path values are copied; empty values count as unset.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RuntimeEnv = struct {
    /// WMUX_TEST_MODE: isolate the instance for automation (ADR-12.3): no
    /// global hotkey, no tray icon (desktop balloons go to the toast sink),
    /// no update check, no sounds, an in-process fake clipboard, MessageBox
    /// auto-answer, and session restore only with WMUX_TEST_SESSION_RESTORE.
    test_mode: bool = false,

    /// WMUX_TEST_HIDDEN: every top-level window is WS_EX_TOOLWINDOW |
    /// WS_EX_NOACTIVATE with a 1600x1000 client area (clamped to the
    /// primary work area) at the work-area origin, DWM-cloaked (off-screen
    /// at (-32000, -32000) only if cloaking fails), shown only with
    /// SW_SHOWNOACTIVATE; nothing activates (app/foreground.zig, including
    /// its WH_CBT hook) and window placement is neither saved nor restored.
    test_hidden: bool = false,

    /// WMUX_TEST_SESSION_RESTORE: allow session restore in test mode.
    test_session_restore: bool = false,

    /// WMUX_DISABLE_SESSION_RESTORE or CMUX_DISABLE_SESSION_RESTORE.
    disable_session_restore: bool = false,

    /// WMUX_STATE_DIR: overrides where state files live (app/paths.zig).
    state_dir: ?[]const u8 = null,

    /// WMUX_CONFIG_DIR: overrides the wmux config directory
    /// (app/paths.zig; consumed by the settings layer from W1-4 on).
    config_dir: ?[]const u8 = null,

    /// WMUX_TEST_TOAST_SINK: file receiving one JSON line per desktop
    /// notification that test mode does not show.
    test_toast_sink: ?[]const u8 = null,

    /// WMUX_TEST_EXTERNAL_SINK: file receiving one JSON line per external
    /// launch (ShellExecute: open_url, the update page, ...) that test mode
    /// does not perform (app/dialogs.zig, Appendix G / AF-16).
    test_external_sink: ?[]const u8 = null,

    /// WMUX_TEST_SOUND_SINK: file receiving one JSON line per sound
    /// (MessageBeep, PlaySound) that test mode does not play
    /// (app/dialogs.zig).
    test_sound_sink: ?[]const u8 = null,

    /// WMUX_TEST_FILE_DIALOG: what every file dialog answers in test mode
    /// (app/dialogs.zig): a path is returned as the selection; unset,
    /// empty or "cancel" cancels the dialog.
    test_file_dialog: ?[]const u8 = null,

    /// WMUX_LOG: the lowest level written to STATE\logs\wmux.log
    /// (app/logger.zig): "debug", "info" (default), "warn", "error" or
    /// "off" (no log file).
    log_level: LogLevel = .info,

    /// Parse the process environment. Never fails: an unreadable
    /// environment yields the defaults.
    pub fn load(alloc: Allocator) RuntimeEnv {
        var env = std.process.getEnvMap(alloc) catch return .{};
        defer env.deinit();
        return parse(alloc, &env);
    }

    /// Parse `env` (any type with `get(name) ?[]const u8`, e.g.
    /// std.process.EnvMap). Pure, so it is unit-tested.
    pub fn parse(alloc: Allocator, env: anytype) RuntimeEnv {
        return .{
            .test_mode = parseFlag(env.get("WMUX_TEST_MODE")),
            .test_hidden = parseFlag(env.get("WMUX_TEST_HIDDEN")),
            .test_session_restore = parseFlag(env.get("WMUX_TEST_SESSION_RESTORE")),
            .disable_session_restore = parseFlag(env.get("WMUX_DISABLE_SESSION_RESTORE")) or
                parseFlag(env.get("CMUX_DISABLE_SESSION_RESTORE")),
            .state_dir = dupePath(alloc, env.get("WMUX_STATE_DIR")),
            .config_dir = dupePath(alloc, env.get("WMUX_CONFIG_DIR")),
            .test_toast_sink = dupePath(alloc, env.get("WMUX_TEST_TOAST_SINK")),
            .test_external_sink = dupePath(alloc, env.get("WMUX_TEST_EXTERNAL_SINK")),
            .test_sound_sink = dupePath(alloc, env.get("WMUX_TEST_SOUND_SINK")),
            .test_file_dialog = dupePath(alloc, env.get("WMUX_TEST_FILE_DIALOG")),
            .log_level = LogLevel.parse(env.get("WMUX_LOG")),
        };
    }

    pub fn deinit(self: *RuntimeEnv, alloc: Allocator) void {
        if (self.state_dir) |v| alloc.free(v);
        if (self.config_dir) |v| alloc.free(v);
        if (self.test_toast_sink) |v| alloc.free(v);
        if (self.test_external_sink) |v| alloc.free(v);
        if (self.test_sound_sink) |v| alloc.free(v);
        if (self.test_file_dialog) |v| alloc.free(v);
        self.* = .{};
    }

    /// Whether the window placement (`window-state`) may be read and
    /// written: never in WMUX_TEST_HIDDEN (the hidden geometry is fixed),
    /// and in test mode only with WMUX_TEST_SESSION_RESTORE (ADR-12.3).
    pub fn placementPersistenceAllowed(self: *const RuntimeEnv) bool {
        if (self.test_hidden) return false;
        if (self.test_mode) return self.test_session_restore;
        return true;
    }

    /// Whether closing a window saves the session layout
    /// (`session-state.json`): in test mode only with
    /// WMUX_TEST_SESSION_RESTORE, so a test instance never leaves session
    /// state behind (ADR-12.3). The explicit `session-save` command is a
    /// request and is not gated.
    pub fn sessionSaveOnCloseAllowed(self: *const RuntimeEnv) bool {
        if (self.test_mode) return self.test_session_restore;
        return true;
    }

    /// Whether restoring the previous session on launch is allowed: never
    /// when disabled by WMUX_/CMUX_DISABLE_SESSION_RESTORE, and in test
    /// mode only with WMUX_TEST_SESSION_RESTORE. (Restore-on-launch itself
    /// arrives with W1-7; the explicit restore_session action and the
    /// `session-restore` command are user requests and are not gated.)
    pub fn sessionRestoreAllowed(self: *const RuntimeEnv) bool {
        if (self.disable_session_restore) return false;
        if (self.test_mode) return self.test_session_restore;
        return true;
    }
};

/// WMUX_LOG levels, from quietest to most verbose.
pub const LogLevel = enum(u3) {
    off,
    err,
    warn,
    info,
    debug,

    /// "off"/"none", "error"/"err", "warn"/"warning", "info",
    /// "debug"/"trace" (ASCII case-insensitive, trimmed); anything else,
    /// including unset, is the default `.info`.
    pub fn parse(value: ?[]const u8) LogLevel {
        const raw = value orelse return .info;
        const v = std.mem.trim(u8, raw, &std.ascii.whitespace);
        const table = .{
            .{ "off", LogLevel.off },     .{ "none", LogLevel.off },
            .{ "error", LogLevel.err },   .{ "err", LogLevel.err },
            .{ "warn", LogLevel.warn },   .{ "warning", LogLevel.warn },
            .{ "info", LogLevel.info },   .{ "debug", LogLevel.debug },
            .{ "trace", LogLevel.debug },
        };
        inline for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(v, entry[0])) return entry[1];
        }
        return .info;
    }

    /// Whether a record of level `record` is written at this threshold.
    pub fn allows(self: LogLevel, record: LogLevel) bool {
        if (self == .off or record == .off) return false;
        return @intFromEnum(record) <= @intFromEnum(self);
    }
};

/// The flag grammar: "1", "true", "yes", "on" (ASCII case-insensitive,
/// trimmed) are true; everything else, including null and "", is false.
pub fn parseFlag(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const v = std.mem.trim(u8, raw, &std.ascii.whitespace);
    inline for (.{ "1", "true", "yes", "on" }) |word| {
        if (std.ascii.eqlIgnoreCase(v, word)) return true;
    }
    return false;
}

/// Copy a path value; null when unset, empty, or out of memory (an
/// override that cannot be honored falls back to the legacy default).
fn dupePath(alloc: Allocator, value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    const v = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (v.len == 0) return null;
    return alloc.dupe(u8, v) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: app: runtime_env flag grammar" {
    try testing.expect(parseFlag("1"));
    try testing.expect(parseFlag("true"));
    try testing.expect(parseFlag("TRUE"));
    try testing.expect(parseFlag(" yes\t"));
    try testing.expect(parseFlag("On"));
    try testing.expect(!parseFlag(null));
    try testing.expect(!parseFlag(""));
    try testing.expect(!parseFlag("0"));
    try testing.expect(!parseFlag("false"));
    try testing.expect(!parseFlag("off"));
    try testing.expect(!parseFlag("2"));
    try testing.expect(!parseFlag("enabled"));
}

test "unit: app: runtime_env parses the test-mode and path variables" {
    const alloc = testing.allocator;
    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try env.put("WMUX_TEST_MODE", "1");
    try env.put("WMUX_TEST_HIDDEN", "true");
    try env.put("WMUX_STATE_DIR", "C:\\tmp\\state");
    try env.put("WMUX_CONFIG_DIR", "  ");
    try env.put("WMUX_TEST_TOAST_SINK", "C:\\tmp\\toasts.jsonl");
    try env.put("CMUX_DISABLE_SESSION_RESTORE", "1");

    var parsed = RuntimeEnv.parse(alloc, &env);
    defer parsed.deinit(alloc);
    try testing.expect(parsed.test_mode);
    try testing.expect(parsed.test_hidden);
    try testing.expect(!parsed.test_session_restore);
    try testing.expect(parsed.disable_session_restore);
    try testing.expectEqualStrings("C:\\tmp\\state", parsed.state_dir.?);
    try testing.expect(parsed.config_dir == null); // blank = unset
    try testing.expectEqualStrings("C:\\tmp\\toasts.jsonl", parsed.test_toast_sink.?);
}

test "unit: app: runtime_env session restore gating" {
    var e: RuntimeEnv = .{};
    try testing.expect(e.sessionRestoreAllowed());
    e.test_mode = true;
    try testing.expect(!e.sessionRestoreAllowed());
    e.test_session_restore = true;
    try testing.expect(e.sessionRestoreAllowed());
    e.disable_session_restore = true;
    try testing.expect(!e.sessionRestoreAllowed());
    e = .{ .disable_session_restore = true };
    try testing.expect(!e.sessionRestoreAllowed());
}

test "unit: app: runtime_env parses the sink, file dialog and log variables" {
    const alloc = testing.allocator;
    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try env.put("WMUX_TEST_EXTERNAL_SINK", "C:\\tmp\\external.jsonl");
    try env.put("WMUX_TEST_SOUND_SINK", " C:\\tmp\\sound.jsonl ");
    try env.put("WMUX_TEST_FILE_DIALOG", "");
    try env.put("WMUX_LOG", "Debug");

    var parsed = RuntimeEnv.parse(alloc, &env);
    defer parsed.deinit(alloc);
    try testing.expectEqualStrings("C:\\tmp\\external.jsonl", parsed.test_external_sink.?);
    try testing.expectEqualStrings("C:\\tmp\\sound.jsonl", parsed.test_sound_sink.?);
    try testing.expect(parsed.test_file_dialog == null); // empty = cancel
    try testing.expectEqual(LogLevel.debug, parsed.log_level);

    const defaults = RuntimeEnv.parse(alloc, &std.process.EnvMap.init(alloc));
    try testing.expectEqual(LogLevel.info, defaults.log_level);
    try testing.expect(defaults.test_external_sink == null);
}

test "unit: app: runtime_env WMUX_LOG levels" {
    try testing.expectEqual(LogLevel.info, LogLevel.parse(null));
    try testing.expectEqual(LogLevel.info, LogLevel.parse("loud"));
    try testing.expectEqual(LogLevel.off, LogLevel.parse("OFF"));
    try testing.expectEqual(LogLevel.off, LogLevel.parse("none"));
    try testing.expectEqual(LogLevel.err, LogLevel.parse("error"));
    try testing.expectEqual(LogLevel.warn, LogLevel.parse(" warning "));
    try testing.expectEqual(LogLevel.debug, LogLevel.parse("trace"));

    try testing.expect(LogLevel.info.allows(.err));
    try testing.expect(LogLevel.info.allows(.info));
    try testing.expect(!LogLevel.info.allows(.debug));
    try testing.expect(LogLevel.debug.allows(.debug));
    try testing.expect(!LogLevel.err.allows(.warn));
    try testing.expect(!LogLevel.off.allows(.err));
}

test "unit: app: runtime_env placement and close-time session save gating" {
    var e: RuntimeEnv = .{};
    try testing.expect(e.placementPersistenceAllowed());
    try testing.expect(e.sessionSaveOnCloseAllowed());
    e.test_mode = true;
    try testing.expect(!e.placementPersistenceAllowed());
    try testing.expect(!e.sessionSaveOnCloseAllowed());
    e.test_session_restore = true;
    try testing.expect(e.placementPersistenceAllowed());
    try testing.expect(e.sessionSaveOnCloseAllowed());
    // Hidden instances never persist placement, even with restore on.
    e.test_hidden = true;
    try testing.expect(!e.placementPersistenceAllowed());
    try testing.expect(e.sessionSaveOnCloseAllowed());
    e = .{ .test_hidden = true };
    try testing.expect(!e.placementPersistenceAllowed());
}
