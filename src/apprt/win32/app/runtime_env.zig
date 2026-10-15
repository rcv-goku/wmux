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
        };
    }

    pub fn deinit(self: *RuntimeEnv, alloc: Allocator) void {
        if (self.state_dir) |v| alloc.free(v);
        if (self.config_dir) |v| alloc.free(v);
        if (self.test_toast_sink) |v| alloc.free(v);
        self.* = .{};
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
