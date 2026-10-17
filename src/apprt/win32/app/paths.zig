//! Where wmux reads and writes its files (ARCHITECTURE.md ADR-1.6,
//! Appendix G.1). W0-A1 covers the state that exists today:
//!
//! - With WMUX_STATE_DIR set, `window-state`, `session-state.json`,
//!   `scrollback\`, `update_check_at`, the WebView2 user data
//!   (`webview2\`) and `logs\` live directly under it (test instances and
//!   isolated runs never touch the user's files).
//! - Unset, the legacy `%LOCALAPPDATA%\ghostty\...` paths are kept exactly;
//!   the new `logs\` (W0-A4) goes to `%LOCALAPPDATA%\wmux\logs`.
//!
//! Every state path of the app goes through this file (W0-A4).
//!
//! The CONFIG directory resolves WMUX_CONFIG_DIR → %XDG_CONFIG_HOME%\wmux
//! → %USERPROFILE%\.config\wmux for the settings layer (W1-4). The
//! Ghostty config file itself is still found by the Ghostty config loader.

const std = @import("std");
const Allocator = std.mem.Allocator;

const RuntimeEnv = @import("runtime_env.zig").RuntimeEnv;

/// Legacy state file names under %LOCALAPPDATA%\ghostty (or the state
/// directory override).
pub const window_state_file = "window-state";
pub const session_state_file = "session-state.json";
pub const scrollback_dir = "scrollback";
pub const webview2_dir = "webview2";
pub const update_check_file = "update_check_at";

/// The log directory under STATE (logsDir).
pub const logs_dir = "logs";

/// `<WMUX_STATE_DIR>\<name>` when the override is set, else the legacy
/// `%LOCALAPPDATA%\ghostty\<name>`. Caller owns the result. Fails like
/// the legacy code did when %LOCALAPPDATA% is missing.
pub fn statePath(alloc: Allocator, env: *const RuntimeEnv, name: []const u8) ![]u8 {
    if (env.state_dir) |dir| return join(alloc, dir, null, name);
    const local = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
    defer alloc.free(local);
    return join(alloc, local, "ghostty", name);
}

pub fn windowStatePath(alloc: Allocator, env: *const RuntimeEnv) ![]u8 {
    return statePath(alloc, env, window_state_file);
}

pub fn sessionStatePath(alloc: Allocator, env: *const RuntimeEnv) ![]u8 {
    return statePath(alloc, env, session_state_file);
}

pub fn scrollbackPath(alloc: Allocator, env: *const RuntimeEnv) ![]u8 {
    return statePath(alloc, env, scrollback_dir);
}

pub fn webview2UserDataPath(alloc: Allocator, env: *const RuntimeEnv) ![]u8 {
    return statePath(alloc, env, webview2_dir);
}

/// The update-check throttle timestamp (features/updater).
pub fn updateCheckPath(alloc: Allocator, env: *const RuntimeEnv) ![]u8 {
    return statePath(alloc, env, update_check_file);
}

/// STATE\logs (Appendix G.1, AF-16): `<WMUX_STATE_DIR>\logs`, else
/// `%LOCALAPPDATA%\wmux\logs` (the STATE root without the channel level,
/// which arrives with W1-1; logs never went to the legacy ghostty
/// directory). Caller owns the result.
pub fn logsDir(alloc: Allocator, env: *const RuntimeEnv) ![]u8 {
    if (env.state_dir) |dir| return join(alloc, dir, null, logs_dir);
    const local = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
    defer alloc.free(local);
    return join(alloc, local, "wmux", logs_dir);
}

/// The wmux CONFIG directory (Appendix G.1): WMUX_CONFIG_DIR, else
/// %XDG_CONFIG_HOME%\wmux, else %USERPROFILE%\.config\wmux. Caller owns
/// the result.
pub fn configDir(alloc: Allocator, env: *const RuntimeEnv) ![]u8 {
    if (env.config_dir) |dir| return alloc.dupe(u8, dir);
    if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
        defer alloc.free(xdg);
        if (xdg.len > 0) return join(alloc, xdg, null, "wmux");
    } else |_| {}
    const home = try std.process.getEnvVarOwned(alloc, "USERPROFILE");
    defer alloc.free(home);
    return join(alloc, home, ".config", "wmux");
}

/// `base[\middle]\name`, joined like the legacy code (std.fs.path.join).
fn join(alloc: Allocator, base: []const u8, middle: ?[]const u8, name: []const u8) ![]u8 {
    if (middle) |m| return std.fs.path.join(alloc, &.{ base, m, name });
    return std.fs.path.join(alloc, &.{ base, name });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "unit: app: paths put state files under WMUX_STATE_DIR" {
    const alloc = testing.allocator;
    const env: RuntimeEnv = .{ .state_dir = "C:\\tmp\\wmux-state" };

    const ws = try windowStatePath(alloc, &env);
    defer alloc.free(ws);
    try testing.expectEqualStrings("C:\\tmp\\wmux-state\\window-state", ws);

    const ss = try sessionStatePath(alloc, &env);
    defer alloc.free(ss);
    try testing.expectEqualStrings("C:\\tmp\\wmux-state\\session-state.json", ss);

    const sb = try scrollbackPath(alloc, &env);
    defer alloc.free(sb);
    try testing.expectEqualStrings("C:\\tmp\\wmux-state\\scrollback", sb);

    const wv = try webview2UserDataPath(alloc, &env);
    defer alloc.free(wv);
    try testing.expectEqualStrings("C:\\tmp\\wmux-state\\webview2", wv);

    const uc = try updateCheckPath(alloc, &env);
    defer alloc.free(uc);
    try testing.expectEqualStrings("C:\\tmp\\wmux-state\\update_check_at", uc);

    const logs = try logsDir(alloc, &env);
    defer alloc.free(logs);
    try testing.expectEqualStrings("C:\\tmp\\wmux-state\\logs", logs);
}

test "unit: app: paths put logs under LOCALAPPDATA wmux without an override" {
    const alloc = testing.allocator;
    const local = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch
        return error.SkipZigTest;
    defer alloc.free(local);
    const expected = try std.fs.path.join(alloc, &.{ local, "wmux", "logs" });
    defer alloc.free(expected);

    const env: RuntimeEnv = .{};
    const got = try logsDir(alloc, &env);
    defer alloc.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "unit: app: paths keep the legacy LOCALAPPDATA layout without an override" {
    const alloc = testing.allocator;
    const local = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch
        return error.SkipZigTest;
    defer alloc.free(local);
    const expected = try std.fs.path.join(alloc, &.{ local, "ghostty", "session-state.json" });
    defer alloc.free(expected);

    const env: RuntimeEnv = .{};
    const got = try sessionStatePath(alloc, &env);
    defer alloc.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "unit: app: paths config dir honors WMUX_CONFIG_DIR" {
    const alloc = testing.allocator;
    const env: RuntimeEnv = .{ .config_dir = "D:\\cfg\\wmux" };
    const got = try configDir(alloc, &env);
    defer alloc.free(got);
    try testing.expectEqualStrings("D:\\cfg\\wmux", got);
}
